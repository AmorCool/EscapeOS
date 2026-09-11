import Foundation

/// v0.3.295：AppStore 商店服务
/// 全部走 Apple 公开接口（无需登录、无需认证）：
///   · 搜索/详情：https://itunes.apple.com/search、/lookup
///   · 榜单：    https://itunes.apple.com/{cc}/rss/{kind}/limit={n}/genre={id}/json
/// 安装：交给系统 App Store（itms-apps://），或由用户提供 manifest plist 走
///       itms-services OTA 通道（与爱思助手同一条系统机制，见 installViaOTA）。
enum AppStoreService {

    // MARK: - 基础请求

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppStoreError.http(http.statusCode)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppStoreError.decode
        }
        return obj
    }

    // MARK: - 搜索

    static func search(term: String, country: String = "cn", limit: Int = 30) async throws -> [AppStoreItem] {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        guard let enc = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(enc)&country=\(country)&entity=software&limit=\(limit)") else {
            throw AppStoreError.badURL
        }
        let obj = try await getJSON(url)
        let results = obj["results"] as? [[String: Any]] ?? []
        return results.compactMap { parseSearchItem($0) }
    }

    // MARK: - 详情

    static func lookup(id: String, country: String = "cn") async throws -> AppStoreItem? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)&country=\(country)") else {
            throw AppStoreError.badURL
        }
        let obj = try await getJSON(url)
        let results = obj["results"] as? [[String: Any]] ?? []
        guard let first = results.first else { return nil }
        return parseSearchItem(first)
    }

    // MARK: - 榜单

    static func charts(kind: AppStoreRankKind, genre: AppStoreGenre, country: String = "cn", limit: Int = 50) async throws -> [AppStoreItem] {
        var urlStr = "https://itunes.apple.com/\(country)/rss/\(kind.rawValue)/limit=\(limit)"
        if genre != .all { urlStr += "/genre=\(genre.rawValue)" }
        urlStr += "/json"
        guard let url = URL(string: urlStr) else { throw AppStoreError.badURL }
        let obj = try await getJSON(url)
        guard let feed = obj["feed"] as? [String: Any] else { throw AppStoreError.decode }
        var entries: [[String: Any]] = []
        if let arr = feed["entry"] as? [[String: Any]] {
            entries = arr
        } else if let single = feed["entry"] as? [String: Any] {
            entries = [single]
        }
        return entries.compactMap { parseRSSEntry($0, fallbackGenre: genre == .all ? nil : genre.title) }
    }

    // MARK: - 解析（Search / Lookup）

    private static func parseSearchItem(_ d: [String: Any]) -> AppStoreItem? {
        guard let trackId = intVal(d["trackId"] ?? d["collectionId"]) else { return nil }
        let name = (d["trackName"] as? String) ?? (d["trackCensoredName"] as? String) ?? "未知应用"
        let icon = (d["artworkUrl512"] as? String)
            ?? (d["artworkUrl100"] as? String)
            ?? (d["artworkUrl60"] as? String)
        var item = AppStoreItem(id: String(trackId), name: name)
        item.bundleId = d["bundleId"] as? String
        item.seller = (d["sellerName"] as? String) ?? (d["artistName"] as? String)
        item.price = doubleVal(d["price"])
        item.formattedPrice = d["formattedPrice"] as? String
        item.version = d["version"] as? String
        item.fileSizeBytes = intVal(d["fileSizeBytes"])
        item.rating = doubleVal(d["averageUserRating"])
        item.ratingCount = intVal(d["userRatingCount"])
        item.primaryGenre = d["primaryGenreName"] as? String
        item.genres = (d["genres"] as? [String]) ?? (d["genreIds"] as? [String] ?? [])
        item.releaseDate = d["releaseDate"] as? String
        item.updatedDate = d["currentVersionReleaseDate"] as? String
        item.releaseNotes = d["releaseNotes"] as? String
        item.summary = (d["description"] as? String)
        item.screenshots = (d["screenshotUrls"] as? [String]) ?? []
        item.iconURL = icon
        item.iconSmallURL = (d["artworkUrl60"] as? String) ?? icon
        item.minimumOS = d["minimumOsVersion"] as? String
        item.contentRating = d["contentAdvisoryRating"] as? String
        item.trackViewURL = d["trackViewUrl"] as? String
        item.languages = (d["languageCodesISO2A"] as? [String]) ?? []
        item.supportedDevicesCount = (d["supportedDevices"] as? [String])?.count ?? 0
        return item
    }

    // MARK: - 解析（榜单 RSS）

    private static func parseRSSEntry(_ d: [String: Any], fallbackGenre: String?) -> AppStoreItem? {
        guard let idDict = d["id"] as? [String: Any],
              let attrs = idDict["attributes"] as? [String: Any],
              let imid = attrs["im:id"] as? String, !imid.isEmpty else { return nil }
        let name = label(d["im:name"]) ?? "未知应用"
        var item = AppStoreItem(id: imid, name: name)
        // 图标：im:image 是数组，取最后一档（最大）
        if let images = d["im:image"] as? [[String: Any]], let last = images.last {
            item.iconURL = label(last)
            item.iconSmallURL = label(images.first ?? [:])
        }
        item.summary = label(d["summary"])
        item.seller = label(d["im:artist"])
        if let price = d["im:price"] as? [String: Any] {
            item.formattedPrice = label(price)
            if let pa = price["attributes"] as? [String: Any] { item.price = doubleVal(pa["amount"]) }
        }
        item.primaryGenre = label(d["category"])
        if let category = d["category"] as? [String: Any],
           let ca = category["attributes"] as? [String: Any],
           let g = ca["label"] as? String {
            item.primaryGenre = g
            item.genres = [g]
        } else if let g = fallbackGenre {
            item.primaryGenre = g
            item.genres = [g]
        }
        item.releaseDate = label(d["im:releaseDate"])
        if let link = d["link"] as? [String: Any], let la = link["attributes"] as? [String: Any] {
            item.trackViewURL = la["href"] as? String
            if let imgs = la["im:image"] as? [String: Any] { item.iconURL = item.iconURL ?? label(imgs) }
        }
        return item
    }

    // MARK: - 小工具

    private static func label(_ v: Any?) -> String? {
        guard let d = v as? [String: Any] else { return v as? String }
        return d["label"] as? String
    }

    private static func intVal(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func doubleVal(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

enum AppStoreError: Error, LocalizedError {
    case badURL
    case http(Int)
    case decode

    var errorDescription: String? {
        switch self {
        case .badURL: return "请求地址无效"
        case .http(let code): return "网络请求失败（HTTP \(code)）"
        case .decode: return "数据解析失败"
        }
    }
}
