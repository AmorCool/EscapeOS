import Foundation
import Combine

/// v0.3.388：**在线安装（OTA / `itms-services`）的进度** —— 唯一真实来源是
/// 「本机 HTTP 服务器已经把多少字节发给了系统」。
///
/// ## 为什么只有「发包子」这一段有百分比
/// OTA 的包交给系统之后，装包的是 **iOS 自己**（itunesstored / installd / SpringBoard）：
/// App 侧没有任何回调、日志或可读状态能知道「系统装到几成了」。所以这里刻意只有两态：
/// · `.transferring`：本机服务器正在把 IPA 发给系统 → **有真实百分比**（已发字节 / 包大小）；
/// · `.installing`：包已发完，进入**系统安装** → **不确定态**（UI 画转圈），
///   **绝不假装还在走百分比** —— 那是这条链路最容易骗人的地方。
///
/// ## `Range` / 断点续传
/// 系统可能分多次带 `Range` 拉同一个包。服务器回调的是
/// **该响应的绝对起始偏移 + 本次已发字节**（见 `IPALocalHTTPServer.FilePump`），
/// 这里用 `max` 累计：百分比只增不减、也不会超 100。
///
/// ## 生命周期（诚实说明）
/// 系统何时装完**不可观测**。`.installing` 不会自己结束：
/// 由 `OnlineInstallService` 在本机服务器保活到期时调 `scheduleIdleReset(after:)` 被动收尾，
/// 或下一次 OTA 开始时被 `begin(...)` 覆盖。**这不是「装完了」的信号**，只是「观测窗口结束了」。
///
/// ## 线程
/// 与 `IPADownloadLibrary` 同规矩：**只在主线程读写**。类的每个写方法内部会自己 hop 回主线程，
/// 所以调用方（服务器队列 / 后台下载队列）直接调即可。
final class OnlineInstallProgress: ObservableObject {

    static let shared = OnlineInstallProgress()
    private init() {}

    enum Stage: Equatable {
        /// 没有进行中的 OTA
        case idle
        /// 服务器正在把 IPA 发给系统（有确定百分比）
        case transferring
        /// 包已发完，系统在装（**App 看不到进度** → 不确定态）
        case installing
    }

    /// 这次 OTA 针对的**本地包文件名**（在「已下载」列表里认行用；走远端直链时为 nil）
    @Published private(set) var fileName: String?
    /// 这次 OTA 的 bundleId（`fileName` 认不出时的兜底）
    @Published private(set) var bundleId: String?
    @Published private(set) var stage: Stage = .idle
    /// 已发给系统的字节（跨 Range 请求按绝对偏移累计）
    @Published private(set) var sentBytes: UInt64 = 0
    /// 包总大小
    @Published private(set) var totalBytes: UInt64 = 0

    /// 会话号：用于「延迟收尾」回调不误伤新会话
    private var session = 0

    /// 是否有进行中的 OTA
    var isActive: Bool { stage != .idle }

    /// 有确定进度时返回 0...1；不确定态（或一个字节都还没发）返回 nil → UI 画转圈
    var fraction: Double? {
        guard stage == .transferring, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(sentBytes) / Double(totalBytes)))
    }

    // MARK: - 认行

    /// 某个「已下载」条目是不是这次 OTA 的目标。
    ///
    /// 优先按**文件名**认（一个应用常有多版本行，按 bundleId 会一行不落全命中）；
    /// 只有在这次 OTA 没有文件名（走远端直链、不经本机服务器）时才回落 bundleId。
    func matches(fileName name: String?, bundleId bid: String?) -> Bool {
        if let mine = fileName, !mine.isEmpty {
            guard let name, !name.isEmpty else { return false }
            return mine == name
        }
        guard let mine = bundleId, !mine.isEmpty, let bid, !bid.isEmpty else { return false }
        return mine == bid
    }

    // MARK: - 写入（内部自己 hop 主线程）

    /// 开一次 OTA 会话（会覆盖上一次）。
    ///
    /// - Parameter observable: 包是否经**本机服务器**发（远端直链则为 false）。
    ///   false 时我们一个字节都量不到 → 直接进不确定态，不显示假百分比。
    func begin(fileName: String?, bundleId: String?, total: UInt64, observable: Bool) {
        onMain {
            self.session += 1
            self.fileName = fileName
            self.bundleId = bundleId
            self.sentBytes = 0
            self.totalBytes = observable ? total : 0
            self.stage = observable ? .transferring : .installing
        }
    }

    /// 服务器每发完一块调进来（服务器队列；本方法自己 hop 回主线程）。
    func update(sent: UInt64, total: UInt64) {
        onMain {
            guard self.stage != .idle else { return }
            if total > 0 { self.totalBytes = total }
            if sent > self.sentBytes { self.sentBytes = sent }
            if self.totalBytes > 0, self.sentBytes >= self.totalBytes {
                // 整个包都发给系统了 → 往后是系统自己的安装，我们看不到进度
                self.stage = .installing
            }
        }
    }

    /// 服务器保活到期 → 收掉这次会话（**不等于「装完了」**，只是不再有观测窗口）。
    /// 用会话号守卫：期间若又开了新 OTA，这次回调什么都不做。
    func scheduleIdleReset(after delay: TimeInterval) {
        onMain {
            let token = self.session
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.session == token else { return }
                self.reset()
            }
        }
    }

    /// 立刻清空（下一次 OTA 开始、或这条链路确认没跑起来时调）
    func reset() {
        onMain {
            self.fileName = nil
            self.bundleId = nil
            self.stage = .idle
            self.sentBytes = 0
            self.totalBytes = 0
        }
    }

    // MARK: - 私有

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
