import SwiftUI

/// v0.3.xxx：主页按**多色板 + 混合布局**重做（原「3 个全宽行分组 + 全蓝图标」）。
///
/// ## 为什么改（用户原话：「主页布局优化一下 我感觉很丑陋 单一」）
/// 改前主页的问题不是「某一处丑」，而是**整页只有一种语言**：
/// - 8 个功能入口的图标底**全是同一个蓝**（`AppTheme.accent` 占了 5 处）—— 没有模块区分。
/// - 所有入口都是**同一种形状**（全宽横条 + 30pt 图标 + 右 chevron），一屏 8 条一模一样的横条。
/// - 所有卡片都是**同一种底**（`secondarySystemGroupedBackground`），没有层次。
/// - 分段标题是 12pt 灰字 + 小图标，在页面里**立不起来**。
/// - 已定义好的 14 个新色 token（8 模块色 / 4 表面层 / 2 强调变体 / 3 渐变）**一个都没用上**。
///
/// ## 改后（Hero + Bento 网格 + 分组行）
/// - **Hero**：orb 卡片 = `surfaceCard` + 发丝描边（**不再叠加任何渐变 banner**，见下）。
/// - **设备与系统 → 2 列 Bento 网格**（4 个平级工具入口）：每格是**自己的模块色**的淡色
///   渐变卡 + 模块色图标底，是页面的「彩色中心」。
/// - **清理与优化 / 扩展与商店 → 全宽行**（保持「词条 + 说明」的列表语言），
///   但每行图标底换用**自己的模块色**（不再全蓝）。
/// - **分段标题**统一 `AppSectionHeader`，且**竖条 / 符号取该分组自己的模块色**（与组内内容同色）。
/// - **百宝箱**入口换紫色身份，保留点击 / 上滑手势。
/// - 页面底 `surfaceBase`、卡片 `surfaceCard` —— 用上新表面层，撑起层次。
///
/// ## 硬规则对齐
/// - 不用纯蓝实底按钮：hero 的「立即体检」仍是 `TintedButtonStyle`（半透明着色 + 发丝描边）。
/// - 模块色只出现在**紧凑图标底 / 淡色卡底**（不透明度 ≤14%），不做全宽深色实底。
/// - 界面文案一律英文句点 `.`。
///
/// v0.3.599：**去棕 + 去悬浮球 banner**（用户原话：「我不喜欢棕色的颜色 主页你踩雷了 特别是你看
/// "扩展与商店"那两个选区的颜色 你不许用棕色」「主页那个悬浮球背景还叠加一层 banner 看着怪别扭」）。
/// - `categoryStore` 橙棕 `#C2620E` → 冷青蓝 `#0B8FC9`（「扩展与商店」两行随之去棕）。
/// - `categoryAdvanced` 砖红 `#BF3A2B` → 正红 `#E5342B`（同属暖棕族，一并去棕）。
/// - hero 卡片删除叠加的冷色渐变 banner 层。
/// - 分组头竖条改用各分组模块色（不再统一蓝）。
/// v0.3.219：Hero 换装 Metal 实时液态玻璃球（LiquidGlassOrbView + LiquidGlassOrb.metal）。
/// v0.3.207：百宝箱 = 系统原生 sheet（presentationDetents 0.4↔1.0，原生上拉展开 /
/// 下拉关闭，跟手流畅，返回不必点横线；把手区点击或上滑触发）。
struct HomeView: View {
    @ObservedObject var appList: AppListViewModel
    /// v0.3.197：安全评分（占位，后续接入 SecurityPresets.plist + Reveil 思路实做）。
    @State private var securityScore: Int = 92
    /// v0.3.207：百宝箱 sheet
    @State private var treasureOpen = false
    /// 百宝箱入口图标弹跳动效触发值（TRApp `Symbols18BounceSymbolEffect` 语言）。
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
    /// 开启高级功能页（同一套「sheet 关闭后再 push」的中转）
    @State private var showI4Advanced = false
    @State private var pendingI4Advanced = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                heroCard.appAppear(index: 0)
                cleanupSection.appAppear(index: 1)
                deviceSection.appAppear(index: 2)
                extensionSection.appAppear(index: 3)
                treasureCard.appAppear(index: 4)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.surfaceBase)
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
            if pendingI4Advanced {
                pendingI4Advanced = false
                showI4Advanced = true
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
            }, onOpenI4Advanced: {
                pendingI4Advanced = true
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
        // 不要再在**本根级**另挂一个 `navigationDestination(isPresented:)` 去 push 二级页 ——
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
        // 开启高级功能（写设备端爱思移动端沙盒的配对 / 授权文件；独立入口，不再藏在安装流程里）
        .navigationDestination(isPresented: $showI4Advanced) {
            I4AdvancedView()
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

    /// 打开百宝箱 sheet（点击/上滑触发）：触觉 + 图标弹跳。
    private func openTreasure() {
        AppHaptics.tap()
        treasureBounce += 1
        treasureOpen = true
    }

    // MARK: Hero —— 灵动球 + 分数 + 立即体检

    // v0.3.219：Metal 实时液态玻璃球（折射 + RGB 色散 + 菲涅尔 + 焦散 + 液态轮廓，
    // 移植自 liquid-glass v2 WebGL 样板；组件见 LiquidGlassOrbView.swift，
    // 着色器见 LiquidGlassOrb.metal；iOS 17 以下回退旧版圆环进度样式）。
    //
    // ⚠️ 改前本卡在 `surfaceCard` 之上**又叠了一层冷色渐变 banner**（download 蓝 10% → clean 青 3%，
    // 顶→底）。用户原话「主页那个悬浮球背景还叠加一层 banner 看着怪别扭 我不喜欢」—— 那层渐变
    // 与球体自身的极光语言**互相打架**（两层冷色叠加，边界糊成一条脏带），且违背硬规则 1 的
    // 「不做全宽 banner」精神。现**整层删除**：只留 `surfaceCard` + 一条发丝描边，让球体自己
    // 成为唯一焦点，卡片回归干净.
    private var heroCard: some View {
        VStack(spacing: 14) {
            LiquidGlassOrbView(score: securityScore, tint: scoreColor)
            Text(scoreSubtitle)
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
            // 立即体检：淡蓝底按钮（**不是纯蓝实底**），圆角对齐 TRApp 大按钮（12）。
            NavigationLink {
                HealthCheckView(score: $securityScore)
            } label: {
                Label("立即体检", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TintedButtonStyle(tint: AppTheme.accent, radius: AppRadius.button))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppTheme.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(AppTheme.accentBorder.opacity(0.30), lineWidth: 0.5)
        )
    }

    // MARK: 功能分组（分段标题 + 分组内容）

    /// 清理与优化：2 项「扫描 + 瘦身」，保持全宽行（词条 + 说明语言），
    /// 图标底换用**清理模块色**（青绿），不再是全蓝。分组头竖条同用清理模块色.
    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader("清理与优化", symbol: "sparkles", tint: AppModule.clean.tint)
            VStack(spacing: 0) {
                navRow(title: "空间回收", subtitle: "扫描可清理的应用缓存",
                       icon: "internaldrive", tint: AppModule.clean.tint) {
                    SpaceReclaimView(appList: appList)
                        .navigationBarTitleDisplayMode(.inline)
                }
                rowDivider
                navRow(title: "设备瘦身", subtitle: "空间占用分析 / 缓存清理",
                       icon: "arrow.down.to.line", tint: AppModule.clean.tint) {
                    DeviceSlimView()
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard(padding: 0)
        }
    }

    /// 设备与系统：4 个**平级**工具入口（无主次），改 **2 列 Bento 网格**（`AppCardGrid`），
    /// 每格用**自己的模块色**做淡色渐变卡 + 模块色图标底 —— 这是页面的「彩色中心」。
    /// 4 项用 4 个不同色相（靛蓝 / 绿 / 石板灰 / 蓝），一屏之内就看出「不再单一」。
    /// 分组头竖条用设备模块色（靛蓝），与组内主色呼应.
    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader("设备与系统", symbol: "iphone.gen3", tint: AppModule.device.tint)
            AppCardGrid(items: deviceTools, columns: 2) { tool in
                NavigationLink {
                    NavigationLazyView(tool.destination)
                } label: {
                    HomeToolTile(icon: tool.icon, title: tool.title,
                                 subtitle: tool.subtitle, tint: tool.tint)
                }
                .appPressable()
            }
        }
    }

    /// 扩展与商店：2 项「模块 + 商店」，保持全宽行。
    ///
    /// ⚠️ 改前两行图标底均为**橙棕** `AppModule.store.tint`（`#C2620E`）—— 用户点名的「棕色踩雷」处。
    /// `categoryStore` 已去棕改为**冷青蓝**，故此处两行随之变青蓝；分组头竖条同用商店模块色.
    private var extensionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader("扩展与商店", symbol: "shippingbox.fill", tint: AppModule.store.tint)
            VStack(spacing: 0) {
                navRow(title: "模块", subtitle: "模块管理",
                       icon: "shippingbox.fill", tint: AppModule.store.tint) {
                    ModuleManagerView()
                        .navigationBarTitleDisplayMode(.inline)
                }
                rowDivider
                navRow(title: "AppStore 商店", subtitle: "榜单 / 搜索 / 应用详情",
                       icon: "app.badge.fill", tint: AppModule.store.tint) {
                    AppStoreView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard(padding: 0)
        }
    }

    // MARK: 百宝箱入口（上拉抽屉；点击/上滑触发）

    /// 主页底部百宝箱入口：点击或上滑手势进入百宝箱抽屉（面板从底部滑动进入）。
    /// 换 **百宝箱模块色**（紫）身份：紫色淡渐变卡 + 紫图标底，与上方三组区分开。
    ///
    /// 用 `onTapGesture` + `highPriorityGesture`（沿用真机验证过的旧实现），**不套 Button** ——
    /// Button 的点击手势与这里的高优先级 DragGesture 并存时，真机上点击可能被拖拽手势吞掉。
    private var treasureCard: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: "shippingbox.and.arrow.backward.fill",
                       tint: AppModule.treasure.tint, symbolSize: 16, frameSize: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("百宝箱")
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.primary)
                Text("小工具集，点击或上拉展开")
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppModule.treasure.tint.opacity(0.7))
                .appSymbol()
                .symbolEffect(.bounce, value: treasureBounce)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppTheme.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                AppModule.treasure.tint.opacity(0.14),
                                AppModule.treasure.tint.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(AppModule.treasure.tint.opacity(0.20), lineWidth: 0.5)
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

    // MARK: - 数据（Bento 网格 4 项）

    /// 「设备与系统」4 个平级工具入口。每项自带**模块色**与目的地 —— 与 `MoreView.MoreItem`
    /// 同一模式（`AnyView` 懒加载目的地，点击时才创建）。
    private struct HomeTool: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let tint: Color
        let destination: AnyView

        init(id: String, icon: String, title: String, subtitle: String,
             tint: Color, @ViewBuilder destination: () -> some View) {
            self.id = id
            self.icon = icon
            self.title = title
            self.subtitle = subtitle
            self.tint = tint
            self.destination = AnyView(destination())
        }
    }

    /// 4 项模块色：靛蓝（设备）/ 绿（健康）/ 石板灰（信息）/ 蓝（文档）—— 色相各不相同。
    private var deviceTools: [HomeTool] {
        [
            HomeTool(id: "apps", icon: "square.grid.2x2.fill", title: "应用管理",
                     subtitle: "管理已安装应用", tint: AppModule.device.tint) {
                AppListView(viewModel: appList)
            },
            HomeTool(id: "battery", icon: "battery.75percent", title: "电池健康",
                     subtitle: "循环次数 / 容量 / 健康度", tint: AppTheme.success) {
                BatteryHealthView()
            },
            HomeTool(id: "device", icon: "iphone.gen3", title: "设备信息",
                     subtitle: "机型 / 系统 / CPU / 存储", tint: AppModule.settings.tint) {
                DeviceInfoView()
            },
            HomeTool(id: "docs", icon: "folder.fill", title: "文档浏览",
                     subtitle: "开启文件共享的 App 文档目录", tint: AppModule.download.tint) {
                FileSharingAppsView()
            }
        ]
    }

    // MARK: - 通用视觉件

    /// 行分隔线：左缩进对齐到图标底右侧（图标 30 + 间距 12 + 左内边距 14 = 56）。
    private var rowDivider: some View {
        AppHairline().padding(.leading, 56)
    }

    /// 功能行：`HomeRowLabel` 作 label 的 `NavigationLink`（`.plain` 样式，保留整行点击）。
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

/// 主页功能行标签：连续圆角图标底 + 17pt semibold 标题 + 13pt footnote 副标题 + 右侧 chevron。
/// 图标底走**该模块自己的色**（`tint`），不再全蓝。仅作 `HomeView.navRow` 的 label 使用。
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

/// 主页 Bento 网格单元：**模块色淡渐变卡**（`surfaceCard` + tint 14% → 3%）+ 模块色图标底 +
/// 标题 + 副标题。与 `AppGridTile`（白卡 + 彩图标）的区别在于**整格带色**，让网格成为页面的
/// 彩色中心；卡片与图标底都走 `AppRowIcon` / `AppRadius.card` 既有语言。
private struct HomeToolTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppRowIcon(systemName: icon, tint: tint, symbolSize: 18, frameSize: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.bodyEmphasis)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppTheme.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.14), tint.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}
