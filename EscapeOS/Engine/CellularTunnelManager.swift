import Foundation
import Network
import UIKit

/// 「Cellular隧道支持」——移植自 SideStore 的 `CellularRefreshManager`
/// （`SideStore/Core/Shortcuts/CellularRefreshManager.swift`，Created by Magesh K on 4/9/26）.
///
/// 背景（研究报告《研究_SideStore蜂窝刷新.md》§2.4）：iOS 系统限制使「设备走蜂窝上网时，
/// 回环 VPN 连不上本机自建的服务端」. SideStore 的做法**不是**让隧道改走蜂窝，而是用
/// iOS 快捷指令**临时关掉蜂窝数据**，把网络逼成「离线 + 只有回环 VPN」，建完隧道再开回蜂窝.
///
/// 与 SideStore 的逐项对应：
///   · `isCellularRefreshEnabled`（UserDefaults）   → `EscapeOS.CellularTunnelSupport`
///   · `minimuxer.network.isWifiSatisfied`           → `NWPathMonitor` 的 `usesInterfaceType(.wifi)`
///   · `waitForMinimuxerReady(timeout: 2.0)`         → `LocalDevVPN.isTunnelReachable()` 有界轮询
///   · `TurnOffData` / `TurnOnData` 快捷指令          → 同款 `shortcuts://run-shortcut?name=`
///   · PR #1218 的 `if #available(iOS 26.4, *)` 分界  → `isSupported`
///
/// ⚠️ 诚实声明（勿删）：**iOS 没有公开 API 能在 App 内编程开关蜂窝数据**（本轮已查证），
/// 故只能走 `Shortcuts` URL scheme；且 SideStore 维护者明确「iOS >= 26.4 cellular do not work」
/// （Issue #1389），故 `isSupported` 在 26.4+ 恒 `false`（不假装能用）.
///
/// ⚠️ 默认关（`UserDefaults` 无值即 `false`）⇒ 开关不开时本类全部方法都是 no-op，
/// **不改变 Wi-Fi 下既有行为**（兼容纪律，与 `TunnelManager` 同款）.
///
/// `@unchecked Sendable`：唯一可变状态 `turnedOffData` 的读写都在 `lock`（`NSLock`）保护下；
/// 其余全是无状态计算，跨隔离域共享本单例安全（与 `WiFiPowerBridge` 同款处理）.
final class CellularTunnelManager: @unchecked Sendable {
    static let shared = CellularTunnelManager()
    private init() {}

    /// `UserDefaults` 键. 沿用本仓「模块.项」点号惯例（与 `TunnelManager.kindKey` 同款）.
    static let enabledKey = "EscapeOS.CellularTunnelSupport"

    /// 关 / 开蜂窝的快捷指令名（与 SideStore 同名；用户需在「快捷指令」App 里自建）.
    static let turnOffDataShortcut = "TurnOffData"
    static let turnOnDataShortcut = "TurnOnData"

    /// 关蜂窝后 / 开蜂窝后的等待（对齐 SideStore `defaultTurnOffDataBaseDelay` = 1.0s）.
    private static let baseDelay: TimeInterval = 1.0
    /// 轮询隧道就绪的超时（对齐 SideStore `waitForMinimuxerReady(timeout: 2.0)`）.
    private static let readyTimeout: TimeInterval = 2.0
    /// 轮询间隔（对齐 SideStore `200_000_000` ns = 200ms）.
    private static let pollInterval: TimeInterval = 0.2

    private let lock = NSLock()
    private var turnedOffData = false

    // MARK: - 开关与判据

    /// 用户是否开启「Cellular隧道支持」（默认关）.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// 本 iOS 版本是否支持. SideStore 维护者：iOS >= 26.4 的 cellular refresh/shortcuts
    /// 「do not work」并**永久关闭**（Issue #1389）⇒ 这里同样在 26.4+ 返回 `false`.
    var isSupported: Bool {
        if #available(iOS 26.4, *) { return false }
        return true
    }

    /// 是否处于「蜂窝模式」= 版本支持 + 开关开 + 当前没有 Wi-Fi.
    /// 判据与 SideStore 的 `isCellularMode`（`!isWifiSatisfied`）同义.
    var isCellularMode: Bool {
        guard isSupported, isEnabled else { return false }
        return !Self.isWiFiSatisfied()
    }

    // MARK: - 建隧道前 / 后

    /// 建隧道**前**调用. 蜂窝模式下：关蜂窝 → 等基带切换 → 轮询隧道就绪.
    ///
    /// - Returns: 是否真的执行了「关蜂窝」（`false` = 未开开关 / 有 Wi-Fi / 已在关闭态 /
    ///   快捷指令未受理 / iOS 26.4+）.
    @discardableResult
    func prepareForTunnel() -> Bool {
        guard isCellularMode else { return false }
        guard !didTurnOffData else { return false }
        guard runShortcut(Self.turnOffDataShortcut) else {
            LoginLogger.shared.log("[Cellular] TurnOffData 快捷指令未受理，跳过关蜂窝.",
                                   category: .general)
            return false
        }
        setTurnedOffData(true)
        Thread.sleep(forTimeInterval: Self.baseDelay)
        let ready = waitForTunnelReady(timeout: Self.readyTimeout)
        LoginLogger.shared.log("[Cellular] 已关蜂窝，隧道就绪=\(ready).", category: .general)
        return true
    }

    /// 建隧道**后**（无论成功失败）调用，恢复蜂窝. 只在 `prepareForTunnel` 真的关过时才动作.
    @discardableResult
    func restoreAfterTunnel() -> Bool {
        guard didTurnOffData else { return false }
        let ok = runShortcut(Self.turnOnDataShortcut)
        if ok { setTurnedOffData(false) }
        Thread.sleep(forTimeInterval: Self.baseDelay)
        return ok
    }

    /// 有界轮询「隧道端口（49152）可达」，最多等 `timeout`.
    /// 复用 `LocalDevVPN.isTunnelReachable()`（探测 `10.7.0.1:49152`，其自身 1s 超时）.
    func waitForTunnelReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if LocalDevVPN.isTunnelReachable() { return true }
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
    /// 取不到（超时）时**保守返回 `false`**（视作非 Wi-Fi ⇒ 开关开着就走关蜂窝流程，
    /// 与 SideStore「Wi-Fi 未满足就关蜂窝」的语义一致）.
    static func isWiFiSatisfied(timeout: TimeInterval = 0.5) -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.ipaside.escapeos.cellular-path")
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

    // MARK: - 快捷指令

    /// 跑一个「快捷指令」并返回系统是否受理.
    ///
    /// `shortcuts://run-shortcut?name=<name>` 与 SideStore 的 `AppConstants.Shortcuts` 同款.
    /// ⚠️ `UIApplication.open` 必须主线程调用；本类在后台队列（应用列表 / 卸载）被调用，
    /// 故用信号量把 `open` 的**受理结果**同步回调用线程. **若调用方已在主线程**，
    /// 同步等待会死锁 ⇒ 直接发起、不阻塞（对齐 `JITEnableService` 的 `Thread.isMainThread` 处理）.
    private func runShortcut(_ name: String) -> Bool {
        guard let url = Self.shortcutURL(for: name) else { return false }
        let box = BoolBox()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                UIApplication.shared.open(url, options: [:]) { accepted in box.set(accepted) }
            }
            return true
        }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UIApplication.shared.open(url, options: [:]) { accepted in
                    box.set(accepted)
                    semaphore.signal()
                }
            }
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
        return box.value
    }

    /// 构造快捷指令 URL（`name` 做百分号编码，与 SideStore `shortcutURL(for:fallback:)` 同款）.
    static func shortcutURL(for name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    // MARK: - 状态

    private var didTurnOffData: Bool {
        lock.lock(); defer { lock.unlock() }
        return turnedOffData
    }

    private func setTurnedOffData(_ value: Bool) {
        lock.lock(); turnedOffData = value; lock.unlock()
    }
}

/// `NWPathMonitor` 回调 / `open` 回调与调用线程之间的同步盒子.
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
