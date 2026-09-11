import Foundation

/// **从「免登录源」（爱思 PC 端公开接口）按 bundleId 定位可安装的 IPA**。
///
/// 用途：
/// · 设备瘦身「较大应用」重装时本地没有包 → 现场按 bundleId 去源里找；
/// · AppStore 商店详情页「获取」时优先走免登录源直装。
///
/// 查找方式：先用应用名（必要时退化成 bundleId 字面量）走搜索接口，再按
/// **bundleId 精确匹配** —— 搜索结果是模糊匹配，必须自己核对 bundleId，否则会装错应用。
///
/// ## v0.3.321 关键修复
/// 原来的 `find` 把「请求失败」和「源里确实没有」都返回 nil，而 `probe` 又把两者
/// 一起当 `false` 缓存 **7 天** → 一次网络抖动就让某个应用在整周内被判成
/// 「资源缺失无法重装」（真机实锤：可重装的应用被禁用）。现在：
/// **请求失败 → 未知（nil，不缓存、不拦）；确认没有 → false（30 分钟后自动重试）。**
enum SourcePackageLocator {

    struct Hit {
        let ipaURL: String
        let bundleId: String
        let name: String
        let version: String?
    }

    /// 一次查找的结果：区分「查成了但没有」与「没查成」
    private struct LookupResult {
        var succeeded: Bool
        var hit: Hit?
    }

    // MARK: - 查找

    /// 下载链路用：拿不到就返回 nil（调用方按「找不到包」处理）
    static func find(bundleId: String, name: String) async -> Hit? {
        await lookup(bundleId: bundleId, name: name).hit
    }

    private static func lookup(bundleId: String, name: String) async -> LookupResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var keywords: [String] = []
        if !trimmedName.isEmpty { keywords.append(trimmedName) }
        if !bundleId.isEmpty { keywords.append(bundleId) }
        guard !keywords.isEmpty else { return LookupResult(succeeded: false, hit: nil) }

        let target = bundleId.lowercased()
        var anySucceeded = false
        for keyword in keywords {
            let list: [I4PCStoreClient.I4App]
            do {
                // rows 提到 50：原来 20 条常常覆盖不到目标（长尾应用名容易被挤掉）
                list = try await I4PCStoreClient.search(keyword: keyword, rows: 50)
                anySucceeded = true
            } catch {
                continue                       // 这次请求没成 → 换下一个关键词
            }
            for app in list where (app.bundleId ?? "").lowercased() == target {
                guard let url = app.ipaURL else { continue }
                return LookupResult(succeeded: true,
                                    hit: Hit(ipaURL: url.absoluteString,
                                             bundleId: app.bundleId ?? bundleId,
                                             name: app.name,
                                             version: app.version))
            }
        }
        return LookupResult(succeeded: anySucceeded, hit: nil)
    }

    // MARK: - 可用性探测（设备瘦身「较大应用」用）

    /// 缓存（bundleId → `{ok, ts}`）存成 JSON Data —— 不能用
    /// `UserDefaults.dictionary(forKey:) as? [String: [String: Double]]`，
    /// 嵌套桥接不可靠，容易整份读不出来（v0.3.319 的坑）。
    private static let cacheKey = "SourcePackageLocator.availability.v2"
    private static let positiveTTL: TimeInterval = 7 * 24 * 3600   // 能下到：7 天
    private static let negativeTTL: TimeInterval = 30 * 60         // 下不到：30 分钟后自动重试

    private struct Entry: Codable {
        var ok: Bool
        var ts: Double
    }

    private static func loadCache() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }

    private static func saveCache(_ map: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    /// 缓存里的可用性；nil = 没探过 / 已过期 / 上次请求失败
    static func cachedAvailability(bundleId: String) -> Bool? {
        guard let entry = loadCache()[bundleId] else { return nil }
        let age = Date().timeIntervalSince1970 - entry.ts
        let ttl = entry.ok ? positiveTTL : negativeTTL
        guard age < ttl else { return nil }
        return entry.ok
    }

    private static func store(_ available: Bool, bundleId: String) {
        var map = loadCache()
        map[bundleId] = Entry(ok: available, ts: Date().timeIntervalSince1970)
        saveCache(map)
    }

    /// 清空探测缓存（「重新检测」用）
    static func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    /// 探测「源里有没有这个 bundleId 对应的可下载包」。
    /// - Returns: `true` 能下 / `false` 源里确认没有 / `nil` **这次没查成**（未知）
    static func probe(bundleId: String, name: String) async -> Bool? {
        if let cached = cachedAvailability(bundleId: bundleId) { return cached }
        let result = await lookup(bundleId: bundleId, name: name)
        guard result.succeeded else { return nil }   // 请求失败：不缓存、不拦
        let ok = result.hit != nil
        store(ok, bundleId: bundleId)
        return ok
    }

    /// 批量探测（并发 4）；值为 nil 表示该项这次没查成
    static func probe(bundleIds: [(bundleId: String, name: String)],
                      progress: ((Int, Int) -> Void)? = nil) async -> [String: Bool?] {
        var out: [String: Bool?] = [:]
        var pending: [(bundleId: String, name: String)] = []
        for item in bundleIds {
            if let cached = cachedAvailability(bundleId: item.bundleId) {
                out[item.bundleId] = cached
            } else {
                pending.append(item)
            }
        }
        let total = pending.count
        if total == 0 { return out }
        var done = 0
        await withTaskGroup(of: (String, Bool?).self) { group in
            var index = 0
            let window = min(4, pending.count)
            for _ in 0..<window {
                let item = pending[index]
                index += 1
                group.addTask { (item.bundleId, await probe(bundleId: item.bundleId, name: item.name)) }
            }
            while let result = await group.next() {
                out[result.0] = result.1
                done += 1
                progress?(done, total)
                if index < pending.count {
                    let item = pending[index]
                    index += 1
                    group.addTask { (item.bundleId, await probe(bundleId: item.bundleId, name: item.name)) }
                }
            }
        }
        return out
    }
}
