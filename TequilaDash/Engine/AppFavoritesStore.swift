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

    /// Swift 6 并发检查：本类型非 Sendable，但**没有可变实例状态** ——
    /// 每次操作都直接读写 `Documents/app_favorites.json`，不缓存任何内存状态；
    /// 按设计只在主线程（收藏栏 UI）使用。因此 `shared` 共享无风险。
    nonisolated(unsafe) static let shared = AppFavoritesStore()
    private init() {}

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app_favorites.json")
    }

    /// 全部收藏（按收藏时间倒序）
    ///
    /// v0.3.570：读失败不再当「没有收藏」。台账没完整读出来时只返回能读到的那部分（可能为空），
    /// 但**不写盘**（写盘会把没读到的收藏覆盖掉）。
    func items() -> [FavoriteApp] {
        let load = load()
        logReadOnly(load.note)
        return load.items.sorted { $0.addedAt > $1.addedAt }
    }

    func contains(appId: String) -> Bool {
        items().contains { $0.appId == appId }
    }

    /// 该应用被收藏了几次
    func count(appId: String) -> Int {
        items().filter { $0.appId == appId }.count
    }

    /// 收进收藏栏（**每次都新增一条**，返回该应用累计收藏次数）
    ///
    /// v0.3.570：台账没完整读出来时**只读、不写盘**（否则会把没读到的收藏覆盖掉）。
    /// 此时返回当前能读到的次数（不改动原文件）。
    @discardableResult
    func add(_ item: AppStoreItem) -> Int {
        let load = load()
        guard load.writable else {
            logReadOnly(load.note)
            notifyWriteRejected(load.userReason)
            return load.items.filter { $0.appId == item.id }.count
        }
        var list = load.items
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
        let load = load()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        save(load.items.filter { $0.id != id })
    }

    /// 批量移除（编辑模式多选）
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let load = load()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        save(load.items.filter { !ids.contains($0.id) })
    }

    /// 清掉某个应用的全部收藏
    func removeAll(appId: String) {
        let load = load()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        save(load.items.filter { $0.appId != appId })
    }

    func removeAll() {
        // 用户**显式**「清空收藏栏」（确认弹窗，role: .destructive）—— 这是删除命令，
        // 不是「读失败当成空」。不读盘、直接写空，因此台账损坏时也照常生效。
        save([])
    }

    func filtered(_ query: String) -> [FavoriteApp] {
        items().filter { $0.matches(query) }
    }

    /// 台账读取结果。
    ///
    /// `writable == false` = **这一次没能完整读出台账**（文件读不出 / JSON 整份坏 / 有记录解不出）。
    /// 调用方**必须只读、绝不回写** —— 否则会把没读到的收藏当成「不存在」而覆盖掉。
    private struct FavoritesLoad {
        let items: [FavoriteApp]
        let writable: Bool
        let note: String?
        /// 面向用户的简短原因（写被拒时弹给用户看）；`writable == true` 时为 nil。
        let userReason: String?
    }

    /// 读取全部收藏（保持写入顺序）。读不全时 `writable == false`。
    private func load() -> FavoritesLoad {
        // 文件确实不存在 = 合法空台账（首次运行 / 从没收藏过），可以写。
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return FavoritesLoad(items: [], writable: true, note: nil, userReason: nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return FavoritesLoad(items: [], writable: false,
                                 note: "收藏台账存在但读取失败（被占用 / 磁盘错误），本次按只读处理，不回写",
                                 userReason: "收藏台账无法读取")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        // 1) 快路径：整份解得出
        if let list = try? dec.decode([FavoriteApp].self, from: data) {
            return FavoritesLoad(items: list, writable: true, note: nil, userReason: nil)
        }

        // 2) 整份解失败 → **逐条**解，能救多少救多少（单条坏记录不再拖垮整份台账）。
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return FavoritesLoad(items: [], writable: false,
                                 note: "收藏台账 JSON 解析失败（文件损坏），本次按只读处理，不回写",
                                 userReason: "收藏台账文件损坏")
        }
        var salvaged: [FavoriteApp] = []
        for element in raw {
            guard let d = try? JSONSerialization.data(withJSONObject: element),
                  let item = try? dec.decode(FavoriteApp.self, from: d) else { continue }
            salvaged.append(item)
        }
        guard !salvaged.isEmpty else {
            return FavoritesLoad(items: [], writable: false,
                                 note: "收藏台账 \(raw.count) 条全部无法解析，本次按只读处理，不回写",
                                 userReason: "收藏台账文件损坏")
        }
        // 有救回来的条目，但仍**不写盘**：写回会把解不出的那几条永久抹掉。
        return FavoritesLoad(items: salvaged, writable: false,
                             note: "收藏台账 \(raw.count) 条里有 \(raw.count - salvaged.count) 条无法解析，"
                                 + "本次按只读处理，不回写（原文件保留）",
                             userReason: "收藏台账文件损坏")
    }

    private func save(_ list: [FavoriteApp]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(list) else {
            LoginLogger.shared.log("[收藏] 台账编码失败，未写盘（\(list.count) 条）", category: .general)
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 写失败**不能静默**：调用方以为已持久化。
            LoginLogger.shared.log("[收藏] 台账写盘失败：\(error)（\(list.count) 条未持久化）",
                                   category: .general)
        }
    }

    /// 台账没完整读出来时的统一日志（说明本次为何只读、不回写）。
    private func logReadOnly(_ note: String?) {
        guard let note else { return }
        LoginLogger.shared.log("[收藏] \(note)", category: .general)
    }

    /// 写被拒时给**用户可见**的反馈：日志不是反馈，用户改了却看不到变化会以为「点了没反应」。
    /// 文案点明原因与后果。`ToastCenter` 是 `@MainActor` 类，按全仓既有写法显式切回主 actor。
    private func notifyWriteRejected(_ userReason: String?) {
        let reason = userReason ?? "收藏台账读取异常"
        Task { @MainActor in
            ToastCenter.shared.show("\(reason)，本次改动未保存")
        }
    }
}
