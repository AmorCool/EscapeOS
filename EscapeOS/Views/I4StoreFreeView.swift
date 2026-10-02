import SwiftUI

/// v0.3.303：免登录下载商店（爱思 PC 端源）
///
/// 与「AppStore 商店」的区别：**完全不需要登录 Apple ID，也不需要配置分发源**。
/// 数据与安装包都来自爱思 PC 端在用的公开接口（`app4.i4.cn` + `d-app6.i4.cn`），
/// 服务端存放的即为已签名 IPA（`isSignOK == "1"`）。
///
/// 流程：榜单/搜索 → 拿 `path` → `d-app6.i4.cn/soft/<path>` 下载 IPA
/// → `AppStoreInstallService.installLocalIPA`（RSD 隧道 + AFC + installation_proxy）。
///
/// v0.3.364：列表项可点进 `I4StoreFreeDetailView`（详情走 `appinfo.xhtml`），
/// 详情里列出爱思历史版本，安装旧版仍走同一条下载链路。
///
/// v0.3.406：**牛蛙源补上详情页与下载** —— 列表项可点进 `NiuwaStoreDetailView`，
/// 行右侧的「获取」（v0.3.408 前叫「安装」）走 `startNiuwaDownload(_:region:)`
/// （先取直链，再交给 `IPADownloadCenter`）。
struct I4StoreFreeView: View {

    /// v0.3.382：免登录商店的**来源**（接口一 = 爱思，接口二 = 牛蛙）
    ///
    /// v0.3.414：新增**第三来源 NB**（NB Pro）。
    ///
    /// v0.3.540：**修正对 NB 的误判**。此前以为「NB 没有榜单、也没有搜索，常规搜索就是转调爱思」——
    /// 这是只看了一个来源就外推的结论，实际是错的：
    ///   · **NB 有榜单** —— 逐条比对确认它就是 **Apple 官方排行榜**（RSS），
    ///     `NBStoreRankClient` 直接接 Apple，不再假装没有；
    ///   · **NB 有搜索** —— 走 **Apple 官方 search**，区域随 `regionRaw` 走，
    ///     所以美区能搜到美区应用、国区能搜到国区全部上架应用；
    ///   · 原来「借爱思搜索」的做法已删 —— 爱思是中国区商店，借它必然「美区空、国区少」。
    ///
    /// NB 与 Apple 的分工：**榜单/搜索的元数据用 Apple**（NB 自己也是转发的），
    /// **安装包仍然由 NB 通道取**（`NBStoreClient`，Apple RSS 不给包）。
    enum StoreSource: String, CaseIterable, Identifiable {
        case i4 = "爱思"
        case niuwa = "牛蛙"
        case nb = "NB"

        var id: String { rawValue }
    }

    /// v0.3.382：牛蛙源的分区（客户端硬编码中国/美国/香港三档）
    private var region: NiuwaStoreClient.NiuwaRegion { NiuwaStoreClient.NiuwaRegion(rawValue: regionRaw) ?? .cn }

    @State private var source: StoreSource = .i4
    @State private var regionRaw = "cn"
    @State private var rank: I4PCStoreClient.Rank = .recommend
    /// v0.3.540：NB 源的榜单分组（走 Apple RSS，与爱思那份是两套数据）.
    @State private var nbRank: NBStoreRankClient.Rank = .freeApps
    @State private var apps: [I4PCStoreClient.I4App] = []
    /// v0.3.540：NB 源榜单结果（Apple RSS）.
    @State private var nbRankItems: [NBStoreRankClient.RankItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var keyword = ""
    @State private var searchResults: [I4PCStoreClient.I4App] = []
    @State private var searching = false
    /// v0.3.382：牛蛙源的搜索结果（与爱思结果并存，切来源不必重打）
    @State private var niuwaSearchResults: [NiuwaStoreClient.NiuwaApp] = []
    /// v0.3.406：正在「取直链」的那一行（牛蛙要先打一发 `/appstore/download` 才有直链）。
    /// 存 bundleId 而不是 Bool：同一时刻只允许一行在取，且要能对上具体是哪一行。
    @State private var niuwaFetching: String?

    /// v0.3.414：NB 源的取包结果。
    ///
    /// NB 没有列表接口，一次查询只对应一个 trackId，所以这里存的是**单个**结果，
    /// 而不是像前两源那样的数组。`nbTrackID` 记下它是哪个 ID 的包（下载时要上报）。
    @State private var nbPackage: NBStoreClient.NBPackage?
    @State private var nbTrackID = ""
    @State private var nbFetching = false
    /// v0.3.540：NB 源的搜索结果（Apple 官方 search，区域随 `regionRaw` 走）.
    ///
    /// 与 `searchResults`（爱思）**刻意分开** —— 两者数据源完全不同，
    /// 混用一个数组会让「切来源后残留上一个源的条目」，
    /// 而 NB 的行必须走 NB 取包（不能用爱思的 `ipaURL`）.
    @State private var nbSearchResults: [NBStoreRankClient.RankItem] = []

    /// v0.3.549：NB 源**下架**搜索结果。
    ///
    /// 与 `nbSearchResults` 分开存：两者数据源、字段、可做的动作都不同 ——
    /// 下架项只能走 `getOffSaleAppHistoryList` 取包，混在一个数组里会让「这一行该走哪条链路」
    /// 变成靠猜。分开存则行类型本身就决定了链路（见 `nbOffSaleRow`）。
    @State private var nbOffSaleResults: [NBStoreClient.OffSaleApp] = []

    /// v0.3.545：NB 源的**上架 / 下架**筛选（对应 NB 助手的 `DXSTOffSaleController`）。
    ///
    /// ## 怎么判定「下架」
    /// 反编译 NB 助手确认它有独立的下架应用页（`DXSTOffSaleController` +
    /// `DXSTOffSaleDetailController` + `DXSTOffSaleHistoryListController`），
    /// 取包走同一个端点 `/nb/app-downgrade`，只把 `method` 换成
    /// `getOffSaleAppHistoryList`、应用 ID 键换成 `ipaID`（见 `NBStoreClient.offSalePackage`）。
    ///
    /// ## 所以「筛」这个动作怎么做
    /// 应用列表来自 Apple RSS/search，这两条**只回上架应用**，天然没有下架项。
    /// 因此这里的筛选是**开关式的行为切换**，不是对已有数组做过滤：
    /// - `.onSale`（默认）：行为完全不变；
    /// - `.offSale`：把搜索/列表里的每个 trackId 拿去 `lookup` 探一次，
    ///   用 `NBStoreClient.offSalePackage` 取包 —— 也就是说这条路能装到
    ///   App Store 已经搜不到的老应用。
    ///
    /// ⚠️ 刻意**不建本地库**：NB 那边下架列表是本地 SQLite 表 `load_list` 缓存的，
    /// 我们没有必要复刻一份会过期的缓存；状态以实时探测为准。
    enum AppStateFilter: String, CaseIterable, Identifiable {
        case onSale = "上架"
        case offSale = "下架"

        var id: String { rawValue }
    }

    @State private var appStateFilter: AppStateFilter = .onSale

    /// v0.3.305：已下载数量（进入页面时读一次磁盘台账）
    @State private var downloadedCount = 0
    /// 统一下载中心（免登录源与 Apple ID 共用）
    @ObservedObject private var center = IPADownloadCenter.shared

    /// v0.3.399：行长按「查看图标」的全屏预览。
    ///
    /// **复用** AppleID 商店详情页那套 `ImageGalleryViewer`（同一个类型，见 `ImagePreviewSupport.swift`），
    /// 不在这里另写一个只显示一张图的查看器 —— 长按存图也因此白得。
    /// v0.3.408：图数组收进 `ImagePreviewTarget`（页面上不再留 `previewImages`）。
    @State private var previewTarget: ImagePreviewTarget?

    private var isSearchMode: Bool { !keyword.trimmingCharacters(in: .whitespaces).isEmpty }

    /// v0.3.382：搜索框提示随来源变（牛蛙要多说一句区域）
    ///
    /// v0.3.538：NB 源两种输入都收 —— 关键词或 App Store 链接 / 数字 ID。
    /// v0.3.540：关键词这一路已改用 Apple 官方搜索（区域随上方区域选择走）.
    private var searchPrompt: String {
        switch source {
        case .i4:    return "搜索应用（无需登录）"
        case .niuwa: return "搜索应用（无需登录 · \(region.title)）"
        case .nb:    return "搜应用名（\(regionRaw.uppercased())区），或填 App Store ID"
        }
    }

    var body: some View {
        List {
            downloadManagerSection
            sourceSection
            if isSearchMode {
                searchSection
            } else {
                // v0.3.540：NB 源也有榜单了（Apple RSS）—— 不再是「没有榜单」那句话.
                if source == .i4 || source == .nb { rankSection }
                listSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("免登录下载")
        .navigationBarTitleDisplayMode(.inline)
        // v0.3.367：用户要求顶栏搜索**常驻**（下滑也能搜），对齐主页「应用」板块的 .always。
        .searchable(text: $keyword,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt)
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: rank) { _, _ in Task { await load() } }
        // v0.3.540：NB 榜切换分组要重拉（走的是 Apple RSS，与爱思那份数据无关）.
        .onChange(of: nbRank) { _, _ in Task { await load() } }
        // v0.3.382：切来源 / 切区域都要重新取数（搜索态重搜，列表态重载）
        //
        // v0.3.414：切到 NB 时**先清掉上一个来源的结果** —— NB 的结果行只在
        // `source == .nb` 时渲染，但 `nbPackage` 本身不清会串到下一次查询。
        // v0.3.540：`nbSearchResults` 同理（它是 Apple 搜索的结果，与爱思的 `searchResults` 分开存）.
        .onChange(of: source) { _, newValue in
            if newValue == .nb {
                nbPackage = nil
                nbTrackID = ""
                errorText = nil
            }
            nbSearchResults = []
            if isSearchMode { runSearch() } else { Task { await load() } }
        }
        .onChange(of: regionRaw) { _, _ in
            // v0.3.414：NB 源也要响应区域切换（它的 `country` 参数随之变）
            // v0.3.540：NB 的榜单/搜索现在都跟 `country` 走，所以区域变了必须重取.
            guard source == .niuwa || source == .nb else { return }
            if isSearchMode { runSearch() } else { Task { await load() } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .toastHost()
        .fullScreenCover(item: $previewTarget) { target in
            // v0.3.408：`urls` 从 target 里读
            ImageGalleryViewer(urls: target.urls, startIndex: target.index)
        }
        .task {
            downloadedCount = IPADownloadLibrary.shared.items().count
            if apps.isEmpty { await load() }
        }
    }

    // MARK: - v0.3.382 来源 / 区域

    /// **来源**：爱思（接口一）/ 牛蛙（接口二）；选牛蛙时下面多一行**区域**三档
    private var sourceSection: some View {
        Section {
            Picker("来源", selection: $source) {
                ForEach(StoreSource.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)

            // v0.3.414：NB 源也有区域（ID 反编译确认 `country` 参数，`DXSTSegmentController` 就是它的控件）
            if source == .niuwa || source == .nb {
                Picker("区域", selection: $regionRaw) {
                    ForEach(NiuwaStoreClient.NiuwaRegion.allCases) { r in
                        Text(r.title).tag(r.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            // v0.3.545：NB 源的**上架 / 下架**（对应 NB 助手的 DXSTOffSaleController）。
            // 只在 NB 源出现 —— 爱思/牛蛙没有这条链路，不给它们摆一个按不动的开关。
            if source == .nb {
                Picker("状态", selection: $appStateFilter) {
                    ForEach(AppStateFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        // v0.3.545：**修「分组栏目上方有一块空白」**。
        //
        // 原来这里是 `.listRowInsets(top:6, leading:0, bottom:6, trailing:0)`
        // 配 `.listRowBackground(Color.clear)`，用意是「让分段控件贴边、不要卡片背景」。
        // 但这两个一起用会把这一行从 `insetGrouped` 的卡片布局里摘出去：
        // 卡片背景被清空后，Section 的 header 与第一行之间会**按卡片间距留一段空白**，
        // 视觉上就是「分组栏上方空一块、跟下面的榜单对不齐」。
        //
        // 改回 insetGrouped 的标准行内边距（左右各 16），保留卡片背景，
        // 上下只留很小的呼吸 —— 分段控件本来就有自己的内边距，不需要再顶出去。
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: - v0.3.305 下载管理入口

    /// 已下载安装包的管理入口（列表 + 安装 + 删除），顶在最上面方便随时进
    private var downloadManagerSection: some View {
        Section {
            NavigationLink {
                IPADownloadManagerView()
            } label: {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "shippingbox.fill", tint: .blue,
                               symbolSize: 18, frameSize: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下载管理").font(.subheadline.weight(.medium))
                        Text("管理已下载的 IPA 并安装").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if downloadedCount > 0 {
                        Text("\(downloadedCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 已下载数量（进入页面时读一次磁盘台账）
    // MARK: - 榜单选择

    private var rankSection: some View {
        Section {
            // v0.3.540：两个来源的榜单是**两套数据**（爱思自己的服务端 / Apple RSS），
            // 分组取值也不同，所以用各自的 Picker，不硬凑成一个.
            //
            // v0.3.545：两处 `listRowInsets` + `listRowBackground(Color.clear)` 都去掉 ——
            // 与 `sourceSection` 同一个毛病（清掉卡片背景后 header 与内容之间会留一段空白）。
            // 保持 insetGrouped 的默认行边距即可。
            if source == .nb {
                // v0.3.549：下架态下榜单单不存在 —— 不摆一个选了也没用的下拉.
                if appStateFilter == .onSale {
                    Picker("分组", selection: $nbRank) {
                        ForEach(NBStoreRankClient.Rank.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } else {
                Picker("分组", selection: $rank) {
                    ForEach(I4PCStoreClient.Rank.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }
        } footer: {
            Text(source == .nb
                 ? "榜单来自 Apple 官方排行榜（与 NB 助手同一来源）。点「获取」由 NB 通道取包。"
                 : "数据来自爱思 PC 端同款公开接口，安装包由服务端提供（已签名），无需登录 Apple ID。")
                .font(.caption2)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var listSection: some View {
        if loading {
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在获取列表…").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        } else if let errorText {
            Section {
                Label(errorText, systemImage: "xmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        } else if source == .niuwa {
            // v0.3.382：牛蛙源只有搜索，不做榜单（接口文档里只有 /appstore/search + /download）
            Section {
                Text("牛蛙源请用上方搜索框按关键词找应用")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else if source == .nb {
            // v0.3.549：**下架态下不摆榜单**。
            //
            // 榜单来自 Apple RSS，那里面**没有下架应用** —— 在下架态继续显示榜单，
            // 等于用一批在架应用冒充下架结果（用户报的「下架应用搜索完全没用」就是这一类观感）。
            // 下架库只能搜，没有榜单，所以这里如实说明，把入口指到搜索框。
            if appStateFilter == .offSale {
                Section {
                    Text("下架应用没有榜单，请用上方搜索框按名字找（下架库来自 NB）")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if nbRankItems.isEmpty {
                Section {
                    Text("该榜单暂时没有数据").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Section("\(nbRank.title)榜 · \(nbRankItems.count) 款") {
                    ForEach(nbRankItems) { item in
                        nbRankRow(item)
                    }
                }
            }
        } else if apps.isEmpty {
            Section {
                Text("该分组暂时没有数据").font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Section("\(rank.title) · \(apps.count) 款") {
                ForEach(apps) { app in
                    row(app)
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if searching {
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("搜索中…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else if source == .i4 {
            if searchResults.isEmpty {
                Section {
                    Text("没有找到匹配的应用").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Section("搜索结果 · \(searchResults.count) 款") {
                    ForEach(searchResults) { app in
                        row(app)
                    }
                }
            }
        } else if source == .niuwa {
            if niuwaSearchResults.isEmpty {
                Section {
                    Text("没有找到匹配的应用").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Section("搜索结果 · \(niuwaSearchResults.count) 款") {
                    ForEach(niuwaSearchResults) { app in
                        row(app)
                    }
                }
            }
        } else {
            // NB 源三种结果形态：
            //   · 「下架」态 → NB 自己的下架库（`nbOffSaleResults`，v0.3.549）
            //   · 输入是 ID/链接 → 单个取包结果（`nbPackage`）
            //   · 输入是关键词   → Apple 官方搜索的候选列表（`nbSearchResults`），
            //                      点「获取」走 NB 取包（v0.3.540：不再借爱思）
            if appStateFilter == .offSale {
                // 下架库是**独立的**：它的条目不能走 Apple 那套行（字段与链路都不同）。
                if nbOffSaleResults.isEmpty {
                    Section {
                        Text("下架库里没有匹配的应用，换个关键词试试，或确认区域")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Section("下架应用 · \(nbOffSaleResults.count) 款") {
                        ForEach(nbOffSaleResults) { app in
                            nbOffSaleRow(app)
                        }
                    }
                }
            } else if let pkg = nbPackage {
                Section("App Store ID \(nbTrackID)") {
                    nbRow(trackID: nbTrackID, package: pkg)
                }
            } else if nbFetching {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在取包…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else if !nbSearchResults.isEmpty {
                Section("搜索结果 · \(nbSearchResults.count) 款") {
                    ForEach(nbSearchResults) { item in
                        nbRankRow(item)
                    }
                }
            } else {
                Section {
                    Text("搜应用名，或粘贴 App Store 链接 / 填数字 ID")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// NB 源的结果行。
    ///
    /// NB 接口只回 `url` + `sinfs`，**没有名称、图标、版本号**，所以这一行展示的是
    /// 「trackId + 直链是否拿到」，而不是仿照前两源做一张有图有字的卡片 ——
    /// 没有的数据不硬凑。
    ///
    /// v0.3.538：**左侧整块可点进详情页**（对齐另外两个免登录来源）。
    /// 详情页里列历史版本（走 bilin 目录），每个版本单独取包 ——
    /// 这才对得上「NB 助手能选历史版本下载」的形态。
    private func nbRow(trackID: String, package: NBStoreClient.NBPackage) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink {
                // v0.3.549：改走**五参数**构造 —— 原来这里是旧的 `(trackID:country:displayName:)`
                // 三参数版，与 `nbRankRow` 的调用形态不一致（同一个类型两种调法，
                // 详情页里 `offSale` 永远取到默认的 false → 从这条路径进去取包会走错 method）。
                // `offSale` 跟着当前筛选走，与列表行保持同一个口径。
                NBStoreDetailView(trackID: trackID,
                                  country: regionRaw,
                                  displayName: nil,
                                  icon: nil,
                                  offSale: appStateFilter == .offSale)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 54, height: 54)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("App Store ID \(trackID)").font(.body).lineLimit(1)
                        Text(package.sinfBase64 == nil ? "已取到直链（无 sinf）" : "已取到直链 + sinf")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if nbFetching {
                ProgressView().controlSize(.small)
            } else {
                Button("获取") {
                    Task { await startNBDownload(trackID: trackID, package: package) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    /// **下架应用**的结果行（v0.3.549）.
    ///
    /// 与 `nbRankRow`（Apple 榜单/搜索行）的区别：数据来自 NB 的下架库
    /// （`nb9527_searchOffSaleApp`），字段也就跟着 NB 的 `DXSTOffSaleAppModel` 走 ——
    /// 名字 / 图标 / 版本 / 大小都有，所以按前两源同款排版渲染，不是「只有一串数字」.
    ///
    /// 右侧「获取」直接走 `installOffSale` → `NBStoreClient.offSalePackage`（`getOffSaleAppHistoryList`），
    /// 与上架链路（`getAppHistoryList`）分开 —— 两条路的 method 不同，不能混.
    private func nbOffSaleRow(_ app: NBStoreClient.OffSaleApp) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink {
                // 下架详情：`offSale: true` 决定详情页里取包走 `getOffSaleAppHistoryList`.
                NBStoreDetailView(trackID: app.storeID ?? "",
                                  country: regionRaw,
                                  displayName: app.displayName,
                                  icon: app.displayIcon,
                                  offSale: true)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    AsyncImage(url: URL(string: app.displayIcon ?? "")) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                        default: ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.displayName.isEmpty ? "App \(app.id)" : app.displayName)
                            .font(.subheadline.weight(.medium)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        ChipFlow(spacing: 6) {
                            chip("下架", .red)
                            if let v = app.displayVersion, !v.isEmpty {
                                chip("v\(v)", .blue)
                            }
                            if let s = app.sizeText { chip(s, .green) }
                        }
                        if let b = app.bundleID, !b.isEmpty {
                            Text(b).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                }
            }
            .buttonStyle(.plain)

            // v0.3.549：`bundleId` 传 **nil**，与 `startNBDownload`（它以 `bundleId: nil` 建任务）
            // 保持同一口径 —— `activeJob(bundleId:name:)` 在「行有 bundleId、任务没有」时
            // 会直接判不等，进度控件就永远挂不上这一行（用户看到的是「点了获取，行里没反应」）。
            // 传 nil 则退化成按**名字**匹配，与任务侧对得上。
            trailingControl(name: app.displayName, bundleId: nil) {
                Task { await installOffSale(app) }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            iconMenuItems(iconURL: app.displayIcon,
                          fileNameBase: app.bundleID ?? app.displayName) {
                showIconPreview(app.displayIcon, target: $previewTarget)
            }
        }
    }

    /// 下架行「获取」：用 NB 的下架链路取包 → 交给统一下载中心.
    ///
    /// `ipaID` 用 `app.storeID`（`appStoreID` 或 `lookupData.trackId`，两个哪个有值用哪个）.
    /// 服务端没给 ID 时明确报错，不静默 —— 静默会让用户看到「点了没反应」.
    @MainActor
    private func installOffSale(_ app: NBStoreClient.OffSaleApp) async {
        guard let sid = app.storeID, !sid.isEmpty else {
            ToastCenter.shared.show("这条下架记录没有 App Store ID，无法取包")
            return
        }
        do {
            let pkg = try await NBStoreClient.offSalePackage(ipaID: sid, country: regionRaw)
            guard let pkg else {
                ToastCenter.shared.show("该下架应用没有可用的安装包")
                return
            }
            await startNBDownload(trackID: sid,
                                  package: pkg,
                                  name: app.displayName,
                                  version: app.displayVersion,
                                  iconURL: app.displayIcon)
        } catch {
            ToastCenter.shared.show("NB 取包失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 行

    /// NB 源榜单 / 搜索结果的卡片行（v0.3.540）.
    ///
    /// 与 `nbRow`（裸 trackId 那行）的差别：这一行**有 Apple 给的元数据**
    /// （图标 / 名字 / 开发者 / 分类 / 价格），所以按前两源同款排版渲染，
    /// 不再是「只有一串数字」.
    ///
    /// 右侧「获取」走 `installViaNBRank` → `NBStoreClient.package` ——
    /// 榜单数据是 Apple 的，**包仍然由 NB 取**（Apple RSS 不给安装包）.
    private func nbRankRow(_ item: NBStoreRankClient.RankItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink {
                // 进 NB 详情页可以选历史版本（版本列表走 bilin 目录，与 AppleID 商店同一份）.
                // v0.3.545：把图标和上架/下架状态一起带进去 —— 详情页据此选取包链路，
                // 并且在 lookup 回来之前就能先显示图标与名字（少一次白屏）.
                NBStoreDetailView(trackID: item.trackID,
                                  country: regionRaw,
                                  displayName: item.name,
                                  icon: item.icon,
                                  offSale: appStateFilter == .offSale)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        AsyncImage(url: URL(string: item.icon ?? "")) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFit()
                            case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                            default: ProgressView().controlSize(.mini)
                            }
                        }
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        // 名次角标：榜单页最有信息量的那一项.
                        Text("\(item.rank)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .offset(x: -2, y: -2)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        ChipFlow(spacing: 6) {
                            ForEach(nbChips(item), id: \.text) { c in
                                chip(c.text, c.tint)
                            }
                        }
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 6)
                }
            }
            .buttonStyle(.plain)

            // v0.3.549：与下架行同因 —— `startNBDownload` 建任务时 `bundleId` 是 nil，
            // 而这一行以前传的是 `item.bundleID`，`activeJob` 在「行有、任务没有」时直接判不等
            // → 行内不显示下载进度 / 暂停按钮。改传 nil，退化成按名字匹配。
            trailingControl(name: item.name, bundleId: nil) {
                Task { await installViaNBRank(item) }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            iconMenuItems(iconURL: item.icon, fileNameBase: item.bundleID ?? item.name) {
                showIconPreview(item.icon, target: $previewTarget)
            }
        }
    }

    /// NB 榜单行的胶囊（分类 / 价格）.
    ///
    /// 只放**确实有值**的项：Apple RSS 的免费榜 `im:price.label` 是「获取」，
    /// 付费榜是「¥ xx」—— 两者都是有效信息，照原样显示，不硬转成「免费」二字.
    private func nbChips(_ item: NBStoreRankClient.RankItem) -> [ChipItem] {
        var out: [ChipItem] = []
        if let p = item.priceText, !p.isEmpty { out.append(ChipItem(text: p, tint: .orange)) }
        if let c = item.category, !c.isEmpty { out.append(ChipItem(text: c, tint: .blue)) }
        return out
    }

    /// NB 榜单行「获取」：拿 Apple 给的 trackId → 走 NB 取包 → 交给统一下载中心.
    ///
    /// 数据来自 Apple 榜单，但**包必须由 NB 通道取**（Apple RSS 不给安装包），
    /// 所以这里走 `NBStoreClient.package` + `startNBDownload` ——
    /// 与 `install(_:)`（用爱思自己的 `ipaURL`）刻意分开，两条通道的包不是一回事.
    @MainActor
    private func installViaNBRank(_ item: NBStoreRankClient.RankItem) async {
        do {
            // v0.3.545：按「上架 / 下架」走两条链路。
            // 上架 → `getAppHistoryList`（`appID`）；下架 → `getOffSaleAppHistoryList`（`ipaID`）。
            let pkg: NBStoreClient.NBPackage?
            if appStateFilter == .offSale {
                pkg = try await NBStoreClient.offSalePackage(ipaID: item.trackID,
                                                             country: regionRaw)
            } else {
                pkg = try await NBStoreClient.package(appID: item.trackID,
                                                      bundleID: item.bundleID ?? "",
                                                      country: regionRaw)
            }
            guard let pkg else {
                ToastCenter.shared.show("该应用没有可用的安装包")
                return
            }
            await startNBDownload(trackID: item.trackID, package: pkg,
                                  name: item.name, version: nil, iconURL: item.icon)
        } catch {
            ToastCenter.shared.show("NB 取包失败：\(error.localizedDescription)")
        }
    }

    /// 左侧（图标 + 文案）整块可点进**应用详情**，右侧仍是原有的下载/进度控件。
    ///
    /// v0.3.540：`nbMode` 参数**删掉**了。NB 源的搜索/榜单结果现在有自己的行
    /// （`nbRankRow`，数据来自 Apple），不再借用爱思的候选列表走 NB 取包 ——
    /// 这个方法回归成**纯爱思行**，一个参数、一种行为.
    private func row(_ app: I4PCStoreClient.I4App) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink {
                I4StoreFreeDetailView(app: app)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    AsyncImage(url: URL(string: app.icon ?? "")) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                        default: ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // v0.3.367：信息列不再被右侧进度控件挤扁 ——
                    // 胶囊固定单行（`.fixedSize()`），一行放不下就**整体换到下一行**（`ChipFlow`），
                    // 简介与名称允许换行但不截断。用户要求「可以换行显示但不能显示不全」。
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        ChipFlow(spacing: 6) {
                            ForEach(chips(app), id: \.text) { item in
                                chip(item.text, item.tint)
                            }
                        }
                        if let s = app.slogan, !s.isEmpty {
                            Text(s).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 6)
                }
            }

            trailingControl(name: app.name, bundleId: app.bundleId) { install(app) }
        }
        .padding(.vertical, 3)
        // v0.3.399：长按弹「查看图标 / 提取图标」。
        // v0.3.403：菜单内容改走 `ImagePreviewSupport.swift` 的共用实现（四处一份）；
        // 挂载点从左侧那条 `NavigationLink` **挪到整行** —— AppleID 列表是整行可长按，
        // 爱思源原来只有左半块（右半块的下载控件压上去不出菜单），位置口径也对齐。
        .contextMenu {
            iconMenuItems(iconURL: app.icon, fileNameBase: app.bundleId ?? app.name) {
                // v0.3.408：图数组由 `showIconPreview` 写进 target
                showIconPreview(app.icon, target: $previewTarget)
            }
        }
    }

    /// 右侧控件：有任务 → 进度 + 暂停 / 删除；没有 → 一枚「获取」（v0.3.408 前叫「安装」）。
    ///
    /// v0.3.406：参数从「爱思应用」改成裸字段（`name` / `bundleId`），好让**牛蛙行**共用
    /// 同一份 —— 两个来源的行右侧长得一模一样，不留第二套。
    @ViewBuilder
    private func trailingControl(name: String,
                                 bundleId: String?,
                                 action: @escaping () -> Void) -> some View {
        if let job = center.activeJob(bundleId: bundleId, name: name) {
            // 进度控件也固定宽度：它不再跟左侧抢空间，左侧空间不够时由 ChipFlow 换行解决
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, job.overall)))
                    .frame(width: 40)
                Text(job.phase == .paused ? "已暂停" : job.stageText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    if job.phase == .paused {
                        center.resume(job.id)
                    } else {
                        center.pause(job.id)
                    }
                } label: {
                    Image(systemName: job.phase == .paused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(job.canPause ? Color.blue : Color.secondary)
                .disabled(!job.canPause)
                Button {
                    center.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .fixedSize()
        } else {
            Button {
                action()
            } label: {
                // v0.3.408：文案「安装」→「获取」（用户要求）。
                // 只改**发起获取**这一个动作的文案 —— 这一列里的「暂停 / 删除」是**不同语义**
                // （对已存在的任务操作），一字不动；正在跑的任务显示的是 `job.stageText`。
                // 同理没动 AppleID 商店那边的按钮（用户说的是免登录/牛蛙这处）。
                Text("获取")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.14), in: Capsule())
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    /// 版本 / 大小 / 已签名 —— 用 `ForEach` 交给 `ChipFlow`，一行放不下就整块换行
    private func chips(_ app: I4PCStoreClient.I4App) -> [ChipItem] {
        var out: [ChipItem] = []
        if let v = app.version { out.append(ChipItem(text: "v\(v)", tint: .blue)) }
        if let s = app.sizeText { out.append(ChipItem(text: s, tint: .green)) }
        if app.isSigned { out.append(ChipItem(text: "已签名", tint: .purple)) }
        return out
    }

    /// 胶囊：**单行 + 定宽**，绝不被压缩折行（真机截图里 `v8.0.` / `78` 折成两行就是这个毛病）
    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }

    // MARK: - 行（牛蛙源，v0.3.382）

    /// 牛蛙源的行：与爱思行同款排版（图标 + 名称 + 胶囊 + 简介），
    /// 右侧与爱思行共用 `trailingControl(...)`（获取 / 进度 / 暂停 / 删除）。
    ///
    /// v0.3.406：**左侧整块可点进 `NiuwaStoreDetailView`**（此前牛蛙源没有详情页）；
    /// 右侧原来的「获取直链」改成真正的下载动作（v0.3.408 起按钮文案为「获取」）——
    /// 先取直链再交给 `IPADownloadCenter`。
    private func row(_ app: NiuwaStoreClient.NiuwaApp) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink {
                NiuwaStoreDetailView(app: app, region: region)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    AsyncImage(url: app.icon) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                        default: ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.subheadline.weight(.medium)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        ChipFlow(spacing: 6) {
                            ForEach(chips(app), id: \.text) { item in
                                chip(item.text, item.tint)
                            }
                        }
                        if let d = app.desc, !d.isEmpty {
                            Text(d).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 6)
                }
            }

            // 取直链是一次网络往返（爱思那边搜索响应里就带 ipaURL，牛蛙要单打一发）——
            // 这一步的等待要看得见，不能按下去什么都没发生。
            if niuwaFetching == app.bundleId {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("获取中").font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize()
            } else {
                trailingControl(name: app.name, bundleId: app.bundleId) {
                    Task {
                        niuwaFetching = app.bundleId
                        await startNiuwaDownload(app, region: region)
                        niuwaFetching = nil
                    }
                }
            }
        }
        .padding(.vertical, 3)
        // v0.3.399：牛蛙行也要有图标菜单（v0.3.406 起牛蛙有自己的详情页，这里仍然保留 ——
        // 列表里长按就能取图标，不必先进详情）。
        // v0.3.403：菜单项与爱思行、AppleID 两处**共用** `iconMenuItems(...)`（单份定义），
        // 挂载点同样提到整行（原来只有左半块）。
        .contextMenu {
            iconMenuItems(iconURL: app.iconURL, fileNameBase: app.bundleId) {
                // v0.3.408：图数组由 `showIconPreview` 写进 target
                showIconPreview(app.iconURL, target: $previewTarget)
            }
        }
    }

    /// 版本 / 大小 / 区域 —— 与爱思行的胶囊同款
    private func chips(_ app: NiuwaStoreClient.NiuwaApp) -> [ChipItem] {
        var out: [ChipItem] = []
        if let v = app.version, !v.isEmpty { out.append(ChipItem(text: "v\(v)", tint: .blue)) }
        if let s = app.sizeText, !s.isEmpty { out.append(ChipItem(text: s, tint: .green)) }
        out.append(ChipItem(text: region.title, tint: .orange))
        return out
    }

    // MARK: - 加载

    private func load() async {
        loading = true
        errorText = nil
        // v0.3.540：NB 源现在也有榜单了（Apple RSS）—— 只有牛蛙源是真的没有榜单接口.
        if source == .nb {
            do {
                nbRankItems = try await NBStoreRankClient.fetch(rank: nbRank, country: regionRaw)
            } catch {
                nbRankItems = []
                errorText = "NB 榜单加载失败：\(error.localizedDescription)"
            }
            loading = false
            return
        }
        // v0.3.382：牛蛙源没有榜单接口 —— 不请求，仅在列表处提示走搜索
        guard source == .i4 else {
            loading = false
            return
        }
        do {
            apps = try await I4PCStoreClient.list(rank: rank)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func runSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            searchResults = []
            niuwaSearchResults = []
            nbSearchResults = []
            nbOffSaleResults = []
            return
        }
        searching = true
        let src = source
        let reg = region
        Task {
            switch src {
            case .i4:
                do {
                    searchResults = try await I4PCStoreClient.search(keyword: kw)
                } catch {
                    searchResults = []
                    ToastCenter.shared.show("搜索失败：\(error.localizedDescription)")
                }
            case .niuwa:
                do {
                    niuwaSearchResults = try await NiuwaStoreClient.search(keyword: kw, region: reg)
                } catch {
                    niuwaSearchResults = []
                    // ▸ v0.3.387：失败原因必须**留在界面上**。
                    // 只弹一个一闪而过的 toast 的话，用户看到的就是「列表全空、什么也不知道」，
                    // 这一轮就是这么丢掉真机证据的（用户只反馈「界面都是空的」）。
                    // `StoreError.server` 的 description 已带 `nwcore_code` 与 `nwcore_messages`。
                    errorText = "牛蛙源搜索失败：\(error.localizedDescription)"
                    ToastCenter.shared.show("搜索失败")
                }
            case .nb:
                // v0.3.540：**不再借爱思的搜索接口**。
                //
                // 用户反馈「美区一个搜索不到、国区还那么点软件」—— 根因就是这里原来
                // 调的是 `I4PCStoreClient.search`，而爱思是**中国区商店**：
                // 它的库里没有美区应用（美区空），国区也只覆盖它自己收录的那点量。
                //
                // 现在按输入形态分流：
                //   · 数字 ID / App Store 链接 → 直接走 NB 取包（原行为）
                //   · 纯文字关键词           → 走 **Apple 官方 search**（区域跟着 `regionRaw` 走）
                // 这样美区能搜到美区商店的应用，国区能搜到国区商店的全部上架应用。
                //
                // v0.3.549：**「下架」必须走 NB 自己的搜索**。
                //
                // 用户反馈「NB 源选美区下架的应用根本搜索不到，你这下架应用搜索完全没用」——
                // 真因就在这一支：以前无论选上架还是下架，走的都是同一条 Apple search，
                // 而 Apple 的 search/RSS **只回在架应用**（实测 `term=stikdebug&country=us`
                // 回的是 TestFlight / GitHub / Debug Anywhere 这批在架应用，正是截图里那几行）——
                // 所以「下架」这个筛选在数据源上根本不曾生效，是个空开关。
                //
                // 下架库只有 NB 服务端有（`nb9527_searchOffSaleApp`，见 `NBStoreClient`）。
                // 数字 ID 这一支在下架态下也走下架接口 —— 下架应用只能这样取包。
                if appStateFilter == .offSale {
                    // 下架态：一律走 NB 下架搜索（输入是 ID 或名字都一样，接口只吃 `kw`）。
                    do {
                        nbOffSaleResults = try await NBStoreClient.searchOffSaleApp(keyword: kw)
                    } catch {
                        nbOffSaleResults = []
                        errorText = "NB 下架搜索失败：\(error.localizedDescription)"
                        ToastCenter.shared.show("搜索失败")
                    }
                } else if nbParseTrackIDOnly(kw) != nil || kw.lowercased().contains("apple.com") {
                    await runNBFetch(kw)
                } else {
                    do {
                        nbSearchResults = try await NBStoreRankClient.search(keyword: kw, country: regionRaw)
                    } catch {
                        nbSearchResults = []
                        errorText = "NB 源搜索失败：\(error.localizedDescription)"
                        ToastCenter.shared.show("搜索失败")
                    }
                }
            }
            searching = false
        }
    }

    // MARK: - 下载并安装（免登录）

    private func install(_ app: I4PCStoreClient.I4App) {
        guard let ipaURL = app.ipaURL else {
            ToastCenter.shared.show("该应用没有可用的安装包地址")
            return
        }
        _ = IPADownloadCenter.shared.start(name: app.name,
                                           bundleId: app.bundleId,
                                           version: app.version,
                                           iconURL: app.icon,
                                           remoteURL: ipaURL.absoluteString)
        downloadedCount = IPADownloadLibrary.shared.items().count
    }

    // MARK: - v0.3.414 NB 源（按 App Store ID 取包）

    /// 从用户输入里取出 App Store trackId。
    ///
    /// 三种写法都认：纯数字 `6451407032`、`id6451407032`、
    /// 完整链接 `https://apps.apple.com/cn/app/xxx/id6451407032`。
    private func nbParseTrackID(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.allSatisfy({ $0.isNumber }) { return s }
        // 链接：取最后一处 `id` 后面连续的数字
        guard let r = s.range(of: "id", options: .backwards) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// 只在输入**确实是 ID 或链接**时返回 trackId；纯关键词（含空格/字母）返回 nil。
    ///
    /// 与 `nbParseTrackID` 的差别：那个是「尽力解析」，链接里抽不到数字也返回 nil；
    /// 这个是「判定输入类型」，用来决定 NB 源该走取包还是走搜索。
    /// 注意「Reddit」这种纯字母词不能被当成 ID —— 所以这里要求全数字，或带 `apple.com`。
    private func nbParseTrackIDOnly(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.allSatisfy({ $0.isNumber }) { return s }
        guard s.lowercased().contains("apple.com") else { return nil }
        return nbParseTrackID(s)
    }

    /// NB 源取包：输入 → trackId → 取直链与 sinf。
    @MainActor
    private func runNBFetch(_ raw: String) async {
        nbPackage = nil
        errorText = nil
        guard let tid = nbParseTrackID(raw) else {
            errorText = "NB 源需要 App Store 链接或数字 ID（例如 6451407032）"
            searching = false
            return
        }
        nbTrackID = tid
        nbFetching = true
        do {
            nbPackage = try await NBStoreClient.package(appID: tid, country: regionRaw)
            if nbPackage == nil { errorText = "该应用没有可用的安装包" }
        } catch {
            errorText = "NB 源取包失败：\(error.localizedDescription)"
        }
        nbFetching = false
        searching = false
    }
}

// MARK: - v0.3.414 NB 源：取直链 → 交给统一下载中心

/// NB 源的下载入口。与 `startNiuwaDownload` 同构：
/// NB 下发的同样是 **Apple 原始加密包**，所以必须把 sinf 一起交给下载中心写回包内。
///
/// v0.3.538：`name` 与 `version` 改为可传入 —— NB 详情页里同一个 trackId 会有多个
/// 历史版本，只按 trackId 命名会让几行在「下载管理」里长得一模一样、分不清是哪个版本。
///
/// v0.3.545：加 `iconURL` —— 详情页从 lookup 拿到 512 图标后一起带进下载台账，
/// 这样「下载管理」里那一行也有图标（以前 NB 源传的是 `nil`，那几行全是灰占位）。
@MainActor
func startNBDownload(trackID: String,
                     package: NBStoreClient.NBPackage,
                     name: String? = nil,
                     version: String? = nil,
                     iconURL: String? = nil) async {
    guard !package.ipaURL.isEmpty else {
        ToastCenter.shared.show("该应用没有可用的安装包")
        return
    }
    let shownName = (name?.isEmpty == false) ? name! : "App \(trackID)"
    let shownVersion = (version?.isEmpty == false) ? version : package.version
    _ = IPADownloadCenter.shared.start(name: shownName,
                                       bundleId: nil,
                                       version: (shownVersion?.isEmpty == false) ? shownVersion : nil,
                                       iconURL: (iconURL?.isEmpty == false) ? iconURL : nil,
                                       remoteURL: package.ipaURL,
                                       source: .nb,
                                       sinfBase64: package.sinfBase64)
}

// MARK: - v0.3.406 牛蛙源：取直链 → 交给统一下载中心

/// 牛蛙源「下载」的**唯一一份实现**（列表行与详情页共用，不留第二套）。
///
/// 与爱思源唯一的差别：爱思的**搜索结果里就带 `ipaURL`**，点一下直接进下载中心；
/// 牛蛙要**先打一发** `POST /appstore/download` 才拿得到直链（`ba_ipaURL`），
/// 所以这一步必须是异步的。
///
/// 拿到直链之后走的是**与爱思源一字不差的同一条链路**：
/// `IPADownloadCenter.shared.start(name:bundleId:version:iconURL:remoteURL:source:sinfBase64:)`
/// （v0.3.412：去掉 `autoInstall` 参数 —— 详见 `IPADownloadCenter.start`）
/// —— 全项目只有这一套下载/安装实现（`ref-客户端常见坑`：禁止新建第二个下载管理器），
/// 牛蛙不另开一条，也不在本函数里做任何文件/安装动作。
///
/// ⚠️ `ba_ipaURL` **指向 `iosapps.itunes.apple.com` 是正常的**：牛蛙服务器代我们向 Apple 取包，
/// 回来的是 Apple 签发的 CDN 地址，不是"抓错了源"。
///
/// v0.3.407：随直链回来的 `ba_sinfs`（base64 的标准 `.sinf`）也一并交给下载中心
/// （`sinfBase64:`）—— 这类包是 Apple 的**原始加密包**，装之前必须先把它写回包内
/// `SC_Info/<CFBundleExecutable>.sinf`（由 `IPADownloadCenter` 的 `PackageSINFWriter` 做）。
///
/// v0.3.408：**首次网络失败自动重试一次**（只一次）。原因见 `NiuwaStoreClient.pubUDID`：
/// 那两个 `pub_*` 字段原来会在**请求路径上现场建设备隧道**（秒级），
/// 而同一时刻 App 自己的 LocalDevVPN 正在被重配 —— 这一发 HTTPS 会被顶掉，
/// 表现就是「第一次点获取必失败、再点一次就成功」。已经把那两处改成**只吃缓存 + 后台预热**，
/// 这里的这一发重试是给"网络抖动"兜底。**只对网络层失败重试**
///（服务端说没有包 / 解密失败 / HTTP 非 2xx 重试没有意义，照旧直接失败）。
///
/// v0.3.410：**空直链也重试**（最多 2 次、间隔 600ms）—— 这是"大部分应用获取失败"的直接成因，
/// 详见 `fetchNiuwaPackage` 的注释（含真机日志）。两层重试语义分开，不叠加。
///
/// `@MainActor`：**顶层自由函数不像 `View` 那样被推断成主 actor**，而这里要调
/// `IPADownloadCenter`（`@MainActor`）与 `ToastCenter`。两个调用点都在 `View` 内。
@MainActor
func startNiuwaDownload(_ app: NiuwaStoreClient.NiuwaApp,
                        region: NiuwaStoreClient.NiuwaRegion) async {
    do {
        let full = try await fetchNiuwaPackage(app, region: region)
        guard let link = full?.downloadURL, !link.isEmpty else {
            ToastCenter.shared.show("该应用没有可用的安装包")
            return
        }
        _ = IPADownloadCenter.shared.start(name: app.name,
                                           bundleId: app.bundleId,
                                           version: full?.version ?? app.version,
                                           iconURL: app.iconURL,
                                           remoteURL: link,
                                           // v0.3.406：来源标成「牛蛙免登录」——
                                           // 默认值是 `.i4Free`，不传就会被下载管理页错标成爱思。
                                           source: .niuwa,
                                           // v0.3.407：`ba_sinfs` 是这份包**本机专用**的 sinf，
                                           // 落盘后由下载中心写回包内 `SC_Info/` —— 不然加密包装不上。
                                           sinfBase64: full?.sinfBase64)
    } catch {
        // 失败不许静默：界面上给一句短提示，具体原因在日志里（`[牛蛙源]` 前缀）
        ToastCenter.shared.show("获取安装包失败")
    }
}

/// 取直链。**两层重试，语义分开、互不叠加**：
///
/// ① **网络层**（`v0.3.408`）：`StoreError.network` = 请求根本没拿到响应 —— 这是
///    「建隧道期间 LocalDevVPN 被重配、这一发被顶掉」唯一会产生的形态，**只重试一次**（400ms）。
/// ② **空直链**（`v0.3.410`）：服务端回 200、但 `ba_ipaURL` 为空
///    （`body` 长这样：`{"ba_sinfs":"","ba_ipaURL":""}`）→ 解析层把它当「没有包」，
///    **返回 nil、不是 error** → 旧代码**根本不重试**，用户只能自己再点一次。
///
/// 真机日志（同一个 `com.tuyafeng.Via`）证明空直链是**限流/抖动**、不是"真没包"：
/// ```
/// 21:46:36 region=1 download → 空（ba_ipaURL=""）
/// 21:46:40 region=1 download → ✓ 直链（sinf 1376 字符）      ← 隔 4 秒重试就成功
/// 18:47:20 / 18:47:41 region=0 → 空
/// 18:47:43 region=0 → ✓ 直链                                  ← 第 3 次成功
/// ```
/// ⇒ 对空直链做**有界重试**：最多再试 **2 次**、每次间隔 **~600ms**。
///
/// **为什么有界（2 次）**：实测 1~2 次即成功；再多试只会把「服务端对这个应用真没包」
/// 也拖成十几秒的假死 —— 那种情况就该如实报「没有可用的安装包」，不该让用户干等。
///
/// 两层**不叠加**：`.network` 的那一次补发若也拿到空直链，才会进入第 ② 层重试；
/// 其余错误（`.server` / `.decode` / `.crypto` / `.http(N)`）一律直接抛出，不重试。
private func fetchNiuwaPackage(_ app: NiuwaStoreClient.NiuwaApp,
                               region: NiuwaStoreClient.NiuwaRegion) async throws -> NiuwaStoreClient.NiuwaApp? {
    // 第 0 次 = 首发；之后最多再补 2 次（只针对空直链）
    var hit = try await fetchNiuwaPackageOnce(app, region: region)
    var retries = 0
    while retries < 2, (hit?.downloadURL ?? "").isEmpty {
        retries += 1
        LoginLogger.shared.log("[牛蛙源] 空直链（\(app.bundleId)），第 \(retries) 次重试",
                               category: .appStore)
        // 服务端限流/抖动是秒级的，600ms 够跨过一次；再短会和上一次请求挤在一起
        try? await Task.sleep(for: .milliseconds(600))
        hit = try await fetchNiuwaPackageOnce(app, region: region)
    }
    if retries > 0, let hit, !(hit.downloadURL ?? "").isEmpty {
        LoginLogger.shared.log("[牛蛙源] ✓ 空直链重试成功（\(app.bundleId)，第 \(retries) 次）",
                               category: .appStore)
    }
    return hit
}

/// `fetchNiuwaPackage` 的**单次**请求（含 v0.3.408 的网络层一次重试）。
///
/// 只负责「发一发、网络失败再补一发」，**不管空直链** —— 空直链的重试在上层，
/// 拆开是为了不让两条重试揉在一起（否则会重复请求）。
private func fetchNiuwaPackageOnce(_ app: NiuwaStoreClient.NiuwaApp,
                                   region: NiuwaStoreClient.NiuwaRegion) async throws -> NiuwaStoreClient.NiuwaApp? {
    do {
        return try await NiuwaStoreClient.download(bundleId: app.bundleId, region: region)
    } catch let error as NiuwaStoreClient.StoreError {
        guard case .network(let message) = error else { throw error }
        LoginLogger.shared.log("[牛蛙源] 首发网络失败（\(message)），等 400ms 重试一次（\(app.bundleId)）",
                               category: .appStore)
        // 短等一下：失败的成因是"同一时刻设备隧道在重配"，立刻重发多半还在同一次抖动里
        try? await Task.sleep(for: .milliseconds(400))
        let retried = try await NiuwaStoreClient.download(bundleId: app.bundleId, region: region)
        LoginLogger.shared.log("[牛蛙源] ✓ 重试成功（\(app.bundleId)）", category: .appStore)
        return retried
    }
}

// MARK: - 胶囊自动换行布局

/// 一颗胶囊（文本 + 着色），供 `ChipFlow` 使用
private struct ChipItem {
    let text: String
    let tint: Color
}

/// v0.3.367：一行放得下就横排，放不下就把**整个胶囊**挪到下一行 ——
/// 不缩字号、不折行内文字、不截断。
///
/// 用 `HStack` 做不到这件事：空间不足时它会把 `Text` 压成竖排（真机截图里
/// `v8.0.78` 变成 `v8.0.` / `78` 两行就是这个原因）。
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > limit {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widest, limit), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
