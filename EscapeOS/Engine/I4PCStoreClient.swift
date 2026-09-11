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
        /// IPA 相对路径（`d-app6.i4.cn/soft/` 之下）
        var ipaPath: String?
        var plistPath: String?
        /// 服务端是否已签名（`isSignOK == "1"`）
        var isSigned: Bool = false

        var ipaURL: URL? {
            guard let p = ipaPath, !p.isEmpty else { return nil }
            if p.hasPrefix("http") { return URL(string: p) }
            return URL(string: I4PCStoreClient.packagePrefix + p)
        }
        var plistURL: URL? {
            guard let p = plistPath, !p.isEmpty else { return nil }
            if p.hasPrefix("http") { return URL(string: p) }
            return URL(string: I4PCStoreClient.packagePrefix + p)
        }
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

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址无效"
            case .http(let c): return "请求失败（HTTP \(c)）"
            case .decode: return "返回数据解析失败"
            case .empty: return "该分组没有数据"
            case .notSigned: return "该应用在服务端没有可用的已签名安装包"
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

    // MARK: - 解析

    private static func parse(_ d: [String: Any]) -> I4App? {
        let id = str(d["id"])
        let name = str(d["appname"]) ?? str(d["appName"])
        guard let id, let name, !name.isEmpty else { return nil }
        var app = I4App(id: id, name: name)
        app.bundleId = str(d["sourceId"]) ?? str(d["sourceid"])
        app.itemId = str(d["itemId"])
        app.version = str(d["version"]) ?? str(d["shortversion"])
        app.versionId = str(d["versionid"]) ?? str(d["versionId"])
        app.slogan = str(d["slogan"])
        app.sizeText = str(d["size"])
        app.sizeBytes = int64(d["sizebyte"]) ?? int64(d["sizeByte"])
        app.minOS = str(d["minversion"]) ?? str(d["minVersion"])
        app.category = str(d["typeName"])
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
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("http") {
            // 列表接口给的是 http 明文，统一升 https
            return s.replacingOccurrences(of: "http://d.image.i4.cn",
                                          with: "https://d-image.i4.cn")
        }
        return iconPrefix + s
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
