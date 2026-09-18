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
        var ipaFileName: String?   // 免登录下载库里已有的包（nil = 本地没有）
        /// 免登录源里能不能下到（nil = 还没探测）—— 恢复爱思的「资源缺失无法重装」判定
        var sourceAvailable: Bool? = nil
        var isRisky: Bool = false  // 聊天类：重装会丢聊天记录
    }

    struct Group: Identifiable {
        let kind: GroupKind
        var items: [Item]
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

    /// 重装阶段（进度条文案）
    enum ReinstallStage: String {
        case locating = "查找安装包"
        case downloading = "下载中"
        case installing = "安装中"
    }

    /// 重装进度（index 从 1 开始）
    struct ReinstallProgress {
        let index: Int
        let total: Int
        let name: String
        let stage: ReinstallStage
        let fraction: Double    // 当前这一个的整体进度 0~1
    }

    // MARK: - 白名单与常量

    static let pathPhotoThumbnails = "/PhotoData/Thumbnails"
    static let pathPhotoCaches = "/PhotoData/Caches"
    static let pathSharedAlbumCaches = "/PhotoData/PhotoCloudSharingData/Caches"

    /// 系统缓存文件 = 可再生缓存目录。
    /// `/Downloads` 是 Safari 的下载记录数据库（`downloads.28.sqlitedb` + `-wal`/`-shm`），
    /// 体积随 WAL 波动（实测 369.25 KiB，爱思面板曾显示 361.20 KB）——爱思的清理项里也有它。
    static var systemCachePaths: [(String, String)] {
        [(pathPhotoThumbnails, "照片缩略图"),
         (pathPhotoCaches, "照片库缓存"),
         (pathSharedAlbumCaches, "共享相簿缓存"),
         ("/Downloads", "下载记录缓存")]
    }

    static let tempPaths: [(String, String)] = [
        ("/Deferred", "延迟处理暂存"),
        ("/Sync", "同步中转暂存"),
        ("/PublicStaging", "公共暂存区"),
        ("/Airlock", "隔空投送暂存"),
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

    // MARK: - 应用列表读取（快路径 + 可选大小增强）

    /// 一次应用读取的结果.
    struct AppReadResult {
        var apps: [FileSharingApp] = []
        /// 快路径（`get_apps`）是否拿到数据 —— false = 真拿不到，页面应显示错误态 + 重试
        var usable = false
        /// **是否真的拿到了可用的大小**（v0.3.401 起不再看「增强回填了几条」）——
        /// false = 没有精确大小，只能按可得信息出数据（「应用」分片会偏小、
        /// 「较大应用」判不出「> 500MB」），页面据此提示「应用大小不可用」.
        /// 背景：带属性 Lookup 已把大小字段移出请求（为解决它卡 ~25 秒的回归），
        /// 而 iOS 侧**没有 AFC 等价通道**能补应用大小（house_arrest 只到数据容器）.
        var sizeComplete = false
    }

    /// v0.3.378：设备瘦身页读取已装应用（空间占用的「应用」分片 / 「较大应用」分组）.
    ///
    /// 改成「快路径 + 可选增强」（真机 16:30 日志的教训：原先直接等带属性 Lookup →
    /// 每轮都「应用列表读取超时，本轮按空处理」→「应用」分片恒 0、「较大应用」恒空，
    /// 用户看到的是「功能坏了」）：
    ///   1. **快路径 `get_apps`**（真机 333 应用 2.5 秒级）→ 保证一定有应用列表；
    ///   2. **可选增强**（带属性 Lookup，独立 15 秒；v0.3.379 由 8 秒提到 15——后台可选、
    ///      不阻塞首屏，且单飞保证同一时刻只有一条在飞）→ 补 appSize/docSize，
    ///      「应用」分片与「较大应用」才有意义；失败就退化为「没有精确大小」；
    ///   3. **结果缓存 30 秒**：`loadUsage` 与 `bigApps` 在同一轮页面加载里共用一份，
    ///      不再重复开隧道；
    ///   4. 只有**快路径也失败**时才回空数组，并置问题文案 → 页面显示
    ///      「应用读取超时」+ 重试，**不显示成静默空列表**.
    /// 注意：大小的可得性分两种（v0.3.406 起）——
    ///   - **应用大小** `appSize`：只能来自第 2 步的带属性 Lookup（`StaticDiskUsage`，
    ///     v0.3.406 加回请求；`get_apps` 从来不带）。取不到时「应用」分片与「较大应用」
    ///     会退化，页面必须明确提示「应用大小不可用」（判据见 sizeComplete）.
    ///   - **文档大小** `docSize`（`DynamicDiskUsage`）：**不再从请求里拿**（疑为「带属性 Lookup
    ///     卡 ~25 秒」的元凶，见 FileSharingService / installation_proxy.rs 注释）——
    ///     v0.3.408 起改走**本机通道**按需量：`containerPath`（`get_apps` 默认响应自带）
    ///     + `SandboxEscape` + `FileService.countTree`，与「空间回收」页同一套，
    ///     每轮后台补一批、跨轮累积。落地与代价见 `startDocSizePass`.
    private static func readAppsForSlim() -> AppReadResult {
        appReadLock.lock()
        if let cache = appReadCache, Date().timeIntervalSince(cache.at) < 30 {
            let cached = cache.result
            appReadLock.unlock()
            return cached
        }
        appReadLock.unlock()

        var result = AppReadResult()
        // ① 快路径：get_apps
        switch FileSharingService.listAppsWithFileSharing(timeout: 20) {
        case .ok(let found):
            result.apps = found
            result.usable = !found.isEmpty
            LoginLogger.shared.log("[设备瘦身] get_apps 快路径：\(found.count) 条")
        case .failed(let message):
            LoginLogger.shared.log("[设备瘦身] get_apps 快路径失败：\(message)")
        case .timedOut:
            LoginLogger.shared.log("[设备瘦身] get_apps 快路径超时（排队与执行分开计）")
        }
        // ①' v0.3.408：拿到列表就**立刻**发起「文档大小」（本机通道）——它要真的把每个应用
        //     的容器文件树走一遍，所以放在这里与后面（最长 15 秒的带属性 Lookup + 空间快照）
        //     **重叠**，不额外占首屏时间；`bigApps()` 取到什么算什么，见 `startDocSizePass`.
        startDocSizePass(result.apps)
        // ② 可选增强：带属性 Lookup（独立 15 秒、失败就不补；额度见 lookupAppAttributes 默认参数）
        let enhanced = FileSharingService.lookupAppAttributes()
        if enhanced.isEmpty {
            LoginLogger.shared.log("[设备瘦身] 大小增强未取到：本轮没有精确大小（「应用」分片偏小、「较大应用」判不出）")
        } else {
            let byId = Dictionary(enhanced.map { ($0.bundleId, $0) }, uniquingKeysWith: { first, _ in first })
            var patched = 0
            for index in result.apps.indices {
                guard let e = byId[result.apps[index].bundleId] else { continue }
                if result.apps[index].appSize == nil { result.apps[index].appSize = e.appSize }
                if result.apps[index].docSize == nil { result.apps[index].docSize = e.docSize }
                if result.apps[index].appleId == nil { result.apps[index].appleId = e.appleId }
                patched += 1
            }
            // v0.3.401（补修）：`sizeComplete` 改成按「**是否真的拿到大小**」判定.
            // 原来按「回填了几条」（`patched > 0`）判定 —— 只要带属性增强返回了列表就算
            // 成功；而本版已把 StaticDiskUsage / DynamicDiskUsage 移出请求（为解决
            // 「带属性 Lookup 卡 ~25 秒」），于是 `patched` 仍 > 0 但 appSize 全为 nil：
            // 页面不给「应用大小不可用」，而 bigApps 的 `total > threshold` 会把全部
            // 应用跳过（`appSize/docSize` 都是 0）→ 「应用」分片 /「较大应用」**静默为空**.
            // 现在要求「至少有一个应用真的带上了 appSize」，否则如实报「大小不可用」.
            // 注：iOS 侧**没有 AFC 等价通道**能补应用大小（house_arrest 只到数据容器），
            // 所以去掉这两个字段就等于「应用大小整体不可用」，必须让页面说清楚.
            let sizedApps = result.apps.filter { $0.appSize != nil }.count
            let sizedDocs = result.apps.filter { $0.docSize != nil }.count
            result.sizeComplete = sizedApps > 0
            LoginLogger.shared.log(
                "[设备瘦身] 大小增强回填 \(patched) 条，其中真的带 appSize \(sizedApps) 条"
                + " / 带 docSize \(sizedDocs) 条（sizeComplete=\(result.sizeComplete)）"
            )
            // v0.3.408：**没有 appSize 的那批到底是什么**（真机：334 条里只有 125 条有大小）——
            // 一次真机日志即可判定要不要管：`ApplicationType=System/HiddenSystemApp` 的应用
            // 本来就被 `bigApps()` 排除，若这批几乎全是系统应用，「125/334」就不再是缺陷。
            // 只有「三方 + 有安装路径」那部分才是「较大应用」漏判的真实来源。
            let missing = result.apps.filter { $0.appSize == nil }
            let missingSystem = missing.filter { isSystemApp($0) }.count
            let missingNoPath = missing.filter { ($0.path ?? "").isEmpty }.count
            LoginLogger.shared.log(
                "[设备瘦身] 无 appSize 的 \(missing.count) 条中：系统应用 \(missingSystem) 条"
                + " / 三方 \(missing.count - missingSystem) 条 / 无安装路径 \(missingNoPath) 条"
            )
        }

        appReadLock.lock()
        if !result.usable {
            appReadIssueFlag = "应用读取超时"
        } else if !result.sizeComplete {
            appReadIssueFlag = "应用大小不可用"
        } else {
            appReadIssueFlag = nil
        }
        appReadCache = (result, Date())
        let issue = appReadIssueFlag
        appReadLock.unlock()
        if let issue { LoginLogger.shared.log("[设备瘦身] 本轮问题：\(issue)（已在页面提示 + 提供重试）") }
        return result
    }

    private static let appReadLock = NSLock()
    /// Swift 6 并发检查：`appReadCache` / `appReadIssueFlag` 的**全部**读写都在上面的
    /// `appReadLock` 内（见 `readAppsForSlim` / `consumeAppReadIssue` / `invalidateAppReadCache`），
    /// 因此这两个静态变量本身线程安全。
    nonisolated(unsafe) private static var appReadCache: (result: AppReadResult, at: Date)?
    /// 本轮需要向用户说明的问题（nil = 一切正常）——页面取走后清零，避免跨轮残留.
    nonisolated(unsafe) private static var appReadIssueFlag: String?

    /// 取走并清零本轮的问题文案（页面在数据落地后调用一次）.
    static func consumeAppReadIssue() -> String? {
        appReadLock.lock(); defer { appReadLock.unlock() }
        let value = appReadIssueFlag
        appReadIssueFlag = nil
        return value
    }

    /// 用户点「重试」时先丢掉缓存，否则 30 秒内会直接拿到上一次的失败结果.
    static func invalidateAppReadCache() {
        appReadLock.lock(); defer { appReadLock.unlock() }
        appReadCache = nil
        appReadIssueFlag = nil
    }

    // MARK: - v0.3.408：文档大小的本机通道

    private static let docSizeLock = NSLock()
    /// Swift 6 并发检查：`docSizeCache` / `docSizeInFlight` 的**全部**读写都在上面的
    /// `docSizeLock` 内（见 `cachedDocSize` / `startDocSizePass` 的量取任务），本身线程安全。
    /// 量过的 `docSize`（bundleId → 字节 + 量到的时刻）。**跨轮保留** ——
    /// 「较大应用」的文档大小因此一轮比一轮全，而不是每轮都从头发一遍.
    nonisolated(unsafe) private static var docSizeCache: [String: (bytes: Int64, at: Date)] = [:]
    /// 正在量的 bundleId（`readAppsForSlim` 缓存刚失效时，两个调用方可能同时发起）.
    nonisolated(unsafe) private static var docSizeInFlight: Set<String> = []

    /// 单轮最多量几个应用；单个应用最多看几个节点（20k 是「空间回收」的口径，这里更保守）.
    private static let docSizePassMaxApps = 60
    private static let docSizeMaxNodesPerApp = 12_000
    /// 量到的值保留 10 分钟：文档会变，但没必要每轮重走一遍文件树.
    private static let docSizeCacheTTL: TimeInterval = 600

    /// 量到过的文档大小（读不到 / 过期 → nil，调用方按 0 处理，与从前一致）.
    static func cachedDocSize(_ bundleId: String) -> Int64? {
        docSizeLock.lock(); defer { docSizeLock.unlock() }
        guard let hit = docSizeCache[bundleId] else { return nil }
        guard Date().timeIntervalSince(hit.at) < docSizeCacheTTL else { return nil }
        return hit.bytes
    }

    /// 系统应用（instproxy `ApplicationType` 口径，与 `InstalledApp.isSystem` 同款）.
    private static func isSystemApp(_ app: FileSharingApp) -> Bool {
        app.applicationType == "System" || app.applicationType == "HiddenSystemApp"
    }

    /// 单轮待量的一个应用。用 struct 而不是元组：`Task.detached` 的闭包要 `@Sendable`，
    /// 具名类型的 Sendable 语义最明确.
    private struct DocSizeTarget: Sendable {
        let bundleId: String
        let path: String
    }

    /// **文档大小（`docSize`）的落地点**（v0.3.408）.
    ///
    /// ## 为什么必须有它
    /// `docSize` 以前恒为 0，因为它的来源字段 `DynamicDiskUsage` **根本不在请求里**
    ///（`FileSharingService.attributeRequestFields` 与 Rust 的 `attrs` 都只有
    /// `StaticDiskUsage`）—— 不是"请求了没人填"，是**从来没请求过**。
    /// 于是「较大应用」的判据 `appSize + docSize` 里那一半恒等于 0：
    /// **App 本体不大、文档却几十 GB 的应用（微信、游戏）永远进不了这个分组**，
    /// 用户看到的就是「没有扫到文档的」。
    ///
    /// ## 为什么不把 `DynamicDiskUsage` 加回请求
    /// 它是「带属性 Lookup 卡 ~25 秒」的头号嫌疑（见 `FileSharingService` 注释），
    /// 为了补一个大小把它引回来不值 —— 那会让整个「应用管理 / 文档浏览 / 设备瘦身」
    /// 一起变慢，代价远大于收益.
    ///
    /// ## 为什么不用 house_arrest + AFC
    /// `house_arrest_vend_documents` **要求应用开启文档共享**（`UIFileSharingEnabled`）——
    /// 用户报的那批应用（微信、游戏）恰恰没开，那条路覆盖不到它们.
    ///（`FileSharingService.computeDocumentsSize` 走的就是那条路，且它的调用点
    /// `FileSharingAppsView.computeDocumentSizes()` 至今是死代码 —— 也正因如此从没生效过.）
    ///
    /// ## 实际通道：本机沙盒扩展 + 递归求和（与「空间回收」页同一套）
    /// `escape.withHandle(for: 容器路径)` 消费沙盒扩展 → `files.countTree` 递归求和.
    /// 只要 instproxy 给了 `Container`（`get_apps` 默认响应自带，见
    /// `FileSharingApp.containerPath`）就能量 —— 不需要应用配合，也不需要额外隧道.
    /// 量的是**整个数据容器**（Documents + Library + tmp），与 `DynamicDiskUsage` 的口径一致
    ///（不是只量 Documents）.
    ///
    /// ## 代价（如实说明）
    /// · 走的是**本机 syscall**（不是 USB 隧道），但确实要 stat 一遍文件树，所以有上限：
    ///   单应用 ≤ `docSizeMaxNodesPerApp` 个节点、单轮 ≤ `docSizePassMaxApps` 个应用；
    /// · 全程在 `Task.detached(.utility)` 上跑、**不阻塞首屏**：从快路径拿到列表就发起，
    ///   与后面的带属性 Lookup（最长 15 秒）和空间快照**重叠**，通常等在它后面的是现成结果；
    /// · 量的结果**跨轮累积**（10 分钟有效），所以第一轮多半只覆盖一部分，
    ///   多进几次「设备瘦身」/ 点一次刷新就补齐 —— 日志里每轮都打覆盖数，别猜.
    private static func startDocSizePass(_ apps: [FileSharingApp]) {
        let measurable = apps.filter { !isSystemApp($0) && ($0.containerPath?.isEmpty == false) }
        let pending = measurable.filter { cachedDocSize($0.bundleId) == nil }

        docSizeLock.lock()
        let picked = pending
            .filter { !docSizeInFlight.contains($0.bundleId) }
            .prefix(docSizePassMaxApps)
            .map { DocSizeTarget(bundleId: $0.bundleId, path: $0.containerPath ?? "") }
        for entry in picked { docSizeInFlight.insert(entry.bundleId) }
        let done = docSizeCache.count
        docSizeLock.unlock()

        guard !picked.isEmpty else {
            LoginLogger.shared.log(
                "[设备瘦身] 文档大小：本轮无需补（已量 \(done)/\(measurable.count) 个可量的应用）"
            )
            return
        }
        LoginLogger.shared.log(
            "[设备瘦身] 文档大小：本轮量 \(picked.count) 个应用（本机通道；此前累计 \(done) 个，"
            + "可量 \(measurable.count) 个）"
        )
        Task.detached(priority: .utility) {
            var measured = 0
            var failed = 0
            for entry in picked {
                let startedAt = Date()
                let bytes = measureContainerBytes(entry.path)
                // Swift 6：NSLock 的 lock/unlock 在 async 上下文不可用，改用作用域加锁
                // `withLock`（临界区内没有 await，语义与原来的 lock/unlock 完全一致）。
                let nowDone = docSizeLock.withLock { () -> Int in
                    if let bytes {
                        docSizeCache[entry.bundleId] = (bytes, Date())
                        measured += 1
                    } else {
                        failed += 1
                    }
                    docSizeInFlight.remove(entry.bundleId)
                    return docSizeCache.count
                }
                let seconds = String(format: "%.2f", Date().timeIntervalSince(startedAt))
                LoginLogger.shared.log(
                    "[设备瘦身] 文档大小 \(entry.bundleId)："
                    + (bytes.map { formatBytes($0) } ?? "量不到")
                    + "（用时 \(seconds)s；累计 \(nowDone)/\(measurable.count)）"
                )
            }
            LoginLogger.shared.log(
                "[设备瘦身] 文档大小本轮结束：量到 \(measured) 个 / 量不到 \(failed) 个"
                + "（剩下的下一轮继续）"
            )
        }
    }

    /// 单个应用数据容器的递归占用（字节）；`nil` = 这次没量到（沙盒扩展被拒 / 容器不在）.
    private static func measureContainerBytes(_ containerPath: String) -> Int64? {
        guard !containerPath.isEmpty else { return nil }
        let escape = SandboxEscape()
        let files = FileService()
        do {
            return try escape.withHandle(for: containerPath) { _ in
                guard files.isDirectory(at: containerPath) else { return nil }
                let counted = try files.countTree(at: containerPath,
                                                  maxNodes: docSizeMaxNodesPerApp)
                return counted.bytes
            }
        } catch {
            return nil
        }
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
        // v0.3.378：快路径（get_apps）保底出数据，不再「超时按空处理」；
        // 精确大小依赖可选增强，取不到时该分片会偏小，页面以「应用大小不可用」明确说明.
        let appRead = readAppsForSlim()
        for app in appRead.apps where app.applicationType != "System" {
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
            systemItems.append(Item(id: path, name: why,
                                    detail: cacheDetail(path, snap),
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
            tempItems.append(Item(id: path, name: why,
                                  detail: cacheDetail(path, snap),
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
        // v0.3.378：快路径（get_apps）保底出数据；没有精确大小时（增强未成功）
        // 该分组判不出「> 500MB」，页面以「应用大小不可用」明确说明，而不是静默变空.
        let appRead = readAppsForSlim()
        for app in appRead.apps {
            guard app.applicationType != "System" else { continue }
            let appSize = app.appSize ?? 0
            // v0.3.408：文档大小取**本机通道**量到的结果（`DynamicDiskUsage` 不在请求里，
            // 见 `startDocSizePass`）。还没量到的按 0 算 —— 与从前一字不差，不是回退.
            let docSize = app.docSize ?? cachedDocSize(app.bundleId) ?? 0
            let total = appSize + docSize
            guard total > bigAppThreshold else { continue }
            var available: Bool? = nil
            if byBundle[app.bundleId] != nil {
                available = true
            } else {
                available = SourcePackageLocator.cachedAvailability(bundleId: app.bundleId)
            }
            out.append(Item(id: app.bundleId, name: app.name,
                            detail: nil, bytes: total, kind: .bigApps, deletable: false,
                            appSize: appSize, docSize: docSize, version: app.version,
                            ipaFileName: byBundle[app.bundleId]?.fileName,
                            sourceAvailable: available,
                            isRisky: riskyBundleIds.contains(app.bundleId)))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// 缓存行副标题：设备上的目录名 + 文件数（用来对照爱思面板）
    private static func cacheDetail(_ path: String, _ snap: Snapshot) -> String {
        let leaf = itemName(path)
        let count = snap.fileCounts[path] ?? 0
        return leaf == path ? "\(count) 个文件" : "\(leaf) · \(count) 个文件"
    }

    private static func itemName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// 探测「免登录源里有没有这些应用」，回填 `sourceAvailable`（爱思的「资源缺失无法重装」）。
    /// 值为 nil = 该项这次没查成（**不是**资源缺失，UI 不应拦）。
    static func probeSourceAvailability(_ targets: [(bundleId: String, name: String)],
                                        progress: ((Int, Int) -> Void)? = nil) async -> [String: Bool?] {
        await SourcePackageLocator.probe(bundleIds: targets, progress: progress)
    }

    /// 「重新检测」：清空探测缓存后重探（源里新上架 / 之前网络失败时用）
    static func refreshSourceAvailability(_ targets: [(bundleId: String, name: String)],
                                          progress: ((Int, Int) -> Void)? = nil) async -> [String: Bool?] {
        SourcePackageLocator.clearCache()
        return await SourcePackageLocator.probe(bundleIds: targets, progress: progress)
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

    /// 卸载 + 重装（**会清掉该 App 的文稿与数据**）。
    ///
    /// 本地「免登录下载」库里没有该包时，**现场去免登录源按 bundleId 找并下载**
    /// ——这正是爱思的做法（它的包不落本地，重装时从自己服务端取）。
    /// 源里也找不到才判定为「资源缺失」。
    static func reinstall(items: [Item],
                          progress: (@Sendable (ReinstallProgress) -> Void)? = nil) async -> ReinstallResult {
        var result = ReinstallResult()
        let targets = items.filter { $0.kind == .bigApps }
        for (index, item) in targets.enumerated() {
            // Swift 6：report 会被下面两个 @Sendable 的 progress 闭包捕获 ——
            // 标 @Sendable，并且只捕获 Sendable 的快照（进度回调、序号、总数、名称），
            // 不再捕获可能非 Sendable 的 `item` / `targets`（原写法触发
            // SendableClosureCaptures，CI 实测 :797）。语义不变。
            let progressHandler = progress
            let itemIndex = index + 1
            let itemTotal = targets.count
            let itemName = item.name
            @Sendable func report(_ stage: ReinstallStage, _ fraction: Double) {
                progressHandler?(ReinstallProgress(index: itemIndex, total: itemTotal,
                                                   name: itemName, stage: stage, fraction: fraction))
            }
            do {
                // ① 本地已有包就直接用；否则去源里找
                var fileName = item.ipaFileName
                var localPath = fileName.map { IPADownloadLibrary.shared.path(forFileName: $0) } ?? ""
                if fileName == nil || !FileManager.default.fileExists(atPath: localPath) {
                    report(.locating, 0)
                    guard let hit = await SourcePackageLocator.find(bundleId: item.id, name: item.name) else {
                        result.failures.append("\(item.name)：源里没有找到该应用")
                        continue
                    }
                    let saved = try await AppStoreInstallService.downloadIPA(
                        urlString: hit.ipaURL,
                        suggestedName: "\(item.id)-\(hit.version ?? "x").ipa",
                        progress: { p in
                            DispatchQueue.main.async { report(.downloading, p * 0.6) }
                        },
                        onLog: { LoginLogger.shared.log("[瘦身] \($0)", category: .i4Store) })
                    fileName = saved.lastPathComponent
                    localPath = saved.path
                    await MainActor.run {
                        IPADownloadLibrary.shared.record(fileURL: saved,
                                                         displayName: item.name,
                                                         bundleId: item.id,
                                                         version: hit.version,
                                                         iconURL: nil,
                                                         source: "爱思免登录")
                    }
                }
                guard let fileName, FileManager.default.fileExists(atPath: localPath) else {
                    result.failures.append("\(item.name)：安装包不可用")
                    continue
                }
                // ② 卸载 → 装回
                report(.installing, 0.6)
                try UninstallService.shared.uninstall(bundleId: item.id)
                try await AppStoreInstallService.installLocalIPA(
                    localPath,
                    progress: { p in
                        DispatchQueue.main.async { report(.installing, 0.6 + p * 0.4) }
                    },
                    onLog: { LoginLogger.shared.log("[瘦身] \($0)", category: .i4Store) })
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
