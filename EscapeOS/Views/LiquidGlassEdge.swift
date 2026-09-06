import SwiftUI

/// v0.3.218：液态玻璃球边缘形状 —— Canvas + Path + 多频正弦角度扰动，
/// 仿照 D:\Zcode\liquid-glass\index-v2.html 球体扰动公式。
/// TimelineView 自驱动 phase，无需外部传参。
struct LiquidGlassEdge: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var path = Path()
                let segments = 128
                for i in 0...segments {
                    let angle = Double(i) / Double(segments) * .pi * 2
                    let wave = 1.0
                        + 0.020 * sin(angle * 3.0 + phase * 0.8)
                        + 0.012 * sin(angle * 5.0 - phase * 0.6 + 2.1)
                        + 0.008 * sin(angle * 8.0 + phase * 1.1)
                    let r = radius * wave
                    let x = center.x + cos(angle) * r
                    let y = center.y + sin(angle) * r
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 1.6)
                context.stroke(path, with: .color(.white.opacity(0.65)), lineWidth: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}
