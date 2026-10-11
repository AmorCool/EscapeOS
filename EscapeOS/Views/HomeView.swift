import SwiftUI

/// v0.3.xxx：主页按**巨魔录音机（TRApp）设计语言**重做（原 2×N 网格卡片 → inset-grouped 分组列表）.
///
/// 设计口径（对照 `P4_全能签逆向/_简报/逆向_巨魔录音机UI完整规范.md`，只借**结构 / 节奏**，
/// 不照抄内容）：
/// - **页边距 20**（`AppTheme.pageInset`，原 16）；**大标题**走系统 `.large`（34pt bold）.
/// - **功能入口改 inset-grouped 卡片分组**（连续圆角 + 分段标题），行 =
///   连续圆角图标底 + **17pt semibold** 标题 + **13pt footnote** 副标题 + 右 chevron
///   （TRApp 设置列表行语言；分隔线左缩进对齐标题）.
/// - **强调色**用 TRApp 实测 `#005493`（`AppTheme.trAccent`）；**不全局改** `AppTheme.accent`
///   （全 App 影响面大，决定与理由见简报 §③）.
/// - **不用纯蓝实底按钮**：hero 的「立即体检」改 `TintedButtonStyle` 淡蓝底（圆角 `AppRadius.button`）.
/// - 图标 `.hierarchical` 分层渲染；百宝箱入口 `.symbolEffect(.bounce)` + 触觉.
///
/// v0.3.219：Hero 换装 Metal 实时液态玻璃球（LiquidGlassOrbView + LiquidGlassOrb.metal）.
/// v0.3.207：百宝箱 = 系统原生 sheet（presentationDetents 0.4↔1.0，原生上拉展开/
/// 下拉关闭——跟手流畅，返回不必点横线；把手区点击或上滑触发）.
struct HomeView: View {
    @ObservedObject var appList: AppListViewModel
    /// v0.3.197：安全评分（占位 — 后续接入 SecurityPresets.plist + Reveil 思路实做）.
    @State private var securityScore: Int = 92
    /// v0.3.207：百宝箱 sheet
    @State private var treasureOpen = false
    /// 百宝箱入口图标弹跳动效触发值（TRApp `Symbols18BounceSymbolEffect` 语言）.
    @State private var treasureBounce = 0

    /// v0.3.441：Gestalt 不再占底部 tab，改从百宝箱进入。
    /// 为什么要 pendingGestalt 这个中转：直接在 sheet 里 push 会套第二层导航栈（页面没返回按钮），
    /// 而「关掉 sheet 再 push」必须等 sheet **完全关闭**才 push，否则导航会被吞掉 ——
    /// 所以用 sheet 的 onDismiss 作为时机。
    @State private var showGestalt = false
    @State private var pendingGestalt = false
    /// 顽固图标清理页（与 Gestalt 同一套「sheet 关闭后再 push」的中转）
    @State private var showIconCleanup = false
    @State private var pendingIconCleanup = false
    /// 反激活设备页（同一套「sheet 关闭后再 push」的中转）
    @State private var showDeactivate = false
    @State private var pendingDeactivate = false
    /// 软件源管理页（同一套「sheet 关闭后再 push」的中转）
    @State private var showSignSource = false
    @State private var pendingSignSource = false
    /// 爱思应用修复安装页（同一套「sheet 关闭后再 push」的中转）
    @State private var showI4Fix = false
    @State private var pendingI4Fix = false
    /// 安装爱思移动端页（同一套「sheet 关闭后再 push」的中转）
    @State private var showMobileInstall = false
    @State private var pendingMobileInstall = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                cleanupSection
                deviceSection
                extensionSection
                treasureCard
                Spacer(minLength: 8)
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .sheet(isPresented: $treasureOpen, onDismiss: {
            // v0.3.441：百宝箱里点了「Gestalt 编辑」→ 等 sheet 完全关闭后再 push
            // （sheet 还在收场时 push 会被导航系统吞掉）
            if pendingGestalt {
                pendingGestalt = false
                showGestalt = true
            }
            if pendingIconCleanup {
                pendingIconCleanup = false
                showIconCleanup = true
            }
            if pendingDeactivate {
                pendingDeactivate = false
                showDeactivate = true
            }
            if pendingSignSource {
                pendingSignSource = false
                showSignSource = true
            }
            if pendingI4Fix {
                pendingI4Fix = false
                showI4Fix = true
            }
            if pendingMobileInstall {
                pendingMobileInstall = false
                showMobileInstall = true
            }
        }) {
            // 原生 sheet：0.4↔1.0 detent 上拉展开、下拉关闭
            TreasureBoxView(onOpenGestalt: {
                pendingGestalt = true
                treasureOpen = false
            }, onOpenIconCleanup: {
                pendingIconCleanup = true
                treasureOpen = false
            }, onOpenDeactivate: {
                pendingDeactivate = true
                treasureOpen = false
            }, onOpenSignSource: {
                pendingSignSource = true
                treasureOpen = false
            }, onOpenI4Fix: {
                pendingI4Fix = true
                treasureOpen = false
            }, onOpenMobileInstall: {
                pendingMobileInstall = true
                treasureOpen = false
            })
            .presentationDetents([.fraction(0.4), .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
            .interactiveDismissDisabled(false)
        }
        // v0.3.441：Gestalt 编辑页。挂在这里是因为 HomeView 就是 RootView 里
        // `NavigationStack { HomeView(...) }` 的内容视图，本修饰符链天然位于该栈内部。
        .navigationDestination(isPresented: $showGestalt) {
            GestaltView()
        }
        .navigationDestination(isPresented: $showIconCleanup) {
            IconCleanupView()
        }
        .navigationDestination(isPresented: $showDeactivate) {
            ActivationView()
        }
        // 软件源管理（源列表）。右上角「下载管理」入口由 `SignSourceListView` **自己** push
        // （`downloadManagerDestination` 接线）：二级页是标准子级 push，才有系统返回箭头。
        // ⚠️ 不要再在**本根级**另挂一个 `navigationDestination(isPresented:)` 去 push 二级页 ——
        // 一级页的 `isPresented` 绑定此时仍为 `true`，两个「钉在栈顶」的 `isPresented` 目的地
        // 会让二级页失去返回箭头（用户实测「进下载管理没有返回按钮」）。
        .navigationDestination(isPresented: $showSignSource) {
            SignSourceListView(downloadManagerDestination: {
                AnyView(IPADownloadManagerView(filterSource: [.thirdPartySource]))
            })
        }
        // 爱思应用修复安装（读 + 可选写设备 i4tool2.acc，含读回校验）
        .navigationDestination(isPresented: $showI4Fix) {
            I4AppFixView()
        }
        // 安装爱思移动端（爱思 9.0 对话框移植；内嵌 IPA 为 FairPlay 加密包）
        .navigationDestination(isPresented: $showMobileInstall) {
            // 把 Service 的安装动作注入 View：不注入则 installAction 恒为 nil，
            // 页面恒显「本页未接入安装动作」且主按钮 .disabled(true)（接线断裂）。
            // 用 makeInstallCachedAction（**只装已缓存的包**，跳过未缓存的）—— 页面主按钮要的是
            // 「把已经下好的包装上」；旧接线用 makeInstallAllAction（要求内置三包全缓存，缺一即抛），
            // 用户实测只缓存了 220.ipa 时点「开始安装」却报「缓存里没有 217.ipa」，已缓存的 220 也不装。
            // 其返回类型 () async throws -> Void 与 I4MobileInstallView.installAction 精确匹配。
            // onLog 转发到 LoginLogger(.i4Fix)，与 I4AppFixView 同一板块。
            I4MobileInstallView(installAction: I4MobileInstallService.makeInstallCachedAction(
                onLog: { LoginLogger.shared.log($0, category: .i4Fix) }))
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

    /// 打开百宝箱 sheet（点击/上滑触发）：触觉 + 图标弹跳.
    private func openTreasure() {
        AppHaptics.tap()
        treasureBounce += 1
        treasureOpen = true
    }

    // MARK: Hero —— 灵动球 + 分数 + 立即体检

    // v0.3.219：Metal 实时液态玻璃球（折射 + RGB 色散 + 菲涅尔 + 焦散 + 液态轮廓，
    // 移植自 liquid-glass v2 WebGL 样板；组件见 LiquidGlassOrbView.swift，
    // 着色器见 LiquidGlassOrb.metal；iOS 17 以下回退旧版圆环进度样式）.
    private var heroCard: some View {
        VStack(spacing: 14) {
            LiquidGlassOrbView(score: securityScore, tint: scoreColor)
            Text(scoreSubtitle)
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
            // 立即体检：淡蓝底按钮（**不是纯蓝实底**），圆角对齐 TRApp 大按钮（12）.
            NavigationLink {
                HealthCheckView(score: $securityScore)
            } label: {
                Label("立即体检", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle(tint: AppTheme.trAccent, radius: AppRadius.button))
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    // MARK: 功能分组（inset-grouped 卡片，TRApp 设置列表语言）

    private var cleanupSection: some View {
        featureSection(title: "清理与优化", symbol: "sparkles") {
            navRow(title: "空间回收", subtitle: "扫描可清理的应用缓存",
                   icon: "internaldrive", tint: AppTheme.trAccent) {
                SpaceReclaimView(appList: appList)
                    .navigationBarTitleDisplayMode(.inline)
            }
            rowDivider
            navRow(title: "设备瘦身", subtitle: "空间占用分析 / 缓存清理",
                   icon: "arrow.down.to.line", tint: AppTheme.trRecoverable) {
                DeviceSlimView()
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var deviceSection: some View {
        featureSection(title: "设备与系统", symbol: "iphone.gen3") {
            navRow(title: "应用管理", subtitle: "管理已安装应用",
                   icon: "square.grid.2x2.fill", tint: AppTheme.trAccent) {
                AppListView(viewModel: appList)
            }
            rowDivider
            navRow(title: "电池健康", subtitle: "循环次数 / 容量 / 健康度",
                   icon: "battery.75percent", tint: AppTheme.trSuccess) {
                BatteryHealthView()
            }
            rowDivider
            navRow(title: "设备信息", subtitle: "机型 / 系统 / CPU / 存储",
                   icon: "iphone.gen3", tint: AppTheme.trRecoverable) {
                DeviceInfoView()
            }
            rowDivider
            navRow(title: "文档浏览", subtitle: "开启文件共享的 App 文档目录",
                   icon: "folder.fill", tint: AppTheme.trAccent) {
                FileSharingAppsView()
            }
        }
    }

    private var extensionSection: some View {
        featureSection(title: "扩展与商店", symbol: "shippingbox.fill") {
            navRow(title: "模块", subtitle: "模块管理",
                   icon: "shippingbox.fill", tint: AppTheme.trAccent) {
                ModuleManagerView()
                    .navigationBarTitleDisplayMode(.inline)
            }
            rowDivider
            navRow(title: "AppStore 商店", subtitle: "榜单 / 搜索 / 应用详情",
                   icon: "app.badge.fill", tint: AppTheme.trAccent) {
                AppStoreView()
            }
        }
    }

    // MARK: 百宝箱入口（上拉抽屉；点击/上滑触发）

    /// 主页底部百宝箱入口：点击或上滑手势进入百宝箱抽屉（面板从底部滑动进入）.
    ///
    /// 用 `onTapGesture` + `highPriorityGesture`（沿用真机验证过的旧实现），**不套 Button** ——
    /// Button 的点击手势与这里的高优先级 DragGesture 并存时，真机上点击可能被拖拽手势吞掉.
    private var treasureCard: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: "shippingbox.and.arrow.backward.fill",
                       tint: AppTheme.trAccent, symbolSize: 16, frameSize: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("百宝箱")
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.primary)
                Text("小工具集 · 点击或上拉展开")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .appSymbol()
                .symbolEffect(.bounce, value: treasureBounce)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
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

    // MARK: - 通用视觉件（TRApp inset-grouped 语言）

    /// 分段标题：SF Symbol + 次级字色小标题，位于卡片**上方**（inset-grouped 分段口径）.
    private func sectionHeader(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.trAccent)
                .appSymbol()
            Text(title)
                .font(AppFont.captionEmphasis)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// 行分隔线：左缩进对齐到图标底右侧（图标 30 + 间距 12 + 左内边距 14 = 56）.
    private var rowDivider: some View {
        Divider().padding(.leading, 56)
    }

    /// 功能分组：分段标题 + 连续圆角卡片（行内 0 间距，靠 `rowDivider` 分隔）.
    private func featureSection<Content: View>(
        title: String, symbol: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title, symbol)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCard(padding: 0)
        }
    }

    /// 功能行：`HomeRowLabel` 作 label 的 `NavigationLink`（`.plain` 样式，保留整行点击）.
    private func navRow<Destination: View>(
        title: String, subtitle: String, icon: String, tint: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HomeRowLabel(icon: icon, tint: tint, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
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

/// 主页功能行标签（TRApp inset-grouped 行语言）：连续圆角图标底 + 17pt semibold 标题 +
/// 13pt footnote 副标题 + 右侧 chevron. 仅作 `HomeView.navRow` 的 label 使用.
private struct HomeRowLabel: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: icon, tint: tint, symbolSize: 16, frameSize: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .appSymbol()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
