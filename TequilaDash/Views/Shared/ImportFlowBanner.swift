import SwiftUI

// 共享转换 ·「导入 → 修补 → 安装」步骤条（用户需求 #5）.
//
// 用户原话：「那个『导入』-『修补』-『安装』的 banner **要常驻**，『共享转换』里的**二级菜单也要显示**，
// 因为是来看状态的」⇒ 抽成**共享组件**，主页与三个二级页共用，观感一致。
//
// 用户第 2 条澄清：「**我说的是你在 banner 里对应步骤显示进度**」
//   ⇒ 进度必须画在**步骤条里对应的那一段**上（当前段旁边），**不是**步骤下方另起一个进度区。
//
// 定位：**纯展示，不持有任何业务状态**。调用方传「当前处于哪一段」（高亮）+ 可选进度，其余交给本组件画。
//
// 进度两种来源（同时给出时以 `progress` 为准）：
//   · `progress: (current: Int, total: Int)?` —— **批量**进度（如「批量修补 1/14」）；
//   · `fraction: Double?`                     —— **单包**进度（0…1，如导入一个包的复制进度）；
//   · `indeterminate: Bool`                   —— 无确定进度时的转圈（如复制 / 解析阶段）。
//
// 形态：`body` 是一整个 `Section`，直接放进 `List` 即可（与 `ImportView.flowSection` 同型）。

/// 流程三段。顺序即 `rawValue`，用于推导「已完成 / 进行中 / 未开始」。
enum ImportFlowStage: Int, CaseIterable, Sendable {
    case importFile = 0
    case repair = 1
    case install = 2

    var title: String {
        switch self {
        case .importFile: return "导入"
        case .repair:     return "修补"
        case .install:    return "安装"
        }
    }

    var symbol: String {
        switch self {
        case .importFile: return "square.and.arrow.down"
        case .repair:     return "wrench.and.screwdriver"
        case .install:    return "checkmark.circle"
        }
    }
}

/// 「导入 → 修补 → 安装」步骤条（常驻）。
///
/// - Parameters:
///   - stage: 当前所处的段（高亮）；更早的段显示为已完成（打勾），更晚的段为未开始。
///   - progress: 可选**批量**进度，如 `(current: 1, total: 14)` ⇒ 在**当前段**下方显示进度条与「1/14」。
///   - fraction: 可选**单包**进度（0…1）⇒ 在**当前段**下方显示进度条与百分比。`progress` 优先。
///   - indeterminate: 无确定进度时在当前段下方显示转圈（如复制 / 解析阶段）。有 `progress` / `fraction` 时忽略。
///   - caption: 可选补充说明（如「正在修补：xxx」）；仅在当前段有进度显示时出现。
///   - footer: 页脚说明。默认与主页一致；传 `nil` 表示不显示页脚。
struct ImportFlowBanner: View {

    var stage: ImportFlowStage
    var progress: (current: Int, total: Int)? = nil
    var fraction: Double? = nil
    var indeterminate: Bool = false
    var caption: String? = nil
    var footer: String? = "三步都需你确认，包来源要可信."

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 0) {
                step(.importFile)
                arrow
                step(.repair)
                arrow
                step(.install)
            }
            .padding(.vertical, 6)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    // MARK: - 当前段进度

    /// 当前段的进度形态；无进度时返回 nil（不显示）。
    private enum ActiveProgress {
        /// 确定进度：`value / total`，附一句读数（批量「1/14」或单包「45%」）。
        case determinate(value: Double, total: Double, text: String)
        /// 不确定态：转圈。
        case indeterminate
    }

    /// 当前段的进度（批量 `progress` 优先，其次单包 `fraction`，再次 `indeterminate`）。
    private var activeProgress: ActiveProgress? {
        if let progress {
            let cur = max(0, progress.current)
            let tot = max(1, progress.total)
            return .determinate(value: Double(cur), total: Double(tot), text: "\(cur)/\(tot)")
        }
        if let fraction {
            let f = min(1, max(0, fraction))
            return .determinate(value: f, total: 1, text: "\(Int((f * 100).rounded()))%")
        }
        if indeterminate { return .indeterminate }
        return nil
    }

    // MARK: - 单段

    private enum StepState {
        case idle, active, done

        var tint: Color {
            switch self {
            case .idle:   return .secondary
            case .active: return AppTheme.accent
            case .done:   return AppTheme.success
            }
        }
    }

    private func state(of target: ImportFlowStage) -> StepState {
        if target.rawValue < stage.rawValue { return .done }
        if target.rawValue == stage.rawValue { return .active }
        return .idle
    }

    private func step(_ target: ImportFlowStage) -> some View {
        let s = state(of: target)
        // 进度只画在**当前段**上（用户原话：在 banner 里对应步骤显示进度）。
        let active: ActiveProgress? = (s == .active) ? activeProgress : nil
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(s.tint.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: s == .done ? "checkmark" : target.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(s.tint)
            }
            Text(target.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(s.tint)

            if let active {
                progressBlock(active)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// 当前段下方的进度块（进度条 / 转圈 + 读数 + 说明）。
    @ViewBuilder
    private func progressBlock(_ active: ActiveProgress) -> some View {
        switch active {
        case .determinate(let value, let total, let text):
            ProgressView(value: value, total: total)
                .progressViewStyle(.linear)
                .frame(maxWidth: 72)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        case .indeterminate:
            ProgressView()
                .controlSize(.small)
        }
        if let caption, !caption.isEmpty {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            // 顶部对齐（各段高度可能因进度块不同），箭头垂直居中于圆点（圆点高 34）。
            .padding(.top, 11)
    }
}
