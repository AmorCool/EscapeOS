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

    /// 隧道目标 IP（默认 10.7.0.1，与「设置 → 本地隧道」共用）.
    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: "TunnelDeviceIP")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return "10.7.0.1" }
        return stored
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

    /// 已安装则打开 LocalDevVPN 连接，否则跳 App Store.
    static func openOrInstall() {
        if isInstalled {
            openInstalled()
        } else {
            openAppStore()
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
