import Foundation

//
//  WirelessLockdownService.swift
//  EscapeOS
//
//  v0.3.240：局域网 Wi-Fi 配对连接 +（当年的）Wi-Fi 射频开关。
//  通过 RSD 隧道 lockdownd 会话向 `com.apple.mobile.wireless_lockdown` domain 写值：
//  - EnableWifiConnections 允许局域网 Wi-Fi 配对连接（iDescriptor 同款）
//
//  v0.3.243：修复「读取配对文件失败：failed to parse raw pairing file from bytes」。
//  本 App 的 pairingFile.plist 是远程配对文件（RpPairingFile），经典 IdevicePairingFile
//  需要 USB 配对字段，解析必然失败；且 RSD 隧道（lockdownd_connect_rsd）本来就无
//  StartSession 步骤——隧道自身即信任边界。现在 connect_rsd → set_value，
//  与 DeviceInfoService/BatteryHealthService/DeviceControlService 同款。
//
//  v0.3.245：EnableWifiConnections 增加 GetValue 状态读回；修复 UI 从未赋值导致的弹回。
//
//  v0.3.328：**移除监督（Supervision）与 Wi-Fi 射频开关**。
//  ① 射频开关原来走 MCInstall `SetWiFiPowerState`，而该命令必须先在**同一连接内
//     Escalate**（用监督身份做 PKCS7 签名）才不被设备拒（否则 14005
//     `Unable to set Wi-Fi power`）。既然坚持不走监督那套，`setWifiPower` /
//     `supervise` / `verifySupervisionChannel` / `supervisionCertIfEnabled` 全部删除。
//  ② 本文件保留：lockdown Set/Get（wireless_lockdown 域，`EnableWifiConnections`）
//     与 MCInstall `GetProfileList`（描述文件列表，不需要监督身份）。
//

enum WirelessLockdownService {

    private static let domain = "com.apple.mobile.wireless_lockdown"

    /// MCInstall 的 RSD 服务名（pymobiledevice3 MobileConfig.RSD_SERVICE_NAME 同款）.
    private static let mcInstallRSDService = "com.apple.mobile.MCInstall.shim.remote"

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

    /// 发一条 MCInstall 请求（同一隧道内）.
    /// `body` 是 plist 正文（`<dict>...</dict>`），plist 头与收尾由 Rust 统一拼装.
    private static func mcinstallRequest(_ body: String, tunnel: Tunnel) throws -> String {
        var replyPtr: UnsafeMutablePointer<CChar>?
        let ffiError = mcinstall_request_rsd(tunnel.adapter, tunnel.handshake, body, nil, 0, &replyPtr)
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

    // MARK: - 描述文件列表（MCInstall GetProfileList，v0.3.252）

    /// GetProfileList 里单个描述文件的元数据
    struct ManagedProfile {
        let identifier: String     // PayloadIdentifier（唯一码）
        let uuid: String           // PayloadUUID（文件 ID）
        let name: String
        let desc: String?
        let organization: String?
        let type: String?
        let version: Int?
        let removable: Bool
        let created: Date?
        let expiry: Date?
    }

    /// 取设备上**全部**已安装配置描述（含用户装的 .mobileconfig / 托管描述）.
    /// misagent 只返回预置描述（.mobileprovision），这是「描述文件管理」比爱思少的根因.
    static func getManagedProfileList() throws -> [ManagedProfile] {
        try queue.sync { () -> [ManagedProfile] in
            let tunnel = try createTunnel()
            defer { tunnel.release() }
            guard mcinstallShimPort(tunnel.handshake) != nil else {
                throw makeError("设备未暴露 \(mcInstallRSDService)")
            }
            let reply = try mcinstallRequest(
                "<dict><key>RequestType</key><string>GetProfileList</string></dict>",
                tunnel: tunnel)
            try checkAck(reply, action: "GetProfileList")
            return parseProfileMetadata(reply)
        }
    }

    /// 解析 GetProfileList 应答的 ProfileMetadata（identifier → 各字段）.
    private static func parseProfileMetadata(_ reply: String) -> [ManagedProfile] {
        let iso = ISO8601DateFormatter()
        var out: [ManagedProfile] = []
        for entry in profileMetadataEntries(reply) {
            let body = entry.body
            func str(_ key: String) -> String? {
                xmlValue(body, key: key, open: "<string>", close: "</string>")
            }
            let uuid = str("PayloadUUID") ?? entry.id
            let name = str("DisplayName") ?? str("PayloadDisplayName") ?? entry.id
            let removable = (xmlValue(body, key: "RemovalDisallowed", open: "<", close: "/>") != "true")
            let created = str("CreationDate").flatMap { iso.date(from: $0) }
            let expiry = str("ExpirationDate").flatMap { iso.date(from: $0) }
            let version = xmlValue(body, key: "Version", open: "<integer>", close: "</integer>")
                .flatMap(Int.init)
            out.append(ManagedProfile(
                identifier: entry.id,
                uuid: uuid,
                name: name,
                desc: str("PayloadDescription") ?? str("Description"),
                organization: str("PayloadOrganization"),
                type: str("PayloadType"),
                version: version,
                removable: removable,
                created: created,
                expiry: expiry))
        }
        return out
    }

    /// 把 `ProfileMetadata` 下每个 `<key>ID</key><dict>…</dict>` 切成独立片段.
    /// （GetProfileList 的元数据是嵌套 dict，逐段配对 `<dict>`/`</dict>` 深度）.
    private static func profileMetadataEntries(_ reply: String) -> [(id: String, body: String)] {
        guard let metaKey = reply.range(of: "<key>ProfileMetadata</key>") else { return [] }
        guard let outer = reply[metaKey.upperBound...].range(of: "<dict>") else { return [] }
        var i = outer.upperBound
        var out: [(String, String)] = []
        while true {
            // 子 dict 之后：下一个 token 要么是 <key>（还有更多描述），要么是 </dict>（外层结束）
            let nextKey = reply[i...].range(of: "<key>")
            let outerClose = reply[i...].range(of: "</dict>")
            if let c = outerClose, nextKey == nil || c.lowerBound < nextKey!.lowerBound { break }

            guard let kRange = reply[i...].range(of: "<key>") else { break }
            guard let kEnd = reply[kRange.upperBound...].range(of: "</key>") else { break }
            let id = String(reply[kRange.upperBound..<kEnd.lowerBound])

            guard let dOpen = reply[kEnd.upperBound...].range(of: "<dict>") else { break }
            var depth = 1
            var j = dOpen.upperBound
            var bodyEnd = j
            while depth > 0 {
                let o = reply[j...].range(of: "<dict>")
                let c = reply[j...].range(of: "</dict>")
                switch (o, c) {
                case (let o?, let c?) where o.lowerBound < c.lowerBound:
                    depth += 1; j = o.upperBound
                case (_, let c?):
                    depth -= 1; j = c.upperBound
                    if depth == 0 { bodyEnd = c.lowerBound }
                case (let o?, nil):
                    depth += 1; j = o.upperBound
                default:
                    return out                       // XML 不完整，返回已解析部分
                }
            }
            out.append((id, String(reply[dOpen.upperBound..<bodyEnd])))
            i = j
        }
        return out
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
