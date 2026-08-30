import SwiftUI

/// 液态玻璃视觉层（EscapeSpace 适配版，v0.2.149 重写）。
///
/// ## 为什么列表行不用 LiquidGlassKit 的 Metal 视图
/// `LiquidGlassView` 继承 `MTKView`，**逐帧**渲染。「更多」页有 20+ 行，
/// 每行一个 MTKView 滚动时必然掉帧；而整页铺一张玻璃又会被看成
/// 「贴在后面的一块背景板」（v0.2.148 的用户原话）—— 两者都不可取。
///
/// 这里改为用纯 SwiftUI 复刻液态玻璃的**三个可辨识特征**，零 GPU 开销，
/// 任意行数都不掉帧：
/// 1. **半透明材质**：`.ultraThinMaterial` 透出下层光晕 / 内容；
/// 2. **镜面高光**：顶部强反射 → 中段通透 → 底部压暗；
/// 3. **折射描边**：1px 描边，左上缘亮（反射）、右下缘暗（玻璃厚度）。
///
/// iOS 26+ 系统本身就是 Liquid Glass，这类自定义背景统一跳过、保持原生外观。
enum GlassStyle {
    /// 行 / 卡片圆角。比系统分组列表（10pt）大，更接近 iOS 26 的观感。
    static let cornerRadius: CGFloat = 16
}

/// 一块液态玻璃：材质 + 镜面高光 + 折射描边。
///
/// 它是**控件本身**，尺寸由内容决定、跟着列表一起滚动 —— 而不是铺在页面
/// 后面的一张固定底板（v0.2.148 的做法，被用户指出「多了一块背景」）。
struct GlassSurface: View {
    var cornerRadius: CGFloat = GlassStyle.cornerRadius
    /// 玻璃"厚度"：0 极通透，1 标准，越大高光越强。
    var thickness: CGFloat = 1

    var body: some View {
        ZStack {
            // 1. 材质：透出下层的光晕 / 内容。
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)

            // 2. 镜面高光：上缘强反射 → 中段通透 → 下缘压暗。
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .white.opacity(0.30 * thickness), location: 0.00),
                            Gradient.Stop(color: .white.opacity(0.10 * thickness), location: 0.18),
                            Gradient.Stop(color: .white.opacity(0.02), location: 0.55),
                            Gradient.Stop(color: .black.opacity(0.05 * thickness), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 3. 折射描边：左上亮（光从这来）、右下暗（玻璃厚度）。
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.60),
                            .white.opacity(0.14),
                            .white.opacity(0.06),
                            .black.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

/// 页面底：系统分组背景 + 极淡的多色光晕。
///
/// 液态玻璃的折射 / 高光只有在**下面有内容**时才看得出来；铺在纯色底上，
/// 它和普通圆角卡片几乎没有区别。这里垫几团很淡的冷色光晕（蓝 / 青 / 靛，
/// 不使用棕色系），让玻璃真正"有东西可折射"。
struct GlassPageBackdrop: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(
                colors: [Color.blue.opacity(0.18), Color.clear],
                center: .topLeading, startRadius: 8, endRadius: 420
            )
            RadialGradient(
                colors: [Color.indigo.opacity(0.13), Color.clear],
                center: UnitPoint(x: 0.85, y: 0.28), startRadius: 8, endRadius: 360
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.15), Color.clear],
                center: .bottomTrailing, startRadius: 8, endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// 给列表行套上液态玻璃底：一块独立的悬浮玻璃卡片。
    ///
    /// iOS 26 及以上系统原生就是 Liquid Glass，再叠自定义背景反而显脏，
    /// 所以直接跳过；iOS 18~25 才用 `GlassSurface` 复刻。
    ///
    /// 配合 `.listStyle(.plain)` 使用：行间距由 `listRowInsets` 给足，
    /// 每行才是独立悬浮的玻璃块，而不是被分组圆角裁掉一半的矩形。
    @ViewBuilder
    func liquidGlassRow(cornerRadius: CGFloat = GlassStyle.cornerRadius) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self
                .listRowBackground(GlassSurface(cornerRadius: cornerRadius))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        }
    }
}
