import SwiftUI

/// v0.3.295：AppStore 商店（主页新板块）
///
/// 数据源：Apple 公开接口（iTunes Search / Lookup / 官方榜单 RSS）。
/// 安装：免登录源直装（RSD 隧道）或跳转系统 App Store。
struct AppStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AppStoreRankKind = .free
    @State private var genre: AppStoreGenre = .all
    @State private var items: [AppStoreItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var keyword = ""
    @State private var searchResults: [AppStoreItem] = []
    @State private var searching = false
    @State private var showDisclaimer = false
    @State private var showI4 = false
    @State private var showFavorites = false
    /// 区域筛选（App Store 商场，默认 cn = 国区；`"auto"` = 跟随账号区）
    @AppStorage("AppStore.ShopRegion") private var shopRegion = "cn"
    // 列表行「获取」→ 安装方式选择
    @State private var installTarget: AppStoreItem?
    @State private var accountTarget: AppStoreItem?
    @ObservedObject private var center = IPADownloadCenter.shared

    /// v0.3.399：列表行**长按 →「查看图片」**用的全屏预览。
    ///
    /// 为什么还要 `previewImages` 这份数组：榜单走的是 RSS（`parseRSSEntry`），
    /// 服务端**根本不返回截图**，所以列表项自己的 `screenshots` 恒为空
    /// → 长按时先按 id 取一次 Lookup 拿图，再开预览（详见 `openImagePreview(for:)`）。
    @State private var previewImages: [String] = []
    @State private var previewTarget: ImagePreviewTarget?

    /// 实际生效的区域码（`"auto"` 在此解析成账号区）—— 用于标题文案
    private var resolvedCode: String { AppStoreService.resolveRegion(shopRegion) }

    /// 区域标题：常用区用中文名，其余（含「自动」解析出的陌生区）用大写码
    private var regionTitle: String {
        AppStoreService.Region(rawValue: resolvedCode)?.title ?? resolvedCode.uppercased()
    }

    /// v0.3.328：进入商店时按当前 Apple ID 同步区域。
    /// 只在**账号换了**才改（登录时已经跟随过一次）—— 用户手动挑的区域不会被每次进页面覆盖。
    /// 改的是同一个 `AppStorage` 键，`onChange(of: shopRegion)` 会自动清空搜索并重载榜单。
    private func syncRegionWithAccount() {
        // 用户显式选了「自动」就保持「自动」，不要被改写成具体区
        guard shopRegion != AppStoreService.autoRegion else { return }
        guard let account = AppStoreDownloadStore.shared.selectedAccount else { return }
        guard let followed = AppStoreService.followAccountRegionIfNeeded(
            email: account.email, storefront: account.store) else { return }
        shopRegion = followed
        ToastCenter.shared.show("已切换到账号区域 \(followed.uppercased())")
    }

    private var isSearchMode: Bool { !keyword.trimmingCharacters(in: .whitespaces).isEmpty }

    /// v0.3.303：免登录下载入口 —— 放在商店最显眼位置。
    ///
    /// 数据与安装包来自爱思 PC 端在用的公开接口（`app4.i4.cn` / `d-app6.i4.cn`），
    /// 服务端即为已签名 IPA，因此**不需要 Apple ID、也不需要配置任何分发源**。
    @ViewBuilder
    private var freeSection: some View {
        Section {
            NavigationLink {
                I4StoreFreeView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("免登录下载").font(.subheadline.weight(.medium))
                        Text("不用 Apple ID、不用配置，点一下就装")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// v0.3.308：账号管理 + **AppStore 独立日志**入口（此前商店里没有这两个入口）
    @ViewBuilder
    private var manageSection: some View {
        Section {
            NavigationLink {
                AppStoreAccountsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.badge.gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("账号管理").font(.subheadline.weight(.medium))
                        Text("多账号 / 退出登录")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            NavigationLink {
                AppStoreLogView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AppStore 日志").font(.subheadline.weight(.medium))
                        Text("只看 AppStore 板块（下载/安装）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    var body: some View {
        List {
            freeSection
            manageSection
            if isSearchMode {
                searchSection
            } else {
                regionSection
                chartsSection
                genreSection
                listSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AppStore 商店")
        .navigationBarTitleDisplayMode(.inline)
        // v0.3.367：用户要求「无论下滑状态都能搜索」→ 搜索栏常驻（原 .automatic 下滑会收起）。
        // 形态对齐主页「应用」板块的 `.searchable(..., displayMode: .always)`。
        .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用名 / BundleID")
        .onSubmit(of: .search) { runSearch() }
        .onAppear(perform: syncRegionWithAccount)
        .onChange(of: kind) { _, _ in Task { await loadCharts() } }
        .onChange(of: shopRegion) { _, code in
            AppStoreService.countryCode = code
            searchResults = []
            Task { await loadCharts() }
        }
        .onChange(of: genre) { _, _ in Task { await loadCharts() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await loadCharts() }
                    } label: {
                        Label("刷新榜单", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showI4 = true
                    } label: {
                        Label("爱思商店（专题 / 榜单）", systemImage: "cart.fill")
                    }
                    Button {
                        showFavorites = true
                    } label: {
                        Label("收藏栏", systemImage: "star")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showI4) { NavigationStack { AppStoreI4View() } }
        .sheet(isPresented: $showFavorites) { NavigationStack { AppFavoritesView() } }
        .sheet(item: $installTarget) { target in
            InstallOptionsSheet(
                appleIDSubtitle: appleIDSubtitle,
                onAppleID: {
                    installTarget = nil
                    chooseAppleIDAndInstall(target)
                },
                onI4: {
                    installTarget = nil
                    installFromFreeSource(target)
                },
                onAcquireLicense: {
                    installTarget = nil
                    acquireLicense(target)
                })
            .presentationDetents([.height(344)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $accountTarget) { target in
            AppleIDPickerSheet { email in
                accountTarget = nil
                IPADownloadCenter.shared.startWithAppleID(item: target, email: email)
                ToastCenter.shared.show("已开始用「\(email)」下载")
            }
            .presentationDetents([.medium])
        }
        // v0.3.399：列表行长按「查看图片」→ 与详情页/爱思源**同一套**预览组件
        .fullScreenCover(item: $previewTarget) { target in
            ImageGalleryViewer(urls: previewImages, startIndex: target.index)
        }
        .overlay {
            if showDisclaimer {
                AppStoreDisclaimerView(
                    onAccept: {
                        AppStoreDisclaimer.accept()
                        showDisclaimer = false
                    },
                    onDecline: {
                        showDisclaimer = false
                        dismiss()
                    }
                )
            }
        }
        .toastHost()
        .task {
            if !AppStoreDisclaimer.accepted { showDisclaimer = true }
            if items.isEmpty { await loadCharts() }
        }
    }

    // MARK: 榜单

    /// 区域筛选：切换后榜单 / 搜索 / 详情都按该区域取数据。
    /// 三段式：自动（跟随账号）→ 常用区域 → 其他地区（全表余下的，`XX - storefront id`）
    ///
    /// v0.3.363：「自动」时把**跟随到的那个区**标注出来（用户要求：不然不知道自动跟了哪个区）。
    /// 「自动」当前解析到的区域码（小写）；非自动模式返回空串，不标注。
    private var followedRegionCode: String {
        guard shopRegion == AppStoreService.autoRegion else { return "" }
        return AppStoreService.resolveRegion(AppStoreService.autoRegion)
    }

    private var regionSection: some View {
        Section {
            Picker("区域", selection: $shopRegion) {
                Text(AppStoreService.autoDisplay).tag(AppStoreService.autoRegion)
                Section("常用区域") {
                    ForEach(AppStoreService.Region.allCases) { r in
                        Text(r.rawValue == followedRegionCode ? "\(r.display) [自动跟随]" : r.display)
                            .tag(r.rawValue)
                    }
                }
                // v0.3.363：这节剔掉上面的常用区 —— 两节同 tag 会让 Picker 可能双勾选/标题错。
                Section("其他地区") {
                    ForEach(StoreRegions.excluding(Set(AppStoreService.Region.allCases.map(\.rawValue))),
                            id: \.code) { region in
                        Text(region.code.lowercased() == followedRegionCode
                             ? "\(region.code) - \(region.storefrontID) [自动跟随]"
                             : "\(region.code) - \(region.storefrontID)")
                            .tag(region.code.lowercased())
                    }
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var chartsSection: some View {
        Section {
            Picker("榜单", selection: $kind) {
                ForEach(AppStoreRankKind.allCases) { k in
                    Text(k.title).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private var genreSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AppStoreGenre.allCases) { g in
                        Button {
                            genre = g
                        } label: {
                            Text(g.title)
                                .font(.subheadline.weight(genre == g ? .semibold : .regular))
                                .foregroundStyle(genre == g ? Color.white : Color.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(genre == g ? Color.blue : Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if loading {
            Section {
                HStack {
                    Spacer()
                    ProgressView("正在加载榜单…")
                    Spacer()
                }
                .padding(.vertical, 40)
            }
        } else if let errorText {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.secondary)
                    Text(errorText).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await loadCharts() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }
        } else if items.isEmpty {
            Section {
                ContentUnavailableView("暂无数据", systemImage: "square.grid.2x2")
            }
        } else {
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, app in
                    storeRow(app, rank: idx + 1)
                }
            } header: {
                Text("\(regionTitle) · \(genre.title) · \(kind.title) · 共 \(items.count) 款")
            }
        }
    }

    // MARK: 搜索

    @ViewBuilder
    private var searchSection: some View {
        if searching {
            Section {
                HStack { Spacer(); ProgressView("搜索中…"); Spacer() }.padding(.vertical, 40)
            }
        } else if searchResults.isEmpty {
            Section {
                ContentUnavailableView.search(text: keyword)
            }
        } else {
            Section("\(regionTitle) 搜索结果 · \(searchResults.count) 款") {
                ForEach(searchResults) { app in
                    storeRow(app, rank: nil)
                }
            }
        }
    }

    // MARK: 行

    /// v0.3.399：榜单行 / 搜索结果行**共用**的行壳 —— 点进详情 + 长按菜单「查看图片」。
    /// 抽出来只是为了让两处不要各挂一份一模一样的 `contextMenu`（菜单只有一项，别再复制）。
    private func storeRow(_ app: AppStoreItem, rank: Int?) -> some View {
        NavigationLink {
            AppStoreDetailView(item: app)
        } label: {
            appRow(app, rank: rank)
        }
        .contextMenu {
            Button {
                openImagePreview(for: app)
            } label: {
                Label("查看图片", systemImage: "photo.on.rectangle")
            }
        }
    }

    /// v0.3.399：列表长按「查看图片」→ 全屏预览（图 = 详情页那组截图）。
    ///
    /// 为什么要按 id 再查一次：榜单走官方 RSS，`parseRSSEntry` **不解析 `screenshotUrls`**，
    /// 所以榜单项的 `screenshots` 恒定为空；搜索结果来自 `search`（`parseSearchItem`）自带截图，
    /// 这时就不再发网络请求。查不到图只提示一句，不开空预览。
    ///
    /// 函数名没叫 `previewImages`：那会和上面同名的 `@State previewImages` 撞在一起（同一个类型里
    /// 属性与函数同名容易读错），改叫 `openImagePreview` 更明确。
    private func openImagePreview(for app: AppStoreItem) {
        if !app.screenshots.isEmpty {
            previewImages = app.screenshots
            previewTarget = ImagePreviewTarget(index: 0)
            return
        }
        ToastCenter.shared.show("正在获取图片")
        Task {
            let shots = (try? await AppStoreService.lookup(id: app.id))?.screenshots ?? []
            guard !shots.isEmpty else {
                ToastCenter.shared.show("该应用没有可查看的图片")
                return
            }
            previewImages = shots
            previewTarget = ImagePreviewTarget(index: 0)
        }
    }

    private func appRow(_ app: AppStoreItem, rank: Int?) -> some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(rank <= 3 ? Color.orange : Color.secondary)
                    .frame(width: 22, alignment: .center)
            }
            iconView(app, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(app.primaryGenre ?? app.seller ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let r = app.ratingText {
                        Label(r, systemImage: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                    Text(app.priceText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(app.priceText == "免费" ? Color.green : Color.blue)
                }
            }
            Spacer(minLength: 6)
            Button {
                installTarget = app
            } label: {
                if center.activeJob(bundleId: app.bundleId, name: app.name) != nil {
                    ProgressView().controlSize(.mini).frame(width: 36)
                } else {
                    Text(app.priceText == "免费" ? "获取" : app.priceText)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(center.activeJob(bundleId: app.bundleId, name: app.name) != nil)
        }
        .padding(.vertical, 2)
    }

    private func iconView(_ app: AppStoreItem, size: CGFloat) -> some View {
        AsyncImage(url: URL(string: app.iconURL ?? app.iconSmallURL ?? "")) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFit()
            case .failure:
                Image(systemName: "app.dashed").foregroundStyle(.secondary)
            default:
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    // MARK: 加载

    private func loadCharts() async {
        loading = true
        errorText = nil
        do {
            let list = try await AppStoreService.charts(kind: kind, genre: genre, limit: 50)
            items = list
            if list.isEmpty { errorText = "该分类暂无榜单数据" }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func runSearch() {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { searchResults = []; return }
        searching = true
        Task {
            do {
                searchResults = try await AppStoreService.search(term: term)
            } catch {
                searchResults = []
                errorText = error.localizedDescription
            }
            searching = false
        }
    }

    /// Apple ID 通道的副标题
    private var appleIDSubtitle: String {
        let list = AppStoreDownloadStore.shared.usableAccounts
        if list.isEmpty { return "尚未登录 Apple ID" }
        if list.count == 1 { return list[0].email }
        return "共 \(list.count) 个账号，可自选"
    }

    private func chooseAppleIDAndInstall(_ app: AppStoreItem) {
        let list = AppStoreDownloadStore.shared.usableAccounts
        guard !list.isEmpty else {
            ToastCenter.shared.show("尚未登录 Apple ID —— 请改用「从爱思源快速安装」")
            return
        }
        if list.count > 1 {
            accountTarget = app
            return
        }
        IPADownloadCenter.shared.startWithAppleID(item: app, email: list[0].email)
        ToastCenter.shared.show("已开始用「\(list[0].email)」下载")
    }

    /// 免登录源：按 bundleId 找包 → 下载 → 安装。
    /// 榜单 RSS 不带 bundleId（已在加载时批量补全），这里再兜一次按 AppID 反查。
    /// 获取许可证：用「当前下载账号」把该应用加入授权列表（免费应用）
    private func acquireLicense(_ app: AppStoreItem) {
        guard let email = AppStoreDownloadStore.shared.selectedEmail, !email.isEmpty else {
            ToastCenter.shared.show("先登录一个 Apple ID")
            return
        }
        ToastCenter.shared.show("正在获取许可证…")
        Task {
            do {
                let message = try await AppStoreLocalInstallService.acquireLicense(
                    item: app, email: email) { line in
                        LoginLogger.shared.log("[下载中心] \(line)", category: .appStore)
                    }
                ToastCenter.shared.show(message)
            } catch {
                ToastCenter.shared.show("获取许可证失败：\(error.localizedDescription)")
                LoginLogger.shared.log("[下载中心] 获取许可证失败：\(error.localizedDescription)",
                                       category: .appStore)
            }
        }
    }

    private func installFromFreeSource(_ app: AppStoreItem) {
        ToastCenter.shared.show("正在查找安装包…")
        Task {
            var bid = app.bundleId ?? ""
            if bid.isEmpty, let full = try? await AppStoreService.lookup(id: app.id) {
                bid = full.bundleId ?? ""
            }
            guard !bid.isEmpty else {
                ToastCenter.shared.show("无法确定该应用的 Bundle ID，不能从源匹配")
                return
            }
            _ = await IPADownloadCenter.shared.startFromI4Source(
                name: app.name, bundleId: bid, iconURL: app.iconURL,
                storeItemId: app.id)
        }
    }
}
