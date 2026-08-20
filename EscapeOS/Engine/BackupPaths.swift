import Foundation

/// Metadata embedded in every backup archive as `backup.json`.
struct BackupMetadata: Codable, Hashable {
    let bundleIdentifier: String
    let appName: String
    let containerPath: String
    let createdAt: String
    let fileCount: Int
    let totalBytes: Int64
    let manifestSHA256: String
    let escapeOSVersion: String
    /// Whether this backup was created from a LiveContainer guest app rather than
    /// a system-installed app. Defaults to `false` for archives created before
    /// v0.2.4.
    let isContainerApp: Bool
    /// Pre-decoded icon bytes for the backed-up app, embedded so container-app
    /// backups (whose synthetic bundle id isn't in the system icon cache) still
    /// show their icon in the Backups list. `nil` for pre-v0.2.5 archives.
    let iconData: Data?

    init(
        bundleIdentifier: String,
        appName: String,
        containerPath: String,
        createdAt: String,
        fileCount: Int,
        totalBytes: Int64,
        manifestSHA256: String,
        escapeOSVersion: String,
        isContainerApp: Bool = false,
        iconData: Data? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.containerPath = containerPath
        self.createdAt = createdAt
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.manifestSHA256 = manifestSHA256
        self.escapeOSVersion = escapeOSVersion
        self.isContainerApp = isContainerApp
        self.iconData = iconData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        appName = try c.decode(String.self, forKey: .appName)
        containerPath = try c.decode(String.self, forKey: .containerPath)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        fileCount = try c.decode(Int.self, forKey: .fileCount)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        manifestSHA256 = try c.decode(String.self, forKey: .manifestSHA256)
        escapeOSVersion = try c.decode(String.self, forKey: .escapeOSVersion)
        isContainerApp = try c.decodeIfPresent(Bool.self, forKey: .isContainerApp) ?? false
        iconData = try c.decodeIfPresent(Data.self, forKey: .iconData)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, appName, containerPath, createdAt
        case fileCount, totalBytes, manifestSHA256, escapeOSVersion, isContainerApp, iconData
    }
}

/// A backup archive on disk with parsed metadata.
struct BackupRecord: Identifiable, Hashable {
    let id: String
    let archiveURL: URL
    let metadata: BackupMetadata
    let archiveFileName: String
    let archiveBytes: Int64
    let modified: Date?

    var displayTitle: String { metadata.appName }
    var displaySubtitle: String {
        "\(metadata.fileCount) files · \(Self.formatBytes(metadata.totalBytes))"
    }
}

/// Shared paths and catalog helpers for backup archives.
enum BackupPaths {
    static let folderName = "Backups"
    static let metadataFileName = "backup.json"
    static let manifestFileName = "manifest.json"

    static func backupsDirectory() -> URL {
        documentsDirectory().appendingPathComponent(folderName, isDirectory: true)
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    @discardableResult
    static func ensureBackupsDirectory() throws -> URL {
        let dir = backupsDirectory()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func isoTimestamp(from date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func fileTimestamp(from date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date)
    }

    static let displayStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Lists backup archives stored under Documents/Backups.
final class BackupCatalog {

    func loadRecords() throws -> [BackupRecord] {
        let dir = try BackupPaths.ensureBackupsDirectory()
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.lowercased().hasSuffix(".zip") }
            .sorted(by: >)

        var records: [BackupRecord] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            do {
                let record = try loadRecord(at: url)
                records.append(record)
            } catch {
                continue
            }
        }
        return records.sorted {
            ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
        }
    }

    func loadRecords(forBundleIdentifier bundleId: String) throws -> [BackupRecord] {
        try loadRecords().filter { $0.metadata.bundleIdentifier == bundleId }
    }

    func loadRecord(at url: URL) throws -> BackupRecord {
        let reader = try ZipReader(url: url)
        guard reader.entries[BackupPaths.metadataFileName] != nil else {
            throw BackupError.invalidArchive("Missing \(BackupPaths.metadataFileName)")
        }
        let metadataData = try reader.readEntry(named: BackupPaths.metadataFileName)
        let metadata = try JSONDecoder().decode(BackupMetadata.self, from: metadataData)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date
        return BackupRecord(
            id: url.lastPathComponent,
            archiveURL: url,
            metadata: metadata,
            archiveFileName: url.lastPathComponent,
            archiveBytes: bytes,
            modified: modified
        )
    }

    func delete(record: BackupRecord) throws {
        try FileManager.default.removeItem(at: record.archiveURL)
    }
}

private extension BackupRecord {
    static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
