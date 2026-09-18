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

    /// 日志文件上限（字节）.
    nonisolated static var fileLimitBytes: Int {
        let value = UserDefaults.standard.integer(forKey: fileLimitKey)
        return (value > 0 ? value : defaultKB) * 1024
    }

    /// `cat` 读取上限（字节）.
    nonisolated static var catLimitBytes: Int {
        let value = UserDefaults.standard.integer(forKey: catLimitKey)
        return (value > 0 ? value : defaultKB) * 1024
    }

    /// 把输入框文本规整成合法 KB 值：空 / 非法 / ≤0 一律回落到默认值。
    nonisolated static func normalizedKB(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return defaultKB }
        return value
    }
}
