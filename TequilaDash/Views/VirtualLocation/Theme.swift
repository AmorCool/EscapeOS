import SwiftUI

/// 虚拟定位页主题（移植自 locus-ZH，青/橙语义色，无棕色系）.
///
/// ## 关于明暗两套（硬规则 6）
///
/// 这 7 个色原本全部写死单值 —— 因为本页是**地图界面**：
/// 地图瓦片本身不随系统明暗切换，面板永远浮在深色地图上，
/// 所以「浅色模式用深色文字」那套自适应逻辑在这里不成立。
///
/// v0.3.631 起改成 `Color(UIColor { trait in ... })` 两分支，但**两分支取值相同**，
/// 目的是把「为什么不自适应」这件事写进类型，而不是留给下一个人去猜：
/// 看到 `Color(UIColor { ... })` 就知道「这里考虑过明暗」，
/// 看到写死 `Color(red:...)` 只会以为是漏改。
///
/// 真正需要区分明暗的是**面板内部**的 AppTheme 语义色（文字、分隔线），
/// 那些已经走 AppTheme 的自适应 token，不受本文件影响。
enum LocusTheme {
    /// 主强调色（青）. 地图背景恒定深色，故明暗同值.
    static let accent = Color(UIColor { _ in UIColor(red: 0.35, green: 0.78, blue: 0.72, alpha: 1) })
    /// 次强调色（橙）. 同上.
    static let accentSecondary = Color(UIColor { _ in UIColor(red: 0.95, green: 0.55, blue: 0.28, alpha: 1) })
    /// 危险色. 同上.
    static let danger = Color(UIColor { _ in UIColor(red: 0.92, green: 0.32, blue: 0.36, alpha: 1) })
    /// 面板描边（白 12%）. 同上.
    static let panelStroke = Color.white.opacity(0.12)
    /// 状态-良好. 同上.
    static let statusGood = Color(UIColor { _ in UIColor(red: 0.30, green: 0.86, blue: 0.55, alpha: 1) })
    /// 状态-警告. 同上.
    static let statusWarn = Color(UIColor { _ in UIColor(red: 0.98, green: 0.78, blue: 0.28, alpha: 1) })
    /// 状态-异常. 同上.
    static let statusBad = Color(UIColor { _ in UIColor(red: 0.92, green: 0.32, blue: 0.36, alpha: 1) })
}

enum LocusGlassStyle {
    case regular
    case clear
    case interactive
}

/// iOS 26 液态玻璃；旧系统回退半透明材质.
struct LocusGlassModifier<S: Shape>: ViewModifier {
    var style: LocusGlassStyle
    var shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(glass, in: shape)
                // 玻璃会画出布局边界，扩展命中区域保持一致.
                .contentShape(shape)
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.55))
                    }
                }
                .overlay(shape.stroke(LocusTheme.panelStroke, lineWidth: 1))
                .contentShape(shape)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g: Glass = style == .clear ? .clear : .regular
        if style == .interactive { g = g.interactive() }
        if let tint { g = g.tint(tint) }
        return g
    }
}

extension View {
    func locusGlass<S: Shape>(
        _ style: LocusGlassStyle = .regular,
        tint: Color? = nil,
        in shape: S
    ) -> some View {
        modifier(LocusGlassModifier(style: style, shape: shape, tint: tint))
    }

    func locusGlass(_ style: LocusGlassStyle = .regular, tint: Color? = nil) -> some View {
        locusGlass(style, tint: tint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
