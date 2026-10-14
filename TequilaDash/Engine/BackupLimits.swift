import Foundation

/// Dynamic safety limits shared by backup export and restore.
///
/// The original code hard-capped every archive at 5,000 files / 512 MiB
/// (`BackupService` and `RestoreService` each carried their own copy). That
/// fixed gate rejected perfectly valid app containers with
/// "Safety limit exceeded", and it had nothing to do with any ZIP format
/// limit. These helpers replace it with a budget derived from the volume's
/// free space.
///
/// Why keep any limit at all: the archive is written to the same volume it is
/// read from, so a backup needs roughly `totalBytes` of headroom. Without a
/// guard, a runaway directory tree (or a bug in the walker) could fill the
/// device and take down the whole system.
enum BackupLimits {

    /// Entry-count ceiling for one archive.
    ///
    /// ZIP64 lifts the 65,535-entry format limit, so this is only a sanity
    /// guard against runaway trees, not a container constraint.
    static let maxFiles = 500_000

    /// Lower bound for the byte limit, even on a nearly full volume.
    ///
    /// A backup that genuinely cannot fit fails later with a disk-full error,
    /// which is far clearer to the user than "safety limit exceeded".
    static let minimumMaxBytes: Int64 = 1 * 1024 * 1024 * 1024

    /// Upper bound regardless of how much free space the device reports.
    static let absoluteMaxBytes: Int64 = 64 * 1024 * 1024 * 1024

    /// A single archive may consume at most this fraction of free space. The
    /// other half is left for the system and for the app being backed up.
    static let freeSpaceFraction = 0.5

    /// Resolve the byte ceiling for the volume backing `url` (defaults to the
    /// Backups directory, which is the volume an export is written to).
    ///
    /// Falls back to `absoluteMaxBytes` when the filesystem does not report
    /// free space, so an unknown volume never silently shrinks the limit.
    static func maxTotalBytes(for url: URL? = nil) -> Int64 {
        let probe = url ?? BackupPaths.backupsDirectory()
        guard let available = availableCapacity(at: probe), available > 0 else {
            return absoluteMaxBytes
        }
        let budget = Int64(Double(available) * freeSpaceFraction)
        return min(max(budget, minimumMaxBytes), absoluteMaxBytes)
    }

    /// Free space in bytes for the volume containing `url`, or `nil` when the
    /// filesystem does not report it.
    static func availableCapacity(at url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        // Coarser fallback for volumes that do not support the "important
        // usage" variant.
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return nil
    }
}
