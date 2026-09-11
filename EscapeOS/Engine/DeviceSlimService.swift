import Foundation

/// 设备瘦身 —— 爱思助手 8.0「设备瘦身」功能移植（主页板块）.
///
/// ## 口径来源（逆向 `C:\Program Files\i4Tools8`，2026-09-11）
/// · **空间占用 7 项** = `idm_info.dll` 的 `ios_get_detailed_disk_usage` →
///   lockdown 域 `com.apple.disk_usage`（系统 = `TotalSystemCapacity`、
///   总量 = `TotalDiskCapacity`、剩余 = `AmountRestoreAvailable` 类），
///   再叠加「应用」（instproxy `StaticDiskUsage` 求和）/「照片」/「音视频」/「U盘」。
///   真机校验：系统 7.85 GB、应用 23.98~24 GB 与爱思面板一致；「其他」为余量口径。
/// · **清理分组** = 系统缓存文件 / 用户日志 / 其他临时文件 / 较大应用（> 500 MB）。
/// · **较大应用**（爱思真机截图）：表格「应用名称 / 应用大小 / 文档大小 / 操作」，
///   勾选 = 重装（清掉文稿与数据）；`(资源缺失无法重装)` = 本地没有可重装的包。
///   设备侧旁证 `/iTunes_Control/iTunes/stopremovewhitelist.acc` 的
///   `bundleIds = [com.ownbook.notes, rn.notes.best]` 说明它会重装第三方 App 但放行自家移动端。
///
/// ## 性能（v0.3.314 重写）
/// 之前一次进入要遍历媒体分区 **三遍**（空间占用 + 缓存项 + 日志），而 AFC 的
/// `listDirectory` 对每个条目都要单独 `afc_get_file_info`（≈2 万次往返）→ 慢。
/// 现改为**单次遍历**同时算出全部所需数值，并把结果**落盘缓存**（含时间戳），
/// 再次进入秒开；只有点「重新扫描」才真正重走。
///
/// ## 可达面（免越狱，iOS 27 实测）
/// AFC 根 = `/var/mobile/Media`；`house_arrest` 的 `VendContainer` 在 iOS 27 被拒、
/// `VendDocuments` 只到各 App 的 `Documents`；`/var/mobile/Library/Logs` 不可达。
/// → 只清理媒体分区内**可再生**的缓存/缩略图，白名单之外一律不碰。
enum DeviceSlimService {

    // MARK: - 空间占用

    struct UsageSlice: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let colorHex: UInt32
    }

    struct SpaceUsage {
        var total: Int64 = 0
        var free: Int64 = 0
        var deviceName: String = ""
        var capacityText: String = ""
        var slices: [UsageSlice] = []
        var scannedAt: Date?

        var used: Int64 { max(0, total - free) }
    }

    // MARK: - 可清理项

    enum GroupKind: String, CaseIterable, Identifiable {
        case systemCache = "系统缓存文件"
        case userLog = "用户日志"
        case tempFiles = "其他临时文件"
        case bigApps = "较大应用"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .systemCache, .tempFiles: return "删除冗余的系统、用户"
            case .userLog: return "日志文件及过期的临时文件"
            case .bigApps: return "通过批量重装应用"
            }
        }

        /// 「较大应用」用重装（不是勾选删除），所以不走「可释放空间」统计
        var selectable: Bool { self != .bigApps }

        var icon: String {
            switch self {
            case .systemCache: return "internaldrive.fill"
            case .userLog: return "doc.text.fill"
            case .tempFiles: return "clock.arrow.circlepath"
            case .bigApps: return "app.badge.fill"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String          // 缓存项 = 设备路径；较大应用 = bundleId
        let name: String
        let detail: String?
        let bytes: Int64        // 缓存项 = 占用；较大应用 = 合计（应用+文档）
        let kind: GroupKind
        let deletable: Bool
        // 较大应用专用
        var appSize: Int64 = 0
        var docSize: Int64 = 0
        var version: String = ""
        var ipaFileName: String?   // 免登录下载库里匹配到的重装包（nil = 资源缺失）
        var isRisky: Bool = false  // 聊天类：重装会丢聊天记录
    }

    struct Group: Identifiable {
        let kind: GroupKind
        let items: [Item]
        var id: String { kind.rawValue }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    struct CleanResult {
        var freed: Int64 = 0
        var deleted: Int = 0
        var failures: [String] = []
    }

    struct ReinstallResult {
        var ok: [String] = []
        var failures: [String] = []
    }

    // MARK: - 白名单与常量

    static let pathPhotoThumbnails = "/PhotoData/Thumbnails"
    static let pathPhotoCaches = "/PhotoData/Caches"
    static let pathSharedAlbumCaches = "/PhotoData/PhotoCloudSharingData/Caches"

    static var systemCachePaths: [(String, String)] {
        [(pathPhotoThumbnails, "照片缩略图（系统按需重建）"),
         (pathPhotoCaches, "照片库缓存"),
         (pathSharedAlbumCaches, "共享相簿媒体缓存")]
    }

    static let tempPaths: [(String, String)] = [
        ("/Deferred", "系统延迟处理暂存"),
        ("/Sync", "同步中转暂存"),
        ("/PublicStaging", "公共暂存区"),
        ("/Airlock", "空投/隔空投送暂存"),
    ]

    static let bigAppThreshold: Int64 = 500 * 1024 * 1024

    /// 重装会丢聊天记录的 App（爱思标注「谨慎选择」）
    static let riskyBundleIds: Set<String> = [
        "com.tencent.xin", "com.tencent.mqq", "com.tencent.tim", "com.tencent.ww",
    ]

    static let photoDirs = ["/DCIM", "/PhotoData"]
    static let mediaDirs = ["/Music", "/Radio", "/Recordings"]
    static let usbDir = "/虚拟U盘"

    private static let logPattern = ["log", "ips", "crash", "diag", "panic"]

    /// 需要单独统计的子路径（缓存项 / 临时项）
    private static var watchedSubpaths: [String] {
        systemCachePaths.map(\.0) + tempPaths.map(\.0)
    }

    // MARK: - 格式化（对齐爱思：二进制单位、两位小数）

    static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.2f KB", b / kb) }
        return String(format: "%.2f B", b)
    }

    // MARK: - 快照（单次遍历 + 落盘缓存）

    struct Snapshot: Codable {
        var totals: [String: Int64] = [:]     // 路径 → 字节
        var fileCounts: [String: Int] = [:]
        var logs: [LogHit] = []
        var takenAt: Date = .distantPast
    }

    struct LogHit: Codable { var path: String; var bytes: Int64 }

    private static var snapshotURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/device_slim_snapshot.json")
    }

    /// 读缓存快照；`maxAge` 秒内视为新鲜（默认 10 分钟）
    static func cachedSnapshot(maxAge: TimeInterval = 600) -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else { return nil }
        guard Date().timeIntervalSince(snap.takenAt) <= maxAge else { return nil }
        return snap
    }

    /// **单次遍历**媒体分区：同时算出空间占用各分区、缓存项、临时项、日志项.
    static func buildSnapshot(progress: ((String) -> Void)? = nil) throws -> Snapshot {
        var snap = Snapshot()
        let watched = watchedSubpaths
        let firstLevels = Set(photoDirs + mediaDirs + [usbDir])
        var logs: [LogHit] = []
        var budget = 0

        progress?("正在扫描设备文件…")
        try AFCService.shared.batch { client in
            // 迭代式 DFS（显式栈，避免深递归）
            var stack: [(path: String, depth: Int)] = [("/", 0)]
            while let node = stack.popLast() {
                guard let entries = try? AFCService.listDirectory(client: client, path: node.path) else { continue }
                budget += entries.count
                for entry in entries {
                    let p = entry.path
                    if entry.isDirectory {
                        // 目录自身不累加；继续下探（全部下探——数值要准）
                        stack.append((p, node.depth + 1))
                        continue
                    }
                    let size = entry.size
                    snap.fileCounts["/*"] = (snap.fileCounts["/*"] ?? 0) + 1
                    // 一级目录
                    let comps = p.split(separator: "/", omittingEmptySubsequences: true)
                    if let first = comps.first {
                        let key = "/" + first
                        snap.totals[key] = (snap.totals[key] ?? 0) + size
                        if firstLevels.contains(key) {
                            snap.fileCounts[key] = (snap.fileCounts[key] ?? 0) + 1
                        }
                    }
                    // 关注的子路径（缓存/临时）
                    for w in watched where p.hasPrefix(w + "/") {
                        snap.totals[w] = (snap.totals[w] ?? 0) + size
                        snap.fileCounts[w] = (snap.fileCounts[w] ?? 0) + 1
                    }
                    // 日志类文件（只扫非照片内容区，控量）
                    if logs.count < 60, budget < 60000,
                       !p.hasPrefix("/DCIM/"), !p.hasPrefix("/PhotoData/") {
                        let lower = entry.name.lowercased()
                        if logPattern.contains(where: { lower.contains($0) }) {
                            logs.append(LogHit(path: p, bytes: size))
                        }
                    }
                }
            }
        }
        logs.sort { $0.bytes > $1.bytes }
        snap.logs = Array(logs.prefix(40))
        snap.takenAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snap) {
            try? data.write(to: snapshotURL)
        }
        return snap
    }

    // MARK: - 空间占用

    static func loadUsage(snapshot: Snapshot? = nil,
                          progress: ((String) -> Void)? = nil) throws -> SpaceUsage {
        var usage = SpaceUsage()
        let snap = try snapshot ?? buildSnapshot(progress: progress)

        let du = (try? DeviceInfoService.lockdownDomainDict("com.apple.disk_usage")) ?? [:]
        func num(_ key: String) -> Int64? {
            if let n = du[key] as? Int { return Int64(n) }
            if let n = du[key] as? NSNumber { return n.int64Value }
            return nil
        }
        usage.total = num("TotalDiskCapacity") ?? num("TotalDataCapacity") ?? 0
        let system = num("TotalSystemCapacity") ?? 0
        usage.free = num("AmountRestoreAvailable") ?? num("AmountDataAvailable") ?? num("TotalDataAvailable") ?? 0

        var apps: Int64 = 0
        let appList = (try? FileSharingService.listAppsWithFileSharing()) ?? []
        for app in appList where app.applicationType != "System" {
            apps += app.appSize ?? 0
        }

        let photos = photoDirs.reduce(Int64(0)) { $0 + (snap.totals[$1] ?? 0) }
        let media = mediaDirs.reduce(Int64(0)) { $0 + (snap.totals[$1] ?? 0) }
        let usb = snap.totals[usbDir] ?? 0
        let other = max(0, usage.total - system - apps - photos - media - usb - usage.free)

        usage.slices = [
            UsageSlice(id: "system", label: "系统", bytes: system, colorHex: 0x2F80ED),
            UsageSlice(id: "apps", label: "应用", bytes: apps, colorHex: 0x2D9CDB),
            UsageSlice(id: "photos", label: "照片", bytes: photos, colorHex: 0x9B51E0),
            UsageSlice(id: "media", label: "音视频", bytes: media, colorHex: 0xF2C94C),
            UsageSlice(id: "usb", label: "U盘", bytes: usb, colorHex: 0x27AE60),
            UsageSlice(id: "other", label: "其他", bytes: other, colorHex: 0xF2994A),
            UsageSlice(id: "free", label: "剩余", bytes: usage.free, colorHex: 0xBDBDBD),
        ]
        usage.scannedAt = snap.takenAt

        let machine = sysctlString("hw.machine") ?? "iPhone"
        usage.deviceName = DeviceCatalog.name(machine)
        usage.capacityText = "\(decimalCapacity(usage.total)) · \(usage.deviceName)"
        return usage
    }

    private static func decimalCapacity(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1_000_000_000
        if let standard = [16.0, 32, 64, 128, 256, 512, 1024, 2048].first(where: { gb <= $0 * 1.02 }) {
            return "\(Int(standard))GB"
        }
        return String(format: "%.0fGB", gb)
    }

    // MARK: - 扫描（复用同一快照）

    static func scan(snapshot: Snapshot? = nil,
                     progress: ((String) -> Void)? = nil) throws -> [Group] {
        let snap = try snapshot ?? buildSnapshot(progress: progress)
        var groups: [Group] = []

        var systemItems: [Item] = []
        for (path, why) in systemCachePaths {
            let bytes = snap.totals[path] ?? 0
            guard bytes > 0 else { continue }
            systemItems.append(Item(id: path, name: itemName(path),
                                    detail: "\(why) · \(snap.fileCounts[path] ?? 0) 个文件",
                                    bytes: bytes, kind: .systemCache, deletable: true))
        }
        groups.append(Group(kind: .systemCache, items: systemItems))

        let logItems = snap.logs.map {
            Item(id: $0.path, name: itemName($0.path), detail: "日志文件",
                 bytes: $0.bytes, kind: .userLog, deletable: true)
        }
        groups.append(Group(kind: .userLog, items: logItems))

        var tempItems: [Item] = []
        for (path, why) in tempPaths {
            let bytes = snap.totals[path] ?? 0
            guard bytes > 0 else { continue }
            tempItems.append(Item(id: path, name: itemName(path),
                                  detail: "\(why) · \(snap.fileCounts[path] ?? 0) 个文件",
                                  bytes: bytes, kind: .tempFiles, deletable: true))
        }
        groups.append(Group(kind: .tempFiles, items: tempItems))

        groups.append(Group(kind: .bigApps, items: bigApps()))
        return groups
    }

    /// 较大应用（> 500 MB）：连同「免登录下载库里有没有可重装的包」一起算.
    static func bigApps() -> [Item] {
        let library = IPADownloadLibrary.shared.items()
        var byBundle: [String: IPADownloadItem] = [:]
        for item in library {
            guard let bid = item.bundleId, !bid.isEmpty else { continue }
            // 同一 bundleId 有多份包时取**最新**的那份
            if let old = byBundle[bid], old.downloadedAt >= item.downloadedAt { continue }
            byBundle[bid] = item
        }

        var out: [Item] = []
        for app in (try? FileSharingService.listAppsWithFileSharing()) ?? [] {
            guard app.applicationType != "System" else { continue }
            let appSize = app.appSize ?? 0
            let docSize = app.docSize ?? 0
            let total = appSize + docSize
            guard total > bigAppThreshold else { continue }
            out.append(Item(id: app.bundleId, name: app.name,
                            detail: nil, bytes: total, kind: .bigApps, deletable: false,
                            appSize: appSize, docSize: docSize, version: app.version,
                            ipaFileName: byBundle[app.bundleId]?.fileName,
                            isRisky: riskyBundleIds.contains(app.bundleId)))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    private static func itemName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    // MARK: - 清理（缓存项）

    static func clean(items: [Item],
                      progress: ((Int, Int) -> Void)? = nil) throws -> CleanResult {
        var result = CleanResult()
        let targets = items.filter { $0.deletable && $0.kind != .bigApps }
        guard !targets.isEmpty else { return result }

        try AFCService.shared.batch { client in
            for (index, item) in targets.enumerated() {
                progress?(index + 1, targets.count)
                let before = measure(client: client, path: item.id).bytes
                if let ffiError = item.id.withCString({ afc_remove_path_and_contents(client, $0) }) {
                    let message = ffiError.pointee.message.map { String(cString: $0) } ?? "rc=\(ffiError.pointee.code)"
                    idevice_error_free(ffiError)
                    result.failures.append("\(item.name)：\(message)")
                    continue
                }
                let after = measure(client: client, path: item.id).bytes
                result.freed += max(0, before - after)
                result.deleted += 1
            }
        }
        // 数值已变，作废缓存
        try? FileManager.default.removeItem(at: snapshotURL)
        return result
    }

    // MARK: - 重装（较大应用）

    /// 卸载 + 用免登录下载库里的 IPA 重装（**会清掉该 App 的文稿与数据**）.
    static func reinstall(items: [Item],
                          progress: ((Int, Int, String) -> Void)? = nil) async -> ReinstallResult {
        var result = ReinstallResult()
        let targets = items.filter { $0.kind == .bigApps && $0.ipaFileName != nil }
        for (index, item) in targets.enumerated() {
            progress?(index + 1, targets.count, item.name)
            guard let fileName = item.ipaFileName else { continue }
            let ipaPath = IPADownloadLibrary.shared.path(forFileName: fileName)
            guard FileManager.default.fileExists(atPath: ipaPath) else {
                result.failures.append("\(item.name)：重装包不在本地（\(fileName)）")
                continue
            }
            do {
                try UninstallService.shared.uninstall(bundleId: item.id)
                try await AppStoreInstallService.installLocalIPA(ipaPath, progress: { _ in })
                IPADownloadLibrary.shared.markInstalled(fileName: fileName)
                result.ok.append(item.name)
            } catch {
                result.failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: snapshotURL)
        return result
    }

    // MARK: - 辅助

    static func measure(client: OpaquePointer, path: String) -> (bytes: Int64, files: Int) {
        var info = AfcFileInfo()
        let rc = path.withCString { afc_get_file_info(client, $0, &info) }
        guard rc == nil else { return (0, 0) }
        defer { afc_file_info_free(&info) }
        let isDir = info.st_ifmt.map { String(cString: $0) == "S_IFDIR" } ?? false
        if !isDir { return (Int64(info.size), 1) }

        var bytes: Int64 = 0
        var files = 0
        var stack = [path]
        while let current = stack.popLast() {
            guard let entries = try? AFCService.listDirectory(client: client, path: current) else { continue }
            for entry in entries {
                if entry.isDirectory { stack.append(entry.path) }
                else { bytes += entry.size; files += 1 }
            }
        }
        return (bytes, files)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
