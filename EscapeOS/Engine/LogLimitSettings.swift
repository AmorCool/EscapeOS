import Foundation
import Combine

/// 日志相关的**可配置上限**（用户可在「更多 → 设置 → 日志」里改）。
///
/// ## 为什么做成可配置
/// 此前两处上限都写死在代码里，用户既拿不到完整内容、文件又会无限增长：
/// - `SSHServerService` 的 `cat` 硬编码 **256KB**；
/// - `LoginLogger` 的日志文件**完全没有上限**（实测涨到 683KB）。
///
/// 现在两项都可调，默认 **1024 KB**；输入框留空时自动恢复默认值。
@MainActor
final class LogLimitSettings: ObservableObject {
    static let shared = LogLimitSettings()

    /// 默认上限（KB）。输入框留空时回填这个值。
    static let defaultKB = 1024

    /// 日志**文件**存储上限（KB）—— 超过时滚动截断（保留最新部分）。
    nonisolated static let fileLimitKey = "LogLimit.maxFileKB"
    /// SSH `cat` 命令的读取上限（KB）。
    nonisolated static let catLimitKey = "LogLimit.maxCatKB"

    /// 日志文件上限（KB）.
    @Published var maxFileKB: Int {
        didSet { UserDefaults.standard.set(maxFileKB, forKey: Self.fileLimitKey) }
    }

    /// `cat` 读取上限（KB）.
    @Published var maxCatKB: Int {
        didSet { UserDefaults.standard.set(maxCatKB, forKey: Self.catLimitKey) }
    }

    private init() {
        let file = UserDefaults.standard.integer(forKey: Self.fileLimitKey)
        let cat = UserDefaults.standard.integer(forKey: Self.catLimitKey)
        self.maxFileKB = file > 0 ? file : Self.defaultKB
        self.maxCatKB = cat > 0 ? cat : Self.defaultKB
    }

    // MARK: - 线程安全读取（供后台线程 / SSH 命令用，不经 MainActor）

    /// 日志文件上限（字节）。**填 `0` 表示无限制。**
    nonisolated static var fileLimitBytes: Int {
        guard let raw = UserDefaults.standard.object(forKey: fileLimitKey) as? Int else {
            return defaultKB * 1024          // 从未设置 → 默认
        }
        if raw == 0 { return Int.max }       // 0 = 无限制
        return (raw > 0 ? raw : defaultKB) * 1024
    }

    /// `cat` 读取上限（字节）。**填 `0` 表示无限制。**
    nonisolated static var catLimitBytes: Int {
        guard let raw = UserDefaults.standard.object(forKey: catLimitKey) as? Int else {
            return defaultKB * 1024
        }
        if raw == 0 { return Int.max }
        return (raw > 0 ? raw : defaultKB) * 1024
    }

    /// 把输入框文本规整成合法 KB 值。
    ///
    /// - 空 / 非法 → 回落默认值（用户要求「为空自动改为 1024」）；
    /// - `0` → **保留为 0**（= 无限制）；
    /// - 其它正数 → 原样。
    nonisolated static func normalizedKB(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else { return defaultKB }
        return value
    }

    /// 给 UI 显示的大小说明（如 `1024 KB（= 1 MB）` / `无限制`）。
    nonisolated static func describe(kb: Int) -> String {
        if kb == 0 { return "无限制" }
        if kb % 1024 == 0 { return "= \(kb / 1024) MB" }
        return "= \(String(format: "%.1f", Double(kb) / 1024.0)) MB"
    }
}
