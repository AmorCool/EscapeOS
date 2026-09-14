import Foundation

/// v0.3.208：文档共享应用文件浏览（iDescriptor FileSharing 移植，不依赖漏洞）.
/// 数据源：
///   - instproxy_browse 列全部已装应用（含 UIFileSharingEnabled 字段）
///   - house_arrest_vend_documents 为指定 bundle id 拿 AFC 会话（仅该 App /Documents 容器）
///   - afc_list_directory / afc_get_file_info 列举与读元数据
struct FileSharingApp: Identifiable {
    var id: String { bundleId }
    var bundleId: String
    var name: String        // CFBundleDisplayName
    var version: String     // CFBundleShortVersionString
    var applicationType: String // "User" / "System"
    var supportsFileSharing: Bool
    var path: String?       // ApplicationPath（可选展示）
    var appSize: Int64?     // 应用大小（StaticDiskUsage / CFBundleSize，字节；未返回则为 nil）
    var docSize: Int64?     // 文档大小（DynamicDiskUsage，字节；未返回则 UI 层走 AFC 懒算）
    // v0.3.291：安装来源（真机 iPhone15,4 / iOS 27.0 实证）
    //   iTunesMetadata 是 **binary plist 字节**（不是字典），账号邮箱在
    //   com.apple.iTunesStore.downloadInfo.accountInfo.AppleID；
    //   ApplicationDSID = 安装该 App 的账号 DSID（与 accountInfo.DSPersonID 同值）；
    //   IsAppStoreVendable / Archive 在 iOS 27 均不可用（后者返回 UnknownCommand）。
    var appleId: String?      // 账号邮箱（appleId 顶层 或 downloadInfo.accountInfo.AppleID）
    var dsid: String?         // 账号 DSID（accountInfo.DSPersonID 或 ApplicationDSID）
    var purchaseDate: String? // 购买/下载时间（downloadInfo.purchaseDate）
    var signer: String?       // SignerIdentity（侧载/签名身份，App Store 为 "Apple iPhone OS Application Signing"）
    var isGenuine: Bool = false // 爱思「苹果正版」= 归档信息里有 iTunesMetadata（App Store 下发）
    /// v0.3.363：安装来源类型（与「应用」板块 **同一套** AppTypeDetector 判定，
    /// 见 AppListView.loadAppTypes）。此前文档浏览只按 isGenuine 二分成
    /// 「苹果正版 / 共享正版」，把自签 / 企业 / 系统应用全部压成「共享正版」。
    /// v0.3.364：listAppsWithFileSharing() 不再填这个字段（首屏不等 profile），
    /// 由 UI 渐进式回填（fetchAppTypeContext → detectTypes）.
    var appType: AppType? = nil
}

/// v0.3.364：文档浏览的**显示口径**——对齐爱思分类（**唯一映射点**）.
///
/// 判定仍全部来自 AppTypeDetector；本枚举只负责「AppType → 用户看得懂的标签」。
/// 后续 i4-class 逆向出的分类微调**只改这里的 classify**（UI 只按本类型取文案/配色）.
///
/// 类别集合（v0.3.364）：苹果正版 / 共享正版 / 个人签名 / 企业签名 / 越狱版 / 系统 / 未识别。
/// 爱思 9.0 的 6 类里没有「系统」（它只有 全部/可更新/旧版/适配iPad/苹果正版/
/// 共享正版/个人签名/企业签名/越狱版/其他版本），「系统」是用户明确要求保留的自加类。
enum FileSharingTypeClass: String, CaseIterable, Identifiable, Hashable {
    case appStorePersonal = "苹果正版"
    case appStoreShared   = "共享正版"
    case development      = "个人签名"
    case enterprise       = "企业签名"
    case jailbroken       = "越狱版"
    case system           = "系统"
    case unrecognized     = "未识别"

    var id: String { rawValue }

    /// 权威归入：ApplicationType + AppType → 显示类别.
    /// - 非 User（System / HiddenSystemApp / 其它）→ 系统
    /// - .appStore（加密包但拿不到元数据的兜底）→ 苹果正版（不显示「AppStore」）
    static func classify(applicationType: String?, appType: AppType?) -> FileSharingTypeClass {
        if applicationType != "User" { return .system }
        switch appType ?? .unknown {
        case .appStorePersonal, .appStore: return .appStorePersonal
        case .appStoreShared:              return .appStoreShared
        case .development:                 return .development
        case .enterprise:                  return .enterprise
        case .jailbroken:                  return .jailbroken
        case .hidden:                      return .system
        case .unknown:                     return .unrecognized
        }
    }

    /// 渐进加载专用：返回 nil = 「还没算出来」（UI 显示占位，不下判断）.
    /// - 非 User 应用首屏即可定类（ApplicationType 来自 instproxy，无需 profile）
    /// - `settled == true`（本轮判定已跑完）仍未拿到 appType → 收敛到「未识别」，
    ///   不允许任何应用永远停在占位.
    static func resolve(applicationType: String?, appType: AppType?, settled: Bool) -> FileSharingTypeClass? {
        if applicationType != "User" { return .system }
        guard let appType else { return settled ? .unrecognized : nil }
        return classify(applicationType: applicationType, appType: appType)
    }
}

/// v0.3.376：读取「已装应用列表」的结局——给调用方区分「成功 / 真失败 / 超时」.
/// 为什么要区分：超时不是失败（设备可能只是慢），必须能给出「读取超时」这种
/// 最短提示；真失败要保留原始原因（如「无配对文件」）.
enum FileSharingListOutcome {
    case ok([FileSharingApp])
    case failed(String)
    case timedOut
}

enum FileSharingService {
    static func makeError(_ message: String) -> NSError {
        NSError(domain: "FileSharing", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// RSD 隧道并发铁律（AFCService.swift:15 同款）：**同一 hostname 并发
    /// `tunnel_create_rppairing` 会互相抢占**. 本服务建隧道用的 hostname 固定为
    /// "EscapeSpaceFileShare"（见下方 makeTunnel），而 v0.3.369 起：
    ///   - 「应用管理」AppListView.loadAppTypes 与
    ///   - 「文档浏览」FileSharingAppsView.load
    /// 会**各自独立**调用本服务 → 同 hostname 隧道并发握手.
    ///
    /// v0.3.378：由 v0.3.376 的 `DispatchQueue.sync` 换成 **`NSRecursiveLock`**，
    /// 两个理由：
    ///   1. 需要把「排队等待」与「实际执行」**分开记账**（sync 拿不到这个分界点）；
    ///   2. 闸门只在 `makeTunnel` 里取/放，锁粒度仍是「建隧道这一步」——
    ///      **绝不在 FFI 阻塞期间持锁**，否则一次卡死会把其它入口全拖死.
    static let tunnelGate = NSRecursiveLock()

    /// v0.3.378：当前线程在闸门上的累计排队等待秒数（threadDictionary，按线程隔离）.
    /// 为什么需要它：等待发生在 `makeTunnel` 深处，而超时记账在 `runGated`；
    /// 线程局部是两者之间最小、且不需要改动任何调用方签名的传递通道.
    private static let queueWaitKey = "com.escapeos.filesharing.queueWait"

    private static func recordQueueWait(_ seconds: TimeInterval) {
        let dict = Thread.current.threadDictionary
        dict[queueWaitKey] = ((dict[queueWaitKey] as? Double) ?? 0) + seconds
    }

    private static func takeQueueWait() -> TimeInterval {
        let dict = Thread.current.threadDictionary
        let value = (dict[queueWaitKey] as? Double) ?? 0
        dict[queueWaitKey] = 0
        return value
    }

    private static func resetQueueWait() {
        Thread.current.threadDictionary[queueWaitKey] = 0
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    /// 列出全部已装应用并标 UIFileSharingEnabled.
    ///
    /// **v0.3.378：主路径曾一度退回 `get_apps`（快路径）**.
    /// 证据（真机 16:29 日志）：3 次**并发**的带属性 Lookup 全部 20 秒一个字节不回
    ///（`[16:29:21.813 / :24.105 / :34.744] 开始读取` → `[16:29:41.889] 读取超时`），
    /// 而**同一次会话**里改用 `get_apps` + profile 的路径 **2.5 秒**就判完 333 个应用
    ///（16:29:41.895 → :44.395）——说明通道是好的，是 `Lookup` 这条命令卡死.
    ///
    /// **v0.3.401：类型判定的主路径改回带属性 Lookup**
    /// （见 `listAppsWithAttributesWithFallback(timeout:)`）—— 因为 `get_apps`
    /// **不返回 `iTunesMetadata`**，购买邮箱恒空，**共享正版会被判成「苹果正版」**
    /// （回归：`b2c310d` / v0.3.378；两板块共用同一输入与判定）。同时把
    /// ReturnAttributes 收紧到类型判定必需字段（去掉磁盘占用类，Rust 侧见
    /// installation_proxy.rs 的 `attrs` 常量），验证「卡死 = 逐 app 算磁盘占用」的假设.
    ///
    /// 本函数（**无属性** `get_apps`）随之降级为两处用途：
    ///   - **小额度调用**的快路径（如 `IPADownloadActionsSheet` 的 5s 数据源）；
    ///   - 带属性 Lookup 失败/超时后的**降级路径**（缺购买邮箱 → 类型显示「未识别」，
    ///     不再误判成「苹果正版」，见 AppTypeDetector v0.3.401）.
    /// 同步阻塞——调用方放后台线程.
    static func listAppsWithFileSharing() throws -> [FileSharingApp] {
        LoginLogger.shared.log("[文件共享] get_apps 快路径开始（不带 ReturnAttributes）")
        let apps = try legacyGetApps()
        let withMeta = apps.filter(\.isGenuine).count
        let withAccount = apps.filter { $0.appleId != nil }.count
        LoginLogger.shared.log(
            "[文件共享] get_apps 快路径返回 \(apps.count) 条"
            + "（带 iTunesMetadata \(withMeta) / 带购买邮箱 \(withAccount)）"
        )
        return apps
    }

    /// v0.3.401：**类型判定主路径** —— 先带属性 Lookup（购买邮箱
    /// `iTunesMetadata.appleId` 的**唯一**来源），取不到再降级到无属性 `get_apps`。
    /// 两层都在：带属性走单飞+短期缓存（见 AttributeLookupCenter）、失败/超时降级，
    /// 整条链路由外层 `listAppsWithFileSharing(timeout:)` 的硬超时兜底.
    ///
    /// 为什么「去掉磁盘占用字段」有机会救回来（**待真机验证的假设**）：
    /// `StaticDiskUsage` / `DynamicDiskUsage` 会让 installd 对**每个**已装应用走一遍
    /// bundle / 数据容器目录树（后者要遍历 GB 级数据容器），是这条命令最贵的部分；
    /// 类型判定只需要 `iTunesMetadata` + 基础标识字段。真机跑一次看日志里的
    /// **实际执行 X.Xs** 是否从 20s+ 掉到可接受，即完成验证（日志见本函数内）.
    ///
    /// 额度自适应：`timeout` 是外层给这条链路的总额度，这里给带属性 Lookup 留
    /// `timeout - 5`（真机 `get_apps` 2.5s 级，留 5s 足够降级跑完并把列表交回），
    /// 上限 `attributeLookupBudget`；**额度 < 10s 的调用直接用 `get_apps`**——
    /// 带属性 Lookup 跑不进那么短，只会白留一条僵尸命令、还会把随后几次调用推进静默期.
    private static func listAppsWithAttributesWithFallback(timeout: TimeInterval) throws -> [FileSharingApp] {
        if timeout < 10 {
            LoginLogger.shared.log(
                "[文件共享] 额度 \(formatSeconds(timeout))s < 10s：直接用 get_apps 快路径"
                + "（不发起带属性 Lookup）"
            )
            return try listAppsWithFileSharing()
        }
        let budget = max(2, min(attributeLookupBudget, timeout - 5))
        let startedAt = Date()
        LoginLogger.shared.log(
            "[文件共享] 主路径：带属性 Lookup（请求字段："
            + attributeRequestFields.joined(separator: " / ")
            + "；额度 \(formatSeconds(budget))s）"
        )
        let (outcome, note) = AttributeLookupCenter.shared.run(
            timeout: budget,
            label: "带属性 Lookup（主路径）"
        ) {
            do {
                return .ok(try lookupAppsWithAttributes())
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        if case .ok(let apps) = outcome, !apps.isEmpty {
            let withMeta = apps.filter(\.isGenuine).count
            let withAccount = apps.filter { $0.appleId != nil }.count
            LoginLogger.shared.log(
                "[文件共享] 主路径返回 \(apps.count) 条"
                + "（带 iTunesMetadata \(withMeta) / 带购买邮箱 \(withAccount)）"
                + "，端到端 \(formatSeconds(Date().timeIntervalSince(startedAt)))s（\(note)）"
            )
            return apps
        }
        LoginLogger.shared.log(
            "[文件共享] 主路径未取到（\(note)）→ 降级 get_apps；购买邮箱缺失，"
            + "类型判定将显示「未识别」而不是「苹果正版」（v0.3.401 A）"
        )
        let apps = try listAppsWithFileSharing()
        LoginLogger.shared.log(
            "[文件共享] 降级 get_apps 返回 \(apps.count) 条，端到端 "
            + "\(formatSeconds(Date().timeIntervalSince(startedAt)))s"
        )
        return apps
    }

    /// v0.3.401：带属性 Lookup **实际请求**的字段（日志用）。必须与 Rust
    /// `rust/idevice-ffi/src/installation_proxy.rs` 的 `attrs` 常量逐条一致——
    /// 改一处务必改另一处，否则日志会骗人.
    private static let attributeRequestFields = [
        "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
        "CFBundleShortVersionString", "ApplicationType", "UIFileSharingEnabled",
        "Path", "iTunesMetadata", "ApplicationDSID", "SignerIdentity",
    ]

    /// v0.3.401：带属性 Lookup 的执行额度上限（秒）——主路径与可选增强
    /// `lookupAppAttributes(timeout:)` 共用同一个值（它们现在共享同一条单飞命令，
    /// 增强通常会命中 12s 缓存而不另发命令）. 与 `lookupAppAttributes` 的默认参数
    /// （15）必须一致，否则日志里的「额度」与实际不符.
    private static let attributeLookupBudget: TimeInterval = 15

    /// v0.3.378：**带属性 `Lookup`** —— `iTunesMetadata`（appleId / isGenuine）与
    /// 大小字段的唯一来源（这些字段只有带 ReturnAttributes 的 Lookup 才返回）.
    ///
    /// v0.3.401：**它已不是「可选增强」，而是主路径的同一条命令**——
    /// `listAppsWithFileSharing(timeout:)` 现在先走带属性 Lookup（主路径），
    /// 因此本函数在那一轮加载里通常**命中 12s 缓存**（单飞复用，不另发命令），
    /// 返回与主路径完全相同的列表；三处消费方（文档浏览 / 应用管理 / 设备瘦身）
    /// 的「第二版精修」因此变成幂等回填，保留它是为了兼容调用方签名与
    /// 「主路径未取到、稍后又自愈」的窗口.
    /// ⚠️ 大小字段自 v0.3.401 起**不再由这条命令返回**（Rust attrs 已收紧），
    /// 所以这里补不回 appSize/docSize。文档大小本有 AFC 兜底实现
    /// （`computeDocumentsSize`），但其调用点 `FileSharingAppsView.computeDocumentSizes()`
    /// **当前是死代码**；应用大小在 iOS 侧没有 AFC 等价通道（house_arrest 只到数据容器）.
    ///
    /// 独立超时、失败或超时**返回空数组**（字段保持「—」）；调用方必须在首屏渲染
    /// 之后调用，且不得因它失败而回退/清空主列表.
    /// **v0.3.379：额度由 8 秒提到 15 秒** —— 它是后台可选增强、不阻塞首屏，且
    /// 单飞保证同一时刻只有一条在飞（不会因为放宽额度而多压设备）；而 v0.3.376
    /// 之前**根本没有超时**，说明这条命令"最终会返回"才是常态。
    ///
    /// **v0.3.379：全部调用统一走 `AttributeLookupCenter`（进程内单飞 + 设备级串行）**.
    /// 真机 16:29 日志（3 次并发发起全挂 20s）+ 代码实证（见 AttributeLookupCenter
    /// 注释）：这条命令本身与 `get_apps` 是**同一套线格式**，差别只在 ReturnAttributes
    /// 让 installd 要对全部已装应用逐个算磁盘占用/读元数据——贵。三方（应用管理 /
    /// 文档浏览 / 设备瘦身）各自发一条时，设备侧被同时压 3 份重活，每条都超时。
    /// 单飞后设备侧任何时刻最多 1 条，并发调用共享同一结果；`timeout` 只计
    /// **本条的实际执行**（跟随/缓存等待单独写日志，不占执行额度）.
    static func lookupAppAttributes(timeout: TimeInterval = 15) -> [FileSharingApp] {
        let (outcome, note) = AttributeLookupCenter.shared.run(timeout: timeout, label: "带属性增强") {
            do {
                return .ok(try lookupAppsWithAttributes())
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        switch outcome {
        case .ok(let apps):
            if apps.isEmpty {
                LoginLogger.shared.log("[文件共享] 带属性增强未取到数据：字段保持「—」（\(note)）")
            } else {
                LoginLogger.shared.log("[文件共享] 带属性增强成功：\(apps.count) 条（补大小/账号）（\(note)）")
            }
            return apps
        case .failed(let message):
            LoginLogger.shared.log("[文件共享] 带属性增强失败：\(message)；字段保持「—」（\(note)）")
            return []
        case .timedOut:
            LoginLogger.shared.log("[文件共享] 带属性增强超时：字段保持「—」（\(note)）")
            return []
        }
    }

    /// v0.3.379：诊断只读计数——「此刻设备侧有几条带属性 Lookup 在飞」.
    /// 单飞协调器保证只会是 0 或 1（三处消费方共用同一条）. 供日志/状态面板查询.
    static var attributeLookupInFlightCount: Int { AttributeLookupCenter.shared.inFlightCount }

    /// v0.3.379：带属性 `Lookup` 的**进程内单飞 + 设备级串行**协调器.
    ///
    /// 为什么必须有它（实证，非推断）：
    ///   - `installation_proxy_lookup_apps`（rust/idevice-ffi/src/installation_proxy.rs:744）
    ///     与 `get_apps` 是**同一条 `Lookup` 命令、同一套 4B 长度前缀线格式**
    ///     （Swift 侧 get_apps→crate `installation_proxy.rs:87`→`Idevice::send_plist`
    ///     /`read_plist_value`；我们的手写帧在 installation_proxy.rs:766-779）——
    ///     所以卡死**不是**帧/读法问题；唯一差异是 ReturnAttributes 让 installd
    ///     对全部已装应用逐个算 `StaticDiskUsage`/`DynamicDiskUsage` 并读
    ///     `iTunesMetadata`/`Entitlements`（贵），而无属性的 `get_apps` 同会话 2.5s
    ///     就跑完 333 个应用；
    ///   - 消费方是**三处**：`AppListView.swift:273`（v0.3.369 起）、
    ///     `FileSharingAppsView.swift:453`、`DeviceSlimService.swift:320`（v0.3.376 起），
    ///     时间线上「卡死」正是并发数 2→3 那一版开始出现的——三方各自发一条贵命令，
    ///     设备侧同时被压 3 份重活，每条都超过 20s 额度.
    ///
    /// 语义（三者缺一不可）：
    ///   - **单飞**：第一条调用实际发起，其余并发调用**不另发命令**，等同一个结果；
    ///   - **短期缓存**：成功结果在 `cacheTTL` 秒内直接复用（同一轮页面加载里三方基本命中同一次）；
    ///   - **设备级串行**：只要上一条还没从设备返回（含已超时放弃、但 FFI 仍在后台跑的
    ///     "僵尸"），就**不再发起**新命令——保证设备侧任何时刻最多 1 条在飞.
    ///
    /// 可观测：`inFlightCount` 可回答「现在有几条在飞」（本协调器保证只会是 0 或 1），
    /// 日志区分「实际发起 / 单飞复用·缓存命中 / 单飞复用·跟随 / 僵尸返回 / 超时静默期」.
    ///
    /// **真机对照判据（下次谁怀疑单飞没生效 / 怀疑卡死不只是并发，照这 4 条看日志）**：
    ///   1. 同一轮只应出现**一条**「… 实际发起（第 N 批；设备侧 Lookup 在飞 1 条…）」；
    ///      若 15s（≈额度）内出现**第二条「实际发起」** → 单飞漏了，回来改这里。
    ///   2. 该条收尾为「实际执行返回（成功 N 条，额度 15s）」且 `实际执行 < 15.0s`
    ///      → 并发就是全部原因，大小/账号字段应恢复有值。
    ///   3. 上一条的 **N ≈ 已装应用数**（如 333）：若 N 明显偏少（如 <300）→ 说明读取
    ///      提前截断，才需要回头查 Rust 读法（当前判定：读法是正确的，见
    ///      installation_proxy.rs:771 的"别改成只认 Status"注释）。
    ///   4. 该条收尾为「超时放弃 15s（FFI 仍在后台跑…）」→ 是**单条工作量 > 额度**，
    ///      不是并发问题；此时应看到随后的调用报「设备侧上一条 Lookup 仍未返回…
    ///      为保持串行不重发」——若没看到而出现了新的「实际发起」，说明闸门漏了。
    private final class AttributeLookupCenter: @unchecked Sendable {
        static let shared = AttributeLookupCenter()

        enum Outcome {
            case ok([FileSharingApp])
            case failed(String)
            case timedOut
        }

        /// 成功结果的短期复用窗口（秒）. 12s 覆盖「同一轮页面加载」，又短到
        /// 用户切页/重试时能拿到新数据.
        private static let cacheTTL: TimeInterval = 12
        /// 失败/超时后的静默期（秒）：此窗口内不重新发起，避免僵尸命令之上再叠一条.
        private static let cooldown: TimeInterval = 4
        /// 跟随者额外的等待余量（秒）：发起者的执行额度 + 它收尾的时间.
        private static let followerSlack: TimeInterval = 20

        /// 一次批次。**引用类型**：发起者与跟随者必须共享同一实例才能看到 `outcome`
        /// 的写入（值类型会被各自拷贝，跟随者永远读到 nil）.
        private final class Flight {
            let generation: Int
            /// 本批的执行额度（秒）——只为日志写清"额度多少"，便于真机核对.
            let budget: TimeInterval
            let group = DispatchGroup()
            var outcome: Outcome?
            /// true = 已写结果并放行等待者（可能因为超时"放弃"，此时 FFI 仍在后台跑）.
            var settled = false
            /// true = 已超时放弃、但工作线程尚未返回（僵尸仍在设备上）.
            var abandoned = false
            var followers = 0
            let startedAt = Date()
            init(generation: Int, budget: TimeInterval) {
                self.generation = generation
                self.budget = budget
            }
        }

        /// 跨线程回传工作线程结果的小盒（与 TimedOutcomeBox 同款模式）.
        private final class OutcomeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Outcome?
            func store(_ value: Outcome) { lock.lock(); stored = value; lock.unlock() }
            func load() -> Outcome? { lock.lock(); defer { lock.unlock() }; return stored }
        }

        private let lock = NSLock()
        private var generation = 0
        /// 非 nil = 上一条命令的工作线程**还没返回**（不论是否已超时放弃）→ 设备侧在飞 1 条.
        private var flight: Flight?
        private var cachedOK: (apps: [FileSharingApp], at: Date)?
        private var cooldownUntil: Date?

        private init() {}

        /// 设备侧真正在飞的 Lookup 条数（只能 0 或 1）.
        var inFlightCount: Int {
            lock.lock(); defer { lock.unlock() }
            return flight == nil ? 0 : 1
        }

        private static func secs(_ value: TimeInterval) -> String {
            String(format: "%.1f", value)
        }

        /// 单飞入口. `timeout` 只作用于**本条的实际执行**；跟随/缓存等待单独写日志.
        /// 返回（结果, 可读说明）——说明会拼进 `[文件共享]` 日志，便于区分各种复用/失败.
        func run(timeout: TimeInterval,
                 label: String,
                 work: @escaping () -> Outcome) -> (Outcome, String) {
            lock.lock()

            // ① 成功结果短期复用（不另发命令）
            if let cachedOK, Date().timeIntervalSince(cachedOK.at) < Self.cacheTTL {
                let age = Date().timeIntervalSince(cachedOK.at)
                lock.unlock()
                return (.ok(cachedOK.apps),
                        "单飞复用·缓存命中（\(Self.secs(age))s 前那一条，未再发命令；在飞 \(inFlightCount) 条）")
            }
            // ② 静默期（上一批失败/超时后不立刻重发）
            if let until = cooldownUntil, Date() < until {
                let remain = max(0, until.timeIntervalSinceNow)
                lock.unlock()
                return (.timedOut,
                        "单飞静默期（下次可发起：还有 \(Self.secs(remain))s；在飞 \(inFlightCount) 条）")
            }
            // ③ 上一条还在设备上（含已超时放弃的僵尸）→ 绝不叠发；能等待就跟随，僵尸则直接如实回报
            if let current = flight {
                if current.abandoned {
                    lock.unlock()
                    return (.timedOut,
                            "设备侧上一条 Lookup 仍未返回（已超时放弃、FFI 无法取消），为保持串行不重发；在飞 \(inFlightCount) 条")
                }
                current.followers += 1
                let index = current.followers
                lock.unlock()
                let waitedFrom = Date()
                _ = current.group.wait(timeout: .now() + timeout + Self.followerSlack)
                let waited = Date().timeIntervalSince(waitedFrom)
                lock.lock()
                let outcome = current.outcome ?? .timedOut
                lock.unlock()
                return (outcome,
                        "单飞复用·跟随第 \(index) 个并发调用（与发起者共享同一条，等待 \(Self.secs(waited))s；全程设备侧只有 1 条在飞）")
            }

            // ④ 成为发起者（设备侧此刻 0 条在飞）
            generation += 1
            let current = Flight(generation: generation, budget: timeout)
            current.group.enter()
            flight = current
            lock.unlock()

            let box = OutcomeBox()
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = work()          // FFI 阻塞在这里；不可取消
                box.store(outcome)
                self.workerReturned(current, outcome: outcome)
            }
            LoginLogger.shared.log(
                "[文件共享] \(label) 实际发起（第 \(current.generation) 批；设备侧 Lookup 在飞 \(inFlightCount) 条，已强制串行为 1）"
                + "；等待实际执行额度 \(Int(timeout))s"
            )

            if current.group.wait(timeout: .now() + timeout) == .success {
                let elapsed = Date().timeIntervalSince(current.startedAt)
                let outcome = current.outcome ?? box.load() ?? .timedOut
                let followers = current.followers
                return (outcome,
                        "实际执行 \(Self.secs(elapsed))s"
                        + (followers > 0 ? "（另有 \(followers) 个并发调用复用了这一条）" : ""))
            }

            // 擦边：刚好在额度用尽时工作线程已返回 → 按完成处理（不重发、不进静默期）
            if let done = box.load() {
                LoginLogger.shared.log("[文件共享] \(label)：执行额度刚到但已返回，按完成处理（不重发）")
                return (done, "实际执行略超 \(Int(timeout))s 额度但已完成")
            }

            // ⑤ 超时：向跟随者广播 .timedOut，**保留 flight**（僵尸仍在设备上）→ 真返回前绝不重发
            abandon(current, reason: "超时放弃（额度 \(Int(timeout))s；FFI 仍在后台跑，结果将丢弃）")
            return (.timedOut,
                    "实际执行超时（额度 \(Int(timeout))s，跟随/缓存等待不计入）；已进入 \(Int(Self.cooldown))s 静默期"
                    + "（下次可发起：还有 \(Self.secs(Self.cooldown))s），在飞 \(inFlightCount) 条"
                    + "（等它真返回才允许下一批）")
        }

        /// 工作线程真正返回时的收尾：写结果 + 缓存 + 放行等待者 + **从注册表摘除**.
        /// 「缓存」与「摘除 flight」必须在同一临界区内完成——否则跟随者可能在
        /// 「flight 已摘除、缓存尚未写入」的缝隙里又发起一条重复命令.
        private func workerReturned(_ current: Flight, outcome: Outcome) {
            lock.lock()
            if current.settled {   // 已超时放弃（僵尸）：结果丢弃，但此刻才真正摘除 flight
                if flight === current { flight = nil }
                lock.unlock()
                LoginLogger.shared.log(
                    "[文件共享] 带属性增强：僵尸 Lookup 返回（已超时放弃，结果丢弃，避免与下一批错位）；"
                    + "跟随者 \(current.followers) 个"
                )
                return
            }
            current.outcome = outcome
            current.settled = true
            if case .ok(let apps) = outcome {
                cachedOK = (apps, Date())
                cooldownUntil = nil
            }
            if flight === current { flight = nil }
            lock.unlock()
            current.group.leave()
            LoginLogger.shared.log(
                "[文件共享] 带属性增强实际执行返回（\(describe(outcome))，额度 \(Int(current.budget))s）；"
                + "跟随者 \(current.followers) 个"
            )
        }

        /// 超时放弃：写结果 + 放行等待者 + 进静默期，但**不**摘除 flight（僵尸挡重发）.
        private func abandon(_ current: Flight, reason: String) {
            lock.lock()
            let firstSettle = !current.settled
            if firstSettle {
                current.outcome = .timedOut
                current.settled = true
            }
            current.abandoned = true
            cooldownUntil = Date().addingTimeInterval(Self.cooldown)
            lock.unlock()
            if firstSettle { current.group.leave() }   // group 只 leave 一次（enter 也只一次）
            LoginLogger.shared.log("[文件共享] 带属性增强 \(reason)；跟随者 \(current.followers) 个")
        }

        private func describe(_ outcome: Outcome) -> String {
            switch outcome {
            case .ok(let apps): return "成功 \(apps.count) 条"
            case .failed(let message): return "失败：\(message)"
            case .timedOut: return "超时"
            }
        }
    }

    /// v0.3.376：**带硬超时**的列表读取——止血点.
    ///
    /// 为什么必须有超时：整条链路从 Swift 到 Rust 没有任何一层设超时——
    ///   - Swift `FileSharingAppsView.load()` 的 `defer { loading = false }` 只在
    ///     函数返回时执行；
    ///   - Rust `run_sync_local`（lib.rs:136）= `block_on` 无超时；
    ///   - `TcpStream::connect`（tunnel_provider.rs:873）、`create_tcp_listener`
    ///     （:314）、`RemotePairingClient::connect`（:887）无超时；
    ///   - instproxy 响应读取 `read_raw`（installation_proxy.rs:774/779）无超时.
    /// 只要设备/隧道不再应答，`listAppsWithFileSharing()` 就**永不返回**。
    ///
    /// v0.3.378：超时**只计「实际执行」**时长，在闸门上的排队等待单独记账
    /// （见 runGated 与 tunnelGate 注释）——否则一个调用可能把十几秒耗在排队上，
    /// 刚轮到就"已超时"，报出的「20s」名不副实.
    ///
    /// 超时返回 `.timedOut`（**不是**空数组），调用方据此给提示/降级，绝不无限等待.
    /// 被放弃的那次 FFI 调用仍在后台线程上跑（FFI 无法取消），只是不再阻塞调用方.
    ///
    /// v0.3.401：本函数是**两个板块共用的唯一入口**，内部顺序为
    /// 「带属性 Lookup（买邮箱）→ 失败/超时降级 get_apps」（见
    /// `listAppsWithAttributesWithFallback(timeout:)`）；`workTimeout` 是这条链路的
    /// **总额度**，带属性 Lookup 的额度在内部按它自适应 . 这里的 20s 排队额度不变.
    static func listAppsWithFileSharing(timeout: TimeInterval) -> FileSharingListOutcome {
        runGated(queueTimeout: 20,
                 workTimeout: timeout,
                 label: "列表读取（带属性 Lookup → get_apps 降级）") {
            try listAppsWithAttributesWithFallback(timeout: timeout)
        }
    }

    /// 排队与执行**分别记账**的硬超时执行器.
    /// - `queueTimeout`：在闸门（同 hostname 隧道）上排队等待的额度
    /// - `workTimeout`：真正开始干活之后的执行额度
    /// 总等待上限 = 两者之和；结束时把「排队 Y.Ys / 实际执行 X.Xs」分别写日志，
    /// 保证报出的执行时长不含排队时间.
    private static func runGated(queueTimeout: TimeInterval,
                                 workTimeout: TimeInterval,
                                 label: String,
                                 _ work: @escaping () throws -> [FileSharingApp]) -> FileSharingListOutcome {
        let box = TimedOutcomeBox()
        let sem = DispatchSemaphore(value: 0)
        let startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            resetQueueWait()
            let outcome: FileSharingListOutcome
            do {
                outcome = .ok(try work())
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            box.store(outcome, queueWait: takeQueueWait())
            sem.signal()
        }
        switch sem.wait(timeout: .now() + queueTimeout + workTimeout) {
        case .success:
            let elapsed = Date().timeIntervalSince(startedAt)
            let queued = box.queueWait
            let executed = max(0, elapsed - queued)
            if queued > 0.2 {
                LoginLogger.shared.log(
                    "[文件共享] \(label)：实际执行 \(formatSeconds(executed))s"
                    + "（其中排队等待 \(formatSeconds(queued))s，排队不吃执行额度）"
                )
            }
            return box.load() ?? .failed("读取失败")
        case .timedOut:
            let elapsed = Date().timeIntervalSince(startedAt)
            LoginLogger.shared.log(
                "[文件共享] \(label) 超时：已等待 \(formatSeconds(elapsed))s"
                + "（排队额度 \(Int(queueTimeout))s + 执行额度 \(Int(workTimeout))s，排队与执行分开计）"
            )
            return .timedOut
        }
    }

    /// 上面超时入口用的线程安全小盒（只在 semaphore 信号之后读取，仍加锁防御）.
    private final class TimedOutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: FileSharingListOutcome?
        private var storedQueueWait: TimeInterval = 0
        func store(_ outcome: FileSharingListOutcome, queueWait: TimeInterval) {
            lock.lock(); stored = outcome; storedQueueWait = queueWait; lock.unlock()
        }
        func load() -> FileSharingListOutcome? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
        var queueWait: TimeInterval {
            lock.lock(); defer { lock.unlock() }; return storedQueueWait
        }
    }

    /// v0.3.364：类型判定所需的输入快照（一次性拉取，供分批判定复用）.
    struct AppTypeContext {
        var entitlements: [String: [String: Any]] = [:]
        var provisionsAllDevices: [String: Bool] = [:]
        var currentAppleID: String?
    }

    /// v0.3.364：拉取类型判定数据（**唯一**会开 profile 隧道的入口，与 AppListView.loadAppTypes 同源）.
    ///
    /// 字段来源：
    ///   - entitlements / application-identifier ← installation_proxy 的 Entitlements
    ///     （ProvisioningProfileStore.fetchSideloadedApps，仅有 profile 的侧载应用返回）
    ///   - ProvisionsAllDevices ← misagent 拉的 .mobileprovision 顶层字段
    ///     （企业判定唯一权威字段，Apple TN3125），按 application-identifier 与 profile 匹配
    ///   - currentAppleID ← 当前登录的 App Store 账号（keychain 直读）。
    ///     **v0.3.364 起仅作辅助信息**：正版/共享已改为比「App 自身购买邮箱 ∈
    ///     爱思共享账号白名单」（见 AppTypeDetector），不再比本机登录账号.
    ///
    /// **两条隧道必须顺序串行**：tuple 从左到右求值，各自 createTunnel + defer 释放后
    /// 才建下一条（并发握手会死锁闪退，v0.3.187 真机实证，见 AppListView 注释）.
    /// 同步阻塞——调用方放后台线程，且必须在首屏返回**之后**再调.
    static func fetchAppTypeContext() -> AppTypeContext {
        var context = AppTypeContext()
        LoginLogger.shared.log("[文件共享] 类型上下文开始（profile/misagent 两条隧道串行，无超时）")
        context.currentAppleID = MemoryLimitSettings.currentAppleIDDirect()
        let (sideloaded, allProfiles): (
            [ProvisioningProfileStore.SideloadedAppInfo],
            [ProvisioningProfileStore.ProfileInfo]
        ) = autoreleasepool(invoking: {
            (
                (try? ProvisioningProfileStore.fetchSideloadedApps()) ?? [],
                (try? ProvisioningProfileStore.fetchAllProfiles()) ?? []
            )
        })
        var entMap: [String: [String: Any]] = [:]
        for item in sideloaded {
            entMap[item.bundleID] = item.entitlements
        }
        // 同一 application-identifier 可能有多份 profile → 用 uniquingKeysWith 保留首个
        let profileByAppId = Dictionary(
            allProfiles.map { ($0.appId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var provisionsAllDevicesMap: [String: Bool] = [:]
        for item in sideloaded {
            guard let appId = item.applicationIdentifier,
                  let profile = profileByAppId[appId] else { continue }
            provisionsAllDevicesMap[item.bundleID] = profile.provisionsAllDevices
        }
        context.entitlements = entMap
        context.provisionsAllDevices = provisionsAllDevicesMap
        LoginLogger.shared.log(
            "[文件共享] 类型上下文完成：entitlements \(entMap.count) 条 / "
            + "provisionsAllDevices \(provisionsAllDevicesMap.count) 条 / "
            + "已登录账号 \(context.currentAppleID == nil ? "否" : "是")"
        )
        return context
    }

    /// v0.3.364：对给定 App 子集判定 AppType（渐进式分批回填用；与 AppListView 同源判定）.
    /// 纯内存计算，不开隧道.
    static func detectTypes(for apps: [FileSharingApp], context: AppTypeContext) -> [String: AppType] {
        var resolved: [String: AppType] = [:]
        for app in apps {
            resolved[app.bundleId] = AppTypeDetector.detect(
                entitlements: context.entitlements[app.bundleId] ?? [:],
                applicationType: app.applicationType,
                iTunesAppleID: app.appleId,
                currentAppleID: context.currentAppleID,
                provisionsAllDevices: context.provisionsAllDevices[app.bundleId] ?? false,
                hasITunesMetadata: app.isGenuine
            )
        }
        LoginLogger.shared.log("[文件共享] 类型判定一批：\(apps.count) 条")
        return resolved
    }

    /// v0.3.284：**Lookup** + ReturnAttributes（此前用 Browse —— 大小字段只在
    /// Lookup 的 ReturnAttributes 里返回，pymobiledevice3 同款：lookup +
    /// GET_APPS_ADDITIONAL_INFO）。Rust 侧一次请求取全部字段并以 bplist 字节回传，
    /// Swift 侧完全不碰 plist_t 指针（照抄 get_apps 的 void** 出参模式）。
    ///
    /// **v0.3.378：曾降级为可选增强；v0.3.401 起重新是「类型判定主路径」**
    /// （由 `listAppsWithAttributesWithFallback` 调用，额度自适应、失败由外层降级
    /// 到 `get_apps`）。此函数是购买邮箱 / 大小字段的**唯一**来源；v0.3.401 起
    /// ReturnAttributes 已收紧到类型判定必需字段（Rust 侧 `attrs` 常量），
    /// 因此它**不再返回** `StaticDiskUsage` / `DynamicDiskUsage` / `CFBundleSize`.
    private static func lookupAppsWithAttributes() throws -> [FileSharingApp] {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var ip: OpaquePointer?
        guard installation_proxy_connect_rsd(adapter, handshake, &ip) == nil, let ip else {
            throw makeError("连接 instproxy 失败")
        }
        defer { installation_proxy_client_free(ip) }

        var rawPtr: UnsafeMutableRawPointer?
        var len: Int = 0
        if let err = installation_proxy_lookup_apps(ip, &rawPtr, &len) {
            let msg = err.pointee.message.map { String(cString: $0) } ?? "unknown"
            idevice_error_free(err)
            throw makeError("Lookup 失败：\(msg)")
        }
        guard let rawPtr, len > 0 else {
            throw makeError("Lookup 返回空结果")
        }
        defer { idevice_data_free(rawPtr.assumingMemoryBound(to: UInt8.self), UInt(len)) }

        let data = Data(bytes: rawPtr, count: len)
        guard let array = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [[String: Any]] else {
            throw makeError("Lookup 结果解析失败")
        }
        var result: [FileSharingApp] = []
        for dict in array {
            if let app = parseAppDict(dict) { result.append(app) }
        }
        return result
    }

    /// dict → FileSharingApp（大小字段多来源防御：StaticDiskUsage/CFBundleSize →
    /// NSNumber/Int64 双形态）.
    private static func parseAppDict(_ dict: [String: Any]) -> FileSharingApp? {
        guard let bundleId = dict["CFBundleIdentifier"] as? String, !bundleId.isEmpty else { return nil }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String) ?? bundleId
        let version = (dict["CFBundleShortVersionString"] as? String) ?? ""
        let appType = (dict["ApplicationType"] as? String) ?? "Unknown"
        let sharing = (dict["UIFileSharingEnabled"] as? Bool) ?? false
        let appSize = (dict["StaticDiskUsage"] as? NSNumber)?.int64Value
            ?? (dict["CFBundleSize"] as? NSNumber)?.int64Value
        let docSize = (dict["DynamicDiskUsage"] as? NSNumber)?.int64Value
        let itunesMeta = dict["iTunesMetadata"]
        var appleId: String?
        var dsid = (dict["ApplicationDSID"] as? NSNumber).map { String($0.int64Value) }
        var purchaseDate: String?

        // v0.3.291：iTunesMetadata 在 iOS 27 上以 **binary plist 字节(Data)** 返回
        // （真机实证：b'bplist00...'），此前按 [String:Any] 解析恒失败 → 所有 App
        // 都落到兜底分支被打成「共享正版」。账号邮箱实际路径：
        //   com.apple.iTunesStore.downloadInfo.accountInfo.AppleID
        func absorbMetadata(_ meta: [String: Any]) {
            if appleId == nil {
                appleId = (meta["appleId"] as? String)
                    ?? (meta["purchaseAccountID"] as? String)
                    ?? (meta["bpsAccountID"] as? String)
            }
            guard let info = meta["com.apple.iTunesStore.downloadInfo"] as? [String: Any] else { return }
            if purchaseDate == nil { purchaseDate = info["purchaseDate"] as? String }
            guard let account = info["accountInfo"] as? [String: Any] else { return }
            if appleId == nil { appleId = account["AppleID"] as? String }
            if dsid == nil, let person = account["DSPersonID"] as? NSNumber {
                dsid = String(person.int64Value)
            }
        }
        if let metaData = itunesMeta as? Data,
           let meta = (try? PropertyListSerialization.propertyList(from: metaData, options: [], format: nil)) as? [String: Any] {
            absorbMetadata(meta)
        } else if let meta = itunesMeta as? [String: Any] {
            absorbMetadata(meta)
        }

        let signer = dict["SignerIdentity"] as? String
        let isGenuine = itunesMeta != nil
        return FileSharingApp(
            bundleId: bundleId,
            name: name,
            version: version,
            applicationType: appType,
            supportsFileSharing: sharing,
            path: dict["Path"] as? String,
            appSize: appSize,
            docSize: docSize,
            appleId: appleId,
            dsid: dsid,
            purchaseDate: purchaseDate,
            signer: signer,
            isGenuine: isGenuine
        )
    }

    /// `installation_proxy_get_apps`（**不带** ReturnAttributes）——v0.3.378~400 曾是主路径；
    /// **v0.3.401 起是「小额度快路径 + 主路径降级」**（见
    /// `listAppsWithAttributesWithFallback`）：与 AppDiscovery/TunnelContext.getAllAppsInfo
    /// 同一条命令，真机 333 应用实测 2.5 秒级可用，但**不返回 `iTunesMetadata`**
    /// （购买邮箱 / 正版存在性因此缺失 → 类型判定显示「未识别」，不再误判）.
    /// 命名沿用历史（它曾是 Lookup 失败时的回退）.
    private static func legacyGetApps() throws -> [FileSharingApp] {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        // 1. instproxy connect
        var ip: OpaquePointer?
        guard installation_proxy_connect_rsd(adapter, handshake, &ip) == nil, let ip else {
            throw makeError("连接 instproxy 失败")
        }
        defer { installation_proxy_client_free(ip) }

        // 2. get_apps（Lookup）—— 与 AppDiscovery / JITEnableService 同一范式
        var rawApps: UnsafeMutableRawPointer?
        var count = 0
        if let ffiError = installation_proxy_get_apps(ip, nil, nil, 0, &rawApps, &count) {
            throw makeError("获取应用列表失败")
        }
        guard let rawApps, count > 0 else { return [] }

        let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count {
                plist_free(apps[index])
            }
            idevice_data_free(rawApps.assumingMemoryBound(to: UInt8.self),
                               UInt(count * MemoryLayout<plist_t?>.stride))
        }

        var result: [FileSharingApp] = []
        for index in 0..<count {
            var binaryPlist: UnsafeMutablePointer<CChar>?
            var binaryLength: UInt32 = 0
            guard plist_to_bin(apps[index], &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                  let binaryPlist, binaryLength > 0 else { continue }
            let data = Data(bytes: binaryPlist, count: Int(binaryLength))
            plist_mem_free(binaryPlist)
            guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                    as? [String: Any] else { continue }
            if let app = parseAppDict(dict) { result.append(app) }
        }
        return result
    }

    /// 为指定 bundle id 建立 Documents 容器 AFC 会话（house_arrest vend_documents）.
    /// 返回 AFC handle（caller 负责 free）.失败 throw.
    static func openAppDocuments(bundleId: String) throws -> OpaquePointer {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var ha: OpaquePointer?
        guard house_arrest_client_connect_rsd(adapter, handshake, &ha) == nil, let ha else {
            throw makeError("连接 house_arrest 失败")
        }
        // vend_documents 会消费 ha（Rust 端 Box::from_raw → drop handle）
        var afc: OpaquePointer?
        let rc = bundleId.withCString { bid in
            house_arrest_vend_documents(ha, bid, &afc)
        }
        guard rc == nil, let afc else {
            throw makeError("无法为 \(bundleId) 取得 Documents AFC（可能未开启文档共享或未配对）")
        }
        return afc
    }

    /// v0.3.214：为指定 bundle id 建立**完整数据容器** AFC 会话（house_arrest vend_container）.
    /// 返回 AFC handle（caller 负责 free）；失败 throw —— 表示该应用不允许整个容器访问
    /// （多数第三方 App 无权限，仅开发者/受信签名 App 可开；此时降级只读 Documents）.
    static func openAppContainer(bundleId: String) throws -> OpaquePointer {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var ha: OpaquePointer?
        guard house_arrest_client_connect_rsd(adapter, handshake, &ha) == nil, let ha else {
            throw makeError("连接 house_arrest 失败")
        }
        var afc: OpaquePointer?
        let rc = bundleId.withCString { bid in
            house_arrest_vend_container(ha, bid, &afc)
        }
        guard rc == nil, let afc else {
            throw makeError("该应用不允许访问完整容器（无权限）")
        }
        return afc
    }

    /// v0.3.270：计算指定 App Documents 容器的总大小（字节）.
    /// 每次新建 house_arrest 隧道 + AFC 递归遍历求和（Documents 树通常较小）.
    /// 调用方放后台线程、逐 App 串行（避免同时开多条隧道抢占）.
    static func computeDocumentsSize(bundleId: String) throws -> Int64 {
        let afc = try openAppDocuments(bundleId: bundleId)
        defer { afc_client_free(afc) }
        return try documentsSizeRecursively(afc: afc, path: "/")
    }

    private static func documentsSizeRecursively(afc: OpaquePointer, path: String) throws -> Int64 {
        var total: Int64 = 0
        for entry in try listDirectory(afc: afc, path: path) {
            if entry.isDirectory {
                total += try documentsSizeRecursively(afc: afc, path: entry.path)
            } else {
                total += fileSize(afc: afc, path: entry.path) ?? 0
            }
        }
        return total
    }

    /// v0.3.270：字节 → MB 可读文本（保留 2 位小数，与爱思格式一致）.
    static func formatMB(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.2f MB", mb)
    }

    // MARK: v0.3.214 文件操作（移植 FileBrowserView 能力：新建/重命名/删除）

    /// 新建目录
    static func makeDirectory(afc: OpaquePointer, path: String) throws {
        let rc = path.withCString { afc_make_directory(afc, $0) }
        guard rc == nil else { throw makeError("新建目录失败：\(path)") }
    }

    /// 重命名 / 移动
    static func rename(afc: OpaquePointer, from: String, to: String) throws {
        let rc = from.withCString { src in
            to.withCString { dst in afc_rename_path(afc, src, dst) }
        }
        guard rc == nil else { throw makeError("重命名失败：\(from)") }
    }

    /// 删除（目录需递归删 → 用 remove_path_and_contents）
    static func remove(afc: OpaquePointer, path: String, recursive: Bool) throws {
        let rc = path.withCString { cstr in
            if recursive {
                afc_remove_path_and_contents(afc, cstr)
            } else {
                afc_remove_path(afc, cstr)
            }
        }
        guard rc == nil else { throw makeError("删除失败：\(path)") }
    }

    /// 下载整个文件到内存（afc_file_read_entire 一次读，AFCService 同款范式）
    /// v0.3.226：0 字节空文件合法（新建空文件可编辑）；>200MB 才拒
    static func downloadFile(afc: OpaquePointer, path: String) throws -> Data {
        guard let size = fileSize(afc: afc, path: path), size <= 200 * 1024 * 1024 else {
            throw makeError("文件不存在或超过 200MB")
        }
        var handle: OpaquePointer?
        let rc = path.withCString { afc_file_open(afc, $0, AfcRdOnly, &handle) }
        guard rc == nil, let handle else { throw makeError("打开文件失败") }
        defer { afc_file_close(handle) }
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        if let r = afc_file_read_entire(handle, &dataPtr, &length) {
            throw makeError("读取失败")
        }
        defer { if let dataPtr { afc_file_read_data_free(dataPtr, length) } }
        guard let dataPtr, length > 0 else { return Data() }
        return Data(bytes: dataPtr, count: length)
    }

    /// v0.3.227：流式下载到本地文件（1MB 分块读+写盘，不占内存，任意大小）+ 字节进度
    static func downloadFileStreaming(afc: OpaquePointer, path: String, to dest: URL,
                                      progress: @escaping (Int64, Int64) -> Void) throws {
        let total = fileSize(afc: afc, path: path) ?? 0
        var handle: OpaquePointer?
        let rc = path.withCString { afc_file_open(afc, $0, AfcRdOnly, &handle) }
        guard rc == nil, let handle else { throw makeError("打开文件失败：\(path)") }
        defer { afc_file_close(handle) }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: dest) else {
            throw makeError("创建本地文件失败：\(dest.lastPathComponent)")
        }
        defer { try? fh.close() }
        var done: Int64 = 0
        while true {
            var dataPtr: UnsafeMutablePointer<UInt8>? = nil
            var readLen: Int = 0
            let r = afc_file_read(handle, &dataPtr, 1_048_576, &readLen)
            if let dataPtr, readLen > 0 {
                fh.write(Data(bytes: dataPtr, count: readLen))
                afc_file_read_data_free(dataPtr, readLen)
                done += Int64(readLen)
                progress(done, total)
            }
            if r != nil { throw makeError("读取失败：\(path)") }
            if readLen <= 0 { break }
        }
    }

    /// 上传文件到 AFC（1MB 分块写，AFCService writeFile 同款）.父目录须已存在.
    static func uploadFile(afc: OpaquePointer, data: Data, to path: String) throws {
        var handle: OpaquePointer?
        let rc = path.withCString { afc_file_open(afc, $0, AfcWrOnly, &handle) }
        guard rc == nil, let handle else { throw makeError("创建文件失败：\(path)") }
        defer { afc_file_close(handle) }
        let chunkSize = 1_048_576
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let chunk = min(chunkSize, data.count - offset)
                if let r = afc_file_write(handle, base.advanced(by: offset), chunk) {
                    throw makeError("写入失败：\(path)")
                }
                offset += chunk
            }
        }
    }

    /// 列目录（AFC）.返回顶层条目名 + 是否目录.
    /// v0.3.213：错误不再吞成空数组——抛给 UI 显示真实原因.
    static func listDirectory(afc: OpaquePointer, path: String) throws -> [AfcEntry] {
        var entriesPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int = 0
        let rc = path.withCString { cstr in
            afc_list_directory(afc, cstr, &entriesPtr, &count)
        }
        guard rc == nil else {
            throw makeError("列目录失败：\(path)")
        }
        defer {
            if let entriesPtr {
                for i in 0..<count {
                    if let p = entriesPtr[i] { free(p) }
                }
                entriesPtr.deallocate()
            }
        }
        var result: [AfcEntry] = []
        guard let entriesPtr else { return [] }
        for i in 0..<count {
            guard let cstr = entriesPtr[i] else { continue }
            let name = String(cString: cstr)
            guard name != ".", name != ".." else { continue }
            let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
            // v0.3.288：一次 afc_get_file_info 同时取 类型/大小/修改时间
            //（原先只判目录 + 大小从未取 → 列表恒 0 字节）
            var info = AfcFileInfo()
            let rc = childPath.withCString { afc_get_file_info(afc, $0, &info) }
            var isDir = false
            var size: Int64 = 0
            var modified: Date? = nil
            if rc == nil {
                if let ifmt = info.st_ifmt { isDir = String(cString: ifmt) == "S_IFDIR" }
                size = Int64(info.size)
                if info.modified > 0 {
                    // libimobiledevice AFC 的 modified 为纳秒；自适应秒/纳秒
                    let raw = Double(info.modified)
                    let seconds = raw > 1e12 ? raw / 1_000_000_000.0 : raw
                    if seconds > 0 { modified = Date(timeIntervalSince1970: seconds) }
                }
                afc_file_info_free(&info)
            } else {
                isDir = isDirectory(afc: afc, path: childPath)
            }
            result.append(AfcEntry(name: name, path: childPath, isDirectory: isDir,
                                   size: size, modified: modified))
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 探测是否为目录（通过 afc_get_file_info 的 st_ifmt）
    static func isDirectory(afc: OpaquePointer, path: String) -> Bool {
        var info = AfcFileInfo()
        let rc = path.withCString { cstr in
            afc_get_file_info(afc, cstr, &info)
        }
        guard rc == nil else { return false }
        defer { afc_file_info_free(&info) }
        if let p = info.st_ifmt {
            let s = String(cString: p)
            return s == "S_IFDIR"
        }
        return false
    }

    /// 读文件大小（字节）
    static func fileSize(afc: OpaquePointer, path: String) -> Int64? {
        var info = AfcFileInfo()
        let rc = path.withCString { cstr in
            afc_get_file_info(afc, cstr, &info)
        }
        defer { afc_file_info_free(&info) }
        return rc == nil ? Int64(info.size) : nil
    }

    // MARK: 隧道（拷贝自 DeviceInfoService 简化版）
    struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }
    static func pairingPath() -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }
    /// v0.3.378：建隧道入口——过**闸门**（`tunnelGate`），并把「排队等待」记下来
    /// （threadDictionary，供 runGated 把排队时长从执行时长里剥离）.
    ///
    /// 闸门保护的是**同 hostname 的 `tunnel_create_rppairing`**（项目铁律：
    /// 同一 hostname 并发建隧道会互相冲突，见 AFCService.swift:15），
    /// 因此 `tunnel_create_rppairing` 这一次 FFI 调用**必须**在锁内；
    /// 但**只锁到「隧道建好」为止**——调用方随后的 instproxy 命令（`get_apps` /
    /// `Lookup`，真正会长时间无响应的那部分）都在闸门之外执行，所以一次卡死的
    /// Lookup 不会按住闸门把别的入口一起拖死，它只占住自己那条隧道.
    static func makeTunnel() throws -> TunnelHandles {
        let waitStarted = Date()
        tunnelGate.lock()
        defer { tunnelGate.unlock() }
        let waited = Date().timeIntervalSince(waitStarted)
        if waited > 0.2 {
            recordQueueWait(waited)
            LoginLogger.shared.log("[文件共享] 隧道排队等待 \(formatSeconds(waited))s 后开始")
        }
        return try makeTunnelLocked()
    }

    private static func makeTunnelLocked() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath()) else {
            throw makeError("无配对文件")
        }
        var pairingFile: OpaquePointer?
        if let e = pairingPath().withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw makeError("读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("配对解析失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        let _ = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        var lastError: NSError?
        for _ in 0..<3 {
            var tunnel = TunnelHandles()
            let e = "EscapeSpaceFileShare".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn, pairingFile, nil, nil, &tunnel.adapter, &tunnel.handshake)
                    }
                }
            }
            if e != nil {
                lastError = makeError("建隧道失败")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            }
            if let h = tunnel.handshake { rsd_handshake_free(h) }
            if let a = tunnel.adapter { adapter_free(a) }
        }
        // v0.3.376：这条路径以前失败也不留痕，用户只能看到「一直读取中」.
        LoginLogger.shared.log("[文件共享] 建隧道失败（已重试 3 次）：\(lastError?.localizedDescription ?? "未知")")
        throw lastError ?? makeError("建隧道失败")
    }
}

struct AfcEntry: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    /// v0.3.288：文件大小（字节）与修改时间——原先列表恒显示 0（sizes 字典从未填充）
    var size: Int64 = 0
    var modified: Date? = nil
    var id: String { path }
}