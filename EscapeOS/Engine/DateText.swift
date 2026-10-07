import Foundation

/// 全 App 统一的**日期 / 时间展示工具**（纯 Foundation，无 UI 依赖）。
///
/// ## 为什么要有它
/// 此前各页面各自 `new DateFormatter`，口径不一；更有几处把后端返回的 **ISO8601 原始串**
/// 直接塞进界面（用户截图里出现 `2026-09-13T16:59:22+08:00`）。本工具把「解析 + 格式化」
/// 收拢到一处，并统一为两种展示口径（见 `Style`）。
///
/// ## 铁律
/// · **解析失败返回 `nil`** —— 绝不把原始串回退到界面上（宁可少显示一行，也不显示机器串）.
/// · 展示一律用**设备本地时区**，与下载列表（`MM-dd HH:mm`）等既有页面一致.
enum DateText {

    /// 展示口径。
    enum Style {
        /// `MM-dd HH:mm` —— 紧凑格式，全 App 默认（下载列表 / 图标清理 / 软件源胶囊同款）.
        case compact
        /// `yyyy-MM-dd` —— 只到「日」；用于**纯日期**数据（版本快照日等，本就没有时刻可显示）.
        ///
        /// 保留年份的理由：版本历史**跨年**，去掉年份会让 `2024-10-05` 与 `2025-10-05`
        /// 无法区分；且源数据本身无时刻，套 `MM-dd HH:mm` 会凭空造出 `00:00`.
        case day
    }

    // MARK: - 解析

    /// 把原始时间串解析成 `Date`；**全部形态都失败时返回 `nil`**（不抛错、不猜、不回退原始串）.
    ///
    /// 兼容的输入形态（前 5 种取自本项目真实数据，后 2 种为字段形态未实测时的防御兜底）：
    ///
    /// | 形态 | 真实样例 | 出处 |
    /// |---|---|---|
    /// | 时区偏移（带冒号） | `2026-09-13T16:59:22+08:00` | 审计报告 B 节 P0 截图 |
    /// | 时区偏移（无冒号） | `2026-09-30T10:00:00+0800` | 源探针 `appUpdateTime` |
    /// | 毫秒 + `Z` | `2026-10-06T08:51:55.070Z` | 日志时间戳 |
    /// | 无毫秒 + `Z` | `2026-09-13T16:59:22Z` | Apple RSS `currentVersionReleaseDate` |
    /// | 纯日期 | `2025-06-06` | 爱思 `releasetime`（`I4PCStoreClient.swift:87`） |
    /// | 无时区 ISO | `2025-06-06T10:00:00` | 防御 |
    /// | 空格分隔 | `2025-06-06 10:00:00` | 防御（`UpdateTime` 形态未实测） |
    static func date(from raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        // ISO8601：带毫秒的必须先试（`isoPlain` 不接受毫秒；`isoFractional` 也不接受无毫秒）.
        if let d = isoFractional.date(from: raw) { return d }
        if let d = isoPlain.date(from: raw) { return d }
        for f in fallbacks {
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// 解析 + 格式化；**解析失败返回 `nil`**（调用方据此决定「不显示」，而非显示原始串）.
    static func string(from raw: String?, style: Style = .compact) -> String? {
        guard let date = date(from: raw) else { return nil }
        return formatter(for: style).string(from: date)
    }

    /// 直接格式化一个**已有 `Date`**（不经解析）—— 供「数据源本身就是 `Date`」的展示点收敛到本工具
    /// （版本历史 / 收藏栏等原先各自持有 `DateFormatter`）。与 `string(from:style:)` 口径完全一致.
    static func string(from date: Date, style: Style = .compact) -> String {
        formatter(for: style).string(from: date)
    }

    // MARK: - 私有

    /// Swift 6 并发检查：`ISO8601DateFormatter` / `DateFormatter` 都不是 Sendable，
    /// 无法作为共享静态实例（否则报 `#MutableGlobalVariable` / 非 Sendable 静态存储）。
    /// 与 `AppleAuthenticator.dateFormatter` 同款规避：改为**按需构造的计算属性**。
    /// 这些 formatter 原本就是「构造后不再修改」，输出与配置完全一致，只是不再共享同一个对象。
    /// 调用点在列表行渲染里，单次构造开销可忽略。
    private static var isoFractional: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static var isoPlain: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// 非严格 ISO 的兜底（`en_US_POSIX` 固定历法，避免用户设备日历干扰）.
    private static var fallbacks: [DateFormatter] {
        ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }

    /// 输出格式化器：时区留空 = 设备本地，与 `IPADownloadManagerView` 的惯例一致.
    private static func formatter(for style: Style) -> DateFormatter {
        switch style {
        case .compact:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MM-dd HH:mm"
            return f
        case .day:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }
    }
}
