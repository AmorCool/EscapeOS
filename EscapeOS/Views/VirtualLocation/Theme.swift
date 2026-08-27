import SwiftUI

/// 虚拟定位页主题（移植自 locus-ZH，青/橙语义色，无棕色系）。
enum LocusTheme {
    static let accent = Color(red: 0.35, green: 0.78, blue: 0.72)
    static let accentSecondary = Color(red: 0.95, green: 0.55, blue: 0.28)
    static let danger = Color(red: 0.92, green: 0.32, blue: 0.36)
    static let panelStroke = Color.white.opacity(0.12)
    static let statusGood = Color(red: 0.30, green: 0.86, blue: 0.55)
    static let statusWarn = Color(red: 0.98, green: 0.78, blue: 0.28)
    static let statusBad = Color(red: 0.92, green: 0.32, blue: 0.36)
}

enum LocusGlassStyle {
    case regular
    case clear
    case interactive
}

/// iOS 26 液态玻璃；旧系统回退半透明材质。
struct LocusGlassModifier<S: Shape>: ViewModifier {
    var style: LocusGlassStyle
    var shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(glass, in: shape)
                // 玻璃会画出布局边界，扩展命中区域保持一致。
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
