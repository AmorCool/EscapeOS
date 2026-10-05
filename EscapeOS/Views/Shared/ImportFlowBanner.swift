import SwiftUI

// 共享转换 ·「导入 → 修补 → 安装」步骤条（用户需求 #5）.
//
// 用户原话：「那个『导入』-『修补』-『安装』的 banner **要常驻**，『共享转换』里的**二级菜单也要显示**，
// 因为是来看状态的」⇒ 抽成**共享组件**，主页与三个二级页共用，观感一致。
//
// 定位：**纯展示，不持有任何业务状态**。调用方传「当前处于哪一段」（高亮）+ 可选进度，其余交给本组件画。
// 画法照抄 `ImportView.flowSection`（圆点 + 图标 + 标题 + chevron 连接；已完成的段自动打勾），
// 故 `impl-importview` 可把主页的 `flowSection` 直接换成 `ImportFlowBanner(...)` 而不改变观感。
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
///   - progress: 可选进度，如 `(current: 1, total: 14)` ⇒ 显示进度条与「1/14」。
///   - caption: 可选补充说明（如「正在安装」）；仅在 `progress` 非空时显示。
///   - footer: 页脚说明。默认与主页一致；传 `nil` 表示不显示页脚。
struct ImportFlowBanner: View {

    var stage: ImportFlowStage
    var progress: (current: Int, total: Int)? = nil
    var caption: String? = nil
    var footer: String? = "三步都需你确认，包来源要可信."

    var body: some View {
        Section {
            HStack(spacing: 0) {
                step(.importFile)
                arrow
                step(.repair)
                arrow
                step(.install)
            }
            .padding(.vertical, 6)

            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        ProgressView(value: Double(max(0, progress.current)),
                                     total: Double(max(1, progress.total)))
                            .progressViewStyle(.linear)
                        Text("\(progress.current)/\(progress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .padding(.bottom, 2)
            }
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    // MARK: - 单段

    private enum StepState {
        case idle, active, done

        var tint: Color {
            switch self {
            case .idle:   return .secondary
            case .active: return AppTheme.accent
            case .done:   return LocusTheme.statusGood
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
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(s.tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: s == .done ? "checkmark" : target.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(s.tint)
            }
            Text(target.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(s.tint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}
