import Foundation

/// 用户自定义软件源清单的持久化（增删改查）。
///
/// ## 存储形态（与仓库既有台账一致）
/// · 单文件 JSON：`Documents/sign_sources.json`，一个 `[SignSource]` 数组，每条含其 `apps` 缓存。
///   与 `AppFavoritesStore`（`Documents/app_favorites.json`）、`IPADownloadLibrary`
///   （`Documents/ipa_downloads.json`）同款：`Codable` + 单文件 + `Data.write(options: .atomic)`。
/// · **数组顺序 = 列表显示顺序**（新增追加到末尾，`sources()` 不重排）。
/// · **唯一键 = 归一化 URL**（见 `normalize(_:)`）—— 去重 / 删除 / 更新均按它比对。
///
/// ## 读失败一律「只读、不回写」（照 `AppFavoritesStore`）
/// 台账读不全时（文件读不出 / 整份 JSON 坏 / 有条目解不出）**绝不回写** —— 否则会把没读到的源
/// 当成「不存在」而覆盖掉。此时 `sources()` 仍返回能读到的那部分，写操作被拒。
///
/// ## 模型归属
/// `SignSource` / `SignSourceApp` 的唯一真源是 `SignSourceModels.swift` —— 本文件**只引用**，不重定义。
final class SignSourceStore {

    /// 日志前缀（与 `SignSourceClient.logTag` 同串，便于真机 grep 一路日志）。
    static let logTag = "[软件源]"

    /// Swift 6 并发检查：本类型非 Sendable，但**无可变实例状态** —— 每次操作都现场读写
    /// `Documents/sign_sources.json`，不缓存内存状态；按设计只在主线程（软件源 UI）使用，
    /// 故 `shared` 共享无风险（同 `AppFavoritesStore`）。
    nonisolated(unsafe) static let shared = SignSourceStore()
    private init() {}

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sign_sources.json")
    }

    // MARK: - 读

    /// 全部源（按存储顺序 = 列表显示顺序）。
    func sources() -> [SignSource] {
        let load = load()
        logReadOnly(load.note)
        return load.items
    }

    /// 是否已添加该源（按**归一化 URL** 比对：`https://A.com/x/` 与 `https://a.com/x` 视为同源）。
    func contains(sourceURL: String) -> Bool {
        let key = Self.key(sourceURL)
        return sources().contains { Self.key($0.sourceURL) == key }
    }

    // MARK: - 写

    /// 新增一个源。返回是否**真正落盘**。
    ///
    /// · 已存在（归一化 URL 相同）⇒ 返回 `false`，不改动；
    /// · 台账读不全 ⇒ 只读、不写，返回 `false`；
    /// · 成功 ⇒ 追加到末尾（列表末尾），返回 `true`。
    @discardableResult
    func add(_ source: SignSource) -> Bool {
        let incoming = Self.canonical(source)
        let load = load()
        guard load.writable else {
            logReadOnly(load.note)
            return false
        }
        if load.items.contains(where: { Self.key($0.sourceURL) == incoming.sourceURL }) {
            return false
        }
        save(load.items + [incoming])
        return true
    }

    /// 删除一个源（按**归一化 URL** 匹配）。
    func remove(sourceURL: String) {
        let key = Self.key(sourceURL)
        let load = load()
        guard load.writable else {
            logReadOnly(load.note)
            notifyWriteRejected(load.userReason)
            return
        }
        save(load.items.filter { Self.key($0.sourceURL) != key })
    }

    /// 覆盖式更新一个源（「更新」动作：重拉后调用）。
    ///
    /// 匹配键 = 归一化 URL，命中则**保持原位置**替换；未命中则追加到末尾。
    func update(_ source: SignSource) {
        let incoming = Self.canonical(source)
        let load = load()
        guard load.writable else {
            logReadOnly(load.note)
            notifyWriteRejected(load.userReason)
            return
        }
        var list = load.items
        if let i = list.firstIndex(where: { Self.key($0.sourceURL) == incoming.sourceURL }) {
            list[i] = incoming
        } else {
            list.append(incoming)
        }
        save(list)
    }

    // MARK: - 归一化（**唯一权威实现**）

    /// 归一化源地址；不合格返回 `nil`（调用方提示「无效源地址」）。
    ///
    /// 归一化：去首尾空白 → 缺 scheme 补 `http://` → scheme/host 转小写 → 去尾 `/`。
    /// 校验：① 归一化后长度 ≥ 12；② `URLComponents` 可解析；③ scheme ∈ {http, https}；
    ///       ④ host 非空且满足「IPv4 正则 ∨ 含 `.` 且 len>3 ∨ 含 `:` 且 len>1」。
    ///
    /// ⚠️ **本函数是源地址归一化的唯一真源**（规格 §4.1 / §5.5 要求「归一化与唯一键共用同一份」）。
    /// `SignSourceListView` 侧的 `normalizeSourceURLString(_:)` 应改为调用本函数（行为逐字一致）。
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        guard var comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(),
              let rawHost = comps.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.lowercased()
        // ③ scheme 检查
        guard scheme == "http" || scheme == "https" else { return nil }
        // ④ host 规则
        guard isValidSourceHost(host) else { return nil }
        comps.scheme = scheme
        comps.host = host
        var normalized = comps.string ?? s
        while normalized.hasSuffix("/") { normalized.removeLast() }
        // ① 长度检查（按归一化后的字符串计）
        guard normalized.count >= 12 else { return nil }
        return normalized
    }

    /// host 规则（照抄全能签，规格 §4.1）：
    /// IPv4 正则 `^\d{1,3}(?:\.\d{1,3}){3}$` ∨ 含 `.` 且长度 > 3 ∨ 含 `:` 且长度 > 1。
    private static func isValidSourceHost(_ host: String) -> Bool {
        if host.range(of: #"^\d{1,3}(?:\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return true
        }
        if host.contains(".") && host.count > 3 { return true }
        if host.contains(":") && host.count > 1 { return true }   // IPv6 字面量
        return false
    }

    /// 归一化键：优先用 `normalize(_:)` 的归一化结果；不合规时退回「去空白原串」，
    /// 以便对已损坏 / 历史条目也能做「原样」比对（不至于匹配不上而无法删除）。
    private static func key(_ raw: String) -> String {
        normalize(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 入库前把 `sourceURL` 收敛为归一化键（规格 §5.3：`sourceURL` 存归一化后的值）。
    private static func canonical(_ source: SignSource) -> SignSource {
        var s = source
        s.sourceURL = key(source.sourceURL)
        return s
    }

    // MARK: - 落盘 / 读盘

    /// 台账读取结果。
    ///
    /// `writable == false` = **这一次没能完整读出台账**（文件读不出 / JSON 整份坏 / 有记录解不出）。
    /// 调用方**必须只读、绝不回写** —— 否则会把没读到的源当成「不存在」而覆盖掉。
    private struct LoadResult {
        let items: [SignSource]
        let writable: Bool
        let note: String?
        /// 面向用户的简短原因（写被拒时弹给用户看）；`writable == true` 时为 nil。
        let userReason: String?
    }

    /// 读取全部源（保持写入顺序）。读不全时 `writable == false`。
    private func load() -> LoadResult {
        // 文件确实不存在 = 合法空台账（首次运行 / 从没添加过），可以写。
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadResult(items: [], writable: true, note: nil, userReason: nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadResult(items: [], writable: false,
                              note: "源清单存在但读取失败（被占用 / 磁盘错误），本次按只读处理，不回写",
                              userReason: "源清单无法读取")
        }
        let dec = JSONDecoder()

        // 1) 快路径：整份解得出
        if let list = try? dec.decode([SignSource].self, from: data) {
            return LoadResult(items: refill(list), writable: true, note: nil, userReason: nil)
        }

        // 2) 整份解失败 → **逐条**解，能救多少救多少（单条坏记录不再拖垮整份台账）。
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return LoadResult(items: [], writable: false,
                              note: "源清单 JSON 解析失败（文件损坏），本次按只读处理，不回写",
                              userReason: "源清单文件损坏")
        }
        var salvaged: [SignSource] = []
        for element in raw {
            guard let d = try? JSONSerialization.data(withJSONObject: element),
                  let item = try? dec.decode(SignSource.self, from: d) else { continue }
            salvaged.append(item)
        }
        guard !salvaged.isEmpty else {
            return LoadResult(items: [], writable: false,
                              note: "源清单 \(raw.count) 条全部无法解析，本次按只读处理，不回写",
                              userReason: "源清单文件损坏")
        }
        // 有救回来的条目，但仍**不写盘**：写回会把解不出的那几条永久抹掉。
        return LoadResult(items: refill(salvaged), writable: false,
                          note: "源清单 \(raw.count) 条里有 \(raw.count - salvaged.count) 条无法解析，"
                              + "本次按只读处理，不回写（原文件保留）",
                          userReason: "源清单文件损坏")
    }

    private func save(_ list: [SignSource]) {
        let enc = JSONEncoder()
        guard let data = try? enc.encode(list) else {
            LoginLogger.shared.log("\(Self.logTag) 源清单编码失败，未写盘（\(list.count) 条）",
                                   category: .signSource)
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 写失败**不能静默**：调用方以为已持久化。
            LoginLogger.shared.log("\(Self.logTag) 源清单写盘失败：\(error)（\(list.count) 条未持久化）",
                                   category: .signSource)
        }
    }

    /// 解码后回填 `apps[].sourceURL` / `sourceName`（模型的 `applyInheritance()`）。
    ///
    /// `SignSourceApp` 的 `CodingKeys` 刻意**不含**这两个回填字段（它们不来自源 JSON），
    /// 不重填的话，持久化读回后源内 App 行的「来源」会为空。
    private func refill(_ list: [SignSource]) -> [SignSource] {
        list.map { var s = $0; s.applyInheritance(); return s }
    }

    /// 台账没完整读出来时的统一日志（说明本次为何只读、不回写）。
    private func logReadOnly(_ note: String?) {
        guard let note else { return }
        LoginLogger.shared.log("\(Self.logTag) \(note)", category: .signSource)
    }

    /// 写被拒时给**用户可见**的反馈（`remove` / `update` 无返回值，静默失败会让用户以为「点了没反应」）。
    /// `add` 由调用方按 `false` 自行提示，故此处不重复弹。`ToastCenter` 是 `@MainActor` 类，
    /// 按全仓既有写法显式切回主 actor。
    private func notifyWriteRejected(_ userReason: String?) {
        let reason = userReason ?? "源清单读取异常"
        Task { @MainActor in
            ToastCenter.shared.show("\(reason)，本次改动未保存")
        }
    }
}
