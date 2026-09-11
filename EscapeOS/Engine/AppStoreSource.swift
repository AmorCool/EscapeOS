import Foundation

/// v0.3.297：AppStore 商店 —— 分发源（全新独立实现）
///
/// 逆向结论（爱思助手手机端 AsTools.app / HotJs main.jsbundle 原文）：
///   安装 = `itms-services://?action=download-manifest&url=<plist>`
///   其中 plist 来自服务端：`list-app-m.i4.cn/appinfo.xhtml` → 字段 `plist` / `plist_s`
///   （`onlyshare==1` 用 plist，否则 plist_s），IPA 托管在 `dl.i4.cn`。
///   服务端接口带 RSA 签名（`NativeModules.Crypto.rsa`，实现在客户端原生模块里）。
///
/// 本模块把「源」抽象出来：**由用户自己配置源**，App 只负责
/// ①按模板/接口解析出 manifest plist 地址 ②交给系统 itms-services 安装。
/// 不内置任何第三方分发地址。
struct AppStoreSource: Identifiable, Codable, Hashable {
    /// 唯一标识
    var id: String
    /// 展示名
    var name: String
    /// 是否启用
    var enabled: Bool
    /// 详情接口地址模板（GET），支持占位符 {id} / {bundleId}
    /// 例：`https://example.com/appinfo.xhtml?appid={id}`
    var infoURLTemplate: String
    /// 从详情接口返回的 JSON 里取 plist 地址的字段路径，支持 `a.b.c` 嵌套
    /// 例：`plist_s`、`data.plist`
    var plistFieldPath: String
    /// 直接给出 plist 地址的模板（若填写，则优先用模板，不再请求接口）
    /// 例：`https://example.com/{bundleId}.plist`
    var plistURLTemplate: String
    /// 请求详情接口时附带的请求头（JSON 字符串，可空）
    var extraHeaders: String

    init(id: String = UUID().uuidString,
         name: String,
         enabled: Bool = true,
         infoURLTemplate: String = "",
         plistFieldPath: String = "",
         plistURLTemplate: String = "",
         extraHeaders: String = "") {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.infoURLTemplate = infoURLTemplate
        self.plistFieldPath = plistFieldPath
        self.plistURLTemplate = plistURLTemplate
        self.extraHeaders = extraHeaders
    }

    /// 用应用信息填充模板占位符
    func fill(_ template: String, item: AppStoreItem) -> String {
        var s = template
        s = s.replacingOccurrences(of: "{id}", with: item.id)
        s = s.replacingOccurrences(of: "{bundleId}", with: item.bundleId ?? "")
        s = s.replacingOccurrences(of: "{name}", with: item.name)
        s = s.replacingOccurrences(of: "{version}", with: item.version ?? "")
        return s
    }

    var isUsable: Bool {
        !plistURLTemplate.trimmingCharacters(in: .whitespaces).isEmpty
            || !infoURLTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 源仓库（UserDefaults 持久化，JSON 编码）
final class AppStoreSourceStore {
    static let shared = AppStoreSourceStore()

    private let key = "AppStoreDistributionSources"

    private(set) var sources: [AppStoreSource] = []

    private init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([AppStoreSource].self, from: data) else {
            sources = []
            return
        }
        sources = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ source: AppStoreSource) {
        sources.append(source)
        save()
    }

    func update(_ source: AppStoreSource) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[idx] = source
        save()
    }

    func remove(id: String) {
        sources.removeAll { $0.id == id }
        save()
    }

    var enabledSources: [AppStoreSource] { sources.filter { $0.enabled && $0.isUsable } }
}
