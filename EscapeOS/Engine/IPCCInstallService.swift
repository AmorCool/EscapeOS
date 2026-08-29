import Foundation

/// IPCC 安装服务 —— **爱思助手「更新 IPCC」同款通道**（v0.2.128）。
///
/// 链路（与 ideviceinstaller / 爱思助手一致，无需越狱、无需系统级 entitlement）：
/// 1. AFC 隧道（RSD，根 = /var/mobile/media）把 .ipcc 上传到
///    `/PublicStaging/xxx.ipcc` —— AFC jail 内，installd / CommCenter 可读；
/// 2. `installation_proxy` 服务的 `Install` 命令，
///    `ClientOptions = { PackageType: "CarrierBundle" }`（.ipa 是 `Developer`），
///    `PackagePath` 指向刚上传的路径；
/// 3. installd → CommCenter 完成解包 / 校验 / 写入运营商配置区并广播变更。
///
/// 爱思在电脑端做的事（usbmuxd → lockdownd 配对 → installation_proxy），
/// 我们设备端 App 扮演"配对主机"，用同一条 RSD 隧道完成同样的上传 + 命令。
///
/// 与巨魔 IPCCInstaller 的区别：那个是设备端直接调 CoreTelephony 私有 API
/// （`_CTServerConnectionInstallCarrierBundle`），需要 CoreTrust 授予的系统级
/// entitlement —— **不是我们的路子**。
final class IPCCInstallService {

    static let shared = IPCCInstallService()
    private init() {}

    /// 解析 .ipcc 得到的包信息。
    struct ParsedIPCC {
        let bundleName: String
        let identifier: String
        let version: String
        let prefix: String
    }

    /// 最近安装记录（本地保存；CommCenter 安装后的实际 bundle 在系统区，我们看不到）。
    struct InstallRecord: Identifiable, Equatable {
        let fileName: String
        let bundleName: String
        let date: Date
        let success: Bool
        let detail: String
        /// v0.2.130：详细步骤日志（时间戳 + 每一步结果）。
        let steps: [String]
        var id: String { fileName + "-" + date.timeIntervalSince1970.description }
    }

    private var recordsKey: String { "IPCCInstallHistory" }

    func savedRecords() -> [InstallRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { dict in
            guard let fileName = dict["fileName"] as? String else { return nil }
            return InstallRecord(
                fileName: fileName,
                bundleName: dict["bundleName"] as? String ?? "",
                date: (dict["date"] as? Date) ?? .distantPast,
                success: (dict["success"] as? Bool) ?? false,
                detail: dict["detail"] as? String ?? "",
                steps: dict["steps"] as? [String] ?? []
            )
        }
    }

    private func appendRecord(_ record: InstallRecord) {
        var list: [[String: Any]] = savedRecords().map { [
            "fileName": $0.fileName, "bundleName": $0.bundleName,
            "date": $0.date, "success": $0.success, "detail": $0.detail,
            "steps": $0.steps
        ] }
        list.insert([
            "fileName": record.fileName, "bundleName": record.bundleName,
            "date": record.date, "success": record.success, "detail": record.detail,
            "steps": record.steps
        ], at: 0)
        if list.count > 30 { list.removeLast(list.count - 30) }
        if let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "IPCCInstall", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - 解析

    /// 解析 .ipcc：任意层级找 `*.bundle/Info.plist`（Apple 标准 IPCC =
    /// Payload/xxx.bundle/...，v0.2.126 已修复）。
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

    // MARK: - 安装（爱思同款：installation_proxy + PackageType=CarrierBundle）

    /// 安装 .ipcc。
    /// 1. 经 AFC 隧道上传到 `/PublicStaging/`（AFC jail，installd/CommCenter 可读）；
    /// 2. `installation_proxy` 的 Install 命令 + `PackageType=CarrierBundle`
    ///    （ideviceinstaller / 爱思助手安装 .ipcc 的标准做法）；
    /// 3. installd → CommCenter 完成解包 / 校验 / 写入运营商配置区并触发重载。
    func install(ipccURL: URL) throws -> String {
        let parsed = try parse(ipccURL: ipccURL)
        var steps: [String] = []
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "HH:mm:ss"
        func step(_ s: String) {
            steps.append("[\(stamp.string(from: Date()))] \(s)")
        }

        step("开始安装 \(ipccURL.lastPathComponent)")
        step("解析成功：bundle=\(parsed.bundleName) 标识=\(parsed.identifier.isEmpty ? "未知" : parsed.identifier)")
        do {
            try IPAInstallService.shared.installIPCC(ipccURL.path, log: { step($0) })
            let detail = "已通过 installation_proxy 安装（PackageType=CarrierBundle）"
            step("✔ \(detail)")
            appendRecord(InstallRecord(fileName: ipccURL.lastPathComponent,
                                       bundleName: parsed.bundleName,
                                       date: Date(), success: true, detail: detail, steps: steps))
            return parsed.bundleName
        } catch {
            step("✘ 失败：\(error.localizedDescription)")
            appendRecord(InstallRecord(fileName: ipccURL.lastPathComponent,
                                       bundleName: parsed.bundleName,
                                       date: Date(), success: false,
                                       detail: "安装失败：\(error.localizedDescription)", steps: steps))
            throw error
        }
    }
}
