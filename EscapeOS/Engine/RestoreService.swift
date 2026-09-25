import Foundation
import CryptoKit
import Darwin

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

    // Safety limits live in `BackupLimits` and are resolved per call. The old
    // hard-coded 5,000 files / 512 MiB gate rejected archives that the (now
    // unlimited) export side happily produced, so both sides share the same
    // dynamic budget.

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
                version: nil,
                applicationType: nil
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
            warnings.append("关闭 \(app.name) 后再恢复.应用运行时打开的数据库可能无法完整恢复.")
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
                "备份时的容器路径与当前不一致，恢复将写入当前容器."
            )
        }
        warnings.append("关闭 \(app.name) 后再恢复.应用运行时打开的数据库可能无法完整恢复.")

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
        if metadata.isContainerApp {
            // Container backups carry a synthetic bundle id
            // (`host::guestBundleId::uuid`). Restoring into a *different* UUID
            // sandbox of the same guest app is the whole point of the sandbox
            // picker, so we match on the guest bundle id (middle segment)
            // rather than the full synthetic id.
            guard guestBundleId(from: metadata.bundleIdentifier) == guestBundleId(from: app.bundleIdentifier) else {
                throw BackupError.restoreBlocked(
                    "Backup app (\(guestBundleId(from: metadata.bundleIdentifier))) does not match target (\(guestBundleId(from: app.bundleIdentifier)))."
                )
            }
        } else {
            guard metadata.bundleIdentifier == app.bundleIdentifier else {
                throw BackupError.restoreBlocked(
                    "Backup bundle ID \(metadata.bundleIdentifier) does not match \(app.bundleIdentifier)."
                )
            }
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
        guard manifest.count <= BackupLimits.maxFiles else {
            throw BackupError.restoreBlocked(
                "Backup contains \(manifest.count) files, which exceeds the supported limit of \(BackupLimits.maxFiles)."
            )
        }

        let totalBytes = manifest.reduce(Int64(0)) { $0 + Int64($1.size) }
        let maxTotalBytes = BackupLimits.maxTotalBytes()
        guard totalBytes <= maxTotalBytes else {
            throw BackupError.restoreBlocked(
                "Backup is \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                    + " which exceeds the current size limit of "
                    + ByteCountFormatter.string(fromByteCount: maxTotalBytes, countStyle: .file)
                    + ". Free up space and try again."
            )
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

                let absolute = (app.containerPath as NSString).appendingPathComponent(entry.path)
                let parent = (absolute as NSString).deletingLastPathComponent
                if !files.exists(at: parent) {
                    try files.createDirectory(at: parent)
                }

                // Stream the entry to disk in fixed-size chunks. This is the
                // v0.3.532 fix for "restoring a single >4 GiB file runs out of
                // memory": the old code read the whole entry into `Data` before
                // writing it, so one big file was enough to get the process
                // jetsam-killed. See `writeEntryStreaming` for how the manifest
                // checksum stays just as strict while the bytes never sit in
                // memory all at once.
                let written = try writeEntryStreaming(from: reader, entry: entry, to: absolute)
                filesRestored += 1
                bytesWritten += written
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

    /// Stream one manifest entry into `destination` with constant memory, and
    /// publish it only once the entry has been fully verified.
    ///
    /// Ordering (this is the part that must not be reordered):
    /// 1. The entry is streamed straight from the archive into a sibling temp
    ///    file while SHA-256 is accumulated incrementally and the byte count is
    ///    tallied. `destination` is not touched yet, so a corrupt, truncated or
    ///    mismatching archive can never destroy the file already sitting there.
    /// 2. When the stream ends, the byte count must equal `entry.size` and the
    ///    accumulated digest must equal `entry.sha256`. These are the same two
    ///    manifest checks the old read-whole-entry code ran - only now they are
    ///    computed in the single streaming pass instead of after buffering the
    ///    entire file. The archive's own CRC32 is additionally verified inside
    ///    `ZipReader.streamEntry`.
    /// 3. Only after both checks pass is the verified temp file atomically
    ///    swapped onto `destination`.
    ///
    /// Failure handling: the temp file is deleted on every failing path
    /// (checksum/size mismatch, disk full, cancellation, read error), so a
    /// failed restore never leaves a half-written file behind, and the previous
    /// contents of `destination` survive a verification failure untouched.
    ///
    /// Memory stays at one `ZipReader.streamEntry` chunk (1 MiB) no matter how
    /// large the entry is.
    private func writeEntryStreaming(
        from reader: ZipReader,
        entry: BackupManifestEntry,
        to destination: String
    ) throws -> Int64 {
        let fm = FileManager.default
        let directory = (destination as NSString).deletingLastPathComponent
        // The temp file lives in the destination's own directory so the final
        // step is a rename within one filesystem (atomic) rather than a
        // cross-volume copy. The dotted prefix keeps it out of the way if a
        // crash ever leaves one behind.
        let tempPath = (directory as NSString)
            .appendingPathComponent(".escapeos-restore-\(UUID().uuidString).tmp")

        guard fm.createFile(atPath: tempPath, contents: nil) else {
            throw BackupError.writeFailed("Could not create a temporary file next to \(destination)")
        }
        var published = false
        defer {
            // Also runs on success, where the temp file has already been moved
            // away and this removal is a harmless no-op.
            if !published { try? fm.removeItem(atPath: tempPath) }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))
        } catch {
            throw BackupError.writeFailed("Could not open temporary file: \(error.localizedDescription)")
        }

        var hasher = SHA256()
        var written: Int64 = 0
        do {
            try reader.streamEntry(named: entry.path) { chunk in
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                written += Int64(chunk.count)
            }
            try handle.close()
        } catch {
            // Disk full, cancellation, a CRC failure inside the reader, or any
            // other read error. Close first (idempotent), then let `defer`
            // remove the partial temp file before the error propagates.
            try? handle.close()
            throw error
        }

        // Same two guards, in the same order, as the previous read-whole-entry
        // implementation: checksum first, then size.
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            throw BackupError.invalidArchive("Checksum mismatch for \(entry.path)")
        }
        guard written == Int64(entry.size) else {
            throw BackupError.invalidArchive("Size mismatch for \(entry.path)")
        }

        try publish(tempPath: tempPath, to: destination)
        published = true
        return written
    }

    /// Move a fully verified temp file onto `destination`, replacing it.
    ///
    /// Only `rename(2)` is used, and deliberately so:
    /// - it is atomic on APFS, so a reader never observes a half-written file;
    /// - it replaces an existing destination in the same single step, so there
    ///   is no window in which the file is missing;
    /// - it is exactly the primitive `Data.write(options: .atomic)` uses, so the
    ///   end result matches the previous implementation (the destination inode
    ///   is swapped, it is not modified in place).
    /// The temp file is always in the destination's own directory, so both
    /// paths are guaranteed to live on the same filesystem.
    private func publish(tempPath: String, to destination: String) throws {
        // `errno` is captured inside the closure, right after `rename`, because
        // anything else that runs in between could overwrite it.
        var failure: Int32 = 0
        let result = tempPath.withCString { from in
            destination.withCString { to in
                let rc = rename(from, to)
                if rc != 0 { failure = errno }
                return rc
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(failure))
            throw BackupError.writeFailed("Could not replace \(destination): \(reason)")
        }
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

    /// Extract the guest bundle id (middle segment) from a synthetic
    /// `host::guestBundleId::uuid` id. Returns the input unchanged when it
    /// doesn't follow that shape.
    private func guestBundleId(from synthetic: String) -> String {
        let parts = synthetic.components(separatedBy: "::")
        return parts.count == 3 ? parts[1] : synthetic
    }

    /// For a container-app backup, return the LiveContainer guest sandboxes
    /// currently present on the device that match the backed-up app (same host
    /// + same guest bundle id). Empty when the app is no longer hosted or when
    /// discovery fails. Used by the restore flow to offer a sandbox picker when
    /// more than one sandbox exists for the same guest app.
    func candidateSandboxes(for record: BackupRecord, installedApps: [InstalledApp]) -> [LiveContainerGuest] {
        guard record.metadata.isContainerApp else { return [] }
        let parts = record.metadata.bundleIdentifier.components(separatedBy: "::")
        guard parts.count == 3 else { return [] }
        let hostBundleId = parts[0]
        let guestBundleId = parts[1]
        let discovery = LiveContainerDiscovery()
        let instances = discovery.discover(installedApps: installedApps)
        var matches: [LiveContainerGuest] = []
        for instance in instances {
            for guest in instance.guests {
                let guestParts = guest.id.components(separatedBy: "::")
                let guestHost = guestParts.first ?? ""
                if guestHost == hostBundleId && guest.bundleIdentifier == guestBundleId {
                    matches.append(guest)
                }
            }
        }
        return matches
    }
}
