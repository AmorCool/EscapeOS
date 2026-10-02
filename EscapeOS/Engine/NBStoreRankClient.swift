import Foundation

/// NB 源的**榜单与搜索**（Apple 官方接口）.
///
/// ## 为什么要单独一个文件
///
/// `NBStoreClient` 只管「按 trackId 取包」（NB 私有协议 + 私有加解密），
/// 而**榜单和搜索根本不该走 NB 私有接口** —— 因为 NB 自己也不产这份数据。
///
/// ## 榜单数据的真实来源（实测确证，2026-10-02）
///
/// 逆向 NB（`XNZS`）时从它的 `DXSTStorePlusHomeController`（榜单页）与
/// `DXAppStorePlusModel` 一路追下去，端点是 `/nb/appstore-plus`；
/// 但**真机对照 + 逐条比对**后发现：那一屏的每一行都与 Apple 官方 RSS **逐字一致**：
///
/// | 榜单 | 实测抓回来的前 3 名（中国区） |
/// |---|---|
/// | 免费榜 | 抖音商城-下单返积分、退货包运费 / 红果短剧 / 红果漫剧 |
/// | 付费榜 | 潜水员戴夫 / 喵斯快跑 / 王国保卫战 5 |
/// | 游戏榜（genre=6014） | 跃动小子 / 王者万象棋 / 王者荣耀 |
///
/// ⇒ **NB 的榜单 = Apple 的 RSS**，它只是转发。所以我们**直接接 Apple**，
/// 比对 NB 多绕一层中继更稳（少一个会挂的第三方），也**不再假装「NB 源没有榜单」**。
///
/// ## 与爱思 / 牛蛙的差别
///
/// 爱思的榜单是**爱思自己的服务器**算的（`app4.i4.cn`，且它顺带给了 IPA 直链）；
/// Apple RSS **只给元数据**（图标 / 名字 / 开发者 / 价格 / 分类 / 简介），
/// **不给安装包**。所以 NB 源的行点「获取」仍然回到 `NBStoreClient` 取包 ——
/// 「榜单用 Apple、取包用 NB」是这套数据关系下的正确分工，不是拼凑。
enum NBStoreRankClient {

    static let logTag = "[NB榜单]"

    /// 榜单类型（对应 Apple RSS 的三个路径段）.
    enum Rank: String, CaseIterable, Identifiable {
        /// 免费应用榜（`topfreeapplications`）.
        case freeApps
        /// 付费应用榜（`toppaidapplications`）.
        case paidApps
        /// 免费游戏榜（`topfreeapplications` + `genre=6014`）.
        case freeGames
        /// 付费游戏榜（`toppaidapplications` + `genre=6014`）.
        case paidGames

        var id: String { rawValue }

        var title: String {
            switch self {
            case .freeApps: return "免费"
            case .paidApps: return "付费"
            case .freeGames: return "免费游戏"
            case .paidGames: return "付费游戏"
            }
        }

        /// RSS 路径段（`topfreeapplications` / `toppaidapplications`）.
        fileprivate var rssSegment: String {
            switch self {
            case .freeApps, .freeGames: return "topfreeapplications"
            case .paidApps, .paidGames: return "toppaidapplications"
            }
        }

        /// 游戏类目限定（Apple 的 `genre=6014` 就是「游戏」）.
        fileprivate var genreSuffix: String {
            switch self {
            case .freeGames, .paidGames: return "/genre=6014"
            case .freeApps, .paidApps: return ""
            }
        }
    }

    /// 榜单里的一条（就是 Apple RSS 的一个 `entry`）.
    ///
    /// 字段名对齐 `I4PCStoreClient.I4App` 里那几个**同名**的（`name` / `itemId` /
    /// `icon` / `bundleId`），好让列表行能复用同一套渲染；其余是 RSS 独有的补充信息.
    struct RankItem: Identifiable, Hashable {
        /// App Store trackId（RSS 的 `id.attributes.im:id`）—— 也是 NB 取包要的 `appID`.
        var trackID: String
        var name: String
        var bundleID: String?
        var icon: String?
        /// 开发者名（RSS 的 `im:artist.label`）.
        var artist: String?
        /// 分类（RSS 的 `category.attributes.label`）.
        var category: String?
        /// 价格文案（`im:price.label`，免费榜是「获取」/ 付费榜是「¥ xx」）.
        var priceText: String?
        /// 排行榜名次（1 起）.
        var rank: Int
        /// 简介（`summary.label`，RSS 给的是短简介）.
        var summary: String?

        var id: String { trackID }

        /// 给列表行用的副标题（开发者 + 分类）.
        var subtitle: String {
            var parts: [String] = []
            if let a = artist, !a.isEmpty { parts.append(a) }
            if let c = category, !c.isEmpty { parts.append(c) }
            return parts.joined(separator: " · ")
        }
    }

    enum StoreError: Error, LocalizedError {
        case badURL
        case http(Int)
        case decode(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "榜单地址无效"
            case .http(let c): return "榜单请求失败（HTTP \(c)）"
            case .decode(let m): return "榜单解析失败：\(m)"
            case .network(let m): return "网络错误：\(m)"
            }
        }
    }

    // MARK: - 请求

    /// Apple RSS 的 CDN 直连（**HTTPS**，不在 ATS 例外里也不受影响）.
    private static let host = "https://itunes.apple.com"

    /// 榜单限时：太短会把慢网直接判失败，太长又让用户干等.
    private static let timeout: TimeInterval = 15

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 拉一个榜单.
    ///
    /// - Parameters:
    ///   - rank: 榜单类型（免费/付费 × 应用/游戏）.
    ///   - country: 区域码（`cn` / `us`），与 `NBStoreClient.package` 的 `country` 同一口径.
    ///   - limit: 条数（Apple 上限 200，这里默认 50）.
    static func fetch(rank: Rank,
                      country: String,
                      limit: Int = 50) async throws -> [RankItem] {
        let cc = normalizeCountry(country)
        let capped = max(1, min(200, limit))
        let path = "/\(cc)/rss/\(rank.rssSegment)/limit=\(capped)\(rank.genreSuffix)/json"
        guard let url = URL(string: host + path) else { throw StoreError.badURL }

        var req = URLRequest(url: url)
        // Apple 的 RSS 对 UA 不敏感，但带一个 App Store 的 UA 更稳（少一层反爬）.
        req.setValue("com.apple.appstored/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        LoginLogger.shared.log("\(logTag) → GET \(url.absoluteString)", category: .appStore)

        let data: Data
        do {
            let (d, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw StoreError.http(http.statusCode)
            }
            data = d
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.network(error.localizedDescription)
        }

        let items = try parse(data)
        LoginLogger.shared.log("\(logTag) ✓ \(rank.title) \(cc.uppercased()) · \(items.count) 条",
                               category: .appStore)
        return items
    }

    /// 关键词搜索.
    ///
    /// ## 这一条为什么必须有
    /// 用户反馈「**美区一个搜索不到、国区还那么点软件**」——
    /// 根因是 NB 源原来借的是**爱思**的搜索接口，而爱思是**中国区商店**，
    /// 它的库里根本没有美区应用（美区自然搜不到），国区也只覆盖它自己收录的那点量。
    ///
    /// 换成 Apple 官方的 `search` 接口后，**区域跟着 `country` 走**：
    /// 美区能搜到美区商店的应用，国区能搜到国区商店的**全部**上架应用 ——
    /// 这才是「搜得到」的正确来源.
    static func search(keyword: String,
                       country: String,
                       limit: Int = 50) async throws -> [RankItem] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        let cc = normalizeCountry(country)
        let capped = max(1, min(200, limit))

        var comps = URLComponents(string: host + "/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: kw),
            URLQueryItem(name: "country", value: cc),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: String(capped)),
        ]
        guard let url = comps?.url else { throw StoreError.badURL }

        var req = URLRequest(url: url)
        req.setValue("com.apple.appstored/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        LoginLogger.shared.log("\(logTag) → GET /search term=\(kw) country=\(cc)", category: .appStore)

        let data: Data
        do {
            let (d, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw StoreError.http(http.statusCode)
            }
            data = d
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.network(error.localizedDescription)
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw StoreError.decode("响应里没有 results 数组")
        }
        // 搜索接口的字段是平的（不是 RSS 的嵌套 label 结构），单独映射.
        let items = results.enumerated().compactMap { index, obj -> RankItem? in
            guard let trackID = Self.string(obj["trackId"]), !trackID.isEmpty else { return nil }
            return RankItem(
                trackID: trackID,
                name: Self.string(obj["trackName"]) ?? "App \(trackID)",
                bundleID: Self.string(obj["bundleId"]),
                icon: Self.string(obj["artworkUrl100"]) ?? Self.string(obj["artworkUrl512"]),
                artist: Self.string(obj["artistName"]),
                category: (obj["primaryGenreName"] as? String),
                priceText: Self.string(obj["formattedPrice"]),
                rank: index + 1,
                summary: nil
            )
        }
        LoginLogger.shared.log("\(logTag) ✓ 搜索「\(kw)」\(cc.uppercased()) · \(items.count) 条",
                               category: .appStore)
        return items
    }

    // MARK: - 解析

    /// 解析 RSS JSON.
    ///
    /// Apple 的 RSS 是「字段 → `{label: …}`」的嵌套结构（历史遗留），
    /// 例如 `"im:name": {"label": "微信"}`，`id` 还要再下一层 `attributes.im:id`.
    /// 这里逐层取，取不到就留空 —— **不编造**.
    private static func parse(_ data: Data) throws -> [RankItem] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let feed = root["feed"] as? [String: Any] else {
            throw StoreError.decode("响应里没有 feed")
        }
        // `entry` 只有一条时 Apple 给的是**字典**而不是数组，这里统一成数组.
        let rawEntries: [[String: Any]]
        if let arr = feed["entry"] as? [[String: Any]] {
            rawEntries = arr
        } else if let one = feed["entry"] as? [String: Any] {
            rawEntries = [one]
        } else {
            return []
        }

        return rawEntries.enumerated().compactMap { index, e -> RankItem? in
            guard let trackID = Self.nestedLabel(e, ["id", "attributes", "im:id"]),
                  !trackID.isEmpty else { return nil }
            let categoryLabel = Self.nestedLabel(e, ["category", "attributes", "label"])
            return RankItem(
                trackID: trackID,
                name: Self.nestedLabel(e, ["im:name", "label"]) ?? "App \(trackID)",
                bundleID: Self.nestedLabel(e, ["id", "attributes", "im:bundleId"]),
                icon: Self.imageURL(e),
                artist: Self.nestedLabel(e, ["im:artist", "label"]),
                category: categoryLabel,
                priceText: Self.nestedLabel(e, ["im:price", "label"]),
                rank: index + 1,
                summary: Self.nestedLabel(e, ["summary", "label"])
            )
        }
    }

    /// 从 `im:image` 数组里取**分辨率最高**的那张.
    ///
    /// Apple 给三档（`53` / `75` / `100` 边长），数组**按分辨率升序**，
    /// 所以取 `last` 通常就是最大那张；但不保证，仍按 attributes 里的 height 排序兜底.
    private static func imageURL(_ entry: [String: Any]) -> String? {
        guard let images = entry["im:image"] as? [[String: Any]] else {
            // 只有一张时同样是字典.
            if let one = entry["im:image"] as? [String: Any] {
                return nestedLabel(one, ["label"])
            }
            return nil
        }
        let sorted = images.sorted { lhs, rhs in
            (Self.intValue(lhs["attributes"], "height") ?? 0) < (Self.intValue(rhs["attributes"], "height") ?? 0)
        }
        return sorted.last.flatMap { nestedLabel($0, ["label"]) }
    }

    /// 按路径逐层下钻取 `label` 字符串.
    private static func nestedLabel(_ dict: [String: Any], _ path: [String]) -> String? {
        var current: Any = dict
        for key in path {
            guard let d = current as? [String: Any], let next = d[key] else { return nil }
            current = next
        }
        if let s = current as? String { return s.isEmpty ? nil : s }
        if let n = current as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intValue(_ dict: Any?, _ key: String) -> Int? {
        guard let d = dict as? [String: Any] else { return nil }
        if let n = d[key] as? NSNumber { return n.intValue }
        if let s = d[key] as? String { return Int(s) }
        return nil
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// 区域码规范化：只认两位小写字母，其余一律回落 `cn`.
    ///
    /// NB 的 `country` 传的是字符串 `cn` / `us`；而 UI 的持久化值历史上出现过 `hk`.
    /// 这里把大小写统一，并挡住空值/异常值（URL 里带个奇怪的国家码会让 Apple 回 404）.
    private static func normalizeCountry(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count == 2, s.allSatisfy({ $0.isLetter }) else { return "cn" }
        return s
    }

    // MARK: - v0.3.545 详情页元数据（照搬 NB 助手的 DXSTiTunesAPI）

    /// 详情页要显示的全部元数据 —— 字段**逐条对齐 NB 助手**的 `DXSTDetailModel`。
    ///
    /// ## 这份清单从哪来（不是自己想的）
    ///
    /// 反编译 NB 助手（`XNZS`）拿到的 `DXSTDetailModel` 属性表（Swift 反射串段，原序）：
    ///
    /// ```
    /// averageUserRatingForCurrentVersion  subtitle        wrapperType
    /// currency                            oldVersion      trackId
    /// version                             descriptionStr  trackName
    /// price                               artistId        artistName
    /// genres                              userRatingCount
    /// ```
    ///
    /// 配套的 `artworkUrl60/100/512`、`screenshotUrls`、`sellerName`、`releaseNotes`、
    /// `minimumOSVersion`、`fileSizeBytes`、`formattedPrice` 等也都在同一段里
    /// —— 而且这些键名与 **Apple 官方 lookup 的响应的键名逐字一致**。
    ///
    /// ⇒ 结论：NB 助手的详情页就是拿 `itunes.apple.com/lookup` 的响应对进这个模型。
    /// 我们照做即可（这是「搬过来」最直白的形态）。
    struct AppDetail: Hashable {
        var trackID: String
        var name: String
        var bundleID: String?
        /// 512×512 图标（列表用 100，详情页用 512）
        var artwork512: String?
        var artwork100: String?
        /// 开发者（`sellerName`，公司名；`artistName` 是作者名，两个都留）
        var sellerName: String?
        var artistName: String?
        /// 版本号（`version`）与发布日期（`currentVersionReleaseDate`）
        var version: String?
        var releaseDate: String?
        /// 「新功能」文案（`releaseNotes`）
        var releaseNotes: String?
        /// 简介（Apple 的键是 `description`，NB 模型里叫 `descriptionStr`）
        var descriptionText: String?
        /// 副标题（`subtitle`）
        var subtitle: String?
        /// 价格：`formattedPrice` 是本地化文案（「免费」/「¥ 30.00」），`price` 是数值
        var formattedPrice: String?
        /// 评分（`averageUserRating`）与评分人数（`userRatingCount`）
        var averageRating: Double?
        var ratingCount: Int?
        /// 包大小（字节，`fileSizeBytes`）
        var fileSizeBytes: Int64?
        /// 最低系统（`minimumOSVersion`）
        var minimumOSVersion: String?
        /// 分类（`genres` 数组 + `primaryGenreName`）
        var genres: [String]
        /// **截图（预览图的来源）** —— `screenshotUrls` 是 iPhone 的，
        /// `ipadScreenshotUrls` / `appletvScreenshotUrls` 是另外两端的。
        /// NB 助手的 `DXSTDetailADView` 就是横向翻页显示这一组。
        var screenshotURLs: [String]

        /// 包大小的可读文案（与 Apple 在 App Store 里显示的口径一致：十进制 MB/GB）
        var sizeText: String? {
            guard let b = fileSizeBytes, b > 0 else { return nil }
            let mb = Double(b) / 1_000_000
            if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
            if mb >= 1 { return String(format: "%.1f MB", mb) }
            return String(format: "%.0f KB", Double(b) / 1000)
        }

        /// 评分文案（一位小数）
        var ratingText: String? {
            guard let r = averageRating, r > 0 else { return nil }
            return String(format: "%.1f", r)
        }
    }

    /// 用 `itunes.apple.com/lookup` 取一个 App 的**完整详情**.
    ///
    /// ## 与 `fetch` / `search` 的关系
    ///
    /// 那两条给的是**列表形态**（RSS / search 的扁平字段）；这一条给的是**详情形态**
    /// （lookup 的完整字段，含截图与简介）。两者刻意分开：列表 50 条不需要
    /// 每条都带 12 张截图，那样响应体要大一两个数量级。
    ///
    /// ## 参数口径
    /// - `trackID`：App Store 数字 ID（= NB 的 `appID`）。
    /// - `country`：区域 —— lookup **必须带**，否则拿到的价格/上架状态是美区的。
    /// - `entity=software`：只要 iOS 应用（不加会混进 Mac / iPad 版本）。
    static func detail(trackID: String, country: String) async throws -> AppDetail? {
        let tid = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tid.isEmpty else { return nil }
        let cc = normalizeCountry(country)

        var comps = URLComponents(string: host + "/lookup")
        comps?.queryItems = [
            URLQueryItem(name: "id", value: tid),
            URLQueryItem(name: "country", value: cc),
            URLQueryItem(name: "entity", value: "software"),
        ]
        guard let url = comps?.url else { throw StoreError.badURL }

        var req = URLRequest(url: url)
        req.setValue("com.apple.appstored/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        LoginLogger.shared.log("\(logTag) → GET /lookup id=\(tid) country=\(cc)", category: .appStore)

        let data: Data
        do {
            let (d, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw StoreError.http(http.statusCode)
            }
            data = d
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.network(error.localizedDescription)
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw StoreError.decode("lookup 响应里没有 results 数组")
        }
        guard let obj = results.first else {
            LoginLogger.shared.log("\(logTag) ○ lookup 无结果（id=\(tid) cc=\(cc)）", category: .appStore)
            return nil
        }

        let detail = AppDetail(
            trackID: Self.string(obj["trackId"]) ?? tid,
            name: Self.string(obj["trackName"]) ?? "App \(tid)",
            bundleID: Self.string(obj["bundleId"]),
            artwork512: Self.string(obj["artworkUrl512"]),
            artwork100: Self.string(obj["artworkUrl100"]) ?? Self.string(obj["artworkUrl60"]),
            sellerName: Self.string(obj["sellerName"]),
            artistName: Self.string(obj["artistName"]),
            version: Self.string(obj["version"]),
            releaseDate: Self.string(obj["currentVersionReleaseDate"]) ?? Self.string(obj["releaseDate"]),
            releaseNotes: Self.string(obj["releaseNotes"]),
            descriptionText: Self.string(obj["description"]),
            subtitle: Self.string(obj["subtitle"]),
            formattedPrice: Self.string(obj["formattedPrice"]),
            averageRating: (obj["averageUserRating"] as? NSNumber)?.doubleValue,
            ratingCount: (obj["userRatingCount"] as? NSNumber)?.intValue,
            fileSizeBytes: (obj["fileSizeBytes"] as? NSNumber)?.int64Value
                ?? Int64(Self.string(obj["fileSizeBytes"]) ?? ""),
            minimumOSVersion: Self.string(obj["minimumOsVersion"]),
            genres: (obj["genres"] as? [String]) ?? [],
            screenshotURLs: (obj["screenshotUrls"] as? [String]) ?? []
        )
        LoginLogger.shared.log("\(logTag) ✓ lookup「\(detail.name)」"
                               + "截图 \(detail.screenshotURLs.count) 张"
                               + (detail.descriptionText == nil ? " · 无简介" : ""),
                               category: .appStore)
        return detail
    }
}
