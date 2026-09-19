import Foundation

/// 登录诊断日志：把 Apple 认证引擎每一步的关键事件（请求/响应/错误）记录到
/// `Documents/LoginLogs/login.log`，支持在登录界面查看、复制与导出分享，便于排查
/// Anisette / GrandSlam 握手失败的真实原因.
/// `@unchecked Sendable`：本类是全项目（含后台隧道 / Rust 回调线程）共用的日志器。
/// 唯一可变状态 `buffer` 的每次读写都在 `lock`（`NSLock`）保护下
/// （`log` / `clear` / `fullLog` / `recentLines` 四个入口全部持锁），
/// 因此跨隔离域共享引用是安全的——复用类内已有的锁。
final class LoginLogger: @unchecked Sendable {
    static let shared = LoginLogger()

    /// v0.3.307：日志**按板块分类**，各板块只读自己那一类，不再互相串台.
    ///
    /// 之前所有模块共用一个缓冲区、共用一个日志页，导致 AppStore 商店的日志板块里
    /// 混着证书管理 / IPA 侧载 / 爱思源 等其它板块的输出（用户实测指正）。
    /// 现在每条日志带一个分类；`recentLines(_:category:)` 只取该分类的行。
    /// 未显式传分类的调用一律归入 `.general`（老代码不受影响）。
    enum Category: String, CaseIterable {
        case general = "通用"
        /// **AppStore 商店**（主页商店：登录 / 获取 / 下载 / 安装 / 账号管理）
        /// —— v0.3.311：原「更多 → AppStore 下载」板块已整体移除，AppStore 只剩这一个板块
        case appStore = "AppStore"
        /// **AppleID 登录 / 认证引擎**（SAP / GrandSlam / Anisette / 会话）。
        ///
        /// 为什么必须和 `.appStore` 拆开：这个分类此前被**两个板块共用** ——
        /// ① AppleID 登录/认证引擎（`Services/AppleAuth/` 的 SAP / GrandSlam / Anisette / 会话），
        /// ② AppStore 商店业务（商品页 / 版本历史 / 三方 API / 下载安装，全仓 100+ 处）。
        /// 结果就是「登录诊断日志」页里混着商店业务日志、商店页里混着登录握手日志，
        /// 两边都过滤不干净（用户实测指正）。拆开后各页只读自己那一类。
        case appleID = "AppleID 登录"
        case i4Store = "爱思源"
        case sideload = "侧载签名"
        case certificate = "证书管理"
    }

    private struct Entry {
        let line: String
        let category: Category
    }

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private let maxBufferLines = 500

    /// 日志文件位置（App 沙盒 Documents 内，LiveContainer 中同样可写、可被文件浏览器访问）.
    var logFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/LoginLogs")
            .appendingPathComponent("login.log")
    }

    private init() {
        // 启动时保证目录存在
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func log(_ message: String, category: Category = .general) {
        // v0.3.310：分类写进行首 —— 这样**文件里的历史日志**也能按板块过滤
        // （此前分类只在内存条目里，重启后按分类读文件读不到 → 板块日志页空白）
        let line = "[\(Self.timestamp())][\(category.rawValue)] \(message)"
        lock.lock()
        buffer.append(Entry(line: line, category: category))
        if buffer.count > maxBufferLines { buffer.removeFirst(buffer.count - maxBufferLines) }
        lock.unlock()
        appendToFile(line)
        // iOS 26 SDK 把 NSLog 的 variadic 形式标 unavailable，用 print 代替；
        // print 仍然进 Apple 系统日志（Console.app 可见），仅 path 不同（用户日常习惯差异）.
        print("[Login] \(message)")
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    /// 全部日志文本（内存缓冲 + 文件内容合并，去重）.
    func fullLog() -> String {
        lock.lock()
        let mem = buffer.map(\.line)
        lock.unlock()

        var fileLines: [String] = []
        if let data = try? Data(contentsOf: logFileURL),
           let text = String(data: data, encoding: .utf8) {
            fileLines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        let merged = mem + fileLines.filter { !mem.contains($0) }
        return merged.joined(separator: "\n")
    }

    /// 最近 n 行（纯内存读取，v0.3.268 供状态板块 2s 轮询实时展示登录过程）.
    func recentLines(_ n: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard n > 0 else { return [] }
        return buffer.suffix(n).map(\.line)
    }

    /// 只取指定分类的最近 n 行（板块日志隔离）。
    ///
    /// **必须读文件，不能只读内存缓冲**（本轮修正 —— 之前只读 `buffer`，是个真实缺陷）：
    /// `buffer` 是**全 App 共享**的、上限只有 `maxBufferLines`（500）行，而商店业务
    /// （`.appStore`，100+ 个写入点）一次下载就能把它刷满 ⇒ 低频分类（如 `.appleID`）
    /// 会被**整批挤出缓冲** ⇒ 「登录诊断日志」页会几乎空白。
    /// 本文件从 v0.3.310 起就把分类写进了**行首**（`[HH:mm:ss.SSS][分类] 正文`），
    /// 当时注释写的就是「这样**文件里的历史日志**也能按板块过滤」——
    /// 但 `logText` / `recentLines` 都只读内存，**那个意图一直没被实现**；这里把它补上。
    ///
    /// 性能：本方法被四个日志页 **2s 轮询**调用，所以文件**只读尾部**（见 `tailLines`），
    /// 不整文件读。
    func recentLines(_ n: Int, categories: [Category]) -> [String] {
        guard n > 0 else { return [] }
        let wanted = Set(categories.map(\.rawValue))

        lock.lock()
        let mem = buffer.map(\.line)
        lock.unlock()

        // 顺序 = 时间顺序（**最新的在最后**）：文件尾部（旧的在前）→ 再补上内存里
        // 还没落盘的行（正常为空；只有写文件失败时才可能非空，那时它本来就是最新的）。
        // ⚠️ 不要照 `fullLog()` 的 `mem + 文件` 顺序 —— 那是「最新的一块在最前」，
        // 日志页会把最后一行当作最新去自动滚底，顺序反了就会停在**最旧**的一行上。
        var all = tailLines()
        let inFile = Set(all)
        all.append(contentsOf: mem.filter { !inFile.contains($0) })

        return Array(all.filter { Self.category(of: $0).map(wanted.contains) ?? false }.suffix(n))
    }

    /// 读日志文件**尾部**并拆行（时间顺序，最新的在最后）。
    ///
    /// 为什么只读尾部：调用方（日志页）是 2s 轮询，而文件上限默认 1024KB
    /// （`LogLimitSettings.fileLimitBytes`，可配、可关）—— 每次整文件读 + 解码是白烧。
    /// 512KB 约等于 2000+ 行，与 `LogConsoleView.maxRenderedLines` 同量级，够用。
    private func tailLines() -> [String] {
        let cap = 512 * 1024
        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(cap) ? size - UInt64(cap) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return [] }

        var bytes = [UInt8](data)
        if offset > 0 {
            // 从任意字节偏移开始读，首行必然被截断 —— 而且**必须**从换行字节处切开：
            // 日志正文是中文（多字节 UTF-8），若从某个字符的中间字节开始解码，
            // 整个 `String(bytes:encoding:)` 会直接返回 nil（一行都拿不到）。
            guard let newline = bytes.firstIndex(of: 0x0A) else { return [] }
            bytes = Array(bytes[(newline + 1)...])
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// 从一行日志里取出**分类的 rawValue**。
    ///
    /// 行格式（见 `log(_:category:)`）：`[HH:mm:ss.SSS][分类] 正文`
    /// ⇒ 取**第二个**方括号里的内容。时间戳里不含 `]`，所以「找第一个 `]` 再找下一个 `[`」是安全的。
    /// 注意匹配的是 `rawValue`（中文，如 `"AppleID 登录"`），**不是** case 名。
    private static func category(of line: String) -> String? {
        guard line.hasPrefix("["), let firstClose = line.firstIndex(of: "]") else { return nil }
        let afterFirst = line.index(after: firstClose)
        guard afterFirst < line.endIndex, line[afterFirst] == "[" else { return nil }
        let rest = line[line.index(after: afterFirst)...]
        guard let secondClose = rest.firstIndex(of: "]") else { return nil }
        return String(rest[rest.startIndex..<secondClose])
    }

    /// v0.3.307：日志页文本。传 categories 则只显示这些分类（板块隔离）；
    /// 不传则返回合并文件的全量日志（导出/全局排查用）.
    func logText(categories: [Category]? = nil) -> String {
        guard let categories else { return fullLog() }
        return recentLines(10_000, categories: categories).joined(separator: "\n")
    }

    private func appendToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            // v0.3.434：超过用户设定的上限时**滚动截断**（保留最新部分），
            // 避免日志文件无限增长（此前实测涨到 683KB）。
            // 上限可在「更多 → 设置 → 日志」里改，默认 1024KB，**填 0 = 无限制**。
            let limit = LogLimitSettings.fileLimitBytes
            if limit < Int.max,                       // 无限制 → 不截断
               let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
               let size = attrs[.size] as? UInt64,
               size > UInt64(limit) {
                trimFile(to: limit)
            }
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    /// 把日志文件截到 `limit` 字节 —— **保留后半段**（即最新的日志）。
    ///
    /// 从换行处切开，避免留下半行。
    private func trimFile(to limit: Int) {
        guard let data = try? Data(contentsOf: logFileURL), data.count > limit else { return }
        let tail = data.suffix(limit)
        if let newline = tail.firstIndex(of: 0x0A) {
            let after = tail.index(after: newline)
            if after < tail.endIndex {
                try? Data(tail[after...]).write(to: logFileURL)
                return
            }
        }
        try? Data(tail).write(to: logFileURL)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
