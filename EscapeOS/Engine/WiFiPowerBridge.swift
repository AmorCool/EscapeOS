import Foundation

/// WiFi 射频控制桥（v0.3.102）—— RSD 隧道 MCInstall `SetWiFiPowerState`
/// （pymobiledevice3 `profile set-wifi-power` 同款：设备自己的服务有权限，
/// App 直调 MobileWiFi 无 entitlement 是空操作）。
///
/// 流程：rp_pairing 隧道 → mcinstall_connect_rsd → mcinstall_set_wifi_power
/// → 结果回传 Lua（经 lua_host_set_wifi_power_fn 注册的原生 handler）。
final class WiFiPowerBridge {
    static let shared = WiFiPowerBridge()
    private init() {}

    private let lock = NSLock()
    private var handlerRegistered = false
    private var clientHandle: OpaquePointer?     // McInstallClientHandle*
    private var clientTunnel: TunnelHandles?

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "WiFiPower", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "WiFiPower", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    // MARK: - 注册（App 启动 / Lua 运行前调用一次）

    /// 向 Lua 宿主注册原生 wifi handler；幂等。
    func ensureRegistered() {
        lock.lock(); defer { lock.unlock() }
        guard !handlerRegistered else { return }
        lua_host_set_wifi_power_fn(escapeos_wifi_power_impl)
        handlerRegistered = true
    }

    // MARK: - 射频控制（同步阻塞，供 handler 调用）

    /// 切换 WiFi 射频。失败抛错（错误文本会进入 Lua 输出）。
    func performPower(_ on: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        // 一次机会用现有客户端，失败即重建隧道重试一次
        if let handle = clientHandle {
            if tryPowerWithClient(handle, on: on) { return }
            dropClient()
        }
        try createClient()
        guard let handle = clientHandle else { throw makeError("MCInstall 客户端创建失败") }
        if tryPowerWithClient(handle, on: on) { return }
        dropClient()
        throw makeError("SetWiFiPowerState 失败（隧道已重建仍失败）")
    }

    private func tryPowerWithClient(_ handle: OpaquePointer, on: Bool) -> Bool {
        var reply: UnsafeMutablePointer<CChar>?
        let ffiError = mcinstall_set_wifi_power(handle, on, &reply)
        if let ffiError {
            idevice_error_free(ffiError)
            return false
        }
        if let reply {
            defer { mcinstall_string_free(reply) }
            let text = String(cString: reply)
            appendLog("SetWiFiPowerState(\(on)) 响应: \(text.prefix(200))")
        }
        return true
    }

    private func dropClient() {
        if let clientHandle { mcinstall_client_free(clientHandle); self.clientHandle = nil }
        clientTunnel?.free()
        clientTunnel = nil
    }

    private func appendLog(_ text: String) {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modules/com.escapeos.wifitoggle/data/wifi_bridge.log")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let line = "[\(Date())] \(text)\n"
        if let handle = FileHandle(forWritingAtPath: path.path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: path)
        }
    }

    // MARK: - 隧道 + 客户端建立（RingtonesService 同款 rp_pairing 模式）

    private func createClient() throws {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件（需 LocalDevVPN + 开发者模式）")
        }
        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = "EscapeSpaceWiFiPower".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
                    }
                }
            }
            var created = false
            if let ffiError {
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                // 建 MCInstall 客户端
                var client: OpaquePointer?
                if let ffiError = mcinstall_connect_rsd(tunnel.adapter, tunnel.handshake, &client) {
                    lastError = error(from: ffiError, fallback: "连接 MCInstall 服务失败")
                } else if let client {
                    clientHandle = client
                    clientTunnel = tunnel
                    created = true
                } else {
                    lastError = makeError("MCInstall 客户端创建失败")
                }
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if created { return }
            tunnel.free()
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }
}

/// 注册进 Lua 宿主的原生 handler（C ABI；由 Rust wifi_set_power 回调）
@_cdecl("escapeos_wifi_power_impl")
func escapeos_wifi_power_impl(_ on: Int32) -> Int32 {
    // 阻塞当前线程（Lua 宿主工作线程）直至隧道操作完成
    do {
        try WiFiPowerBridge.shared.performPower(on == 1)
        return 0
    } catch {
        return -1
    }
}
