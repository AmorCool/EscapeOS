import Foundation
import CryptoKit

/// Progress callback for backup export.
typealias BackupProgress = (_ filesProcessed: Int, _ totalBytes: Int64, _ currentFile: String) -> Void

/// Result of a completed backup export.
struct BackupResult {
    let archiveURL: URL
    let fileCount: Int
    let totalBytes: Int64
    let manifestSHA256: String
    let metadata: BackupMetadata
}

/// Errors specific to backup / restore archives.
enum BackupError: Error, LocalizedError {
    case containerInaccessible(String)
    case writeFailed(String)
    case cancelled
    case invalidArchive(String)
    case restoreBlocked(String)
    case appNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .containerInaccessible(let m): return "Container inaccessible: \(m)"
        case .writeFailed(let m): return "Failed to write backup: \(m)"
        case .cancelled: return "Backup was cancelled."
        case .invalidArchive(let m): return "Invalid backup archive: \(m)"
        case .restoreBlocked(let m): return m
        case .appNotInstalled(let id): return "App is not installed: \(id)"
        }
    }
}

/// Exports an app's Data container (Documents, Library, tmp) into a zip
/// archive with a manifest of SHA-256 hashes. Read-only with respect to the
/// target app during export.
final class BackupService {

    private let escape = SandboxEscape()
    private let files = FileService()

    /// Subtrees of a Data container we export and restore.
    static let backupRoots = ["Documents", "Library", "tmp"]

    // Safety limits live in `BackupLimits`. The previous hard-coded
    // 5,000 files / 512 MiB gate was removed in v0.3.531: it was not a ZIP
    // limit and it silently rejected valid containers. The byte ceiling is now
    // derived from the volume's free space, and the file ceiling only guards
    // against runaway trees (ZIP64 removed the 65,535-entry format limit).

    /// Export the given app's container to a zip inside Documents/Backups.
    func exportBackup(
        for app: InstalledApp,
        isContainerApp: Bool = false,
        iconData: Data? = nil,
        progress: BackupProgress? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> BackupResult {
        let backupsDir = try BackupPaths.ensureBackupsDirectory()
        let stamp = BackupPaths.fileTimestamp()
        // Preserve Unicode letters/numbers (including CJK) plus `_` and `-`;
        // replace filesystem-unsafe characters with `_`. Falls back to the
        // bundle identifier if the app name sanitizes to nothing.
        var safeName = app.name.replacingOccurrences(
            of: "[^\\p{L}\\p{N}_\\-]",
            with: "_",
            options: .regularExpression
        )
        if safeName.isEmpty {
            safeName = app.bundleIdentifier.replacingOccurrences(
                of: "[^\\p{L}\\p{N}_\\-]",
                with: "_",
                options: .regularExpression
            )
        }
        if safeName.isEmpty {
            safeName = "App"
        }
        let outURL = backupsDir.appendingPathComponent("\(safeName)_backup_\(stamp).zip")

        // Resolve the limits once per export. The byte ceiling depends on the
        // free space of the volume we are about to write the archive to.
        let maxFiles = BackupLimits.maxFiles
        let maxTotalBytes = BackupLimits.maxTotalBytes(for: backupsDir)

        var manifest: [BackupManifestEntry] = []
        var totalBytes: Int64 = 0

        let zip = ZipWriter()
        do {
            try zip.begin(at: outURL)
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }

        do {
            try escape.withHandle(for: app.containerPath) { _ in
                var foundRoot = false
                for root in Self.backupRoots {
                    if isCancelled() { throw BackupError.cancelled }
                    let rootPath = (app.containerPath as NSString).appendingPathComponent(root)
                    guard files.isDirectory(at: rootPath) else { continue }
                    foundRoot = true
                    try walk(
                        path: rootPath,
                        relativePrefix: root,
                        zip: zip,
                        manifest: &manifest,
                        totalBytes: &totalBytes,
                        maxFiles: maxFiles,
                        maxTotalBytes: maxTotalBytes,
                        progress: progress,
                        isCancelled: isCancelled
                    )
                }
                if !foundRoot {
                    throw BackupError.containerInaccessible(
                        "Documents, Library, and tmp were not visible after opening \(app.containerPath)"
                    )
                }
            }
        } catch let error as BackupError {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestHash = SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }
            .joined()
        try zip.addFile(name: BackupPaths.manifestFileName, data: manifestData)

        let metadata = BackupMetadata(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            containerPath: app.containerPath,
            createdAt: BackupPaths.isoTimestamp(),
            fileCount: manifest.count,
            totalBytes: totalBytes,
            manifestSHA256: manifestHash,
            escapeOSVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            isContainerApp: isContainerApp,
            iconData: iconData
        )
        let metadataData = try encoder.encode(metadata)
        try zip.addFile(name: BackupPaths.metadataFileName, data: metadataData)

        do {
            try zip.finish()
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw BackupError.writeFailed(error.localizedDescription)
        }

        return BackupResult(
            archiveURL: outURL,
            fileCount: manifest.count,
            totalBytes: totalBytes,
            manifestSHA256: manifestHash,
            metadata: metadata
        )
    }

    private func walk(
        path: String,
        relativePrefix: String,
        zip: ZipWriter,
        manifest: inout [BackupManifestEntry],
        totalBytes: inout Int64,
        maxFiles: Int,
        maxTotalBytes: Int64,
        progress: BackupProgress?,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw BackupError.cancelled }

        let entries: [FileItem]
        do {
            entries = try files.list(directory: path)
        } catch {
            throw BackupError.containerInaccessible(error.localizedDescription)
        }

        for entry in entries {
            if isCancelled() { throw BackupError.cancelled }
            let rel = "\(relativePrefix)/\(entry.name)"

            if entry.isDirectory {
                try walk(
                    path: entry.path,
                    relativePrefix: rel,
                    zip: zip,
                    manifest: &manifest,
                    totalBytes: &totalBytes,
                    maxFiles: maxFiles,
                    maxTotalBytes: maxTotalBytes,
                    progress: progress,
                    isCancelled: isCancelled
                )
            } else if entry.kind == .regular {
                let added: ZipAddedFile
                do {
                    // Stream from disk: the file is never held in memory, so a
                    // multi-gigabyte file no longer risks a jetsam kill. The
                    // SHA-256 the manifest needs is computed in the same pass.
                    added = try zip.addFile(name: rel, path: entry.path, expectedSize: entry.size)
                } catch ZipWriterError.cannotReadSource {
                    // Locked or removed between listing and read. Nothing was
                    // written for this file, so skipping keeps the archive
                    // consistent (same as the previous behaviour).
                    continue
                } catch {
                    // The local header is already on disk with a partial
                    // payload, so the archive must be discarded by the caller.
                    throw BackupError.writeFailed(error.localizedDescription)
                }

                manifest.append(BackupManifestEntry(path: rel, size: Int(added.size), sha256: added.sha256))
                totalBytes += added.size
                progress?(manifest.count, totalBytes, rel)

                // Guard after every file rather than once per directory. The
                // old entry-level check could be skipped entirely when the
                // overflow happened inside the last existing root.
                if manifest.count > maxFiles || totalBytes > maxTotalBytes {
                    throw BackupError.writeFailed(
                        "Safety limit exceeded (over \(maxFiles) files or over "
                            + ByteCountFormatter.string(fromByteCount: maxTotalBytes, countStyle: .file)
                            + " of data)."
                    )
                }
            }
        }
    }
}
