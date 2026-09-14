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
/// 行右侧的「安装」走 `startNiuwaDownload(_:region:)`（先取直链，再交给 `IPADownloadCenter`）。
struct I4StoreFreeView: View {

    /// v0.3.382：免登录商店的**来源**（接口一 = 爱思，接口二 = 牛蛙）
    enum StoreSource: String, CaseIterable, Identifiable {
        case i4 = "爱思"
        case niuwa = "牛蛙"

        var id: String { rawValue }
    }

    /// v0.3.382：牛蛙源的分区（客户端硬编码中国/美国/香港三档）
    private var region: NiuwaStoreClient.NiuwaRegion { NiuwaStoreClient.NiuwaRegion(rawValue: regionRaw) ?? .cn }

    @State private var source: StoreSource = .i4
    @State private var regionRaw = "cn"
    @State private var rank: I4PCStoreClient.Rank = .recommend
    @State private var apps: [I4PCStoreClient.I4App] = []
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

    /// v0.3.305：已下载数量（进入页面时读一次磁盘台账）
    @State private var downloadedCount = 0
    /// 统一下载中心（免登录源与 Apple ID 共用）
    @ObservedObject private var center = IPADownloadCenter.shared

    /// v0.3.399：行长按「查看图标」的全屏预览。
    ///
    /// **复用** AppleID 商店详情页那套 `ImageGalleryViewer`（同一个类型，见 `ImagePreviewSupport.swift`），
    /// 不在这里另写一个只显示一张图的查看器 —— 长按存图也因此白得。
    @State private var previewImages: [String] = []
    @State private var previewTarget: ImagePreviewTarget?

    private var isSearchMode: Bool { !keyword.trimmingCharacters(in: .whitespaces).isEmpty }

    /// v0.3.382：搜索框提示随来源变（牛蛙要多说一句区域）
    private var searchPrompt: String {
        source == .i4 ? "搜索应用（无需登录）" : "搜索应用（无需登录 · \(region.title)）"
    }

    var body: some View {
        List {
            downloadManagerSection
            sourceSection
            if isSearchMode {
                searchSection
            } else {
                if source == .i4 { rankSection }
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
        // v0.3.382：切来源 / 切区域都要重新取数（搜索态重搜，列表态重载）
        .onChange(of: source) { _, _ in
            if isSearchMode { runSearch() } else { Task { await load() } }
        }
        .onChange(of: regionRaw) { _, _ in
            guard source == .niuwa else { return }
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
            ImageGalleryViewer(urls: previewImages, startIndex: target.index)
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

            if source == .niuwa {
                Picker("区域", selection: $regionRaw) {
                    ForEach(NiuwaStoreClient.NiuwaRegion.allCases) { r in
                        Text(r.title).tag(r.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
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
            Picker("分组", selection: $rank) {
                ForEach(I4PCStoreClient.Rank.allCases) { r in
                    Text(r.title).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .listRowBackground(Color.clear)
        } footer: {
            Text("数据来自爱思 PC 端同款公开接口，安装包由服务端提供（已签名），无需登录 Apple ID。")
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
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            }
        } else if source == .niuwa {
            // v0.3.382：牛蛙源只有搜索，不做榜单（接口文档里只有 /appstore/search + /download）
            Section {
                Text("牛蛙源请用上方搜索框按关键词找应用。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else if apps.isEmpty {
            Section {
                Text("该分组暂时没有数据。").font(.subheadline).foregroundStyle(.secondary)
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
                    Text("没有找到匹配的应用。").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Section("搜索结果 · \(searchResults.count) 款") {
                    ForEach(searchResults) { app in
                        row(app)
                    }
                }
            }
        } else {
            if niuwaSearchResults.isEmpty {
                Section {
                    Text("没有找到匹配的应用。").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Section("搜索结果 · \(niuwaSearchResults.count) 款") {
                    ForEach(niuwaSearchResults) { app in
                        row(app)
                    }
                }
            }
        }
    }

    // MARK: - 行

    /// v0.3.364：左侧（图标 + 文案）整块可点进**应用详情**，右侧仍是原有的下载/进度控件。
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
                showIconPreview(app.icon, images: $previewImages, target: $previewTarget)
            }
        }
    }

    /// 右侧控件：有任务 → 进度 + 暂停 / 删除；没有 → 一枚「安装」。
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
                Text("安装")
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
    /// 右侧与爱思行共用 `trailingControl(...)`（安装 / 进度 / 暂停 / 删除）。
    ///
    /// v0.3.406：**左侧整块可点进 `NiuwaStoreDetailView`**（此前牛蛙源没有详情页）；
    /// 右侧原来的「获取直链」改成真正的「安装」—— 先取直链再交给 `IPADownloadCenter`。
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
                showIconPreview(app.iconURL, images: $previewImages, target: $previewTarget)
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
            return
        }
        searching = true
        let src = source
        let reg = region
        Task {
            if src == .i4 {
                do {
                    searchResults = try await I4PCStoreClient.search(keyword: kw)
                } catch {
                    searchResults = []
                    ToastCenter.shared.show("搜索失败：\(error.localizedDescription)")
                }
            } else {
                do {
                    niuwaSearchResults = try await NiuwaStoreClient.search(keyword: kw, region: reg)
                } catch {
                    niuwaSearchResults = []
                    // ★ v0.3.387：失败原因必须**留在界面上**。
                    // 只弹一个一闪而过的 toast 的话，用户看到的就是「列表全空、什么也不知道」，
                    // 这一轮就是这么丢掉真机证据的（用户只反馈「界面都是空的」）。
                    // `StoreError.server` 的 description 已带 `nwcore_code` 与 `nwcore_messages`。
                    errorText = "牛蛙源搜索失败：\(error.localizedDescription)"
                    ToastCenter.shared.show("搜索失败")
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
                                           remoteURL: ipaURL.absoluteString,
                                           autoInstall: true)
        downloadedCount = IPADownloadLibrary.shared.items().count
    }
}

// MARK: - v0.3.406 牛蛙源：取直链 → 交给统一下载中心

/// 牛蛙源「下载」的**唯一一份实现**（列表行与详情页共用，不留第二套）。
///
/// 与爱思源唯一的差别：爱思的**搜索结果里就带 `ipaURL`**，点一下直接进下载中心；
/// 牛蛙要**先打一发** `POST /appstore/download` 才拿得到直链（`ba_ipaURL`），
/// 所以这一步必须是异步的。
///
/// 拿到直链之后走的是**与爱思源一字不差的同一条链路**：
/// `IPADownloadCenter.shared.start(name:bundleId:version:iconURL:remoteURL:autoInstall:source:sinfBase64:)`
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
/// `@MainActor`：**顶层自由函数不像 `View` 那样被推断成主 actor**，而这里要调
/// `IPADownloadCenter`（`@MainActor`）与 `ToastCenter`。两个调用点都在 `View` 内。
@MainActor
func startNiuwaDownload(_ app: NiuwaStoreClient.NiuwaApp,
                        region: NiuwaStoreClient.NiuwaRegion) async {
    do {
        let full = try await NiuwaStoreClient.download(bundleId: app.bundleId, region: region)
        guard let link = full?.downloadURL, !link.isEmpty else {
            ToastCenter.shared.show("该应用没有可用的安装包")
            return
        }
        _ = IPADownloadCenter.shared.start(name: app.name,
                                           bundleId: app.bundleId,
                                           version: full?.version ?? app.version,
                                           iconURL: app.iconURL,
                                           remoteURL: link,
                                           autoInstall: true,
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
