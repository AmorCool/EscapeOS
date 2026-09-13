import Foundation

/// v0.3.303：爱思助手 PC 端应用接口客户端（**完全免登录**）
///
/// 来源：`https://app4.i4.cn/pc_v9/`（爱思 PC V9 的 Vite SPA）里的实际调用，非推测。
/// 从它的 `index-4f71eb97.js` 取到的接口定义原文：
/// ```js
/// const ze = "https://app4.i4.cn"
/// ms = a => Ce({ url: ze + "/getSpecialList.xhtml", method: "GET",  params: a })
/// _s = a => Ce({ url: ze + "/getAppList.xhtml",    method: "GET",  params: a })
/// gs = a => Ce({ url: ze + "/appinfo.xhtml",       method: "POST", data:   a })
/// hs = a => Ce({ url: "https://search-app-m.i4.cn/appInfo/jsonpResp.go", method: "GET", params: a })
/// ```
/// 列表调用的完整参数（同一文件 appList 组件原文）：
/// ```js
/// _s({ isjail:0, isAuth:1, model: model=="iPhone"?101:102,
///      remd, sort, type, pageno, specialid, hd: model=="iPhone"?0:1 })
/// ```
/// 搜索调用的参数（appListSearch 组件原文）：
/// ```js
/// hs({ reqtype:100, ft:3, page, model: model=="iPad"?102:101,
///      isTs:0, rows, keyword, isHd: model=="iPad"?1:0 })
/// ```
/// 资源前缀（同文件原文）：图标 `https://d-image.i4.cn/image/`，
/// 安装包 `https://d-app6.i4.cn/soft/`。
///
/// **关键点**：这些接口**不需要登录、不需要签名**，直接 GET 即返回真实数据；
/// 搜索结果里的 `isSignOK == "1"` 表示服务端存放的就是**已签名的 IPA**
/// （实测 `d-app6.i4.cn/soft/<path>` 可下载，长度与接口 `sizeByte` 一致）。
enum I4PCStoreClient {

    // MARK: - 常量

    static let listHost = "https://app4.i4.cn"
    static let searchHost = "https://search-app-m.i4.cn"
    /// 图标前缀（列表接口给完整 URL，搜索接口给相对路径）
    static let iconPrefix = "https://d-image.i4.cn/image/"
    /// 安装包前缀（`path` / `plist` 的相对路径拼在这里）
    static let packagePrefix = "https://d-app6.i4.cn/soft/"

    private static let referer = "https://app4.i4.cn/pc_v9/index.html"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    // MARK: - 模型

    struct I4App: Identifiable, Hashable {
        var id: String                 // 爱思应用 id
        var name: String               // appname / appName
        var bundleId: String?          // sourceId
        var itemId: String?            // App Store trackId
        var version: String?           // version
        var versionId: String?
        var slogan: String?
        var icon: String?              // 完整 URL
        var sizeText: String?          // "767.29MB"
        var sizeBytes: Int64?
        var minOS: String?
        var category: String?          // typeName
        /// 安装包类型（详情接口 `appinfo.xhtml` 的参数之一）
        var pkgType: String?
        /// IPA 相对路径（`d-app6.i4.cn/soft/` 之下）
        var ipaPath: String?
        var plistPath: String?
        /// 服务端是否已签名（`isSignOK == "1"`）
        var isSigned: Bool = false

        var ipaURL: URL? {
            guard let s = I4PCStoreClient.normalizeAssetURL(ipaPath) else { return nil }
            return URL(string: s)
        }
        var plistURL: URL? {
            guard let s = I4PCStoreClient.normalizeAssetURL(plistPath) else { return nil }
            return URL(string: s)
        }
    }

    /// v0.3.364：应用详情里的一个**历史版本**（来自 `appinfo.xhtml` 的 `historyversion`）。
    ///
    /// 字段名取自爱思 PC V9 商店详情页（`index-4f71eb97.js` 里 `appDetail` 组件）实测渲染：
    /// `T.Version` / `T.releasetime` / `T.Size` / `T.versionnote`，下载用 `T.path`。
    struct I4Version: Identifiable, Hashable {
        var id: String                 // versionid
        var version: String
        var sizeText: String?
        var sizeBytes: Int64?
        var releaseTime: String?       // releasetime，形如 "2025-06-06"
        var note: String?              // versionnote，多数为空
        var minOS: String?
        var md5: String?
        /// 该版本的 IPA 相对地址（http 明文，需规范化）
        var ipaPath: String?

        var ipaURL: URL? {
            guard let s = I4PCStoreClient.normalizeAssetURL(ipaPath) else { return nil }
            return URL(string: s)
        }
    }

    /// v0.3.364：应用详情（`appinfo.xhtml`）。
    struct I4AppDetail: Hashable {
        var appId: String
        var name: String
        var bundleId: String?
        var icon: String?
        var screenshots: [String] = []
        var version: String?
        var sizeText: String?
        var sizeBytes: Int64?
        var minOS: String?
        var category: String?
        var company: String?
        var language: String?
        var updateTime: String?
        var newVersionNote: String?
        var longNote: String?
        var shortNote: String?
        var downloadCount: String?
        var ipaPath: String?
        var plistPath: String?
        var versions: [I4Version] = []
        /// v0.3.368：App 隐私（`app_privacy.privacycards`），没有这块数据时为空数组
        var privacyCards: [I4PrivacyCard] = []

        var ipaURL: URL? {
            guard let s = I4PCStoreClient.normalizeAssetURL(ipaPath) else { return nil }
            return URL(string: s)
        }
    }

    /// v0.3.368：`app_privacy.privacycards[]` 里的一个**分组**（爱思原文 heading）。
    ///
    /// 实测原文（微信）：
    /// ```json
    /// {"heading":"与您关联的数据","description":"开发者可能会收集以下数据，且数据与您的身份关联：",
    ///  "items":[{"heading":"健康与健身","icon":""}, …]}
    /// ```
    /// **保真度边界**：这份数据比 App Store 的粗 —— 只有「分组 → 数据类别」两层，
    /// 没有 `purposes` / `dataTypes` 那层，所以只映射存在的层，缺的不编。
    struct I4PrivacyCard: Hashable, Identifiable {
        var heading: String
        var items: [I4PrivacyItem]

        var id: String { heading }
    }

    /// v0.3.368：隐私分组里的一条**数据类别**（`items[]`）。
    /// 实测 `icon` 恒为空串，所以它是「有则显示」的可选字段。
    struct I4PrivacyItem: Hashable, Identifiable {
        var heading: String
        var icon: String?

        var id: String { heading }
    }

    /// v0.3.304：把服务端给的资源地址规范化成 **https**。
    ///
    /// **这是真机实测踩到的坑**：列表接口返回的 `path` 是**明文 http**：
    /// `http://d.app6.i4.cn/soft/2026/09/10/23/6466733523/z…_796155.ipa`
    /// iOS 的 ATS 会直接拒绝该连接，用户看到的是
    /// 「The resource could not be loaded because the App Transport Security policy
    /// requires the use of a secure connection.」——即"点安装没反应/失败"。
    ///
    /// 爱思自己的前端就是这么干的（`index-4f71eb97.js` 原文）：
    /// `path.replace("http://d.app6.i4.cn/soft", "https://d-app6.i4.cn/soft")`
    /// 实测 https 侧可正常下载（206，长度与接口 `sizebyte` 一致）。
    static func normalizeAssetURL(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        v = v.replacingOccurrences(of: "http://d.app6.i4.cn/soft",
                                   with: "https://d-app6.i4.cn/soft")
        v = v.replacingOccurrences(of: "http://d.image.i4.cn",
                                   with: "https://d-image.i4.cn")
        // 任何残留的明文 i4 CDN 一并升级，避免再被 ATS 拦
        v = v.replacingOccurrences(of: "http://d-app6.i4.cn", with: "https://d-app6.i4.cn")
        v = v.replacingOccurrences(of: "http://d-image.i4.cn", with: "https://d-image.i4.cn")
        if v.hasPrefix("http") { return v }
        return packagePrefix + v
    }

    /// 榜单（remd/sort 取自 PC 端首页模块的真实配置）
    enum Rank: String, CaseIterable, Identifiable {
        case recommend = "1|0"
        case apps = "3|1"
        case games = "3|2"
        case hotApps = "44|1"
        case hotGames = "44|2"

        var id: String { rawValue }
        var remd: Int { Int(rawValue.split(separator: "|")[0]) ?? 1 }
        var sort: Int { Int(rawValue.split(separator: "|")[1]) ?? 0 }

        var title: String {
            switch self {
            case .recommend: return "推荐"
            case .apps: return "应用"
            case .games: return "游戏"
            case .hotApps: return "热门应用"
            case .hotGames: return "热门游戏"
            }
        }
    }

    enum StoreError: Error, LocalizedError {
        case badURL
        case http(Int)
        case decode
        case empty
        case notSigned
        case detailUnavailable
        /// v0.3.366：搜索结果里没有 `itemId` 等于目标 Apple trackId 的应用（映射不到爱思 appid）
        case appNotMatched

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址无效"
            case .http(let c): return "请求失败（HTTP \(c)）"
            case .decode: return "返回数据解析失败"
            case .empty: return "该分组没有数据"
            case .notSigned: return "该应用在服务端没有可用的已签名安装包"
            case .detailUnavailable: return "该应用暂无详情"
            case .appNotMatched: return "爱思没有匹配该应用"
            }
        }
    }

    // MARK: - 请求

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StoreError.http(http.statusCode)
        }
        return data
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// v0.3.364：表单 POST（`appinfo.xhtml` 是 POST + `application/x-www-form-urlencoded`）
    private static func post(_ url: URL, form: [String: String]) async throws -> Data {
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StoreError.http(http.statusCode)
        }
        return data
    }

    // MARK: - 列表

    /// 榜单列表（免登录）
    static func list(rank: Rank, page: Int = 1, iPad: Bool = false) async throws -> [I4App] {
        var comps = URLComponents(string: listHost + "/getAppList.xhtml")
        comps?.queryItems = [
            .init(name: "isjail", value: "0"),
            .init(name: "isAuth", value: "1"),
            .init(name: "model", value: iPad ? "102" : "101"),
            .init(name: "remd", value: String(rank.remd)),
            .init(name: "sort", value: String(rank.sort)),
            .init(name: "type", value: "0"),
            .init(name: "pageno", value: String(page)),
            .init(name: "specialid", value: "0"),
            .init(name: "hd", value: iPad ? "1" : "0"),
        ]
        guard let url = comps?.url else { throw StoreError.badURL }
        guard let obj = jsonObject(try await get(url)) else { throw StoreError.decode }
        let raw = obj["list"] as? [[String: Any]] ?? []
        return raw.compactMap(parse)
    }

    /// 专题列表（免登录；`getSpecialList.xhtml`）
    static func specials() async throws -> [[String: Any]] {
        var comps = URLComponents(string: listHost + "/getSpecialList.xhtml")
        comps?.queryItems = [.init(name: "pageno", value: "1")]
        guard let url = comps?.url else { throw StoreError.badURL }
        guard let obj = jsonObject(try await get(url)) else { throw StoreError.decode }
        return obj["list"] as? [[String: Any]] ?? []
    }

    // MARK: - 搜索

    /// 关键词搜索（免登录）。返回项带 `ipaPath` / `plistPath`。
    static func search(keyword: String, page: Int = 1, rows: Int = 20, iPad: Bool = false) async throws -> [I4App] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        var comps = URLComponents(string: searchHost + "/appInfo/jsonpResp.go")
        comps?.queryItems = [
            .init(name: "reqtype", value: "100"),
            .init(name: "ft", value: "3"),
            .init(name: "page", value: String(page)),
            .init(name: "model", value: iPad ? "102" : "101"),
            .init(name: "isTs", value: "0"),
            .init(name: "rows", value: String(rows)),
            .init(name: "keyword", value: kw),
            .init(name: "isHd", value: iPad ? "1" : "0"),
        ]
        guard let url = comps?.url else { throw StoreError.badURL }
        guard let obj = jsonObject(try await get(url)) else { throw StoreError.decode }
        let result = obj["result"] as? [String: Any]
        let raw = result?["list"] as? [[String: Any]] ?? []
        return raw.compactMap(parseSearch)
    }

    /// 搜索建议（免登录取词；`jsonRespSuggest.go`）
    static func suggest(keyword: String) async throws -> [String] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        var comps = URLComponents(string: searchHost + "/appInfo/jsonRespSuggest.go")
        comps?.queryItems = [.init(name: "keyword", value: kw)]
        guard let url = comps?.url else { throw StoreError.badURL }
        guard let obj = jsonObject(try await get(url)) else { return [] }
        let result = obj["result"]
        if let arr = result as? [String] { return arr }
        if let dict = result as? [String: Any], let arr = dict["list"] as? [String] { return arr }
        return []
    }

    // MARK: - 详情 + 历史版本

    /// v0.3.364：应用详情（免登录）。
    ///
    /// 来源为爱思 PC V9 商店详情页（`app4.i4.cn/pc_v9` 的 `appDetail` 组件）实测调用：
    /// ```js
    /// gs = a => Ce({ url: ze + "/appinfo.xhtml", method: "POST", data: a })   // ze = "https://app4.i4.cn"
    /// const w = { appid: S.id, pkagetype: S.pkagetype, model: e.model /* iPhone | iPad */, from: 1 }
    /// ```
    /// 实测（2026-09）返回体含 `AppName` / `Version` / `Size` / `Company` / `UpdateTime` /
    /// `TypeName` / `Language` / `MinVersion` / `LongNote` / `NewVersionNote` / `Image[]`（截图）/
    /// `app_privacy`（App 隐私，v0.3.368），以及 **`historyversion[]`（历史版本）**。`pkagetype` 可省略。
    static func detail(appId: String,
                       pkagetype: String? = nil,
                       iPad: Bool = false) async throws -> I4AppDetail {
        let id = appId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let url = URL(string: listHost + "/appinfo.xhtml") else { throw StoreError.badURL }
        var form = ["appid": id, "model": iPad ? "iPad" : "iPhone", "from": "1"]
        if let p = pkagetype, !p.isEmpty { form["pkagetype"] = p }
        guard let obj = jsonObject(try await post(url, form: form)) else { throw StoreError.decode }
        guard let detail = parseDetail(obj) else { throw StoreError.detailUnavailable }
        return detail
    }

    // MARK: - Apple trackId → 爱思 appid → 历史版本

    /// v0.3.366：按 **Apple trackId** 取爱思侧的历史版本（用于 `volumeStoreDownloadProduct`
    /// 静默空包时的 `externalVersionId` 候选；见 `AppStoreLocalInstallService.candidateVersionIDs`）。
    ///
    /// 两步映射（第一步是实测踩到的坑）：
    /// 1. **映射到爱思 appid**：搜索接口**不接受纯数字的 trackId 当关键词**（实测多个真实 trackId
    ///    全部返回 0 条），所以只能**按应用名搜**，再在结果里挑 `itemId == trackId` 的那条，
    ///    取其 `id`（例：搜「微信」得 `id=165776`，同一项的 `itemId` 就是微信的 App Store trackId）
    ///    —— `id` 与 `itemId` 是**两个不同字段**，别拿错。
    /// 2. `POST appinfo.xhtml` 取 `historyversion[]`，字段见 `I4Version`。
    ///
    /// **请求上界：1 次搜索 + 1 次详情**（映射失败即止，不再多打）。映射不到抛 `appNotMatched`，
    /// 调用方按「爱思源不可用」降级。返回顺序与接口一致，**排序/裁剪由调用方统一负责**。
    ///
    /// 另注意：爱思的 `historyversion` 是**缓存快照**，实测**不含当前最新版**
    ///（历史里的 `versionid` 最高值明显小于详情里当前版本的 `versionid`）—— 只适合当兜底来源。
    static func historyVersions(trackId: String, name: String,
                                iPad: Bool = false) async throws -> [I4Version] {
        let tid = trackId.trimmingCharacters(in: .whitespaces)
        let kw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty, !kw.isEmpty else { throw StoreError.appNotMatched }
        let apps = try await search(keyword: kw, rows: 30, iPad: iPad)
        guard let app = apps.first(where: { $0.itemId == tid }) else { throw StoreError.appNotMatched }
        let detail = try await detail(appId: app.id, pkagetype: app.pkgType, iPad: iPad)
        return detail.versions
    }

    // MARK: - 解析

    private static func parseDetail(_ d: [String: Any]) -> I4AppDetail? {
        guard let appId = str(d["AppId"]) ?? str(d["appid"]),
              let name = str(d["AppName"]) else { return nil }
        var detail = I4AppDetail(appId: appId, name: name)
        detail.bundleId = str(d["sourceid"]) ?? str(d["sourceId"])
        detail.icon = normalizeIcon(str(d["Icon"]))
        detail.screenshots = (d["Image"] as? [Any] ?? []).compactMap { normalizeIcon(str($0)) }
        detail.version = str(d["Version"]) ?? str(d["ShortVersion"])
        detail.sizeText = str(d["Size"])
        detail.sizeBytes = int64(d["sizebyte"]) ?? int64(d["sizeByte"])
        detail.minOS = str(d["MinVersion"])
        detail.category = str(d["TypeName"])
        detail.company = str(d["Company"])
        detail.language = str(d["Language"])
        detail.updateTime = str(d["UpdateTime"])
        detail.shortNote = str(d["shortshortnote"])
        detail.newVersionNote = stripHTML(str(d["NewVersionNote"]))
        detail.longNote = stripHTML(str(d["LongNote"]))
        detail.downloadCount = str(d["DownloadCount"])
        detail.ipaPath = str(d["path"])
        detail.plistPath = str(d["plist"])
        let raw = d["historyversion"] as? [[String: Any]] ?? []
        detail.versions = raw.compactMap(parseVersion)
        detail.privacyCards = parsePrivacy(d)
        return detail
    }

    /// v0.3.368：解析 `app_privacy.privacycards[]`（App 隐私）。
    /// 两种「没有」都要落成空数组：整个 `app_privacy` 缺失（实测豆包/汽水音乐），
    /// 或某个分组没有 `items`（空分组不显示）。
    private static func parsePrivacy(_ d: [String: Any]) -> [I4PrivacyCard] {
        guard let privacy = d["app_privacy"] as? [String: Any] else { return [] }
        let cards = privacy["privacycards"] as? [[String: Any]] ?? []
        return cards.compactMap { card in
            guard let heading = str(card["heading"]) else { return nil }
            let items = (card["items"] as? [[String: Any]] ?? []).compactMap { item -> I4PrivacyItem? in
                guard let h = str(item["heading"]) else { return nil }
                return I4PrivacyItem(heading: h, icon: normalizeIcon(str(item["icon"])))
            }
            guard !items.isEmpty else { return nil }
            return I4PrivacyCard(heading: heading, items: items)
        }
    }

    private static func parseVersion(_ d: [String: Any]) -> I4Version? {
        let vid = str(d["versionid"]) ?? str(d["versionId"])
        let ver = str(d["Version"]) ?? str(d["version"])
        guard let vid, let ver, !ver.isEmpty else { return nil }
        var v = I4Version(id: vid, version: ver)
        v.sizeText = str(d["Size"])
        v.sizeBytes = int64(d["sizebyte"]) ?? int64(d["sizeByte"])
        v.releaseTime = str(d["releasetime"])
        v.note = str(d["versionnote"])
        v.minOS = str(d["MinVersion"])
        v.md5 = str(d["md5"])
        v.ipaPath = str(d["path"])
        return v
    }

    /// 详情里的 `LongNote` / `NewVersionNote` 带 HTML 标签，两端客户端都先去标签再展示
    ///（RN bundle：`n.LongNote.replace(/<\/?[^>]*>/g,'')`）。
    private static func stripHTML(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let clean = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func parse(_ d: [String: Any]) -> I4App? {
        let id = str(d["id"])
        let name = str(d["appname"]) ?? str(d["appName"])
        guard let id, let name, !name.isEmpty else { return nil }
        var app = I4App(id: id, name: name)
        app.bundleId = str(d["sourceId"]) ?? str(d["sourceid"])
        app.itemId = str(d["itemId"]) ?? str(d["itemid"])
        app.version = str(d["version"]) ?? str(d["shortversion"])
        app.versionId = str(d["versionid"]) ?? str(d["versionId"])
        app.slogan = str(d["slogan"])
        app.sizeText = str(d["size"])
        app.sizeBytes = int64(d["sizebyte"]) ?? int64(d["sizeByte"])
        app.minOS = str(d["minversion"]) ?? str(d["minVersion"])
        app.category = str(d["typeName"])
        app.pkgType = str(d["pkagetype"]) ?? str(d["pkgType"])
        app.icon = normalizeIcon(str(d["icon"]))
        app.ipaPath = str(d["path"])
        app.plistPath = str(d["plist"])
        app.isSigned = str(d["isSignOK"]) == "1"
        return app
    }

    private static func parseSearch(_ d: [String: Any]) -> I4App? {
        // 搜索返回的字段名与列表不同（appName / versionId / sizeByte）
        parse(d)
    }

    private static func normalizeIcon(_ s: String?) -> String? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") {
            // 列表接口给的是 http 明文，统一升 https（否则 ATS 拦图）
            var v = raw
            v = v.replacingOccurrences(of: "http://d.image.i4.cn", with: "https://d-image.i4.cn")
            v = v.replacingOccurrences(of: "http://d.app6.i4.cn", with: "https://d-app6.i4.cn")
            return v
        }
        return iconPrefix + raw
    }

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }
}
