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

    // MARK: - TRApp 风格语义色（新增）
    //
    // 对照 TRApp 逆向结论（`P4_全能签逆向/_简报/逆向_TRApp的UI.md`）：TRApp 只有 7 个
    // 自定义语义色，其余全走系统语义色。本仓已有 success / pending / danger，这里补齐
    // warning / mark 两个缺口，口径与既有四个 token 一致（`Color(uiColor:)` 语义色，随
    // 明暗模式自适应，不写死 RGB）.

    /// 警示 / 需注意.
    static let warning = Color(uiColor: .systemYellow)
    /// 高亮 / 标记（强调性标注、关键数值底色）.
    static let mark = Color(uiColor: .systemPink)

    // MARK: - 品牌渐变（新增）
    //
    // 取自 TRApp AppIcon 解码实测：深藏青竖向渐变 `#2C3A6A → #161F2E` + 纯白图形.
    // **仅新增常量供新页面的 hero 区块使用，不替换既有 `accent`**：全 App 主色替换
    // 会牵动 `TintedButtonStyle` / `AppRowIcon` / `SizePill` 等已锚定语义色的组件，
    // 影响面大且非本次目标，故保持 `accent` 为 `systemBlue` 不变.

    /// 品牌深藏青（TRApp AppIcon 实测主色 `#2C3A6A`）.
    static let brandNavy = Color(red: 0x2C / 255, green: 0x3A / 255, blue: 0x6A / 255)
    /// 品牌渐变（`#2C3A6A → #161F2E`，竖向）.
    static let brandGradient = LinearGradient(
        colors: [
            Color(red: 0x2C / 255, green: 0x3A / 255, blue: 0x6A / 255),
            Color(red: 0x16 / 255, green: 0x1F / 255, blue: 0x2E / 255)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - TRApp 实测语义色（本轮从 Assets.car 解出）
    //
    // 上一轮只拿到命名色的**名称**；本轮用 `car-unpacker-py`（纯 Python，BOMStore + RLOC
    // float64 分量）解 `Assets.car`，拿到 TRApp 7 个命名色的**真实 RGB**（取自 flat-ui 调色板）。
    // 这是品牌实测值，故直接写死 sRGB；**仅供新页面使用**，不动既有 `success/pending/danger/
    // warning/mark`（那四个仍走系统语义色，全 App 影响面大）.
    // 证据：`P4_全能签逆向/_简报/实现_TRApp风格落地爱思移动端页.md` §①.

    /// TRApp 强调色（实测 `#005493`）.
    static let trAccent = Color(red: 0x00 / 255, green: 0x54 / 255, blue: 0x93 / 255)
    /// TRApp 成功色（实测 `#6AB04C`）.
    static let trSuccess = Color(red: 0x6A / 255, green: 0xB0 / 255, blue: 0x4C / 255)
    /// TRApp 失败色（实测 `#E74C3C`）.
    static let trDanger = Color(red: 0xE7 / 255, green: 0x4C / 255, blue: 0x3C / 255)
    /// TRApp 警示色（实测 `#F9CA24`）.
    static let trWarning = Color(red: 0xF9 / 255, green: 0xCA / 255, blue: 0x24 / 255)
    /// TRApp 可恢复色（实测 `#008974`）.
    static let trRecoverable = Color(red: 0x00 / 255, green: 0x89 / 255, blue: 0x74 / 255)
    /// TRApp 标记色（实测 `#F9CA24`，与警示同值）.
    static let trMark = Color(red: 0xF9 / 255, green: 0xCA / 255, blue: 0x24 / 255)
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

    /// 参数类型必须写具体名 `ButtonStyleConfiguration`、不能写 `Configuration`：
    /// 本模块里 `vendor/ApplePackage` 另有一个 `public enum Configuration`，它在模块作用域里
    /// **盖过**了 `ButtonStyle.Configuration` ⇒ 裸写 `Configuration` 会解析成那个枚举，
    /// 报「cannot convert value of type 'Configuration' to expected argument type
    /// 'ButtonStyleConfiguration'」（v0.3.585 首次 CI 实测）。
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        TintedBody(configuration: configuration, tint: tint)
    }

    /// 样式体单独成一个 `View`：只有 `View` 能读 `@Environment`，用它在**禁用**时降透明度
    /// （自定义 `ButtonStyle` 不会像 `.borderedProminent` 那样自动置灰）.
    ///
    /// 名字**不能**叫 `Body`：`ButtonStyle` 有名为 `Body` 的关联类型，同名嵌套类型会被当成
    /// 那个关联类型去匹配协议要求，而它又是 `private` ⇒ 报
    /// 「struct 'Body' must be as accessible as its enclosing type」（同一次 CI 实测）。
    private struct TintedBody: View {
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

/// 品牌渐变主按钮（TRApp 深藏青渐变底 + 白字 + 连续圆角）.
///
/// 用于 hero / 主行动（如本页「开始安装」）。**不是纯蓝实底**：底是品牌深藏青渐变
/// `#2C3A6A → #161F2E`（取自 TRApp AppIcon 实测），符合「不要纯蓝实底按钮」的规则.
/// 按下时轻微缩放 + 降透明度作为反馈（替代实底样式的自动变暗）.
struct BrandProminentButtonStyle: ButtonStyle {
    var radius: CGFloat = 14

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        BrandBody(configuration: configuration, radius: radius)
    }

    /// 样式体单独成 View：只有 View 能读 `@Environment`，用于禁用态置灰.
    private struct BrandBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(AppFont.bodyEmphasis)
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(AppTheme.brandGradient)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
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

// MARK: - TRApp 风格 token 层（新增）
//
// 对照 TRApp 逆向结论：全站 SF Rounded（`design: .rounded`）+ Dynamic Type、
// 连续圆角、毛玻璃、数字等宽、分层符号渲染。以下把字号/圆角/间距收成命名 token，
// 供**新页面**使用；既有页面内联的字号与圆角**保持不变**（不一次全改，避免大范围回归）.

/// 字体层：SF Rounded + Dynamic Type，数字场景走等宽.
enum AppFont {
    static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let title = Font.system(.title2, design: .rounded).weight(.bold)
    static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
    static let headline = Font.system(.headline, design: .rounded).weight(.semibold)
    static let body = Font.system(.body, design: .rounded)
    static let bodyEmphasis = Font.system(.body, design: .rounded).weight(.semibold)
    static let subheadline = Font.system(.subheadline, design: .rounded)
    static let subheadlineEmphasis = Font.system(.subheadline, design: .rounded).weight(.semibold)
    static let caption = Font.system(.caption, design: .rounded)
    static let captionEmphasis = Font.system(.caption, design: .rounded).weight(.semibold)
    /// 数字等宽：进度百分比、体积、倒计时等数字场景（TRApp 用 `.monospacedDigit()`）.
    static let number = Font.system(.body, design: .rounded).monospacedDigit()
    static let numberEmphasis = Font.system(.body, design: .rounded).weight(.semibold).monospacedDigit()
    static let numberSmall = Font.system(.caption, design: .rounded).monospacedDigit()
    /// 次标题号等宽数字（机型序列号 / 版本号等「值」列）.
    static let numberSubheadline = Font.system(.subheadline, design: .rounded).monospacedDigit()
    static let numberSubheadlineEmphasis = Font.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit()
}

/// 圆角层：连续圆角（`RoundedCornerStyle.continuous`），与既有卡片口径对齐.
enum AppRadius {
    /// 卡片圆角（对齐既有 heroCard 的 16）.
    static let card: CGFloat = 16
    /// 内层容器 / 次级卡片.
    static let inner: CGFloat = 12
    /// chip / 小控件（对齐 `TintedButtonStyle` 常规号 8）.
    static let chip: CGFloat = 8
    /// 行内图标底（对齐 `AppRowIcon` 的 7）.
    static let icon: CGFloat = 7
}

/// 间距层：区块 / 行 / 紧凑三档.
enum AppSpacing {
    /// 区块之间.
    static let section: CGFloat = 16
    /// 行内元素之间.
    static let row: CGFloat = 12
    /// 紧凑元素之间.
    static let tight: CGFloat = 6
}

/// 尺寸层：卡片内边距与图标尺寸.
enum AppMetrics {
    /// 卡片内边距.
    static let cardPadding: CGFloat = 16
    /// 行内图标底边长（对齐 `AppRowIcon` 默认 30）.
    static let iconSize: CGFloat = 30
    /// hero 区块图标边长.
    static let heroIconSize: CGFloat = 44
}

/// 触觉层：方法在**调用侧**执行，不持有非 Sendable 的静态生成器实例（Swift 6 严格并发）.
enum AppHaptics {
    /// 轻点反馈（工具行点击等）：瞬时、较强.
    @MainActor
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred(intensity: 0.8)
    }

    /// 成功反馈.
    @MainActor
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 失败反馈.
    @MainActor
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/// 卡片底：语义分组背景 + 连续圆角 + 统一内边距.
struct AppCardBackground: ViewModifier {
    var radius: CGFloat = AppRadius.card
    var padding: CGFloat = AppMetrics.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
    }
}

/// 毛玻璃底（TRApp `Material.ultraThin` 语言），用于浮层 / 悬浮条.
struct AppGlassBackground: ViewModifier {
    var radius: CGFloat = AppRadius.card

    func body(content: Content) -> some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
    }
}

/// SF Symbol 分层渲染（TRApp `.symbolRenderingMode(.hierarchical)` 语言）.
struct AppSymbol: ViewModifier {
    func body(content: Content) -> some View {
        content.symbolRenderingMode(.hierarchical)
    }
}

extension View {
    /// 统一卡片外观（语义背景 + 连续圆角 + 内边距）.
    func appCard(radius: CGFloat = AppRadius.card, padding: CGFloat = AppMetrics.cardPadding) -> some View {
        modifier(AppCardBackground(radius: radius, padding: padding))
    }

    /// 统一毛玻璃外观.
    func appGlass(radius: CGFloat = AppRadius.card) -> some View {
        modifier(AppGlassBackground(radius: radius))
    }

    /// SF Symbol 分层渲染.
    func appSymbol() -> some View {
        modifier(AppSymbol())
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
