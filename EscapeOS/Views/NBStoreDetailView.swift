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
    let trackID: String
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
        self.trackID = trackID
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
                            previewTarget = ImagePreviewTarget(urls: d.screenshotURLs, index: index)
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
    private func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await loadDetail() }
            group.addTask { await loadVersions() }
        }
    }

    /// 拉详情（`itunes.apple.com/lookup`）。
    ///
    /// **失败不挡主要内容**：详情拿不到只是少几个区块，版本列表与取包照常，
    /// 所以这里只把错误记进日志，不占页面的 error 区块（那是给版本列表用的）。
    private func loadDetail() async {
        guard !trackID.isEmpty else { return }
        detailLoading = true
        defer { detailLoading = false }
        do {
            detail = try await NBStoreRankClient.detail(trackID: trackID, country: country)
        } catch {
            detailErrorText = error.localizedDescription
            LoginLogger.shared.log("[NB详情] ○ 详情拉取失败：\(error.localizedDescription)",
                                   category: .appStore)
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
    @MainActor
    private func installVersion(_ v: NBStoreClient.NBVersion) async {
        fetchingID = v.externalIdentifier
        defer { fetchingID = nil }
        do {
            // v0.3.545：按「上架 / 下架」走不同 method（同一端点）。
            let pkg: NBStoreClient.NBPackage?
            if offSale {
                pkg = try await NBStoreClient.offSalePackage(ipaID: trackID,
                                                             appVerId: v.externalIdentifier,
                                                             country: country)
            } else {
                pkg = try await NBStoreClient.package(appID: trackID,
                                                      appVerId: v.externalIdentifier,
                                                      country: country)
            }
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
