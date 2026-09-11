import Foundation

/// v0.3.315：**从「免登录源」（爱思 PC 端公开接口）按 bundleId 定位可安装的 IPA**。
///
/// 用途：
/// · 设备瘦身「较大应用」重装时本地没有包 → 现场按 bundleId 去源里找；
/// · AppStore 商店详情页「获取」时优先走免登录源直装。
///
/// 查找方式：用应用名（必要时退化成 bundleId 字面量）走搜索接口，再按 **bundleId 精确匹配**
/// ——搜索结果是模糊匹配，必须自己核对 bundleId，否则会装错应用。
enum SourcePackageLocator {

    struct Hit {
        let ipaURL: String
        let bundleId: String
        let name: String
        let version: String?
    }

    /// - Parameters:
    ///   - bundleId: 目标应用 bundle id（必填，用于精确匹配）
    ///   - name: 应用显示名（搜索关键词）
    static func find(bundleId: String, name: String) async -> Hit? {
        let target = bundleId.lowercased()
        guard !target.isEmpty else { return nil }
        var keywords: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { keywords.append(trimmed) }
        keywords.append(bundleId)

        for keyword in keywords {
            let list = (try? await I4PCStoreClient.search(keyword: keyword, rows: 20)) ?? []
            for app in list {
                guard (app.bundleId ?? "").lowercased() == target, let url = app.ipaURL else { continue }
                return Hit(ipaURL: url.absoluteString,
                           bundleId: app.bundleId ?? bundleId,
                           name: app.name,
                           version: app.version)
            }
        }
        return nil
    }

    // MARK: - 可用性探测（设备瘦身「较大应用」用）

    /// 结果缓存（bundleId → 是否可下载），TTL 7 天；避免每次进页面都联网重探
    private static let cacheKey = "SourcePackageLocator.availability.v1"
    private static let ttl: TimeInterval = 7 * 24 * 3600

    /// 缓存里的可用性；nil = 没探过/已过期
    static func cachedAvailability(bundleId: String) -> Bool? {
        guard let raw = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String: Double]],
              let entry = raw[bundleId],
              let ts = entry["ts"], let ok = entry["ok"],
              Date().timeIntervalSince1970 - ts < ttl
        else { return nil }
        return ok > 0.5
    }

    private static func store(_ available: Bool, bundleId: String) {
        var raw = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String: Double]]) ?? [:]
        raw[bundleId] = ["ts": Date().timeIntervalSince1970, "ok": available ? 1 : 0]
        UserDefaults.standard.set(raw, forKey: cacheKey)
    }

    /// 探测「源里有没有这个 bundleId 对应的可下载包」（带缓存）
    static func probe(bundleId: String, name: String) async -> Bool {
        if let cached = cachedAvailability(bundleId: bundleId) { return cached }
        let hit = await find(bundleId: bundleId, name: name)
        let ok = hit != nil
        store(ok, bundleId: bundleId)
        return ok
    }

    /// 批量探测（并发 4，避免把源打爆）
    static func probe(bundleIds: [(bundleId: String, name: String)],
                      progress: ((Int, Int) -> Void)? = nil) async -> [String: Bool] {
        var out: [String: Bool] = [:]
        var pending: [(String, String)] = []
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
        await withTaskGroup(of: (String, Bool).self) { group in
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
