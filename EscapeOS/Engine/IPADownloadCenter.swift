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
        case appleID = "Apple ID"
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
        /// v0.3.388 起 `progress` 的**口径统一**为「链路进度」：
        /// · 下载阶段写入的是「下载分数」（0~1），故这里乘 0.75（下载占链路 75%）；
        /// · 安装阶段写入的**已经是链路 0~1**（`AppStoreInstallService.installLocalIPA` 内部
        ///   把 AFC 上传 0~0.75、installd 0.75~1 拼好；下载完再装的链路由调用方折算），
        ///   所以这里直接返回 `progress` —— 再乘一次权重会把安装段压扁。
        var overall: Double {
            switch phase {
            case .downloading, .paused: return progress * 0.75
            case .installing: return progress
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

    /// 某应用当前正在进行的任务（**按 bundleId 口径**）。
    ///
    /// 适用：商店列表 / 详情页 —— 那里一行 = 一个应用，只关心「这个应用有没有在装/在下」。
    /// ⚠️ **不要**拿它给「同一个应用的多个版本行」判状态：它只认 bundleId，
    /// 会把同一个活跃任务挂到所有版本行上（v0.3.381 修的「多版本一起显示安装中」就是这个坑）。
    /// 下载管理页请用 `activeJob(fileName:bundleId:version:name:allowBundleIdFallback:)`。
    func activeJob(bundleId: String?, name: String) -> Job? {
        jobs.first { job in
            guard job.phase.isBusy else { return false }
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
    /// · 任务**自带 version** → 版本不一致就不是这一行；
    /// · 任务**version 未知**（`startFromI4Source` 的「查找安装包」阶段）→ 只能按 bundleId 认行，
    ///   而这只在**该 bundleId 在列表里只有一行**时才是安全的 —— 多行时必须传
    ///   `allowBundleIdFallback: false`，此时**不匹配任何行**（宁可少显示，不能显示错）。
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
            if let jv = job.version, !jv.isEmpty {
                // 任务自带版本：版本对不上就不是这一行
                if let v = version, !v.isEmpty, v != jv { return false }
            } else if !allowBundleIdFallback {
                // v0.3.382：任务版本未知、只能按 bundleId 认行 —— 该 bundleId 有多行时宁可不匹配
                return false
            }
            if let bid = bundleId, let jbid = job.bundleId { return bid == jbid }
            return job.name == name
        }
    }

    /// 某应用最近一次结束的任务（失败提示用，**按 bundleId 口径**）
    func lastFinishedJob(bundleId: String?, name: String) -> Job? {
        jobs.first { job in
            guard !job.phase.isBusy else { return false }
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
            if let jv = job.version, !jv.isEmpty {
                if let v = version, !v.isEmpty, v != jv { return false }
            } else if !allowBundleIdFallback {
                return false
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

    private var runner: RemoteDownloader?
    private var runningID: UUID?

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
        // ⚠️ 必须写 `self.job(id)`：本函数开头有 `var job = Job(...)`（`:242` 附近），
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
                let dest = try await AppStoreLocalInstallService.downloadAndInstall(
                    item: item,
                    email: email,
                    externalVersionID: externalVersionID,
                    downloadProgress: { p in
                        Task { @MainActor in
                            self.update(id) { $0.progress = p; $0.stageText = "下载中" }
                        }
                    },
                    installProgress: { p in
                        Task { @MainActor in
                            self.update(id) {
                                $0.phase = .installing
                                // v0.3.388：`p` 是**安装链自己的 0~1**（上传 0~0.75 + installd 0.75~1），
                                // 而这条链路的前 75% 是下载 → 折算到链路的后 25%，保证 `overall` 只增不减。
                                $0.progress = 0.75 + min(1, max(0, p)) * 0.25
                                $0.stageText = "安装中"
                            }
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
                    // ★★★ v0.3.392 根因修复：**这条链路必须自己写台账**。
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
                        $0.phase = .done
                        $0.progress = 1
                        $0.stageText = "已完成"
                        $0.localFileName = dest.lastPathComponent
                    }
                }
            } catch {
                await MainActor.run {
                    self.update(id) {
                        // v0.3.383：这条链路「下载 + 安装」在同一个调用里，按**抛错时的 phase**打标
                        // （已进 .installing 才算安装失败，否则是下载阶段没走完）
                        $0.failureStage = $0.phase == .installing ? .install : .download
                        $0.phase = .failed
                        $0.error = error.localizedDescription
                        $0.stageText = "失败"
                    }
                }
            }
        }
        return id
    }

    /// 安装库里已有的包（下载管理页用）
    @discardableResult
    func installLocal(fileName: String, displayName: String, bundleId: String?,
                      version: String?, iconURL: String?) -> UUID {
        // v0.3.383：文件不在（被外部删除/移走）→ 属「下载/文件类」，**不是**安装失败
        let path = IPADownloadLibrary.shared.path(forFileName: fileName)
        guard FileManager.default.fileExists(atPath: path) else {
            LoginLogger.shared.log("[下载中心] 本地包不存在 \(fileName)", category: .appStore)
            return recordFileFailure(fileName: fileName, displayName: displayName,
                                     bundleId: bundleId, version: version,
                                     iconURL: iconURL, reason: "文件不存在")
        }
        var job = Job(name: displayName, bundleId: bundleId, version: version, iconURL: iconURL,
                      remoteURL: nil, source: .i4Free, accountEmail: nil)
        job.phase = .installing
        job.stageText = "安装中"
        job.localFileName = fileName
        jobs.insert(job, at: 0)
        let id = job.id
        // ★★★ v0.3.413（D8 修法 B）：**安装前把台账里的 sinf 写回包内**。
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
        Task.detached(priority: .userInitiated) {
            if let sinfBase64 {
                PackageSINFWriter.writeIfNeeded(sinfBase64: sinfBase64, ipaPath: path)
            }
            do {
                try await AppStoreInstallService.installLocalIPA(
                    path,
                    progress: { p in
                        Task { @MainActor in self.update(id) { $0.progress = p } }
                    },
                    onLog: { LoginLogger.shared.log("[下载中心] \($0)", category: .appStore) })
                await MainActor.run { IPADownloadLibrary.shared.markInstalled(fileName: fileName) }
                await MainActor.run {
                    self.update(id) { $0.phase = .done; $0.progress = 1; $0.stageText = "已完成" }
                }
            } catch {
                // v0.3.382：失败原因只进日志 —— 界面行上只显示「安装失败」四个字，不把长错误塞进 UI
                LoginLogger.shared.log("[下载中心] 安装失败 \(fileName)：\(error.localizedDescription)",
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
        runner?.pause()
        resetSpeedWindow()
    }

    func resume(_ id: UUID) {
        guard let job = job(id), job.phase == .paused else { return }
        pausingIDs.remove(id)
        if runningID == id, let runner {
            runner.resume()
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
    func cancel(_ id: UUID) {
        guard let job = job(id) else { return }
        pausingIDs.remove(id)
        if runningID == id {
            runner?.abort()
            runner = nil
            runningID = nil
            resetSpeedWindow()
        }
        if let fileName = job.localFileName {
            IPADownloadLibrary.shared.remove(fileName: fileName)
        }
        jobs.removeAll { $0.id == id }
        pump()
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

    // MARK: - 调度（串行）

    private func pump() {
        guard runningID == nil,
              let next = jobs.last(where: { $0.phase == .waiting && $0.remoteURL != nil }) else { return }
        startDownload(next.id)
    }

    private func startDownload(_ id: UUID) {
        guard let job = job(id), let urlString = job.remoteURL, let url = URL(string: urlString) else { return }
        runningID = id
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
        runner = downloader
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
                                       + "storeItemId=\(writeSID ?? "nil")", category: .appStore)
                IPADownloadLibrary.shared.record(fileURL: dest,
                                                 displayName: current.name,
                                                 bundleId: current.bundleId,
                                                 version: current.version,
                                                 iconURL: current.iconURL,
                                                 source: current.source.rawValue,
                                                 // ⚠️ 必须**重新取一次** job，不能用上面的 `current`：
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
                // 只对**牛蛙源**做（爱思源的服务端包已签名、AppleID 通道由 SignatureInjector 自己写回）。
                if current.source == .niuwa, let sinf = current.sinfBase64 {
                    let ipaPath = dest.path
                    Task.detached(priority: .userInitiated) {
                        PackageSINFWriter.writeIfNeeded(sinfBase64: sinf, ipaPath: ipaPath)
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
                runner = nil
                runningID = nil
                // v0.3.412：彻底不自动装 —— 见上面 $0.phase = .done 处的说明。
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
                runner = nil; runningID = nil; pump(); return
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
        runner = nil
        runningID = nil
        pump()
    }

    // v0.3.412：彻底删除 `installAfterDownload` —— 用户明确要求"以后安装都不能自动安装"。
    // 安装入口现统一走 `IPADownloadManagerView.install(item)` → `installLocal(...)`
    // （用户点"安装"/"重装"按钮触发），不再由下载完成自动启动。
    //
    // 牛蛙源的 sinf 写入也由手动安装流程接管（见 `installLocal` 里的处理）。
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
/// ## 覆盖策略（重要）
/// 现有 ZIP 写入器（`vendor/ApplePackage/Supplement/ZipFoundationShim.swift`）只会**追加**条目、
/// **没有删除能力**，所以"覆盖"其实做不到 —— 硬写只会产出**重名条目**（更坏的包）。
/// 因此：条目**不存在**才写；**已存在**就记一行日志跳过。
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
/// ## ★★ 复现样本：**别删工作区里的 `_tmp_ssh/syllabic/` 解压目录**
/// 那个目录是牛蛙客户端（`JCD.app`，`com.dinh.syllabic` 9.0.1）的**解压产物**，
/// **包内自带 `SC_Info/`** —— 它是 v0.3.407「加密包…缺少 SC_Info/*.sinf」这个问题的
/// **唯一复现来源**：既能复现"包内没有可用 sinf"的失败，也能验证本写入器追加后的成品。
/// 删了它 = 这条链路以后**没法在本地复现/回归**（真机重下一次代价大得多）。
///
/// 每一步的结果（成功 / 跳过 / 失败原因）都写 `[下载中心]` 日志 —— 不许静默。
private enum PackageSINFWriter {

    static func writeIfNeeded(sinfBase64: String?, ipaPath: String) {
        // 1) 必须有 sinf
        guard let raw = sinfBase64?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            log("这一份没有 sinf，跳过（包内若也缺，安装会明确报「缺少 SC_Info/*.sinf」）")
            return
        }

        // 2) base64 → Data（标准 base64；失败要说清长度，便于比对真机日志）
        guard let sinf = Data(base64Encoded: raw) else {
            log("sinf base64 解码失败（\(raw.count) 字符），包内不会带 sinf")
            return
        }

        // 3) 只有加密包需要 sinf
        guard IPAPackageInspector.isFairPlayEncrypted(ipaPath: ipaPath) == true else {
            log("包未加密（cryptid=0），不需要 sinf，跳过")
            return
        }

        do {
            let archive = try ApplePackageArchive(url: URL(fileURLWithPath: ipaPath), accessMode: .update)
            // 目标路径由包内 Info.plist 的 CFBundleExecutable 决定（不硬编码、不猜）
            guard let infoEntry = archive.entries.first(where: {
                $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist")
            }) else {
                log("包内找不到 Payload/….app/Info.plist，无法定位 SC_Info（未写入）")
                return
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
                log("Info.plist 里读不到 CFBundleExecutable，无法确定 sinf 文件名（未写入）")
                return
            }

            let target = "\(appPrefix).app/SC_Info/\(exe).sinf"
            if archive[target] != nil {
                log("包内已有 \(target)；本写入器只能追加、不能替换，跳过（安装可能解密失败）")
                return
            }

            try archive.addEntry(with: target,
                                 uncompressedSize: Int64(sinf.count),
                                 compressionMethod: .deflate,
                                 provider: { (position: Int64, size: Int) -> Data in
                let start = sinf.startIndex.advanced(by: Int(position))
                return sinf.subdata(in: start ..< (start + size))
            })
            try archive.flush()
            log("已把 sinf 写进包内：\(target)（\(sinf.count) 字节）")
        } catch {
            log("写 sinf 失败（\(error.localizedDescription)），包内不会带 sinf")
        }
    }

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

    init(request: URLRequest,
         onProgress: @escaping (Int64, Int64) -> Void,
         onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.request = request
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func start() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let t = s.downloadTask(with: request)
        task = t
        t.resume()
    }

    func pause() {
        guard !finished, let t = task else { return }
        paused = true
        t.cancel(byProducingResumeData: { [weak self] data in
            self?.resumeData = data
        })
    }

    func resume() {
        guard !finished else { return }
        paused = false
        if let data = resumeData {
            let t = session?.downloadTask(withResumeData: data)
            task = t
            t?.resume()
        } else {
            // 没有续传数据（服务器不支持 Range / 刚起步）→ 重新下
            let t = session?.downloadTask(with: request)
            task = t
            t?.resume()
        }
    }

    func abort() {
        guard !finished else { return }
        finished = true
        paused = true
        task?.cancel()
        session?.finishTasksAndInvalidate()
        session = nil
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        onFinish(result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
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
        if finished { return }
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
        if paused {
            // 暂停/取消产生的取消错误：不当作失败
            return
        }
        if let error {
            finish(.failure(error))
        }
    }
}
