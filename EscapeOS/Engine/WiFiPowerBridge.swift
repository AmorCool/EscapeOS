import Foundation

/// WiFi 射频控制桥（v0.3.105）—— RSD 隧道 MCInstall `SetWiFiPowerState`
/// （pymobiledevice3 `profile set-wifi-power` 同款）。
///
/// 分工：
/// - Swift：rp_pairing 隧道建立（配对文件 + LocalDevVPN IP），建好后把
///   adapter/handshake **所有权移交**给 Rust（`lua_host_set_mcinstall_handles`）
/// - Rust：services 查 MCInstall.shim.remote 端口 → adapter.connect（隧道内转发，
///   裸 TCP 会被拒——v0.3.104 实测 Connection refused）→ XML plist 帧
///   （RSDCheckin 三步握手 + SetWiFiPowerState）
final class WiFiPowerBridge {
    static let shared = WiFiPowerBridge()
    private init() {}

    private let lock = NSLock()
    private var handlerRegistered = false

    private func makeError(_ message: String) -> NSError {
        stepLog("❌ " + message)
        return NSError(domain: "WiFiPower", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func stepLog(_ text: String) {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Modules/com.escapeos.wifitoggle/data/wifi_bridge.log")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let line = "[" + String(describing: Date()) + "] " + text + "\n"
        if let handle = FileHandle(forWritingAtPath: path.path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: path)
        }
    }

    /// 向 Lua 宿主注册原生 wifi handler；幂等。
    func ensureRegistered() {
        lock.lock(); defer { lock.unlock() }
        guard !handlerRegistered else { return }
        lua_host_set_wifi_power_fn(escapeos_wifi_power_cfn)
        handlerRegistered = true
    }

    // MARK: - 隧道建立 + 所有权移交（同步阻塞，供 handler 调用）

    /// 建 rp_pairing 隧道并把 adapter/handshake 移交给 Rust。
    /// 失败抛错（错误文本经 errOut 回 Lua）。
    func prepareTunnelAndHandover() throws {
        // 1) 配对文件
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件（需 LocalDevVPN + 开发者模式）")
        }
        stepLog("步骤1 配对文件 ✓")

        // 2) 隧道 IP
        let deviceIP = LocalDevVPN.targetIP
        guard !deviceIP.isEmpty else {
            throw makeError("隧道 IP 为空（请检查「设置 → 本地隧道」）")
        }

        // 3) rp_pairing 隧道（3 次退避）
        var created: (adapter: OpaquePointer, handshake: OpaquePointer)? = nil
        var lastError: NSError?
        for attempt in 0..<3 {
            var pairingFile: OpaquePointer?
            if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
                idevice_error_free(ffiError)
                throw makeError("读取配对文件失败")
            }
            defer { rp_pairing_file_free(pairingFile) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(49152).bigEndian
            _ = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

            var adapter: OpaquePointer?
            var handshake: OpaquePointer?
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
                            &adapter,
                            &handshake
                        )
                    }
                }
            }
            if let ffiError {
                idevice_error_free(ffiError)
                lastError = makeError("创建开发者隧道失败（attempt \(attempt)）")
            } else if let adapter, let handshake {
                created = (adapter, handshake)
                break
            } else {
                adapter_free(adapter)
                rsd_handshake_free(handshake)
                lastError = makeError("创建开发者隧道失败")
            }
            usleep(useconds_t(300_000 * (attempt + 1)))
        }
        guard let (adapter, handshake) = created else {
            throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
        }
        stepLog("步骤2 隧道创建 ✓（IP=\(deviceIP)）")

        // 4) 所有权移交 Rust（此后 Swift 不再释放；Rust 用完自行释放）
        // 移交 adapter/handshake 所有权 + 配对文件路径（Rust 侧用它起 lockdownd 会话）
        pairingPath.withCString { p in
            lua_host_set_mcinstall_handles(
                UnsafeMutableRawPointer(adapter), UnsafeMutableRawPointer(handshake), p)
        }
        stepLog("步骤3 adapter/handshake 所有权已移交 Rust ✓")
    }
}

/// 注册进 Lua 宿主的原生 handler（C 函数指针；由 Rust wifi_set_power 两阶段调用）。
/// 阶段 1：建隧道 + 移交所有权；阶段 2 由 Rust 完成 MCInstall 协议。
let escapeos_wifi_power_cfn: @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 = { on, errOut in
    do {
        try WiFiPowerBridge.shared.prepareTunnelAndHandover()
        if let errOut { errOut.pointee = strdup("tunnel ready") }
        return 0
    } catch {
        if let errOut { errOut.pointee = strdup((error as NSError).localizedDescription) }
        return -1
    }
}
