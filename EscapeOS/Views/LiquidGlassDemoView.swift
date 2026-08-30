import SwiftUI
import UIKit

/// 把 LiquidGlassKit 的 `VisualEffectView` 包进 SwiftUI。
/// 工厂方法 `VisualEffectView(effect:)` 会自行判断：iOS 26+ 用原生
/// `UIGlassEffect`，iOS 26 以下用本库自带的 Metal 实现（backport）。
struct LiquidGlassRepresentable: UIViewRepresentable {
    let style: LiquidGlassEffect.Style

    func makeUIView(context: Context) -> UIView {
        VisualEffectView(effect: LiquidGlassEffect(style: style))
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Liquid Glass 效果演示与自检页（v0.2.147）。
///
/// 用途：验证 LiquidGlassKit 在 Theos 构建下是否真正生效——
/// iOS 26 以下设备应显示 Metal 渲染的玻璃效果；若 metallib 缺失或
/// 设备不支持 Metal，页面顶部会明确提示（而不是静默无效果）。
struct LiquidGlassDemoView: View {
    private var systemVersion: String {
        UIDevice.current.systemVersion
    }

    /// 主 bundle 里是否有编译好的 metallib（决定 backport 能否工作）。
    private var metallibExists: Bool {
        Bundle.main.url(forResource: "LiquidGlassKit", withExtension: "metallib") != nil
    }

    /// Metal + shader 管线是否就绪（LiquidGlassRenderer 内置的降级标志）。
    private var rendererAvailable: Bool {
        LiquidGlassRenderer.shared.isAvailable
    }

    private var usesNativeGlass: Bool {
        guard let major = systemVersion.split(separator: ".").first,
              let value = Int(major) else { return false }
        return value >= 26
    }

    var body: some View {
        ZStack {
            // 彩色背景：玻璃的折射/色散效果只有在有内容可折射时才看得出来。
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    glassShowcase
                    infoSection
                }
                .padding(20)
            }
        }
        .navigationTitle("Liquid Glass")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 子视图

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [.blue, .purple, .cyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 状态自检卡片：一眼看出当前走的是原生还是 backport、管线是否就绪。
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("运行状态", systemImage: "stethoscope")
                .font(.headline)
            row("系统版本", "iOS \(systemVersion)")
            row("渲染来源", usesNativeGlass ? "系统原生 UIGlassEffect" : "LiquidGlassKit Metal backport")
            row("Shader 库", metallibExists ? "已加载 LiquidGlassKit.metallib" : "缺失（效果不可用）")
            row("Metal 管线", rendererAvailable ? "就绪" : "不可用（已安全降级）")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(glassLayer(.regular))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 玻璃效果展示：同一内容分别套 regular / clear 两种风格。
    private var glassShowcase: some View {
        VStack(spacing: 16) {
            glassCard(title: "Regular 风格", subtitle: "标准玻璃：折射 + 色散 + 边缘高光", style: .regular)
            glassCard(title: "Clear 风格", subtitle: "通透玻璃：更接近纯净玻璃质感", style: .clear)
        }
    }

    private func glassCard(title: String, subtitle: String, style: LiquidGlassEffect.Style) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(glassLayer(style))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func glassLayer(_ style: LiquidGlassEffect.Style) -> some View {
        LiquidGlassRepresentable(style: style)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("说明")
                .font(.footnote.weight(.semibold))
            Text("LiquidGlassKit 是 Apple iOS 26 Liquid Glass 设计系统的 backport，用 Metal 着色器实现折射、色散、菲涅尔反射与镜面高光，iOS 18 及以下设备同样可用；iOS 26+ 自动改用系统原生实现。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }
}
