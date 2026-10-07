import Foundation

/// **统一下载 / 安装中心** —— AppStore 商店的「免登录下载」与（预留的）「Apple ID 下载」
/// 共用同一条下载管理接口，并支持**中途暂停 / 继续 / 删除安装包**。
///
/// · 队列串行执行（一次只下一个），避免多隧道并发抢占；
/// · 下载落地 `Documents/AppStoreDownloads/<bundleId>-<version>.ipa`，完成后自动登记
///   `IPADownloadLibrary`（下载管理页看到的就是它），可选自动安装（RSD 隧道）；
/// · 暂停用 `URLSessionDownloadTask.cancel(byProducingResumeData:)`，恢复用 resumeData
///   （爱思 CDN 支持 Range，实测可续传）。
@MainActor
final class IPADownloadCenter: ObservableObject {

    static let shared = IPADownloadCenter()
    private init() {}

    // MARK: - 模型

    enum Source: String {
        case i4Free = "爱思免登录"
        /// v0.3.406：免登录商店的**第二个来源**（牛蛙）。它的包得先打一发
        /// `/appstore/download` 才拿得到直链，但拿到之后走的是同一条下载/安装链路，
        /// 所以只是"来源"这一栏的口径不同 —— 以前借用 `.i4Free`，
        /// 下载管理页那一行会把牛蛙的包标成「爱思免登录」。
        case niuwa = "牛蛙免登录"
        /// v0.3.414：免登录商店的**第三个来源**（NB Pro，bundle id `com.nbmaster.app`）。
        /// 与牛蛙同构：服务端随直链下发 `sinfs[].dataHex`，安装前必须写回包内 `SC_Info/`。
        case nb = "NB免登录"
        /// 软件源管理（用户自加 URL 的**第三方软件源**）。
        ///
        /// 与前三档硬编码免登录来源是两回事：这里的源由用户在「软件源管理」里自行添加。
        /// 显示名**严禁含「牛蛙」**（用户明确划界：这不是牛蛙官方源、也不是牛蛙 AppStore）。
        /// 与既有 `.niuwa`（「牛蛙免登录」= 内置商店）在枚举值上本就可区分。
        ///
        /// 本轮边界：软件源**只负责下载**，不签名/不安装 ⇒ 下载传 `sinfBase64: nil`，
        /// 故 `needsSinfWriteback` 取 `false`（见下）。
        case thirdPartySource = "第三方软件源"
        case appleID = "Apple ID"

        /// 安装前是否需要把服务端下发的 sinf 写回包内 `SC_Info/`。
        ///
        /// 牛蛙与 NB 下发的都是 **Apple 原始加密包**（FairPlay 未剥离），
        /// 必须补上本机专用 sinf 才能过验证；爱思源的服务端包已签名、
        /// AppleID 通道由 `SignatureInjector` 自行写回，均不需要。
        var needsSinfWriteback: Bool {
            switch self {
            case .niuwa, .nb: return true
            // 软件源（`.thirdPartySource`）：本轮只下载、不签名，下载层不做 sinf 写回。
            case .i4Free, .appleID, .thirdPartySource: return false
            }
        }
    }

    /// 日志板块：按包的**来源**选分类 —— 三方软件源独立成「软件源」，其余保持既有行为（AppStore）。
    ///
    /// 只给「记录这个包从哪来 / 它的下载安装」的日志用。本机环境（隧道 / IPv4 接口）与
    /// 静态工具函数（`PackageSINFWriter`）的日志与来源无关，仍写 `.appStore`。
    /// 只从主 actor 调用（`handle` / `installLocal` 体内）；安装链在 detached 里用的是
    /// 主 actor 上预先算好的 `LoginLogger.Category`，不把 `Source` 带过隔离边界。
    private func logCategory(for source: Source) -> LoginLogger.Category {
        source == .thirdPartySource ? .signSource : .appStore
    }

    enum Phase: Equatable {
        case waiting
        case downloading
        case paused
        case installing
        case done
        case failed

        var isBusy: Bool {
            switch self {
            case .waiting, .downloading, .paused, .installing: return true
            case .done, .failed: return false
            }
        }

        var title: String {
            switch self {
            case .waiting: return "等待中"
            case .downloading: return "下载中"
            case .paused: return "已暂停"
            case .installing: return "安装中"
            case .done: return "已完成"
            case .failed: return "失败"
            }
        }
    }

    struct Job: Identifiable {

        /// v0.3.383：失败发生在**哪个阶段** —— 界面上「下载失败」与「安装失败」是两件事：
        /// 前者文件可能根本不完整/不存在，后者文件是好的、卡在安装环节。
        /// 一律报「安装失败」属于错标（性质同「多行齐显安装中」：显示错 > 显示少）。
        enum FailureStage {
            /// 下载链路（取直链/下载/落盘/文件不存在）
            case download
            /// `AppStoreInstallService.installLocalIPA` 这条安装链路
            case install
        }

        let id = UUID()
        var name: String
        var bundleId: String?
        var version: String?
        var iconURL: String?
        var remoteURL: String?
        /// v0.3.391：**App Store 商品号（`trackId`）** —— 落盘时写进台账，供「复制商店链接」用。
        /// AppleID 通道由 `startWithAppleID` 填（直接取 `AppStoreItem.id`）；其它来源为 nil。
        var storeItemId: String?
        var source: Source
        var accountEmail: String?
        /// v0.3.578：**逐行唯一的行键** —— 专治「同名多行串台」。
        ///
        /// 背景（真机 bug）：软件源列表一行 = 源 JSON 里的一条 `apps[]`，同一个 App 可以有多行
        /// （样本里 3 条 `name == "全能签"`，且该 schema 家族**整源没有 `bundleIdentifier`**）。
        /// 旧的 `activeJob(bundleId:name:)` 在 `bundleId == nil` 时退化成「同名即命中」，
        /// 于是一个进行中的任务被同时挂到全部同名行上：3 行齐显「下载中」，
        /// 而任一行点「取消 / 暂停」都作用在**同一个**真实任务上（误操作，见诊断 §1.5）。
        ///
        /// 行键取值：**源列表那一行的 `downloadURL`**（逐行唯一；`start(...)` 收到的
        /// `remoteURL` 就是它）。只有 `.thirdPartySource` 的任务带行键 ——
        /// 其它来源（爱思 / 牛蛙 / NB / AppleID）的列表是「一行一个 App」，
        /// `bundleId` 已能唯一认行，不需要行键，也就不会改变它们既有的匹配语义。
        ///
        /// **用途（v0.3.578 修订）**：行键的**匹配**由源列表视图自己做
        /// （`SignSourceAppListView.activeJob(for:)` 按 `remoteURL` 比），引擎侧**没有**按行键
        /// 认行的 API —— `activeJob(bundleId:name:)` / `lastFinishedJob(bundleId:name:)` 只把它当
        /// 「这是源列表任务」的标记：`job.rowKey == nil` 的任务才参与 bundleId / 名称口径匹配。
        /// 保留这个字段是因为那条 `guard` 是**防止源列表任务被商店页按 `name` 误认**的保险 ——
        /// 别删（删了源列表里 `name` 与某个商店页 App 同名的任务会跨页串台）。
        var rowKey: String? = nil
        /// v0.3.407：**牛蛙源**随直链一起下发的 sinf（`ba_sinfs`，base64 的标准 `.sinf` 容器）。
        ///
        /// 为什么它得跟着任务走：这类包是 Apple 的**原始加密包**，安装前必须把这份 sinf 写回
        /// `Payload/<App>.app/SC_Info/<CFBundleExecutable>.sinf`（见 `PackageSINFWriter`）。
        /// 只有 `source == .niuwa` 且非空时才用；爱思源（服务端存的是已签名包）与 AppleID 通道
        /// （`SignatureInjector` 自己会写回）都不需要，所以默认 `nil`、不传即无行为变化。
        var sinfBase64: String? = nil
        var phase: Phase = .waiting
        var progress: Double = 0
        var stageText = "等待中"
        var localFileName: String?
        var error: String?
        /// 仅当 `phase == .failed` 时有意义；按**失败发生在哪个阶段**打标，不去猜错误码
        var failureStage: FailureStage? = nil

        // MARK: v0.3.394：下载中的实时数据（界面显示「已下/总量 · 速度」用）

        /// 已收到字节（下载阶段有意义）
        var receivedBytes: Int64 = 0
        /// 包总字节 —— 来自 URLSession 的 `totalBytesExpectedToWrite`；
        /// 服务器不给 `Content-Length` 时保持 0（界面就不显示分母，只显示已下）
        var totalBytes: Int64 = 0
        /// **瞬时速度**（字节/秒）。用两次回调的**字节差 ÷ 时间差**算，再指数平滑。
        /// 刻意**不用全程平均**：掉速时全程平均会长时间停留在虚高的数字上，等于骗人。
        var speedBytesPerSecond: Double = 0
        /// 任务创建时间（合并列表里「下载中」那一行显示时间用）
        var createdAt = Date()

        /// v0.3.387：这个任务**落地后会用**的文件名（与 `startDownload` 里的 `safeName` 同源）。
        ///
        /// 「下载中」的任务还没落台账（`localFileName == nil`），但直链要**在下载时就写进台账**，
        /// 「下载中」那行弹操作面板也要能算出一个文件名 → 统一由这里出，避免两处各拼一遍。
        var expectedFileName: String {
            "\(bundleId ?? name)-\(version ?? "x").ipa"
                .replacingOccurrences(of: "/", with: "_")
        }

        /// 只有「有直链且正在下载/已暂停」才允许暂停/继续
        var canPause: Bool {
            remoteURL != nil && (phase == .downloading || phase == .paused)
        }
        /// 整条链路的进度（0~1），给界面画进度环用。
        ///
        /// v0.3.578：**修正进度模型** —— 下载与安装现在是**两条独立的任务**，不再共享一条
        /// 0~1 的链路：v0.3.412 起「下载完成不再自动安装」，`handle` 与 AppleID 通道都在
        /// 下载完成后把任务收在 `.done`（文案「已下载」），安装是用户后来点「安装」时
        /// **另起**一个 `.installing` 任务（`installLocal`）。所以：
        /// · `.downloading` / `.paused` 的 `progress` 就是**下载分数**（0~1），直接返回 ——
        ///   以前乘 0.75 是「下载占链路 75%、安装占 25%」那套已被废弃的模型留下的；
        ///   它会让下载条全程只走到 75%、完成瞬间跳到 100%，正是用户看到的
        ///   「下载完成却停在 75%」（诊断 §1.5）。
        /// · `.installing` 的 `progress` 是安装链自己的 0~1（`AppStoreInstallService.installLocalIPA`
        ///   内部把 AFC 上传 0~0.75、installd 0.75~1 拼好），直接返回。
        /// · `.done` 恒 1（终态「已下载」/「已完成」）。
        var overall: Double {
            switch phase {
            case .downloading, .paused, .installing: return progress
            case .done: return 1
            default: return 0
            }
        }
    }

    @Published private(set) var jobs: [Job] = []

    /// v0.3.394：**「该重新读台账了」的信号** —— 任务**换阶段**时 +1。
    ///
    /// 为什么需要它：下载管理页的**行内容**来自磁盘上的台账（`IPADownloadLibrary`，
    /// 它不是 `@Published`），而「装完 → 这一行从『安装中』变回『重装』」靠的是台账里的
    /// `lastInstalledAt`。不重新读，用户就得退出这一页再进来才看到变化
    /// —— 正是用户骂的「不要等到返回上一级目录才能刷新状态」。
    ///
    /// 为什么用「换阶段」而不是「`jobs` 变了」：`jobs` 在**每个下载进度回调**里都会变
    /// （每秒几十次），跟着它重读台账等于把磁盘读爆；而阶段变化一个任务只有 2~3 次，
    /// 重读的代价可以忽略。
    @Published private(set) var finishedTick = 0

    /// 正在运行的（含暂停）
    var activeJobs: [Job] { jobs.filter { $0.phase.isBusy } }
    var finishedJobs: [Job] { jobs.filter { !$0.phase.isBusy } }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// 某应用当前正在进行的任务（**行键优先 → bundleId → 名称**）。
    ///
    /// 适用：商店列表 / 详情页 —— 那里一行 = 一个应用，只关心「这个应用有没有在装/在下」。
    /// 注意： **不要**拿它给「同一个应用的多个版本行」判状态：它只认 bundleId，
    /// 会把同一个活跃任务挂到所有版本行上（v0.3.381 修的「多版本一起显示安装中」就是这个坑）。
    /// 下载管理页请用 `activeJob(fileName:bundleId:version:name:allowBundleIdFallback:)`。
    ///
    /// v0.3.578：**带行键的任务（源列表发起）不在这里认领** ——
    /// 软件源列表里 3 行同名（且该源整源没有 `bundleIdentifier`）会同时命中同一个任务
    /// （真机 bug：3 行齐显「下载中」，任一行「取消 / 暂停」都作用在那**唯一**的真实任务上）。
    /// 源列表行由它自己的 `activeJob(for:)` 按 `remoteURL`（= 该行 `downloadURL`）精确认行
    /// （`SignSourceAppListView.swift:416`），所以这里只要**排除**带行键的任务即可 ——
    /// 宁可少显示（这一行暂时不显示进度），也不能显示错、更不能让按钮作用到别的行。
    func activeJob(bundleId: String?, name: String) -> Job? {
        jobs.first { job in
            guard job.phase.isBusy, job.rowKey == nil else { return false }
            if let bid = bundleId, let jbid = job.bundleId { return bid == jbid }
            return job.name == name
        }
    }

    /// v0.3.381：某**一条已下载的条目**（含版本）当前正在进行的任务 —— **文件名优先**。
    ///
    /// 为什么不能只按 `bundleId`：同一应用常有多版本条目（ChatGPT v1.2026.224 / v230），
    /// 按 bundleId 匹配会把同一个活跃任务挂到**所有版本行**上 → 多行一起显示「安装中」（用户实测 BUG）。
    /// 库与文件本身都是按 `fileName` 记的（`IPADownloadLibrary.markInstalled(fileName:)`、
    /// `Job.localFileName`），所以按文件名匹配才对得上唯一一行。
    ///
    /// 回落规则（**只对「还没落地」的任务生效**，即 `job.localFileName == nil`）：
    /// · `allowBundleIdFallback == false` → **只按 fileName**，整个回落段直接拒绝
    ///   （v0.3.578：拦截提到版本判断之前，见下方实现处的说明）；
    /// · `allowBundleIdFallback == true` 时：任务**自带 version** 则要求版本一致；
    ///   任务 version 未知（`startFromI4Source` 的「查找安装包」阶段）则按 bundleId / 名称认行。
    ///
    /// - Parameter allowBundleIdFallback: 该 bundleId 在列表里是否唯一（唯一才允许按 bundleId 认行）。
    ///   由调用方按台账算；列表页 `IPADownloadManagerView` 会传 `false` 表示「这个 bundleId 有多行」。
    func activeJob(fileName: String?,
                   bundleId: String?,
                   version: String?,
                   name: String,
                   allowBundleIdFallback: Bool) -> Job? {
        // 1) 精确命中本行文件（含版本）
        if let fileName, !fileName.isEmpty,
           let exact = jobs.first(where: { $0.phase.isBusy && $0.localFileName == fileName }) {
            return exact
        }
        // 2) 回落：只考虑还没有文件名的进行中任务
        return jobs.first { job in
            guard job.phase.isBusy, job.localFileName == nil else { return false }
            // v0.3.578（诊断方案 C）：`allowBundleIdFallback == false` 现在**真正**意味着
            // 「只按 fileName」—— 拦截提到版本判断**之前**，整个回落段直接拒绝。
            //
            // 旧实现在 `else if !allowBundleIdFallback` 里才拦截，于是任务**自带版本**时
            // （第三方软件源 `start(version:)` 必带版本）流程会跳过那条 `else`，
            // 照样落到 `bid == jbid` / `job.name == name` —— 开关名不副实，
            // 下载管理页仍可能把同一个任务挂到多行（诊断 §1.4）。
            guard allowBundleIdFallback else { return false }
            if let jv = job.version, !jv.isEmpty {
                // 任务自带版本：版本对不上就不是这一行
                if let v = version, !v.isEmpty, v != jv { return false }
            }
            if let bid = bundleId, let jbid = job.bundleId { return bid == jbid }
            return job.name == name
        }
    }

    /// 某应用最近一次结束的任务（失败提示用，bundleId → 名称）。
    /// 口径与 `activeJob(bundleId:name:)` 完全一致（同样**排除带行键的源列表任务**）。
    func lastFinishedJob(bundleId: String?, name: String) -> Job? {
        jobs.first { job in
            guard !job.phase.isBusy, job.rowKey == nil else { return false }
            if let bid = bundleId, let jbid = job.bundleId { return bid == jbid }
            return job.name == name
        }
    }

    /// v0.3.381：某**一条已下载的条目**最近一次结束的任务 —— 与 `activeJob(fileName:…)` 同口径，
    /// 供按行提示「这条装的成/败」用（同样是文件名优先，避免多版本行互相串状态）。
    /// 回落规则与 `allowBundleIdFallback` 的含义同上。
    func lastFinishedJob(fileName: String?,
                         bundleId: String?,
                         version: String?,
                         name: String,
                         allowBundleIdFallback: Bool) -> Job? {
        if let fileName, !fileName.isEmpty,
           let exact = jobs.first(where: { !$0.phase.isBusy && $0.localFileName == fileName }) {
            return exact
        }
        return jobs.first { job in
            guard !job.phase.isBusy, job.localFileName == nil else { return false }
            // v0.3.578：与 `activeJob(fileName:…)` 同口径 —— 不允许兜底 = 只按 fileName
            guard allowBundleIdFallback else { return false }
            if let jv = job.version, !jv.isEmpty {
                if let v = version, !v.isEmpty, v != jv { return false }
            }
            if let bid = bundleId, let jbid = job.bundleId { return bid == jbid }
            return job.name == name
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let before = jobs[i].phase
        change(&jobs[i])
        // v0.3.394：阶段变了 → 台账可能已经跟着变（刚落盘 / 刚装完 / 刚失败），
        // 通知列表重读。只在这一处发信号，所有调用点自动都覆盖到。
        if jobs[i].phase != before { finishedTick &+= 1 }
    }

    // MARK: - 启动

    /// v0.3.413：**并发下载** —— 每个进行中的任务一个下载器，按 job id 索引。
    ///
    /// 以前是单个 `runner` + `runningID`（`pump()` 保证一次只下一个）。
    /// 改成字典后可以同时跑多个；上限见 `maxConcurrentDownloads`。
    private var runners: [UUID: RemoteDownloader] = [:]

    /// 同时进行的下载数上限。
    ///
    /// 用户要求「并发下载」；加上限是为了不把网络 / 内存打满 ——
    /// 每个下载各有独立的 `URLSession` 与落盘缓冲，同时太多会互相抢带宽、
    /// 也会让「下载管理」页的速度显示与进度更新变得难以阅读。
    private static let maxConcurrentDownloads = 3

    /// v0.3.398（②，第二层防护）：**「这次暂停是我发起的」的显式记录**。
    ///
    /// 为什么光有「先写 `.paused`」不够：那一层只覆盖「回调到达时状态已经写成 `.paused`」
    /// 这一种时序。回调是**跨队列**来的（`URLSession` delegate 队列 → `Task { @MainActor }`），
    /// 写入与回调谁先到并没有硬保证；而且状态位本身也分不清
    /// 「因为暂停而被取消」与「下载真的断了」。
    /// 所以再记一份**只属于主 actor 的意图**：`pause()` 一开始就插入，回调到达时读它，
    /// 与「状态何时写入」「回调何时到达」全都无关。
    ///
    /// 生命周期：`pause()` 插入；`resume()` / `cancel()` 移除（离开 `.paused` 就不再需要它，
    /// 否则之后**真**的网络错误会被误判成暂停而永远显示「已暂停」）。
    private var pausingIDs: Set<UUID> = []

    // MARK: v0.3.394：瞬时速度的采样窗口
    //
    // 下载是**串行**的（`pump()` 保证一次只下一个），所以一套窗口变量就够，不必按任务存。
    // 窗口长度 0.8s：太短数字乱跳，太长反应迟钝。

    private var speedWindowStart: Date?
    private var speedWindowBytes: Int64 = 0
    private var smoothedSpeed: Double = 0
    private static let speedWindow: TimeInterval = 0.8

    /// 把「已下字节 / 总字节」写进任务，顺便估一个**瞬时速度**。
    ///
    /// 速度 = 两次采样的字节差 ÷ 时间差，再做指数平滑（新样本 45% / 旧值 55%）：
    /// 既不跟着每个回调乱跳，掉速时也不会像全程平均那样长时间停在虚高的数字上。
    /// 采样窗口没满时沿用上一次的值（不刷新），所以界面上的数字是稳定的。
    private func applyDownloadProgress(_ id: UUID, written: Int64, expected: Int64) {
        let now = Date()
        if let start = speedWindowStart {
            let dt = now.timeIntervalSince(start)
            if dt >= Self.speedWindow {
                let delta = Double(written - speedWindowBytes)
                speedWindowStart = now
                speedWindowBytes = written
                if delta >= 0 {
                    let instant = delta / dt
                    smoothedSpeed = smoothedSpeed <= 0 ? instant : smoothedSpeed * 0.55 + instant * 0.45
                }
            }
        } else {
            speedWindowStart = now
            speedWindowBytes = written
        }
        let speed = smoothedSpeed
        update(id) { job in
            if expected > 0 { job.totalBytes = expected }
            if written > job.receivedBytes { job.receivedBytes = written }
            if expected > 0 { job.progress = min(1, max(0, Double(written) / Double(expected))) }
            if speed > 0 { job.speedBytesPerSecond = speed }
        }
    }

    /// 换任务 / 暂停 / 续传 / 结束时清掉速度窗口。
    /// 不清的话，续传后第一次采样的字节差会跨过暂停那段空档，把速度算成天文数字。
    private func resetSpeedWindow() {
        speedWindowStart = nil
        speedWindowBytes = 0
        smoothedSpeed = 0
    }

    /// 免登录源：直接给直链
    ///
    /// v0.3.406：加 `source` 参数（**默认 `.i4Free`**，既有调用点一个都不用改）——
    /// 牛蛙源要能在下载管理页显示成「牛蛙免登录」，不能借用爱思那一档。
    /// v0.3.407：加 `sinfBase64`（**默认 nil**）—— 牛蛙源把 `ba_sinfs` 一起带进来，
    /// 落盘后由 `PackageSINFWriter` 写回包内再安装；不传即与从前完全一致。
    /// v0.3.578：源列表（第三方软件源）任务**自动**带上行键 = `remoteURL`（= 该行 downloadURL）。
    /// 其它来源保持 `nil` —— 它们的列表「一行一个 App」，bundleId 已能唯一认行。
    /// 行键的**认行**由源列表视图按 `remoteURL` 自己做（`SignSourceAppListView.activeJob(for:)`）；
    /// 引擎侧只用它把源列表任务**排除**出 bundleId / 名称口径（见 `Job.rowKey`）。
    @discardableResult
    // v0.3.412：彻底去掉自动装（用户明确要求），所以不再接受也不需要 autoInstall 参数。
    // 旧的「autoInstall: Bool = true」默认参数也一并删除 —— 没有调用方再传它。
    func start(name: String,
               bundleId: String?,
               version: String?,
               iconURL: String?,
               remoteURL: String,
               source: Source = .i4Free,
               sinfBase64: String? = nil) -> UUID {
        var job = Job(name: name, bundleId: bundleId, version: version, iconURL: iconURL,
                      remoteURL: remoteURL, source: source, accountEmail: nil,
                      sinfBase64: sinfBase64)
        // 行键：源列表（第三方软件源）任务用 downloadURL（= `remoteURL`）当行键。
        // 其它来源保持 `nil` —— 它们的列表「一行一个 App」，bundleId 已能唯一认行。
        job.rowKey = source == .thirdPartySource ? remoteURL : nil
        job.stageText = "排队中"
        jobs.insert(job, at: 0)
        pump()
        return job.id
    }

    /// 免登录源：只给 bundleId/名称，自己按 bundleId 去源里找包
    ///
    /// v0.3.392：新增 `storeItemId`（App Store trackId）—— 用来给**爱思来源**的包也记上「商店链接」。
    /// 调用点手上就有（`AppStoreItem.id` 就是 trackId）；若没给，稍后用爱思返回的
    /// `I4App.itemId`（**接口里本来就带的 App Store trackId**）兜底。
    @discardableResult
    func startFromI4Source(name: String, bundleId: String, iconURL: String?,
                           storeItemId: String? = nil) async -> UUID {
        var job = Job(name: name, bundleId: bundleId, version: nil, iconURL: iconURL,
                      remoteURL: nil, source: .i4Free, accountEmail: nil)
        job.storeItemId = storeItemId
        job.stageText = "查找安装包"
        jobs.insert(job, at: 0)
        let id = job.id
        guard let hit = await SourcePackageLocator.find(bundleId: bundleId, name: name) else {
            update(id) {
                $0.phase = .failed
                // 还没拿到直链就失败了 → 属下载/取包链路，不是安装链路
                $0.failureStage = .download
                $0.stageText = "未找到安装包"
                $0.error = "免登录源里没有该应用"
            }
            return id
        }
        update(id) {
            $0.remoteURL = hit.ipaURL
            $0.version = hit.version
            // 调用点没给商品号时，用爱思接口返回的那个兜底（它就是 App Store trackId）
            if ($0.storeItemId ?? "").isEmpty { $0.storeItemId = hit.itemId }
            $0.stageText = "排队中"
        }
        // v0.3.387：直链与版本刚开始确定 → 也立刻落盘一次（此刻台账多半还没有这一行，属 no-op；
        // 重下同版本时才真正生效）。真正写入在 `startDownload` 与 `handle` 两处。
        // 注意： 必须写 `self.job(id)`：本函数开头有 `var job = Job(...)`（`:242` 附近），
        // 裸写 `job(id)` 会被那个局部变量遮蔽 →
        // `error: cannot call value of non-function type 'IPADownloadCenter.Job'`（v0.3.387 CI 实测）。
        if let name = self.job(id)?.expectedFileName {
            IPADownloadLibrary.shared.updateSourceURL(fileName: name, url: hit.ipaURL)
        }
        pump()
        return id
    }

    /// Apple ID 通道（预留）：用指定账号从 App Store 官方源取包
    ///
    /// v0.3.335：`externalVersionID` 非空时取**指定历史版本**（版本历史页用）。
    /// v0.3.578：**不再自动安装** —— 下载 + 注入 sinf 后停在「已下载」，
    /// 由用户在「下载管理」点「安装」手动装（与 v0.3.412 对免登录通道的改动对齐）。
    @discardableResult
    func startWithAppleID(item: AppStoreItem,
                          email: String,
                          externalVersionID: String? = nil,
                          displayVersion: String? = nil) -> UUID {
        let shownVersion = displayVersion ?? item.version
        var job = Job(name: item.name, bundleId: item.bundleId, version: shownVersion,
                      iconURL: item.iconSmallURL ?? item.iconURL, remoteURL: nil,
                      source: .appleID, accountEmail: email)
        // v0.3.391：**下载时就知道商品号**，直接记进任务 → 落盘时写进台账。
        // 用户要的「商店链接」= App Store 的跳转链接（`https://apps.apple.com/app/id<itemId>`），
        // 而 `AppStoreItem.id` 本身就是 `trackId` —— 根本不需要去读包内 `iTunesMetadata`
        // （重签包那个文件会被删掉，读包必然失败）。
        job.storeItemId = item.id
        job.stageText = "准备中"
        job.phase = .downloading
        jobs.insert(job, at: 0)
        let id = job.id

        Task.detached(priority: .userInitiated) { [item, email] in
            do {
                // v0.3.578：AppleID 通道**不再自动安装**（与 v0.3.412 对免登录通道的改动对齐）。
                //
                // 旧实现走 `AppStoreLocalInstallService.downloadAndInstall` —— 「下载 → 注入 sinf →
                // 安装」焊在同一个调用里，下载一完成就自动 `installLocalIPA`：无开关、无确认。
                // 而 installd 的 `Install` 对同 bundleId 的已装应用**天然覆盖**，等于**未经用户同意
                // 替换他已装的 App**（诊断：`诊断_自动安装与本地标签.md` §1.1/§4.1）。
                // v0.3.412 只删了免登录通道的自动装（那条走 `handle`），AppleID 通道不走 `handle`，
                // 于是被整条漏掉。现在只下载 + 注入 sinf，安装交给用户手动点「安装」。
                //
                // 注意： 没有 `installProgress` 回调了 —— 这条链路里**不存在**安装段。
                let dest = try await AppStoreLocalInstallService.download(
                    item: item,
                    email: email,
                    externalVersionID: externalVersionID,
                    downloadProgress: { p in
                        Task { @MainActor in
                            self.update(id) { $0.progress = p; $0.stageText = "下载中" }
                        }
                    },
                    onResolvedURL: { url in
                        // v0.3.391：Apple 一签发下载地址就挂到 job 上 ——
                        // ① `handle` 落盘时会把它写进台账（用户要的「记住这次下载的链接」）；
                        // ② 「下载中」那一行的「提取下载链接」也能立刻取到（不必等下载完）。
                        //
                        // v0.3.392：**加一行日志定案** —— 真机实测出现过「下载中能取到、
                        // 落盘后台账里却是空」的现象，而光读代码看不出原因（链路看着都对）。
                        // 这条日志 + `handle` 里那条，一次就能定位到底哪一步断掉。
                        LoginLogger.shared.log("[下载中心] 拿到直链 → 写入任务：\(String(url.prefix(56)))…",
                                               category: .appStore)
                        Task { @MainActor in
                            self.update(id) { $0.remoteURL = url }
                        }
                    },
                    onLog: { line in
                        LoginLogger.shared.log("[下载中心] \(line)", category: .appStore)
                    })
                await MainActor.run {
                    // ▸▸▸ v0.3.392 根因修复：**这条链路必须自己写台账**。
                    //
                    // AppleID 通道**不走 `startDownload` → 从不经过 `handle`**，
                    // 而写台账（含 `sourceURL` / `storeItemId`）的逻辑在 `handle` 里。
                    // 以前这里只更新内存里的 job，台账条目是事后靠**磁盘扫描现场补登记**
                    // 生成的 —— 那条路径根本不知道这两个字段，
                    // 于是「已下载」面板里「提取下载链接」和「复制商店链接」双双显示「无」。
                    // 真机实证：11:51「下载中」能提取到直链，11:52 落盘后台账里却是空。
                    let live = self.job(id)
                    IPADownloadLibrary.shared.record(
                        fileURL: dest,
                        displayName: item.name,
                        bundleId: item.bundleId,
                        version: shownVersion,
                        iconURL: item.iconSmallURL ?? item.iconURL,
                        source: live?.source.rawValue ?? Source.appleID.rawValue,
                        sourceURL: live?.remoteURL,
                        storeItemId: live?.storeItemId)
                    LoginLogger.shared.log("[下载中心] AppleID 通道落盘写台账 \(dest.lastPathComponent)："
                                           + "sourceURL=\(live?.remoteURL.map { String($0.prefix(40)) + "…" } ?? "nil") "
                                           + "storeItemId=\(live?.storeItemId ?? "nil")", category: .appStore)
                    self.update(id) {
                        // v0.3.578：**终态 = 「已下载」**，与免登录通道 `handle` 的收尾完全一致。
                        // 不再自动进入安装 ⇒ 也不会再出现「下载完成却停在 75%」那种状态：
                        // `phase == .done` ⇒ `overall == 1`（见 `Job.overall`），
                        // 进度环走满、文案「已下载」，用户在「下载管理」点该行的「安装」才装。
                        $0.phase = .done
                        $0.progress = 1
                        $0.stageText = "已下载"
                        $0.localFileName = dest.lastPathComponent
                    }
                }
            } catch {
                await MainActor.run {
                    self.update(id) {
                        // v0.3.578：这条链路只剩「下载 + 注入 sinf」，**没有安装段** ⇒
                        // 失败一律属下载链路。旧的 `$0.phase == .installing ? .install : .download`
                        // 已无意义（phase 不会再进 `.installing`），留着会把下载失败错标成「安装失败」。
                        $0.failureStage = .download
                        $0.phase = .failed
                        $0.error = error.localizedDescription
                        $0.stageText = "失败"
                    }
                    // v0.3.578：**失败必须可见** —— 以前这里只改内存状态、一行日志都不写，
                    // 真机上表现为「点了下载、什么都不发生」。与 `installLocal` / `handle` 同口径落日志。
                    LoginLogger.shared.log("[下载中心] AppleID 下载失败：\(error.localizedDescription)",
                                           category: .appStore)
                }
            }
        }
        return id
    }

    /// 安装库里已有的包（下载管理页用）
    ///
    /// `source`：这个包**从哪来** —— 决定它的安装日志写进哪个板块（三方软件源 → 「软件源」，
    /// 其余 → AppStore）。默认 `.i4Free` 与历史行为一致（旧调用方不传即零变化）。
    /// 想让三方软件源的安装日志正确分板，调用方需把台账里那条的 `source` 传进来。
    @discardableResult
    func installLocal(fileName: String, displayName: String, bundleId: String?,
                      version: String?, iconURL: String?,
                      source: Source = .i4Free) -> UUID {
        // v0.3.383：文件不在（被外部删除/移走）→ 属「下载/文件类」，**不是**安装失败
        let path = IPADownloadLibrary.shared.path(forFileName: fileName)
        guard FileManager.default.fileExists(atPath: path) else {
            LoginLogger.shared.log("[下载中心] 本地包不存在 \(fileName)",
                                   category: logCategory(for: source))
            return recordFileFailure(fileName: fileName, displayName: displayName,
                                     bundleId: bundleId, version: version,
                                     iconURL: iconURL, reason: "文件不存在")
        }
        var job = Job(name: displayName, bundleId: bundleId, version: version, iconURL: iconURL,
                      remoteURL: nil, source: source, accountEmail: nil)
        job.phase = .installing
        job.stageText = "安装中"
        job.localFileName = fileName
        jobs.insert(job, at: 0)
        let id = job.id
        // ▸▸▸ v0.3.413（D8 修法 B）：**安装前把台账里的 sinf 写回包内**。
        //
        // 这是 D8 的核心修复。牛蛙源的加密包只有包内有 `SC_Info/<CFBundleExecutable>.sinf`
        // 才能过 FairPlay 验证；而「下载管理 → 重装」走的是本方法（`installLocal`），
        // 它以前**读不到**内存里的 `Job.sinfBase64`（那个 Job 早就结束了）→ 必然报
        // 「该 IPA 是加密包，但缺少 SC_Info/*.sinf」（真机日志实证）。
        //
        // 现在 sinf 跟着台账落盘（见 `IPADownloadLibrary.record(sinfBase64:)`），
        // 这里读回来写进包内即可 —— **不需要重下**。
        // 写包是几百 MB 的 ZIP 操作，必须在 detached 里跑（不能占主线程）。
        let sinfBase64 = IPADownloadLibrary.shared.sinf(forFileName: fileName)
        // 安装日志的板块按来源**在主 actor 上先算好**，再带进后台安装链 ——
        // 避免在 detached 里引用 `Source`（跨隔离边界）。`LoginLogger.Category` 是 Sendable。
        let sourceCategory = logCategory(for: source)
        Task.detached(priority: .userInitiated) {
            // ▸▸▸ v0.3.581：**隧道探测全部降级为提示，不再有任何安装硬门**。
            //
            // 背景：安装的第一步是建 RSD 隧道，而 Rust 侧 `tunnel_create_rppairing` 的首个
            // `TcpStream::connect` **没有超时**（`rust/idevice-ffi/src/tunnel_provider.rs:873`）。
            // LocalDevVPN 未连接时目标地址是黑洞，`connect` 只能等操作系统的 TCP 建连超时 ——
            // 真机实测「下载完成 17:03:29 → 安装报错 17:08:14」（约 4m45s），期间进度、文案、
            // 错误全不动，用户看到的就是「卡住」（诊断 §1.5 / §1.6）。所以前几版在这里加探测，
            // 想把它变成「1 秒明确报错」。
            //
            // v0.3.578 曾把探测降级为「提示」，但**保留了 `!isConnected` 这个硬门**，理由写在
            // 当时的注释里：「本机连 10.7.0.x 的 utun 地址都不存在时安装必然失败」。**那个理由
            // 是错的** —— 真机探针（`P4_全能签逆向/_devicelog3/ddi_probe.txt:7` /
            // `cd_probe.txt:8`，2026-10-05）两次都出现 `isConnected=false` 而
            // `tunnel_create_rppairing(10.7.0.1:49152)` **成功**（隧道 OK）；根因是
            // `isConnected` 假设 utun 地址落在 10.7.0.x，而真机 utun 上没有该网段的 IPv4 地址。
            // 后果：连续 6 条安装全部被这条硬门误判为「隧道未连接」并直接标失败
            // （`_devicelog3/login.log:48-54`，用户「明明连了 LocalDevVPN」）。
            // ⇒ 判据是**间接推断**、且已被证伪 ⇒ 不再设硬门。`isConnected` /
            //   `isTunnelReachable` 一律只记日志、继续尝试安装，由 `IPAInstallService.createTunnel()`
            //   自己的 3 次退避重试兜底；真的连不上时，安装链会给出**真实**错误.
            if !LocalDevVPN.isConnected {
                LoginLogger.shared.log(
                    "[下载中心] 未检测到本机 utun 接口（可能未连接 LocalDevVPN），仍继续尝试安装：\(fileName).",
                    category: .appStore)
                LoginLogger.shared.log(
                    "[下载中心] 本机 IPv4 接口地址：\(LocalDevVPN.ipv4InterfaceSummary()).",
                    category: .appStore)
            }
            if !LocalDevVPN.isTunnelReachable() {
                LoginLogger.shared.log(
                    "[下载中心] 隧道预检未通过（\(LocalDevVPN.targetIP):49152），仍继续尝试安装：\(fileName).",
                    category: .appStore)
            }
            if let sinfBase64 {
                PackageSINFWriter.writeIfNeeded(sinfBase64: sinfBase64, ipaPath: path)
                // v0.3.568：写回后台账的 hasSINF 仍是「写回前」的旧快照 → 现读包内定正，
                // 否则这一行会一直显示「缺 sinf」（见 `syncLedgerSinf`）。
                await Self.syncLedgerSinf(fileName: fileName, ipaPath: path)
            }
            do {
                try await AppStoreInstallService.installLocalIPA(
                    path,
                    progress: { p in
                        Task { @MainActor in self.update(id) { $0.progress = p } }
                    },
                    onLog: { LoginLogger.shared.log("[下载中心] \($0)", category: sourceCategory) })
                await MainActor.run { IPADownloadLibrary.shared.markInstalled(fileName: fileName) }
                await MainActor.run {
                    self.update(id) { $0.phase = .done; $0.progress = 1; $0.stageText = "已完成" }
                }
            } catch {
                // v0.3.382：失败原因只进日志 —— 界面行上只显示「安装失败」四个字，不把长错误塞进 UI
                LoginLogger.shared.log("[下载中心] 安装失败 \(fileName)：\(error.localizedDescription)",
                                       category: sourceCategory)
                // v0.3.581：把本机实际的 IPv4 接口地址一并落日志（纯事实枚举）。
                // 用途：下次失败时一眼分清「真的没连隧道」还是「接口枚举/网段判断漏了」。
                LoginLogger.shared.log(
                    "[下载中心] 本机 IPv4 接口地址：\(LocalDevVPN.ipv4InterfaceSummary()).",
                    category: .appStore)
                await MainActor.run {
                    self.update(id) {
                        // 走到了这里就是安装链路本身失败（文件存在且可读）
                        $0.failureStage = .install
                        $0.phase = .failed
                        $0.error = error.localizedDescription
                        $0.stageText = "失败"
                    }
                }
            }
        }
        return id
    }

    /// v0.3.383：登记一次**文件/下载类**失败（本地包不存在等）。
    /// 文件本身不完整/不存在，和「装失败」不是一回事 —— 行上要显示「下载失败」而不是「安装失败」。
    /// 同文件的旧失败记录先清掉，避免反复点重试时把 jobs 堆满。
    @discardableResult
    func recordFileFailure(fileName: String, displayName: String, bundleId: String?,
                           version: String?, iconURL: String?, reason: String) -> UUID {
        jobs.removeAll { $0.localFileName == fileName && !$0.phase.isBusy }
        var job = Job(name: displayName, bundleId: bundleId, version: version, iconURL: iconURL,
                      remoteURL: nil, source: .i4Free, accountEmail: nil)
        job.phase = .failed
        job.failureStage = .download
        job.stageText = "文件不存在"
        job.error = reason
        job.localFileName = fileName
        jobs.insert(job, at: 0)
        return job.id
    }

    // MARK: - 暂停 / 继续 / 删除 / 重试

    func pause(_ id: UUID) {
        guard let job = job(id), job.canPause, job.phase == .downloading else { return }
        // v0.3.398（②，两层防护的第一层）：**先记意图、再写状态、最后才动下载流**。
        //
        // 原来的顺序是 `runner?.pause()` → 最后才写 `.paused`。而「暂停」是靠
        // `URLSessionDownloadTask.cancel(byProducingResumeData:)` 实现的，取消会产生一个
        // `URLError.cancelled` 回调；那个回调只要**先于**这次写入到达（异步，时机不定），
        // `handle` 的失败分支看到的就是 `phase == .downloading` → 把「暂停」判成「下载失败」
        // → 用户实测的「暂停后几率变失败、进度归 0」（`.failed` 的 `overall` 恒为 0）。
        pausingIDs.insert(id)
        update(id) { $0.phase = .paused; $0.stageText = "已暂停"; $0.speedBytesPerSecond = 0 }
        runners[id]?.pause()
        resetSpeedWindow()
    }

    func resume(_ id: UUID) {
        guard let job = job(id), job.phase == .paused else { return }
        pausingIDs.remove(id)
        if let r = runners[id] {
            r.resume()
            // v0.3.394：续传要重新起窗口（见 `resetSpeedWindow` 注释）
            resetSpeedWindow()
            update(id) { $0.phase = .downloading; $0.stageText = "下载中" }
            return
        }
        // v0.3.398：下载流已经不在了 → 当**重新排队**处理。
        //
        // 为什么不能直接 `pump()`：`pump()` 只挑 `phase == .waiting` 的任务
        // （见其注释与筛选条件），而这个任务还是 `.paused` → **永远选不中**
        // → 用户点了「继续」**永久无反应**（实测 bug）。也**不能**改 `pump()` 去收 `.paused`：
        // 那会让「暂停」的任务被自动拉起，违背暂停意图。
        // 走这条兜底说明流已断（`resumeData` 也随流一起没了）→ 只能从头下，
        // 所以把进度归零：界面显示 44% 却从头传是在骗人。
        update(id) {
            $0.phase = .waiting
            $0.stageText = "排队中"
            $0.progress = 0
            $0.receivedBytes = 0
            $0.speedBytesPerSecond = 0
        }
        pump()
    }

    /// 取消并**删除安装包**（下载中的部分文件一并丢弃）
    ///
    /// v0.3.580（一致性修复）：**返回删除结果**，不再丢弃 —— 旧实现无论删除成败都
    /// `jobs.removeAll`，台账只读（损坏）/ 文件被占用时用户以为「已取消并删除该安装包」，
    /// 磁盘上的包与台账条目却都还在 ⇒ **假成功**。现在：删除失败时**保留任务行**
    /// （进行中的收成 `.failed`，让用户看得见、能重试），调用方拿返回值按实际结果提示。
    ///
    /// `@discardableResult`：既有调用方（商店页 / 源列表 / 下载管理）不关心结果时可照旧忽略，
    /// 不必一次性改动全部 8 个调用点。
    /// 返回 `nil` 表示「没有落地文件可删」（任务还在下载、或 id 不存在）—— 此时任务照旧移除。
    @discardableResult
    func cancel(_ id: UUID) -> IPADownloadLibrary.RemoveResult? {
        guard let job = job(id) else { return nil }
        pausingIDs.remove(id)
        if let r = runners[id] {
            r.abort()
            runners[id] = nil
            resetSpeedWindow()
        }
        var result: IPADownloadLibrary.RemoveResult?
        if let fileName = job.localFileName {
            result = IPADownloadLibrary.shared.remove(fileName: fileName)
        }
        // 删除被拒（台账只读）/ 文件删不掉时，**不能把任务从 `jobs` 抹掉**：
        // 文件与台账都还在，任务凭空消失就是假成功（旧行为）。
        if result == .rejectedReadOnly || result == .fileRemovalFailed {
            // 只把**还在进行中**的任务收成 `.failed`：终态（`.done` / `.failed`）保持原样，
            // 别把一次「下载成功但没删掉」误标成下载失败。
            if job.phase.isBusy {
                update(id) {
                    $0.phase = .failed
                    $0.failureStage = .download
                    $0.stageText = "删除失败"
                    $0.error = result == .rejectedReadOnly
                        ? "下载台账文件损坏，安装包未删除"
                        : "安装包文件无法删除（可能被占用）"
                    $0.speedBytesPerSecond = 0
                }
            }
        } else {
            jobs.removeAll { $0.id == id }
        }
        pump()
        return result
    }

    /// 失败的重新来一次
    func retry(_ id: UUID) {
        guard let job = job(id), job.phase == .failed else { return }
        update(id) {
            $0.phase = .waiting
            $0.progress = 0
            // v0.3.398：已下字节也要归零。`applyDownloadProgress` 只在 `written > receivedBytes`
            // 时才写，留着上次的 120 MB 会让「进度条 0%」和「已下 120 MB/271 MB」自相矛盾，
            // 而且要等新下载超过 120 MB 才会开始动 —— 等于一直在骗人。
            $0.receivedBytes = 0
            $0.speedBytesPerSecond = 0
            $0.error = nil
            $0.failureStage = nil
            $0.stageText = "排队中"
        }
        pump()
    }

    /// 清掉已结束的记录（不动文件）
    func clearFinished() {
        jobs.removeAll { !$0.phase.isBusy }
    }

    // MARK: - 调度（v0.3.413：并发，上限 `maxConcurrentDownloads`）

    /// 把排队中的任务尽量填满并发槽。
    ///
    /// `startDownload` 会把命中的 job 改成 `.downloading`，所以下一轮
    /// `jobs.last(where: { .waiting })` 取到的是**下一个**任务 —— 不会死循环。
    private func pump() {
        while runners.count < Self.maxConcurrentDownloads,
              let next = jobs.last(where: { $0.phase == .waiting && $0.remoteURL != nil }) {
            startDownload(next.id)
        }
    }

    private func startDownload(_ id: UUID) {
        guard let job = job(id), let urlString = job.remoteURL, let url = URL(string: urlString) else { return }
        update(id) { $0.phase = .downloading; $0.stageText = "下载中" }

        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        // 爱思 CDN 要求完整浏览器 UA（短 UA 会被 403）
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        req.setValue("https://app4.i4.cn/pc_v9/index.html", forHTTPHeaderField: "Referer")

        let safeName = job.expectedFileName
        // v0.3.387：**文件名与直链这一刻都确定了 → 立刻写进台账并落盘**（用户要求「下载时就记住
        // 这一次的下载链接」）。幂等：台账里还没有这一行时是 no-op，真正落盘在 `handle` 那一次。
        // 失败/取消都**保留**已写入的值 —— 链接可能过期，但「当初从哪下的」要留住。
        IPADownloadLibrary.shared.updateSourceURL(fileName: safeName, url: urlString)

        // v0.3.394：新任务起一个新窗口
        resetSpeedWindow()
        let downloader = RemoteDownloader(
            request: req,
            onProgress: { written, expected in
                Task { @MainActor in
                    self.applyDownloadProgress(id, written: written, expected: expected)
                }
            },
            onFinish: { result in
                Task { @MainActor in self.handle(id: id, safeName: safeName, result: result) }
            })
        runners[id] = downloader
        downloader.start()
    }

    private func handle(id: UUID, safeName: String, result: Result<URL, Error>) {
        guard let current = job(id) else { return }
        switch result {
        case .success(let tmp):
            do {
                let dir = try AppStoreInstallService.downloadDirectory()
                let dest = dir.appendingPathComponent(safeName)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                // v0.3.392：落盘前先记一行「到底拿到什么」—— 真机出现过「下载中能提取、
                // 落盘后台账为空」的现象，这行 + `onResolvedURL` 那行能一次定位断点。
                let writeURL = self.job(id)?.remoteURL ?? current.remoteURL
                let writeSID = self.job(id)?.storeItemId ?? current.storeItemId
                LoginLogger.shared.log("[下载中心] 落盘写台账 \(dest.lastPathComponent)："
                                       + "sourceURL=\(writeURL.map { String($0.prefix(40)) + "…" } ?? "nil") "
                                       + "storeItemId=\(writeSID ?? "nil")",
                                       category: logCategory(for: current.source))
                IPADownloadLibrary.shared.record(fileURL: dest,
                                                 displayName: current.name,
                                                 bundleId: current.bundleId,
                                                 version: current.version,
                                                 iconURL: current.iconURL,
                                                 source: current.source.rawValue,
                                                 // 注意： 必须**重新取一次** job，不能用上面的 `current`：
                                                 // `current` 是本函数开头取的值类型快照，而直链是下载过程中
                                                 // 才由 `onResolvedURL` 回填到 job 上的（AppleID 通道尤其如此）
                                                 // → 用快照会**永远写进 nil**。
                                                 sourceURL: writeURL,
                                                 storeItemId: writeSID,
                                                 // v0.3.413（D8 修法 B）：sinf 一并落台账 ——
                                                 // 于是「下载管理 → 重装」也能把它读回来写进包内，
                                                 // 不必重下（以前 sinf 只活在内存 Job 里，重装必失败）。
                                                 sinfBase64: current.sinfBase64)
                // v0.3.412：把 sinf 写回包内 —— 这是「安装前的准备」，与「是否自动装」**无关**。
                // 牛蛙源的用户即使手动点安装也必须有 sinf 才能过 FairPlay 验证。
                // 以前 `installAfterDownload` 顺手做这一步；现在彻底不自动装，这一步独立出来：
                // 在主 actor 上 dispatch 到后台队列跑（写几百 MB 的 IPA 不能卡 UI）。
                // 只对**牛蛙源 / NB 源**做（两者都是 Apple 原始加密包 + 服务端下发 sinf）；
                // 爱思源的服务端包已签名、AppleID 通道由 SignatureInjector 自己写回，都不需要。
                if current.source.needsSinfWriteback, let sinf = current.sinfBase64 {
                    let ipaPath = dest.path
                    Task.detached(priority: .userInitiated) {
                        PackageSINFWriter.writeIfNeeded(sinfBase64: sinf, ipaPath: ipaPath)
                        // v0.3.568：写回成功后把台账 hasSINF 定正（`record()` 记的是写回前的旧值）。
                        await Self.syncLedgerSinf(fileName: safeName, ipaPath: ipaPath)
                    }
                }
                update(id) {
                    $0.localFileName = dest.lastPathComponent
                    $0.progress = 1
                    // v0.3.412：彻底去掉自动装 —— 用户明确要求「以后安装都不能自动安装
                    // 否则怕出bug」。下载完成永远停在「已下载」，由用户在「下载管理」
                    // 里点对应行的「安装」手动装。
                    $0.phase = .done
                    $0.stageText = "已下载"
                    // v0.3.394：收工了 → 速度归零、已下字节对齐总量（别留个 99.8% 的尾巴）
                    if $0.totalBytes > 0 { $0.receivedBytes = $0.totalBytes }
                    $0.speedBytesPerSecond = 0
                }
                resetSpeedWindow()
                // v0.3.390：同名文件**刚刚成功落地** → 清掉之前那条「文件不存在」之类的失败记录。
                //
                // 为什么必须清（真 bug，`dl-ui` 定位）：`recordFileFailure` 插入的失败任务**不会自己消失**，
                // 而「已下载」列表是按 `finishedJob(for:)` 判失败态的。下载成功后本条 job 会进 `.installing`
                // （`isBusy == true`）→ **不算 finished、被过滤掉** → 那一行能匹配到的**只剩那条旧失败记录**
                // → 用户会看到**刚下好的包被标成红色「下载失败」**，点它还会重试一次安装。
                // 清掉之后这一行就恢复正常（「安装」/「重装」）。
                jobs.removeAll {
                    $0.id != id && $0.localFileName == dest.lastPathComponent && $0.phase == .failed
                }
                runners[id] = nil
                // v0.3.412：彻底不自动装 —— 见上面 $0.phase = .done 处的说明。
                // v0.3.413：并发下载 —— 一个任务收工后把并发槽让给下一个排队的。
                pump()
            } catch {
                finishWithError(id, error)
            }
        case .failure(let error):
            // 暂停导致的取消不算失败。
            //
            // v0.3.398（②）两道判据，缺一不可：
            // · `pausingIDs.contains(id)` —— 主 actor 上的**显式暂停意图**，与回调到达时机无关；
            // · `job(id)?.phase == .paused` —— 状态兜底（`pause()` 已保证先写状态）。
            // 把「取消」当失败会直接毁掉这一行的可恢复性：`.failed` 不 `isBusy` →
            // 列表把它归入「已结束」，`overall` 对 `.failed` 恒返回 0 → 用户看到「暂停的 44%」
            // 变成「失败 0%」，而且再点继续也回不去（实测截图就是这两帧）。
            if pausingIDs.contains(id) || job(id)?.phase == .paused {
                runners[id] = nil; pump(); return
            }
            finishWithError(id, error)
        }
    }

    private func finishWithError(_ id: UUID, _ error: Error) {
        // v0.3.398：这条任务已经离开「暂停」语义 → 清掉可能残留的暂停意图，
        // 否则将来它真失败时会被那句 `pausingIDs.contains(id)` 误判成暂停。
        pausingIDs.remove(id)
        update(id) {
            // 下载链路（取流/落盘/HTTP 状态码）失败 —— 文件可能根本不完整
            $0.failureStage = .download
            $0.phase = .failed
            $0.error = error.localizedDescription
            $0.stageText = "失败"
            // v0.3.394：失败 → 速度归零（界面上不该挂着一个速度数字）
            $0.speedBytesPerSecond = 0
        }
        resetSpeedWindow()
        runners[id] = nil
        pump()
    }

    // v0.3.412：彻底删除 `installAfterDownload` —— 用户明确要求"以后安装都不能自动安装"。
    // 安装入口现统一走 `IPADownloadManagerView.install(item)` → `installLocal(...)`
    // （用户点"安装"/"重装"按钮触发），不再由下载完成自动启动。
    //
    // 牛蛙源的 sinf 写入也由手动安装流程接管（见 `installLocal` 里的处理）。

    /// v0.3.568：sinf 写回包内之后，把台账的 `hasSINF` / `sinfStructurallyValid` **定正**。
    ///
    /// 为什么需要：`record()` 是在「写回之前」记的（见 `handle` 的落盘段），所以走写回链路的
    /// 加密包一开始必然是 `hasSINF == false`；写回成功后若不更新，下载管理会一直显示
    /// 「缺 sinf」（本仓实测的假阳性来源）。`IPADownloadLibrary.items()` 的现算能兜住
    /// **历史**记录，这里让**新下载 / 重装**当场就正确，不必等下一次列表重算。
    ///
    /// 现读包内字节判定（不猜）：`extractSINF` 只判存在性，结构交给 `isStructurallyValidSinf`。
    ///
    /// **`nonisolated`**：本类是 `@MainActor`，静态方法默认继承主 actor 隔离；
    /// 而这里要**开包读几百 MB 的 IPA** —— 若在主 actor 上跑会卡 UI。标 `nonisolated`
    /// 让它留在调用方（detached 后台任务）的线程上，只有写台账那一步回主 actor。
    nonisolated private static func syncLedgerSinf(fileName: String, ipaPath: String) async {
        guard let sinf = IPAPackageInspector.extractSINF(ipaPath: ipaPath) else { return }
        // 三态：`unrecognized`（格式不认识）→ nil（未知），不写成 false 冻死成「sinf 异常」
        let structure = PackageSINFWriter.sinfStructure(sinf).isValid
        await MainActor.run {
            IPADownloadLibrary.shared.markSinf(fileName: fileName, structurallyValid: structure)
        }
    }
}

// MARK: - v0.3.407：把外部下发的 sinf 写回包内（牛蛙源专用）

/// 把**外部下发**的 sinf 追加进一个已经下载好的 IPA。
///
/// ## 为什么必须有这一步
/// 本项目两条安装链路的 sinf 都是**从包内读**的，不是"传参数"进去的：
/// `AppStoreInstallService.installLocalIPA`（`:111`）判到加密包后走
/// `IPAPackageInspector.extractSINF(ipaPath:)`，读的是 `Payload/<App>.app/SC_Info/<exe>.sinf`。
/// 所以「从接口拿到一份 sinf」只有**写回包内**才可能生效 —— 这正是牛蛙源
/// （`ba_ipaURL` + `ba_sinfs`）与爱思源（服务端给的已是签名包）的根本差别。
///
/// ## 为什么不用现成的 `SignatureInjector`
/// 那是 AppleID 通道用的：路径由 `SC_Info/Manifest.plist` 的 `SinfPaths` **按数组下标**配对，
/// 且**条目已存在就抛错**（`sinf file already exists`）。而这里要写的是由
/// `CFBundleExecutable` **唯一确定**的那一个路径，并且「已存在」时正确的动作是
/// **不写**（见下），所以直接调底层 ZIP 写入器更可控。
///
/// ## 覆盖策略（重要，v0.3.546 改）
/// 现有 ZIP 写入器（`vendor/ApplePackage/Supplement/ZipFoundationShim.swift`）
/// 追加条目时会重写中央目录 —— v0.3.546 起给它加了 `removeEntry(with:)`：
/// **先从中央目录摘掉同名旧条目、再追加新条目**，从而真正做到「替换」。
///
/// v0.3.546 **之前**的做法是「已存在就跳过」，那是个真 bug（真机日志实证）：
/// NB 源拿到的 Apple CDN 直链 IPA 自带一份 sinf，但那是**不绑定本机**的；
/// 跳过 = 装的是错的那份 → **装得上、一启动就崩**。
/// 现在改成替换，装的是服务端为本设备签发的那份。
///
/// ## 只做该做的事
/// · 调用方（`IPADownloadCenter.handle`）已经限定**只有牛蛙源**才传 sinf 进来
///   （爱思源与 AppleID 通道传的是 nil）；
/// · 只处理**加密包**（`cryptid == 1`）：明文/已重签的包加一个 `SC_Info/*.sinf` 反而可能
///   破坏它自己的代码签名，而它本来也不需要 sinf；
/// · 解出来的 base64 就是**标准 `.sinf` 容器**，直接写入，**不做任何包装/再加密**。
/// · v0.3.412：写入时机从「自动装之前」改为「下载落盘之后」，与「是否自动装」解耦。
///   哪怕用户手动点安装也得先有 sinf 才能过 FairPlay 验证。
///
/// ## ▸▸ 复现样本：**别删工作区里的 `_tmp_ssh/syllabic/` 解压目录**
/// 那个目录是牛蛙客户端（`JCD.app`，`com.dinh.syllabic` 9.0.1）的**解压产物**，
/// **包内自带 `SC_Info/`** —— 它是 v0.3.407「加密包…缺少 SC_Info/*.sinf」这个问题的
/// **唯一复现来源**：既能复现"包内没有可用 sinf"的失败，也能验证本写入器追加后的成品。
/// 删了它 = 这条链路以后**没法在本地复现/回归**（真机重下一次代价大得多）。
///
/// ## ▸▸ v0.3.560：整包重写替换，不再原地改 ZIP
///
/// 0.3.546 → 0.3.559 用的是「摘中央目录记录 + 在旧中央目录起点追加新条目」的原地改法，
/// 真机上加密包**一直**报 `PackageExtractionFailed (Could not extract archive)`
/// —— 从 3.5MB 的 Via 到 230MB 的 ChatGPT 全都失败，而**未加密**的包（不注入 sinf）
/// 走同一条 AFC 上传链路就能装成功。⇒ 问题出在「我们改过的那个 ZIP」本身。
///
/// 原地改法会留下两个苹果解压通道不吃的痕迹：
/// 1. 旧 sinf 的 local header + 数据块还在文件里（只摘了索引）
///    → 文件里多一个**无中央目录记录指向的 `PK\x03\x04`**；
/// 2. 新条目属性是自己拼的（`version made by = 20`、无 extra），
///    与苹果自己的条目（`0x314` = Unix + 2.0，带 extra）不同源。
///
/// 现在改为「整包重写」（`ApplePackageArchive.replaceEntries`）：逐条复制成一份新包，
/// 被替换的那条写新内容。产物与「苹果自己压的包」同构，无孤儿字节、无属性差异。
///
/// 每次写包的每一步（成功 / 跳过 / 失败原因）都写 `[下载中心]` 日志 —— 不许静默。
///
/// v0.3.568：由 `private` 改为 `internal` —— 多路径注入 `injectAllPaths(sinf:ipaPath:)`
/// 需要被 `RepairService`（共享修补线）复用，避免两套注入逻辑。`writeIfNeeded` 行为不变。
enum PackageSINFWriter {

    static func writeIfNeeded(sinfBase64: String?, ipaPath: String) {
        // 1) 必须有 sinf
        guard let raw = sinfBase64?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            log("这一份没有 sinf，跳过（包内若也缺，安装会明确报「缺少 SC_Info/*.sinf」）")
            return
        }

        // 2) 归一化成 Data，并做**结构自检**。
        //
        // 注意： 2026-10-05 真机定案：这一步**不能**只判「base64 解码有没有返回 nil」。
        // hex 字符串（NB 的 `dataHex`，以及 v0.3.562 及以前落进台账的旧值）的字符集
        // `[0-9a-f]` 恰好全在 base64 字母表内，长度又是 4 的倍数 ⇒ 解码**静默成功**，
        // 产出 1.5 倍长度的垃圾（1056 字节正确件 → 1584 字节垃圾），全程无一行报错。
        //
        // 判据因此换成**结构**：头 4 字节大端 == 实际长度，且第 5-8 字节 == `"sinf"`。
        // 顺序：先按 base64 解，结构不对再按 hex 解（兼容旧台账里的 hex 值）；
        // 两个都不对就**明确报错不写** —— 宁可装不上报「缺少 SC_Info/*.sinf」，也不写垃圾进包。
        guard let sinf = decodeSinfPayload(raw) else {
            // 注意措辞：这里只是「**本次跳过写入**」，**不等于**「包内没有 sinf」——
            // 如果包内本来就有 sinf（Apple CDN 的包都有 `SC_Info/<exe>.sinf`），它会原样保留。
            // 以前这句写成「包内不会带 sinf」，会让人以为包被写坏了，真机上就出现过这个误读。
            let head = raw.count >= 16 ? String(raw.prefix(16)) : raw
            log("sinf 载荷解不出合法结构（\(raw.count) 字符，开头 \(head)）——"
                + " base64 与 hex 两种解法的结果都不像 sinf（既非「长度+sinf+TLV」也非 SuperBlob）。"
                + "本次跳过写入，包内原有的 sinf 会保留")
            return
        }

        // 3) 只有加密包需要 sinf。**读不出加密状态 ≠ 未加密** ——
        //    `isFairPlayEncrypted` 返回 nil（包读不出 / 主二进制读不出）时，
        //    旧代码用 `== true` 判定，把「没能观察」当成了「确定未加密」并跳过写 sinf，
        //    日志还谎称「包未加密（cryptid=0）」。现在三态显式处理：
        //    只有**明确读到 cryptid=0** 才跳过；未知一律按「不排除加密」继续尝试写入。
        switch IPAPackageInspector.inspect(ipaPath: ipaPath)?.encryption {
        case .plaintext:
            log("包是明文（明确读到 cryptid=0），不需要 sinf，跳过")
            return
        case .encrypted:
            break
        case .unknown, .none:
            log("无法判定包是否加密（主二进制读不出）—— 不按「未加密」跳过，继续尝试写入 sinf")
        }

        do {
            let written = try injectAllPaths(sinf: sinf, ipaPath: ipaPath)
            log("已把 sinf 写进包内 \(written.count) 条路径（每条 \(sinf.count) 字节）："
                + written.joined(separator: ", "))
        } catch {
            log("写 sinf 失败（\(error.localizedDescription)），包内不会带 sinf")
        }
    }

    /// **把同一份 sinf 写进包内全部 `SC_Info/*.sinf` 路径**（v0.3.568：主包单路径 → 全部路径）。
    ///
    /// ## 为什么全铺（前提已按实测收窄）
    ///
    /// Apple CDN 的包对 `SC_Info` 是「每个二进制一套」（主包 + 每个 framework + 每个 appex）。
    /// **部分包**（如 XNZS）内多份 sinf 逐字节相同（一份会话 sinf 被复制到各路径）；
    /// 但**真实 App Store 包可以只有 1 份**——实测 Loon（`Loon_3.3.0_NBTool.ipa`，2026-10-05）：
    /// `Manifest.plist` 的 `SinfReplicationPaths` 列 22 条，包内实际只有 `SC_Info/Loon.sinf` 1 份。
    /// ⇒ 不能假定「一定有多份」。
    ///
    /// 旧实现只写主包一条：在**包内确实有多份 sinf 的包**上会漏掉 framework / appex 那份，
    /// 若两份不一致则 `dlopen` 时解密失败 → 崩；但在**包内仅 1 份的真实包**上，
    /// 「只写主包」与 Apple 发布内容一致，**不构成漏注**。
    /// 「全铺」的收益**未在真实多份包上验证**，且会**追加 Apple 未发布的条目**（Loon 情形下多出 21 条），
    /// 其安全性**待复核**。【实测 + 未证实】
    ///
    /// ## 目标路径来源（按优先级）
    ///
    ///   1. `Payload/<App>.app/SC_Info/Manifest.plist` 的 `SinfReplicationPaths`
    ///      （权威；缺失回退 `SinfPaths`）；
    ///   2. 兜底扫描中央目录里**所有** `Payload/…/SC_Info/*.sinf`
    ///      （Apple CDN 包不带 `Manifest.plist` 也可能有多份）；
    ///   3. **始终并入主路径** `SC_Info/<exe>.sinf`。
    ///
    /// ## 写入方式
    ///
    /// 一次整包重写批量替换（`ApplePackageArchive.replaceEntries`）—— 逐条替换
    /// 一次只能安全换一条，逐条各开一次 = N 次整包重写，性能不可接受。
    /// 写后**逐条复读**长度与内容（须重开新实例，原实例偏移已失效）；不一致则抛错，**不静默**。
    ///
    /// - Returns: 实际写入的路径（相对 IPA 根）。
    @discardableResult
    static func injectAllPaths(sinf: Data, ipaPath: String) throws -> [String] {
        let archive = try ApplePackageArchive(url: URL(fileURLWithPath: ipaPath), accessMode: .update)
        // 目标路径由包内 Info.plist 的 CFBundleExecutable 决定（不硬编码、不猜）
        guard let infoEntry = archive.entries.first(where: {
            $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist")
        }) else {
            throw SinfInjectError.noInfoPlist
        }
        var plistData = Data()
        try archive.extract(infoEntry) { plistData.append($0) }
        let plistValue = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil)
        guard let plist = plistValue,
              let info = plist as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty,
              let appPrefix = infoEntry.path.components(separatedBy: ".app/").first,
              !appPrefix.isEmpty else {
            throw SinfInjectError.noExecutable
        }

        let mainPath = "\(appPrefix).app/SC_Info/\(exe).sinf"
        // `collectSinfTargets` 会并入 `mainPath`（见其步骤 3），但**出口做签名封存过滤**
        // （步骤 4）—— 若主路径的兄弟二进制不存在（畸形包），它同样会被丢弃 ⇒ 返回集**可能为空**。
        // 故本 guard 不再是「防御性断言」而是**硬约束**：畸形包宁可拒写（fail closed），
        // 也不写出会落进 `^.*` 兜底规则、破坏代码签名的条目。
        let targets = collectSinfTargets(archive: archive, appPrefix: appPrefix, mainPath: mainPath)
        guard !targets.isEmpty else { throw SinfInjectError.noTargets }

        // **入口校验（硬约束）**：这些路径来自**不可信**的包内容（`CFBundleExecutable` /
        // `SinfReplicationPaths` / 中央目录条目名），会被 `replaceEntries` **原样**写成 ZIP
        // 条目名。若不校验，恶意包可注入 `../` 或绝对路径条目，产出一个带越界条目的 IPA。
        // 复用仓库唯一的 ZIP-slip 防线 `ArchiveEntryPath.resolve`，并补上它不覆盖的
        // NUL 与绝对路径判定。**任一非法 → 抛错，不写包**。
        for t in targets { try validateSinfTarget(t) }

        // v0.3.568：一次整包重写批量替换。
        let written = try archive.replaceEntries(with: targets, data: sinf)

        // 写后逐条复读（必须重开新实例：`replaceEntries` 后原实例的 entries 偏移已失效）
        try verifyWritten(targets: targets, sinf: sinf, ipaPath: ipaPath)
        return written
    }

    /// 收集「要写 sinf 的全部路径」（相对 IPA 根）。优先级见 `injectAllPaths`。
    ///
    /// **注意**：`SinfReplicationPaths` 是**声明清单**，不等于包内实际存在的条目
    /// （实测 Loon：声明 22 条、包内仅 1 条）。**声明的用途是「告诉系统安装期把主包那份
    /// sinf 复制到哪些路径」，不是「包里必须预先存在这些文件」** —— 所以本函数**只替换
    /// 包内已存在的条目**，不按声明追加（见出口判据 4；主路径例外）。
    private static func collectSinfTargets(archive: ApplePackageArchive,
                                           appPrefix: String,
                                           mainPath: String) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        func add(_ p: String) {
            if !p.isEmpty, seen.insert(p).inserted { paths.append(p) }
        }

        // 1) Manifest.plist 的 SinfReplicationPaths（权威；缺失回退 SinfPaths）
        let manifestPath = "\(appPrefix).app/SC_Info/Manifest.plist"
        if let mEntry = archive[manifestPath] {
            var data = Data()
            if (try? archive.extract(mEntry) { data.append($0) }) != nil,
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dict = plist as? [String: Any] {
                let rep = (dict["SinfReplicationPaths"] as? [String]) ?? []
                let single = (dict["SinfPaths"] as? [String]) ?? []
                for p in rep { add("\(appPrefix).app/\(p)") }
                if rep.isEmpty { for p in single { add("\(appPrefix).app/\(p)") } }
            }
        }

        // 2) 兜底：扫描包内**所有** `Payload/…/SC_Info/*.sinf`
        //
        // 收集条件与出口判据 `isSealingSafe`（判据 1-2）**严格对齐**：父目录名必须**恰好**
        // 是 `SC_Info`、文件名必须以**小写** `.sinf` 结尾。
        //
        // 为什么不「放宽」：本步历史上曾放宽为「忽略大小写 + 不要求位于 `SC_Info/` 目录」，
        // 但下游 `isSealingSafe` 又把父目录不是 `SC_Info` / 后缀不是小写 `.sinf` 的条目
        // **全部丢弃** ⇒ 那段放宽**从不产生任何存活目标**（死代码），其注释还会误导读者以为
        // 「非 `SC_Info` 下的 `.sinf` 也会被替换」。故收紧到与判据一致：少一次无效遍历，
        // 也不再暗示存在这样一条路径。
        //   · `.sinf` 大小写敏感：`.SINF`/`.Sinf` 不受 `CodeResources` 的 omit 规则覆盖
        //     （见判据 2 注释），收进来也必被丢弃，故此处同样只收小写。
        //   · `payload/` 前缀仍忽略大小写：`isSealingSafe` **不**校验前缀，真实条目名若为
        //     小写 `payload/…` 仍应被替换，故此处保持原判定不变。
        // 本步只收**包内已存在**的条目（遍历 `archive.entries`），因此不会引入新条目；
        // 与出口判据 4 一致。注：与上面 Manifest 那步是**并集**（不是「优先级回退」）——
        //     「只要发现多于一条 SC_Info/*.sinf 就必须全部替换」。
        for e in archive.entries {
            let comps = e.path.split(separator: "/", omittingEmptySubsequences: false)
            guard comps.count >= 2,
                  comps[comps.count - 2] == "SC_Info",
                  comps[comps.count - 1].hasSuffix(".sinf"),
                  e.path.lowercased().hasPrefix("payload/") else { continue }
            add(e.path)
        }

        // 3) 始终并入主路径
        add(mainPath)

        // 4) **签名封存过滤（判据 1-3，2026-10-05 加固）**：只保留满足三条判据的候选目标。
        //
        // ## 为什么必须过滤
        // 候选目标来自**不可信**的包内容（Manifest 的 `SinfReplicationPaths`/`SinfPaths`、
        // 中央目录条目名、`CFBundleExecutable`）。而 `_CodeSignature/CodeResources` 用
        // 「逐二进制一条 omit 规则 + `^.* = True` 兜底」决定封存：
        //   · omit 正则形如 `SC_Info/<该二进制名>\.(sinf|supp|supf|supx)$`，其中
        //     **`(sinf|supp|supf|supx)` 全小写、整个正则大小写敏感**（实测：`SC_Info/Loon.SINF`
        //     不命中 `SC_Info/Loon\.(sinf|supp|supf|supx)$`）；
        //   · 任何不匹配更具体规则的文件，都被 `^.* = True` **封存**（Loon 实测：`files2`
        //     里的 `hash`/`hash2` 就是文件内容哈希，改动即失配）。
        // ⇒ 只要写出一个「目录不是 `SC_Info` / 后缀不是小写 `.sinf` / 名字不是任何真实二进制名」
        //    的条目，它就会落进兜底规则：覆盖已封存文件 = 封存失配；新增 = 包内出现未封存内容。
        //    两者都会**破坏代码签名**。过滤即把这类目标挡在写入之前（fail closed，不静默）。
        //
        // ## 注意： 本判据是「近似」，**不是** `CodeResources` omit 规则的实现
        // 上面三条判据（父目录 `SC_Info` / 小写 `.sinf` / 兄弟二进制存在）**只是**对
        // `CodeResources` omit 规则的**结构近似** —— 本函数**从不读** `_CodeSignature/CodeResources`，
        // 更不解析其 omit 正则。为什么这样是安全的（而非偷懒）：
        //   · **Apple 原生加密包**：`cryptid=1` 由 FairPlay 打包产生，而 `SC_Info/*.sinf`
        //     正是**同一步**在资源封存之后注入 ⇒ `CodeResources` **必然**带 SC_Info omit 规则。
        //     此时近似判据与真实 omit 规则**必然等价**（`verify-omit-reachability` 实测：
        //     45 个 `cryptid=1` 包中 24 个带 `CodeResources`，**24/24 全含 omit 规则**）。
        //   · **无 `CodeResources` 的包**（NB 源 / 重签派生物 / `_work_*`）：签名已被上游剥离
        //     ⇒ **无封存**，写 sinf 本来就安全，近似判据**恰好正确**（实测：21 个 `cryptid=1`
        //     包根本没有 `CodeResources`）。
        //   · **唯一反例 `Syllabic`**（`CodeResources` 存在但无 omit 规则、31 份 sinf 全被封存）
        //     是 **`cryptid=0`** 的**解密后重签**包（解密 ⇒ cryptid=0，与「有无 omit 规则」
        //     **反相关**）⇒ `RepairService` 判明文包、**跳过注入**，本判据根本不会执行。
        // ⇒ **不要**为了「更严谨」改成真读 `CodeResources`：那会让上述 21 个无 `CodeResources`
        //    的包**全部无法修补**（净损失），而收益为 0（可达性交集为空）。
        //
        // 说明：本过滤与 `validateSinfTarget`（ZIP-slip 防线）**互补、不合并** ——
        // 后者防「条目名越界（`..`/绝对路径）」，本条防「落进签名封印规则」，两件事不同。
        func isSealingSafe(_ path: String) -> Bool {
            // 按 `/` 手工切分（不用 NSString 路径 API，避免其规范化改变语义）。
            let comps = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard comps.count >= 2 else { return false }
            let fileName = comps[comps.count - 1]
            // 判据 1：父目录名必须**恰好**是 `SC_Info`（大小写敏感；`sc_info` 不受 omit 覆盖）。
            guard comps[comps.count - 2] == "SC_Info" else { return false }
            // 判据 2：必须以**小写** `.sinf` 结尾（`.SINF`/`.Sinf` 都不受 omit 覆盖）。
            guard fileName.hasSuffix(".sinf") else { return false }
            let stem = String(fileName.dropLast(".sinf".count))
            guard !stem.isEmpty else { return false }
            // 判据 3：兄弟二进制必须存在 —— `<dir>/SC_Info/<stem>.sinf` ⇒ 归档里要有 `<dir>/<stem>`。
            // omit 规则的 `<该二进制名>` 恒等于真实二进制文件名，故此判据一次挡掉
            // 「目录对但名字错」（如 `SC_Info/evil.sinf`：没有名为 `evil` 的兄弟二进制）。
            let sibling = comps.dropLast(2).joined(separator: "/") + "/" + stem
            return archive[sibling] != nil
        }

        // 可观测性（**只记录、不阻断、不改变行为**）：本判据从不核对真实 omit 规则，
        // 一旦包内缺 `CodeResources`（或读不出），「近似 vs 真实」的差异就**不可交叉验证**。
        // 此处记一行（**一次修补仅一行**，不刷屏），使将来包形态变化时能被发现。
        let codeResourcesPath = "\(appPrefix).app/_CodeSignature/CodeResources"
        var canCrossCheckOmitRules = false
        if let crEntry = archive[codeResourcesPath] {
            canCrossCheckOmitRules = (try? archive.extract(crEntry) { _ in }) != nil
        }
        if !canCrossCheckOmitRules {
            log("包内无 _CodeSignature/CodeResources（或读不出），无法核对 omit 规则，按结构近似放行")
        }

        // 5) **存在性过滤（判据 4，2026-10-05 加固）**：只写「包内本来就有的」目标 + 主路径例外。
        //
        // ## 为什么还需要这一条（判据 1-3 不够）
        // 判据 1-3 只保证「**写的地方**签名安全」，但它**不阻止往包里塞 Apple 从没发过的条目**。
        // `SinfReplicationPaths` 是「给系统的**安装期复制指令**」，**不是包内必须存在的文件清单**
        // （实测 Loon：声明 22 条、包内实际只有 1 份 `SC_Info/Loon.sinf`）。旧行为按声明全铺
        // ⇒ 会**追加 21 条 Apple 未发布的条目**，把包改成非原生形态（且对「只发 1 份」的真实包
        // 没有已知收益）。本条只保留**包内已存在**的目标，从根上避免「凭空新增」。
        //   · 真实 Loon ⇒ 21 条 framework/appex 目标包内不存在 ⇒ 全部丢弃，只剩 1 条主路径；
        //   · `nb.ipa`（41 份 sinf 全部存在）⇒ 41 条全部保留，**「替换已存在」语义不变**。
        //
        // ## 主路径例外（豁免「存在性」，**不**豁免签名封存）
        // `mainPath`（`SC_Info/<CFBundleExecutable>.sinf`）**在通过 `isSealingSafe` 之后**，
        // **不再要求它已存在于包内**（即豁免判据 4 的「存在性」）：它是本功能的根本目的
        // —— NB 源下发的 sinf 在包内**常常缺失**，必须由我们写进去（旧日志里的「缺少
        // SC_Info/*.sinf」正是这一情形），不能因为「包内没有」就丢弃。
        // **注意：这不是「无条件保留」。** `mainPath` 仍须通过上面的 `isSealingSafe`（判据 1-3）
        // 才可能进入 `sealingSafe`，本行只豁免判据 4。对抗审计实测：恶意 `CFBundleExecutable`
        // （如 `../../evil`、`a/b`）构造出的 `mainPath` 会因父目录不是 `SC_Info`
        // （`comps[-2] != "SC_Info"`）被 `isSealingSafe` 丢弃 ⇒ fail closed。
        // 正常包里 `<exe>` 兄弟二进制恒存在，故主路径必然通过。
        let existing = Set(archive.entries.map { $0.path })
        let sealingSafe = paths.filter(isSealingSafe)
        return sealingSafe.filter { $0 == mainPath || existing.contains($0) }
    }

    /// 校验一条「将被写成 ZIP 条目名」的目标路径。**来源不可信**，必须全部过关才允许写入。
    ///
    /// 拒绝：空串 / 含 NUL / 绝对路径 / `..` / 标准化后逃逸。前两项 `ArchiveEntryPath.resolve`
    /// 不覆盖，故在此显式判定；后两项复用该函数（本仓唯一的 ZIP-slip 防线）。
    /// 路径是「ZIP 条目名（相对 IPA 根）」，故传入一个固定哨兵根，仅用于触发其越界判定。
    private static func validateSinfTarget(_ path: String) throws {
        // 绝对路径判定必须在**反斜杠归一化之后**：`\etc\passwd` 归一成 `/etc/passwd`，
        // 否则会绕过 `hasPrefix("/")`，再经 `resolve` 丢掉前导空段变成相对名 `etc/passwd`。
        // 归一化仅用于这处「空 / NUL / 绝对路径」前置判定；越界判定仍唯一交给 `ArchiveEntryPath.resolve`。
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty,
              !path.contains("\0"),
              !normalized.hasPrefix("/") else {
            throw SinfInjectError.unsafeTarget(path)
        }
        do {
            _ = try ArchiveEntryPath.resolve(path, under: "/__sinf_target_root__")
        } catch {
            throw SinfInjectError.unsafeTarget(path)
        }
    }

    /// 写后逐条复读：每条目标路径的字节必须 == 传入的 sinf。不一致 → 抛错（不静默）。
    private static func verifyWritten(targets: [String], sinf: Data, ipaPath: String) throws {
        // 注意： 必须重开新实例：`replaceEntries` 调用后原实例的 `entries` 偏移已失效。
        let verify = try ApplePackageArchive(url: URL(fileURLWithPath: ipaPath), accessMode: .read)
        var bad: [String] = []
        for p in targets {
            guard let e = verify[p] else { bad.append("\(p)（缺失）"); continue }
            var got = Data()
            try verify.extract(e) { got.append($0) }
            if got != sinf { bad.append("\(p)（\(got.count) 字节 ≠ \(sinf.count)）") }
        }
        guard bad.isEmpty else { throw SinfInjectError.verifyFailed(bad) }
        log("写后复读：\(targets.count) 条 sinf 全部 == 传入数据（\(sinf.count) 字节）")
    }

    enum SinfInjectError: LocalizedError {
        case noInfoPlist, noExecutable, noTargets, verifyFailed([String]), unsafeTarget(String)
        var errorDescription: String? {
            switch self {
            case .noInfoPlist: return "包内找不到 Payload/….app/Info.plist，无法定位 SC_Info"
            case .noExecutable: return "Info.plist 里读不到 CFBundleExecutable，无法确定 sinf 文件名"
            case .noTargets: return "没有可写入的 SC_Info 目标路径"
            case .verifyFailed(let bad): return "写后复读发现 \(bad.count) 条不一致：\(bad.joined(separator: "；"))"
            case .unsafeTarget(let p): return "拒绝写入越界条目名：\(p)"
            }
        }
    }

    /// 把 sinf 载荷归一化成 `Data`，并校验它真的是一个 sinf 容器。
    ///
    /// 输入可能是两种编码之一（历史原因）：
    ///   · **base64** —— 牛蛙的 `ba_sinfs`、AppleID 的 plist、以及修好之后的新值
    ///   · **hex**    —— NB 的 `dataHex`，以及 v0.3.562 及以前落进台账的旧值
    ///
    /// **不靠猜**：谁解出来的东西结构自洽就用谁；两个都不对返回 nil。
    /// 这样即使上游某个调用点又漏了编码转换，这里也不会把垃圾写进包内。
    private static func decodeSinfPayload(_ raw: String) -> Data? {
        if let d = Data(base64Encoded: raw), isStructurallyValidSinf(d) { return d }
        if let d = hexDecoded(raw), isStructurallyValidSinf(d) { return d }
        return nil
    }

    /// sinf 容器的结构判定（v0.3.570：三态）。
    ///
    /// **为什么必须三态**：旧实现只返回 `Bool`，于是「**格式不认识**」（可能是我们尚未见过的
    /// 第三种合法形态）与「**格式认识但结构坏了**」被压成同一个 `false` —— 前者是「不知道」，
    /// 后者是「确定坏」。v0.3.565 已经因为「只认一种格式」误杀过合法 SuperBlob；
    /// 把「不认识」当成「坏」并写进台账，就会被标签永久冻结成「sinf 异常」。
    enum SinfStructure {
        case valid          // 格式可识别且自洽
        case invalid        // 格式可识别但结构坏了（长度对不上等）
        case unrecognized   // 格式不认识 —— **未知**，不等于坏

        /// 存台账用：`unrecognized → nil`（未知），绝不当成「坏」。
        var isValid: Bool? {
            switch self {
            case .valid: return true
            case .invalid: return false
            case .unrecognized: return nil
            }
        }
    }

    /// 判定 sinf 容器结构。判据见 `isStructurallyValidSinf`。
    static func sinfStructure(_ d: Data) -> SinfStructure {
        let b = [UInt8](d)
        guard b.count >= 8 else { return .unrecognized }

        // 格式一：`{4B 长度}"sinf" + TLV`
        if Array(b[4..<8]) == Array("sinf".utf8) {
            let declared = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            return declared == b.count ? .valid : .invalid
        }

        // 格式二：SuperBlob（magic 0xFADE0CC0 + 总长 + count）
        let magic = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16)
                  | (UInt32(b[2]) << 8) | UInt32(b[3])
        if magic == 0xFADE0CC0 {
            let declared = (Int(b[4]) << 24) | (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7])
            return declared == b.count ? .valid : .invalid
        }

        return .unrecognized
    }

    /// sinf 容器结构自检。**两种真实格式都要认**，否则会误杀合法件。
    ///
    /// 格式一（本项目实测的主流形态，`SC_Info` 里常见）：
    ///   `{4B 大端总长}` + `"sinf"` + TLV 块序列（每块 `{4B tag}{4B 大端块长}{body}`）
    ///   判据：头 4 字节大端 == 实际长度
    ///
    /// 格式二（Apple 经典容器）：
    ///   `SuperBlob` = `{4B magic 0xFADE0CC0}{4B 大端总长}{4B 大端 count}` + BlobIndex[]
    ///   判据：magic 命中 **且** 长度字段 == 实际长度
    ///
    /// 注意： **不能**把 `00 00 04 30` 当固定魔数 —— 前 4 字节是**长度**。
    /// 1056 字节的合法 sinf 头是 `00 00 04 20 73 69 6e 66`；
    /// 拿 `00000430` 去校验会**误杀合法件**。
    ///
    /// 注意： 2026-10-05 修正：本函数**最初只认格式一**，结果把合法的 SuperBlob sinf
    /// 判成「不合法」⇒ 跳过写入 + 打出「缺 sinf」的日志（真机反馈的现象）。
    /// 两种格式都实测存在于 `SC_Info` 里，必须都放行。
    ///
    /// v0.3.570：本函数退化为 `sinfStructure(_:) == .valid` 的兼容壳 ——
    /// **只有确定合法才 true**；`.unrecognized`（不认识）与 `.invalid`（坏）都返回 false。
    /// 需要区分「未知」时请直接用 `sinfStructure(_:)`。
    static func isStructurallyValidSinf(_ d: Data) -> Bool {
        sinfStructure(d) == .valid
    }

    /// hex 字符串 → Data。容忍空格/换行（服务端偶尔分行发）。
    private static func hexDecoded(_ s: String) -> Data? {
        let cleaned = s.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let v = UInt8(cleaned[i..<j], radix: 16) else { return nil }
            bytes.append(v)
            i = j
        }
        return Data(bytes)
    }

    /// sinf 注入的日志固定走 `.appStore`：本类型是**静态工具**（没有 Job / 来源上下文），
    /// 且只有 `.niuwa` / `.nb` 两个来源会触发写回 —— 二者按来源映射本就落在 `.appStore`。
    private static func log(_ message: String) {
        LoginLogger.shared.log("[下载中心] sinf 注入：\(message)", category: .appStore)
    }
}

// MARK: - 可暂停的下载器

/// 支持 `pause / resume / abort` 的单文件下载器（暂停用 resumeData）。
private final class RemoteDownloader: NSObject, URLSessionDownloadDelegate {

    private let request: URLRequest
    /// v0.3.394：回调改成给**原始字节数**（已下 / 总量），不再自己折算成 0~1 ——
    /// 界面要显示「70.3 MB/271.7 MB」，速度也要靠字节差算，所以在中心那一侧统一处理。
    private let onProgress: (Int64, Int64) -> Void
    private let onFinish: (Result<URL, Error>) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var finished = false
    private var paused = false

    /// v0.3.549：`paused` / `finished` / `task` / `resumeData` 会被**两条线程**碰 ——
    /// `URLSession` 的 delegate 回调（后台队列）与主 actor 上的 `pause()` / `resume()`。
    /// 以前它们全是裸变量：暂停后进度还在走、暂停后立刻继续会丢续传数据，
    /// 都出在这个竞态上。加一把锁把读写收口.
    private let lock = NSLock()

    init(request: URLRequest,
         onProgress: @escaping (Int64, Int64) -> Void,
         onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.request = request
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    /// 读一个受锁保护的布尔量
    private func isPausedOrFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paused || finished
    }

    func start() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        lock.lock()
        session = s
        let t = s.downloadTask(with: request)
        task = t
        lock.unlock()
        t.resume()
    }

    func pause() {
        lock.lock()
        guard !finished, let t = task else { lock.unlock(); return }
        paused = true
        lock.unlock()
        // v0.3.549：`resumeData` 是**回调异步**给的，而 `resume()` 会立刻来读它 ——
        // 两条线程（delegate 队列 vs 主 actor）之间必须有锁，
        // 否则用户「暂停后马上继续」很可能读到 nil → 白白从头重下.
        //
        // 注意： `cancel(byProducingResumeData:)` **可能在当前线程同步执行回调**，
        // 所以它必须在**不持锁**的状态下调 —— 否则回调里的 `lock.lock()` 会自锁死.
        t.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            self.lock.lock(); self.resumeData = data; self.lock.unlock()
        })
    }

    func resume() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        paused = false
        let data = resumeData
        // 从暂停态恢复时，用一个全新的 task（旧的那个已被 cancel）。
        // 创建 task 与赋值在**同一段持锁区**内完成 —— 中间不留空档，
        // 否则「解锁 → 建 task → 再上锁」之间挤进一次 `pause()` 就会把新 task 漏掉.
        let t: URLSessionDownloadTask?
        if let data {
            t = session?.downloadTask(withResumeData: data)
        } else {
            // 没有续传数据（服务器不支持 Range / 刚起步）→ 重新下
            t = session?.downloadTask(with: request)
        }
        task = t
        lock.unlock()
        t?.resume()
    }

    func abort() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        paused = true
        let t = task
        let s = session
        session = nil
        lock.unlock()
        t?.cancel()
        s?.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let s = session
        session = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
        onFinish(result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // v0.3.549：**暂停后不再上报进度**.
        //
        // 「暂停」是靠 `cancel(byProducingResumeData:)` 实现的，而取消是**异步生效**的 ——
        // 在它真正落地之前，已经在网络上的数据包仍会送到这里。以前这里不看 `paused`，
        // 于是用户点完暂停之后进度条**还在往前爬**（用户报的「点击暂停下载是没有用的，
        // 我发现它会继续下载」就是这个）。这里加一道：一旦进入暂停态就不再上报，
        // 界面立刻停住；`resume()` 会把 `paused` 归 false，进度自然继续.
        guard !isPausedOrFinished() else { return }
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // v0.3.549：**暂停期间落地的文件不算下载完成**.
        //
        // `pause()` 与「下载刚好完成」这两件事可能撞在一起：`cancel(byProducingResumeData:)`
        // 对**已完成**的任务是 no-op，回调解不成 `resumeData`，而文件已经躺在 `location` 了。
        // 不挡的话这次暂停等于没发生 —— 文件照常落盘、任务照常进 `.done`，
        // 与用户「我明明按了暂停」的预期完全相反。这里直接丢弃并结束，
        // 磁盘与状态都不动（用户仍留在「已暂停」，可以再点继续）.
        if isPausedOrFinished() {
            try? FileManager.default.removeItem(at: location)
            return
        }
        // 系统随后删除该临时文件 → 先搬到稳定位置
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString).part")
        do {
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.moveItem(at: location, to: keep)
        } catch {
            finish(.failure(error))
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finish(.failure(NSError(domain: "IPADownloadCenter", code: http.statusCode,
                                    userInfo: [NSLocalizedDescriptionKey: "服务器返回 \(http.statusCode)"])))
            return
        }
        finish(.success(keep))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // v0.3.549：`finished` / `paused` 统一走锁读（与 `pause()` / `resume()` 收口）.
        lock.lock()
        let done = finished
        let isPaused = paused
        lock.unlock()
        if done { return }
        // v0.3.398：**本地取消永远不是「下载失败」** —— 这是「暂停后几率变失败」的根因层。
        //
        // 暂停是靠 `cancel(byProducingResumeData:)` 实现的，它必然产生一个 `URLError.cancelled`。
        // 只靠下面的 `paused` 挡不住：`resume()` 会把 `paused` 改回 `false`，
        // 而被取消任务的取消错误**可能晚于** `resume()` 才到达（旧任务先报错，新的还在传）
        // → 那一刻 `paused == false` → 被判成真失败。
        // `URLError.cancelled` 只可能来自**本地** `cancel`（`pause()` / `abort()`），
        // 网络层的断开/超时是 `networkConnectionLost` / `timedOut` 等**别的**码，
        // 所以这里无条件丢弃它最稳，而且不依赖任何跨线程状态的读数时序。
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        if isPaused {
            // 暂停/取消产生的取消错误：不当作失败
            return
        }
        if let error {
            finish(.failure(error))
        }
    }
}
