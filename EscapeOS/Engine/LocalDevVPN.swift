import Darwin
import Foundation
import UIKit

/// LocalDevVPN 检测 / 打开（移植自 locus-ZH）.
/// 隧道 IP 与 EscapeSpace「设置 → 本地隧道」的 TunnelDeviceIP 联动.
enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// 启动隧道后通过 scheme 回到 EscapeSpace.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=escapeos")!

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
    /// 解析优先级（**不再依赖写死的默认值**）：
    ///   1. 用户显式覆盖：`UserDefaults["TunnelDeviceIP"]`（「设置 → 本地隧道」）.
    ///   2. 自动推导：本机 `utun*` 点对点接口的**对端地址**（`getifaddrs` 的 `ifa_dstaddr`）.
    ///   3. 兜底默认：`10.7.0.1`（LocalDevVPN 出厂 peerIP；仅在 1、2 都拿不到时使用）.
    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: "TunnelDeviceIP")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        if let peer = utunPeerIPv4() { return peer }
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
        let interfaces = interfaceAddresses()
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
        let ipv4 = interfaceAddresses().filter { $0.family == AF_INET }
        if ipv4.isEmpty { return "（无）" }
        return ipv4.map { "\($0.name)=\($0.address)" }.joined(separator: ", ")
    }

    /// 探测隧道端口（49152，RPPairing 服务）是否可达（1 秒超时）.
    /// 用于自动重试前的预检：隧道未起时不建 RSD 隧道，避免反复失败
    /// 与 ServiceNotFound 竞争（v0.2.106）.
    static func isTunnelReachable() -> Bool {
        let ip = targetIP
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let parseResult = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // 连接超时 1 秒.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.stride))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.stride))

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        return result == 0
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

    /// 自动推导隧道**对端地址**：取本机 `utun*` 点对点接口的 IPv4 目的地址（`ifa_dstaddr`）.
    ///
    /// 为什么读 `ifa_dstaddr` 而不是接口地址：见 `targetIP` 注释 —— LocalDevVPN 把
    /// `tunnelRemoteAddress` 设成 peerIP，iOS 据此把 utun 配成点对点接口，
    /// `ifconfig` 显示为 `inet <ifaceIP> --> <peerIP>`：`ifa_addr` 是 ifaceIP，
    /// `ifa_dstaddr` 才是 peerIP.
    ///
    /// 返回 `nil` 的几种情况（都**安全退回**默认值，不改变现状、不新增假阴性）：
    ///   · 没有 utun 接口（隧道没起）；· utun 没有 IPv4 目的地址（非点对点 / 只有 IPv6）；
    ///   · 推出来的地址不像隧道对端（非私有地址、或等于本机接口地址）.
    private static func utunPeerIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var loose: String?   // 次选：任意合格的点对点 utun 对端
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            ptr = interface.ifa_next
            guard String(cString: interface.ifa_name).hasPrefix("utun") else { continue }

            // 点对点接口才有「目的地址」；非点对点的 `ifa_dstaddr` 是广播地址，必须排除.
            guard interface.ifa_flags & UInt32(IFF_POINTOPOINT) != 0 else { continue }
            guard let dstPtr = interface.ifa_dstaddr,
                  dstPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let peer = numericIPv4(dstPtr), isPrivateIPv4(peer) else { continue }

            let local: String? = (interface.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET))
                ? interface.ifa_addr.flatMap { numericIPv4($0) } : nil
            if let local, peer == local { continue }          // 对端 == 本机 ⇒ 不是点对点对端

            // 首选：与本机 utun 地址同处 `10.0.0.0/8`（LocalDevVPN 的隧道就是 10.x）.
            if let local, local.hasPrefix("10."), peer.hasPrefix("10.") { return peer }
            if loose == nil { loose = peer }
        }
        return loose
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

    /// 枚举本机接口地址（IPv4 与 IPv6 都收，带接口名与地址族）.
    /// 旧实现只看 `AF_INET` ⇒ LocalDevVPN 的 utun 若只给 IPv6 就会整条漏掉；
    /// 这里两个地址族都收，且**不过滤接口名**（utun / en0 / pdp_ip0 一视同仁）.
    private static func interfaceAddresses() -> [(name: String, family: Int32, address: String)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [(name: String, family: Int32, address: String)] = []
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
            results.append((name: name, family: family, address: String(cString: host)))
        }
        return results
    }
}
