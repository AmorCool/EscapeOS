import SwiftUI

/// v0.3.197：主页（手机管家形态）— 顶部灵动球 hero + 中部 2 列卡片网格
/// （空间回收 / 应用管理 / 模块 / 百宝箱 — 仅含项目真有的功能，未照抄原图
/// 所有入口）。下拉/上滑手势可进入百宝箱占位页。
struct HomeView: View {
    @ObservedObject var appList: AppListViewModel
    /// v0.3.197：安全评分（占位 — 后续接入 SecurityPresets.plist + Reveil 思路实做）.
    @State private var securityScore: Int = 92
    /// 体感上的呼吸节奏 —— 灵动球渐变光晕周期
    @State private var breathe: Bool = false
    @State private var showTreasure: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                quickCheckCard
                cardsGrid
                Spacer(minLength: 24)
                treasureHint
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("主页")
        .navigationBarTitleDisplayMode(.large)
        .gesture(treasureGesture)
        .navigationDestination(isPresented: $showTreasure) {
            TreasureBoxView()
        }
    }

    // MARK: Hero —— 灵动球 + 分数 + 立即体检
    private var heroCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // 外圈柔光呼吸（中等复杂度核心）
                Circle()
                    .fill(radial: scoreGradient)
                    .frame(width: 220, height: 220)
                    .blur(radius: breathe ? 18 : 8)
                    .opacity(breathe ? 0.75 : 0.5)
                    .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: breathe)
                // 球体本体
                Circle()
                    .fill(sphereGradient)
                    .frame(width: 180, height: 180)
                    .overlay(
                        Circle()
                            .stroke(AngularGradient(colors: ringColors, center: .center), lineWidth: 3)
                            .blur(radius: 0.5)
                    )
                    .shadow(color: scoreShadow, radius: 24, y: 4)
                // 高光
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 90, height: 90)
                    .offset(x: -28, y: -42)
                    .blur(radius: 12)
                // 数字
                VStack(spacing: 2) {
                    Text("\(securityScore)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                    Text(scoreSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .frame(height: 240)
            .onAppear { breathe = true }
            // 立即体检按钮
            NavigationLink {
                HealthCheckView()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stethoscope")
                        .font(.body.weight(.semibold))
                    Text("立即体检")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.blue.opacity(0.92))
                )
                .foregroundStyle(.white)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: 简短的体检小结
    private var quickCheckCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(scoreSubtitle)
                    .font(.subheadline.weight(.semibold))
                Text("下次体检建议：每周一次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink {
                HealthCheckView()
            } label: {
                Text("查看")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: 功能卡片网格 — 只放项目真有的功能
    private var cardsGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]
        return LazyVGrid(columns: columns, spacing: 12) {
            NavigationLink {
                SpaceReclaimView(appList: appList)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HomeCard(title: "空间回收",
                         subtitle: "扫描可清理的应用缓存",
                         icon: "internaldrive",
                         tint: .blue)
            }
            .buttonStyle(.plain)

            NavigationLink {
                AppListView(viewModel: appList)
            } label: {
                HomeCard(title: "应用管理",
                         subtitle: "已安装应用 + 签名类型",
                         icon: "square.grid.2x2.fill",
                         tint: .indigo)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ModuleManagerView()
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HomeCard(title: "模块",
                         subtitle: "KernelSU 风格模块管理",
                         icon: "shippingbox.fill",
                         tint: .orange)
            }
            .buttonStyle(.plain)

            Button {
                showTreasure = true
            } label: {
                HomeCard(title: "百宝箱",
                         subtitle: "更多工具 · 即将上线",
                         icon: "shippingbox.and.arrow.backward.fill",
                         tint: .purple)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 百宝箱提示（页面底部装饰）
    private var treasureHint: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.compact.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("下滑进入百宝箱")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 百宝箱下滑手势
    private var treasureGesture: some Gesture {
        // 在 ScrollView 顶部时下滑触发
        DragGesture(minimumDistance: 30, coordinateSpace: .named("home"))
            .onEnded { value in
                guard value.translation.height > 80,
                      abs(value.translation.width) < 60 else { return }
                showTreasure = true
            }
    }

    // MARK: 视觉辅助
    private var scoreSubtitle: String {
        switch securityScore {
        case 80...: return "手机很安全，可继续优化"
        case 60..<80: return "安全状况良好"
        default: return "建议尽快体检"
        }
    }
    private var scoreGradient: RadialGradient {
        RadialGradient(
            colors: [scoreColor.opacity(0.55), scoreColor.opacity(0)],
            center: .center, startRadius: 30, endRadius: 180
        )
    }
    private var sphereGradient: RadialGradient {
        RadialGradient(
            colors: [scoreColor.opacity(0.95), scoreColor.opacity(0.55)],
            center: .center, startRadius: 8, endRadius: 100
        )
    }
    private var ringColors: [Color] {
        [scoreColor.opacity(0.9), scoreColor.opacity(0.4), scoreColor.opacity(0.9)]
    }
    private var scoreColor: Color {
        switch securityScore {
        case 80...: return .blue
        case 60..<80: return .yellow
        default: return .orange
        }
    }
    private var scoreShadow: Color {
        scoreColor.opacity(0.6)
    }
}

/// 主页功能卡片
struct HomeCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}