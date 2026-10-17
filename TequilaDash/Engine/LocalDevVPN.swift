import Darwin
import Foundation
import UIKit

/// LocalDevVPN 检测 / 打开（移植自 locus-ZH）.
/// 隧道 IP 与 TequilaDash「设置 → 本地隧道」的 TunnelDeviceIP 联动.
enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// 启动隧道后通过 scheme 回到 TequilaDash.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=tequiladash")!

    /// 隧道目标 IP —— 即 LocalDevVPN 的**对端地址**（不是本机 utun 的接口地址）.
    ///
    /// ⚠️ 关键事实（2026-10-08 取证）：**对端地址与本机 utun 地址本来就是两个不同的地址**.
    /// LocalDevVPN 建的是**点对点** utun：
    ///   · 接口地址（本机侧） = ifaceIP，出厂 `10.7.1.1/32`
    ///   · 对端地址（要连的） = peerIP， 出厂 `10.7.0.1/32`
    /// 依据 `marcinmajsc/LocalDevVPN` 源码：
    ///   · `LocalDevVPN/Constants.swift`：`defaultIfaceIP = "10.7.1.1/32"`、`defaultPeerIP = "10.7.0.1/32"`
    ///   · `TunnelProv/PacketTunnelProvider.swift`：`NEIPv4Settings(addresses: [ifaceIP])`、
    ///     `includedRoutes = [NEIPv4Route(peerIP/32)]`、`NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerIP)`
    /// 真机日志 `P4_全能签逆向/_devicelog4/login.log:69` 的 `utun4=10.7.1.1` 正是 ifaceIP
    /// ⇒ 对端应取 **peerIP（10.7.0.1）**，把目标改成 `10.7.1.1` 反而会连到本机接口地址、必然失败.
    ///
    /// 与 TunnelContext / heartbeat 统一：用户配置优先，否则用默认对端.
    /// 枚举的 utun 只作为诊断候选，不把第一个任意 VPN 接口当成实际连接目标.
    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: "TunnelDeviceIP")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return "10.7.0.1"
    }

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    /// 本机是否存在 LocalDevVPN 建起的隧道接口.
    ///
    /// ⚠️ v0.3.581 修正（真机实证）：旧实现以「本机存在 `targetIP` 的 /24 网段 IPv4 地址」
    /// 为**唯一**判据，假设 LocalDevVPN 会把 utun 地址放在 `10.7.0.x`。但真机探针
    /// （`P4_全能签逆向/_devicelog3/ddi_probe.txt:7` 与 `cd_probe.txt:8`，2026-10-05）
    /// 两次都出现 `isConnected=false` 而 `tunnel_create_rppairing(10.7.0.1:49152)`
    /// **成功** —— 隧道通了，本机却没有 `10.7.0.x` 的 IPv4 地址（utun 可能只给 IPv6，
    /// 或本机侧地址在别的网段）⇒ 网段假设不成立，旧判据**必然假阴性**。
    /// 现改为**不假设网段**：存在任意 `utun*` 接口（IPv4 或 IPv6）即算已连接；仅当
    /// 连 utun 都没有时，才退回按网段再判一次（命中才为真 ⇒ 不会新增假阴性）.
    static var isConnected: Bool {
        let interfaces = allInterfaces()
        if interfaces.contains(where: { $0.name.hasPrefix("utun") }) { return true }

        // 兜底：万一某版本的隧道接口不叫 utun，仍按 targetIP 网段判一次.
        let target = targetIP
        if interfaces.contains(where: { $0.address == target }) { return true }
        let parts = target.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.dropLast().joined(separator: ".") + "."
        return interfaces.contains { $0.address.hasPrefix(prefix) }
    }

    /// 诊断用：本机全部 IPv4 接口的 `接口名=地址` 列表（纯事实枚举，无判断）.
    /// 供安装失败时打进日志 —— 下次一看即知「真的没连」还是「枚举漏了」.
    static func ipv4InterfaceSummary() -> String {
        let ipv4 = allInterfaces().filter { $0.family == AF_INET }
        if ipv4.isEmpty { return "（无）" }
        return ipv4.map { "\($0.name)=\($0.address)" }.joined(separator: ", ")
    }

    /// 探测**单个**地址的隧道端口（49152，RPPairing 服务）是否可达.
    /// 用于自动重试前的预检：隧道未起时不建 RSD 隧道，避免反复失败
    /// 与 ServiceNotFound 竞争（v0.2.106）.
    ///
    /// - Parameter timeout: 连接超时（秒）. 默认调用点用 1.0（保持既有行为不变）；
    ///   蜂窝轮询由 `CellularTunnelManager` 传 0.25 —— 对齐 SideStore
    ///   `MinimuxerConstants.defaultTCPProbeTimeoutMs`（250ms），使 2 秒预算内能试更多次.
    static func isReachable(ip: String, timeout: TimeInterval, port: UInt16 = 49152) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        let parseResult = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Socket send/receive timeouts do not bound connect() on Darwin.
        // Nonblocking connect + poll + SO_ERROR also prevents a refused socket
        // from being reported as ready simply because it became writable.
        guard timeout.isFinite, timeout > 0 else { return false }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            let milliseconds = Int32(min(ceil(remaining * 1000), Double(Int32.max)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return false }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
        }
    }

    /// 探测当前推导出的对端地址（`targetIP`）是否可达（1 秒超时）.
    /// 单地址版，保持既有调用点（下载中心预检等）行为不变.
    static func isTunnelReachable() -> Bool {
        isReachable(ip: targetIP, timeout: 1.0)
    }

    /// 探测**任一候选对端**是否可达（并行，取第一个成功）.
    ///
    /// 对齐 SideStore `DeviceConnectionManager.resolveLocalVPNTunnel`：把所有候选对端
    /// 丢进 `withTaskGroup` **并行**探测，谁先回谁胜出（`group.cancelAll()`）.
    /// 本机可能同时装着 Surge / Loon / Shadowrocket 等（各起一条 utun），
    /// 只探「第一条 utun」会探错隧道 ⇒ 必须多候选并行.
    ///
    /// - Parameter timeout: 每个候选的连接超时（秒）.
    static func isAnyCandidateReachable(timeout: TimeInterval) -> Bool {
        let peers = candidateTunnelPeers()
        guard !peers.isEmpty else { return false }
        if peers.count == 1 { return isReachable(ip: peers[0], timeout: timeout) }

        // `concurrentPerform` 是同步阻塞的（全部迭代跑完才返回），
        // 每个候选各自带 `timeout`，所以整体耗时约等于单个候选的超时.
        let flag = TunnelProbeFlag()
        DispatchQueue.concurrentPerform(iterations: peers.count) { index in
            if !flag.value, isReachable(ip: peers[index], timeout: timeout) { flag.set() }
        }
        return flag.value
    }

    /// 候选隧道对端地址（有序、去重、已按 SideStore `isValidCandidatePeer` 规则过滤）.
    ///
    /// 顺序：用户显式覆盖（`UserDefaults["TunnelDeviceIP"]`）→ 各 utun 点对点对端
    /// （同处 `10.0.0.0/8` 的排前）→ 出厂默认 `10.7.0.1`.
    ///
    /// 对齐 SideStore：候选集合 ≈ `DeviceConnectionManager.resolveCandidatePeers`
    /// （route gateway → route destination → link-layer destination），
    /// 过滤规则 = `isValidCandidatePeer`；用户覆盖 ≈ `overridePeerIp`.
    ///
    /// v0.3.619：**补上路由表来源**.
    ///
    /// 真机证据（用户 2026-10-17 截图）：`utun 隧道接口 = 存在`，
    /// 但「候选对端」只剩兜底 `10.7.0.1` —— 说明 `utunPeerIPv4Candidates()`（只读
    /// `ifa_dstaddr`）**返回空**。而 minimuxer 的日志字段是
    /// `linkLayerDestinationIP` / `destinationIPs` / `destinationGatewayIPs`，
    /// 那三个都来自**路由表**，不是 `ifa_dstaddr`.
    /// ⇒ 只读 `ifa_dstaddr` 是我自己收窄了来源；这里补齐路由表与链路层目的地.
    static func candidateTunnelPeers() -> [String] {
        var peers: [String] = []
        let stored = UserDefaults.standard.string(forKey: "TunnelDeviceIP")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { peers.append(stored) }
        peers.append(contentsOf: utunPeerIPv4Candidates())
        peers.append(contentsOf: routeTablePeers())
        peers.append("10.7.0.1")

        var seen = Set<String>()
        return peers.filter { isValidCandidatePeer($0) && seen.insert($0).inserted }
    }

    /// 各来源枚举到多少个候选（诊断页用：分清「没有 utun」还是「枚举方式没覆盖到」）.
    struct PeerSourceReport: Sendable {
        let override: String?
        let utunPeerCount: Int
        let routeCount: Int
        let defaultFallback: String
    }

    static func peerSourceReport() -> PeerSourceReport {
        let stored = UserDefaults.standard.string(forKey: "TunnelDeviceIP")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PeerSourceReport(
            override: (stored?.isEmpty == false) ? stored : nil,
            utunPeerCount: utunPeerIPv4Candidates().count,
            routeCount: routeTablePeers().count,
            defaultFallback: "10.7.0.1")
    }

    /// 从**路由表**枚举指向 utun 的目的地址 / 网关（对齐 minimuxer 的
    /// `destinationIPs` / `destinationGatewayIPs` / `linkLayerDestinationIP`）.
    ///
    /// 实现走 **C 垫片** `EscRoutePeers.c`：`rt_msghdr` / `sockaddr_dl` / `RTAX_*`
    /// 定义在 `<net/route.h>`，**不在 Swift Clang Importer 的可见范围**
    /// （CI 实测：`error: cannot find type 'rt_msghdr' in scope`）。
    /// 与本仓 `EscBrowseApps.c` / `EscDDIProbe.c` 同款：解析全在 C 层，Swift 只拿字符串。
    ///
    /// 失败（sysctl 被拒 / 无 utun 路由）时返回空数组 —— 不抛错、不影响既有来源.
    static func routeTablePeers() -> [String] {
        var count: Int = 0
        guard let raw = esc_route_utun_peers(&count) else { return [] }
        defer { esc_route_utun_peers_free(raw) }
        let text = String(cString: raw)
        return text
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { isValidCandidatePeer($0) }
    }

    /// 候选地址合法性 —— 对齐 SideStore `isValidCandidatePeer`：
    /// 拒空、拒 `0.0.0.0` / `default` / `255.255.255.255`、拒回环（`127.*`）、
    /// 拒组播（`224.*`、`239.*`），且必须是合法 IPv4.
    static func isValidCandidatePeer(_ ip: String) -> Bool {
        guard !ip.isEmpty, ip != "0.0.0.0", ip != "default", ip != "255.255.255.255",
              !ip.hasPrefix("127."), !ip.hasPrefix("224."), !ip.hasPrefix("239.") else { return false }
        var addr = in_addr()
        return ip.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    static func openInstalled() {
        UIApplication.shared.open(enableURL)
    }

    static func openAppStore() {
        UIApplication.shared.open(appStoreURL)
    }

    /// 打开 LocalDevVPN（深链）；系统未受理再兜底跳 App Store.
    ///
    /// 为什么不再用 `isInstalled`（`canOpenURL`）决定分支：`canOpenURL` 依赖
    /// `Info.plist` 的 `LSApplicationQueriesSchemes` 白名单 —— 白名单漏登 `localdevvpn` 时
    /// 它**恒返回 false**，于是无论装没装都跳 App Store（本轮修的正是这个）。
    /// `open` 的 completion 才是「系统到底受理了没有」的直接证据，故改用它兜底；
    /// 白名单照旧补上 `localdevvpn`（`VirtualLocationSettingsView` 仍用 `isInstalled` 显示状态）.
    static func openOrInstall() {
        // completion 由系统在主队列回调，但闭包本身不是 `@MainActor` 隔离的
        // ⇒ 二次 `open`（MainActor 隔离）用 `assumeIsolated` 同步进主 actor
        // （与 OnlineInstallService 同款处理）.
        UIApplication.shared.open(enableURL, options: [:]) { accepted in
            guard !accepted else { return }
            MainActor.assumeIsolated {
                UIApplication.shared.open(appStoreURL, options: [:], completionHandler: nil)
            }
        }
    }

    /// 首个合格的点对点 utun 对端地址（= `utunPeerIPv4Candidates()` 的第一项）.
    /// 单地址版；蜂窝就绪轮询改走多候选 `isAnyCandidateReachable(timeout:)`.
    ///
    /// 返回 `nil` 的几种情况（都**安全退回**默认值，不改变现状、不新增假阴性）：
    ///   · 没有 utun 接口（隧道没起）；· utun 没有 IPv4 目的地址（非点对点 / 只有 IPv6）；
    ///   · 推出来的地址不像隧道对端（非私有地址、或等于本机接口地址）.
    private static func utunPeerIPv4() -> String? {
        utunPeerIPv4Candidates().first
    }

    /// 收集**全部**合格的点对点 utun 对端地址（不止第一条）.
    ///
    /// 为什么读 `ifa_dstaddr` 而不是接口地址：见 `targetIP` 注释 —— LocalDevVPN 把
    /// `tunnelRemoteAddress` 设成 peerIP，iOS 据此把 utun 配成点对点接口，
    /// `ifconfig` 显示为 `inet <ifaceIP> --> <peerIP>`：`ifa_addr` 是 ifaceIP，
    /// `ifa_dstaddr` 才是 peerIP.
    ///
    /// 判据与 `utunPeerIPv4()` 原实现完全一致（只是不再「取到第一条就 return」）：
    ///   · 接口名以 `utun` 开头；· 是点对点（`IFF_POINTOPOINT`；非点对点的
    ///     `ifa_dstaddr` 是广播地址，必须排除）；· 目的地址是私有 IPv4；· 对端 ≠ 本机.
    /// 排序：与本机 utun 地址同处 `10.0.0.0/8` 的排前（LocalDevVPN 的隧道就是 10.x），
    /// 其余（其它 VPN 起的 utun）排后.
    private static func utunPeerIPv4Candidates() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var preferred: [String] = []   // 首选：与本机 utun 同处 10/8
        var loose: [String] = []       // 次选：其余合格的点对点 utun 对端
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            ptr = interface.ifa_next
            guard String(cString: interface.ifa_name).hasPrefix("utun") else { continue }

            guard interface.ifa_flags & UInt32(IFF_POINTOPOINT) != 0 else { continue }
            guard let dstPtr = interface.ifa_dstaddr,
                  dstPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let peer = numericIPv4(dstPtr), isPrivateIPv4(peer) else { continue }

            let local: String? = (interface.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET))
                ? interface.ifa_addr.flatMap { numericIPv4($0) } : nil
            if let local, peer == local { continue }          // 对端 == 本机 ⇒ 不是点对点对端

            if let local, local.hasPrefix("10."), peer.hasPrefix("10.") {
                preferred.append(peer)
            } else {
                loose.append(peer)
            }
        }
        return preferred + loose
    }

    /// 把已确认 `AF_INET` 的 `sockaddr` 转成点分十进制 IPv4 字符串.
    private static func numericIPv4(_ addr: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size),
                          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let value = String(cString: host)
        return value.isEmpty ? nil : value
    }

    /// 是否私有 IPv4（`10/8`、`172.16/12`、`192.168/16`）—— 隧道对端必为私有地址.
    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }

    /// 网络接口信息（诊断页与日志共用）.
    ///
    /// 用结构体而不是元组：Swift 的 **key path 不能指向元组成员**，
    /// `ForEach(items, id: \.name)` 在元组数组上无法编译.
    /// 显式 `Sendable`：诊断页在 `Task.detached` 里探测、把结果传回主 actor.
    struct InterfaceInfo: Identifiable, Hashable, Sendable {
        let name: String
        let family: Int32
        let address: String
        /// 点对点对端（`ifa_dstaddr`，仅 `IFF_POINTOPOINT` 接口有意义）.
        var peer: String? = nil
        /// 是否点对点接口（utun 这类 VPN 隧道）.
        var isPointToPoint: Bool = false
        var id: String { "\(name)|\(family)|\(address)|\(peer ?? "")" }
        /// 是否 IPv4（`AF_INET`）—— 供视图显示用，避免视图层再 import Darwin.
        var isIPv4: Bool { family == AF_INET }
        /// 是否 utun 隧道接口.
        var isUtun: Bool { name.hasPrefix("utun") }
    }

    /// 枚举本机接口地址（IPv4 与 IPv6 都收，带接口名与地址族）.
    /// 旧实现只看 `AF_INET` ⇒ LocalDevVPN 的 utun 若只给 IPv6 就会整条漏掉；
    /// 这里两个地址族都收，且**不过滤接口名**（utun / en0 / pdp_ip0 一视同仁）.
    /// v0.3.616：`private` → 供 TunnelHealthCheckView 诊断页使用.
    /// v0.3.619：补 `peer`（`ifa_dstaddr`）与 `isPointToPoint` —— 诊断页要能直接看到
    /// utun 的对端到底解析出来没有（真机截图显示候选只有兜底 10.7.0.1，说明枚举返回空）.
    static func allInterfaces() -> [InterfaceInfo] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [InterfaceInfo] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            ptr = interface.ifa_next
            guard let sockAddr = interface.ifa_addr else { continue }
            let family = Int32(sockAddr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameLen = (family == AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sockAddr, nameLen, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let p2p = interface.ifa_flags & UInt32(IFF_POINTOPOINT) != 0
            var peer: String? = nil
            if p2p, let dst = interface.ifa_dstaddr, dst.pointee.sa_family == sa_family_t(family) {
                peer = numericIPv4(dst) ?? numericIPv6(dst)
            }
            results.append(InterfaceInfo(
                name: name, family: family, address: String(cString: host),
                peer: peer, isPointToPoint: p2p))
        }
        // utun 排最前：诊断时第一眼就要看到隧道接口的真实地址与对端.
        return results.sorted { lhs, rhs in
            if lhs.isUtun != rhs.isUtun { return lhs.isUtun }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.family < rhs.family
        }
    }

    /// IPv6 的数值串（`numericIPv4` 只处理 AF_INET）.
    private static func numericIPv6(_ addr: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in6>.size),
                          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let value = String(cString: host)
        return value.isEmpty ? nil : value
    }
}

/// 并行探测的「已命中」标志.
///
/// Swift 6 严格并发下不允许在 `@Sendable` 闭包里改写捕获的 `var`，
/// 故用带锁的引用类型（与 `CellularTunnelManager` 里的 `BoolBox` 同款）.
private final class TunnelProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock(); stored = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
