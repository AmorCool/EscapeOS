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

/// 一个**读取失败**的备份归档。
///
/// 读不出的归档**仍然要出现在列表里**（标为「无法读取（原因）」），而不是被静默跳过 ——
/// 跳过会让用户以为备份丢了：把「读不出」当成了「不存在」。
///
/// 它无法归属到具体应用（元数据本身就没读出来），因此只在全局备份列表里标注，
/// 不进「某个应用的备份」列表（凭文件名硬猜属于哪个应用会更误导）。
struct UnreadableBackupRecord: Identifiable, Hashable {
    let id: String
    let archiveURL: URL
    let archiveFileName: String
    let archiveBytes: Int64
    let modified: Date?
    /// 读取失败原因（面向用户展示）。
    let reason: String

    init(archiveURL: URL, reason: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: archiveURL.path)
        self.id = archiveURL.lastPathComponent
        self.archiveURL = archiveURL
        self.archiveFileName = archiveURL.lastPathComponent
        self.archiveBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        self.modified = attrs?[.modificationDate] as? Date
        self.reason = reason
    }
}

/// 备份目录的列举结果：**可正常读取**的归档 + **读取失败**的归档。
///
/// 两者分开保存，是为了让「真的没有备份」（两者皆空）与「有备份但读不出」
/// （`unreadable` 非空）能分辨 —— 这正是本轮一直在清的「没能观察到 ≠ 确定没有」。
struct BackupListing {
    let records: [BackupRecord]
    let unreadable: [UnreadableBackupRecord]

    var isEmpty: Bool { records.isEmpty && unreadable.isEmpty }
    var totalCount: Int { records.count + unreadable.count }
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

    /// 列出全部备份归档。
    ///
    /// **目录本身列举失败会 `throws`** —— 调用方必须显式报错，**不得回空列表**
    /// （回空 = 假空，用户会以为「一个备份都没有」）。
    ///
    /// **单个归档读取失败不 `throws`、也不丢弃**：登记进 `unreadable`，仍出现在列表里
    /// 并标注原因。旧实现 `catch { continue }` 会把读不出的包静默跳过，是本轮要清的缺陷。
    func loadRecords() throws -> BackupListing {
        let dir = try BackupPaths.ensureBackupsDirectory()
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.lowercased().hasSuffix(".zip") }
            .sorted(by: >)

        var records: [BackupRecord] = []
        var unreadable: [UnreadableBackupRecord] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            do {
                records.append(try loadRecord(at: url))
            } catch {
                // 读不出**不得**表现为「不存在」：仍登记，标为「无法读取（原因）」。
                unreadable.append(UnreadableBackupRecord(archiveURL: url,
                                                         reason: Self.describe(error)))
            }
        }
        records.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        unreadable.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return BackupListing(records: records, unreadable: unreadable)
    }

    /// 列出某个应用的备份。
    ///
    /// 逐应用视图只能归属到「元数据可读」的归档；读不出的归档无法判断属于哪个应用，
    /// 因此 `records` 只含本应用的、`unreadable` 原样带上全局的读失败项，
    /// 供界面提示「另有 N 个归档无法读取」——不能凭文件名硬猜归属。
    func loadRecords(forBundleIdentifier bundleId: String) throws -> BackupListing {
        let all = try loadRecords()
        let mine = all.records.filter { $0.metadata.bundleIdentifier == bundleId }
        return BackupListing(records: mine, unreadable: all.unreadable)
    }

    /// 把抛出的错误转成面向用户的简短原因。
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func loadRecord(at url: URL) throws -> BackupRecord {
        // The reader keeps a file handle open (it reads the archive on demand
        // instead of loading it into memory), so release it as soon as the
        // metadata has been decoded. `loadRecords()` calls this once per
        // archive; leaking handles there used to mean holding every backup's
        // bytes in RAM at the same time.
        let reader = try ZipReader(url: url)
        defer { reader.close() }
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
