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
struct I4StoreFreeView: View {

    @State private var rank: I4PCStoreClient.Rank = .recommend
    @State private var apps: [I4PCStoreClient.I4App] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var keyword = ""
    @State private var searchResults: [I4PCStoreClient.I4App] = []
    @State private var searching = false

    /// v0.3.305：已下载数量（进入页面时读一次磁盘台账）
    @State private var downloadedCount = 0
    /// 统一下载中心（免登录源与 Apple ID 共用）
    @ObservedObject private var center = IPADownloadCenter.shared

    private var isSearchMode: Bool { !keyword.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            downloadManagerSection
            if isSearchMode {
                searchSection
            } else {
                rankSection
                listSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("免登录下载")
        .navigationBarTitleDisplayMode(.inline)
        // v0.3.367：用户要求顶栏搜索**常驻**（下滑也能搜），对齐主页「应用」板块的 .always。
        .searchable(text: $keyword,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索应用（无需登录）")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: rank) { _, _ in Task { await load() } }
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
        .task {
            downloadedCount = IPADownloadLibrary.shared.items().count
            if apps.isEmpty { await load() }
        }
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
        } else if searchResults.isEmpty {
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

            trailingControl(app)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func trailingControl(_ app: I4PCStoreClient.I4App) -> some View {
        if let job = center.activeJob(bundleId: app.bundleId, name: app.name) {
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
                install(app)
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

    // MARK: - 加载

    private func load() async {
        loading = true
        errorText = nil
        do {
            apps = try await I4PCStoreClient.list(rank: rank)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func runSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { searchResults = []; return }
        searching = true
        Task {
            do {
                searchResults = try await I4PCStoreClient.search(keyword: kw)
            } catch {
                searchResults = []
                ToastCenter.shared.show("搜索失败：\(error.localizedDescription)")
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
