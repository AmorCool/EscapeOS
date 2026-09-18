import Foundation

/// v0.3.295：AppStore 商店服务
/// 全部走 Apple 公开接口（无需登录、无需认证）：
///   · 搜索/详情：https://itunes.apple.com/search、/lookup
///   · 榜单：    https://itunes.apple.com/{cc}/rss/{kind}/limit={n}/genre={id}/json
/// 安装：交给系统 App Store（itms-apps://），或由用户提供 manifest plist 走
///       itms-services OTA 通道（与爱思助手同一条系统机制，见 installViaOTA）。
enum AppStoreService {

    // MARK: - 区域（App Store 商店的国家/地区）

    /// 「自动」：跟随当前 Apple ID 的账号区域（v0.3.363）
    static let autoRegion = "auto"

    private static let shopRegionKey = "AppStore.ShopRegion"

    /// 用户选择区的**原始**存储值：具体国家码（小写），或特殊值 `"auto"`（跟随账号）。
    static var rawShopRegion: String {
        get { UserDefaults.standard.string(forKey: shopRegionKey) ?? "cn" }
        set { UserDefaults.standard.set(newValue, forKey: shopRegionKey) }
    }

    /// 传给 Apple 接口的**具体**区域码；默认 `cn`（国区）。
    ///
    /// 榜单 RSS、搜索、详情 lookup、版本历史全部走这个区域 —— 不同区域的
    /// 商品池完全不同（美区没有国区应用，反之亦然）。
    ///
    /// ⚠️ `"auto"` 只存在于 `rawShopRegion`，**绝不**从这里漏出：读到 `"auto"` 时
    /// 立刻解析成账号区（未登录/无账号 → 兜底 `cn`），保证所有消费点拿到的都是具体国家码。
    static var countryCode: String {
        get { resolveRegion(rawShopRegion) }
        set { rawShopRegion = newValue }
    }

    /// 把原始选择解析成**具体**国家码（`"auto"` → 账号区；空/未知 → `cn`）。
    static func resolveRegion(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == autoRegion { return accountStorefrontCode() ?? "cn" }
        return value.isEmpty ? "cn" : value
    }

    /// 当前账号所在区的国家码（小写）；未登录 / storefront 认不出时 nil。
    ///
    /// 账号的 `fullStoreFront`（如 `143441-19,34`）第一段就是 storefront id，
    /// 经 `StoreRegions` 反查得到国家码。
    static func accountStorefrontCode() -> String? {
        guard let account = AppStoreDownloadStore.shared.selectedAccount else { return nil }
        let storefront = (account.fullStoreFront?.isEmpty == false)
            ? (account.fullStoreFront ?? account.store) : account.store
        let head = storefront.split(separator: "-").first.map(String.init) ?? ""
        guard !head.isEmpty else { return nil }
        return StoreRegions.code(for: head)?.lowercased()
    }

    /// 「自动」选项的文案：解析出的账号区**不在常用列表**里才拼 `"自动 · BR"`，
    /// 在列表里（或未登录兜底 `cn`）就只显示 `"自动"`。
    static var autoDisplay: String {
        let code = resolveRegion(autoRegion)
        if Region.allCases.contains(where: { $0.rawValue == code }) { return "自动" }
        return "自动 · \(code.uppercased())"
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
    ///
    /// - Parameter email: 传入则同时记住「已跟随过这个账号」，供进入商店时判断是否需要再跟随
    @discardableResult
    static func adoptAccountRegion(storefront: String, email: String? = nil) -> String? {
        guard let code = Configuration.countryCode(for: storefront)?.lowercased() else { return nil }
        // 用户显式选了「自动」时保持不动 —— 它本来就跟随账号，不该被覆盖成具体区
        if rawShopRegion != autoRegion { countryCode = code }
        if let email { UserDefaults.standard.set(email, forKey: followedEmailKey) }
        return code
    }

    /// 已经「跟随过」的账号（email）
    private static let followedEmailKey = "AppStore.RegionFollowedEmail"

    /// v0.3.328：进入商店页时用 —— **只在当前账号与上次跟随的账号不同时**才改区域，
    /// 这样用户手动挑的区域不会被每次进页面时覆盖。
    @discardableResult
    static func followAccountRegionIfNeeded(email: String, storefront: String) -> String? {
        guard email != UserDefaults.standard.string(forKey: followedEmailKey) else { return nil }
        return adoptAccountRegion(storefront: storefront, email: email)
    }

    /// 传给 Apple 接口的区域（未指定时用当前选择）。
    /// 兜底再解析一次，保证调用方万一传进 `"auto"` 也不会漏进 URL。
    private static func resolved(_ country: String?) -> String {
        guard let c = country, !c.isEmpty else { return countryCode }
        return resolveRegion(c)
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

    // MARK: - v0.3.368：商品页 HTML（详情页「App 隐私」与历史版本页共用）

    /// 商品页 HTML 抓取 + 缓存。
    ///
    /// 详情页（App 隐私）与版本历史页解析的是**同一张** `apps.apple.com/<cc>/app/id<id>`
    /// 商品页 —— SSR 时 `privacyDetail` 与 `versionHistory` 一起塞在
    /// `<script id="serialized-server-data">` 的 JSON 里。各抓各的 = 一次浏览打两发
    /// 1MB 级页面，所以这里按「区域 + appId」缓存整段 HTML，同一份只下一次。
    ///
    /// 并发去重：同一 key 的在途请求只发一次，后来者等同一份结果 ——
    /// 「刚进详情页就点历史版本」这种时序不会再各打一发。
    ///
    /// v0.3.369 —— **区域健壮**：`apps.apple.com` 会按**出口 IP** 做地理重定向，
    /// 从中国大陆出口访问 `/us/app/idX`、`/app/idX` 一律 302 到 `/cn/iphone/today`
    /// （根本不是应用页；`Cookie: geo=US` / `site=US` 都压不住）。所以先按请求区域抓，
    /// 拿到的不是该应用的详情页就**依次回落「账号区」「`cn`」再抓**；都拿不到才算真没有。
    /// 账号区优先于 cn：Apple 按出口 IP 重定向，账号区通常就是出口区。
    ///
    ///   实测（大陆出口 IP）：
    ///   · `/us/app/id6448311069`（ChatGPT，US 独占）→ 302 `/cn/iphone/today`；
    ///     回落 cn 后仍是首页 → **US 独占应用取不到，这不是我们的解析问题**；
    ///   · `/us/app/id414478124`（微信，CN 有）→ 重定向，回落 cn 拿到应用页，`privacyDetail=True`。
    ///
    ///   隐私分组数量**随应用不同**（微信只有 1 组 `LINKED_TO_YOU`，淘宝 3 组），
    ///   不要假设一定是 3 组。
    ///
    /// 只缓存**确实拿到该应用详情页**的结果；拿不到详情页（重定向到 `/xx/iphone/today`
    /// 的 200 降级页、HTTP/网络失败）一律不写缓存，下次进入会重新抓 —— 否则「取不到 =
    /// 空隐私」会被当成该区域的成功结果钉住，表现为第一次进详情看不到、刷新后才有。
    ///
    /// 单份 HTML 是 0.6–1.6MB，所以除了 TTL 还给个条数上限：写入前清掉过期项，
    /// 仍超上限就丢最旧的一条 —— 避免连续浏览多个应用把内存堆起来。
    private static let htmlCacheTTL: TimeInterval = 10 * 60
    private static let htmlCacheLimit = 3

    /// 被出口 IP 地理重定向时的回落区域（v0.3.369）。
    ///
    /// 从**中国大陆出口 IP** 访问 `apps.apple.com` 只会拿到国区页面 ——
    /// 请求区与账号区都抓不到时最后回落 `cn`；CN 上架的应用因此能拿到 `privacyDetail`。
    private static let productFallbackRegion = "cn"

    /// 缓存值：整段 HTML + **实际服务这张页面的区域**。
    ///
    /// 正常时它可能不等于请求区域：被地理重定向后回落了账号区 / `cn`，或 Apple 直接把
    /// `/us/app/idX` 302 成 `/cn/app/idX`。记下来，命中缓存时能说清「数据为何来自别的区」。
    /// 降级页面（都没拿到应用页）没有可用区域，就记请求区域。
    private struct CachedProductPage {
        let html: String
        let served: String
        let at: Date
    }

    /// 抓取结果：HTML + 实际服务区域 + 是否为「该应用的详情页」。
    private struct ProductPage {
        let html: String
        let served: String
        let isAppPage: Bool
    }

    /// `productPage(appId:country:)` 在锁内算出的查找结果：命中缓存 / 命中在飞任务 / 新建在飞任务。
    /// 拆成枚举是为了让 `htmlLock` 只覆盖**同步**的「查表 + 登记」，`await` 一律在锁外发生。
    private enum ProductPageLookup {
        case cached(CachedProductPage)
        case inflight(Task<ProductPage, Error>)
        case started(Task<ProductPage, Error>)
    }

    private static let htmlLock = NSLock()
    /// nonisolated(unsafe)：`enum` 的静态存储属性无法用锁做隔离标注；
    /// `htmlCache` / `htmlInflight` 的**全部**读写都在 `htmlLock.withLock` 作用域内
    /// （无一处跨 `await` 持锁），实际无竞争 —— 与 `BinaryModuleRunner` 的
    /// `cachedBinaryModuleHandle` 同一套「锁保护的存取器」约定。
    nonisolated(unsafe) private static var htmlCache: [String: CachedProductPage] = [:]
    nonisolated(unsafe) private static var htmlInflight: [String: Task<ProductPage, Error>] = [:]

    private static func productHTML(appId: String, country: String?) async throws -> String {
        let page = try await productPage(appId: appId, country: country)
        return page.html
    }

    private static func productPage(appId: String, country: String?) async throws -> ProductPage {
        let cc = resolved(country)
        let key = "\(cc)|\(appId)"

        // 锁内只做「查缓存 / 查在飞任务 / 登记新任务」这三件同步事；await 一律在锁外。
        // （Swift 6：NSLock.lock()/unlock() 在异步上下文不可用，改用作用域式的 withLock；
        //   这里的锁本来就没有跨 await 持有，语义完全不变。）
        let lookup: ProductPageLookup = htmlLock.withLock {
            if let hit = htmlCache[key], Date().timeIntervalSince(hit.at) < htmlCacheTTL {
                return .cached(hit)
            }
            if let running = htmlInflight[key] {
                return .inflight(running)
            }
            let task = Task { try await loadProductPage(appId: appId, requested: cc) }
            htmlInflight[key] = task
            return .started(task)
        }

        switch lookup {
        case .cached(let hit):
            // 命中「回落过」的条目：说明请求区域在这台设备上必然被重定向，
            // 直接复用实际区域那份 HTML，不再撞一次重定向（也解释清了数据为何来自别的区）。
            if hit.served != cc {
                LoginLogger.shared.log("商品页 HTML：\(cc)/\(appId) 命中缓存（实际服务区域 \(hit.served)，地理重定向后回落）",
                                       category: .appStore)
            }
            return ProductPage(html: hit.html, served: hit.served, isAppPage: true)

        case .inflight(let running):
            return try await running.value

        case .started(let task):
            do {
                let page = try await task.value
                htmlLock.withLock {
                    if page.isAppPage {
                        let now = Date()
                        htmlCache = htmlCache.filter { now.timeIntervalSince($0.value.at) < htmlCacheTTL }
                        if htmlCache.count >= htmlCacheLimit,
                           let oldest = htmlCache.min(by: { $0.value.at < $1.value.at })?.key {
                            htmlCache[oldest] = nil
                        }
                        htmlCache[key] = CachedProductPage(html: page.html, served: page.served, at: now)
                    }
                    htmlInflight[key] = nil
                }
                // 不是详情页就不落缓存，下次进入重新抓（本次仍把页面交回去解析，行为不变）。
                if !page.isAppPage {
                    LoginLogger.shared.log("商品页 HTML：\(cc)/\(appId) 未取到详情页，本次结果不缓存，下次重试",
                                           category: .appStore)
                }
                return page
            } catch {
                htmlLock.withLock {
                    htmlInflight[key] = nil
                }
                throw error
            }
        }
    }

    /// 区域健壮抓取：按 `requested` → 账号区 → `cn` 的次序各试一次，返回第一个确实是
    /// `id<appId>` 详情页的结果（含实际服务区域）。
    ///
    /// 判定「是不是该应用的详情页」看 `URLSession` 跟随重定向后的最终 URL（缺失时退到
    /// 页面自指的 canonical 链接）：`/cn/app/…/id414478124` 这种才算，落到
    /// `/cn/iphone/today` 就是被地理重定向了。
    ///
    /// 账号区排第二是因为 Apple 按**出口 IP** 重定向：请求区与出口区不一致时只会拿到
    /// `/xx/iphone/today` 降级页，而账号区通常就是出口区，先试它才能第一次就拿到详情页。
    ///
    /// 三处都不是应用页时，原因（重定向到哪 / HTTP 几 / 回落失败）全部写进商店日志；
    /// 手头若还有一份 200 页面就交回去（`isAppPage=false`，不落缓存），否则抛最后一次的错误。
    private static func loadProductPage(appId: String, requested: String) async throws -> ProductPage {
        var regions = [requested]
        if let account = accountStorefrontCode(), !regions.contains(account) { regions.append(account) }
        if !regions.contains(productFallbackRegion) { regions.append(productFallbackRegion) }
        var carriedHTML: String?
        var carriedError: Error?
        var reasons: [String] = []

        for region in regions {
            do {
                let attempt = try await loadProductHTML(appId: appId, country: region)
                carriedHTML = attempt.html
                if let served = appPageRegion(finalURL: attempt.finalURL, html: attempt.html, appId: appId) {
                    if served != requested {
                        LoginLogger.shared.log("商品页 HTML：请求 \(requested)/\(appId) 被地理重定向到 \(served)，已按 \(served) 页面解析",
                                               category: .appStore)
                    }
                    LoginLogger.shared.log("商品页 HTML：\(served)/\(appId) 取到 \(attempt.html.count) 字（详情页与版本历史共用）",
                                           category: .appStore)
                    return ProductPage(html: attempt.html, served: served, isAppPage: true)
                }
                let landing = attempt.finalURL?.absoluteString ?? "无最终 URL"
                reasons.append("\(region)：HTTP 200 但落到 \(landing)（不是该应用的详情页）")
            } catch {
                carriedError = error
                reasons.append("\(region)：\(error.localizedDescription)")
            }
        }

        LoginLogger.shared.log("商品页 HTML：\(requested)/\(appId) 取不到应用页 —— \(reasons.joined(separator: "；"))",
                               category: .appStore)
        if let html = carriedHTML {
            return ProductPage(html: html, served: requested, isAppPage: false)
        }
        throw carriedError ?? AppStoreError.badURL
    }

    /// 真正发请求：必须用**桌面 UA**，否则手机 UA 会被 301 到 `itms-appss://` 协议链接。
    ///
    /// 跟随重定向（默认行为），并把**最终 URL** 交回去 —— 判断是否被地理重定向要用它。
    private static func loadProductHTML(appId: String, country: String) async throws -> (html: String, finalURL: URL?) {
        guard let url = URL(string: "https://apps.apple.com/\(country)/app/id\(appId)") else {
            throw AppStoreError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                     + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppStoreError.http(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw AppStoreError.decode }
        return (html, resp.url)
    }

    /// 这张页面**确实是 `id<appId>` 的详情页**时返回其区域码（`cn` / `us` …），否则 nil。
    ///
    /// 首选 `URLSession` 的最终 URL（`/cn/app/微信/id414478124`）；个别情况下拿不到
    /// （非 HTTP 响应）就退到页面自指的 `canonical` 链接 —— 被重定向到首页时 canonical
    /// 是 `/cn/iphone/today`，同样不会误判。
    private static func appPageRegion(finalURL: URL?, html: String, appId: String) -> String? {
        if let final = finalURL, let region = appPageRegion(in: final.absoluteString, appId: appId) {
            return region
        }
        if let canonical = canonicalHref(in: html),
           let region = appPageRegion(in: canonical, appId: appId) {
            return region
        }
        return nil
    }

    /// 从 `/cn/app/…/id414478124` 这类链接里取出区域码；不是该应用的详情页则 nil。
    private static func appPageRegion(in urlString: String, appId: String) -> String? {
        guard urlString.contains("/app/"), urlString.contains("id\(appId)"),
              let app = urlString.range(of: "/app/") else { return nil }
        let before = urlString[urlString.startIndex..<app.lowerBound]
        guard let slash = before.lastIndex(of: "/") else { return nil }
        let code = before[before.index(after: slash)...].lowercased()
        return code.isEmpty ? nil : code
    }

    /// `<link rel="canonical" href="…">` —— 商品页自指链接，用来兜底确认页面归属。
    private static func canonicalHref(in html: String) -> String? {
        guard let marker = html.range(of: "rel=\"canonical\"") else { return nil }
        let tail = html[marker.upperBound...]
        guard let open = tail.range(of: "href=\""),
              let close = tail[open.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(tail[open.upperBound..<close])
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
    /// 该页面**无需登录、无需认证**。HTML 由 `productHTML` 统一抓取/缓存，
    /// 与详情页的「App 隐私」共用同一份（v0.3.368）。
    static func versionHistory(appId: String, country: String? = nil) async throws -> [AppStoreVersion] {
        parseVersionHistory(html: try await productHTML(appId: appId, country: country))
    }

    // MARK: - v0.3.335：历史版本（账号通道，移植 Asspp）

    /// 取某应用的**全量版本身份**（数字 externalVersionId，旧 → 新）。
    ///
    /// 走 App Store 下载协议（`VersionFinder`，Asspp `AppPackageArchive` 同款）：
    /// `volumeStoreDownloadProduct` 响应里 `metadata.softwareVersionExternalIdentifiers`
    /// 就是该应用全部历史版本的 ID 列表。**需要已登录的 Apple ID**（会带 DSID + cookie）。
    ///
    /// 这是唯一在**任何区域**都能拿到完整版本列表的通道 —— 商品页 HTML 那条
    /// 只有部分区域/部分应用内嵌了 `versionHistory` shelf，所以非国区经常是空的。
    ///
    /// v0.3.364：**不带 `externalVersionId` 时 Apple 对不少应用回静默空包**（HTTP 200 +
    /// 空 songList + 无错误码）—— 这不是「该账号没买过」（真机实测同一账号 `buyProduct`
    /// 回的是 5002 LicenseAlreadyExists），所以这里用版本目录的旧版 ID 当候选重打一次。
    ///
    /// v0.3.365：`allowRotate` 与 `storeVersionMetadata` 共用**整次加载唯一的一次重登额度**
    /// （每次 rotate 都是一次完整 SAP 登录，一次页面加载重登两次等于把登录链路再推回风暴）。
    /// 身份通道价值最高（一次拿全量版本身份），所以视图把这个额度**优先分配给它**，
    /// 后面的 metadata 批次一律 `allowRotate: false`。
    static func storeVersionIdentifiers(bundleId: String, appId: String,
                                       email: String,
                                       allowRotate: Bool = true) async throws -> [String] {
        try await StoreAccountSession.withAccount(email: email) { account in
            do {
                return try await VersionFinder.list(account: &account, bundleIdentifier: bundleId)
            } catch ApplePackageError.passwordTokenExpired where allowRotate {
                account = try await AppleIDSignInService.rotate(email: email, failedAccount: account)
                return try await VersionFinder.list(account: &account, bundleIdentifier: bundleId)
            } catch ApplePackageError.emptyPackage {
                let ids = await versionIdentifiersWithCandidates(account: &account, bundleId: bundleId,
                                                                 appId: appId)
                guard !ids.isEmpty else { throw ApplePackageError.emptyPackage }
                return ids
            }
        }
    }

    /// v0.3.364：静默空包时，用「版本目录」里的 `externalVersionId` 逐个重打 volumeStore。
    ///
    /// 与 v0.3.361 下载链路同一批真机证据：ChatGPT 这类应用**只在 body 带
    /// `externalVersionId` 时才出包**，且最新两个 ID 会被 Apple 拒、更旧的可以下 ——
    /// 所以拿目录里最新 6 个试（目录是「最新在前」，前两槽撞空，窗口内能命中）。
    /// 命中后 Apple 回的是该账号的**全量** `softwareVersionExternalIdentifiers`。
    private static func versionIdentifiersWithCandidates(account: inout AppStoreAccount,
                                                         bundleId: String,
                                                         appId: String) async -> [String] {
        guard let history = try? await versionHistoryFromCatalog(appId: appId) else {
            LoginLogger.shared.log("版本历史账号通道：静默空包，且版本目录不可用（无候选）", category: .appStore)
            return []
        }
        var seen = Set<String>()
        let candidates = history.compactMap { $0.externalVersionID }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(6)
        for candidate in candidates {
            do {
                let ids = try await VersionFinder.list(account: &account, bundleIdentifier: bundleId,
                                                       externalVersionID: candidate)
                LoginLogger.shared.log("版本历史账号通道：用候选 externalVersionId=\(candidate) 取到 \(ids.count) 个版本",
                                       category: .appStore)
                return ids
            } catch {
                LoginLogger.shared.log("版本历史账号通道：候选 externalVersionId=\(candidate) 未出包（\(error.localizedDescription)）",
                                       category: .appStore)
            }
        }
        LoginLogger.shared.log("版本历史账号通道：\(candidates.count) 个候选版本全部未出包", category: .appStore)
        return []
    }

    /// 取某版本身份对应的版本号与发布日期（`VersionLookup`，同 Asspp）。
    ///
    /// v0.3.365：`allowRotate` 是**整次加载只放行一次的重登闸门**（对齐
    /// `AppStoreLocalInstallService.downloadInformation` 的 `refreshed` 写法）。
    /// 历史版本页一次加载会连着取几十个 metadata，若每条的 2034 都各自 rotate，
    /// 一次「加载更多」最坏就是 20 次重登（审计实测结论）—— 闸门用掉后
    /// `where allowRotate` 不再匹配，错误原样上抛，由调用方停手。
    static func storeVersionMetadata(item: AppStoreItem,
                                     versionID: String,
                                     email: String,
                                     allowRotate: Bool = true) async throws -> (version: String, date: Date) {
        let software = try AppStoreLocalInstallService.makeSoftware(item)
        return try await StoreAccountSession.withAccount(email: email) { account in
            do {
                let metadata = try await VersionLookup.getVersionMetadata(account: &account,
                                                                          app: software, versionID: versionID)
                return (metadata.displayVersion, metadata.releaseDate)
            } catch ApplePackageError.passwordTokenExpired where allowRotate {
                account = try await AppleIDSignInService.rotate(email: email, failedAccount: account)
                let metadata = try await VersionLookup.getVersionMetadata(account: &account,
                                                                          app: software, versionID: versionID)
                return (metadata.displayVersion, metadata.releaseDate)
            }
        }
    }

    // MARK: - 历史版本解析

    // MARK: - 版本历史（版本目录 API，免登录）

    /// 版本目录通道：`apis.bilin.eu.org/history/<trackId>`。
    ///
    /// 一次返回**全量版本**：版本号 / `external_identifier`（= 下载指定版本要的
    /// `externalVersionId`）/ 包大小 / 发布时间。与 IPARanger 2.6.0 用的是同一个接口
    /// （它先 iTunes lookup 拿 trackId，再打这个接口选版本，最后 `--external-version-id` 下载）。
    ///
    /// 关键价值：**不需要登录、不需要该账号下载过这个应用、任何区域都有数据** ——
    /// 正好补上「账号通道为空」（Apple 对没有下载记录的应用回空包）和
    /// 「商品页通道只在部分区域有」这两个缺口，而且**直接带发布日期**。
    ///
    /// 实测：ChatGPT 的 `890707559` 与我们从 MDM 目录解析出的 externalVersionId 一致。
    /// 该服务有速率限制（连续请求会 429），所以结果按 appId 落盘缓存。
    ///
    /// v0.3.365：**失败也要落缓存**（短 TTL 负缓存）。原来只有 200＋解析成功才写缓存，
    /// 于是目录一旦 429，每次进页面都会再打一发（账号通道恢复 + 回退三方 API 各一次），
    /// 429 永远冷却不下来 —— 这是审计出来的自持放大点。负缓存与 6h 成功缓存**分开记**，
    /// 失败绝不写进成功缓存，窗口一过自然恢复。
    static func versionHistoryFromCatalog(appId: String) async throws -> [AppStoreVersion] {
        if let data = catalogCache(appId: appId), let versions = parseCatalogHistory(data), !versions.isEmpty {
            return versions
        }
        if catalogRecentlyFailed(appId: appId) {
            LoginLogger.shared.log("三方 API：负缓存窗口内，跳过请求", category: .appStore)
            throw AppStoreError.catalogCoolingDown
        }
        guard let url = URL(string: "https://apis.bilin.eu.org/history/\(appId)") else {
            throw AppStoreError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data: Data
        let code: Int
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            data = body
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            // 网络层失败（超时/断网）同样记负缓存，否则连续进出页面会反复重打
            storeCatalogFailure(appId: appId)
            LoginLogger.shared.log("三方 API 通道：网络失败（\(error.localizedDescription)）",
                                   category: .appStore)
            throw error
        }
        guard code == 200 else {
            storeCatalogFailure(appId: appId)
            LoginLogger.shared.log("三方 API 通道 HTTP \(code)", category: .appStore)
            throw AppStoreError.http(code)
        }
        guard let versions = parseCatalogHistory(data), !versions.isEmpty else {
            storeCatalogFailure(appId: appId)
            throw AppStoreError.decode
        }
        storeCatalogCache(appId: appId, data: data)
        clearCatalogFailure(appId: appId)
        return versions
    }

    private static func parseCatalogHistory(_ data: Data) -> [AppStoreVersion]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out: [AppStoreVersion] = []
        var seen = Set<String>()
        for item in list {
            guard let version = item["bundle_version"] as? String, !version.isEmpty else { continue }
            let raw = item["created_at"] as? String
            let identifier = (item["external_identifier"] as? NSNumber).map { "\($0.int64Value)" }
                ?? (item["external_identifier"] as? String)
            let key = identifier ?? version
            guard seen.insert(key).inserted else { continue }
            out.append(AppStoreVersion(version: version,
                                       dateRaw: raw,
                                       notes: nil,
                                       externalVersionID: identifier,
                                       dateValue: raw.flatMap { formatter.date(from: $0) }))
        }
        return out.isEmpty ? nil : out
    }

    /// 版本目录缓存（JSON Data + 时间戳；Data 才能可靠桥接）
    private static let catalogCacheTTL: TimeInterval = 6 * 3600

    private static func catalogCache(appId: String) -> Data? {
        let defaults = UserDefaults.standard
        let at = defaults.double(forKey: "bilinHistory.\(appId).at")
        guard at > 0, Date().timeIntervalSince1970 - at < catalogCacheTTL else { return nil }
        return defaults.data(forKey: "bilinHistory.\(appId)")
    }

    private static func storeCatalogCache(appId: String, data: Data) {
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: "bilinHistory.\(appId)")
        defaults.set(Date().timeIntervalSince1970, forKey: "bilinHistory.\(appId).at")
    }

    // MARK: - v0.3.365：三方目录失败负缓存

    /// 失败负缓存 TTL（秒）。取 **3 分钟**：
    ///   · 审计实测「一次会话里连续进出历史版本页」的重复打点是 2 发/次，3 分钟足以全部吸收；
    ///   · 又远短于 6h 成功缓存，429 一停就能自然恢复，不会把目录长期判死。
    private static let catalogFailureTTL: TimeInterval = 3 * 60

    private static func catalogFailureKey(_ appId: String) -> String { "bilinHistory.\(appId).failedAt" }

    /// 距上次失败是否还在负缓存窗口内
    private static func catalogRecentlyFailed(appId: String) -> Bool {
        let at = UserDefaults.standard.double(forKey: catalogFailureKey(appId))
        return at > 0 && Date().timeIntervalSince1970 - at < catalogFailureTTL
    }

    /// 只记「失败时刻」，**不写成功缓存** —— 窗口内跳过网络，窗口外自动重试
    private static func storeCatalogFailure(appId: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: catalogFailureKey(appId))
    }

    private static func clearCatalogFailure(appId: String) {
        UserDefaults.standard.removeObject(forKey: catalogFailureKey(appId))
    }

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

    // MARK: - v0.3.368：App 隐私（App Store 侧）

    /// 取某应用的「App 隐私」三组数据（用于追踪 / 与你关联 / 不与你关联）。
    ///
    /// 数据源与版本历史**同一条**：商品页 HTML 的 `serialized-server-data` 里存在
    /// `"page":"privacyDetail"` 段落，其 `pageData.shelves[*].items[*]` 里
    /// `$kind` 为 `PrivacyType` 的条目，`identifier` 就是
    /// `DATA_USED_TO_TRACK_YOU` / `DATA_LINKED_TO_YOU` / `DATA_NOT_LINKED_TO_YOU`。
    ///
    /// **无需登录**（`amp-api` 那条实测 401，不用）。HTML 与历史版本页共用缓存。
    ///
    /// 不是所有应用都有这块数据 → 返回空数组，调用方**整节不显示**（不显示空壳/占位）。
    /// 但**不静默**（v0.3.369）：商品页取不到 / 页面里没有 `privacyDetail` 都会往商店日志
    /// 写一行原因（地理重定向到哪、HTTP 几、还是页面本就没有），用户能在「商店日志」看到。
    static func privacyDetail(appId: String, country: String? = nil) async throws -> [AppPrivacyGroup] {
        let page = try await productPage(appId: appId, country: country)
        let groups = parsePrivacy(html: page.html)
        if groups.isEmpty {
            LoginLogger.shared.log(page.isAppPage
                                   ? "App 隐私：\(page.served)/\(appId) 详情页里没有 privacyDetail（该应用未提供隐私标签）"
                                   : "App 隐私：\(page.served)/\(appId) 没取到详情页，本次无数据且不缓存",
                                   category: .appStore)
        }
        return groups
    }

    /// 从商品页 HTML 解析隐私三组。
    ///
    /// 三类分组在页面里各出现一次且内容一致（`privacyHeader/seeAllAction` 与各
    /// `privacyTypes/items[n]/clickAction` 的 `pageData` 是同一份），取第一处即可拿全。
    ///
    /// 结构（实测国区微信 414478124 / 387682726）：
    ///   PrivacyType{identifier,title,purposes:[{title,categories:[{identifier,title,dataTypes:[…]}]}],
    ///               categories:[…]}                                     ← 「用于追踪」只有 categories
    static func parsePrivacy(html: String) -> [AppPrivacyGroup] {
        guard let marker = html.range(of: "\"page\":\"privacyDetail\"") else { return [] }
        let tail = html[marker.upperBound...]
        guard let shelvesStart = tail.range(of: "\"shelves\":[") else { return [] }
        let fromBracket = tail[shelvesStart.upperBound...]
        guard let jsonArray = balancedSlice(prefix: "[", from: fromBracket),
              let arr = try? JSONSerialization.jsonObject(with: Data(jsonArray.utf8)) as? [Any] else {
            return []
        }

        var byIdentifier: [String: AppPrivacyGroup] = [:]
        var order: [String] = []
        for case let shelf as [String: Any] in arr {
            // 只有 privacyType 货架承载数据类别，privacyHeader 是那句说明文字，跳过
            guard (shelf["contentType"] as? String) == "privacyType",
                  let items = shelf["items"] as? [Any] else { continue }
            for case let it as [String: Any] in items {
                guard (it["$kind"] as? String) == "PrivacyType",
                      let identifier = it["identifier"] as? String, !identifier.isEmpty,
                      byIdentifier[identifier] == nil else { continue }
                let categories = privacyCategories(from: it)
                guard !categories.isEmpty else { continue }
                byIdentifier[identifier] = AppPrivacyGroup(id: identifier,
                                                          title: privacyGroupTitle(identifier),
                                                          categories: categories)
                order.append(identifier)
            }
        }

        // 固定顺序：用于追踪 → 与你关联 → 不与你关联（Apple 的原生顺序）
        let rank = ["DATA_USED_TO_TRACK_YOU", "DATA_LINKED_TO_YOU", "DATA_NOT_LINKED_TO_YOU"]
        return order.sorted { (rank.firstIndex(of: $0) ?? Int.max) < (rank.firstIndex(of: $1) ?? Int.max) }
            .compactMap { byIdentifier[$0] }
    }

    /// 分组标题：按 identifier 给固定短中文 —— 不取 HTML 里的 `title`
    /// （那会随区域/语言变化，而且出口 IP 重定向到别的区时会串味）。
    private static func privacyGroupTitle(_ identifier: String) -> String {
        switch identifier {
        case "DATA_USED_TO_TRACK_YOU": return "用于追踪你的数据"
        case "DATA_LINKED_TO_YOU":     return "与你关联的数据"
        case "DATA_NOT_LINKED_TO_YOU": return "不与你关联的数据"
        default:                       return identifier
        }
    }

    /// 把一组的类别摊平：组级 `categories` 与 `purposes[].categories` 合并，
    /// 同一类别（同 `identifier`）跨用途去重，用途标题按出现顺序并到一条上。
    private static func privacyCategories(from group: [String: Any]) -> [AppPrivacyCategory] {
        var raw: [String: [String: Any]] = [:]       // identifier → 类别原始字典
        var purposes: [String: [String]] = [:]       // identifier → 用途（去重有序）
        var order: [String] = []

        func absorb(_ category: [String: Any], purpose: String?) {
            guard let identifier = category["identifier"] as? String, !identifier.isEmpty else { return }
            if raw[identifier] == nil {
                raw[identifier] = category
                purposes[identifier] = []
                order.append(identifier)
            }
            guard let purpose, !purpose.isEmpty,
                  purposes[identifier]?.contains(purpose) == false else { return }
            purposes[identifier, default: []].append(purpose)
        }

        // 「用于追踪你的数据」的类别直接挂在组上
        for case let c as [String: Any] in (group["categories"] as? [Any] ?? []) {
            absorb(c, purpose: nil)
        }
        // 「与你关联 / 不与你关联」是 组 → purposes → categories
        for case let p as [String: Any] in (group["purposes"] as? [Any] ?? []) {
            let title = (p["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            for case let c as [String: Any] in (p["categories"] as? [Any] ?? []) {
                absorb(c, purpose: title)
            }
        }

        return order.compactMap { identifier -> AppPrivacyCategory? in
            guard let category = raw[identifier] else { return nil }
            let title = (category["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return AppPrivacyCategory(id: identifier,
                                      title: title,
                                      dataTypes: deduped((category["dataTypes"] as? [String]) ?? []),
                                      purposes: purposes[identifier] ?? [],
                                      systemImage: privacySymbol(category["artwork"] as? [String: Any]))
        }
    }

    /// `artwork.template` 形如 `systemimage://bag.fill` / `resource://person.circle.slash`。
    /// **只认 `systemimage://`**：那是明确的 SF Symbol 名；`resource://` 是 Apple 内部资源名，
    /// 在 iOS 上未必能解析成图标（乱用会留空白占位），所以返回 nil 表示「没有图标」。
    private static func privacySymbol(_ artwork: [String: Any]?) -> String? {
        let scheme = "systemimage://"
        guard let template = artwork?["template"] as? String, template.hasPrefix(scheme) else { return nil }
        let name = String(template.dropFirst(scheme.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func deduped(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
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

/// 一条「数据类别」（App 隐私栏目里的一行）。
struct AppPrivacyCategory: Identifiable, Hashable {
    /// 类别 identifier（如 `IDENTIFIERS`）
    let id: String
    /// 类别名，Apple 原文（如「标识符」）
    let title: String
    /// 具体数据类型，Apple 原文（如「设备 ID」）
    let dataTypes: [String]
    /// 用途，Apple 原文（如「第三方广告」）；「用于追踪」组无用途，为空
    let purposes: [String]
    /// SF Symbol 名；Apple 没给 `systemimage://` 模板时为 nil（不显示图标）
    let systemImage: String?
}

/// 「App 隐私」的一个分组（用于追踪 / 与你关联 / 不与你关联）。
struct AppPrivacyGroup: Identifiable, Hashable {
    /// `DATA_USED_TO_TRACK_YOU` / `DATA_LINKED_TO_YOU` / `DATA_NOT_LINKED_TO_YOU`
    let id: String
    /// 固定短中文标题
    let title: String
    let categories: [AppPrivacyCategory]
}

enum AppStoreError: Error, LocalizedError {
    case badURL
    case http(Int)
    case decode
    case noAccount
    /// v0.3.365：三方版本目录刚失败过，负缓存窗口内不再重打（窗口一过自动恢复）
    case catalogCoolingDown

    var errorDescription: String? {
        switch self {
        case .badURL: return "请求地址无效"
        case .http(let code): return "网络请求失败（HTTP \(code)）"
        case .decode: return "数据解析失败"
        case .noAccount: return "需要先登录 Apple ID"
        case .catalogCoolingDown: return "三方 API 暂时不可用，稍后自动重试"
        }
    }
}
