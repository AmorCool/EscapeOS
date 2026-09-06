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
    /// v0.3.199：百宝箱手势 — 跟踪 ScrollView 顶部偏移，判定"是否在页面顶部"
    /// （只有顶部才能下拉进入百宝箱，避免与列表滚动冲突误触）
    @State private var topOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                treasureHandle    // 顶部把手（下拉进入百宝箱）
                heroCard
                quickCheckCard
                cardsGrid
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .background(
                // 读取 ScrollView 内容相对滚动的顶部偏移
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollTopOffsetKey.self,
                        value: geo.frame(in: .named("homeScroll")).minY
                    )
                }
            )
        }
        .coordinateSpace(name: "homeScroll")
        .onPreferenceChange(ScrollTopOffsetKey.self) { topOffset = $0 }
        // v0.3.200：进入主页自动静默体检（灵动球分数即时显示）
        .task(id: "auto-check") {
            let total = await Task.detached(priority: .userInitiated) {
                SecurityScanner.runAll().1
            }.value
            withAnimation(.easeInOut(duration: 0.5)) { securityScore = total }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("主页")
        .navigationBarTitleDisplayMode(.large)
        .simultaneousGesture(treasureGesture)
        .navigationDestination(isPresented: $showTreasure) {
            TreasureBoxView()
        }
    }

    /// 顶部把手：提示下拉进入百宝箱；拖动时视觉放大反馈
    private var treasureHandle: some View {
        VStack(spacing: 5) {
            Capsule()
                .fill(Color(.separator))
                .frame(width: 36, height: 5)
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.semibold))
                Text("下拉进入百宝箱")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
            .scaleEffect(handleScale)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var handleScale: CGFloat {
        // 下拉时把手轻微放大 → 提示手势生效
        let pull = max(0, min(dragOffset, 60))
        return 1 + (pull / 60) * 0.18
    }

    // MARK: Hero —— 灵动球 + 分数 + 立即体检
    private var heroCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // 外圈柔光呼吸（中等复杂度核心）
                Circle()
                    .fill(scoreGradient)
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
                HealthCheckView(score: $securityScore)
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
                HealthCheckView(score: $securityScore)
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

            // v0.3.199：电池健康（iDescriptor BatteryInfo 移植）
            NavigationLink {
                BatteryHealthView()
            } label: {
                HomeCard(title: "电池健康",
                         subtitle: "循环次数 / 容量 / 健康度",
                         icon: "battery.75percent",
                         tint: .green)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 百宝箱下滑手势（v0.3.199：只在页面顶部时触发，避免与滚动冲突）
    private var treasureGesture: some Gesture {
        // simultaneousGesture：与 ScrollView 滚动共存——但仅当内容在顶部
        // （topOffset ≥ -2，含下拉弹性）且下滑 >90pt 时进入百宝箱。
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                // 只有向下拖且在页面顶部时记录
                if value.translation.height > 0, topOffset >= -2 {
                    dragOffset = value.translation.height
                } else {
                    dragOffset = 0
                }
            }
            .onEnded { value in
                dragOffset = 0
                guard value.translation.height > 90,
                      abs(value.translation.width) < 80,
                      topOffset >= -2 else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
// MARK: - 滚动顶部偏移 PreferenceKey（百宝箱手势判定用）
fileprivate struct ScrollTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
