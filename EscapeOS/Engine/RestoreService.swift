import Foundation
import CryptoKit

/// Progress callback for restore operations.
typealias RestoreProgress = (_ filesRestored: Int, _ totalFiles: Int, _ currentFile: String) -> Void

/// Result of a completed restore.
struct RestoreResult {
    let filesRestored: Int
    let bytesWritten: Int64
    let targetApp: InstalledApp
    let backupMetadata: BackupMetadata
}

/// Pre-flight status for a backup against currently installed apps.
enum RestoreEligibility {
    case ready(app: InstalledApp, metadata: BackupMetadata, warnings: [String])
    case appNotInstalled(bundleIdentifier: String, appName: String)
    case invalidArchive(String)

    var canRestore: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Restores a backup archive into an installed app's Data container.
final class RestoreService {

    private let escape = SandboxEscape()
    private let files = FileService()

    private let maxFiles = 5000
    private let maxTotalBytes: Int64 = 512 * 1024 * 1024

    /// Evaluate whether a backup can be restored right now.
    func eligibility(for record: BackupRecord, installedApps: [InstalledApp]) -> RestoreEligibility {
        let metadata = record.metadata

        // Container apps (LiveContainer guests) are not in the system app list.
        // Eligibility is based on whether the recorded container path still exists
        // and is reachable through the sandbox extension.
        if metadata.isContainerApp {
            let app = InstalledApp(
                bundleIdentifier: metadata.bundleIdentifier,
                name: metadata.appName,
                containerPath: metadata.containerPath,
                version: nil
            )
            var warnings: [String] = []
            do {
                try escape.withHandle(for: app.containerPath) { _ in
                    if !files.isDirectory(at: app.containerPath) {
                        throw BackupError.appNotInstalled(
                            "Container path is no longer reachable: \(app.containerPath)"
                        )
                    }
                }
            } catch {
                return .appNotInstalled(
                    bundleIdentifier: metadata.bundleIdentifier,
                    appName: metadata.appName
                )
            }
            warnings.append("关闭 \(app.name) 后再恢复。应用运行时打开的数据库可能无法完整恢复。")
            return .ready(app: app, metadata: metadata, warnings: warnings)
        }

        guard let app = installedApps.first(where: { $0.bundleIdentifier == metadata.bundleIdentifier }) else {
            return .appNotInstalled(
                bundleIdentifier: metadata.bundleIdentifier,
                appName: metadata.appName
            )
        }

        var warnings: [String] = []
        if app.containerPath != metadata.containerPath {
            warnings.append(
                "备份时的容器路径与当前不一致，恢复将写入当前容器。"
            )
        }
        warnings.append("关闭 \(app.name) 后再恢复。应用运行时打开的数据库可能无法完整恢复。")

        return .ready(app: app, metadata: metadata, warnings: warnings)
    }

    /// Restore a backup archive into the target app container.
    func restore(
        record: BackupRecord,
        to app: InstalledApp,
        progress: RestoreProgress? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> RestoreResult {
        let reader = try ZipReader(url: record.archiveURL)

        guard reader.entries[BackupPaths.manifestFileName] != nil else {
            throw BackupError.invalidArchive("Missing \(BackupPaths.manifestFileName)")
        }
        guard reader.entries[BackupPaths.metadataFileName] != nil else {
            throw BackupError.invalidArchive("Missing \(BackupPaths.metadataFileName)")
        }

        let metadataData = try reader.readEntry(named: BackupPaths.metadataFileName)
        let metadata = try JSONDecoder().decode(BackupMetadata.self, from: metadataData)
        guard metadata.bundleIdentifier == app.bundleIdentifier else {
            throw BackupError.restoreBlocked(
                "Backup bundle ID \(metadata.bundleIdentifier) does not match \(app.bundleIdentifier)."
            )
        }

        let manifestData = try reader.readEntry(named: BackupPaths.manifestFileName)
        let manifestHash = SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard manifestHash == metadata.manifestSHA256 else {
            throw BackupError.invalidArchive("Manifest checksum does not match backup metadata.")
        }

        let manifest = try JSONDecoder().decode([BackupManifestEntry].self, from: manifestData)
        guard !manifest.isEmpty else {
            throw BackupError.invalidArchive("Backup manifest is empty.")
        }
        guard manifest.count <= maxFiles else {
            throw BackupError.restoreBlocked("Backup exceeds the maximum supported file count.")
        }

        let totalBytes = manifest.reduce(Int64(0)) { $0 + Int64($1.size) }
        guard totalBytes <= maxTotalBytes else {
            throw BackupError.restoreBlocked("Backup exceeds the maximum supported size.")
        }

        var filesRestored = 0
        var bytesWritten: Int64 = 0

        try escape.withHandle(for: app.containerPath) { _ in
            for entry in manifest {
                if isCancelled() { throw BackupError.cancelled }
                try validateRelativePath(entry.path)

                guard reader.entries[entry.path] != nil else {
                    throw BackupError.invalidArchive("Archive is missing \(entry.path)")
                }

                let data = try reader.readEntry(named: entry.path)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == entry.sha256 else {
                    throw BackupError.invalidArchive("Checksum mismatch for \(entry.path)")
                }
                guard data.count == entry.size else {
                    throw BackupError.invalidArchive("Size mismatch for \(entry.path)")
                }

                let absolute = (app.containerPath as NSString).appendingPathComponent(entry.path)
                let parent = (absolute as NSString).deletingLastPathComponent
                if !files.exists(at: parent) {
                    try files.createDirectory(at: parent)
                }

                try files.writeFile(data: data, to: absolute)
                filesRestored += 1
                bytesWritten += Int64(data.count)
                progress?(filesRestored, manifest.count, entry.path)
            }
        }

        return RestoreResult(
            filesRestored: filesRestored,
            bytesWritten: bytesWritten,
            targetApp: app,
            backupMetadata: metadata
        )
    }

    private func validateRelativePath(_ path: String) throws {
        if path.hasPrefix("/") || path.contains("..") {
            throw BackupError.restoreBlocked("Unsafe path in backup: \(path)")
        }
        let root = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        guard let root, BackupService.backupRoots.contains(root) else {
            throw BackupError.restoreBlocked("Backup path outside allowed roots: \(path)")
        }
    }
}
