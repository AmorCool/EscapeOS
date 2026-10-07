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

    // MARK: - 私有（缓存）

    // ## 为什么用 `nonisolated(unsafe)` 缓存，而不是每次新建
    //
    // `DateFormatter` / `ISO8601DateFormatter` 的**构造很贵**（要建 locale / calendar / ICU 数据）。
    // 此前把它们写成「按需构造的计算属性」是为了过 Swift 6 严格并发，代价是**每次调用都新建**：
    // 源 App 列表页（`SignSourceAppListView`，逐行调用）在 34 / 3911 / 28026 行的源上，
    // 每行要新建 2 个 `ISO8601DateFormatter` + 1 个 `DateFormatter` —— 逐行开销（实测见
    // `P4_全能签逆向/_impl/修复_日期性能回退.md`）。
    //
    // ## 为什么这样是并发安全的（不是随手 `unsafe`）
    // · 这些是 **`let`**：只在首次访问时构造一次，此后**永不重新赋值**；
    // · 构造之后**只读**：本类型的全部代码只调用它们的 `date(from:)` / `string(from:)`，
    //   从不修改 `dateFormat` / `locale` / `formatOptions`（grep 本文件即可确认）；
    // · 对**已配置完成、不再修改**的 formatter 做**并发只读**是受支持的用法：
    //   `DateFormatter` 自 iOS 7 / macOS 10.9 起即为线程安全；`ISO8601DateFormatter` 同样
    //   在配置后无可变状态，`date(from:)` / `string(from:)` 内部不写回实例。
    // ⇒ 多线程同时调用只是「并发读同一个不可变对象」，无数据竞争。
    //
    // ## 为什么不用 `@MainActor` 缓存
    // 已 grep 全部 13 个调用点：其中 `AppStoreModels.dateText` 经 `NBStoreClient.versionList`
    // （`enum` 的 nonisolated `async static func`）在**后台线程**上调用 ⇒ `@MainActor` 会把
    // 该非主线程路径一并要求隔离，属改对外 API 语义，不可取。故用 `nonisolated(unsafe)` 保持
    // 对外 API（`date(from:)` / `string(from:style:)`）的 nonisolated 签名完全不变。
    // 与本仓既有先例同款：`AFCService.swift:16`、`AppStoreService.swift:332`。

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 非严格 ISO 的兜底（`en_US_POSIX` 固定历法，避免用户设备日历干扰）.
    nonisolated(unsafe) private static let fallbacks: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    /// 输出格式化器：时区留空 = 设备本地，与 `IPADownloadManagerView` 的惯例一致.
    nonisolated(unsafe) private static let compactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func formatter(for style: Style) -> DateFormatter {
        switch style {
        case .compact: return compactFormatter
        case .day: return dayFormatter
        }
    }
}
