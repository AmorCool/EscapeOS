import SwiftUI

/// v0.3.303：免登录下载商店（爱思 PC 端源）
///
/// 与「AppStore 商店」的区别：**完全不需要登录 Apple ID，也不需要配置分发源**。
/// 数据与安装包都来自爱思 PC 端在用的公开接口（`app4.i4.cn` + `d-app6.i4.cn`），
/// 服务端存放的即为已签名 IPA（`isSignOK == "1"`）。
///
/// 流程：榜单/搜索 → 拿 `path` → `d-app6.i4.cn/soft/<path>` 下载 IPA
/// → `AppStoreInstallService.installLocalIPA`（RSD 隧道 + AFC + installation_proxy）。
struct I4StoreFreeView: View {

    @State private var rank: I4PCStoreClient.Rank = .recommend
    @State private var apps: [I4PCStoreClient.I4App] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var keyword = ""
    @State private var searchResults: [I4PCStoreClient.I4App] = []
    @State private var searching = false

    /// 每个 App 的操作状态文案（下载/安装进度）
    @State private var progress: [String: String] = [:]
    @State private var toast: String?
    /// v0.3.305：已下载数量（进入页面时读一次磁盘台账）
    @State private var downloadedCount = 0

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
        .searchable(text: $keyword,
                    placement: .navigationBarDrawer(displayMode: .automatic),
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
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
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

    private func row(_ app: I4PCStoreClient.I4App) -> some View {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let v = app.version { chip("v\(v)", .blue) }
                    if let s = app.sizeText { chip(s, .green) }
                    if app.isSigned { chip("已签名", .purple) }
                }
                if let s = app.slogan, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)

            if let st = progress[app.id] {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(st).font(.caption2).foregroundStyle(.secondary)
                }
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
        .padding(.vertical, 3)
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
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
                toast = "搜索失败：\(error.localizedDescription)"
            }
            searching = false
        }
    }

    // MARK: - 下载并安装（免登录）

    private func install(_ app: I4PCStoreClient.I4App) {
        guard progress[app.id] == nil else { return }
        guard let ipaURL = app.ipaURL else {
            toast = "该应用没有可用的安装包地址"
            return
        }
        progress[app.id] = "下载中…"
        let bundle = app.bundleId ?? app.id
        let version = app.version ?? "x"

        Task {
            do {
                let ipa = try await AppStoreInstallService.downloadIPA(
                    urlString: ipaURL.absoluteString,
                    suggestedName: "\(bundle)-\(version).ipa",
                    progress: { p in
                        // 下载进度来自 URLSession delegate queue（非主线程）
                        DispatchQueue.main.async {
                            self.progress[app.id] = String(format: "下载 %.0f%%", p * 100)
                        }
                    },
                    onLog: { LoginLogger.shared.log("[I4源] \($0)") })

                self.progress[app.id] = "安装中…"
                // v0.3.305：登记到下载台账（商店元信息只有列表里才有，包本身读不出来）
                await MainActor.run {
                    IPADownloadLibrary.shared.record(fileURL: ipa,
                                                     displayName: app.name,
                                                     bundleId: app.bundleId,
                                                     version: app.version,
                                                     iconURL: app.icon,
                                                     source: "爱思免登录")
                    self.downloadedCount = IPADownloadLibrary.shared.items().count
                }
                try await AppStoreInstallService.installLocalIPA(
                    ipa.path,
                    progress: { p in
                        DispatchQueue.main.async {
                            self.progress[app.id] = String(format: "安装 %.0f%%", p * 100)
                        }
                    },
                    onLog: { LoginLogger.shared.log("[I4源] \($0)") })

                progress[app.id] = nil
                toast = "已安装：\(app.name)"
            } catch {
                progress[app.id] = nil
                toast = "失败：\(error.localizedDescription)"
                LoginLogger.shared.log("[I4源] 失败 \(app.name)：\(error.localizedDescription)")
            }
        }
    }
}
