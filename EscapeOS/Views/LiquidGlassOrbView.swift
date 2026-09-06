import SwiftUI

/// v0.3.219：液态玻璃灵动球（主页 Hero）。
///
/// iOS 17+：Metal 实时渲染 —— 极光背景折射进球体（RGB 三路色散）、菲涅尔边缘反射、
/// 虹彩薄膜、三光源高光（主光跟随手指）、底部焦散、SDF 液态轮廓微扰、
/// 卫星小球、安全分进度环（分数变化时平滑增长）。算法与视觉对标
/// D:\Zcode\liquid-glass\index-v2.html 的 WebGL 样板。
///
/// ⚠️ 着色器在 LiquidGlassOrb.metal，需一并加入 App target。
/// iOS 17 以下：自动回退为旧的圆环进度样式。
struct LiquidGlassOrbView: View {
    var score: Int
    var tint: Color

    /// 着色器时间轴起点
    @State private var startDate = Date()
    /// 光源目标位置（uv 空间 0…1，y 向上；跟随手指，松手后缓动回球心）
    @State private var lightTarget: CGPoint?
    @State private var lightCur: CGPoint = CGPoint(x: 0.5, y: 0.55)
    /// 进度环平滑值（避免分数跳变）
    @State private var progressCur: Float = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(iOS 17.0, *) {
            shaderOrb
        } else {
            legacyOrb
        }
    }

    // MARK: - Metal 实时液态玻璃球（iOS 17+）

    @available(iOS 17.0, *)
    @available(iOS 17.0, *)
    @ViewBuilder
    private func shaderRect(size: CGSize, t: Double) -> some View {
        // ShaderLibrary.xxx 返回 ShaderFunction?（.metal 未编译/函数未找到 → nil）
        if let fn = ShaderLibrary.liquidGlassOrb {
            Rectangle()
                .fill(Color(red: 0.010, green: 0.012, blue: 0.028))
                .colorEffect(
                    Shader(fn,
                        .float2(Float(size.width), Float(size.height)),
                        .float(Float(t)),
                        .float2(Float(lightCur.x), Float(lightCur.y)),
                        .float3(tintVec.x, tintVec.y, tintVec.z),
                        .float(progressCur)
                    )
                )
        } else {
            // .metal 未编译 → 占位背景
            Rectangle().fill(Color(red: 0.010, green: 0.012, blue: 0.028))
        }
    }

    @available(iOS 17.0, *)
    private var shaderOrb: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                TimelineView(.animation) { timeline in
                    let t = reduceMotion ? 3.0 : timeline.date.timeIntervalSince(startDate)
                    shaderRect(size: size, t: t)
                }
                // 球心分数（球心位于面板 55% 高度处）
                scoreText
                    .position(x: size.width * 0.5, y: size.height * 0.55)
                // 左上角小铭牌
                Text("SECURE ORB · REALTIME GLASS")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        lightTarget = CGPoint(
                            x: g.location.x / max(size.width, 1),
                            y: 1 - g.location.y / max(size.height, 1)
                        )
                    }
                    .onEnded { _ in lightTarget = nil }
            )
            .accessibilityLabel("安全评分 \(score) 分")
        }
        .aspectRatio(1.25, contentMode: .fit)
        .task(id: "orb-loop") { await animateLoop() }
    }

    /// 60fps 轻量状态循环：光源缓动 + 进度环平滑
    @available(iOS 17.0, *)
    private func animateLoop() async {
        while !Task.isCancelled {
            let home = CGPoint(x: 0.5, y: 0.55)
            let tgt = lightTarget ?? home
            lightCur.x += (tgt.x - lightCur.x) * 0.16
            lightCur.y += (tgt.y - lightCur.y) * 0.16
            let target = Float(min(max(score, 0), 100)) / 100.0
            progressCur += (target - progressCur) * 0.07
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private var scoreText: some View {
        VStack(spacing: -2) {
            Text("\(score)")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 9, y: 1)
            Text("分")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .animation(.easeInOut(duration: 0.5), value: score)
    }

    private var tintVec: SIMD3<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(tint).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
    }

    // MARK: - 旧系统回退（iOS 17 以下：圆环进度样式）

    private var legacyOrb: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(0.45), tint.opacity(0)],
                    center: .center, startRadius: 30, endRadius: 180))
                .frame(width: 230, height: 230)
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 14)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.7), value: score)
            VStack(spacing: -4) {
                Text("\(score)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .foregroundStyle(tint)
                Text("分")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
