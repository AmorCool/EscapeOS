import Foundation
import Darwin

//
//  ProfileConfigService.swift
//  EscapeOS
//
//  v0.3.229：iOS 设置描述文件（Configuration Profile，.mobileconfig/.mobileprofile）管理.
//  参考 pymobiledevice3 的 profile 命令（list / install / remove）——底层同为 misagent
//  服务（com.apple.misagent）.与"预置描述管理"（.mobileprovision，ProvisioningProfileStore）
//  共用同一服务：copy_all 返回设备全部 profile，按 PayloadType 排除预置描述.
//

enum ProfileConfigService {

    struct ConfigurationProfile: Identifiable {
        let uuid: String           // PayloadUUID / UUID（remove 用）
        let name: String           // PayloadDisplayName / Name / AppIDName
        let organization: String?  // PayloadOrganization
        let type: String?          // PayloadType（首个 payload）
        let desc: String?          // PayloadDescription
        let verified: Bool         // SignedPayload（设备已验证签名）
        let teamName: String?      // TeamName（使用者，mobileprovision）
        let version: Int?          // Version（版本号）
        let expiry: Date?          // ExpirationDate
        let isProvisioning: Bool   // 预置描述（.mobileprovision）
        // v0.3.245：详情页新增字段（对齐爱思助手详情：文件ID/使用者/是否可移除…）
        let identifier: String?    // PayloadIdentifier（文件 ID）
        let removable: Bool        // 顶层 RemovalDisallowed 取反（默认可移除；设备端移除密码仅删除时报错）
        let created: Date?         // CreationDate（mobileprovision 常见）
        let contentCount: Int      // PayloadContent payload 数（0=单层/未知）
        var id: String { uuid }
    }

    // MARK: - 错误工具

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "ProfileConfigService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        let message = ffiError?.pointee.message.map { String(cString: $0) } ?? ""
        let code = ffiError.map { Int($0.pointee.code) } ?? -1
        if let ffiError { idevice_error_free(ffiError) }
        return NSError(domain: "ProfileConfigService", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : "\(fallback)：\(message)"])
    }

    // MARK: - 隧道

    private static func createTunnel() throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        let pairingPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件.请先导入配对文件.")
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

    // MARK: - plist 提取（ProvisioningProfileStore.extractPlist 同款）

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

    // MARK: - 列表

    /// 列表结果（含诊断：copy_all 原始数量 / 解析失败数）
    struct ListResult {
        let profiles: [ConfigurationProfile]
        let rawCount: Int
        let parseFailed: Int
    }

    /// 设备上**全部描述文件**（v0.3.239：取消类型过滤对齐爱思识别；预置描述标注"预置"）.
    static func listAll() throws -> ListResult {
        let all = try withMisagent { client -> [ConfigurationProfile] in
            var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
            var profileLengths: UnsafeMutablePointer<Int>?
            var profileCount = 0
            if let ffiError = misagent_copy_all(client, &profilePointers, &profileLengths, &profileCount) {
                throw error(from: ffiError, fallback: "获取描述文件失败")
            }
            profileCountSnapshot = profileCount
            defer {
                if let profilePointers, let profileLengths {
                    misagent_free_profiles(profilePointers, profileLengths, profileCount)
                }
            }
            guard let profilePointers, let profileLengths else { return [] }

            var result: [ConfigurationProfile] = []
            for index in 0..<profileCount {
                guard let bytes = profilePointers[index] else { continue }
                let data = Data(bytes: bytes, count: profileLengths[index])
                guard let plistData = extractPlist(from: data),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
                      let dict = plist as? [String: Any] else {
                    continue  // 计入 parseFailed
                }

                // 单 payload 或多 payload（取首 payload 元数据）
                var type: String? = dict["PayloadType"] as? String
                var displayName = dict["PayloadDisplayName"] as? String
                var organization = dict["PayloadOrganization"] as? String
                var desc = dict["PayloadDescription"] as? String
                if let contents = dict["PayloadContent"] as? [[String: Any]], let first = contents.first {
                    if type == nil { type = first["PayloadType"] as? String }
                    if displayName == nil { displayName = first["PayloadDisplayName"] as? String }
                    if organization == nil { organization = first["PayloadOrganization"] as? String }
                    if desc == nil { desc = first["PayloadDescription"] as? String }
                }

                // v0.3.241：mobileprovision 字段 fallback（Name/AppIDName/TeamName/Version/ExpirationDate）
                if displayName == nil { displayName = dict["Name"] as? String }
                if displayName == nil { displayName = dict["AppIDName"] as? String }
                let teamName = (dict["TeamName"] as? String)
                    ?? ((dict["TeamIdentifier"] as? [String])?.first)
                    ?? (dict["ApplicationIdentifierPrefix"] as? [String])?.first
                let version = (dict["Version"] as? NSNumber)?.intValue
                var expiry: Date?
                if let ts = dict["ExpirationDate"] as? Double {
                    expiry = Date(timeIntervalSinceReferenceDate: ts)
                } else if let ts = dict["ExpirationDate"] as? TimeInterval {
                    expiry = Date(timeIntervalSinceReferenceDate: ts)
                } else if let date = dict["ExpirationDate"] as? Date {
                    expiry = date
                }

                // UUID fallback：无 UUID 时用名称+序号占位（remove 对此类会失败但至少可见）
                let uuid = (dict["PayloadUUID"] as? String)
                    ?? (dict["UUID"] as? String)
                    ?? ("unknown-\(index)-" + (displayName ?? "unnamed"))
                let isProvisioning = (type == "Provisioning Profiles")
                    || (dict["Entitlements"] is [String: Any])
                // v0.3.245：详情页字段（PayloadIdentifier / RemovalDisallowed / CreationDate / payload 数）
                let identifier = (dict["PayloadIdentifier"] as? String) ?? (dict["Identifier"] as? String)
                let removable = !(dict["RemovalDisallowed"] as? Bool ?? false)
                var created: Date?
                if let ts = dict["CreationDate"] as? Double {
                    created = Date(timeIntervalSinceReferenceDate: ts)
                } else if let date = dict["CreationDate"] as? Date {
                    created = date
                }
                let contentCount = (dict["PayloadContent"] as? [Any])?.count ?? 0
                result.append(ConfigurationProfile(
                    uuid: uuid,
                    name: displayName ?? "未命名",
                    organization: organization,
                    type: isProvisioning ? "预置描述" : type,
                    desc: desc,
                    verified: (dict["SignedPayload"] as? Bool) ?? false,
                    teamName: teamName,
                    version: version,
                    expiry: expiry,
                    isProvisioning: isProvisioning,
                    identifier: identifier,
                    removable: removable,
                    created: created,
                    contentCount: contentCount
                ))
            }
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let raw = profileCountSnapshot
        let failed = max(raw - all.count, 0)
        return ListResult(profiles: all, rawCount: raw, parseFailed: failed)
    }

    /// copy_all 原始数量快照（ListResult 诊断用）
    private static var profileCountSnapshot: Int = 0

    // MARK: - 安装 / 删除

    /// 安装 .mobileconfig/.mobileprofile（misagent_install，复用 ProvisioningProfileStore）
    static func install(_ data: Data) throws {
        try ProvisioningProfileStore.addProfile(data)
    }

    /// 按 PayloadUUID 删除（misagent_remove，复用 ProvisioningProfileStore）
    static func remove(uuid: String) throws {
        try ProvisioningProfileStore.removeProfile(uuid: uuid)
    }
}
