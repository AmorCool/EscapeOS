import Foundation

/// 收藏栏条目：**每次收藏都是一条独立记录**（`id` 为 UUID），
/// 因此同一个应用收藏多次会各占一行，用收藏时间区分。
struct FavoriteApp: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString   // 每条收藏自己的标识
    var appId: String                    // AppID（App Store trackId）
    var bundleId: String?
    var name: String
    var storeURL: String                 // App Store 链接
    var iconURL: String?
    var addedAt: Date                    // 收进收藏栏的时间

    /// 搜索索引：名称 / AppID / BundleID 任一命中
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if name.lowercased().contains(q) { return true }
        if appId.lowercased().contains(q) { return true }
        if let b = bundleId, b.lowercased().contains(q) { return true }
        return false
    }

    /// v0.3.321：旧版记录（`id` 当时等于 appId）没有 `id` 字段，缺就补一个新的，
    /// 否则整份收藏会因 keyNotFound 直接读不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decode(String.self, forKey: .appId)
        bundleId = try? c.decodeIfPresent(String.self, forKey: .bundleId)
        name = try c.decode(String.self, forKey: .name)
        storeURL = try c.decode(String.self, forKey: .storeURL)
        iconURL = try? c.decodeIfPresent(String.self, forKey: .iconURL)
        addedAt = (try? c.decode(Date.self, forKey: .addedAt)) ?? Date()
        // 旧记录没有 id → 用 appId + 收藏时间推一个**稳定** id（不能用随机 UUID，
        // 否则每次读盘 id 都变，列表刷新会错位）
        if let existing = try? c.decode(String.self, forKey: .id), !existing.isEmpty {
            id = existing
        } else {
            id = "\(appId)-\(Int(addedAt.timeIntervalSince1970))"
        }
    }

    init(appId: String, bundleId: String?, name: String,
         storeURL: String, iconURL: String?, addedAt: Date) {
        self.id = UUID().uuidString
        self.appId = appId
        self.bundleId = bundleId
        self.name = name
        self.storeURL = storeURL
        self.iconURL = iconURL
        self.addedAt = addedAt
    }

    /// 收藏时间文案（列表里区分同款应用的多条记录）
    var addedText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: addedAt)
    }
}

/// 收藏栏存储（`Documents/app_favorites.json`，单例，主线程使用）。
final class AppFavoritesStore {

    static let shared = AppFavoritesStore()
    private init() {}

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app_favorites.json")
    }

    /// 全部收藏（按收藏时间倒序）
    func items() -> [FavoriteApp] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([FavoriteApp].self, from: data) else { return [] }
        return list.sorted { $0.addedAt > $1.addedAt }
    }

    func contains(appId: String) -> Bool {
        items().contains { $0.appId == appId }
    }

    /// 该应用被收藏了几次
    func count(appId: String) -> Int {
        items().filter { $0.appId == appId }.count
    }

    /// 收进收藏栏（**每次都新增一条**，返回该应用累计收藏次数）
    @discardableResult
    func add(_ item: AppStoreItem) -> Int {
        var list = rawItems()
        list.append(FavoriteApp(appId: item.id,
                                bundleId: item.bundleId,
                                name: item.name,
                                storeURL: item.webURL?.absoluteString
                                    ?? "https://apps.apple.com/cn/app/id\(item.id)",
                                iconURL: item.iconURL ?? item.iconSmallURL,
                                addedAt: Date()))
        save(list)
        return list.filter { $0.appId == item.id }.count
    }

    /// 移除某条收藏
    func remove(id: String) {
        save(rawItems().filter { $0.id != id })
    }

    /// 批量移除（编辑模式多选）
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        save(rawItems().filter { !ids.contains($0.id) })
    }

    /// 清掉某个应用的全部收藏
    func removeAll(appId: String) {
        save(rawItems().filter { $0.appId != appId })
    }

    func removeAll() {
        save([])
    }

    func filtered(_ query: String) -> [FavoriteApp] {
        items().filter { $0.matches(query) }
    }

    /// 未排序的原始记录（保持写入顺序）
    private func rawItems() -> [FavoriteApp] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([FavoriteApp].self, from: data)) ?? []
    }

    private func save(_ list: [FavoriteApp]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
