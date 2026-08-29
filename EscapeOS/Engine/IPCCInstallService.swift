import Foundation

/// IPCC 安装服务 —— **爱思助手同款官方通道**（v0.2.127 重写）。
///
/// 原理（参考 IPCCInstaller 逆向分析报告 + 爱思助手行为）：
/// 1. 把 .ipcc 经 AFC 隧道（RSD，根=/var/mobile/media）上传到
///    `/var/mobile/Media/PublicStaging/`（系统守护进程可见的公共中转目录，
///    正好在 AFC 根内 —— 不需要任何系统权限）；
/// 2. 进程内 dlopen CoreTelephony，调私有 C API
///    `_CTServerConnectionCreate` + `_CTServerConnectionInstallCarrierBundle`
///    把**绝对路径字符串**交给 CommCenter（root 守护进程）；
/// 3. CommCenter 完成解包 / 校验 / 写入运营商配置区并触发重载 ——
///    与 iTunes / Finder / 爱思"更新 IPCC"是同一套系统安装管线。
///
/// 这就是爱思在电脑端做的事（usbmuxd → lockdownd 配对 → 运营商配置更新服务），
/// 我们设备端 App 扮演"配对主机"，用 RSD 隧道完成同样的上传 + 触发。
///
/// ⚠️ CommCenter 侧会校验调用方的签名权限；EscapeSpace 当前仅有
/// `get-task-allow`。若被拒绝，错误码会明确告诉我们缺什么。
final class IPCCInstallService {

    static let shared = IPCCInstallService()
    private init() {}

    private let afc = AFCService.shared

    /// CommCenter 中转目录（AFC 相对路径，= /var/mobile/media/PublicStaging）。
    static let stagingAFCPath = "PublicStaging"
    /// 传给 CoreTelephony 的绝对路径前缀。
    static let stagingAbsolutePath = "/private/var/mobile/Media/PublicStaging"

    // MARK: - CoreTelephony 私有 C API（dlopen + dlsym）

    private let coreTelephonyHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW)
    }()

    private typealias CTServerConnectionCreateFn =
        @convention(c) (CFAllocator?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> OpaquePointer?
    private typealias CTServerConnectionInstallCarrierBundleFn =
        @convention(c) (OpaquePointer?, CFString?) -> Int32

    private var createConnection: CTServerConnectionCreateFn? {
        guard let handle = coreTelephonyHandle,
              let sym = dlsym(handle, "_CTServerConnectionCreate") else { return nil }
        return unsafeBitCast(sym, to: CTServerConnectionCreateFn.self)
    }

    private var installCarrierBundle: CTServerConnectionInstallCarrierBundleFn? {
        guard let handle = coreTelephonyHandle,
              let sym = dlsym(handle, "_CTServerConnectionInstallCarrierBundle") else { return nil }
        return unsafeBitCast(sym, to: CTServerConnectionInstallCarrierBundleFn.self)
    }

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
                detail: dict["detail"] as? String ?? ""
            )
        }
    }

    private func appendRecord(_ record: InstallRecord) {
        var list: [[String: Any]] = savedRecords().map { [
            "fileName": $0.fileName, "bundleName": $0.bundleName,
            "date": $0.date, "success": $0.success, "detail": $0.detail
        ] }
        list.insert([
            "fileName": record.fileName, "bundleName": record.bundleName,
            "date": record.date, "success": record.success, "detail": record.detail
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

    // MARK: - 安装（AFC 上传 + CommCenter 官方通道）

    /// 安装 .ipcc。
    /// 1. 经 AFC 隧道上传到 `/var/mobile/Media/PublicStaging/`；
    /// 2. 调 `_CTServerConnectionInstallCarrierBundle` 交给 CommCenter；
    /// 3. 返回 0 = 已受理（CommCenter 后台解包/校验/安装，需重启或等通知生效）。
    func install(ipccURL: URL) throws -> String {
        let parsed = try parse(ipccURL: ipccURL)
        let data = try Data(contentsOf: ipccURL)
        let name = ipccURL.lastPathComponent

        // 1. AFC 上传到 PublicStaging（media 内，隧道直达，无系统权限要求）
        let remotePath = Self.stagingAFCPath + "/" + name
        do {
            try afc.batch { client in
                _ = Self.stagingAFCPath.withCString { afc_make_directory(client, $0) }
            }
            // 清掉同名残留再传（爱思同款：先 remove 再 copy）
            try? afc.removePath(remotePath)
            try afc.writeFile(data, to: remotePath)
        } catch {
            appendRecord(InstallRecord(fileName: name, bundleName: parsed.bundleName,
                                       date: Date(), success: false, detail: "上传失败：\(error.localizedDescription)"))
            throw error
        }

        // 2. 调 CoreTelephony 私有 API，触发 CommCenter 安装
        guard let create = createConnection, let install = installCarrierBundle else {
            let msg = "无法加载 CoreTelephony 私有 API"
            appendRecord(InstallRecord(fileName: name, bundleName: parsed.bundleName,
                                       date: Date(), success: false, detail: msg))
            throw makeError(msg)
        }
        guard let conn = create(kCFAllocatorDefault, nil, nil) else {
            let msg = "创建 CTServerConnection 失败"
            appendRecord(InstallRecord(fileName: name, bundleName: parsed.bundleName,
                                       date: Date(), success: false, detail: msg))
            throw makeError(msg)
        }

        let absolute = Self.stagingAbsolutePath + "/" + name
        let ret = install(conn, absolute as CFString)
        if ret == 0 {
            appendRecord(InstallRecord(fileName: name, bundleName: parsed.bundleName,
                                       date: Date(), success: true,
                                       detail: "已交给 CommCenter 安装（\(absolute)）"))
            return absolute
        } else {
            let msg = "CommCenter 拒绝安装（错误码 \(ret)）。该服务会校验调用方签名权限，"
                + "EscapeSpace 当前只有 get-task-allow，可能需要额外的系统级 entitlement。"
            appendRecord(InstallRecord(fileName: name, bundleName: parsed.bundleName,
                                       date: Date(), success: false, detail: msg))
            throw makeError(msg)
        }
    }
}
