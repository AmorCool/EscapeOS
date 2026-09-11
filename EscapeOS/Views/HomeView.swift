import SwiftUI

/// v0.3.197：主页（手机管家形态）— 顶部灵动球 hero + 卡片网格.
/// v0.3.219：Hero 换装 Metal 实时液态玻璃球（LiquidGlassOrbView + LiquidGlassOrb.metal）.
/// v0.3.207：百宝箱 = 系统原生 sheet（presentationDetents 0.4↔1.0，原生上拉展开/
/// 下拉关闭——跟手流畅，返回不必点横线；把手区点击或上滑触发）.
struct HomeView: View {
    @ObservedObject var appList: AppListViewModel
    /// v0.3.197：安全评分（占位 — 后续接入 SecurityPresets.plist + Reveil 思路实做）.
    @State private var securityScore: Int = 92
    /// v0.3.207：百宝箱 sheet
    @State private var treasureOpen = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                cardsGrid
                treasureHandleBar   // v0.3.207：底部把手（点击/上滑开 sheet）
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .sheet(isPresented: $treasureOpen) {
            // 原生 sheet：0.4↔1.0 detent 上拉展开、下拉关闭
            TreasureBoxView()
                .presentationDetents([.fraction(0.4), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                .interactiveDismissDisabled(false)
        }
        // v0.3.200：进入主页自动静默体检（灵动球分数即时显示）
        .task(id: "auto-check") {
            let total = await Task.detached(priority: .userInitiated) {
                SecurityScanner.runAll().1
            }.value
            withAnimation(.easeInOut(duration: 0.5)) { securityScore = total }
        }
        .navigationTitle("主页")
        .navigationBarTitleDisplayMode(.large)
    }

    /// 打开百宝箱 sheet（把手点击/上滑触发）
    private func openTreasure() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        treasureOpen = true
    }

    // MARK: Hero —— 灵动球 + 分数 + 立即体检
    // v0.3.219：Metal 实时液态玻璃球（折射 + RGB 色散 + 菲涅尔 + 焦散 + 液态轮廓，
    // 移植自 liquid-glass v2 WebGL 样板；组件见 LiquidGlassOrbView.swift，
    // 着色器见 LiquidGlassOrb.metal；iOS 17 以下回退旧版圆环进度样式）
    private var heroCard: some View {
        VStack(spacing: 16) {
            LiquidGlassOrbView(score: securityScore, tint: scoreColor)
            Text(scoreSubtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
            // 立即体检按钮
            NavigationLink {
                HealthCheckView(score: $securityScore)
            } label: {
                Label("立即体检", systemImage: "stethoscope")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
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

    // MARK: 功能卡片网格（v0.3.213：参考系统管家 2×3 = 6 卡布局）
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

            // v0.3.207：设备信息（iDescriptor DeviceInfo 面板移植）
            NavigationLink {
                DeviceInfoView()
            } label: {
                HomeCard(title: "设备信息",
                         subtitle: "机型 / 系统 / CPU / 存储",
                         icon: "iphone.gen3",
                         tint: .teal)
            }
            .buttonStyle(.plain)

            // v0.3.208：文档浏览（iDescriptor FileSharing 移植——开启文档共享的应用文件树）
            NavigationLink {
                FileSharingAppsView()
            } label: {
                HomeCard(title: "文档浏览",
                         subtitle: "开启文件共享的 App 文档目录",
                         icon: "folder.fill",
                         tint: .indigo)
            }
            .buttonStyle(.plain)

            // v0.3.295：AppStore 商店（榜单 / 搜索 / 详情；安装走系统 App Store）
            NavigationLink {
                AppStoreView()
            } label: {
                HomeCard(title: "AppStore 商店",
                         subtitle: "榜单 / 搜索 / 应用详情",
                         icon: "app.badge.fill",
                         tint: .blue)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 百宝箱把手（v0.3.206：底部上拉抽屉——小米管家式，非嵌内容非简单切换）

    /// 主页底部把手条：点击或上滑手势进入百宝箱抽屉（面板从底部滑动进入）.
    private var treasureHandleBar: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color(.separator))
                .frame(width: 40, height: 5)
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("百宝箱")
                        .font(.subheadline.weight(.semibold))
                    Text("上拉查看小工具 · 更多工具持续补充")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
        .onTapGesture { openTreasure() }
        .highPriorityGesture(
            // 上滑手势进入抽屉（与点击并存；只响应向上滑动）
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard value.translation.height < -60,
                          abs(value.translation.width) < 80 else { return }
                    openTreasure()
                }
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
    private var scoreColor: Color {
        switch securityScore {
        case 80...: return .blue
        case 60..<80: return .yellow
        default: return .orange
        }
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
