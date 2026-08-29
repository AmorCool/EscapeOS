import Foundation

/// IPCC 安装服务：导入运营商配置文件（.ipcc，本质是 zip），
/// 解包出 `.bundle`（如 `46000_ipcc.bundle`），写入
/// `/var/mobile/Library/Carrier Bundles/Overrides/`（用户数据分区，
/// 通过 bad_query 签发沙盒扩展访问），重启后由系统加载生效。
///
/// 注意：本服务能做的只是"把 bundle 放进 Overrides 目录"。
/// 是否真正生效取决于 iOS 版本对 Carrier Bundles 的加载策略
/// （iOS 26 实测需要验证），安装成功后必须重启设备/SpringBoard。
final class IPCCInstallService {

    static let shared = IPCCInstallService()
    private init() {}

    private let escape = SandboxEscape()
    private let files = FileService()

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
        /// bundle 目录名（如 `46000_ipcc.bundle`）。
        let bundleName: String
        /// Info.plist 里的 CFBundleIdentifier（如 `com.apple.CarrierBundle.46000`）。
        let identifier: String
        /// 版本（CFBundleVersion，缺失时用空串）。
        let version: String
        /// zip 内 bundle 前缀（`46000_ipcc.bundle/`）。
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

        // 读 Info.plist
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

    // MARK: - 安装

    /// 安装 .ipcc：解包 → 写入 Overrides（bad_query 扩展）→ 清理暂存。
    /// 返回安装到的 bundle 路径。
    func install(ipccURL: URL) throws -> String {
        let parsed = try parse(ipccURL: ipccURL)

        // 1. 解包到本地暂存目录（本容器内，无权限问题）。
        let stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IPCCStaging", isDirectory: true)
        try? files.deleteItem(at: stagingRoot.path)
        try files.createDirectory(at: stagingRoot.path)
        let bundleStaging = stagingRoot.appendingPathComponent(parsed.bundleName).path
        try files.createDirectory(at: bundleStaging)

        let reader = try ZipReader(url: ipccURL)
        for name in reader.entryNames() where name.hasPrefix(parsed.prefix) {
            let relative = String(name.dropFirst(parsed.prefix.count))
            guard !relative.isEmpty else { continue }
            let data = try reader.readEntry(named: name)
            let target = URL(fileURLWithPath: bundleStaging).appendingPathComponent(relative).path
            try files.writeFile(data: data, to: target)
        }
        defer { try? files.deleteItem(at: stagingRoot.path) }

        // 2. 对 Overrides 目录签发沙盒扩展（create: true 允许目录不存在时预创建）。
        let handle = try escape.consume(path: Self.overrideRoot, create: true)
        defer { escape.release(handle) }
        // Overrides 目录可能还不存在：扩展签发后显式递归创建。
        try files.createDirectory(at: Self.overrideRoot)

        // 3. 目标：Overrides/<bundleName>；已存在则先删除旧版本。
        let targetBundle = Self.overrideRoot + "/" + parsed.bundleName
        if files.exists(at: targetBundle) {
            try files.deleteItem(at: targetBundle)
        }
        try files.copyItem(at: bundleStaging, to: targetBundle)

        return targetBundle
    }

    // MARK: - 已安装列表 / 删除

    /// 列出 Overrides 下已安装的 bundle（bad_query 扩展下读取 Info.plist）。
    func listInstalled() -> [InstalledBundle] {
        do {
            let handle = try escape.consume(path: Self.overrideRoot, create: true)
            defer { escape.release(handle) }
            guard files.isDirectory(at: Self.overrideRoot),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: Self.overrideRoot) else {
                return []
            }
            var result: [InstalledBundle] = []
            for name in names where name.hasSuffix(".bundle") {
                let path = Self.overrideRoot + "/" + name
                let infoPath = path + "/Info.plist"
                var identifier = ""
                var version = ""
                if let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    identifier = plist["CFBundleIdentifier"] as? String ?? ""
                    version = plist["CFBundleVersion"] as? String
                        ?? plist["CFBundleShortVersionString"] as? String ?? ""
                }
                result.append(InstalledBundle(name: name, path: path,
                                              identifier: identifier, version: version))
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            return []
        }
    }

    /// 删除已安装的 bundle。
    func uninstall(_ bundle: InstalledBundle) throws {
        let handle = try escape.consume(path: Self.overrideRoot, create: true)
        defer { escape.release(handle) }
        if files.exists(at: bundle.path) {
            try files.deleteItem(at: bundle.path)
        }
    }
}
