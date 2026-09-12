//
//  DeveloperModeService.swift
//  EscapeOS
//
//  v0.3.328：开发者模式（Developer Mode）检测 + 开启。
//  参考 iDescriptor（src/service_manager.rs）：
//    · 状态：lockdown `get_value("DeveloperModeStatus", "com.apple.security.mac.amfi")`
//      —— 与「激活锁」同理，这个域必须**按 key 读**，整域读是空的。
//    · 开启：RSD 的 amfi 服务（com.apple.amfi.lockdown）：
//        action 0 = reveal_developer_mode_option_in_ui（让「设置」里出现开关）
//        action 1 = enable_developer_mode（真正打开）
//  ⚠️ **关闭没有接口**：amfi 只有 0/1/2/3/4 五个 action（无 disable），
//     关闭只能去设备「设置 → 隐私与安全性 → 开发者模式」手动关。
//
import Foundation

enum DeveloperModeService {

    private static let domain = "com.apple.security.mac.amfi"
    private static let statusKey = "DeveloperModeStatus"

    /// 本服务自己的串行队列（RSD 隧道铁律：同 hostname 并发 tunnel_create_rppairing 会互抢）
    private static let queue = DispatchQueue(label: "com.ipaside.escapeos.developer-mode")

    // MARK: - 错误

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "DeveloperModeService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
                              fallback: String) -> NSError {
        var message = ffiError?.pointee.message.map { String(cString: $0) } ?? ""
        if message.hasPrefix("UnexpectedResponse(\""), message.hasSuffix("\")") {
            message = String(message.dropFirst("UnexpectedResponse(\"".count).dropLast(2))
        }
        let code = ffiError.map { Int($0.pointee.code) } ?? -1
        if let ffiError { idevice_error_free(ffiError) }
        return NSError(domain: "DeveloperModeService", code: code,
                       userInfo: [NSLocalizedDescriptionKey:
                                    message.isEmpty ? fallback : "\(fallback)：\(message)"])
    }

    // MARK: - 状态（lockdown，按 key 读）

    /// 设备当前是否已开启开发者模式；读不到返回 nil（UI 显示未知，**不要**当成「关」）
    static func status() -> Bool? {
        (try? DeviceInfoService.lockdownValue(domain: domain, key: statusKey)) as? Bool
    }

    // MARK: - 开启（RSD amfi）

    /// 让「设置 → 隐私与安全性」里出现开发者模式开关（不改状态）
    static func revealOptionInSettings() throws {
        try withAMFIClient { client in
            if let e = amfi_reveal_developer_mode_option_in_ui(client) {
                throw error(from: e, fallback: "在设置中显示开发者模式开关失败")
            }
        }
    }

    /// 开启开发者模式（先让开关出现在设置里，再下发开启）
    static func enable() throws {
        try withAMFIClient { client in
            if let e = amfi_reveal_developer_mode_option_in_ui(client) {
                throw error(from: e, fallback: "在设置中显示开发者模式开关失败")
            }
            if let e = amfi_enable_developer_mode(client) {
                throw error(from: e, fallback: "开启开发者模式失败")
            }
        }
    }

    private static func withAMFIClient(_ body: (OpaquePointer) throws -> Void) throws {
        try queue.sync { () -> Void in
            let tunnel = try createTunnel()
            defer { tunnel.release() }
            var client: OpaquePointer?
            if let e = amfi_connect_rsd(tunnel.adapter, tunnel.handshake, &client) {
                throw error(from: e, fallback: "连接 amfi 服务失败（设备未暴露该服务？）")
            }
            guard let client else { throw makeError("amfi 客户端创建失败") }
            defer { amfi_client_free(client) }
            try body(client)
        }
    }

    // MARK: - 隧道（与其它 RSD 服务同款：配对文件 + LocalDevVPN IP + 3 次退避）

    private struct Tunnel {
        let adapter: OpaquePointer
        let handshake: OpaquePointer

        func release() {
            rsd_handshake_free(handshake)
            adapter_free(adapter)
        }
    }

    private static func createTunnel(hostname: String = "EscapeSpaceDevMode") throws -> Tunnel {
        let pairingPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件。请先导入配对文件.")
        }

        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("配对文件解析失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var adapter: OpaquePointer?
            var handshake: OpaquePointer?
            let ffiError = hostname.withCString { host in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            host,
                            pairingFile,
                            nil,
                            nil,
                            &adapter,
                            &handshake
                        )
                    }
                }
            }
            if let ffiError {
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
                if let handshake { rsd_handshake_free(handshake) }
                if let adapter { adapter_free(adapter) }
            } else if let adapter, let handshake {
                return Tunnel(adapter: adapter, handshake: handshake)
            } else {
                lastError = makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }
}
