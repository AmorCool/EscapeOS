import SwiftUI
import UIKit

/// Shared visual language for EscapeOS. Ported and adapted from 3105's
/// DesignSystem: a blue accent, a tinted rounded icon, and reclaim-specific
/// category styling. Uses EscapeOS's own model fields (no localization system).
enum AppTheme {
    /// Brand accent. System blue (semantic), adapts to light/dark mode.
    /// 之前是暖橙，在浅色玻璃背景下显脏棕，按用户审美改为系统蓝.
    static let accent = Color(uiColor: .systemBlue)
    static let pageInset: CGFloat = 16
    static let appIconSize: CGFloat = 44

    // MARK: - 语义状态色
    //
    // 全部取 UIKit 语义色，自动适配明暗模式. 此前共享转换模块跨模块借用了
    // `LocusTheme`（虚拟定位页主题），而 `LocusTheme` 是硬编码 sRGB、不随明暗
    // 模式变化，深色下对比度不足. 这四个 token 是让共享转换退出 `LocusTheme`
    // 的落点 —— 只新增实际用到的，不建完整的 spacing / typography / radius 体系.

    /// 已完成 / 已修补.
    static let success = Color(uiColor: .systemGreen)
    /// 待处理 / 待修补.
    static let pending = Color(uiColor: .systemOrange)
    /// 失败 / 错误.
    static let danger = Color(uiColor: .systemRed)
    /// 未选中态的图标灰（选择圈、占位图形）.
    static let unselected = Color.secondary.opacity(0.5)
    /// 选择圈图标尺寸（已导入 / 待修补 / 已修补三页共用）.
    static let selectionIconSize: CGFloat = 20
}

/// 「透明淡蓝」按钮样式（用户审美：不要纯蓝实底，要淡一点的蓝底）.
///
/// 只加这一个样式，不另造体系：前景取品牌蓝 `AppTheme.accent`（`Color(uiColor: .systemBlue)`，
/// 语义色、随明暗模式自适应），背景取**同一色低透明度** —— 与 `AppRowIcon` / `SizePill` /
/// `PackageChip` / `ImportFlowBanner` 的 `tint.opacity(...)` 是同一口径（本仓既有的
/// 「淡底 + 同色前景」语言）。全程**不写死 RGB**，只用语义色 + 不透明度.
///
/// 与 `.borderedProminent` 的差别：后者是**实底**（用户不喜欢的纯蓝背景），本样式是**淡底**。
///
/// 明暗辨识度（本轮修正）：固定 12% 淡底在**深色背景**上几乎与背景同色，按钮边界辨识度弱。
/// 故按 `colorScheme` 分档：浅色维持 12%，深色提到 22%（按下再提一档作为反馈，替代实底样式的
/// 自动变暗）；并补一圈**发丝描边**（同为 `tint` 语义色），即便淡底与背景相近也有一条清晰边界.
///
/// 与同排次要按钮（`.bordered`）的风格对齐（本轮修正）：圆角 10 → 8（对齐系统 `.bordered` 常规号）、
/// 字号 `subheadline`(15) → `body`(17)（对齐 `.bordered` 的默认字号）、常规号竖向内边距 8 → 6
/// （使总高 ≈ `.bordered` 的 34pt）。小号（卡片内动作，无 `.bordered` 同排）维持原度量.
struct TintedButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, tint: tint)
    }

    /// 样式体单独成一个 `View`：只有 `View` 能读 `@Environment`，用它在**禁用**时降透明度
    /// （自定义 `ButtonStyle` 不会像 `.borderedProminent` 那样自动置灰）.
    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.colorScheme) private var colorScheme

        /// 尺寸随 `controlSize` 缩放：小号用于卡片内动作，常规号用于批量底条.
        private var small: Bool { controlSize == .small }
        /// 圆角与同排 `.bordered` 次要按钮对齐：常规号取 8（系统 `.bordered` 常规号口径）.
        private var radius: CGFloat { small ? 7 : 8 }
        private var hPad: CGFloat { small ? 10 : 14 }
        /// 常规号 6：配合 `body` 字号使总高 ≈ `.bordered` 常规号的 34pt，同排不显高矮不齐.
        private var vPad: CGFloat { small ? 5 : 6 }
        /// 深色下淡底几乎与背景同色 ⇒ 不透明度分档；浅色维持既有 12% 口径.
        private var fillOpacity: Double { colorScheme == .dark ? 0.22 : 0.12 }
        private var pressedOpacity: Double { colorScheme == .dark ? 0.34 : 0.24 }
        /// 发丝描边不透明度：给淡底补一条清晰边界（同为 `tint` 语义色，不写死 RGB）.
        private var strokeOpacity: Double { colorScheme == .dark ? 0.45 : 0.25 }

        var body: some View {
            configuration.label
                // 常规号对齐 `.bordered` 默认字号（body），小号（卡片内动作）维持 subheadline.
                .font(small ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(tint.opacity(configuration.isPressed ? pressedOpacity : fillOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(tint.opacity(strokeOpacity), lineWidth: 0.5)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

/// Tinted rounded-rectangle icon used for category rows in the reclaim views.
struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = 17
    var frameSize: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

/// A card with a tinted icon, title, message, and optional action button.
/// Used for empty / error / prompt states across the app so every tab shares
/// the same visual language.
struct InfoActionCard: View {
    let icon: String
    var iconTint: Color = AppTheme.accent
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var disabled: Bool = false
    /// 动作按钮是否用「透明淡蓝」（`TintedButtonStyle`）。默认 `false` ⇒ 维持系统
    /// `.borderedProminent` 实底，**不动其它页面**的既有观感；共享转换的空态按钮传 `true`.
    var actionTinted: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppRowIcon(systemName: icon, tint: iconTint, symbolSize: 20, frameSize: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = actionTitle, let action = action {
                    // 两种样式各写一遍（而非改全局默认）：只有显式要求淡蓝的调用点变，
                    // 其余页面的空态按钮维持 `.borderedProminent` 实底不变.
                    if actionTinted {
                        Button(action: action) {
                            Text(actionTitle)
                        }
                        .buttonStyle(TintedButtonStyle())
                        .controlSize(.small)
                        .disabled(disabled)
                        .padding(.top, 2)
                    } else {
                        Button(action: action) {
                            Text(actionTitle)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .disabled(disabled)
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// A small pill that highlights a byte count with a tinted background.
struct SizePill: View {
    let text: String
    var tint: Color = AppTheme.accent

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Reclaim category styling

extension ReclaimRisk {
    /// Visual role color: safe = green, session = amber, kept = grey.
    var tint: Color {
        switch self {
        case .safe: return Color.green
        case .session: return Color.orange
        case .kept: return Color.secondary
        }
    }
}

extension ReclaimCategory {
    /// SF Symbol matching each reclaim bucket, mirroring 3105's intent.
    /// The runtime `UIImage(systemName:)` guard protects against missing
    /// glyphs on older iOS builds (observed: `cookie` not rendering on some
    /// iOS 18.0 devices), falling back to a safe generic icon so the row
    /// never shows a blank tile.
    var symbol: String {
        switch id {
        case "tmp": return "clock"
        case "caches": return "internaldrive"
        case "logs": return "doc.text"
        case "splash": return "photo"
        case "gpucache": return "cpu"
        case "cookies":
            return safeSymbol(named: "cookie", fallback: "doc.text")
        case "http": return "globe"
        case "webkit": return "safari"
        case "savedstate": return "arrow.clockwise"
        case "documents": return "doc"
        case "preferences": return "gearshape"
        case "appsupport": return "folder"
        default: return "questionmark"
        }
    }

    private func safeSymbol(named primary: String, fallback: String) -> String {
        UIImage(systemName: primary) != nil ? primary : fallback
    }
}

// MARK: - Sharing

/// Identifiable wrapper for a file URL we want to share.
struct ShareTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// System share sheet (`UIActivityViewController`) for exporting a file
/// via AirDrop, Files, etc.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
