import SwiftUI

/// v0.3.295：AppStore 商店（主页新板块）
///
/// 数据源：Apple 公开接口（iTunes Search / Lookup / 官方榜单 RSS）。
/// 安装：①系统 App Store（默认）②itms-services OTA（爱思同款机制，需自备 manifest 源）。
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
    @State private var showOTASheet = false
    @State private var showSources = false
    @State private var showDisclaimer = false
    @State private var showI4 = false
    @ObservedObject private var installManager = AppStoreInstallManager.shared
    @State private var otaURL = ""
    @State private var toast: String?

    private var isSearchMode: Bool { !keyword.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            if isSearchMode {
                searchSection
            } else {
                chartsSection
                genreSection
                listSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AppStore 商店")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索 App Store 应用")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: kind) { _, _ in Task { await loadCharts() } }
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
                        otaURL = UserDefaults.standard.string(forKey: "AppStoreOTAManifest") ?? ""
                        showOTASheet = true
                    } label: {
                        Label("OTA 安装（自定义分发源）", systemImage: "arrow.down.app")
                    }
                    Button {
                        showSources = true
                    } label: {
                        Label("分发源管理", systemImage: "server.rack")
                    }
                    Button {
                        showI4 = true
                    } label: {
                        Label("爱思商店（专题 / 榜单）", systemImage: "cart.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showOTASheet) { otaSheet }
        .sheet(isPresented: $showSources) { NavigationStack { AppStoreSourceView() } }
        .sheet(isPresented: $showI4) { NavigationStack { AppStoreI4View() } }
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
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .task {
            if !AppStoreDisclaimer.accepted { showDisclaimer = true }
            if items.isEmpty { await loadCharts() }
        }
    }

    // MARK: 榜单

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
                    NavigationLink {
                        AppStoreDetailView(item: app)
                    } label: {
                        appRow(app, rank: idx + 1)
                    }
                }
            } header: {
                Text("\(genre.title) · \(kind.title) · 共 \(items.count) 款")
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
            Section("搜索结果 · \(searchResults.count) 款") {
                ForEach(searchResults) { app in
                    NavigationLink {
                        AppStoreDetailView(item: app)
                    } label: {
                        appRow(app, rank: nil)
                    }
                }
            }
        }
    }

    // MARK: 行

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
                install(app)
            } label: {
                if installManager.isRunning(app.id) {
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
            .disabled(installManager.isRunning(app.id))
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

    // MARK: OTA 安装面板

    private var otaSheet: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://…/manifest.plist", text: $otaURL, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("manifest 描述文件地址")
                } footer: {
                    Text("走 iOS 系统的 itms-services OTA 通道（与爱思助手同一条机制）：系统读取该 plist 后自行下载并安装其中指向的 IPA。plist 与 IPA 需由你自己的分发源提供——本 App 不内置任何第三方分发地址。安装后如提示「未受信任的开发者」，需到 设置 → 通用 → VPN与设备管理 信任对应证书。")
                        .font(.caption2)
                }
                Section {
                    Button {
                        UserDefaults.standard.set(otaURL, forKey: "AppStoreOTAManifest")
                        if AppStoreInstaller.installViaOTA(manifestURL: otaURL) {
                            toast = "已交给系统安装"
                        } else {
                            toast = "地址无效或无法打开"
                        }
                        clearToastLater()
                        showOTASheet = false
                    } label: {
                        Label("开始 OTA 安装", systemImage: "arrow.down.app.fill")
                    }
                    .disabled(otaURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        AppStoreInstaller.openCertificateTrustSettings()
                    } label: {
                        Label("打开证书信任设置", systemImage: "checkmark.shield")
                    }
                }
            }
            .navigationTitle("OTA 安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showOTASheet = false }
                }
            }
        }
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

    /// 安装：走已配置的分发源 → 下载 IPA → RSD 隧道安装（v0.3.300 起为真实下载安装）；
    /// 没有可用源时退回系统 App Store。
    private func install(_ app: AppStoreItem) {
        if AppStoreSourceStore.shared.enabledSources.isEmpty {
            _ = AppStoreInstaller.openInAppStore(app)
            toast = "未配置分发源，已打开系统 App Store"
            clearToastLater()
            return
        }
        guard !installManager.isRunning(app.id) else { return }
        AppStoreInstallManager.shared.start(item: app)
        toast = "已开始处理「\(app.name)」，进度见详情页"
        clearToastLater()
    }

    private func clearToastLater() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toast = nil
        }
    }
}
