import SwiftUI

/// 可展开的长文本 —— 折叠时最多显示 `collapsedLines` 行，超出部分**默认直接裁掉、不画省略号**
/// （`truncationStyle == .clip`），并在**确实被截断**时才给出「展开」按钮。
///
/// ## 为什么抽成共享组件
/// 仓库此前有 4 套各自为政的「展开 / 收起」：
/// `AppStoreVersionHistoryView` / `NBStoreDetailView` / `AppStoreDetailView` 三套用
/// `count > N` 的**字符数启发式**判断是否超长（会误判：短文本也可能占满 N 行、长文本也可能
/// 只占 N-1 行），且折叠态一律用 `lineLimit` ⇒ **画 `…`**；第 4 套（软件源页）改用
/// **实测高度**判定 + `frame(maxHeight:) + clipped()` ⇒ **不画 `…`**。
///
/// 用户硬要求（仓库既有注释 `I4StoreFreeView.swift:722-724`）：「可以换行显示但不能显示不全」
/// ⇒ 不画省略号是更合规的做法，故本组件**默认 `.clip`**。
///
/// ## 4 套的差异都留成参数（差异是刻意的排版选择，不强行抹平）
/// · `collapsedLines` —— 3 / 4 / 5 行各有其用（列表行 3 行、详情页 4~5 行）。
/// · `truncationStyle` —— `.clip`（默认，不画 `…`）或 `.ellipsis`（`lineLimit`，画 `…`，
///   **仅为兼容旧实现保留，新代码勿用**）。
/// · `font` / `foreground` / `buttonFont` / `buttonTint` / `animation` —— 各页排版差异。
/// · 按钮**位置**在 4 套里本就一致（正文下方、左对齐），故不留参数。
///
/// ## 首帧不跳变（沿用第 4 套的修法）
/// `.clip` 下，未测到折叠高度前可见文本先套 `lineLimit(collapsedLines)` —— 首帧就只画 N 行；
/// 测到后撤掉 `lineLimit`（它会画 `…`），改由 `frame(maxHeight:) + clipped()` 精确夹。
/// ⇒ 任何一帧的可见行数都 ≤ N（除用户已点「展开」），不存在旧实现「先全显一帧再收缩」的跳变。
///
/// ## 探针数量
/// `.clip`（默认）每行只挂 **1 个隐藏探针**（量「限 N 行」高度），全文高度由**可见文本自身**的
/// `.background(GeometryReader)` 量出（贴在 `frame` 之前，量的是不受夹子影响的自然高度）。
/// `.ellipsis` 下可见文本带 `lineLimit`、高度随展开态变化，不能用来量折叠高度，故改用
/// **2 个隐藏探针**（全文 / 折叠各一）—— 该分支仅为旧实现兼容，不在默认路径上。
struct ExpandableText: View {

    /// 折叠态的裁剪方式。
    enum TruncationStyle {
        /// 直接裁掉超出部分，**不画省略号**（默认；满足「不能显示不全」）。
        case clip
        /// `lineLimit` 截断，会画 `…` —— 仅为兼容旧实现保留，新代码勿用。
        case ellipsis
    }

    let text: String
    /// 折叠时最多显示的行数。
    var collapsedLines: Int = 3
    /// 折叠态裁剪方式（默认不画省略号）。
    var truncationStyle: TruncationStyle = .clip
    /// 正文字体。
    var font: Font = .caption2
    /// 正文颜色。
    var foreground: Color = .secondary
    /// 展开按钮标题。
    var expandTitle: String = "展开"
    /// 收起按钮标题。
    var collapseTitle: String = "收起"
    /// 展开按钮字体。
    var buttonFont: Font = .caption2.weight(.medium)
    /// 展开按钮颜色。
    var buttonTint: Color = .blue
    /// 展开 / 收起的动画；`nil` = 不加动画。
    var animation: Animation? = .easeInOut(duration: 0.18)

    @State private var expanded = false
    /// 「限 `collapsedLines` 行」时的真实高度；0 = 尚未测到。
    @State private var collapsedHeight: CGFloat = 0
    /// 全文（不限行数）的真实高度；0 = 尚未测到。
    @State private var fullHeight: CGFloat = 0

    /// 折叠高度是否已测到 —— `.clip` 未测到时由 `lineLimit(collapsedLines)` 兜底（首帧即 N 行）。
    private var hasCollapsedHeight: Bool { collapsedHeight > 0 }

    /// 只有「不限行」比「限 N 行」更高时，才说明被截断了。
    private var isTruncated: Bool { fullHeight > collapsedHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            visibleText
            if isTruncated { expandButton }
        }
        .background(probe)
        // 两处实测在本行汇合 —— `onPreferenceChange` 挂在**本行**上，写入本行 `@State`，
        // 只会让这一行重算，不上抛给列表触发全量重排。
        .onPreferenceChange(ExpandableTextHeightKey.self) { h in
            if h.full > 0 { fullHeight = h.full }
            if h.collapsed > 0 { collapsedHeight = h.collapsed }
        }
    }

    // MARK: - 正文

    @ViewBuilder
    private var visibleText: some View {
        switch truncationStyle {
        case .clip:
            Text(text)
                .font(font)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
                // 未测到折叠高度前：`lineLimit` 直接夹到 N 行 —— 首帧即 N 行，绝不先全显。
                // 测到后：撤掉 `lineLimit`（它会画 `…`），改由下面的 `frame(maxHeight:)` 精确夹。
                .lineLimit(expanded || hasCollapsedHeight ? nil : collapsedLines)
                // 全文高度：贴在 `frame` **之前**，量的是文本自然高度（不受夹子影响）。
                .background(GeometryReader { g in
                    Color.clear.preference(key: ExpandableTextHeightKey.self,
                                           value: ExpandableTextHeights(full: g.size.height))
                })
                // 折叠时把高度上限夹到「N 行」；超出部分由 `clipped()` 直接裁掉（**不画省略号**）。
                .frame(maxHeight: expanded ? nil : collapsedHeightOrNil, alignment: .top)
                .clipped()
        case .ellipsis:
            Text(text)
                .font(font)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(expanded ? nil : collapsedLines)
        }
    }

    /// 折叠时的高度上限：测到前返回 `nil`（此时由 `lineLimit(collapsedLines)` 兜底）。
    private var collapsedHeightOrNil: CGFloat? {
        hasCollapsedHeight ? collapsedHeight : nil
    }

    // MARK: - 展开按钮

    private var expandButton: some View {
        Button {
            if let animation {
                withAnimation(animation) { expanded.toggle() }
            } else {
                expanded.toggle()
            }
        } label: {
            Text(expanded ? collapseTitle : expandTitle)
                .font(buttonFont)
        }
        .buttonStyle(.plain)
        .foregroundStyle(buttonTint)
    }

    // MARK: - 高度探针

    @ViewBuilder
    private var probe: some View {
        switch truncationStyle {
        case .clip:
            // 唯一的隐藏探针：量「限 N 行」的高度（与可见文本同宽、同字体、同换行规则）。
            measuredProbe(lineLimit: collapsedLines) { ExpandableTextHeights(collapsed: $0) }
        case .ellipsis:
            measuredProbe(lineLimit: nil) { ExpandableTextHeights(full: $0) }
            measuredProbe(lineLimit: collapsedLines) { ExpandableTextHeights(collapsed: $0) }
        }
    }

    /// 隐藏探针：与可见文本同字体、同换行规则，量出高度后经 `make` 转成偏好值。
    private func measuredProbe(lineLimit: Int?,
                               _ make: @escaping (CGFloat) -> ExpandableTextHeights) -> some View {
        Text(text)
            .font(font)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(GeometryReader { g in
                Color.clear.preference(key: ExpandableTextHeightKey.self, value: make(g.size.height))
            })
    }
}

/// 一次布局里要实测的两个高度：全文（`full`）与限 N 行（`collapsed`）。
/// `Equatable` 供 `onPreferenceChange` 用；显式 `Sendable`（只含 `CGFloat`）保证
/// `ExpandableTextHeightKey.defaultValue` 这个 `static let` 满足 Swift 6 静态存储约束。
private struct ExpandableTextHeights: Equatable, Sendable {
    var full: CGFloat = 0
    var collapsed: CGFloat = 0
}

private struct ExpandableTextHeightKey: PreferenceKey {
    /// Swift 6 并发检查：`PreferenceKey.defaultValue` 协议要求是 `{ get }`，用 `static let` 即可满足，
    /// 且避免「可变静态存储」报错 —— `ExpandableTextHeights` 只含 `CGFloat`（Sendable）
    /// ⇒ 满足「静态存储必须是 Sendable」。
    static let defaultValue = ExpandableTextHeights()
    static func reduce(value: inout ExpandableTextHeights, nextValue: () -> ExpandableTextHeights) {
        let next = nextValue()
        value.full = max(value.full, next.full)
        value.collapsed = max(value.collapsed, next.collapsed)
    }
}
