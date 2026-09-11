import Foundation
import Combine

/// v0.3.300：AppStore 商店 —— 下载/安装任务管理器
///
/// 把「源解析 → 下载 IPA → RSD 隧道安装」这条链路的**进度与日志**暴露给 UI。
/// 安装环节复用既有 `IPAInstallService`（RSD 隧道 + AFC 上传 + installation_proxy）。
@MainActor
final class AppStoreInstallManager: ObservableObject {

    static let shared = AppStoreInstallManager()
    private init() {}

    /// 任务阶段
    enum Phase: Equatable {
        case resolving          // 解析分发源 / manifest
        case downloading        // 下载 IPA
        case installing         // 隧道安装
        case done
        case failed

        var title: String {
            switch self {
            case .resolving: return "解析分发源"
            case .downloading: return "下载中"
            case .installing: return "安装中"
            case .done: return "已完成"
            case .failed: return "失败"
            }
        }

        var isRunning: Bool {
            switch self {
            case .resolving, .downloading, .installing: return true
            case .done, .failed: return false
            }
        }
    }

    /// 单个任务状态
    struct TaskState: Identifiable {
        var id: String                 // AppStoreItem.id
        var name: String
        var iconURL: String?
        var phase: Phase = .resolving
        var downloadProgress: Double = 0
        var installProgress: Double = 0
        var log: [String] = []
        var errorText: String?
        var startedAt = Date()

        /// 综合进度（0~1）
        var overall: Double {
            switch phase {
            case .resolving: return 0.02
            case .downloading: return 0.05 + downloadProgress * 0.7
            case .installing: return 0.75 + installProgress * 0.25
            case .done: return 1
            case .failed: return 0
            }
        }
    }

    @Published private(set) var tasks: [String: TaskState] = [:]

    /// 按开始时间倒序
    var orderedTasks: [TaskState] {
        tasks.values.sorted { $0.startedAt > $1.startedAt }
    }

    var runningCount: Int {
        tasks.values.filter { $0.phase.isRunning }.count
    }

    func state(for appId: String) -> TaskState? { tasks[appId] }

    func isRunning(_ appId: String) -> Bool {
        tasks[appId]?.phase.isRunning ?? false
    }

    func remove(_ appId: String) { tasks.removeValue(forKey: appId) }

    func removeFinished() {
        tasks = tasks.filter { $0.value.phase.isRunning }
    }

    private func append(_ line: String, to appId: String) {
        guard var s = tasks[appId] else { return }
        s.log.append(line)
        if s.log.count > 200 { s.log.removeFirst(s.log.count - 200) }
        tasks[appId] = s
        LoginLogger.shared.log("[AppStore] \(line)", category: .appStore)
    }

    // MARK: - 启动链路

    /// 启动「下载并安装」完整链路。
    ///
    /// `allowDowngrade = true` 时安装用 `Upgrade` 命令（installd 允许降级），
    /// 用于安装**历史版本**或覆盖更高版本的现有安装。
    func start(item: AppStoreItem, allowDowngrade: Bool = false) {
        guard !isRunning(item.id) else { return }
        let appId = item.id
        tasks[appId] = TaskState(id: appId, name: item.name, iconURL: item.iconSmallURL ?? item.iconURL,
                                 phase: .resolving)
        append("开始处理「\(item.name)」(\(appId))", to: appId)

        Task.detached(priority: .userInitiated) { [item] in
            do {
                // v0.3.301：优先走**本机 Apple ID + App Store 官方源** —— sinf 按本机身份
                // 生成，installd 能解 FairPlay 密文段（不需要解密、不需要重签）。
                // 只有没有账号时才回退到自备分发源。
                if let email = AppStoreDownloadStore.shared.selectedAccount?.email {
                    await MainActor.run {
                        self.setPhase(appId, .downloading)
                        self.append("使用本机 Apple ID「\(email)」从 App Store 下载", to: appId)
                    }
                    _ = try await AppStoreLocalInstallService.downloadAndInstall(
                        item: item,
                        email: email,
                        downloadProgress: { p in
                            Task { @MainActor in self.setDownload(appId, p) }
                        },
                        installProgress: { p in
                            Task { @MainActor in
                                self.setPhase(appId, .installing)
                                self.setInstall(appId, p)
                            }
                        },
                        onLog: { line in
                            Task { @MainActor in self.append(line, to: appId) }
                        })
                } else {
                    await MainActor.run {
                        self.setPhase(appId, .downloading)
                        self.append("未登录 Apple ID，改用自备分发源", to: appId)
                    }
                    let (payload, source) = try await AppStoreInstallService
                        .resolvePayloadUsingAnySource(item: item) { line in
                            Task { @MainActor in self.append(line, to: appId) }
                        }
                    await MainActor.run {
                        self.append("源「\(source.name)」载荷：\(payload.title ?? item.name) "
                                    + "\(payload.bundleVersion ?? "-")", to: appId)
                    }
                    let fileName = (payload.bundleIdentifier ?? item.bundleId ?? appId) + ".ipa"
                    let ipa = try await AppStoreInstallService.downloadIPA(
                        urlString: payload.ipaURL,
                        suggestedName: fileName,
                        progress: { p in
                            Task { @MainActor in self.setDownload(appId, p) }
                        },
                        onLog: { line in
                            Task { @MainActor in self.append(line, to: appId) }
                        })
                    await MainActor.run { self.setPhase(appId, .installing) }
                    try await AppStoreInstallService.installLocalIPA(
                        ipa.path,
                        allowDowngrade: allowDowngrade,
                        progress: { p in
                            Task { @MainActor in self.setInstall(appId, p) }
                        },
                        onLog: { line in
                            Task { @MainActor in self.append(line, to: appId) }
                        })
                }

                await MainActor.run {
                    if var s = self.tasks[appId] {
                        s.phase = .done
                        s.downloadProgress = 1
                        s.installProgress = 1
                        self.tasks[appId] = s
                    }
                    self.append("「\(item.name)」安装完成", to: appId)
                }
            } catch {
                await MainActor.run {
                    if var s = self.tasks[appId] {
                        s.phase = .failed
                        s.errorText = error.localizedDescription
                        self.tasks[appId] = s
                    }
                    self.append("失败：\(error.localizedDescription)", to: appId)
                }
            }
        }
    }

    // MARK: - 状态更新

    private func setPhase(_ appId: String, _ phase: Phase) {
        guard var s = tasks[appId] else { return }
        s.phase = phase
        tasks[appId] = s
    }

    private func setDownload(_ appId: String, _ p: Double) {
        guard var s = tasks[appId] else { return }
        s.downloadProgress = p
        tasks[appId] = s
    }

    private func setInstall(_ appId: String, _ p: Double) {
        guard var s = tasks[appId] else { return }
        s.installProgress = p
        tasks[appId] = s
    }
}
