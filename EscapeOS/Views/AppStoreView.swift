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
    @ObservedObject private var center = IPADownloadCenter.shared

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

    /// 列表行的「获取」：**统一走下载中心**（有 Apple ID 走官方源，否则走免登录源）。
    private func install(_ app: AppStoreItem) {
        guard center.activeJob(bundleId: app.bundleId, name: app.name) == nil else { return }
        let accounts = AppStoreDownloadStore.shared.usableAccounts
        if let first = accounts.first {
            IPADownloadCenter.shared.startWithAppleID(item: app, email: first.email)
            ToastCenter.shared.show("已开始用「\(first.email)」下载安装")
            return
        }
        guard let bid = app.bundleId, !bid.isEmpty else {
            ToastCenter.shared.show("该应用缺少 Bundle ID，无法从源匹配")
            return
        }
        ToastCenter.shared.show("正在查找安装包…")
        Task {
            _ = await IPADownloadCenter.shared.startFromI4Source(
                name: app.name, bundleId: bid, iconURL: app.iconURL)
        }
    }
}
