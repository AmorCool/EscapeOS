import Foundation

/// IPCC 安装服务：导入运营商配置文件（.ipcc，本质是 zip），
/// 解包出 `.bundle`，通过 **RSD 隧道（idevice 那套）** 写入
/// `/var/mobile/Library/Carrier Bundles/Overrides/`，重启后由系统加载生效。
///
/// v0.2.125：从 bad_query 改为走 `AFCService`（`afc_client_connect_rsd` →
/// `com.apple.afc.shim.remote`，iOS 26 开发者模式的远程 AFC，根是整个文件系统），
/// 与 AFC 管理 / 铃声管理同一套隧道，避免 bad_query 对系统用户目录权限的不确定性。
final class IPCCInstallService {

    static let shared = IPCCInstallService()
    private init() {}

    private let afc = AFCService.shared

    /// Overrides 目录（IPCC 安装目标）。
    static let overrideRoot = "/var/mobile/Library/Carrier Bundles/Overrides"

    /// 已安装的运营商包信息。
    struct InstalledBundle: Identifiable, Equatable {
        let name: String
        let path: String
        let identifier: String
        let version: String
        var id: String { path }
    }

    /// 解析 .ipcc 得到的包信息。
    struct ParsedIPCC {
        let bundleName: String
        let identifier: String
        let version: String
        let prefix: String
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "IPCCInstall", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - 解析

    /// 解析 .ipcc 文件：找第一个 `.bundle` 目录并读它的 Info.plist。
    func parse(ipccURL: URL) throws -> ParsedIPCC {
        let reader: ZipReader
        do {
            reader = try ZipReader(url: ipccURL)
        } catch {
            throw makeError("无法打开 IPCC 文件（不是有效的 zip）：\(error.localizedDescription)")
        }

        let names = reader.entryNames()
        guard let bundleEntry = names.first(where: {
            $0.contains(".bundle/") && $0.hasSuffix("/Info.plist")
        }) ?? names.first(where: { $0.contains(".bundle/") }) else {
            throw makeError("IPCC 里没有找到 .bundle 目录，不是有效的运营商包")
        }

        let bundleName = bundleEntry.components(separatedBy: "/").first ?? ""
        let prefix = bundleName + "/"
        guard bundleName.hasSuffix(".bundle") else {
            throw makeError("IPCC 里没有找到 .bundle 目录，不是有效的运营商包")
        }

        var identifier = ""
        var version = ""
        if let infoName = names.first(where: { $0 == prefix + "Info.plist" }) {
            if let data = try? reader.readEntry(named: infoName),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                identifier = plist["CFBundleIdentifier"] as? String ?? ""
                if let v = plist["CFBundleVersion"] as? String { version = v }
                else if let v = plist["CFBundleShortVersionString"] as? String { version = v }
            }
        }
        return ParsedIPCC(bundleName: bundleName, identifier: identifier, version: version, prefix: prefix)
    }

    // MARK: - 安装（走 RSD 隧道 / AFC）

    /// 安装 .ipcc：解包 → 经 AFC 隧道写入 Overrides → 清理暂存。
    /// 返回安装到的 bundle 路径。
    func install(ipccURL: URL) throws -> String {
        let parsed = try parse(ipccURL: ipccURL)

        // 1. 解包到本地暂存目录（本容器内，无权限问题）。
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IPCCStaging", isDirectory: true)
        try? FileManager.default.removeItem(atPath: stagingRoot.path)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let bundleStaging = stagingRoot.appendingPathComponent(parsed.bundleName).path
        try FileManager.default.createDirectory(atPath: bundleStaging, withIntermediateDirectories: true)

        let reader = try ZipReader(url: ipccURL)
        for name in reader.entryNames() where name.hasPrefix(parsed.prefix) {
            let relative = String(name.dropFirst(parsed.prefix.count))
            guard !relative.isEmpty else { continue }
            let data = try reader.readEntry(named: name)
            let target = URL(fileURLWithPath: bundleStaging).appendingPathComponent(relative).path
            try data.write(to: URL(fileURLWithPath: target))
        }
        defer { try? FileManager.default.removeItem(atPath: stagingRoot.path) }

        // 2. 经 AFC 隧道批量上传（一条连接完成全部文件，v0.2.125）。
        let targetBundle = Self.overrideRoot + "/" + parsed.bundleName
        try afc.batch { client in
            // 确保 Overrides 存在（已存在则 afc_make_directory 报错，忽略）
            _ = Self.overrideRoot.withCString { afc_make_directory(client, $0) }
            // 已存在同名牌则先整体删除
            Self.removeViaAFC(client: client, path: targetBundle)
            // 逐文件上传（保留目录结构）
            try Self.uploadDirectory(client: client, localDir: bundleStaging, remoteDir: targetBundle)
        }
        return targetBundle
    }

    // MARK: - AFC 底层辅助（batch 内使用）

    private static func removeViaAFC(client: OpaquePointer, path: String) {
        _ = path.withCString { afc_remove_path_and_contents(client, $0) }
    }

    private static func uploadDirectory(client: OpaquePointer, localDir: String, remoteDir: String) throws {
        _ = remoteDir.withCString { afc_make_directory(client, $0) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: localDir)) ?? []
        for name in names {
            let local = (localDir as NSString).appendingPathComponent(name)
            let remote = (remoteDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: local, isDirectory: &isDir), isDir.boolValue {
                try uploadDirectory(client: client, localDir: local, remoteDir: remote)
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: local))
                var file: OpaquePointer?
                if let ffiError = remote.withCString({ afc_file_open(client, $0, AfcWrOnly, &file) }) {
                    let msg = ffiError.pointee.message.map { String(cString: $0) } ?? "rc=\(ffiError.pointee.code)"
                    idevice_error_free(ffiError)
                    throw NSError(domain: "IPCCInstall", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "创建远程文件失败：\(remote)（\(msg)）"])
                }
                guard let file else {
                    throw NSError(domain: "IPCCInstall", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "创建远程文件失败：\(remote)"])
                }
                defer { afc_file_close(file) }
                try data.withUnsafeBytes { buffer in
                    let base = buffer.bindMemory(to: UInt8.self).baseAddress
                    var offset = 0
                    while offset < data.count {
                        let chunk = min(1_048_576, data.count - offset)
                        if let ffiError = afc_file_write(file, base?.advanced(by: offset), chunk) {
                            let msg = ffiError.pointee.message.map { String(cString: $0) } ?? "rc=\(ffiError.pointee.code)"
                            idevice_error_free(ffiError)
                            throw NSError(domain: "IPCCInstall", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "写入远程文件失败：\(remote)（\(msg)）"])
                        }
                        offset += chunk
                    }
                }
            }
        }
    }

    // MARK: - 已安装列表 / 删除

    /// 列出 Overrides 下已安装的 bundle（经 AFC 隧道读取 Info.plist）。
    func listInstalled() -> [InstalledBundle] {
        do {
            let entries = try afc.listDirectory(Self.overrideRoot)
            var result: [InstalledBundle] = []
            for entry in entries where entry.name.hasSuffix(".bundle") && entry.isDirectory {
                let path = entry.path
                var identifier = ""
                var version = ""
                if let data = try? afc.readFile(path + "/Info.plist"),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    identifier = plist["CFBundleIdentifier"] as? String ?? ""
                    version = plist["CFBundleVersion"] as? String
                        ?? plist["CFBundleShortVersionString"] as? String ?? ""
                }
                result.append(InstalledBundle(name: entry.name, path: path,
                                              identifier: identifier, version: version))
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            return []
        }
    }

    /// 删除已安装的 bundle。
    func uninstall(_ bundle: InstalledBundle) throws {
        try afc.removePath(bundle.path, includingContents: true)
    }
}
