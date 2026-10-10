import Darwin
import Foundation
import NetworkExtension
import UIKit

/// 隧道抽象层.
///
/// 背景（2026-10-09）：全仓的「设备地址入口」一直是 `LocalDevVPN.targetIP` /
/// `LocalDevVPN.isConnected` 两个静态属性（约 40 处调用点，遍布 RSD 服务层）.
/// 本文件把「用哪种方式建隧道」抽成用户可选项，在「更多 → 设置 → 隧道」里选择.
///
/// ⚠️ 关键纪律（2026-10-10 修正，勿违反）：**设备地址始终由 `LocalDevVPN` 提供**.
/// 上一版把 40 处调用点改走 `TunnelManager.targetIP` / `TunnelManager.isConnected`，
/// 结果用户一旦选中 Shadowrocket（其 `isConnected` 恒 `false`、不提供设备连接）⇒
/// AFC / lockdown / 安装 / 电池健康等**全部失效**。故本文件**不再暴露** `targetIP` /
/// `isConnected` 转发；`LocalDevVPN.targetIP` 读的是本机 utun 的**对端地址**，
/// `LocalDevVPN.isConnected` 读的是「本机是否有 utun」，二者与「用哪个 App 建隧道」无关，
/// 因此对 LocalDevVPN 与内置隧道同样成立. 本文件只决定**跳转目标**与**内置隧道启停**.
///
/// 三种方式（照 WrapPin 的口径）：
///   · `.localDevVPN` —— 现状，外部 LocalDevVPN 应用建 utun，本应用只读它的对端地址.
///   · `.shadowrocket` —— **只是跳转目标**：点了跳去 Shadowrocket. 它**不保证**能提供
///     设备连接所需的 utun（WrapPin README 原文：「设置中的 Shadowrocket 选项只决定
///     跳转目标，不保证普通代理配置能提供所需的设备连接」）⇒ 本实现**不谎称**已连接.
///   · `.builtIn` —— 新增，用 Network Extension 自己建隧道. 开启前**先检测当前签名
///     是否含 Packet Tunnel 权限**，无权限则置灰（见 `VPNPermissionProbe`）.
///
/// ⚠️ 兼容纪律：默认方式仍是 `.localDevVPN`（`UserDefaults` 无值时回落到它），
/// 且切换方式**不改变任何设备连接功能的行为**（它们都直读 `LocalDevVPN`）.

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

    /// 恒 `false`：跳转目标不构成连接承诺，见类型注释.
    var isConnected: Bool { false }
    var canProbeConnection: Bool { false }

    /// 打开 Shadowrocket 用的 scheme.
    ///
    /// 为什么是 `shadowrocket://open`：Shadowrocket 官方 wiki 的 URL-Schemes 一节
    /// （github.com/LOWERTOP/Shadowrocket，README「URL-Schemes」）明确列出
    /// `shadowrocket://connect` 与 `shadowrocket://open`，均标注为「启动 VPN 隧道」。
    /// 这证明 `shadowrocket` 已注册在其 `CFBundleURLSchemes` 里（未注册则系统不派发）。
    /// 取 `open` 而非 `connect`：两者同为「启动 VPN 隧道」，`open` 更贴近「把 App 拉起」的本意。
    /// 反例说明：早期写的 `sub://` 是订阅导入用途，实测 `canOpenURL(sub://)` 不可靠，已弃用.
    private static let openURL = URL(string: "shadowrocket://open")!

    var availability: TunnelAvailability {
        // `canOpenURL` 只认 `Info.plist` 的 `LSApplicationQueriesSchemes` 白名单；
        // 白名单里已放 `shadowrocket`，且它是官方 wiki 确证的已注册 scheme ⇒ 这里才能真实反映「装没装 Shadowrocket」.
        if UIApplication.shared.canOpenURL(Self.openURL) { return .available }
        return .unavailable("未检测到 Shadowrocket，请先在 App Store 安装.")
    }

    func start() async {
        guard availability.isAvailable else {
            LoginLogger.shared.log("[隧道] Shadowrocket 未安装，跳过跳转.", category: .general)
            return
        }
        LoginLogger.shared.log("[隧道] 请求打开 Shadowrocket（scheme=shadowrocket://open，仅跳转，不保证提供设备连接）.", category: .general)
        // 为什么必须走 `MainActor.run`（三次 CI 实测，逐层退让）：
        //   ① 只写 `open(url)` ⇒ async 上下文推断成 async 重载 ⇒ 报
        //      「expression is 'async' but is not marked with 'await'」；
        //   ② 加 `await` ⇒ async 重载把非 Sendable 的
        //      `[UIApplication.OpenExternalURLOptionsKey: Any]` 跨隔离传 ⇒ 报
        //      「sending value of non-Sendable type ... risks causing data races」；
        //   ③ 显式写全三参（同步重载）⇒ **仍被判成 async**（该重载的 `options` 默认值与
        //      async 版本重载解析歧义）。
        // 正解：把调用整体放进 MainActor —— `UIApplication.shared` 本就是 MainActor 隔离的，
        // 字典在闭包内就地构造、不跨隔离传递。闭包只捕获 `Self.openURL`（static let URL，Sendable）。
        // 带 completion 则明确落到 completion 重载（不会歧义到 async 版），用它如实记下「系统有没有受理」。
        await MainActor.run {
            UIApplication.shared.open(Self.openURL, options: [:]) { accepted in
                if !accepted {
                    LoginLogger.shared.log("[隧道] 系统未受理 shadowrocket://open 打开请求，Shadowrocket 可能未安装.", category: .general)
                }
            }
        }
    }

    func stop() async {
        // 跳转目标没有可断开的连接 ⇒ 空操作.
    }
}

// MARK: - 实现 3：内置隧道（Network Extension）

/// 用 Network Extension 自建 Packet Tunnel.
///
/// 分阶段（用户确认的路线）：
///   · Phase 1：**权限检测 + UI 门槛 + 抽象**. `availability` 由 `VPNPermissionProbe` 决定.
///   · Phase 2（本次）：独立 Network Extension target（`EscapeOSTunnel`：`NEPacketTunnelProvider`
///     子类 + `PlugIns/*.appex`），主 App 侧 `start()` 建配置并拉起扩展.
///     扩展是一个**回环反射器**（与 LocalDevVPN 同口径），让本机自己的开发者服务
///     （RSD 49152 等）通过对端地址可达，不提供出口代理、不改公网 IP.
struct BuiltInTunnel: TunnelProviding {
    let kind: TunnelKind = .builtIn

    /// 本版本是否**真的**把 Network Extension 扩展打进了 App bundle.
    ///
    /// 如实判定：只有 `PlugIns/EscapeOSTunnel.appex` 存在、且其 bundle id 与本类约定的
    /// `Self.providerBundleID` 一致时才为 `true`. 这样「内置隧道」的可用性才不会在扩展缺失时
    /// 谎称可用（例如别人去掉扩展 target 重新构建时，UI 必须如实显示不可用）.
    static var isExtensionBundled: Bool {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        let appex = plugIns.appendingPathComponent("EscapeOSTunnel.appex")
        guard FileManager.default.fileExists(atPath: appex.path) else { return false }
        guard let bundle = Bundle(url: appex) else { return false }
        return bundle.bundleIdentifier == Self.providerBundleID
    }

    /// 内置隧道建出来的也是 utun ⇒ 复用「存在任意 utun 即算已连接」的判据
    /// （与 LocalDevVPN 同源，不假设网段）.
    var isConnected: Bool { LocalDevVPN.isConnected }
    var canProbeConnection: Bool { true }

    /// 同步判定：读**当前进程签名**里的 Packet Tunnel 权限.
    /// 依据与取舍见 `VPNPermissionProbe`.
    ///
    /// 语义（对应「关闭了还显示已检测到」）：这里判定的是**签名里有没有该权限**，
    /// 与「VPN 开关有没有关」「隧道连没连上」无关 —— 签名在安装时即固定，用户在系统里
    /// 断开任何 VPN 都不会改变它，故文案必须写明是「当前签名」，不能写会被读成连接状态的「已检测到」.
    var availability: TunnelAvailability {
        let permission = VPNPermissionProbe.readOwnEntitlement(VPNPermissionProbe.packetTunnelKey)
        let permissionState: String
        switch permission {
        case .granted(let detail): permissionState = "当前签名含 VPN 权限（\(detail)）"
        case .absent(let why):     permissionState = "当前签名不含 VPN 权限（\(why)）"
        case .unknown:             permissionState = "无法确认当前签名是否含 VPN 权限"
        }
        guard Self.isExtensionBundled else {
            // 本版本没做 Phase 2 ⇒ 不谎称可用（同时把签名权限现状一并讲清）.
            return .unavailable("本版本暂未提供内置隧道扩展.\(permissionState)，内置隧道需带 Packet Tunnel 权限的签名.")
        }
        switch permission {
        case .granted:
            return .available
        case .absent, .unknown:
            return .unavailable("\(permissionState).需用带 Packet Tunnel 权限的证书或巨魔安装.")
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
        let outcome = await Self.ensureConfiguredAndStart()
        if outcome.isEmpty {
            LoginLogger.shared.log("[隧道] 内置隧道启动请求已发送（provider=\(Self.providerBundleID)）.", category: .general)
        } else {
            LoginLogger.shared.log("[隧道] \(outcome)", category: .general)
        }
    }

    /// 建立（或复用）内置隧道配置并拉起扩展.
    ///
    /// Swift 6 严格并发约束：`NETunnelProviderManager` 非 Sendable，**不**能跨 `await`
    /// 传回调用方，也**不**宜被嵌套完成回调捕获 ⇒ 拆成两步、每步一个 `loadAllFromPreferences`
    /// 往返，闭包体内只使用**本闭包内新建**的值，跨隔离域只回传一个 `String`
    /// （空串 = 成功；非空 = 失败原因，英文句点结尾）.
    /// 这样写对「完成回调是否为 `@Sendable`」不敏感：两种情形都编得过.
    private static func ensureConfiguredAndStart() async -> String {
        let saveOutcome = await saveConfiguredManager()
        if !saveOutcome.isEmpty { return saveOutcome }
        return await startExistingManager()
    }

    /// 第 1 步：读取 → 建/复用配置 → `saveToPreferences`.
    private static func saveConfiguredManager() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    cont.resume(returning: "读取内置隧道配置失败：\(error.localizedDescription).")
                    return
                }
                // 复用已存在的「本扩展」配置；找不到就新建一条.
                let existing = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID
                }
                let manager = existing ?? NETunnelProviderManager()

                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.providerBundleID
                // Packet Tunnel 里 serverAddress 只是「设置 → VPN」显示的占位；
                // 真正的对端地址经 providerConfiguration 的 peerIP 传给扩展
                // （扩展 PacketTunnelProvider 读该键，缺省回落到 10.7.0.1）.
                let peerIP = LocalDevVPN.targetIP
                proto.serverAddress = peerIP
                proto.providerConfiguration = ["peerIP": peerIP]

                manager.protocolConfiguration = proto
                manager.localizedDescription = "EscapeSpace 内置隧道"
                manager.isEnabled = true

                // 本闭包体内不引用 `manager` ⇒ 不把它捕获进来.
                manager.saveToPreferences { saveError in
                    if let saveError {
                        cont.resume(returning: "保存内置隧道配置失败：\(saveError.localizedDescription).")
                        return
                    }
                    cont.resume(returning: "")
                }
            }
        }
    }

    /// 第 2 步：重新读取（save 之后的）配置并 `startVPNTunnel`.
    ///
    /// 用一次全新的 `loadAllFromPreferences` 取代 `saveToPreferences` 之后对同一对象的
    /// `loadFromPreferences`：读回的 manager 已是「从偏好设置加载过」的状态，其 `connection`
    /// 有效，可直接拉起；同时避免把非 Sendable 的 manager 捕获进嵌套闭包.
    private static func startExistingManager() async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    cont.resume(returning: "读取内置隧道配置失败：\(error.localizedDescription).")
                    return
                }
                guard let manager = managers?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID
                }) else {
                    cont.resume(returning: "保存后未能重新找到内置隧道配置.")
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
    }

    func stop() async {
        let outcome: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    cont.resume(returning: "读取内置隧道配置失败：\(error.localizedDescription).")
                    return
                }
                // 只断**本应用创建**的配置（providerBundleIdentifier 命中），
                // 不动系统里用户其它 VPN / 隧道的配置.
                let own = managers?.filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID
                } ?? []
                guard !own.isEmpty else {
                    cont.resume(returning: "未发现由本应用创建的内置隧道配置.")
                    return
                }
                own.forEach { $0.connection.stopVPNTunnel() }
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
/// 要探测的 key：`com.apple.developer.networking.networkextension`
/// （数组里代表分组隧道的值是 `packet-tunnel-provider`，**不是** `packet-tunnel`）.
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

    /// 上述 key 下代表「分组隧道」的数组值.
    static let packetTunnelProviderValue = "packet-tunnel-provider"

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
        // ★ Packet Tunnel 权限：必须校验数组里**含** packet-tunnel-provider.
        //   只看 key 在不在，会把「数组里只有 dns-proxy 之类」的签名误判成可用.
        if key == packetTunnelKey {
            let values = (value as? [String]) ?? []
            guard values.contains(packetTunnelProviderValue) else {
                return .absent("数组里没有 \(packetTunnelProviderValue)（实为 \(describe(value))）")
            }
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

    /// 把读到的 entitlement 值转成一句可读事实（数组会拼出 packet-tunnel-provider 之类的元素）.
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

/// 全仓隧道**选择**入口（只表达用户偏好，不是设备地址的来源）.
///
/// ⚠️ 设计纪律（2026-10-10 修正）：**设备地址不从这里取**。此前把全仓
/// `LocalDevVPN.targetIP` / `LocalDevVPN.isConnected` 的调用点改走本类型，导致用户一旦
/// 选中 Shadowrocket（其 `isConnected` 恒 `false`、且不提供设备连接）⇒ AFC / lockdown /
/// 安装 / 电池健康 / 崩溃日志等**全部失效**。现明确：
///   · 依赖设备连接的功能**一律直接读** `LocalDevVPN.targetIP` / `LocalDevVPN.isConnected`
///     —— 它读的是本机 utun 的**对端地址**与「本机是否有 utun」，与「用哪个 App 建隧道」无关.
///   · 本类型只用于设置页呈现、跳转目标（Shadowrocket）与内置隧道的启停.
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
}
