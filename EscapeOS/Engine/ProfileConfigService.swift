import Foundation
import Darwin

//
//  ProfileConfigService.swift
//  EscapeOS
//
//  v0.3.229：iOS 设置描述文件（Configuration Profile，.mobileconfig/.mobileprofile）管理。
//  参考 pymobiledevice3 的 profile 命令（list / install / remove）——底层同为 misagent
//  服务（com.apple.misagent）。与"预置描述管理"（.mobileprovision，ProvisioningProfileStore）
//  共用同一服务：copy_all 返回设备全部 profile，按 PayloadType 排除预置描述。
//

enum ProfileConfigService {

    struct ConfigurationProfile: Identifiable {
        let uuid: String           // PayloadUUID（remove 用）
        let name: String           // PayloadDisplayName
        let organization: String?  // PayloadOrganization
        let type: String?          // PayloadType（首个 payload）
        let desc: String?          // PayloadDescription
        let verified: Bool         // SignedPayload（设备已验证签名）
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
            throw makeError("无配对文件")
        }
        var pairingFile: OpaquePointer?
        if let e = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: e, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("配对文件解析失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        if let e = pairingFile.withCString({
            adapter_connect_rsd($0, &adapter)
        }) {
            throw error(from: e, fallback: "RSD 连接失败")
        }
        guard let adapter else { throw makeError("RSD 适配器创建失败") }
        if let e = adapter_handshake_rsd(adapter, &handshake) {
            adapter_free(adapter)
            throw error(from: e, fallback: "RSD 握手失败")
        }
        guard let handshake else {
            adapter_free(adapter)
            throw makeError("RSD 握手句柄缺失")
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

    /// 设备上全部**配置描述文件**（排除 PayloadType == "Provisioning Profiles" 的预置描述）。
    static func listConfigurationProfiles() throws -> [ConfigurationProfile] {
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

            var result: [ConfigurationProfile] = []
            for index in 0..<profileCount {
                guard let bytes = profilePointers[index] else { continue }
                let data = Data(bytes: bytes, count: profileLengths[index])
                guard let plistData = extractPlist(from: data),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
                      let dict = plist as? [String: Any] else { continue }

                // 排除预置描述（.mobileprovision，归"预置描述管理"管）
                if (dict["PayloadType"] as? String) == "Provisioning Profiles" { continue }

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

                // 预置描述也可能无 PayloadType 顶层键但内容像 mobileprovision（有 Entitlements+AppIDName）——排除
                if dict["Entitlements"] is [String: Any], type == nil { continue }

                guard let uuid = (dict["PayloadUUID"] as? String) ?? (dict["UUID"] as? String) else { continue }
                result.append(ConfigurationProfile(
                    uuid: uuid,
                    name: displayName ?? "未命名",
                    organization: organization,
                    type: type,
                    desc: desc,
                    verified: (dict["SignedPayload"] as? Bool) ?? false
                ))
            }
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

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
