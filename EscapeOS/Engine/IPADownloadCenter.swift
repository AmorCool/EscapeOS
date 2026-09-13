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
        var source: Source
        var accountEmail: String?
        var autoInstall: Bool
        var phase: Phase = .waiting
        var progress: Double = 0
        var stageText = "等待中"
        var localFileName: String?
        var error: String?
        /// 仅当 `phase == .failed` 时有意义；按**失败发生在哪个阶段**打标，不去猜错误码
        var failureStage: FailureStage? = nil

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
        var overall: Double {
            switch phase {
            case .downloading, .paused: return progress * 0.75
            case .installing: return 0.75 + progress * 0.25
            case .done: return 1
            default: return 0
            }
        }
    }

    @Published private(set) var jobs: [Job] = []

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
        change(&jobs[i])
    }

    // MARK: - 启动

    private var runner: RemoteDownloader?
    private var runningID: UUID?

    /// 免登录源：直接给直链
    @discardableResult
    func start(name: String,
               bundleId: String?,
               version: String?,
               iconURL: String?,
               remoteURL: String,
               autoInstall: Bool = true) -> UUID {
        var job = Job(name: name, bundleId: bundleId, version: version, iconURL: iconURL,
                      remoteURL: remoteURL, source: .i4Free, accountEmail: nil,
                      autoInstall: autoInstall)
        job.stageText = "排队中"
        jobs.insert(job, at: 0)
        pump()
        return job.id
    }

    /// 免登录源：只给 bundleId/名称，自己按 bundleId 去源里找包
    @discardableResult
    func startFromI4Source(name: String, bundleId: String, iconURL: String?) async -> UUID {
        var job = Job(name: name, bundleId: bundleId, version: nil, iconURL: iconURL,
                      remoteURL: nil, source: .i4Free, accountEmail: nil, autoInstall: true)
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
            $0.stageText = "排队中"
        }
        // v0.3.387：直链与版本刚开始确定 → 也立刻落盘一次（此刻台账多半还没有这一行，属 no-op；
        // 重下同版本时才真正生效）。真正写入在 `startDownload` 与 `handle` 两处。
        if let name = job(id)?.expectedFileName {
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
                      source: .appleID, accountEmail: email, autoInstall: true)
        job.stageText = "准备中"
        job.phase = .downloading
        jobs.insert(job, at: 0)
        let id = job.id

        Task.detached(priority: .userInitiated) { [item, email] in
            do {
                _ = try await AppStoreLocalInstallService.downloadAndInstall(
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
                                $0.progress = p
                                $0.stageText = "安装中"
                            }
                        }
                    },
                    onLog: { line in
                        LoginLogger.shared.log("[下载中心] \(line)", category: .appStore)
                    })
                await MainActor.run {
                    self.update(id) {
                        $0.phase = .done
                        $0.progress = 1
                        $0.stageText = "已完成"
                        $0.localFileName = "\(item.bundleId ?? item.id)-\(shownVersion ?? "x").ipa"
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
                      remoteURL: nil, source: .i4Free, accountEmail: nil, autoInstall: true)
        job.phase = .installing
        job.stageText = "安装中"
        job.localFileName = fileName
        jobs.insert(job, at: 0)
        let id = job.id
        Task.detached(priority: .userInitiated) {
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
                      remoteURL: nil, source: .i4Free, accountEmail: nil, autoInstall: true)
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
        runner?.pause()
        update(id) { $0.phase = .paused; $0.stageText = "已暂停" }
    }

    func resume(_ id: UUID) {
        guard let job = job(id), job.phase == .paused else { return }
        if runningID == id, let runner {
            runner.resume()
            update(id) { $0.phase = .downloading; $0.stageText = "下载中" }
            return
        }
        pump()
    }

    /// 取消并**删除安装包**（下载中的部分文件一并丢弃）
    func cancel(_ id: UUID) {
        guard let job = job(id) else { return }
        if runningID == id {
            runner?.abort()
            runner = nil
            runningID = nil
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

        let downloader = RemoteDownloader(
            request: req,
            onProgress: { p in
                Task { @MainActor in self.update(id) { $0.progress = p } }
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
                IPADownloadLibrary.shared.record(fileURL: dest,
                                                 displayName: current.name,
                                                 bundleId: current.bundleId,
                                                 version: current.version,
                                                 iconURL: current.iconURL,
                                                 source: current.source.rawValue,
                                                 sourceURL: current.remoteURL)
                update(id) {
                    $0.localFileName = dest.lastPathComponent
                    $0.progress = 1
                    $0.phase = current.autoInstall ? .installing : .done
                    $0.stageText = current.autoInstall ? "安装中" : "已下载"
                }
                runner = nil
                runningID = nil
                if current.autoInstall {
                    installAfterDownload(id: id, path: dest.path, fileName: dest.lastPathComponent)
                } else {
                    pump()
                }
            } catch {
                finishWithError(id, error)
            }
        case .failure(let error):
            // 暂停导致的取消不算失败
            if job(id)?.phase == .paused { runner = nil; runningID = nil; pump(); return }
            finishWithError(id, error)
        }
    }

    private func finishWithError(_ id: UUID, _ error: Error) {
        update(id) {
            // 下载链路（取流/落盘/HTTP 状态码）失败 —— 文件可能根本不完整
            $0.failureStage = .download
            $0.phase = .failed
            $0.error = error.localizedDescription
            $0.stageText = "失败"
        }
        runner = nil
        runningID = nil
        pump()
    }

    private func installAfterDownload(id: UUID, path: String, fileName: String) {
        Task.detached(priority: .userInitiated) {
            do {
                try await AppStoreInstallService.installLocalIPA(
                    path,
                    progress: { p in
                        Task { @MainActor in self.update(id) { $0.progress = p } }
                    },
                    onLog: { LoginLogger.shared.log("[下载中心] \($0)", category: .appStore) })
                IPADownloadLibrary.shared.markInstalled(fileName: fileName)
                await MainActor.run {
                    self.update(id) { $0.phase = .done; $0.progress = 1; $0.stageText = "已完成" }
                    self.runner = nil
                    self.runningID = nil
                    self.pump()
                }
            } catch {
                await MainActor.run {
                    self.update(id) {
                        // 包已经下完落地了，这里失败只可能是安装链路
                        $0.failureStage = .install
                        $0.phase = .failed
                        $0.error = error.localizedDescription
                        $0.stageText = "安装失败"
                    }
                    self.runner = nil
                    self.runningID = nil
                    self.pump()
                }
            }
        }
    }
}

// MARK: - 可暂停的下载器

/// 支持 `pause / resume / abort` 的单文件下载器（暂停用 resumeData）。
private final class RemoteDownloader: NSObject, URLSessionDownloadDelegate {

    private let request: URLRequest
    private let onProgress: (Double) -> Void
    private let onFinish: (Result<URL, Error>) -> Void

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var finished = false
    private var paused = false

    init(request: URLRequest,
         onProgress: @escaping (Double) -> Void,
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
        onProgress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
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
        if paused {
            // 暂停/取消产生的取消错误：不当作失败
            return
        }
        if let error {
            finish(.failure(error))
        }
    }
}
