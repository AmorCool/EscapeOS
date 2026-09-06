import SwiftUI

/// v0.3.197：主页（手机管家形态）— 顶部灵动球 hero + 卡片网格。
/// v0.3.206：百宝箱 = 底部上拉抽屉（小米管家式：面板从底部滑动进入，
/// 带滑动过程与弹簧动画，不是简单 push/切换；把手支持点击或上滑手势）。
struct HomeView: View {
    @ObservedObject var appList: AppListViewModel
    /// v0.3.197：安全评分（占位 — 后续接入 SecurityPresets.plist + Reveil 思路实做）.
    @State private var securityScore: Int = 92
    /// 体感上的呼吸节奏 —— 灵动球渐变光晕周期
    @State private var breathe: Bool = false
    /// v0.3.206：灵动球扫描环旋转
    @State private var spinRing: Bool = false
    /// v0.3.206：百宝箱抽屉开关
    @State private var treasureOpen = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 20) {
                    heroCard
                    quickCheckCard
                    cardsGrid
                    treasureHandleBar   // v0.3.206：底部把手（上拉/点击开抽屉）
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)

            // v0.3.206：百宝箱抽屉（底部滑入）
            if treasureOpen {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeTreasure() }
                TreasureBoxView(onClose: { closeTreasure() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .bottom))
            }
        }
        .background(Color(.systemBackground))
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: treasureOpen)
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

    /// 关闭抽屉
    private func closeTreasure() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            treasureOpen = false
        }
    }
    /// 打开抽屉（上滑触发；把手内 DragGesture onEnded 调）
    private func openTreasure() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            treasureOpen = true
        }
    }

    // MARK: Hero —— 液态玻璃灵动球 + 分数 + 立即体检
    private var heroCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // ① 外圈呼吸光晕
                Circle()
                    .fill(scoreGradient)
                    .frame(width: 232, height: 232)
                    .blur(radius: breathe ? 20 : 9)
                    .opacity(breathe ? 0.8 : 0.55)
                    .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: breathe)

                // ② 玻璃球底座（液态玻璃质感：多层渐变叠）
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [scoreColor.opacity(0.9), scoreColor.opacity(0.35)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 180, height: 180)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.22), .clear],
                            center: .init(x: 0.3, y: 0.25), startRadius: 0, endRadius: 110
                        )
                    )
                    .frame(width: 180, height: 180)

                // ③ 玻璃描边（内亮外淡，模拟折射边缘）
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.85), scoreColor.opacity(0.55), .white.opacity(0.1)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.4
                    )
                    .frame(width: 180, height: 180)

                // ④ 顶部弧形反光（玻璃高光条）
                Capsule()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.65), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 110, height: 22)
                    .offset(x: -30, y: -62)
                    .rotationEffect(.degrees(-18))
                    .blur(radius: 0.8)

                // ⑤ 内层高光点
                Circle()
                    .fill(.white.opacity(0.28))
                    .frame(width: 42, height: 42)
                    .offset(x: -52, y: -52)
                    .blur(radius: 3)

                // ⑥ 扫描环（双环旋转，动态完整性实时感）
                Circle()
                    .trim(from: 0.0, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [.clear, scoreColor.opacity(0.9), .clear],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .frame(width: 186, height: 186)
                    .rotationEffect(.degrees(spinRing ? 360 : 0))
                    .animation(.linear(duration: 3.6).repeatForever(autoreverses: false), value: spinRing)
                Circle()
                    .trim(from: 0.3, to: 0.85)
                    .stroke(
                        AngularGradient(
                            colors: [.clear, .white.opacity(0.8), .clear],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
                    )
                    .frame(width: 164, height: 164)
                    .rotationEffect(.degrees(spinRing ? -360 : 0))
                    .animation(.linear(duration: 5.2).repeatForever(autoreverses: false), value: spinRing)

                // ⑦ 底部内阴影
                Circle()
                    .stroke(Color.black.opacity(0.14), lineWidth: 3)
                    .frame(width: 174, height: 174)
                    .offset(y: 2)
                    .blur(radius: 2)
                    .mask(
                        Circle().frame(width: 180, height: 180)
                            .offset(y: 2)
                    )

                // ⑧ 数字 + 副标题
                VStack(spacing: 2) {
                    Text("\(securityScore)")
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    Text(scoreSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .offset(y: 4)
            }
            .frame(height: 240)
            .onAppear {
                breathe = true
                spinRing = true
            }
            .onChange(of: securityScore) { _, _ in
                // 分数变化给球体一个"呼吸脉冲"
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
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
