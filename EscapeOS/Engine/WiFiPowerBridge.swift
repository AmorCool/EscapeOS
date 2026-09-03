import Foundation

/// WiFi 射频控制桥（v0.3.103）—— RSD 隧道 MCInstall `SetWiFiPowerState`
/// （pymobiledevice3 `profile set-wifi-power` 同款：设备自己的服务有权限，
/// App 直调 MobileWiFi 无 entitlement 是空操作）。
///
/// 全 Swift 实现：
/// rp_pairing 隧道 → rsd_get_services 找 MCInstall.shim.remote 端口
/// → TCP 直连（隧道 IP:端口）→ XML plist 帧（4B BE 长度）
/// → RSDCheckin 三步握手 → SetWiFiPowerState → 结果回传 Lua。
final class WiFiPowerBridge {
    static let shared = WiFiPowerBridge()
    private init() {}

    private let lock = NSLock()
    private var handlerRegistered = false

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "WiFiPower", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    /// 向 Lua 宿主注册原生 wifi handler；幂等。
    func ensureRegistered() {
        lock.lock(); defer { lock.unlock() }
        guard !handlerRegistered else { return }
        lua_host_set_wifi_power_fn(escapeos_wifi_power_impl)
        handlerRegistered = true
    }

    // MARK: - 射频控制（同步阻塞，供 handler 调用）

    func performPower(_ on: Bool) throws {
        // 1) 配对文件
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件（需 LocalDevVPN + 开发者模式）")
        }

        // 2) 隧道 IP
        let deviceIP = LocalDevVPN.targetIP
        guard !deviceIP.isEmpty else {
            throw makeError("隧道 IP 为空（请检查「设置 → 本地隧道」）")
        }

        // 3) 建 rp_pairing 隧道（3 次退避）→ adapter + handshake
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
        defer {
            adapter_free(adapter)
            rsd_handshake_free(handshake)
        }

        // 4) 从 RSD 握手查 MCInstall.shim.remote 端口
        var servicesArray: UnsafeMutablePointer<CRsdServiceArray>?
        if let ffiError = rsd_get_services(handshake, &servicesArray) {
            idevice_error_free(ffiError)
            throw makeError("获取 RSD 服务列表失败")
        }
        defer { rsd_free_services(servicesArray) }
        var mcPort: UInt16?
        if let arr = servicesArray?.pointee.services {
            let count = Int(servicesArray?.pointee.count ?? 0)
            for i in 0..<count {
                let svc = arr[i]
                let name = svc.name.map { String(cString: $0) } ?? ""
                if name == "com.apple.mobile.MCInstall.shim.remote" {
                    mcPort = svc.port
                    break
                }
            }
        }
        guard let port = mcPort else {
            throw makeError("RSD 服务列表中无 MCInstall.shim.remote")
        }

        // 5) TCP 直连（隧道 IP:服务端口）
        let fd = try connectSocket(ip: deviceIP, port: port)
        defer { close(fd) }

        // 6) RSDCheckin 三步握手
        try sendPlist(fd, dict: [
            ("Label", .string("EscapeSpaceWiFiPower")),
            ("ProtocolVersion", .string("2")),
            ("Request", .string("RSDCheckin")),
        ])
        let r1 = try readFrame(fd)
        guard r1.contains("RSDCheckin") else { throw makeError("RSDCheckin 响应不匹配: \(r1.prefix(200))") }
        let r2 = try readFrame(fd)
        guard r2.contains("StartService") else { throw makeError("StartService 响应不匹配: \(r2.prefix(200))") }

        // 7) SetWiFiPowerState
        try sendPlist(fd, dict: [
            ("PowerState", .bool(on)),
            ("RequestType", .string("SetWiFiPowerState")),
        ])
        let reply = try readFrame(fd)
        if reply.contains("<key>Error</key>") {
            throw makeError("SetWiFiPowerState 设备返回错误: \(reply.prefix(300))")
        }
    }

    // MARK: - TCP + plist 帧

    private func connectSocket(ip: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw makeError("socket 创建失败") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ok = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) } == 1
        guard ok else {
            close(fd)
            throw makeError("IP 解析失败: \(ip)")
        }
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw makeError("连接 \(ip):\(port) 失败: \(String(cString: strerror(e)))")
        }
        return fd
    }

    private enum PValue {
        case string(String)
        case bool(Bool)
    }

    private func sendPlist(_ fd: Int32, dict: [(String, PValue)]) throws {
        var body = "<dict>"
        for (key, value) in dict {
            body += "<key>\(key)</key>"
            switch value {
            case .string(let s): body += "<string>\(s)</string>"
            case .bool(let b): body += b ? "<true/>" : "<false/>"
            }
        }
        body += "</dict>"
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " +
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\">\(body)</plist>"
        try sendFrame(fd, xml: xml)
    }

    private func sendFrame(_ fd: Int32, xml: String) throws {
        let bytes = Array(xml.utf8)
        var lenBE = UInt32(bytes.count).bigEndian
        try withUnsafeBytes(of: &lenBE) { raw in
            try writeRaw(fd, raw.baseAddress!, raw.count)
        }
        try bytes.withUnsafeBytes { raw in
            try writeRaw(fd, raw.baseAddress!, raw.count)
        }
    }

    private func readFrame(_ fd: Int32) throws -> String {
        var lenBE = UInt32(0)
        try withUnsafeMutableBytes(of: &lenBE) { raw in
            try readRaw(fd, raw.baseAddress!, raw.count)
        }
        let len = UInt32(bigEndian: lenBE)
        guard len > 0, len < 4 * 1024 * 1024 else { throw makeError("plist 帧长度异常: \(len)") }
        var body = [UInt8](repeating: 0, count: Int(len))
        try body.withUnsafeMutableBytes { raw in
            try readRaw(fd, raw.baseAddress!, raw.count)
        }
        return String(bytes: body, encoding: .utf8) ?? "（非 UTF-8 plist）"
    }

    private func writeRaw(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) throws {
        var offset = 0
        while offset < count {
            let n = send(fd, base.advanced(by: offset), count - offset, 0)
            if n <= 0 { throw makeError("发送失败 errno=\(errno)") }
            offset += n
        }
    }

    private func readRaw(_ fd: Int32, _ base: UnsafeMutableRawPointer, _ count: Int) throws {
        var offset = 0
        while offset < count {
            let n = recv(fd, base.advanced(by: offset), count - offset, 0)
            if n <= 0 { throw makeError("接收失败 errno=\(errno)") }
            offset += n
        }
    }
}

/// 注册进 Lua 宿主的原生 handler（C 函数指针；由 Rust wifi_set_power 回调）。
/// 无捕获 @convention(c) 闭包 —— 阻塞当前线程（Lua 宿主工作线程）直至隧道操作完成。
let escapeos_wifi_power_cfn: @convention(c) (Int32) -> Int32 = { on in
    do {
        try WiFiPowerBridge.shared.performPower(on == 1)
        return 0
    } catch {
        return -1
    }
}
