import Foundation

/// 描述文件（provisioning profile）仓库（汉化移植自 StikDebug 的
/// IdeviceFFIBridge + ProfileView 数据层）。
///
/// 数据来源：设备上的 **misagent** 服务（`misagent_copy_all`）返回设备全部的
/// provisioning profiles——物理存储在设备的 `/var/mobile/Library/MobileDevice/
/// Provisioning Profiles/`（每个文件为 <UUID>.mobileprovision）。
/// 这是 Apple 官方的描述文件管理通道（Xcode 的 Devices 窗口也走它），
/// 通过开发者隧道（RPPairing 配对文件 + LocalDevVPN）以配对身份访问，
/// 因此无需越狱即可读取 / 添加 / 删除。
enum ProvisioningProfileStore {

    struct ProfileInfo: Identifiable {
        let id: String          // UUID
        let data: Data
        let appName: String     // AppIDName（证书名，通常含软件名）
        let appId: String       // application-identifier
        let expirationDate: Date?
        let entitlements: [String: Any]
        /// v0.3.187：mobileprovision 顶层 ProvisionsAllDevices。
        /// true 即企业 / In-House profile（Apple TN3125 权威字段）.
        /// 默认 false 让旧调用点（memberwise init）免改.
        var provisionsAllDevices: Bool = false
        /// v0.3.187：mobileprovision 顶层 ProvisionedDevices 数组长度.
        /// >0 即 Ad-Hoc profile（特定设备列表）;0 即 Development/Distribution 团队签.
        var provisionedDevicesCount: Int = 0
        /// v0.3.187：mobileprovision 顶层 TeamIdentifier（首项）或 ApplicationIdentifierPrefix.
        /// 用于 AppType 调色板的同 team 多 App 关联.
        var teamIdentifier: String? = nil

        var formattedDate: String {
            guard let expirationDate else { return "未知" }
            return Self.dateFormatter.string(from: expirationDate)
        }

        /// 过期剩余天数（正 = 还有 N 天，负 = 已过期 N 天）。
        var daysRemaining: Int {
            guard let expirationDate else { return Int.max }
            let today = Calendar.current.startOfDay(for: Date())
            let expiry = Calendar.current.startOfDay(for: expirationDate)
            return Calendar.current.dateComponents([.day], from: today, to: expiry).day ?? 0
        }

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .medium
            return f
        }()
    }

    // MARK: - 错误

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "ProvisioningProfiles", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message: String
        if let cString = ffiError.pointee.message {
            message = String(cString: cString)
        } else {
            message = ""
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "ProvisioningProfiles", code: code, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: - 隧道（与 JITEnableService 同机制）

    private static func createTunnel() throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        let pairingPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件。请先在「应用」页导入配对文件。")
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
            throw makeError("隧道 IP 无效：\(deviceIP)")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        let ffiError = "EscapeSpaceProfiles".withCString { hostname in
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
        guard let adapter, let handshake else {
            throw makeError("创建开发者隧道失败")
        }
        return (adapter, handshake)
    }

    /// 用隧道执行 misagent 操作。
    private static func withMisagent<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let tunnel = try createTunnel()
        defer {
            rsd_handshake_free(tunnel.handshake)
            adapter_free(tunnel.adapter)
        }
        var client: OpaquePointer?
        if let ffiError = misagent_connect_rsd(tunnel.adapter, tunnel.handshake, &client) {
            throw error(from: ffiError, fallback: "连接描述文件服务（misagent）失败")
        }
        guard let client else { throw makeError("连接描述文件服务失败") }
        defer { misagent_client_free(client) }
        return try body(client)
    }

    // MARK: - 读取 / 写入

    /// 侧载应用（installation_proxy 返回、带 ProfileValidated 字段）。
    struct SideloadedAppInfo: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let applicationIdentifier: String?
        let entitlements: [String: Any]
        /// v0.3.187：从匹配的 .mobileprovision 顶层读到的企业标志（权威）.
        var provisionsAllDevices: Bool = false
        /// v0.3.187：mobileprovision 顶层 ProvisionedDevices 数组长度;>0 = Ad-Hoc profile.
        var provisionedDevicesCount: Int = 0
        /// v0.3.187：mobileprovision 顶层的 team identifier（前缀）.
        var teamIdentifier: String? = nil
    }

    /// 读取设备上全部描述文件（misagent_copy_all）。
    static func fetchAllProfiles() throws -> [ProfileInfo] {
        try withMisagent { client in
            var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
            var profileLengths: UnsafeMutablePointer<Int>?
            var profileCount = 0
            if let ffiError = misagent_copy_all(client, &profilePointers, &profileLengths, &profileCount) {
                throw error(from: ffiError, fallback: "获取描述文件失败")
            }
            defer {
                if let profilePointers, let profileLengths {
                    misagent_free_profiles(profilePointers, profileLengths, profileCount)
                }
            }
            guard let profilePointers, let profileLengths else { return [] }

            var result: [ProfileInfo] = []
            for index in 0..<profileCount {
                guard let bytes = profilePointers[index] else { continue }
                let data = Data(bytes: bytes, count: profileLengths[index])
                if let info = parseProfile(data) {
                    result.append(info)
                }
            }
            return result
        }
    }

    /// 侧载应用列表（installation_proxy 返回、带 ProfileValidated 字段，
    /// 用于把描述文件归到对应 App 名下）。
    static func fetchSideloadedApps() throws -> [SideloadedAppInfo] {
        let tunnel = try createTunnel()
        defer {
            rsd_handshake_free(tunnel.handshake)
            adapter_free(tunnel.adapter)
        }
        var client: OpaquePointer?
        if let ffiError = installation_proxy_connect_rsd(tunnel.adapter, tunnel.handshake, &client) {
            throw error(from: ffiError, fallback: "连接安装代理失败")
        }
        guard let client else { throw makeError("连接安装代理失败") }
        defer { installation_proxy_client_free(client) }

        var rawApps: UnsafeMutableRawPointer?
        var count = 0
        if let ffiError = installation_proxy_get_apps(client, nil, nil, 0, &rawApps, &count) {
            throw error(from: ffiError, fallback: "获取应用列表失败")
        }
        guard let rawApps, count > 0 else { return [] }

        let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count {
                plist_free(apps[index])
            }
            idevice_data_free(rawApps.assumingMemoryBound(to: UInt8.self), UInt(count * MemoryLayout<plist_t?>.stride))
        }

        var result: [SideloadedAppInfo] = []
        for index in 0..<count {
            var binaryPlist: UnsafeMutablePointer<CChar>?
            var binaryLength: UInt32 = 0
            guard plist_to_bin(apps[index], &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                  let binaryPlist, binaryLength > 0 else { continue }
            let data = Data(bytes: binaryPlist, count: Int(binaryLength))
            plist_mem_free(binaryPlist)

            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any],
                  dict["ProfileValidated"] != nil,   // 只保留侧载应用
                  let bundleID = dict["CFBundleIdentifier"] as? String else { continue }

            let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
            let name = (dict["CFBundleDisplayName"] as? String)
                ?? (dict["CFBundleName"] as? String)
                ?? bundleID
            result.append(SideloadedAppInfo(
                bundleID: bundleID,
                name: name,
                applicationIdentifier: entitlements["application-identifier"] as? String,
                entitlements: entitlements
            ))
        }
        // v0.3.190：删除 v0.3.187 在此处调 fetchAllProfiles() 的代码——
        // 本函数内 installation_proxy 隧道（defer 在末尾才释放）仍活着时，
        // fetchAllProfiles() 会再建一条 LocalDevVPN 隧道并发 RSD 握手 →
        // 隧道状态竞争/死锁 → 真机闪退（v0.3.187~189 连续闪退元凶）。
        // 需要 profile 顶层字段时由调用方（AppListView.loadAppTypes）顺序串行
        // 调 fetchSideloadedApps() + fetchAllProfiles() 并自行按 appId 匹配.
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 删除指定 UUID 的描述文件（misagent_remove）。
    static func removeProfile(uuid: String) throws {        try withMisagent { client in
            if let ffiError = misagent_remove(client, uuid) {
                throw error(from: ffiError, fallback: "删除描述文件失败（UUID: \(uuid)）")
            }
        }
    }

    /// 安装描述文件（misagent_install）。
    static func addProfile(_ data: Data) throws {
        try withMisagent { client in
            let ffiError = data.withUnsafeBytes { rawBuffer in
                misagent_install(
                    client,
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                    data.count
                )
            }
            if let ffiError {
                throw error(from: ffiError, fallback: "添加描述文件失败")
            }
        }
    }

    // MARK: - 解析

    /// 解析 CMS 签名的 .mobileprovision → plist（简化实现：直接提取内嵌 plist）。
    static func parseProfile(_ data: Data) -> ProfileInfo? {
        guard let plistData = extractPlist(from: data),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }

        let appName = dict["AppIDName"] as? String ?? "未知"
        var appId = "未知"
        if let entitlements = dict["Entitlements"] as? [String: Any],
           let identifier = entitlements["application-identifier"] as? String {
            appId = identifier
        }
        let uuid = dict["UUID"] as? String ?? UUID().uuidString
        let expiration = dict["ExpirationDate"] as? Date
        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
        // v0.3.187：从 mobileprovision 顶层解析企业/Ad-Hoc 权威字段.
        let provisionsAllDevices = dict["ProvisionsAllDevices"] as? Bool ?? false
        let provisionedDevicesCount = (dict["ProvisionedDevices"] as? [Any])?.count ?? 0
        // teamIdentifier 取 TeamIdentifier 数组首项；fallback ApplicationIdentifierPrefix.
        let teamIdentifier: String? = {
            if let team = (dict["TeamIdentifier"] as? [String])?.first { return team }
            return dict["ApplicationIdentifierPrefix"] as? String
        }()

        return ProfileInfo(
            id: uuid,
            data: data,
            appName: appName,
            appId: appId,
            expirationDate: expiration,
            entitlements: entitlements,
            provisionsAllDevices: provisionsAllDevices,
            provisionedDevicesCount: provisionedDevicesCount,
            teamIdentifier: teamIdentifier
        )
    }

    /// 从 CMS 载荷中提取内嵌 plist（XML 或二进制）。
    private static func extractPlist(from data: Data) -> Data? {
        let xmlStart = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        let binaryMagic = Data("bplist00".utf8)

        if let startRange = data.range(of: xmlStart),
           let endRange = data.range(of: plistEnd, options: [], in: startRange.lowerBound..<data.endIndex) {
            return data[startRange.lowerBound..<endRange.upperBound]
        }
        if let binaryRange = data.range(of: binaryMagic) {
            return data[binaryRange.lowerBound..<data.endIndex]
        }
        return nil
    }
}
