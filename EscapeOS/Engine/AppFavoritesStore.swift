import Foundation

/// 收藏栏条目：记录 AppID（trackId）/ BundleID / 应用名 / App Store 链接。
struct FavoriteApp: Codable, Identifiable, Hashable {
    var appId: String            // AppID（App Store trackId）
    var bundleId: String?
    var name: String
    var storeURL: String         // App Store 链接
    var iconURL: String?
    var addedAt: Date

    var id: String { appId }

    /// 搜索索引：名称 / AppID / BundleID 任一命中
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if name.lowercased().contains(q) { return true }
        if appId.lowercased().contains(q) { return true }
        if let b = bundleId, b.lowercased().contains(q) { return true }
        return false
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

    /// 全部收藏（按加入时间倒序）
    func items() -> [FavoriteApp] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return ((try? dec.decode([FavoriteApp].self, from: data)) ?? [])
            .sorted { $0.addedAt > $1.addedAt }
    }

    func contains(appId: String) -> Bool {
        items().contains { $0.appId == appId }
    }

    /// 加入 / 取消收藏（返回操作后是否已收藏）
    @discardableResult
    func toggle(_ item: AppStoreItem) -> Bool {
        var list = items()
        if let idx = list.firstIndex(where: { $0.appId == item.id }) {
            list.remove(at: idx)
            save(list)
            return false
        }
        list.append(FavoriteApp(appId: item.id,
                                bundleId: item.bundleId,
                                name: item.name,
                                storeURL: item.webURL?.absoluteString
                                    ?? "https://apps.apple.com/cn/app/id\(item.id)",
                                iconURL: item.iconURL ?? item.iconSmallURL,
                                addedAt: Date()))
        save(list)
        return true
    }

    func remove(appId: String) {
        save(items().filter { $0.appId != appId })
    }

    func remove(appIds: Set<String>) {
        save(items().filter { !appIds.contains($0.appId) })
    }

    func filtered(_ query: String) -> [FavoriteApp] {
        items().filter { $0.matches(query) }
    }

    private func save(_ list: [FavoriteApp]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
