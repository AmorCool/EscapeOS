import SwiftUI

/// Liquid Glass 视觉层（EscapeSpace 适配版）。
///
/// 设计要点（性能 + 安全）：
/// - **每个面板只用一个 Metal 视图**：LiquidGlassKit 的 `LiquidGlassView`
///   继承 `MTKView`，会持续逐帧渲染。若给列表的每个 row 都套一层，
///   滚动时十几个 MTKView 同时渲染必然掉帧 —— 所以本项目统一用
///   「一整块玻璃背景层 + 透明内容层」，一个页面只画一次。
/// - **永远有兜底**：shader 缺失 / 设备不支持 Metal 时玻璃层是透明的，
///   下面垫一层系统材质，界面不会变空白或崩溃。
/// - iOS 26+ 由 LiquidGlassKit 自动改走系统原生 `UIGlassEffect`。
struct LiquidGlassLayer: View {
    let style: LiquidGlassEffect.Style
    let cornerRadius: CGFloat

    init(style: LiquidGlassEffect.Style = .regular, cornerRadius: CGFloat = 22) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            // 兜底材质：玻璃层透明时（不可用时）由它撑起视觉。
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            // 真正的 Liquid Glass（折射 / 色散 / 菲涅尔 / 高光）。
            LiquidGlassRepresentable(style: style)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 玻璃质感卡片：内容浮在一块 Liquid Glass 上。
///
/// 用法：
/// ```swift
/// LiquidGlassCard {
///     VStack(alignment: .leading) { ... }
/// }
/// ```
struct LiquidGlassCard<Content: View>: View {
    let style: LiquidGlassEffect.Style
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    init(style: LiquidGlassEffect.Style = .regular,
         cornerRadius: CGFloat = 22,
         @ViewBuilder content: () -> Content) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(LiquidGlassLayer(style: style, cornerRadius: cornerRadius))
    }
}

/// 给整个页面铺一层玻璃底：`List` 背景透明后，内容就浮在这层玻璃上。
/// 只创建一个 Metal 视图，滚动性能不受影响。
struct LiquidGlassPageBackground: View {
    let style: LiquidGlassEffect.Style
    let cornerRadius: CGFloat

    init(style: LiquidGlassEffect.Style = .regular, cornerRadius: CGFloat = 26) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        LiquidGlassLayer(style: style, cornerRadius: cornerRadius)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}
