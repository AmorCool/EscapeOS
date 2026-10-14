import SwiftUI
import UIKit

/// 拉起应用（Launch Apps，汉化移植自 StikDebug 的 Other / Launch 标签页）.
/// 列出全部已安装应用（含系统应用），点击即以普通方式启动（不启用 JIT）.
///
/// 布局（本轮）：**布局 E（自适应网格）** —— 应用是「尺寸一致的图标条目流」，用 `AppAdaptiveGrid`
/// 按最小宽度自动决定列数（横竖屏 / 不同机型都铺满），比一列横条更像「启动台」.
///
/// 滚动性能：应用列表可达上百项，`AppAdaptiveGrid` 的单元格是**滚入视野才创建**；阶梯入场
/// 只作用于首屏窗口（见 `AppAppear.staggerWindow`），窗口外立即可见 —— 否则「绝对序号 × 步长」
/// 的延迟会让滚到后面的格子空白数秒，表现就是「上滑下滑反应一会」.
struct LaunchAppsView: View {
    @State private var apps: [JITAppInfo] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var searchText = ""
    @State private var launchingBundleIDs: Set<String> = []
    @State private var feedback: LaunchFeedback?
    /// 常驻搜索框在滚动内容区顶部实测的遮挡高度（由 `SearchBarInsetProbe` 从系统视图树量出，不写死）.
    /// 首帧为 0；探针量到后立刻回填，内容区随即让位 —— 量到之前也不会比「不占位」更差.
    @State private var searchBarInset: CGFloat = 0

    private var hasPairing: Bool { TunnelContext.shared.hasPairingFile }

    private var filteredApps: [JITAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading && apps.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("正在枚举已安装应用…")
                        Spacer()
                    }
                    .padding(.vertical, 40)
                } else if apps.isEmpty && !isLoading {
                    if !hasPairing {
                        PairingGuideCard(showsBackground: false, note: "拉起应用还需要 LocalDevVPN 已连接.")
                    } else {
                        // 空态 banner：与「空间回收」同款（`InfoActionCard` 白底圆角卡）.
                        InfoActionCard(
                            icon: "arrow.clockwise",
                            title: "未获取到应用列表",
                            message: "点击右上角刷新重试；仍为空请确认 LocalDevVPN 已连接、配对文件有效."
                        )
                        .appCard()
                    }
                } else if !searchText.isEmpty && filteredApps.isEmpty {
                    // 搜索无结果 banner：与「空间回收」的「立即扫描」同款视觉（白底圆角卡 + 左侧图标）.
                    InfoActionCard(
                        icon: "magnifyingglass",
                        title: "没有匹配的应用",
                        message: "换个名称或 Bundle ID 试试."
                    )
                    .appCard()
                } else {
                    AppSectionHeader("全部应用",
                                     subtitle: "共 \(filteredApps.count) 个",
                                     symbol: "app.grid.3x3")
                    AppAdaptiveGrid(items: filteredApps, minimum: 92, spacing: 12) { app in
                        launchTile(app)
                    }
                    Text("点击应用即将其在前台拉起（普通启动，不启用 JIT）.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
            // 测量探针：0 高度、不参与布局，只挂在内容里（这样能顺着 UIKit 视图树找到本页滚动视口）.
            .background(alignment: .top) {
                SearchBarInsetProbe(inset: $searchBarInset)
                    .frame(height: 0)
                    .allowsHitTesting(false)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        // 常驻搜索框的占位：把滚动内容区顶部让出「搜索框实测高度」，网格第一行不再被压住.
        // 高度来自 `SearchBarInsetProbe`（机型 / 横竖屏 / 动态字号自适应），不写死.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: searchBarInset)
        }
        .navigationTitle("拉起应用")
        .navigationBarTitleDisplayMode(.inline)
        // 搜索框常驻（`displayMode: .always`）——用户 2026-10-13 要求「回到之前那样常驻」.
        // 本页容器是 `ScrollView`（全仓唯一一个「滚动容器 + 搜索框」的页面，其余同款搜索框页面
        // 都是 `List`）：`List` 会把常驻搜索框计入内容安全区，`ScrollView` 不会，直接 `.always`
        // 搜索框就成了压在内容上的常驻浮层、网格第一行被盖住（2026-10-12 回归）。
        // 所以常驻必须与上面的 `.safeAreaInset(edge: .top)` 成对出现：由探针量出搜索框实际
        // 遮挡高度后让位 —— 既常驻，又不遮挡. 与 `FileSharingAppsView.swift` v0.3.289 同根因.
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .onAppear {
            if apps.isEmpty { Task { await load() } }
        }
        .overlay(alignment: .bottom) {
            if let feedback {
                Text(feedback.message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .foregroundStyle(feedback.success ? .green : .red)
                    .shadow(radius: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .alert("拉起失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    /// 自适应网格里的应用格子（布局 E）：大图标 + 名称居中，点击拉起；拉起中盖一层毛玻璃 + 转圈.
    private func launchTile(_ app: JITAppInfo) -> some View {
        Button {
            AppHaptics.tap()
            launch(app)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    JITAppIconView(bundleID: app.bundleID, size: 60)
                    if launchingBundleIDs.contains(app.bundleID) {
                        RoundedRectangle(cornerRadius: 60 * (8.0 / 36.0), style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 60, height: 60)
                        ProgressView()
                    }
                }
                Text(app.name)
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .appPressable(scale: 0.94)
        .disabled(launchingBundleIDs.contains(app.bundleID))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let apps = try await Task.detached(priority: .userInitiated) {
                try JITEnableService.shared.listAllApps()
            }.value
            await MainActor.run { self.apps = apps }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func launch(_ app: JITAppInfo) {
        guard !launchingBundleIDs.contains(app.bundleID) else { return }
        launchingBundleIDs.insert(app.bundleID)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableService.shared.launchApp(bundleID: app.bundleID)
                }.value
                await MainActor.run {
                    launchingBundleIDs.remove(app.bundleID)
                    showFeedback("「\(app.name)」已启动", success: true)
                }
            } catch {
                await MainActor.run {
                    launchingBundleIDs.remove(app.bundleID)
                    showFeedback("「\(app.name)」启动失败", success: false)
                }
            }
        }
    }

    private func showFeedback(_ message: String, success: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            feedback = LaunchFeedback(message: message, success: success)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                feedback = nil
            }
        }
    }
}

private struct LaunchFeedback: Identifiable {
    let id = UUID()
    let message: String
    let success: Bool
}

// MARK: - 常驻搜索框遮挡高度探针

/// 实测「常驻搜索框压在滚动内容上的高度」，把这段高度交给 `.safeAreaInset(edge: .top)` 占位.
///
/// 为什么需要：`.searchable(placement: .navigationBarDrawer(displayMode: .always))` 的常驻搜索框
/// 在 `List` 里由系统计入内容安全区；本页容器是 `ScrollView`，系统不做这一步，搜索框会浮在
/// 滚动内容上、网格第一行被压住。这里自己从 UIKit 视图树量出真实遮挡高度。
///
/// ⚠️ 遮挡量 = **搜索框底边 − 导航栏底边**（= 搜索框自身占的那一条），**不是**「搜索框底边 −
/// 滚动视口顶边」：`ScrollView` 的 frame 全出血顶到屏幕顶，而系统已把「状态栏 + 导航栏」这段
/// 高度算进了内容安全区，内容实际从**导航栏底边**开始。旧算法没扣掉这段 ⇒ 顶部多出一大片空白
/// （2026-10-13 用户报「拉起应用 空旷的地方」）.
///
/// 高度**不写死**：量的是 `UISearchBar` / `UISearchTextField` 相对同页导航栏的高度（随机型、
/// 横竖屏、动态字号变化）。量不到搜索框则回 0 —— 此时也不存在常驻搜索框，0 正是正确值。
///
/// 布局期不直接改 SwiftUI 状态（会触发「在视图更新中改状态」），一律下一轮主线程回填；
/// 且只在数值真正变化时回填，避免「回填 → 重排 → 再回填」的自激循环.
private struct SearchBarInsetProbe: UIViewRepresentable {
    @Binding var inset: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onMeasure = Self.publisher(for: $inset)
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onMeasure = Self.publisher(for: $inset)
        uiView.measure()
    }

    /// 只在数值变化（容差 0.5pt）时回填，异步回主线程，避免自激.
    private static func publisher(for binding: Binding<CGFloat>) -> @MainActor (CGFloat) -> Void {
        { value in
            guard abs(value - binding.wrappedValue) > 0.5 else { return }
            binding.wrappedValue = value
        }
    }

    final class ProbeView: UIView {
        var onMeasure: (@MainActor (CGFloat) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            measure()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        func measure() {
            guard let window else { return }
            // ① 本页滚动视口：从探针沿 superview 上溯找最近的 UIScrollView.
            var node: UIView? = superview
            while let current = node, !(current is UIScrollView) { node = current.superview }
            guard let scrollView = node as? UIScrollView else { return }

            // ② 同一页的导航栏 / 搜索框：沿滚动视口上溯，找到第一层含导航 chrome 的祖先即停
            //    （避免上溯到 window 根、误取其它页面的搜索框）.
            var searchFrame: CGRect?
            var navBottom: CGFloat?
            var ancestor = scrollView.superview
            while let current = ancestor {
                let chrome = Self.navigationChrome(in: current, skipping: scrollView)
                if chrome.search != nil || chrome.navBar != nil {
                    if let search = chrome.search {
                        searchFrame = search.convert(search.bounds, to: window)
                    }
                    if let navBar = chrome.navBar {
                        navBottom = navBar.convert(navBar.bounds, to: window).maxY
                    }
                    break
                }
                ancestor = current.superview
            }

            // ③ 真实遮挡量 = 搜索框底边 − **导航栏底边**（不是滚动视口顶边）.
            //
            //    关键：`ScrollView` 的 frame 全出血顶到屏幕顶，系统已把「状态栏 + 导航栏」这段
            //    高度算进了内容安全区 —— 内容实际从**导航栏底边**开始。故需要额外让出的只是
            //    「搜索框自身高度」这一条。旧实现量「搜索框底边 − 滚动视口顶边」，把系统已经让过
            //    的「状态栏 + 导航栏」又加了一遍 ⇒ 顶部多出一大片空白（2026-10-13 用户报）.
            let value: CGFloat
            if let searchFrame {
                if let navBottom {
                    value = max(0, searchFrame.maxY - navBottom)
                } else {
                    // 无导航栏兜底：搜索框自身高度即它压在内容上的高度.
                    value = max(0, searchFrame.height)
                }
            } else {
                // 没有常驻搜索框 ⇒ 无需让位.
                value = 0
            }
            Task { @MainActor [weak self] in
                self?.onMeasure?(value)
            }
        }

        /// 在 `root` 子树里找**搜索框**与**导航栏**；`skip` 及其子树跳过，避免误取本页滚动内容.
        ///
        /// 两者都要：搜索框底边给出它压到哪，导航栏底边给出系统已经让过的内容顶边 —— 二者相减
        /// 才是需要额外让出的高度（见 `measure()` ③）。`UISearchBar` 优先于 `UISearchTextField`
        /// （前者含内边距，高度更接近真实占位）。
        private static func navigationChrome(in root: UIView, skipping skip: UIView) -> (search: UIView?, navBar: UIView?) {
            var searchBar: UIView?
            var searchField: UIView?
            var navBar: UIView?
            var stack: [UIView] = [root]
            while let current = stack.popLast() {
                if current === skip { continue }
                if current is UISearchBar {
                    if searchBar == nil { searchBar = current }
                } else if current is UISearchTextField {
                    if searchField == nil { searchField = current }
                } else if current is UINavigationBar, navBar == nil {
                    navBar = current
                }
                stack.append(contentsOf: current.subviews)
            }
            return (searchBar ?? searchField, navBar)
        }
    }
}
