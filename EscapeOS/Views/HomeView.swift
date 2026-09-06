import SwiftUI

/// v0.3.197：主页（手机管家形态）— 顶部灵动球 hero + 卡片网格 + 底部百宝箱区块。
/// v0.3.202：百宝箱**嵌在主页最底部**（滚动直达，无下拉手势——用户反馈手势灵敏度
/// 太高易误触；也删除了顶部"下拉进入"把手与独立 push 页）。
struct HomeView: View {
    @ObservedObject var appList: AppListViewModel
    /// v0.3.197：安全评分（占位 — 后续接入 SecurityPresets.plist + Reveil 思路实做）.
    @State private var securityScore: Int = 92
    /// 体感上的呼吸节奏 —— 灵动球渐变光晕周期
    @State private var breathe: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                quickCheckCard
                cardsGrid
                treasureSection     // v0.3.202：百宝箱区块（主页最底部）
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
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
                         subtitle: "管理已安装应用",
                         icon: "square.grid.2x2.fill",
                         tint: .indigo)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ModuleManagerView()
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HomeCard(title: "模块",
                         subtitle: "模块管理",
                         icon: "shippingbox.fill",
                         tint: .orange)
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

    // MARK: 百宝箱区块（v0.3.202：嵌在主页最底部，滚动直达，无手势）

    /// 主页底部「百宝箱」区块：杂七杂八工具的入口集合（后续逐项填充）。
    private var treasureSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .foregroundStyle(.purple)
                Text("百宝箱")
                    .font(.headline)
            }
            .padding(.bottom, 8)

            ForEach(TreasureItem.placeholder) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("即将上线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                Divider().opacity(item.id == TreasureItem.placeholder.last?.id ? 0 : 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
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

/// 百宝箱工具占位项（后续逐项实现并接真实页面）
struct TreasureItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let color: Color
    static let placeholder: [TreasureItem] = [
        .init(id: "1", icon: "doc.text.magnifyingglass", title: "设备日志导出",
              detail: "一键导出系统日志/Sysmon/诊断数据", color: .blue),
        .init(id: "2", icon: "key.fill", title: "随机设备 ID",
              detail: "重置 ApplePackage/Anisette 设备标识", color: .indigo),
        .init(id: "3", icon: "wifi", title: "设备网络信息",
              detail: "查看局域网 IP / 端口占用", color: .purple),
        .init(id: "4", icon: "trash", title: "清理应用残留",
              detail: "扫描并清理卸载残留的容器/缓存", color: .gray),
    ]
}
