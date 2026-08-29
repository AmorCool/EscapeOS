import Foundation

/// IPCC 安装服务：导入运营商配置文件（.ipcc），解包出 `.bundle` 写入
/// `/var/mobile/Library/Carrier Bundles/Overrides/`，重启后由系统加载生效。
///
/// v0.2.126 通道说明：
/// - v0.2.125 曾改走 RSD 隧道（afc_client_connect_rsd），实测发现
///   `com.apple.afc.shim.remote` 的根目录**仍是 /var/mobile/media**（不是整个
///   文件系统），/var/mobile/Library 在 media 之外 → 全部 Afc(ObjectNotFound)。
///   因此本版改回 bad_query（SandboxEscape + FileService）访问 Overrides。
/// - 解析器修复：Apple 标准 IPCC 结构是 `Payload/xxx.bundle/...`（像 .ipa 一样
///   包一层 Payload），旧版只找顶层 `*.bundle`，CMCC_cn.ipcc 因此报
///   "没有找到 .bundle 目录"。现在按任意层级查找。
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
        let bundleName: String
        let identifier: String
        let version: String
        let prefix: String
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "IPCCInstall", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - 解析

    /// 解析 .ipcc 文件：在**任意层级**找第一个 `.bundle` 目录并读它的 Info.plist。
    /// Apple 标准 IPCC 结构为 `Payload/xxx.bundle/Info.plist`（与 .ipa 相同的
    /// Payload 包装），也可能是顶层 `xxx.bundle/Info.plist`（v0.2.126 修复）。
    func parse(ipccURL: URL) throws -> ParsedIPCC {
        let reader: ZipReader
        do {
            reader = try ZipReader(url: ipccURL)
        } catch {
            throw makeError("无法打开 IPCC 文件（不是有效的 zip）：\(error.localizedDescription)")
        }

        let names = reader.entryNames()
        guard let infoEntry = names.first(where: {
            $0.contains(".bundle/") && $0.hasSuffix("/Info.plist")
        }) ?? names.first(where: { $0.contains(".bundle/") }) else {
            throw makeError("IPCC 里没有找到 .bundle 目录，不是有效的运营商包")
        }

        // bundle 目录 = Info.plist 去掉最后一个组件（如 Payload/CMCC_cn.bundle）
        let bundleDir = (infoEntry as NSString).deletingLastPathComponent
        let bundleName = (bundleDir as NSString).lastPathComponent
        let prefix = bundleDir + "/"
        guard bundleName.hasSuffix(".bundle") else {
            throw makeError("IPCC 里没有找到 .bundle 目录，不是有效的运营商包")
        }

        var identifier = ""
        var version = ""
        if let data = try? reader.readEntry(named: infoEntry),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            identifier = plist["CFBundleIdentifier"] as? String ?? ""
            if let v = plist["CFBundleVersion"] as? String { version = v }
            else if let v = plist["CFBundleShortVersionString"] as? String { version = v }
        }
        return ParsedIPCC(bundleName: bundleName, identifier: identifier, version: version, prefix: prefix)
    }

    // MARK: - 安装（bad_query 通道）

    /// 安装 .ipcc：解包 → 写入 Overrides（bad_query 扩展）→ 清理暂存。
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

        // 2. bad_query 签发 Overrides 扩展（create: true 允许目录不存在时预创建）。
        let handle = try escape.consume(path: Self.overrideRoot, create: true)
        defer { escape.release(handle) }
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
