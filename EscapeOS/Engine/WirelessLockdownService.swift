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
//  v0.3.243：修复两个开关必报「读取配对文件失败：failed to parse raw pairing file
//  from bytes」。v0.3.242 在 SetValue 前插入了 idevice_pairing_file_read +
//  lockdownd_start_session，但本 App 的 pairingFile.plist 是远程配对文件
//  （RpPairingFile：identifier/public_key/private_key/alt_irk，iPASide 或 iOS 27
//  无线配对产出），经典 IdevicePairingFile 需要 DeviceCertificate/HostPrivateKey/
//  SystemBUID 等 USB 配对字段，解析必然失败——两个开关因此 100% 报错。
//  且 RSD 隧道（lockdownd_connect_rsd）本来就无 StartSession 步骤：隧道自身即
//  信任边界，pymobiledevice3 的 RemoteLockdownClient 与 idevice crate 的
//  set_value 文档示例（恰为 wireless_lockdown 域）都是直连后直接 SetValue。
//  现在 connect_rsd → set_value，与 DeviceInfoService/BatteryHealthService/
//  DeviceControlService 等已验证可用的 lockdownd 调用点一致.
//
//  v0.3.245：真机反馈两个开关「开关弹回 / 射频无实际效果 / 无法关闭 / 无状态识别」.
//  ① 射频开关改走 MCInstall SetWiFiPowerState 真路径（见下方公开操作注释）；
//  ② EnableWifiConnections 增加 GetValue 状态读回（iDescriptor 同款数据源）；
//  ③ 修复 TreasureBoxView 从未给 wifiPairingOn 赋值导致的弹回/无法关闭.
//

enum WirelessLockdownService {

    private static let domain = "com.apple.mobile.wireless_lockdown"

    /// MCInstall 的 RSD 服务名（pymobiledevice3 MobileConfig.RSD_SERVICE_NAME 同款）.
    private static let mcInstallRSDService = "com.apple.mobile.MCInstall.shim.remote"

    /// 射频开关最后一次设定值的持久化键（MCInstall 无读取请求，write-only）.
    static let wifiPowerStateKey = "wifiPowerStateLast"

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
    /// v0.3.243：不再尝试 lockdownd_start_session——见文件头说明.
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

    /// Wi-Fi 射频开关（真路径：MCInstall SetWiFiPowerState）
    ///
    /// v0.3.245：lockdown SetValue("WifiPowerState") 在现代 iOS 被 lockdownd 静默
    /// 接受但不生效（真机实测），射频开关的正路是 MCInstall 服务的 SetWiFiPowerState
    /// 请求（pymobiledevice3 `profile set-wifi-power` / Apple Configurator 同款）：
    /// RSD 服务表直连 `com.apple.mobile.MCInstall.shim.remote` → RSDCheckin →
    /// SetWiFiPowerState，全程不经过 lockdownd（无 StartService/配对文件/StartSession
    /// ——v0.3.105 Rust 版「实测不可用」的根因正是在此路径上多走了 lockdownd 三步）.
    /// MCInstall 服务缺失（老系统）时回退 lockdown SetValue.
    static func setWifiPower(_ on: Bool) throws {
        do {
            try mcinstallSetWifiPower(on)
            UserDefaults.standard.set(on, forKey: wifiPowerStateKey)
            return
        } catch {
            // shim.remote 服务不存在（老系统）才回退；其他错误（超时/拒绝）如实上抛
            let msg = (error as NSError).localizedDescription
            guard msg.contains("RSD 服务表无") else { throw error }
            try setValue(key: "WifiPowerState", value: on)
            UserDefaults.standard.set(on, forKey: wifiPowerStateKey)
        }
    }

    /// 局域网 Wi-Fi 配对连接（EnableWifiConnections）
    static func enableWifiConnections() throws {
        try setValue(key: "EnableWifiConnections", value: true)
    }

    /// 停用局域网 Wi-Fi 配对连接
    static func disableWifiConnections() throws {
        try setValue(key: "EnableWifiConnections", value: false)
    }

    /// 读回 EnableWifiConnections 当前状态（lockdownd GetValue over RSD 隧道）.
    /// iDescriptor 同款数据源；隧道不可用/读不到时返回 nil（UI 显示未知而非误报）.
    static func readWifiConnectionsEnabled() -> Bool? {
        do {
            let value = try getValue(key: "EnableWifiConnections", domain: domain)
            return value
        } catch {
            return nil
        }
    }

    // MARK: - lockdownd GetValue

    /// lockdown GetValue（单键 Bool）——与 setValue 同一隧道/会话模式（无 StartSession）.
    private static func getValue(key: String, domain: String) throws -> Bool {
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

        // plist_t = UnsafeMutableRawPointer?（非 OpaquePointer，DeviceInfoService 同款）
        var node: plist_t?
        let rc = key.withCString { k in
            domain.withCString { d in
                lockdownd_get_value(client, k, d, &node)
            }
        }
        if let rc { throw error(from: rc, fallback: "读取 \(key) 失败") }
        guard let node else { throw makeError("读取 \(key) 返回空") }
        defer { plist_free(node) }

        // plist bool 节点 → Swift Bool（经二进制序列化走 Foundation 解析，同 DeviceInfoService）
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
              let binPtr, binLen > 0,
              let obj = try? PropertyListSerialization.propertyList(
                  from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil)
        else {
            throw makeError("解析 \(key) 值失败")
        }
        guard let boolVal = obj as? Bool else {
            throw makeError("\(key) 值不是布尔（\(type(of: obj))）")
        }
        return boolVal
    }

    // MARK: - MCInstall SetWiFiPowerState（纯 Swift，pmd3 MobileConfig 同款）

    private static let plistHeader = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    """

    /// 4 字节大端长度帧（对齐 idevice crate send_plist）
    private static func framed(_ xml: String) -> Data {
        let body = Data(xml.utf8)
        var out = Data(capacity: body.count + 4)
        var beLen = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &beLen) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    private static func sendFrame(_ stream: OpaquePointer, _ xml: String) throws {
        let data = framed(xml)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw makeError("MCInstall 请求缓冲为空")
            }
            if let ffiError = adapter_send(stream, base, UInt(raw.count)) {
                throw error(from: ffiError, fallback: "发送 MCInstall 请求失败")
            }
        }
    }

    /// 精确读 n 字节（adapter_recv 单次 read ≤2048 且可能欠读，必须循环补齐）
    private static func recvExact(_ stream: OpaquePointer, _ n: Int) throws -> Data {
        var out = Data(capacity: n)
        var buf = [UInt8](repeating: 0, count: max(n, 2048))
        while out.count < n {
            var got: UInt = 0
            if let ffiError = buf.withUnsafeMutableBufferPointer({ bp in
                adapter_recv(stream, bp.baseAddress, &got, UInt(bp.count))
            }) {
                throw error(from: ffiError, fallback: "接收 MCInstall 响应失败")
            }
            guard got > 0 else { throw makeError("MCInstall 连接被对端关闭") }
            out.append(contentsOf: buf[..<Int(got)])
        }
        // 欠读循环可能多收（不该发生——逐帧精确读），截掉超出部分
        if out.count > n { out.removeLast(out.count - n) }
        return out
    }

    /// 读一个完整 plist 帧（4B 大端长度 + 体）并转字符串
    private static func recvPlistFrame(_ stream: OpaquePointer) throws -> String {
        let lenData = try recvExact(stream, 4)
        let beLen: UInt32 = lenData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard beLen > 0, beLen < 4 * 1024 * 1024 else {
            throw makeError("MCInstall 响应长度异常: \(beLen)")
        }
        let body = try recvExact(stream, Int(beLen))
        guard let s = String(data: body, encoding: .utf8) else {
            throw makeError("MCInstall 响应非 UTF-8")
        }
        return s
    }

    /// RSDCheckin 三步握手（pmd3 start_lockdown_service 同款：RSDCheckin 应答 + StartService 应答）
    private static func rsdCheckin(_ stream: OpaquePointer) throws {
        try sendFrame(stream, """
        \(plistHeader)<dict><key>Label</key><string>EscapeSpaceMCInstall</string>\
        <key>ProtocolVersion</key><string>2</string>\
        <key>Request</key><string>RSDCheckin</string></dict></plist>
        """)
        let r1 = try recvPlistFrame(stream)
        guard r1.contains("RSDCheckin") else {
            throw makeError("RSDCheckin 应答不匹配: \(r1.prefix(200))")
        }
        let r2 = try recvPlistFrame(stream)
        guard r2.contains("StartService") else {
            throw makeError("StartService 应答不匹配: \(r2.prefix(200))")
        }
        if r2.contains("<key>Error</key>") {
            throw makeError("RSDCheckin StartService 报错: \(r2.prefix(200))")
        }
    }

    /// MCInstall SetWiFiPowerState 全流程（连接→握手→写值→校验 Acknowledged）
    private static func mcinstallSetWifiPower(_ on: Bool) throws {
        let tunnel = try createTunnel()
        defer {
            rsd_handshake_free(tunnel.handshake)
            adapter_free(tunnel.adapter)
        }

        // 1) RSD 服务表拿 shim.remote 端口（RSD 握手自带服务表，无需 StartService RPC）
        var serviceInfo: UnsafeMutablePointer<CRsdService>?
        if let ffiError = mcInstallRSDService.withCString({
            rsd_get_service_info(tunnel.handshake, $0, &serviceInfo)
        }) {
            throw error(from: ffiError, fallback: "RSD 服务表查询失败")
        }
        guard let serviceInfo else { throw makeError("RSD 服务表无 \(mcInstallRSDService)（设备不支持射频开关）") }
        defer { rsd_free_service(serviceInfo) }
        let port = serviceInfo.pointee.port
        guard port != 0 else { throw makeError("MCInstall 服务端口为 0") }

        // 2) 隧道内直连服务端口
        var stream: OpaquePointer?
        if let ffiError = adapter_connect(tunnel.adapter, port, &stream) {
            throw error(from: ffiError, fallback: "连接 MCInstall 服务失败")
        }
        guard let stream else { throw makeError("MCInstall 流未建立") }
        defer { idevice_stream_free(stream) }

        // 3) RSDCheckin 握手
        try rsdCheckin(stream)

        // 4) SetWiFiPowerState（pmd3 MobileConfig.set_wifi_power_state 同款请求体）
        let powerValue = on ? "<true/>" : "<false/>"
        try sendFrame(stream, """
        \(plistHeader)<dict><key>PowerState</key>\(powerValue)\
        <key>RequestType</key><string>SetWiFiPowerState</string></dict></plist>
        """)
        let reply = try recvPlistFrame(stream)
        if reply.contains("<key>Error</key>") {
            throw makeError("设备拒绝 SetWiFiPowerState: \(reply.prefix(300))")
        }
        guard reply.contains("Acknowledged") else {
            throw makeError("SetWiFiPowerState 未确认（期望 Acknowledged）: \(reply.prefix(300))")
        }
    }
}
