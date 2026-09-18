import Foundation
import Combine

/// 日志相关的**可配置上限**（用户可在「更多 → 设置 → 日志」里改）。
///
/// ## 为什么做成可配置
/// 此前两处上限都写死在代码里，用户既拿不到完整内容、文件又会无限增长：
/// - `SSHServerService` 的 `cat` 硬编码 **256KB**；
/// - `LoginLogger` 的日志文件**完全没有上限**（实测涨到 683KB）。
///
/// 现在两项都可调，**单位 MB，默认 1 MB**；输入框留空时自动恢复默认值；
/// **填 `0` 表示无限制**。
///
/// ⚠️ 本类是 `@MainActor`，所以**所有被 `nonisolated` 方法引用的 static 常量
/// 都必须显式标 `nonisolated`**（否则会报
/// "main actor-isolated static property ... can not be referenced from a nonisolated context"）。
@MainActor
final class LogLimitSettings: ObservableObject {
    static let shared = LogLimitSettings()

    /// 默认上限（**MB**）。输入框留空时回填这个值。
    /// `nonisolated`：被下面的 `nonisolated static` 读取函数引用。
    nonisolated static let defaultMB = 1

    /// 日志**文件**存储上限（MB）—— 超过时滚动截断（保留最新部分）。
    /// `nonisolated`：被 `nonisolated static` 读取函数引用。
    nonisolated static let fileLimitKey = "LogLimit.maxFileMB"
    /// SSH `cat` 命令的读取上限（MB）。
    nonisolated static let catLimitKey = "LogLimit.maxCatMB"

    private static let bytesPerMB = 1024 * 1024

    /// 日志文件上限（MB，0 = 无限制）.
    @Published var maxFileMB: Int {
        didSet { UserDefaults.standard.set(maxFileMB, forKey: Self.fileLimitKey) }
    }

    /// `cat` 读取上限（MB，0 = 无限制）.
    @Published var maxCatMB: Int {
        didSet { UserDefaults.standard.set(maxCatMB, forKey: Self.catLimitKey) }
    }

    private init() {
        // 注意：这里用 object(forKey:) 而不是 integer(forKey:) —— 后者对"未设置"和"设为 0"都返回 0，
        // 无法区分「从未设置」与「用户选了无限制」。
        let file = UserDefaults.standard.object(forKey: Self.fileLimitKey) as? Int
        let cat = UserDefaults.standard.object(forKey: Self.catLimitKey) as? Int
        self.maxFileMB = file ?? Self.defaultMB
        self.maxCatMB = cat ?? Self.defaultMB
    }

    // MARK: - 线程安全读取（供后台线程 / SSH 命令用，不经 MainActor）

    /// 日志文件上限（字节）。**填 `0` 表示无限制**（返回 `Int.max`）。
    nonisolated static var fileLimitBytes: Int {
        guard let raw = UserDefaults.standard.object(forKey: fileLimitKey) as? Int else {
            return defaultMB * bytesPerMB          // 从未设置 → 默认
        }
        if raw == 0 { return Int.max }             // 0 = 无限制
        return raw * bytesPerMB
    }

    /// `cat` 读取上限（字节）。**填 `0` 表示无限制**（返回 `Int.max`）。
    nonisolated static var catLimitBytes: Int {
        guard let raw = UserDefaults.standard.object(forKey: catLimitKey) as? Int else {
            return defaultMB * bytesPerMB
        }
        if raw == 0 { return Int.max }
        return raw * bytesPerMB
    }

    /// 把输入框文本规整成合法 MB 值。
    ///
    /// - 空 / 非法 → 回落默认值（用户要求「为空自动改回默认」）；
    /// - `0` → **保留为 0**（= 无限制）；
    /// - 其它非负数 → 原样。
    nonisolated static func normalizedMB(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else { return defaultMB }
        return value
    }

    /// 给 UI 显示的大小说明（如 `= 1024 KB` / `无限制`）。
    nonisolated static func describe(mb: Int) -> String {
        if mb == 0 { return "无限制" }
        return "= \(mb * 1024) KB"
    }
}
