import Darwin
import Foundation
import UIKit

/// LocalDevVPN 检测 / 打开（移植自 locus-ZH）。
/// 隧道 IP 与 EscapeSpace「设置 → 本地隧道」的 TunnelDeviceIP 联动。
enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// 启动隧道后通过 scheme 回到 EscapeSpace。
    static let enableURL = URL(string: "localdevvpn://enable?scheme=escapeos")!

    /// 隧道目标 IP（默认 10.7.0.1，与「设置 → 本地隧道」共用）。
    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: "TunnelDeviceIP")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return "10.7.0.1" }
        return stored
    }

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    /// LocalDevVPN 连接时会在本机放置 10.7.0.x（或自定义）的 utun 地址。
    static var isConnected: Bool {
        let addresses = ipv4InterfaceAddresses()
        let target = targetIP
        if addresses.contains(target) { return true }

        let parts = target.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.dropLast().joined(separator: ".") + "."
        return addresses.contains { $0.hasPrefix(prefix) }
    }

    /// 探测隧道端口（49152，RPPairing 服务）是否可达（1 秒超时）。
    /// 用于自动重试前的预检：隧道未起时不建 RSD 隧道，避免反复失败
    /// 与 ServiceNotFound 竞争（v0.2.106）。
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

        // 连接超时 1 秒。
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

    /// 已安装则打开 LocalDevVPN 连接，否则跳 App Store。
    static func openOrInstall() {
        if isInstalled {
            openInstalled()
        } else {
            openAppStore()
        }
    }

    private static func ipv4InterfaceAddresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(
                    interface.ifa_addr,
                    nameLen,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    results.append(String(cString: host))
                }
            }
            ptr = interface.ifa_next
        }
        return results
    }
}
