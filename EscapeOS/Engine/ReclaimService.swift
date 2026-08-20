import Foundation

enum ReclaimRisk: String, Hashable {
    case safe
    case session
    case kept
}

struct ReclaimCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let relativePath: String
    let risk: ReclaimRisk
}

struct ReclaimBucketStat: Identifiable, Hashable {
    var id: String { category.id }
    let category: ReclaimCategory
    let files: Int
    let directories: Int
    let bytes: Int64
    let available: Bool

    var summary: String {
        guard available else { return "未找到" }
        if files == 0 && bytes == 0 { return "为空" }
        return "\(files) 个文件 · \(ReclaimService.formatBytes(bytes))"
    }
}

struct ReclaimResult {
    let bytesFreed: Int64
    let filesRemoved: Int
    let skipped: Int
}

enum ReclaimError: Error, LocalizedError {
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .nothingSelected:
            return "未选择任何要回收的内容。"
        }
    }
}

/// Safe-folder measurements from the Reclaim tab, reused when opening an app.
final class ReclaimScanCache {
    static let shared = ReclaimScanCache()
    private let lock = NSLock()
    private var map: [String: [ReclaimBucketStat]] = [:]

    func buckets(for bundleId: String) -> [ReclaimBucketStat]? {
        lock.lock()
        defer { lock.unlock() }
        return map[bundleId]
    }

    func merge(_ buckets: [ReclaimBucketStat], for bundleId: String) {
        lock.lock()
        var current = map[bundleId] ?? []
        for bucket in buckets {
            if let i = current.firstIndex(where: { $0.id == bucket.id }) {
                current[i] = bucket
            } else {
                current.append(bucket)
            }
        }
        map[bundleId] = current
        lock.unlock()
    }

    func remove(_ bundleId: String) {
        lock.lock()
        map.removeValue(forKey: bundleId)
        lock.unlock()
    }
}

/// Classified cache/tmp reclaim inside one app Data container. Reclaim never
/// deletes Documents, Preferences, or Application Support. Reset App Data does
/// empty Documents, Library, and tmp. Neither touches Keychain or App Groups.
final class ReclaimService {

    static let categories: [ReclaimCategory] = [
        ReclaimCategory(
            id: "tmp",
            title: "临时文件",
            detail: "tmp — 应用的临时文件，可由应用自行重建",
            relativePath: "tmp",
            risk: .safe
        ),
        ReclaimCategory(
            id: "caches",
            title: "缓存",
            detail: "Library/Caches — 图片、WebKit 磁盘缓存、Metal 缓存",
            relativePath: "Library/Caches",
            risk: .safe
        ),
        ReclaimCategory(
            id: "logs",
            title: "日志",
            detail: "Library/Logs",
            relativePath: "Library/Logs",
            risk: .safe
        ),
        ReclaimCategory(
            id: "splash",
            title: "启动快照",
            detail: "Library/SplashBoard",
            relativePath: "Library/SplashBoard",
            risk: .safe
        ),
        ReclaimCategory(
            id: "gpucache",
            title: "GPU 缓存",
            detail: "Library/GPUCache",
            relativePath: "Library/GPUCache",
            risk: .safe
        ),
        ReclaimCategory(
            id: "cookies",
            title: "Cookies",
            detail: "Library/Cookies — 可能导致应用内网页登录态失效",
            relativePath: "Library/Cookies",
            risk: .session
        ),
        ReclaimCategory(
            id: "http",
            title: "HTTP 存储",
            detail: "Library/HTTPStorages — URL Session 缓存与 Cookie",
            relativePath: "Library/HTTPStorages",
            risk: .session
        ),
        ReclaimCategory(
            id: "webkit",
            title: "WebKit 数据",
            detail: "Library/WebKit — 应用内浏览器站点数据",
            relativePath: "Library/WebKit",
            risk: .session
        ),
        ReclaimCategory(
            id: "savedstate",
            title: "应用状态存档",
            detail: "Library/Saved Application State",
            relativePath: "Library/Saved Application State",
            risk: .session
        ),
        ReclaimCategory(
            id: "documents",
            title: "Documents",
            detail: "用户文件 — 自动回收时不会触碰",
            relativePath: "Documents",
            risk: .kept
        ),
        ReclaimCategory(
            id: "preferences",
            title: "Preferences",
            detail: "Library/Preferences — 设置与登录 token",
            relativePath: "Library/Preferences",
            risk: .kept
        ),
        ReclaimCategory(
            id: "appsupport",
            title: "Application Support",
            detail: "Library/Application Support — 数据库与存档",
            relativePath: "Library/Application Support",
            risk: .kept
        )
    ]

    static var safeCategories: [ReclaimCategory] { categories.filter { $0.risk == .safe } }
    static var sessionCategories: [ReclaimCategory] { categories.filter { $0.risk == .session } }
    static var keptCategories: [ReclaimCategory] { categories.filter { $0.risk == .kept } }

    private let escape = SandboxEscape()
    private let files = FileService()
    private let maxNodes = 20_000

    func scan(app: InstalledApp) throws -> [ReclaimBucketStat] {
        try scan(app: app, risks: [.safe, .session, .kept])
    }

    /// Tab ranking only needs Safe folders. Skipping Documents/Preferences is much faster.
    func scan(app: InstalledApp, risks: Set<ReclaimRisk>) throws -> [ReclaimBucketStat] {
        let wanted = Self.categories.filter { risks.contains($0.risk) }
        return try escape.withHandle(for: app.containerPath) { _ in
            wanted.map { category in
                stat(category: category, container: app.containerPath)
            }
        }
    }

    func reclaim(
        app: InstalledApp,
        categories: [ReclaimCategory],
        progress: ((String) -> Void)? = nil
    ) throws -> ReclaimResult {
        let work = categories.filter { $0.risk != .kept }
        guard !work.isEmpty else { throw ReclaimError.nothingSelected }

        var filesRemoved = 0
        var bytesFreed: Int64 = 0
        var skipped = 0

        try escape.withHandle(for: app.containerPath) { _ in
            for category in work {
                let path = try resolve(category.relativePath, under: app.containerPath)
                let before = stat(category: category, container: app.containerPath)
                progress?("Reclaiming…")
                if self.files.isDirectory(at: path) {
                    skipped += self.files.emptyDirectoryContentsBestEffort(at: path)
                    try? self.files.createDirectory(at: path)
                }
                let after = stat(category: category, container: app.containerPath)
                if before.available {
                    let afterBytes = after.available ? after.bytes : 0
                    let afterFiles = after.available ? after.files : 0
                    bytesFreed += max(0, before.bytes - afterBytes)
                    filesRemoved += max(0, before.files - afterFiles)
                }
            }
        }

        return ReclaimResult(bytesFreed: bytesFreed, filesRemoved: filesRemoved, skipped: skipped)
    }

    /// Wipe Documents, Library, and tmp. Does not touch Keychain or App Groups.
    /// Locked files are skipped instead of failing the whole reset.
    @discardableResult
    func resetAppData(app: InstalledApp) throws -> Int {
        var skipped = 0
        try escape.withHandle(for: app.containerPath) { _ in
            for root in BackupService.backupRoots {
                let path = try resolve(root, under: app.containerPath)
                if files.isDirectory(at: path) {
                    skipped += files.emptyDirectoryContentsBestEffort(at: path)
                    try? files.createDirectory(at: path)
                } else {
                    try files.createDirectory(at: path)
                }
            }
        }
        ReclaimScanCache.shared.remove(app.bundleIdentifier)
        return skipped
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private func stat(category: ReclaimCategory, container: String) -> ReclaimBucketStat {
        do {
            let path = try resolve(category.relativePath, under: container)
            guard files.isDirectory(at: path) else {
                return ReclaimBucketStat(category: category, files: 0, directories: 0, bytes: 0, available: false)
            }
            let counted = try files.countTree(at: path, maxNodes: maxNodes)
            return ReclaimBucketStat(
                category: category,
                files: counted.files,
                directories: counted.directories,
                bytes: counted.bytes,
                available: true
            )
        } catch {
            return ReclaimBucketStat(category: category, files: 0, directories: 0, bytes: 0, available: false)
        }
    }

    private func resolve(_ relative: String, under container: String) throws -> String {
        let resolved = try ArchiveEntryPath.resolve(relative, under: container)
        return resolved.path
    }
}
