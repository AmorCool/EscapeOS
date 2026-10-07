import SwiftUI

// 共享组件 · 胶囊自动换行布局。
//
// 由 `I4StoreFreeView.swift` 的 file-private 实现提升而来（原实现另在
// `SignSourceAppListView.swift` 内整份复制了一份，因该文件被并行占用，本轮不迁）。
// 提升后调用点共用同一份实现，实现体逐字节不变 ⇒ 渲染结果零变化。

/// 一颗胶囊（文本 + 着色），供 `ChipFlow` 使用。
struct ChipItem {
    let text: String
    let tint: Color
}

/// 一行放得下就横排，放不下就把**整个胶囊**挪到下一行 ——
/// 不缩字号、不折行内文字、不截断。
///
/// 用 `HStack` 做不到这件事：空间不足时它会把 `Text` 压成竖排（真机截图里
/// `v8.0.78` 变成 `v8.0.` / `78` 两行就是这个原因）。
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > limit {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widest, limit), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
