import SwiftUI
import os

/// Shared backup progress controller used from the per-app detail screen.
/// Swift 6：本类是 SwiftUI 的 UI 模型，只在主线程读写 → 标 `@MainActor` 是语义正确的隔离，
/// 同时让 `self` 成为 Sendable，内层 `DispatchQueue.main.async { self.x = … }` 的
/// `sending 'self'` / `sending 'onFinished'` 诊断自然消失（该闭包本来就在主线程执行，语义不变）。
@MainActor
final class BackupViewModel: ObservableObject {
    enum State {
        case idle
        case running(files: Int, bytes: Int64, current: String)
        case done(BackupResult)
        case failed(String)
    }

    @Published var state: State = .idle

    private let service = BackupService()
    /// Swift 6：取消标志在主线程写（cancel()）、后台备份流程里轮询读（isCancelled 闭包），
    /// 用系统锁保护避免数据竞争（@MainActor 隔离无法覆盖后台轮询路径）。
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    // Swift 6：onFinished 会被后台队列闭包捕获（:47），必须标 @Sendable（CI 实测）。
    // 调用点（AppDetailView 两处）已改为只捕获 Sendable 的局部值，不捕获 View 的 self。
    func start(app: InstalledApp, isContainerApp: Bool = false, iconData: Data? = nil,
               onFinished: (@Sendable () -> Void)? = nil) {
        cancelled.withLock { $0 = false }
        state = .running(files: 0, bytes: 0, current: "开始备份…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.service.exportBackup(
                    for: app,
                    isContainerApp: isContainerApp,
                    iconData: iconData,
                    progress: { files, bytes, current in
                        DispatchQueue.main.async {
                            self.state = .running(files: files, bytes: bytes, current: current)
                        }
                    },
                    isCancelled: { self.cancelled.withLock { $0 } }
                )
                DispatchQueue.main.async {
                    self.state = .done(result)
                    onFinished?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}
