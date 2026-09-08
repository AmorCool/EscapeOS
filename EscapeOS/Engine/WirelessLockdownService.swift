import Foundation

//
//  WirelessLockdownService.swift
//  EscapeOS
//
//  v0.3.240：Wi-Fi 射频/局域网配对连接（pymobiledevice3 lockdown SetValue 式方案）.
//  通过 RSD 隧道 lockdownd 会话向 `com.apple.mobile.wireless_lockdown` domain 写值：
//  - WifiPowerState        设备 Wi-Fi 射频开关
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
//  ① 射频开关改走 MCInstall SetWiFiPowerState 真路径；
//  ② EnableWifiConnections 增加 GetValue 状态读回（iDescriptor 同款数据源）；
//  ③ 修复 TreasureBoxView 从未给 wifiPairingOn 赋值导致的弹回/无法关闭.
//
//  v0.3.247：射频开关点按闪退修复（v0.3.244/245 纯 Swift 手写帧版本真机实测闪退）.
//  ① 协议整体下沉到 Rust `mcinstall_set_wifi_power_rsd`：RSD 服务表取 shim.remote
//    端口 → 隧道内直连 → RSDCheckin → SetWiFiPowerState → 校验 Acknowledged，
//    全在 Rust 同一个 tokio 上下文内完成。Swift 侧不再手写 4 字节长度帧、不再用
//    adapter_send/adapter_recv 裸指针收发（FFI 头明确写着「stream 必须与 adapter
//    同线程、句柄非线程安全」，Swift 侧跨 run_sync 边界反复收发正是崩溃根源）.
//  ② 补上 idevice.h 缺失的 `mcinstall_set_wifi_power_rsd` 声明（此前只有 Rust 实现
//    没有 C 声明，Swift 侧根本引用不到）.
//  ③ 服务可用性判定改为 RSD 服务表确定性查询（rsd_get_service_info），不再靠猜
//    「FFI 错误码 21 == ServiceNotFound」这种没验证过的映射.
//  ④ 所有操作走同一条串行队列（RSD 隧道并发铁律，与 AFCService 同款），且一次操作
//    只建一条隧道（此前「局域网配对」一次要建 2 条，页面 onAppear 还会再建 1 条）.
//  ⑤ plist_to_bin 产出的 buffer 用 plist_mem_free 释放（此前每次读值都泄漏）.
//

enum WirelessLockdownService {

    private static let domain = "com.apple.mobile.wireless_lockdown"

    /// MCInstall 的 RSD 服务名（pymobiledevice3 MobileConfig.RSD_SERVICE_NAME 同款）.
    private static let mcInstallRSDService = "com.apple.mobile.MCInstall.shim.remote"

    /// 射频开关最后一次设定值的持久化键（MCInstall 无读取请求，write-only）.
    static let wifiPowerStateKey = "wifiPowerStateLast"

    /// RSD 隧道并发铁律（AFCService 同款）：同一 hostname 并发 `tunnel_create_rppairing`
    /// 会互相抢占，本服务所有操作全部经 `queue` 串行执行.
    private static let queue = DispatchQueue(label: "com.ipaside.escapeos.wireless-lockdown")

    // MARK: - 错误

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "WirelessLockdownService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        var message = ffiError?.pointee.message.map { String(cString: $0) } ?? ""
        // v0.3.248：Rust 侧 {:?} 调试格式会把枚举外壳带上（如 UnexpectedResponse("正文")），
        // 剥掉只留正文，避免界面出现一坨调试语法
        if message.hasPrefix("UnexpectedResponse(\""), message.hasSuffix("\")") {
            message = String(message.dropFirst("UnexpectedResponse(\"".count).dropLast(2))
        }
        let code = ffiError.map { Int($0.pointee.code) } ?? -1
        if let ffiError { idevice_error_free(ffiError) }
        return NSError(domain: "WirelessLockdownService", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : "\(fallback)：\(message)"])
    }

    // MARK: - 隧道

    /// 隧道句柄对（构造成功即两者非空，后续免 force unwrap）.
    private struct Tunnel {
        let adapter: OpaquePointer
        let handshake: OpaquePointer

        func release() {
            rsd_handshake_free(handshake)
            adapter_free(adapter)
        }
    }

    private static func createTunnel() throws -> Tunnel {
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

    // MARK: - MCInstall 通用请求（协议帧在 Rust 侧，Swift 只组装 plist 正文）

    /// RSD 服务表查 `MCInstall.shim.remote` 端口；设备未暴露该服务返回 nil.
    /// 这是**确定性**判据（直接查握手自带的服务表），不依赖 FFI 错误码与枚举的映射.
    private static func mcinstallShimPort(_ handshake: OpaquePointer) -> UInt16? {
        var info: UnsafeMutablePointer<CRsdService>?
        if let ffiError = mcInstallRSDService.withCString({ rsd_get_service_info(handshake, $0, &info) }) {
            idevice_error_free(ffiError)
            return nil
        }
        guard let info else { return nil }
        defer { rsd_free_service(info) }
        let port = info.pointee.port
        return port == 0 ? nil : port
    }

    /// plist XML 文本转义（请求里只会出现我们自己拼的字段，此处兜底）
    private static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 从应答里取 `<key>K</key><open>值</open>` 的值
    private static func xmlValue(_ xml: String, key: String, open: String, close: String) -> String? {
        guard let kRange = xml.range(of: "<key>\(key)</key>") else { return nil }
        let tail = String(xml[kRange.upperBound...])
        guard let oRange = tail.range(of: open) else { return nil }
        let rest = String(tail[oRange.upperBound...])
        guard let cRange = rest.range(of: close) else { return nil }
        return String(rest[..<cRange.lowerBound])
    }

    /// 应答必须 Status=Acknowledged，否则把 ErrorCode/ErrorDomain/Description 拼成一句人话抛出
    private static func checkAck(_ reply: String, action: String) throws {
        if xmlValue(reply, key: "Status", open: "<string>", close: "</string>") == "Acknowledged" { return }
        var msg = "设备拒绝 \(action)"
        if let domain = xmlValue(reply, key: "ErrorDomain", open: "<string>", close: "</string>") {
            let code = xmlValue(reply, key: "ErrorCode", open: "<integer>", close: "</integer>")
            msg += "（\(domain)" + (code.map { " \($0)" } ?? "") + "）"
        }
        if let desc = xmlValue(reply, key: "LocalizedDescription", open: "<string>", close: "</string>")
            ?? xmlValue(reply, key: "USEnglishDescription", open: "<string>", close: "</string>") {
            msg += "：\(desc)"
        }
        throw makeError(msg)
    }

    /// 发一条 MCInstall 请求（同一隧道内；`certDER` 非空则先 Escalate 走监督通道）.
    /// `body` 是 plist 正文（`<dict>...</dict>`），plist 头与收尾由 Rust 统一拼装.
    private static func mcinstallRequest(_ body: String,
                                         superviseCert certDER: [UInt8]?,
                                         tunnel: Tunnel) throws -> String {
        var replyPtr: UnsafeMutablePointer<CChar>?
        let ffiError: UnsafeMutablePointer<IdeviceFfiError>?
        if let certDER {
            ffiError = certDER.withUnsafeBufferPointer { buf in
                mcinstall_request_rsd(tunnel.adapter, tunnel.handshake, body,
                                      buf.baseAddress, Int32(buf.count), &replyPtr)
            }
        } else {
            ffiError = mcinstall_request_rsd(tunnel.adapter, tunnel.handshake, body, nil, 0, &replyPtr)
        }
        guard let replyPtr else {
            if let ffiError { throw error(from: ffiError, fallback: "MCInstall 请求失败") }
            throw makeError("MCInstall 空应答")
        }
        let reply = String(cString: replyPtr)
        idevice_string_free(replyPtr)
        if let ffiError { throw error(from: ffiError, fallback: "MCInstall 请求失败") }
        return reply
    }

    // MARK: - lockdownd Set/Get（wireless_lockdown domain）

    private static func lockdownClient(_ tunnel: Tunnel) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = lockdownd_connect_rsd(tunnel.adapter, tunnel.handshake, &client) {
            throw error(from: ffiError, fallback: "连接 lockdownd 失败")
        }
        guard let client else { throw makeError("lockdownd 客户端创建失败") }
        return client
    }

    /// lockdown SetValue（domain: com.apple.mobile.wireless_lockdown）
    /// v0.3.243：不再尝试 lockdownd_start_session——见文件头说明.
    private static func setValue(_ key: String, value: Bool, tunnel: Tunnel) throws {
        let client = try lockdownClient(tunnel)
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

    /// lockdown GetValue（单键 Bool）——与 setValue 同一隧道/会话模式（无 StartSession）.
    private static func boolValue(_ key: String, tunnel: Tunnel) throws -> Bool {
        let client = try lockdownClient(tunnel)
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
              let binPtr, binLen > 0
        else {
            throw makeError("解析 \(key) 值失败")
        }
        // v0.3.247：plist_to_bin 的产出必须用 plist_mem_free 释放（此前每次读值都泄漏）
        defer { plist_mem_free(UnsafeMutableRawPointer(binPtr)) }

        guard let obj = try? PropertyListSerialization.propertyList(
            from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil)
        else {
            throw makeError("解析 \(key) 值失败")
        }
        guard let boolVal = obj as? Bool else {
            throw makeError("\(key) 值不是布尔（\(type(of: obj))）")
        }
        return boolVal
    }

    // MARK: - 公开操作（串行执行；一次操作只建一条隧道）

    /// Wi-Fi 射频开关.
    ///
    /// 优先走 MCInstall SetWiFiPowerState（真路径，pmd3 `profile set-wifi-power`
    /// / Apple Configurator 同款），全程不经过 lockdownd；设备 RSD 服务表里没有
    /// `MCInstall.shim.remote`（老系统）时回退 lockdown SetValue("WifiPowerState").
    /// 监督模式开启时，同一连接内先 Escalate 再下发（否则现代 iOS 会拒绝该命令）.
    static func setWifiPower(_ on: Bool) throws {
        try queue.sync { () -> Void in
            let tunnel = try createTunnel()
            defer { tunnel.release() }

            if mcinstallShimPort(tunnel.handshake) != nil {
                let cert = try supervisionCertIfEnabled()
                let body = "<dict><key>RequestType</key><string>SetWiFiPowerState</string>"
                    + "<key>PowerState</key><\(on ? "true" : "false")/></dict>"
                let reply = try mcinstallRequest(body, superviseCert: cert, tunnel: tunnel)
                try checkAck(reply, action: "SetWiFiPowerState")
            } else {
                try setValue("WifiPowerState", value: on, tunnel: tunnel)
            }
            UserDefaults.standard.set(on, forKey: wifiPowerStateKey)
        }
    }

    // MARK: - 监督（Supervision）

    /// 监督开启则取证书 DER；缺身份时给出明确指引而不是走到一半才报错
    private static func supervisionCertIfEnabled() throws -> [UInt8]? {
        guard SupervisionService.isEnabled else { return nil }
        guard let cert = SupervisionService.certificateDER() else {
            throw makeError("监督模式已开启但监督身份缺失，请先关闭再重新开启「监督模式」")
        }
        SupervisionService.registerSigner()
        return cert
    }

    /// 本机 CloudConfigurationDetails.plist 摘要（系统组**可读**，iOS 26 只读但读没问题）.
    /// 用于 14002 时告诉用户设备到底被谁监督着.
    private static func localCloudConfigSummary() -> String {
        let path = ConfigPlistURL.cloudConfig.path
        guard let dict = (try? NSDictionary(contentsOfFile: path)) as? [String: Any] else {
            return "（本机 CloudConfigurationDetails.plist 读不到）"
        }
        var parts: [String] = []
        if let org = dict["OrganizationName"] as? String, !org.isEmpty { parts.append("监管组织=\(org)") }
        if let sup = dict["IsSupervised"] as? Bool { parts.append("IsSupervised=\(sup ? "是" : "否")") }
        if let certs = dict["SupervisorHostCertificates"] as? [Data], !certs.isEmpty {
            parts.append("监督证书=\(certs.count) 张")
        }
        if let magic = dict["OrganizationMagic"] as? String, !magic.isEmpty {
            parts.append("Magic=\(magic.prefix(8))…")
        }
        return parts.isEmpty ? "（文件存在但无监督字段）" : "本机监督状态：" + parts.joined(separator: "，")
    }

    /// 把设备置于受监督状态（MCInstall SetCloudConfiguration，pmd3 `profile supervise` 同款）.
    /// ⚠️ 设备设置里会出现「此 iPhone 由 <组织> 监管」，MCInstall 无公开撤销接口.
    static func supervise(organization: String) throws {
        try queue.sync { () -> Void in
            guard let cert = SupervisionService.certificateDER() else {
                throw makeError("缺少监督身份")
            }
            SupervisionService.registerSigner()
            let tunnel = try createTunnel()
            defer { tunnel.release() }
            guard mcinstallShimPort(tunnel.handshake) != nil else {
                throw makeError("设备未暴露 \(mcInstallRSDService)")
            }
            let b64 = Data(cert).base64EncodedString()
            let magic = UUID().uuidString
            let body = "<dict><key>RequestType</key><string>SetCloudConfiguration</string>"
                + "<key>CloudConfiguration</key><dict>"
                + "<key>AllowPairing</key><true/>"
                + "<key>CloudConfigurationUIComplete</key><true/>"
                + "<key>ConfigurationSource</key><integer>2</integer>"
                + "<key>ConfigurationWasApplied</key><true/>"
                + "<key>IsMDMUnremovable</key><false/>"
                + "<key>IsMandatory</key><true/>"
                + "<key>IsMultiUser</key><false/>"
                + "<key>IsSupervised</key><true/>"
                + "<key>OrganizationMagic</key><string>\(magic)</string>"
                + "<key>OrganizationName</key><string>\(xmlEscaped(organization))</string>"
                + "<key>PostSetupProfileWasInstalled</key><true/>"
                + "<key>SupervisorHostCertificates</key><array><data>\(b64)</data></array>"
                + "</dict></dict>"
            let reply = try mcinstallRequest(body, superviseCert: nil, tunnel: tunnel)
            do {
                try checkAck(reply, action: "SetCloudConfiguration")
            } catch let err as NSError {
                // v0.3.250：14002 = A cloud configuration is already present on this device.
                // 设备已被别的身份监督 → 不能覆盖；Escalate 必须用「当初那份」监督身份。
                let text = err.localizedDescription
                if text.contains("14002") || text.lowercased().contains("already present") {
                    throw makeError("设备已被其他身份监督（14002），无法覆盖。"
                        + localCloudConfigSummary()
                        + "；SetWiFiPowerState 必须用当初监督这台设备的那份身份（证书+私钥）做 Escalate，App 新生成的身份设备不认。"
                        + " iOS 26 上配置目录只读，也无法直接改写监督身份。")
                }
                throw err
            }
        }
    }

    /// 验证监督通道可用（Escalate → GetCloudConfiguration，同一连接内完成）.
    /// 能 Acknowledged 即代表监督证书与 PKCS7 签名都被设备接受.
    static func verifySupervisionChannel() throws {
        try queue.sync { () -> Void in
            guard let cert = SupervisionService.certificateDER() else {
                throw makeError("缺少监督身份")
            }
            SupervisionService.registerSigner()
            let tunnel = try createTunnel()
            defer { tunnel.release() }
            guard mcinstallShimPort(tunnel.handshake) != nil else {
                throw makeError("设备未暴露 \(mcInstallRSDService)")
            }
            let reply = try mcinstallRequest(
                "<dict><key>RequestType</key><string>GetCloudConfiguration</string></dict>",
                superviseCert: cert, tunnel: tunnel)
            do {
                try checkAck(reply, action: "Escalate")
            } catch let err as NSError {
                let text = err.localizedDescription
                if text.contains("14005") || text.lowercased().contains("unable to set") {
                    throw makeError("监督身份不被设备接受（Escalate 后命令仍被拒）。"
                        + localCloudConfigSummary())
                }
                throw err
            }
        }
    }

    /// 局域网 Wi-Fi 配对连接（EnableWifiConnections）.
    /// 写成功后读回设备真实值确认（写成功 ≠ 生效，以设备为准）.
    /// - returns: 设备读回的确认值；nil = 读不回来（UI 应显示「未知」而不是假装成功）.
    @discardableResult
    static func setWifiConnections(enabled: Bool) throws -> Bool? {
        try queue.sync { () -> Bool? in
            let tunnel = try createTunnel()
            defer { tunnel.release() }

            try setValue("EnableWifiConnections", value: enabled, tunnel: tunnel)
            // 读回失败（隧道可能刚被系统重置）不应把整个操作判成失败
            return try? boolValue("EnableWifiConnections", tunnel: tunnel)
        }
    }

    /// 读回 EnableWifiConnections 当前状态（lockdownd GetValue over RSD 隧道）.
    /// iDescriptor 同款数据源；隧道不可用/读不到时返回 nil（UI 显示未知而非误报）.
    static func readWifiConnectionsEnabled() -> Bool? {
        queue.sync { () -> Bool? in
            guard let tunnel = try? createTunnel() else { return nil }
            defer { tunnel.release() }
            return try? boolValue("EnableWifiConnections", tunnel: tunnel)
        }
    }
}
