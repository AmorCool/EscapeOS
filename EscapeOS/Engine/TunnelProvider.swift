import Darwin
import Foundation
import NetworkExtension
import UIKit

/// 隧道抽象层.
///
/// 背景（2026-10-09）：此前全仓的「隧道入口」就是 `LocalDevVPN.targetIP` /
/// `LocalDevVPN.isConnected` 两个静态属性（约 35 处调用点，遍布 RSD 服务层）.
/// 现在引入本文件，把「用哪种隧道」这件事从硬编码的 `LocalDevVPN` 抽出来，
/// 由用户在「更多 → 设置 → 隧道」里选择，调用点改从 `TunnelManager` 取.
///
/// 三种方式（照 WrapPin 的口径）：
///   · `.localDevVPN` —— 现状，外部 LocalDevVPN 应用建 utun，本应用只读它的对端地址.
///   · `.shadowrocket` —— **只是跳转目标**：点了跳去 Shadowrocket. 它**不保证**能提供
///     设备连接所需的 utun（WrapPin README 原文：「设置中的 Shadowrocket 选项只决定
///     跳转目标，不保证普通代理配置能提供所需的设备连接」）⇒ 本实现**不谎称**已连接.
///   · `.builtIn` —— 新增，用 Network Extension 自己建隧道. 开启前**先检测当前签名
///     是否含 Packet Tunnel 权限**，无权限则置灰（见 `VPNPermissionProbe`）.
///
/// ⚠️ 兼容纪律：默认方式仍是 `.localDevVPN`，且三种方式的 `targetIP` 都走
/// `LocalDevVPN.targetIP` 的同一套推导（`TunnelDeviceIP` 覆盖 → utun 对端自动推导 →
/// 兜底 10.7.0.1）. 因此把调用点改走 `TunnelManager` 后，**默认链路的行为逐字节不变**.

// MARK: - 隧道类型

/// 隧道方式. `rawValue` 直接落 `UserDefaults["TunnelKind"]`.
enum TunnelKind: String, CaseIterable, Identifiable, Sendable {
    case localDevVPN
    case shadowrocket
    case builtIn

    var id: String { rawValue }

    /// 设置页显示名.
    var title: String {
        switch self {
        case .localDevVPN: return "LocalDevVPN"
        case .shadowrocket: return "Shadowrocket 连接"
        case .builtIn: return "内置隧道"
        }
    }

    /// 设置页每项下面那行说明（英文句点结尾，不含任何符号化标记）.
    var detail: String {
        switch self {
        case .localDevVPN:
            return "需在 LocalDevVPN 应用里连接隧道，再回到本应用使用."
        case .shadowrocket:
            return "仅作为跳转目标，不保证能提供所需的设备连接."
        case .builtIn:
            return "由本应用内置的 Network Extension 建隧道，需带 Packet Tunnel 权限的签名."
        }
    }
}

// MARK: - 可用性

/// 某种隧道方式当前能否启用.
enum TunnelAvailability: Equatable, Sendable {
    case available
    /// 不可用 + 原因（英文句点结尾）.
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// 置灰时展示的原因；可用时为 `nil`.
    var reason: String? {
        if case .unavailable(let text) = self { return text }
        return nil
    }
}

// MARK: - 协议

/// 隧道提供者. 所有依赖隧道的功能只认这一组能力.
protocol TunnelProviding {
    var kind: TunnelKind { get }

    /// RSD 目标地址（隧道**对端** IP，不是本机 utun 接口地址）.
    var targetIP: String { get }

    /// 尽力而为的「是否已连接」判断. 语义与能否探测见 `canProbeConnection`.
    var isConnected: Bool { get }

    /// 该方式能否探测连接状态. Shadowrocket 恒为 `false`（它只是跳转目标，无法探测）.
    var canProbeConnection: Bool { get }

    /// 当前能否启用（无权限 / 未安装时给出原因）.
    var availability: TunnelAvailability { get }

    /// 发起连接（或跳转到外部应用）. 幂等，失败只记日志不抛.
    func start() async

    /// 断开连接. 对无法从本应用断开的隧道为空操作.
    func stop() async
}

// MARK: - 实现 1：LocalDevVPN（现状）

/// 现状实现：把既有的 `LocalDevVPN` 包成 `TunnelProviding`.
/// **不改 `LocalDevVPN` 的任何推导逻辑**，只做转发，确保既有链路零行为变化.
struct LocalDevVPNTunnel: TunnelProviding {
    let kind: TunnelKind = .localDevVPN

    var targetIP: String { LocalDevVPN.targetIP }
    var isConnected: Bool { LocalDevVPN.isConnected }
    var canProbeConnection: Bool { true }

    /// 现状不设门槛：默认方式永远可选（`LocalDevVPN.isInstalled` 依赖
    /// `canOpenURL(localdevvpn://)`，而该 scheme 未在白名单里、结果不可靠，故不拿它挡路）.
    var availability: TunnelAvailability { .available }

    func start() async {
        LocalDevVPN.openOrInstall()
    }

    func stop() async {
        // LocalDevVPN 的隧道只能在该应用内断开，本应用无从操作 ⇒ 空操作.
    }
}

// MARK: - 实现 2：Shadowrocket（跳转目标）

/// 照 WrapPin 的做法：只决定**跳转目标**，不建隧道、也不声称已连接.
///
/// 诚实说明（写进 UI 与日志）：Shadowrocket 是普通代理工具，它的配置**不保证**
/// 会在本机建出 RSD 所需的点对点 utun ⇒ 本实现 `isConnected` 恒为 `false`
/// （不把「系统里恰有别的 utun」错记成「Shadowrocket 已就绪」），`canProbeConnection`
/// 恒为 `false`，UI 上如实显示「无法探测」.
struct ShadowrocketTunnel: TunnelProviding {
    let kind: TunnelKind = .shadowrocket

    /// 无法确知 Shadowrocket 的隧道对端，沿用与 LocalDevVPN 同一套推导（`TunnelDeviceIP`
    /// 覆盖 / utun 对端 / 兜底）——这样「用户手动填的地址」在三种方式下语义一致.
    var targetIP: String { LocalDevVPN.targetIP }

    /// 恒 `false`：跳转目标不构成连接承诺，见类型注释.
    var isConnected: Bool { false }
    var canProbeConnection: Bool { false }

    private static let openURL = URL(string: "shadowrocket://")!

    var availability: TunnelAvailability {
        // `canOpenURL` 只认 `Info.plist` 的 `LSApplicationQueriesSchemes` 白名单；
        // 已把 `shadowrocket` 加进去（否则永远返回 false，误判「未安装」）.
        if UIApplication.shared.canOpenURL(Self.openURL) { return .available }
        return .unavailable("未检测到 Shadowrocket，请先在 App Store 安装.")
    }

    func start() async {
        guard availability.isAvailable else {
            LoginLogger.shared.log("[隧道] Shadowrocket 未安装，跳过跳转.", category: .general)
            return
        }
        LoginLogger.shared.log("[隧道] 跳转 Shadowrocket（仅跳转，不保证提供设备连接）.", category: .general)
        // 必须 `await`：iOS 17 SDK 起 `open(_:)` 有 async 重载，Swift 6 会选它；
        // 不写 `await` 报「expression is 'async' but is not marked with 'await'」（CI 实测）。
        await UIApplication.shared.open(Self.openURL)
    }

    func stop() async {
        // 跳转目标没有可断开的连接 ⇒ 空操作.
    }
}

// MARK: - 实现 3：内置隧道（Network Extension）

/// 新增方式：用 Network Extension 自建 Packet Tunnel.
///
/// 分阶段（用户确认的路线）：
///   · Phase 1（本次）：**权限检测 + UI 门槛 + 抽象**. `availability` 由
///     `VPNPermissionProbe` 决定；`start()` 尝试驱动 `NETunnelProviderManager`.
///   · Phase 2：加独立的 Network Extension target（`NEPacketTunnelProvider` 子类 +
///     `PlugIns/*.appex`），并把 Packet Tunnel 权限写进签名. 在那之前本机没有可加载的
///     provider，`start()` 会如实报「尚未创建内置隧道配置」.
struct BuiltInTunnel: TunnelProviding {
    let kind: TunnelKind = .builtIn

    /// 内置隧道的对端地址沿用同一套推导（`TunnelDeviceIP` / utun 对端 / 兜底）.
    var targetIP: String { LocalDevVPN.targetIP }

    /// 内置隧道建出来的也是 utun ⇒ 复用「存在任意 utun 即算已连接」的判据
    /// （与 LocalDevVPN 同源，不假设网段）.
    var isConnected: Bool { LocalDevVPN.isConnected }
    var canProbeConnection: Bool { true }

    /// 同步判定：读**当前进程签名**里的 Packet Tunnel 权限.
    /// 依据与取舍见 `VPNPermissionProbe`.
    var availability: TunnelAvailability {
        switch VPNPermissionProbe.readOwnEntitlement(VPNPermissionProbe.packetTunnelKey) {
        case .granted:
            return .available
        case .absent(let why):
            return .unavailable("当前签名不含 VPN 权限（\(why)），需用带 Packet Tunnel 权限的证书或巨魔安装.")
        case .unknown:
            return .unavailable("无法确认当前签名是否含 VPN 权限，内置隧道默认关闭.")
        }
    }

    /// 异步复核：同步判定说「不可用 / 不确定」时，再用 Network Extension 实测一次；
    /// 实测成功即认为有权限（只可能把结果**升级**为可用，不会反过来把可用判成不可用）.
    static func resolvedAvailability() async -> TunnelAvailability {
        let sync = BuiltInTunnel().availability
        if sync.isAvailable { return sync }
        if case .granted = await VPNPermissionProbe.probeViaNetworkExtension() { return .available }
        return sync
    }

    /// 内置隧道 provider 的 bundle id 约定：主 bundle id + `.tunnel`
    /// （Network Extension 扩展必须以此为主 App bundle id 的前缀）.
    static var providerBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.ipaside.escapeos") + ".tunnel"
    }

    func start() async {
        guard availability.isAvailable else {
            LoginLogger.shared.log("[隧道] 内置隧道未启用：\(availability.reason ?? "无 VPN 权限").", category: .general)
            return
        }
        // 全程只在 completion 内使用 NE 对象，跨 await 只回传 String（避免把非 Sendable
        // 的 NETunnelProviderManager 带过隔离域 —— Swift 6 严格并发）.
        let outcome: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    cont.resume(returning: "读取内置隧道配置失败：\(error.localizedDescription).")
                    return
                }
                guard let manager = managers?.first else {
                    cont.resume(returning: "尚未创建内置隧道配置（本版本未内置隧道扩展，见 Phase 2）.")
                    return
                }
                do {
                    try manager.connection.startVPNTunnel()
                    cont.resume(returning: "")
                } catch {
                    cont.resume(returning: "启动内置隧道失败：\(error.localizedDescription).")
                }
            }
        }
        if outcome.isEmpty {
            LoginLogger.shared.log("[隧道] 内置隧道启动请求已发送（provider=\(Self.providerBundleID)）.", category: .general)
        } else {
            LoginLogger.shared.log("[隧道] \(outcome)", category: .general)
        }
    }

    func stop() async {
        let outcome: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    cont.resume(returning: "读取内置隧道配置失败：\(error.localizedDescription).")
                    return
                }
                managers?.forEach { $0.connection.stopVPNTunnel() }
                cont.resume(returning: "")
            }
        }
        if outcome.isEmpty {
            LoginLogger.shared.log("[隧道] 内置隧道已断开.", category: .general)
        } else {
            LoginLogger.shared.log("[隧道] \(outcome)", category: .general)
        }
    }
}

// MARK: - VPN 权限探测

/// 「当前签名是否含 Packet Tunnel 权限」的探测.
///
/// 要探测的 key：`com.apple.developer.networking.networkextension`（值为 `packet-tunnel`）.
///
/// 两条通道（先同步、必要时再异步复核）：
///
/// 1. **主通道（同步）：读本进程签名里的 entitlement.**
///    用 `SecTaskCreateFromSelf` + `SecTaskCopyValueForEntitlement` —— 它直接回答
///    「我这份签名里有没有这个权限」，正是要问的问题.
///    ⚠️ 依据：Apple 官方文档把这两个符号的可用平台标为 **macOS 10.0+ / Mac Catalyst 13.0+**，
///    **未列 iOS**；它们在 iOS 运行时的 Security 框架里确实导出（侧载生态普遍在用），
///    但**不是 iOS 公开 API** ⇒ 这里用 `dlsym` 运行时查找，取不到就返回 `.unknown`，
///    不硬链接、不臆断.
///    另一个官方依据：该函数「无错误返回即表示该权限不存在」，所以拿到 `nil` 且无 error
///    就是**确定没有**（而不是「不确定」）.
///
/// 2. **复核通道（异步）：让 Network Extension 自己判.**
///    用 `NETunnelProviderManager.loadAllFromPreferences`；Apple 文档明写
///    「The com.apple.developer.networking.networkextension entitlement is required to
///    use the NETunnelProviderManager class」⇒ 该调用报错即为「无权限」的直接证据.
///    只在主通道给不出「可用」时才用，且只用于**升级**结论.
///
/// 不采用「编译期 `#if canImport(NetworkExtension)`」：该权限是**签名**决定的，
/// 编译期无法得知（框架在 iOS 上人人可 import）.
enum VPNPermissionProbe {
    /// Packet Tunnel 权限的 entitlement key.
    static let packetTunnelKey = "com.apple.developer.networking.networkextension"

    /// 探测结论.
    enum Presence: Equatable, Sendable {
        /// 确认存在（附上读到的事实描述）.
        case granted(String)
        /// 确认不存在 / 调用被拒（附原因）.
        case absent(String)
        /// 无法判定.
        case unknown
    }

    // SecTask 的两个 C 符号签名（SecTaskRef 按 CFTypeRef 处理，二者都是不透明指针）.
    private typealias CreateTaskFromSelf = @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias CopyValueForEntitlement = @convention(c) (CFTypeRef?, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    /// 同步读本进程签名里的指定 entitlement.
    static func readOwnEntitlement(_ key: String) -> Presence {
        // RTLD_DEFAULT = (void *)-2：在当前已加载镜像里找符号（Security 已被本 App 链接）.
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let createSym = dlsym(defaultHandle, "SecTaskCreateFromSelf"),
              let copySym = dlsym(defaultHandle, "SecTaskCopyValueForEntitlement") else {
            return .unknown
        }
        let create = unsafeBitCast(createSym, to: CreateTaskFromSelf.self)
        let copy = unsafeBitCast(copySym, to: CopyValueForEntitlement.self)

        guard let task = create(nil) else { return .unknown }
        var error: Unmanaged<CFError>?
        guard let value = copy(task, key as CFString, &error) else {
            // Apple 文档：无错误返回即「该 entitlement 不存在」.
            if error == nil { return .absent("entitlement 不在当前签名里") }
            return .unknown
        }
        return .granted(describe(value))
    }

    /// 异步复核：Network Extension 能不能用（见类型注释的依据）.
    static func probeViaNetworkExtension() async -> Presence {
        await withCheckedContinuation { (cont: CheckedContinuation<Presence, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { _, error in
                if let error {
                    cont.resume(returning: .absent(error.localizedDescription))
                } else {
                    cont.resume(returning: .granted("NETunnelProviderManager 可用"))
                }
            }
        }
    }

    /// 把读到的 entitlement 值转成一句可读事实（数组会拼出 packet-tunnel 之类的元素）.
    private static func describe(_ value: CFTypeRef) -> String {
        if let array = value as? [String] {
            return array.isEmpty ? "（空数组）" : array.joined(separator: ",")
        }
        if let text = value as? String { return text }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return "（已设置）"
    }
}

// MARK: - 入口

/// 全仓隧道入口. 调用点用 `TunnelManager.targetIP` / `TunnelManager.isConnected`
/// 取代原先写死的 `LocalDevVPN.targetIP` / `LocalDevVPN.isConnected`.
///
/// ⚠️ 默认方式仍是 `.localDevVPN`（`UserDefaults` 无值时回落到它），且三种方式的
/// `targetIP` 同源 ⇒ 改造不改变既有行为.
enum TunnelManager {
    /// `UserDefaults` 键. 沿用本仓「模块.项」点号惯例（如 `AppStore.ShopRegion`），
    /// 与设置页 `TunnelPickerView` 的 `@AppStorage` 同键.
    static let kindKey = "EscapeOS.TunnelKind"

    /// 用户当前选择的隧道方式.
    static var selectedKind: TunnelKind {
        get {
            let raw = UserDefaults.standard.string(forKey: kindKey) ?? ""
            return TunnelKind(rawValue: raw) ?? .localDevVPN
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: kindKey) }
    }

    /// 按方式取实现.
    static func provider(for kind: TunnelKind) -> any TunnelProviding {
        switch kind {
        case .localDevVPN: return LocalDevVPNTunnel()
        case .shadowrocket: return ShadowrocketTunnel()
        case .builtIn: return BuiltInTunnel()
        }
    }

    /// 当前选中的实现.
    static var current: any TunnelProviding { provider(for: selectedKind) }

    /// 当前隧道的 RSD 目标地址（既有 `LocalDevVPN.targetIP` 调用点的替代）.
    static var targetIP: String { current.targetIP }

    /// 当前隧道是否已连接（既有 `LocalDevVPN.isConnected` 调用点的替代）.
    static var isConnected: Bool { current.isConnected }
}
