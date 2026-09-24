//
//  AirliftChangeLog.swift
//  EscapeSpace
//
//  airlift 的**改动记录** —— 每次越界写/删都留一条，防止「以后不知道改了啥」.
//
//  ## 为什么需要（用户明确要求）
//  「如果新增的文件要记忆防止以后不知道改了啥文件加了啥东西」
//
//  airlift 能往 `/var/mobile/Library/**` 这些地方写文件，写完之后**设备上没有任何痕迹
//  告诉你「这个文件是谁什么时候加的」** —— 时间一长就变成「不知道哪来的文件」，
//  想回滚也无从下手. 所以宿主侧统一记一份.
//
//  ## 记在哪、记什么
//  `Documents/AirliftChanges/changes.json`（App 沙盒内，AFC 之外的真相源）.
//  每条：时间 / 动作 / 目标路径 / 字节数 / 备份位置 / 是否读回校验通过.
//
//  ## 为什么**同时**写一份 markdown
//  JSON 给界面读；`changes.md` 给人看 —— 用 SSH `cat` 就能读，不用解析 JSON.
//  两份是同一次写入的两个视图，不会不一致（都从同一个数组渲染）.
//

import Foundation

/// airlift 越界操作的改动记录（纯静态，无实例）.
enum AirliftChangeLog {

    /// 一条改动.
    struct Entry: Codable, Identifiable {
        var id: String { "\(time)-\(action)-\(path)" }
        /// ISO8601 时间
        let time: String
        /// `write` / `delete` / `pull`（pull 只读回，不改设备）
        let action: String
        /// 设备上的目标绝对路径
        let path: String
        /// 写入/读出的字节数（delete 记被删的大小，未知则 0）
        let bytes: Int
        /// 备份落在哪（App 沙盒内路径；没有就空）
        let backup: String
        /// 是否**读回校验通过**（`false` = 没验证或验证失败，**不代表没写进去**）
        let verified: Bool
        /// 备注（比如「批量写 12 个文件」）
        let note: String
        /// **值的变化**（用户要求「动作是改了什么值 应该显示在改动记录里」）.
        ///
        /// 形如 `SBDontLockAfterCrash: 未设置 → true`、`原 5764 B → 新 5535 B`.
        /// 用 `String?` 是为了兼容**旧记录**（那时没这个字段，解码成 nil）.
        let detail: String?
    }

    /// 最多保留多少条（超出丢最旧的）
    private static let limit = 500

    private static let lock = NSLock()

    private static var dirURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirliftChanges", isDirectory: true)
    }
    private static var jsonURL: URL { dirURL.appendingPathComponent("changes.json") }
    private static var markdownURL: URL { dirURL.appendingPathComponent("changes.md") }

    /// 追加一条. **任何失败都静默** —— 记录不能影响主流程.
    static func append(action: String, path: String, bytes: Int,
                       backup: String = "", verified: Bool = false, note: String = "",
                       detail: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        var all = readAllUnlocked()
        all.append(Entry(time: ISO8601DateFormatter().string(from: Date()),
                         action: action, path: path, bytes: bytes,
                         backup: backup, verified: verified, note: note,
                         detail: detail))
        if all.count > limit { all.removeFirst(all.count - limit) }

        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        try? renderMarkdown(all).data(using: .utf8)?.write(to: markdownURL, options: .atomic)
    }

    /// 读全部（新→旧）.
    static func readAll() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return readAllUnlocked().reversed()
    }

    private static func readAllUnlocked() -> [Entry] {
        guard let data = try? Data(contentsOf: jsonURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    /// 清空（只删记录，**不动设备上的文件**）.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: jsonURL)
        try? FileManager.default.removeItem(at: markdownURL)
    }

    /// 渲染成人可读的 markdown（SSH `cat` 直接看）.
    private static func renderMarkdown(_ all: [Entry]) -> String {
        var out = "# airlift 改动记录\n\n"
        out += "> 由 EscapeSpace 的 airlift 模块自动记录. 共 \(all.count) 条（新→旧）.\n"
        out += "> `verified` = 读回校验通过；`false` **不代表没写进去**（校验会被会话冷却影响）.\n\n"
        out += "| 时间 | 动作 | 目标 | 变化 | 字节 | 校验 |\n|---|---|---|---|---|---|\n"
        for e in all.reversed() {
            let detail = (e.detail ?? "").replacingOccurrences(of: "|", with: "\\|")
            out += "| \(e.time) | \(e.action) | `\(e.path)` | \(detail.isEmpty ? "—" : detail) | "
                + "\(e.bytes) | " + (e.verified ? "✓" : "—") + " |\n"
        }
        return out
    }

    /// 人可读文件的路径（给界面显示「记录在哪」用）.
    static var markdownPath: String { markdownURL.path }
}
