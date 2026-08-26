import Foundation
import UIKit

/// 监督模式描述文件仓库。
///
/// 移植自 jailbreakdotparty/Lithium。与「配置管理」里现有的「直接写入系统 plist」
/// 双轨并存：这里是**纯描述文件生成**路线——不需要任何漏洞 / 越狱，只要设备处于
/// 监督模式（通常用 Nugget 开启），把生成的 `.mobileconfig` 通过本机 HTTP 服务交给
/// 系统安装即可。所有写入都发生在「设置 → VPN 与设备管理」里，不触碰系统配置目录，
/// 因此完全不依赖 bad_query / MHA 等沙盒逃逸机制。
///
/// 模板随包携带（Resources/esc.*.mobileconfig），首次进入某功能时复制到
/// `Documents/Profiles/` 作为可编辑副本；重置即重新从模板覆盖。
enum SupervisedProfileStore {

    /// 支持的受监管描述文件类型。
    enum Profile: String, CaseIterable, Identifiable {
        case restrictions   // 限制开关 + 应用隐藏（共用 com.apple.applicationaccess 载体）
        case notifications   // 通知管理
        case footnote       // 锁屏页脚（监管，com.apple.shareddeviceconfiguration）
        case webclip        // 网页快捷方式

        var id: String { rawValue }

        /// 随包模板资源名（不含扩展名）。
        var templateName: String {
            switch self {
            case .restrictions: return "esc.restrictions"
            case .notifications: return "esc.notifications"
            case .footnote:     return "esc.footnote"
            case .webclip:      return "esc.webclip"
            }
        }

        /// 中文显示名（用于导航入口与安装页标题）。
        var displayName: String {
            switch self {
            case .restrictions: return "限制开关"
            case .notifications: return "通知管理"
            case .footnote:     return "锁屏页脚"
            case .webclip:      return "网页快捷方式"
            }
        }

        /// 入口图标（系统符号，避开棕色系，沿用蓝/橙语义色）。
        var systemImage: String {
            switch self {
            case .restrictions: return "hand.raised.fill"
            case .notifications: return "bell.slash.fill"
            case .footnote:     return "text.line.first.and.arrowtriangle.forward"
            case .webclip:      return "safari.fill"
            }
        }
    }

    // MARK: - 路径

    private static let fm = FileManager.default

    /// 可编辑副本所在目录：`Documents/Profiles/`。
    static var profilesDirectory: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Profiles", isDirectory: true)
    }

    /// 某类型当前可编辑副本的路径。
    static func savedURL(for profile: Profile) -> URL {
        profilesDirectory
            .appendingPathComponent(profile.templateName)
            .appendingPathExtension("mobileconfig")
    }

    /// 随包模板路径。
    static func templateURL(for profile: Profile) -> URL? {
        Bundle.main.url(forResource: profile.templateName, withExtension: "mobileconfig")
    }

    // MARK: - 监督模式检测

    /// 设备是否处于监督模式。
    /// 读取系统组里的 CloudConfigurationDetails.plist 的 `IsSupervised` 字段——
    /// 与「配置管理」直接写入轨共用同一来源，读取不依赖写权限。
    static func isSupervised() -> Bool {
        let path = ConfigPlistURL.cloudConfig.path
        guard fm.fileExists(atPath: path),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return false
        }
        return dict["IsSupervised"] as? Bool ?? false
    }

    // MARK: - 读写

    /// 确保可编辑副本存在（不存在则从模板复制）。
    private static func ensureCopied(_ profile: Profile) throws {
        let dest = savedURL(for: profile)
        if fm.fileExists(atPath: dest.path) { return }
        guard let template = templateURL(for: profile) else {
            throw StoreError.missingTemplate(profile.templateName)
        }
        try fm.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: template, to: dest)
    }

    /// 载入某类型当前的可编辑副本（NSMutableDictionary）。
    /// 使用 `mutableContainers` 确保嵌套的 array / dict 也是可变的，
    /// 否则写入 `PayloadContent[0]` 等嵌套键时会因不可变容器而失败。
    static func load(_ profile: Profile) throws -> NSMutableDictionary {
        try ensureCopied(profile)
        let url = savedURL(for: profile)
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(
            from: data, options: [.mutableContainers], format: nil
        ) as? NSMutableDictionary else {
            throw StoreError.corruptProfile(profile.templateName)
        }
        return dict
    }

    /// 将字典序列化写回可编辑副本。
    static func save(_ profile: Profile, dict: NSMutableDictionary) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: savedURL(for: profile), options: .atomic)
    }

    /// 重置为模板默认值（删除副本，下次 load 自动从模板重建）。
    static func reset(_ profile: Profile) throws {
        let dest = savedURL(for: profile)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
    }

    // MARK: - 安装 / 导出

    /// 通过本机 HTTP 服务把当前副本交给系统安装（与「屏蔽域名」同机制）。
    /// 调用方需在主线程调用（内部会 `UIApplication.shared.open`）。
    static func install(_ profile: Profile) throws {
        let dict = try load(profile)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let filename = savedURL(for: profile).lastPathComponent
        let port = try ProfileHTTPServer.shared.start(payload: data, filename: filename)
        UIApplication.shared.open(URL(string: "http://127.0.0.1:\(port)/")!)
        // 安装完成后关闭临时服务。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            ProfileHTTPServer.shared.stop()
        }
    }

    /// 导出当前副本到可分享的临时位置（用于隔空投送 / 存文件）。
    static func exportURL(_ profile: Profile) throws -> URL {
        let dict = try load(profile)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("EscapeSpace-\(profile.templateName)")
            .appendingPathExtension("mobileconfig")
        try data.write(to: tmp, options: .atomic)
        return tmp
    }

    // MARK: - 错误

    enum StoreError: LocalizedError {
        case missingTemplate(String)
        case corruptProfile(String)

        var errorDescription: String? {
            switch self {
            case .missingTemplate(let n): return "找不到模板文件：\(n).mobileconfig（请确认已随包打包）"
            case .corruptProfile(let n): return "描述文件已损坏，无法解析：\(n).mobileconfig"
            }
        }
    }
}
