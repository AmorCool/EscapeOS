import Foundation

//
//  WirelessLockdownService.swift
//  EscapeOS
//
//  v0.3.240：Wi-Fi 射频/局域网配对连接（pymobiledevice3 lockdown SetValue 式方案）.
//  通过 RSD 隧道 lockdownd 会话向 `com.apple.mobile.wireless_lockdown` domain 写值：
//  - WifiPowerState       设备 Wi-Fi 射频开关
//  - EnableWifiConnections 允许局域网 Wi-Fi 配对连接（iDescriptor 同款）
//  替代原 WiFiPowerBridge 两阶段 Lua 桥（MCInstall SetWiFiPowerState，实测不可用）.
//

enum WirelessLockdownService {

    private static let domain = "com.apple.mobile.wireless_lockdown"

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "WirelessLockdownService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        let message = ffiError?.pointee.message.map { String(cString: $0) } ?? ""
        let code = ffiError.map { Int($0.pointee.code) } ?? -1
        if let ffiError { idevice_error_free(ffiError) }
        return NSError(domain: "WirelessLockdownService", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : "\(fallback)：\(message)"])
    }

    private static func createTunnel() throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
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
            throw makeError("隧道 IP 无效：\(deviceIP)")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        let ffiError = "EscapeSpaceWireless".withCString { hostname in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostname,
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
            throw error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
        }
        guard let adapter, let handshake else { throw makeError("创建开发者隧道失败") }
        return (adapter, handshake)
    }

    /// lockdown SetValue（domain: com.apple.mobile.wireless_lockdown）
    private static func setValue(key: String, value: Bool) throws {
        let tunnel = try createTunnel()
        defer {
            rsd_handshake_free(tunnel.handshake)
            adapter_free(tunnel.adapter)
        }
        var client: OpaquePointer?
        if let ffiError = lockdownd_connect_rsd(tunnel.adapter, tunnel.handshake, &client) {
            throw error(from: ffiError, fallback: "连接 lockdownd 失败")
        }
        guard let client else { throw makeError("lockdownd 客户端创建失败") }
        defer { lockdownd_client_free(client) }

        // v0.3.242：set_value 前启动配对会话（否则写 wireless_lockdown 域不生效）。
        // lockdownd_start_session 只接受 IdevicePairingFile（idevice_pairing_file_read 产出）；
        // 不能复用 createTunnel 里的 RpPairingFileHandle —— 两者都是不透明指针但底层布局不同，
        // 强传会按错误结构解引用 host_id/system_buid，直接闪退。
        var pairingFile: OpaquePointer?
        let pairingPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        if let ffiError = pairingPath.withCString({ idevice_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("配对文件解析失败") }
        defer { idevice_pairing_file_free(pairingFile) }
        if let ffiError = lockdownd_start_session(client, pairingFile) {
            throw error(from: ffiError, fallback: "启动 lockdownd 会话失败")
        }

        let plistValue = plist_new_bool(value ? 1 : 0)
        defer { plist_free(plistValue) }

        if let ffiError = key.withCString({ k in
            domain.withCString { d in
                lockdownd_set_value(client, k, plistValue, d)
            }
        }) {
            throw error(from: ffiError, fallback: "写入 \(key) 失败")
        }
    }

    // MARK: - 公开操作

    /// Wi-Fi 射频开关（WifiPowerState）
    static func setWifiPower(_ on: Bool) throws {
        try setValue(key: "WifiPowerState", value: on)
    }

    /// 局域网 Wi-Fi 配对连接（EnableWifiConnections）
    static func enableWifiConnections() throws {
        try setValue(key: "EnableWifiConnections", value: true)
    }

    /// 停用局域网 Wi-Fi 配对连接
    static func disableWifiConnections() throws {
        try setValue(key: "EnableWifiConnections", value: false)
    }
}
