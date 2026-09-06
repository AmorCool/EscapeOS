import SwiftUI

/// v0.3.197：主页（手机管家形态）— 顶部灵动球 hero + 卡片网格。
/// v0.3.207：百宝箱 = 系统原生 sheet（presentationDetents 0.4↔1.0，原生上拉展开/
/// 下拉关闭——跟手流畅，返回不必点横线；把手区点击或上滑触发）。
struct HomeView: View {
    @ObservedObject var appList: AppListViewModel
    /// v0.3.197：安全评分（占位 — 后续接入 SecurityPresets.plist + Reveil 思路实做）.
    @State private var securityScore: Int = 92
    /// 体感上的呼吸节奏 —— 灵动球渐变光晕周期
    @State private var breathe: Bool = false
    /// v0.3.207：百宝箱 sheet
    @State private var treasureOpen = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                quickCheckCard
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
    // v0.3.207：回退 v0.3.204 版灵动球（v0.3.206 八层液态玻璃被用户否掉）
    private var heroCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // 外圈柔光呼吸
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
        }
    }

    // MARK: 百宝箱把手（v0.3.206：底部上拉抽屉——小米管家式，非嵌内容非简单切换）

    /// 主页底部把手条：点击或上滑手势进入百宝箱抽屉（面板从底部滑动进入）。
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
