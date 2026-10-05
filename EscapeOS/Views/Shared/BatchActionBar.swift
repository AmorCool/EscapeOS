import SwiftUI

// 通用批量操作底条（用户需求 #4：批量操作参考「空间回收」的底部设计）.
//
// 从 `ReclaimTabView.batchBar`（`Views/ReclaimTabView.swift:245-267`）抽出，**视觉原样保留**：
//   左侧「已选 N 项」+ 副标题（如合计字节），右侧主按钮 `.borderedProminent` + `.tint(AppTheme.accent)`；
//   容器 `.padding()` + `.padding(.bottom, 18)` + `.frame(maxWidth: .infinity)` + `.background(.bar)`.
//
// 抽出而非改 `ReclaimTabView`：后者继续用自己的私有 `batchBar`，行为与观感**零改动**；
// 本组件只服务新二级页（已导入 / 待修补 / 已修补）。
//
// 挂载方式（照 `ReclaimTabView.swift:61-69`）：在页面的 `.safeAreaInset(edge: .bottom)` 里，
// **仅在选择态**挂本组件；未进选择态用 `Color.clear.frame(height: 12)` 占位（避免列表末项顶到底栏）。

/// 通用批量操作底条。
///
/// - Parameters:
///   - selectedCount: 已选数量，左侧「已选 N 项」。
///   - subtitle: 副标题（可选，如合计字节 / 合计大小）。为空时不占位。
///   - primaryTitle: 主按钮标题。
///   - primaryDisabled: 主按钮是否禁用。
///   - primaryAction: 主按钮动作。
///   - actions: 主按钮**左侧**的附加动作（如「移除」/「导出」）。留空则不占位。
struct BatchActionBar<Actions: View>: View {

    let selectedCount: Int
    let subtitle: String?
    let primaryTitle: String
    let primaryDisabled: Bool
    let primaryAction: () -> Void
    let actions: () -> Actions

    init(selectedCount: Int,
         subtitle: String? = nil,
         primaryTitle: String,
         primaryDisabled: Bool = false,
         primaryAction: @escaping () -> Void,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.selectedCount = selectedCount
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.primaryAction = primaryAction
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedCount) 项")
                    .font(.subheadline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            actions()
            Button(primaryTitle, action: primaryAction)
                .disabled(primaryDisabled)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
        }
        .padding()
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

extension BatchActionBar where Actions == EmptyView {
    /// 无附加动作的便捷构造（只有主按钮）。
    init(selectedCount: Int,
         subtitle: String? = nil,
         primaryTitle: String,
         primaryDisabled: Bool = false,
         primaryAction: @escaping () -> Void) {
        self.selectedCount = selectedCount
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.primaryAction = primaryAction
        self.actions = { EmptyView() }
    }
}
