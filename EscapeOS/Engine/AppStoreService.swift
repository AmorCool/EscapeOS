import Foundation

/// v0.3.295：AppStore 商店服务
/// 全部走 Apple 公开接口（无需登录、无需认证）：
///   · 搜索/详情：https://itunes.apple.com/search、/lookup
///   · 榜单：    https://itunes.apple.com/{cc}/rss/{kind}/limit={n}/genre={id}/json
/// 安装：交给系统 App Store（itms-apps://），或由用户提供 manifest plist 走
///       itms-services OTA 通道（与爱思助手同一条系统机制，见 installViaOTA）。
enum AppStoreService {

    // MARK: - 区域（App Store 商店的国家/地区）

    /// 用户选择的商场区域（`UserDefaults` 持久化）；默认 `cn`（国区）。
    ///
    /// 榜单 RSS、搜索、详情 lookup、版本历史全部走这个区域 —— 不同区域的
    /// 商品池完全不同（美区没有国区应用，反之亦然）。
    static var countryCode: String {
        get { UserDefaults.standard.string(forKey: "AppStore.ShopRegion") ?? "cn" }
        set { UserDefaults.standard.set(newValue, forKey: "AppStore.ShopRegion") }
    }

    /// 可切换的区域（爱思 PC 端同款常用区）
    enum Region: String, CaseIterable, Identifiable {
        case cn, us, hk, tw, jp, gb, ca, au, sg
        var id: String { rawValue }
        /// 选项文案：`中国大陆 · CN`
        var display: String { "\(title) · \(rawValue.uppercased())" }

        var title: String {
            switch self {
            case .cn: return "中国大陆"
            case .us: return "美国"
            case .hk: return "中国香港"
            case .tw: return "中国台湾"
            case .jp: return "日本"
            case .gb: return "英国"
            case .ca: return "加拿大"
            case .au: return "澳大利亚"
            case .sg: return "新加坡"
            }
        }
    }

    static var currentRegion: Region {
        get { Region(rawValue: countryCode) ?? .cn }
        set { countryCode = newValue.rawValue }
    }

    /// v0.3.327：按 Apple ID 的 storefront 自动切换商店区域。
    ///
    /// 登录响应的 `X-Set-Apple-Store-Front`（形如 `143441-1,29`）第一段就是账号所在区的
    /// storefront id，`Configuration.countryCode(for:)` 可反查国家码。
    /// **商店区域与账号区域不一致会出怪事**：浏览到的是 A 区商品、下单却用 B 区
    /// storefront，Apple 会按「该区没有此商品」拒绝（表现为未知错误）。
    /// 登录后直接跟随账号，就不存在这个错配。
    @discardableResult
    static func adoptAccountRegion(storefront: String) -> String? {
        guard let code = Configuration.countryCode(for: storefront)?.lowercased() else { return nil }
        guard code != countryCode else { return code }
        countryCode = code
        return code
    }

    /// 传给 Apple 接口的区域（未指定时用当前选择）
    private static func resolved(_ country: String?) -> String {
        (country?.isEmpty == false ? country! : countryCode)
    }

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

    static func search(term: String, country: String? = nil, limit: Int = 30) async throws -> [AppStoreItem] {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let cc = resolved(country)
        guard let enc = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(enc)&country=\(cc)&entity=software&limit=\(limit)") else {
            throw AppStoreError.badURL
        }
        let obj = try await getJSON(url)
        let results = obj["results"] as? [[String: Any]] ?? []
        var out = results.compactMap { parseSearchItem($0) }

        // v0.3.321：关键词本身就是 BundleID 时（如 com.tencent.xin），搜索接口
        // 命不中，改用 `/lookup?bundleId=` 直查并把结果并到最前面。
        if looksLikeBundleId(t), let hit = try? await lookup(bundleId: t, country: cc) {
            out.removeAll { $0.id == hit.id }
            out.insert(hit, at: 0)
        }
        return out
    }

    /// 关键词是否形如 BundleID（如 `com.tencent.xin`）
    static func looksLikeBundleId(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6, t.contains("."), !t.contains(" ") else { return false }
        return t.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    // MARK: - 详情

    static func lookup(id: String, country: String? = nil) async throws -> AppStoreItem? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(id)&country=\(resolved(country))") else {
            throw AppStoreError.badURL
        }
        let obj = try await getJSON(url)
        let results = obj["results"] as? [[String: Any]] ?? []
        guard let first = results.first else { return nil }
        return parseSearchItem(first)
    }

    /// 按 BundleID 查（`/lookup?bundleId=`）—— 搜 BundleID / 补全字段用
    static func lookup(bundleId: String, country: String? = nil) async throws -> AppStoreItem? {
        let bid = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty,
              let enc = bid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(enc)&country=\(resolved(country))") else {
            throw AppStoreError.badURL
        }
        let obj = try await getJSON(url)
        let results = obj["results"] as? [[String: Any]] ?? []
        guard let first = results.first else { return nil }
        return parseSearchItem(first)
    }

    /// 批量查（`/lookup?id=1,2,3`，Apple 单次上限约 50 个 id）
    static func lookupBatch(ids: [String], country: String? = nil) async throws -> [AppStoreItem] {
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }
        var out: [AppStoreItem] = []
        for chunk in stride(from: 0, to: unique.count, by: 40).map({ Array(unique[$0..<min($0 + 40, unique.count)]) }) {
            let joined = chunk.joined(separator: ",")
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(joined)&country=\(resolved(country))") else { continue }
            guard let obj = try? await getJSON(url) else { continue }
            let results = obj["results"] as? [[String: Any]] ?? []
            out.append(contentsOf: results.compactMap { parseSearchItem($0) })
        }
        return out
    }

    /// 补齐 `bundleId`：**榜单 RSS 不返回 bundleId**，不补的话
    /// 商店列表点「获取」会走不到免登录源（v0.3.320 真机实锤）。
    static func enrichBundleIds(_ items: [AppStoreItem], country: String? = nil) async -> [AppStoreItem] {
        let missing = items.filter { ($0.bundleId ?? "").isEmpty }.map(\.id)
        guard !missing.isEmpty else { return items }
        guard let found = try? await lookupBatch(ids: missing, country: country) else { return items }
        var byId: [String: String] = [:]
        for f in found {
            if let b = f.bundleId, !b.isEmpty { byId[f.id] = b }
        }
        guard !byId.isEmpty else { return items }
        return items.map { item in
            var copy = item
            if (copy.bundleId ?? "").isEmpty, let b = byId[item.id] { copy.bundleId = b }
            return copy
        }
    }

    // MARK: - 榜单

    static func charts(kind: AppStoreRankKind, genre: AppStoreGenre, country: String? = nil, limit: Int = 50) async throws -> [AppStoreItem] {
        let country = resolved(country)
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
        let list = entries.compactMap { parseRSSEntry($0, fallbackGenre: genre == .all ? nil : genre.title) }
        // RSS 不含 bundleId → 一次批量 lookup 补齐（免登录源匹配、收藏栏都需要它）
        return await enrichBundleIds(list, country: country)
    }

    // MARK: - 历史版本

    /// v0.3.300：应用历史版本列表
    ///
    /// Apple 没有公开的「历史版本」JSON 接口（`/lookup` 只返回当前版本），
    /// 但 `apps.apple.com` 的商品页在 SSR 时会把 **完整版本历史**内嵌进 HTML：
    ///
    ///   "page":"versionHistory","pageData":{"shelves":[{"items":[
    ///       {"$kind":"TitledParagraph","text":"<更新说明>",
    ///        "primarySubtitle":"8.0.78","secondarySubtitle":"Tue Sep 08 2026 …"}
    ///   , …]}]}
    ///
    /// 该页面**无需登录、无需认证**，但必须用桌面 UA（手机 UA 会被 301 到
    /// `itms-appss://` 协议链接）。
    static func versionHistory(appId: String, country: String? = nil) async throws -> [AppStoreVersion] {
        guard let url = URL(string: "https://apps.apple.com/\(resolved(country))/app/id\(appId)") else {
            throw AppStoreError.badURL
        }
        var req = URLRequest(url: url)
        // 关键：桌面 UA，否则返回 301 → itms-appss://
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                     + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppStoreError.http(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw AppStoreError.decode }
        return parseVersionHistory(html: html)
    }

    // MARK: - 历史版本解析

    /// 从商品页 HTML 中抽出版本历史数组并结构化
    static func parseVersionHistory(html: String) -> [AppStoreVersion] {
        guard let marker = html.range(of: "\"page\":\"versionHistory\"") else { return [] }
        let tail = html[marker.upperBound...]
        guard let shelvesStart = tail.range(of: "\"shelves\":[") else { return [] }
        let fromBracket = tail[shelvesStart.upperBound...]        // 指向 `[` 之后
        guard let jsonArray = balancedSlice(prefix: "[", from: fromBracket) else { return [] }

        guard let arr = try? JSONSerialization.jsonObject(with: Data(jsonArray.utf8)) as? [Any] else {
            return []
        }
        var out: [AppStoreVersion] = []
        var seen = Set<String>()
        for case let shelf as [String: Any] in arr {
            guard let items = shelf["items"] as? [Any] else { continue }
            for case let it as [String: Any] in items {
                guard let ver = (it["primarySubtitle"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !ver.isEmpty else { continue }
                // 去掉可能的前缀（`mostRecentVersion` shelf 会写「版本 8.0.78」）
                let cleaned = ver.replacingOccurrences(of: "^版本\\s*", with: "",
                                                       options: .regularExpression)
                guard !seen.contains(cleaned) else { continue }
                seen.insert(cleaned)
                out.append(AppStoreVersion(version: cleaned,
                                           dateRaw: it["secondarySubtitle"] as? String,
                                           notes: it["text"] as? String))
            }
        }
        return out
    }

    /// 从 `from` 起做括号配对，返回完整的 `[…]/ {…}` JSON 文本。
    ///
    /// 必须跳过字符串字面量与反斜杠转义 —— 商品页的更新说明里含
    /// `\n`、`( )`、`[ ]` 等字符，朴素计数会截断出错。
    private static func balancedSlice(prefix: String, from: Substring) -> String? {
        let chars = Array(from)
        var depth = 1            // 起点已消费掉开头的 `[`，视为已进入该数组
        var inString = false
        var escaped = false
        var endIndex: Int?
        for (i, c) in chars.enumerated() {
            if escaped { escaped = false; continue }
            if c == "\\" { if inString { escaped = true }; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" {
                depth -= 1
                if depth == 0 { endIndex = i; break }
            }
        }
        guard let end = endIndex else { return nil }
        return prefix + String(chars[0...end])
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
        item.fileSizeBytes = int64Val(d["fileSizeBytes"])
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

    private static func int64Val(_ v: Any?) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
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
