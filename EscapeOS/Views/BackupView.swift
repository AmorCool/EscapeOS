import SwiftUI

/// Shared backup progress controller used from the per-app detail screen.
final class BackupViewModel: ObservableObject {
    enum State {
        case idle
        case running(files: Int, bytes: Int64, current: String)
        case done(BackupResult)
        case failed(String)
    }

    @Published var state: State = .idle

    private let service = BackupService()
    private var cancelled = false

    var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    func start(app: InstalledApp, isContainerApp: Bool = false, onFinished: (() -> Void)? = nil) {
        cancelled = false
        state = .running(files: 0, bytes: 0, current: "开始备份…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.service.exportBackup(
                    for: app,
                    isContainerApp: isContainerApp,
                    progress: { files, bytes, current in
                        DispatchQueue.main.async {
                            self.state = .running(files: files, bytes: bytes, current: current)
                        }
                    },
                    isCancelled: { self.cancelled }
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
        cancelled = true
    }
}
