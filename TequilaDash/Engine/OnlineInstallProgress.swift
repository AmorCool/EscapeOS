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
/// ## 生命周期（诚实说明；v0.3.396 重写）
/// 系统何时装完**不可观测**，所以下面每一条收尾**都不是「装完了」的信号**，
/// 只是「我们的观测窗口结束了」。三条路径，都不依赖那个拿不到的事实：
/// 1. **60 秒内一个字节都没发出去** → `OnlineInstallService` 的一次性看门狗判定
///    「系统没来拉包」（设备上已装同一版本 / 系统拒装就是这个表现）→ `reset()`；
/// 2. **进入 `.installing` 后 3 分钟**（`installingWindow`）→ 本类自己到期 `reset()`。
///    从**进态那一刻**起算，所以正在传的大包不会被掐；
/// 3. **兜底**：本机服务器保活（15 分钟）到期时 `scheduleIdleReset(after:)` —— 只覆盖
///    「拉到一半卡住、但已经有字节」这种前两条都够不到的残留。
///
/// v0.3.396 之前只有第 3 条，于是「设备已安装 / 系统拒装」时进度环要**挂满 15 分钟**
/// 才自己消失 —— 用户看到的就是「一直卡在在线安装圆圈」。
///
/// ## 线程
/// 与 `IPADownloadLibrary` 同规矩：**只在主线程读写**。类的每个写方法内部会自己 hop 回主线程，
/// 所以调用方（服务器队列 / 后台下载队列）直接调即可。
/// `@unchecked Sendable`：本类刻意「所有可变状态只在主线程读写」——每个写方法
/// （`begin` / `update` / `reset` / `schedule*`）内部都经 `onMain` 收敛到主线程，
/// 因此调用方（本机服务器队列 / 后台下载队列）直接调也不会产生并发写；
/// 跨隔离域共享引用安全（这也是这里不能用 `@MainActor` 的原因：调用点是非隔离的）。
final class OnlineInstallProgress: ObservableObject, @unchecked Sendable {

    static let shared = OnlineInstallProgress()
    private init() {}

    /// v0.3.396（C 项）：进入 `.installing` 之后，进度环最多再留这么久。
    ///
    /// 为什么要有上限：这一态 App **完全观测不到**（见上文），让一个转圈无限期挂着，
    /// 用户只会认为卡死 —— 收掉比挂着诚实。
    /// 为什么从**进态**起算而不是从开会话起算：271 MB 的包在局域网里传可以超过 3 分钟，
    /// 按会话起算会把**正在传**的会话掐掉。
    static let installingWindow: TimeInterval = 3 * 60

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

    /// v0.3.396：会话号的**只读**出口 —— 给外部看门狗做守卫用。
    ///
    /// 为什么需要：`OnlineInstallService` 那个 60 秒「系统没来拉包」看门狗是在**会话外**
    /// 定时触发的，光凭 `stage`/`sentBytes` 认不出「这次的定时器还属于当前会话吗」——
    /// 同一个包连点两次时，第一次留下的定时器会把**第二次**的进度环误收掉。
    var sessionToken: Int { session }

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
            // 远端直链（observable == false）一开就是不确定态 → 同样受 3 分钟兜底约束。
            if !observable { self.scheduleInstallingReset() }
        }
    }

    /// 服务器每发完一块调进来（服务器队列；本方法自己 hop 回主线程）。
    func update(sent: UInt64, total: UInt64) {
        onMain {
            guard self.stage != .idle else { return }
            if total > 0 { self.totalBytes = total }
            if sent > self.sentBytes { self.sentBytes = sent }
            if self.totalBytes > 0, self.sentBytes >= self.totalBytes, self.stage != .installing {
                // 整个包都发给系统了 → 往后是系统自己的安装，我们看不到进度
                self.stage = .installing
                self.scheduleInstallingReset()
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

    /// v0.3.396（C 项）：进入 `.installing` 后起一次 3 分钟倒计时；到期若仍停在**同一会话**的
    /// `.installing`，就 `reset()` 收掉进度环。
    ///
    /// 两道守卫缺一不可：
    /// · **会话号** —— 期间若又 `begin` 了新 OTA（`session += 1`），这次定时器直接作废，
    ///   否则同包连点两次时，第一次留下的倒计时会把**第二次**的进度环掐掉；
    /// · **`stage == .installing`** —— 期间若已由别的路径（手动点环 / 60 秒看门狗）清空或推进，
    ///   这里什么都不做。`reset()` 本身不涨 `session`，所以这道状态守卫是必要的第二层。
    ///
    /// 只在**首次**进 `.installing` 时排一次（`update` 的转换分支带 `stage != .installing` 判断），
    /// 后续同一态的重复回调不会再顺延窗口。
    private func scheduleInstallingReset() {
        onMain {
            let token = self.session
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.installingWindow) { [weak self] in
                guard let self, self.session == token, self.stage == .installing else { return }
                self.reset()
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
