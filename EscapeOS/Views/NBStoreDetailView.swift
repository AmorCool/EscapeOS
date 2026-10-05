import SwiftUI

/// NB 源（NB Pro）的应用详情页。
///
/// ## 这一版做了什么（v0.3.545）
///
/// 用户反馈：「**NB 源的应用详情界面没有详情和预览界面，NB 助手是有的**」——
/// 于是去反编译了 NB 助手（`XNZS`），把它的详情页实现搬了过来：
///
/// | NB 助手的区块 | 我们的落地 |
/// |---|---|
/// | `DXSTDetailLogoView`（图标） | `headerSection` 的大图标 |
/// | `DXSTDetailInfoView`（名称/开发者/评分/大小） | `headerSection` + `metaSection` |
/// | `DXSTDetailADView` / `DXSTDetailADImageCell`（**截图画廊**） | `screenshotSection` |
/// | `DXSTDetailDescView`（简介） | `descriptionSection` |
/// | `DXSTDetailVersionView`（最近更新） | `releaseSection` |
///
/// **数据来源照搬 NB 的做法**：`itunes.apple.com/lookup`（NB 的 `DXSTiTunesAPI` 就是它）。
/// 反编译出的 `DXSTDetailModel` 字段表与 Apple lookup 的响应键**逐字一致**，
/// 所以这一层没有自创协议，就是把 lookup 的响应对进模型。
///
/// ## 与另外两个免登录详情页的关系
///
/// 「下载中」区块与安装按钮**复用**同款共用组件（`DownloadJobSection` / `InstallButton`），
/// 全项目仍然只有一套下载/安装实现。
///
/// ## 取包链路（没变）
/// 1. **版本列表** → `NBStoreClient.versionList(trackID:)`（走 bilin 目录）
/// 2. **取包** → `NBStoreClient.package(appID:appVerId:)`（走 `/nb/app-downgrade`）
/// 3. **装包** → `startNBDownload(...)` → `IPADownloadCenter`（sinf 写回在同一处）
struct NBStoreDetailView: View {

    /// App Store 数字 ID（NB 的 `appID` 与 bilin 路径参数同源）
    ///
    /// v0.3.549：从 `let` 改成 `@State` —— 下架记录的 `id` 是 NB 自己的行号，
    /// 真实 App Store ID 要**进页面后解析**（见 `resolveTrackIDIfNeeded`），
    /// 解析出来才能查版本、取包、查详情.
    @State private var trackID: String
    /// 区域（NB 的 `country` 参数；`cn` / `us` / `hk`）
    let country: String

    /// 可选的展示名：从榜单/搜索跳进来时带上，直接粘贴 ID 时为空。
    /// 详情 lookup 回来后会被真名覆盖，所以这里只是「还没加载完时先显示什么」。
    let displayName: String?

    @ObservedObject private var center = IPADownloadCenter.shared

    /// 列表页带进来的图标（不用等 lookup 回来就能显示）
    private let seedIcon: String?

    /// 是否处于「下架」筛选（从列表页带进来）。
    /// 决定取包走 `getAppHistoryList` 还是 `getOffSaleAppHistoryList`（见 `NBStoreClient`）。
    private let offSale: Bool

    @State private var detail: NBStoreRankClient.AppDetail?
    @State private var detailLoading = false
    @State private var detailErrorText: String?

    @State private var versions: [NBStoreClient.NBVersion] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var showAllVersions = false
    /// 正在取包的那一行（存 `externalIdentifier`，同一时刻只允许一行在取）
    @State private var fetchingID: String?
    /// 截图全屏预览（**复用** AppleID 商店详情页那套 `ImageGalleryViewer`）
    @State private var previewTarget: ImagePreviewTarget?
    /// 简介是否展开（NB 的 `DXSTDetailDescView` 同样有「展开/收起」）
    @State private var descExpanded = false

    private let versionPageSize = 12

    init(trackID: String,
         country: String,
         displayName: String? = nil,
         icon: String? = nil,
         offSale: Bool = false) {
        _trackID = State(initialValue: trackID)
        self.country = country
        self.displayName = displayName
        self.seedIcon = icon
        self.offSale = offSale
    }

    /// 标题：详情回来后用真名，否则用带进来的名字，最后才回落 ID
    private var title: String {
        if let n = detail?.name, !n.isEmpty { return n }
        if let n = displayName, !n.isEmpty { return n }
        return "App \(trackID)"
    }

    /// 图标：详情回来的 512 优先，其次是列表带进来的
    private var iconURL: String? {
        if let u = detail?.artwork512, !u.isEmpty { return u }
        if let u = detail?.artwork100, !u.isEmpty { return u }
        if let u = seedIcon, !u.isEmpty { return u }
        return nil
    }

    private var busyJob: IPADownloadCenter.Job? {
        center.activeJob(bundleId: nil, name: title)
    }

    private var visibleVersions: [NBStoreClient.NBVersion] {
        showAllVersions ? versions : Array(versions.prefix(versionPageSize))
    }

    var body: some View {
        List {
            if let job = busyJob { jobSection(job) }
            headerSection
            if let d = detail {
                if !d.screenshotURLs.isEmpty { screenshotSection(d) }
                if let desc = d.descriptionText, !desc.isEmpty { descriptionSection(desc) }
                metaSection(d)
                if let notes = d.releaseNotes, !notes.isEmpty { releaseSection(d, notes) }
            } else if detailLoading {
                detailLoadingSection
            }
            idSection
            if loading {
                loadingSection
            } else if let errorText {
                errorSection(errorText)
            } else {
                versionSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toastHost()
        .fullScreenCover(item: $previewTarget) { target in
            ImageGalleryViewer(urls: target.urls, startIndex: target.index)
        }
        .task { await loadAll() }
    }

    // MARK: - 头部（图标 + 名称 + 开发者 + 价格）

    private var headerSection: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                AsyncImage(url: URL(string: iconURL ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                    default: ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // 图标长按 = 「查看图标 / 提取图标」，与其它免登录源（I4）、AppleID 商店、
                // 列表行三处走**同一个** `ImagePreviewSupport.iconMenuItems` —— 不再各写一套。
                .contextMenu {
                    iconMenuItems(iconURL: iconURL,
                                  fileNameBase: detail?.bundleID ?? title) {
                        showIconPreview(iconURL, target: $previewTarget)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let sub = subtitleText {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let price = detail?.formattedPrice, !price.isEmpty {
                            chip(price, .blue)
                        }
                        if let v = detail?.version ?? versions.first?.version, !v.isEmpty {
                            chip("v\(v)", .gray)
                        }
                        if let s = detail?.sizeText {
                            chip(s, .green)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var subtitleText: String? {
        guard let d = detail else { return nil }
        var parts: [String] = []
        if let s = d.sellerName, !s.isEmpty { parts.append(s) }
        else if let a = d.artistName, !a.isEmpty { parts.append(a) }
        if let g = d.genres.first, !g.isEmpty { parts.append(g) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 截图（预览）—— 对应 NB 的 DXSTDetailADView

    /// 截图画廊：横向滚动，点一张进全屏查看器。
    ///
    /// **为什么要横向滚动**：NB 的 `DXSTDetailADView` 就是一个横向翻页容器；
    /// App Store 详情页也是同样的形态。用 `List` 里的 `ScrollView(.horizontal)`
    /// 而非 `TabView` —— 后者在列表行里高度会塌成 0（SwiftUI 的已知行为）。
    private func screenshotSection(_ d: NBStoreRankClient.AppDetail) -> some View {
        Section("预览") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(d.screenshotURLs.enumerated()), id: \.offset) { index, url in
                        Button {
                            previewTarget = ImagePreviewTarget(index: index, urls: d.screenshotURLs)
                        } label: {
                            AsyncImage(url: URL(string: url)) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().aspectRatio(contentMode: .fill)
                                case .failure:
                                    Image(systemName: "photo").foregroundStyle(.secondary)
                                default:
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .frame(width: 132, height: 234)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
        }
    }

    // MARK: - 简介 —— 对应 NB 的 DXSTDetailDescView

    private func descriptionSection(_ text: String) -> some View {
        Section("简介") {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(descExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 120 {
                Button(descExpanded ? "收起" : "展开") {
                    withAnimation(.easeInOut(duration: 0.18)) { descExpanded.toggle() }
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: - 信息表 —— 对应 NB 的 DXSTDetailInfoView

    private func metaSection(_ d: NBStoreRankClient.AppDetail) -> some View {
        Section("信息") {
            if let r = d.ratingText {
                infoRow("评分",
                        d.ratingCount.map { "\(r) · \($0) 个评分" } ?? r)
            }
            if let s = d.sellerName, !s.isEmpty { infoRow("开发者", s) }
            if !d.genres.isEmpty { infoRow("分类", d.genres.joined(separator: " ")) }
            if let mv = d.minimumOSVersion, !mv.isEmpty { infoRow("最低系统", "iOS \(mv)") }
            if let sz = d.sizeText { infoRow("大小", sz) }
            if let b = d.bundleID, !b.isEmpty { infoRow("Bundle ID", b) }
        }
    }

    // MARK: - 最近更新 —— 对应 NB 的 DXSTDetailVersionView

    private func releaseSection(_ d: NBStoreRankClient.AppDetail, _ notes: String) -> some View {
        Section {
            Text(notes)
                .font(.subheadline)
                .lineLimit(descExpanded ? nil : 5)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            HStack {
                Text("新功能")
                if let v = d.version, !v.isEmpty { Text("· v\(v)").foregroundStyle(.secondary) }
                Spacer()
                if let date = d.releaseDate, !date.isEmpty {
                    Text(date).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 下载中

    /// 「下载中」区块 —— 与爱思/牛蛙详情页同款布局。
    private func jobSection(_ job: IPADownloadCenter.Job) -> some View {
        Section("下载中") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(job.phase == .paused ? "已暂停" : job.stageText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let v = job.version, !v.isEmpty {
                        Text("v\(v)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(job.overall * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, max(0, job.overall)))
                HStack(spacing: 16) {
                    Button {
                        if job.phase == .paused {
                            center.resume(job.id)
                        } else {
                            center.pause(job.id)
                        }
                    } label: {
                        Label(job.phase == .paused ? "继续" : "暂停",
                              systemImage: job.phase == .paused ? "play.fill" : "pause.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(job.canPause ? Color.blue : Color.secondary)
                    .disabled(!job.canPause)

                    Button {
                        center.cancel(job.id)
                    } label: {
                        Label("删除安装包", systemImage: "trash")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)

                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 标识

    private var idSection: some View {
        Section {
            infoRow("App Store ID", trackID)
            infoRow("区域", country.uppercased())
        } header: {
            Text("来源")
        }
    }

    // MARK: - 历史版本

    private var versionSection: some View {
        Section {
            if versions.isEmpty {
                Text("该应用暂无历史版本")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(visibleVersions) { v in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("v\(v.version)")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let t = v.releaseTime, !t.isEmpty { chip(t, .gray) }
                                if let s = v.sizeText, !s.isEmpty { chip(s, .green) }
                            }
                        }
                        Spacer(minLength: 6)
                        if fetchingID == v.externalIdentifier {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Task { await installVersion(v) }
                            } label: {
                                Text("获取")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                    .padding(.vertical, 2)
                }
                if !showAllVersions && versions.count > versionPageSize {
                    Button {
                        showAllVersions = true
                    } label: {
                        Text("查看全部 \(versions.count) 个版本").font(.subheadline)
                    }
                }
            }
        } header: {
            Text(versions.isEmpty ? "历史版本" : "历史版本 · \(versions.count)")
        }
    }

    // MARK: - 小组件

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline).lineLimit(1).truncationMode(.middle)
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在读取版本列表…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var detailLoadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在读取应用详情…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func errorSection(_ text: String) -> some View {
        Section {
            Text(text).font(.subheadline).foregroundStyle(.red)
        }
    }

    // MARK: - 加载 / 下载

    /// 详情与版本列表并行拉 —— 两者互不依赖，串行会让页面多等一个来回。
    ///
    /// v0.3.549：前面先插一步 **ID 解析**（下架记录带的是 NB 行号，不是 App Store ID）.
    private func loadAll() async {
        await resolveTrackIDIfNeeded()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await loadDetail() }
            group.addTask { await loadVersions() }
        }
    }

    /// 确保 `trackID` 是**真正的 App Store 数字 ID**（v0.3.549）.
    ///
    /// ## 为什么需要这一步
    /// 下架记录里 `id` 是 NB 自己的行号（如 15993），`appStoreID` 与 `lookupData.trackId`
    /// 才可能有一个是真 ID。列表页传进来时已经优先挑了真 ID（`OffSaleApp.storeID`），
    /// 但**两个都空**的场合仍会传空串 —— 那时就只能靠名字去下架库反查.
    ///
    /// 拿不到就保持原样，由 `loadVersions` 报那句「缺少 App Store ID」——
    /// 这个错必须留在界面上（用户要能看出是缺 ID，而不是「点了没反应」）.
    private func resolveTrackIDIfNeeded() async {
        let sid = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        // 已经是纯数字 → 就是 App Store ID，不用解析.
        if !sid.isEmpty, sid.allSatisfy({ $0.isNumber }) { return }
        guard let hint = displayName, !hint.isEmpty else { return }
        do {
            let hits = try await NBStoreClient.searchOffSaleApp(keyword: hint)
            let match = hits.first { $0.displayName.caseInsensitiveCompare(hint) == .orderedSame } ?? hits.first
            if let real = match?.storeID, !real.isEmpty {
                LoginLogger.shared.log("[NB详情] 解析 App Store ID：「\(hint)」→ \(real)", category: .appStore)
                trackID = real
            }
        } catch {
            LoginLogger.shared.log("[NB详情] 解析 App Store ID 失败：\(error.localizedDescription)",
                                   category: .appStore)
        }
    }

    /// 拉详情（`itunes.apple.com/lookup`）。
    ///
    /// **失败不挡主要内容**：详情拿不到只是少几个区块，版本列表与取包照常，
    /// 所以这里只把错误记进日志，不占页面的 error 区块（那是给版本列表用的）。
    ///
    /// ## v0.3.549：**下架应用必须走 NB 自己的详情**
    ///
    /// 用户反馈「NB 源的应用详情界面还是没有详情和预览」—— 真因就在这一句 lookup：
    /// **下架应用在 Apple 的 lookup 里根本查不到**（它就是被下架了才搜不到），
    /// 所以 `results` 为空 → `detail` 为 nil → 页面上「预览 / 简介 / 信息 / 新功能」
    /// 四个区块**整组不渲染**，只剩「来源」和「历史版本」，正是用户那张截图的样子.
    ///
    /// ## v0.3.559：下架态**第一跳就走 NB 下架库**
    ///
    /// 上一版把下架回退放在 lookup 之后，等于每次都要先白等一次必然为空的请求，
    /// 而且回退里还指望「拿到 trackId 再直查 lookup」能中 —— Apple 对已下架的 id
    /// 也常常回空，所以经常整页仍然没详情.
    ///
    /// 现在 `searchOffSaleApp` 的每条记录里**内嵌着 NB 收录时存下的那份完整 lookup**
    /// （`lookupData`，43 个键，含 `description` / `screenshotUrls` / `genres` /
    /// `releaseNotes`），直接映射成 `AppDetail` 就能填满整个页面，**不用再碰 Apple**.
    /// 所以下架态把它提到第一跳，命中即返回.
    private func loadDetail() async {
        guard !trackID.isEmpty else { return }
        detailLoading = true
        defer { detailLoading = false }

        // ── ① 下架态：先吃 NB 下架库内嵌的那份 lookup（最全，且不依赖 Apple）──
        if offSale, let d = await offSaleDetail() {
            detail = d
            return
        }

        // ── ② 现场 lookup（在架应用的主路径）──
        do {
            detail = try await NBStoreRankClient.detail(trackID: trackID, country: country)
        } catch {
            detailErrorText = error.localizedDescription
            LoginLogger.shared.log("[NB详情] [提示] 详情拉取失败：\(error.localizedDescription)",
                                   category: .appStore)
        }
        // 这一跳拿到 → 直接结束.
        if detail != nil { return }

        // ── ③ 回退：按名字去 NB 下架库找，用内嵌 lookup 补详情 ──
        if let d = await offSaleDetail() {
            detail = d
            return
        }

        // ── ④ 兜底：换区域直查一次（下架应用可能只是本区下线）──
        await loadDetailViaOffSaleID()
    }

    /// 去 NB 下架库按名字找，命中就把内嵌的 `lookupData` 变成详情.
    ///
    /// 名字取 `displayName`（列表带进来的就是准的）；没带名字时用当前 `trackID`
    /// 对上一条即可（下架库的 `storeID` 里也有 trackId）.
    private func offSaleDetail() async -> NBStoreRankClient.AppDetail? {
        let hint = (displayName?.isEmpty == false) ? displayName! : ""
        guard !hint.isEmpty || !trackID.isEmpty else { return nil }
        do {
            let hits = try await NBStoreClient.searchOffSaleApp(keyword: hint.isEmpty ? trackID : hint)
            guard !hits.isEmpty else { return nil }
            // 同名的优先；其次是 trackId 对得上的；再退第一条.
            let sameName = hits.first { $0.displayName.caseInsensitiveCompare(hint) == .orderedSame }
            let sameID = hits.first { ($0.storeID ?? "") == trackID }
            guard let match = sameName ?? sameID ?? hits.first,
                  let d = match.lookupDetail else { return nil }
            LoginLogger.shared.log("[NB详情] 下架库内嵌详情命中：「\(d.name)」"
                                   + "截图 \(d.screenshotURLs.count) 张",
                                   category: .appStore)
            return d
        } catch {
            LoginLogger.shared.log("[NB详情] 下架库详情失败：\(error.localizedDescription)",
                                   category: .appStore)
            return nil
        }
    }

    /// 下架详情兜底（v0.3.549）：`trackID` 已经就是 App Store ID 的场合，直查一次.
    ///
    /// 与 `loadDetail` 的差别：这里**换区域再试一次** —— 下架应用常常是「在本区下架、
    /// 别的区还在架」，澳洲/美国区查得到的话就能把截图与简介补上.
    private func loadDetailViaOffSaleID() async {
        for cc in ["us", "cn", "hk"].filter({ $0 != country.lowercased() }) {
            if let d = try? await NBStoreRankClient.detail(trackID: trackID, country: cc) {
                LoginLogger.shared.log("[NB详情] 换区 \(cc) 查到详情（原区 \(country)）", category: .appStore)
                detail = d
                return
            }
        }
    }

    private func loadVersions() async {
        loading = true
        errorText = nil
        guard !trackID.isEmpty else {
            errorText = "缺少 App Store ID，无法查询版本"
            loading = false
            return
        }
        do {
            versions = try await NBStoreClient.versionList(trackID: trackID)
        } catch {
            errorText = "读取版本列表失败：\(error.localizedDescription)"
        }
        loading = false
    }

    /// 取某个版本的包并交给统一下载中心。
    ///
    /// v0.3.556：历史版本这条链路**只对在架应用有效**。
    /// 下架应用的包只能在**搜索结果**里拿（`searchOffSaleApp` 的 `appStoreData`），
    /// 用 trackId + externalVersionID 去查是查不到的（实测 `getOffSaleAppHistoryList`
    /// 对任何参数组合都取不到包）。所以下架态直接如实说明，不发这一发。
    @MainActor
    private func installVersion(_ v: NBStoreClient.NBVersion) async {
        guard !offSale else {
            ToastCenter.shared.show("下架应用请回列表页点「获取」")
            return
        }
        fetchingID = v.externalIdentifier
        defer { fetchingID = nil }
        do {
            let pkg = try await NBStoreClient.package(appID: trackID,
                                                      appVerId: v.externalIdentifier,
                                                      country: country)
            guard let pkg else {
                ToastCenter.shared.show("该版本没有可用的安装包")
                return
            }
            await startNBDownload(trackID: trackID,
                                  package: pkg,
                                  name: title,
                                  version: v.version,
                                  iconURL: iconURL)
        } catch {
            ToastCenter.shared.show("取包失败：\(error.localizedDescription)")
        }
    }
}
