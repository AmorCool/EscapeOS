import Darwin
import Foundation
import NetworkExtension

/// EscapeSpace「内置隧道」扩展的入口类：一个**回环反射器**分组隧道.
///
/// 语义（与 LocalDevVPN 同口径，见简报「调研_VPN权限检测与内置隧道.md」§2.1）：
/// 把本 App 发往隧道对端（默认 `10.7.0.1`）的 IP 包，交换 IPv4 头的源/目的地址后原样
/// 写回网络栈，使其变成「来自对端、去往本机 utun 接口（默认 `10.7.1.1`）」的入站包，
/// 从而让**本机自己的**开发者服务（RSD 49152 等）通过对端地址可达.
///
/// 它**不**提供出口节点、**不**改变公网 IP、**不**需要远端服务器.
///
/// 并发标注：`NEPacketTunnelProvider`（及其父类 `NEProvider`）在 SDK 里**不是** `Sendable`
/// （已核对 Apple 文档的 Conforms To 只含 CVarArg / CustomDebugStringConvertible /
/// CustomStringConvertible / Equatable / Hashable / NSObjectProtocol），而
/// `readPackets` / `setTunnelNetworkSettings` 等完成回调必须捕获 `self` ⇒ 本类显式声明
/// `@unchecked Sendable`. 这是必要的（父类非 Sendable，故不构成冗余 conformance），
/// 且本类的可变状态只在 Network Extension 自己的回调里访问.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {

    /// 本机（utun 接口侧）地址 —— 与 LocalDevVPN 出厂值一致.
    private static let defaultIfaceIP = "10.7.1.1"

    /// 隧道对端地址 —— 与 LocalDevVPN 出厂值一致.
    private static let defaultPeerIP = "10.7.0.1"

    // MARK: - 生命周期

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let peerIP = (options?["peerIP"] as? String)
            ?? (config?["peerIP"] as? String)
            ?? Self.defaultPeerIP
        let ifaceIP = (options?["ifaceIP"] as? String)
            ?? (config?["ifaceIP"] as? String)
            ?? Self.defaultIfaceIP

        let ifaceEndpoint = Endpoint(ifaceIP, defaultPrefix: 24)
        let peerEndpoint = Endpoint(peerIP, defaultPrefix: 32)

        let ipv4 = NEIPv4Settings(
            addresses: [ifaceEndpoint.ip],
            subnetMasks: [ifaceEndpoint.subnetMask]
        )
        // 只把「去往对端」的包收进隧道；其余一律走隧道之外（不改默认出口）.
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: peerEndpoint.ip, subnetMask: peerEndpoint.subnetMask)
        ]
        ipv4.excludedRoutes = [.default()]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerEndpoint.ip)
        settings.ipv4Settings = ipv4

        NSLog("[EscapeOSTunnel] 启动 iface=%@ peer=%@.", ifaceEndpoint.ip, peerEndpoint.ip)
        setTunnelNetworkSettings(settings) { error in
            if let error {
                NSLog("[EscapeOSTunnel] 应用隧道网络设置失败：%@.", error.localizedDescription)
                completionHandler(error)
                return
            }
            self.startReflecting()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        NSLog("[EscapeOSTunnel] 停止 reason=%d.", reason.rawValue)
        completionHandler()
    }

    // MARK: - 回环反射

    /// 持续读取隧道收到的包、交换 IPv4 源/目的地址后写回，形成回环.
    ///
    /// 只处理 IPv4（`AF_INET`）且长度至少 20 字节（IPv4 头）的包；其它协议原样写回.
    private func startReflecting() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var modified = packets
            for index in modified.indices
            where protocols[index].int32Value == AF_INET && modified[index].count >= 20 {
                modified[index].withUnsafeMutableBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    // IPv4 头里，字（UInt32）下标 3 = 源地址（字节 12..15），
                    // 下标 4 = 目的地址（字节 16..19）——交换二者即完成反射.
                    let words = base.assumingMemoryBound(to: UInt32.self)
                    let source = words[3]
                    words[3] = words[4]
                    words[4] = source
                }
            }
            _ = self.packetFlow.writePackets(modified, withProtocols: protocols)
            self.startReflecting()
        }
    }

    // MARK: - CIDR 解析

    /// `ip` 或 `ip/prefix` 的解析结果（点分十进制 IPv4 + 点分十进制子网掩码）.
    ///
    /// 嵌套在 `PacketTunnelProvider` 内：本仓的防复发脚本
    /// `Resources/Scripts/swift_top_level_type_collision.py` 按**顶层声明**（行首无缩进）
    /// 扫描，嵌套类型不计入，避免与主 App 的同名类型误报.
    private struct Endpoint {
        let ip: String
        let subnetMask: String

        init(_ input: String, defaultPrefix: Int) {
            let pieces = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            self.ip = String(pieces[0])
            let prefix = pieces.count > 1 ? (Int(pieces[1]) ?? defaultPrefix) : defaultPrefix
            self.subnetMask = Self.mask(forPrefix: prefix)
        }

        /// 由前缀长度算出点分十进制子网掩码（如 24 ⇒ 255.255.255.0）.
        private static func mask(forPrefix prefix: Int) -> String {
            let clamped = max(0, min(32, prefix))
            let value: UInt32 = clamped == 0 ? 0 : (~UInt32(0) << (32 - clamped))
            let b0 = (value >> 24) & 0xFF
            let b1 = (value >> 16) & 0xFF
            let b2 = (value >> 8) & 0xFF
            let b3 = value & 0xFF
            return "\(b0).\(b1).\(b2).\(b3)"
        }
    }
}
