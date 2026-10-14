import Foundation
import Network

/// 「Cellular隧道支持」——蜂窝网络（无 Wi-Fi）下也能连本地隧道.
///
/// 背景：iOS 系统限制使「设备走蜂窝上网时，回环 VPN 连不上本机自建的服务端」.
/// SideStore 的 `CellularRefreshManager`（`SideStore/Core/Shortcuts/CellularRefreshManager.swift`）
/// 用 iOS 快捷指令临时关掉蜂窝数据，但那要求用户先在「快捷指令」App 里**自建**
/// `TurnOffData` / `TurnOnData` 两个快捷指令 —— 这是把本该由 App 承担的事推给用户，本仓**不采用**.
///
/// 本仓的做法：**不碰蜂窝开关，直接尝试连隧道**. 隧道连的是本地地址（`LocalDevVPN.targetIP`，
/// 默认 `10.7.0.1`），本就不依赖 Wi-Fi；蜂窝下若连不上，如实报错，不做任何「需要用户手动操作」的设计.
/// 换言之，这里只保留 SideStore 里真正有用的那部分：**判是否蜂窝 + 有界等隧道就绪**.
///
/// 与 SideStore 的逐项对应（保留部分）：
///   · `isCellularRefreshEnabled`（UserDefaults）   → `TequilaDash.CellularTunnelSupport`
///   · `minimuxer.network.isWifiSatisfied`           → `NWPathMonitor` 的 `usesInterfaceType(.wifi)`
///   · `waitForMinimuxerReady(timeout: 2.0)`         → 有界轮询（250ms 并行探多候选，见 `waitForTunnelReady`）
///   · `core.isReady(withNetworkCheck: false)`       → 本仓无「Wi-Fi 网络门」，天然等价于 `false`
///
/// ⚠️ 默认关（`UserDefaults` 无值即 `false`）⇒ 开关不开时本类全部方法都是 no-op，
/// **不改变 Wi-Fi 下既有行为**（兼容纪律，与 `TunnelManager` 同款）.
///
/// `@unchecked Sendable`：本类**没有可变存储属性**，全是无状态计算，跨隔离域共享本单例安全.
final class CellularTunnelManager: @unchecked Sendable {
    static let shared = CellularTunnelManager()
    private init() {}

    /// `UserDefaults` 键. 沿用本仓「模块.项」点号惯例（与 `TunnelManager.kindKey` 同款）.
    static let enabledKey = "TequilaDash.CellularTunnelSupport"

    /// 轮询隧道就绪的总预算（对齐 SideStore `waitForMinimuxerReady(timeout: 2.0)`）.
    private static let readyTimeout: TimeInterval = 2.0
    /// 轮询间隔（对齐 SideStore `200_000_000` ns = 200ms）.
    private static let pollInterval: TimeInterval = 0.2
    /// 单次 TCP 探测超时（对齐 SideStore `MinimuxerConstants.defaultTCPProbeTimeoutMs` = 250ms）.
    ///
    /// 为什么不沿用 `LocalDevVPN.isTunnelReachable()` 的 1 秒：1s 探测 + 0.2s 间隔，
    /// 在 2 秒预算里只能试约 2 次；换成 250ms 后同样预算能试 4~8 次，
    /// 与 SideStore 的节奏一致（隧道刚起的那零点几秒正是关键窗口）.
    private static let probeTimeout: TimeInterval = 0.25

    // MARK: - 开关与判据

    /// 用户是否开启「Cellular隧道支持」（默认关）.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// 是否处于「蜂窝模式」= 开关开 + 当前没有 Wi-Fi.
    /// 判据与 SideStore 的 `isCellularMode`（`!isWifiSatisfied`）同义.
    var isCellularMode: Bool {
        guard isEnabled else { return false }
        return !Self.isWiFiSatisfied()
    }

    // MARK: - 建隧道前

    /// 建隧道**前**调用. 蜂窝模式下：直接尝试等隧道就绪（有界轮询），**不关蜂窝**.
    ///
    /// - Returns: 是否处于蜂窝模式且隧道已就绪（`false` = 未开开关 / 有 Wi-Fi / 轮询超时）.
    ///   未就绪时**不阻断**调用方：由后续 `ensureHeartbeat()` 如实报错（见 `AppDiscovery`）.
    @discardableResult
    func prepareForTunnel() -> Bool {
        guard isCellularMode else { return false }
        let ready = waitForTunnelReady(timeout: Self.readyTimeout)
        // 诊断：把「隧道到底在不在、候选对端是哪些、本机接口长什么样」如实打进日志.
        // 对齐 SideStore `DeviceConnectionManager.refresh()` 的那段多行 debugLog
        // （probable-vpn host / derived peer IP / reachable）—— 没有这段，
        // 日志只能看到「就绪=false」，分不清「根本没有 utun」还是「utun 在但端口被拒」
        // （后者在真机日志里表现为 `connect: Connection refused (os error 61)`）.
        let peers = LocalDevVPN.candidateTunnelPeers()
        LoginLogger.shared.log(
            "[Cellular] 蜂窝模式，隧道就绪=\(ready). utun=\(LocalDevVPN.isConnected) "
            + "候选对端=[\(peers.joined(separator: ", "))] 本机接口=\(LocalDevVPN.ipv4InterfaceSummary()).",
            category: .general)
        return ready
    }

    /// 有界轮询「隧道端口（49152）可达」，最多等 `timeout`.
    ///
    /// 每一轮都调 `LocalDevVPN.isAnyCandidateReachable(timeout:)` **并行**探全部候选对端
    /// （对齐 SideStore `DeviceConnectionManager.resolveLocalVPNTunnel` 的并行 `tcpProbe`；
    /// 本机可能同时装着 Surge / Loon / Shadowrocket，各起一条 utun，
    /// 只探第一条 utun 会探错隧道）.
    func waitForTunnelReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if LocalDevVPN.isAnyCandidateReachable(timeout: Self.probeTimeout) { return true }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return false
    }

    // MARK: - Wi-Fi 判据

    /// 当前是否已满足 Wi-Fi（`NWPath.usesInterfaceType(.wifi)`）.
    ///
    /// 本仓此前**没有**任何网络路径判据（研究报告 §2.1：`NWPathMonitor` 全仓命中 0），
    /// 故这里新写一个轻量同步探测：起一个 `NWPathMonitor`，等它的**首个**路径回调
    /// （`timeout` 内），取 `usesInterfaceType(.wifi)` 后立刻 `cancel`.
    /// 取不到（超时）时**保守返回 `false`**（视作非 Wi-Fi，与 SideStore
    /// 「Wi-Fi 未满足即视为蜂窝」的语义一致）.
    static func isWiFiSatisfied(timeout: TimeInterval = 0.5) -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.ipaside.tequiladash.cellular-path")
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        monitor.pathUpdateHandler = { path in
            box.set(path.usesInterfaceType(.wifi))
            semaphore.signal()
        }
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        return box.value
    }
}

/// `NWPathMonitor` 回调与调用线程之间的同步盒子.
/// Swift 6 严格并发下不允许在 `@Sendable` 闭包里改写捕获的 `var`，故用带锁的引用类型.
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set(_ value: Bool) {
        lock.lock(); stored = value; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
