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
    @State private var showAccountSheet = false
    @State private var signedEmail: String?
    @State private var pendingItem: AppStoreItem?
    @State private var otaURL = ""
    @State private var toast: String?

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

    /// v0.3.302：账号区 —— 商店内直接登录 Apple ID。
    ///
    /// 此前登录入口只存在于旧的「App Store 下载」页，本页没有 → 用户点「获取」被
    /// 提示「无分发源」，误以为要手工配置。这里把登录做成商店内的第一入口：
    /// 登录后即可一键下载安装（免费应用），无需任何配置。
    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let email = signedEmail ?? AppStoreDownloadStore.shared.selectedAccount?.email {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(email).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("已登录 · 点「获取」即可下载安装").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("切换") { showAccountSheet = true }
                        .font(.caption)
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    showAccountSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录 Apple ID").font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                            Text("登录后点「获取」即可下载并安装（免费应用）")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        } footer: {
            if signedEmail == nil, (AppStoreDownloadStore.shared.selectedAccount == nil) {
                Text("没有账号时才会退回「分发源」或系统 App Store；登录后无需任何配置。")
                    .font(.caption2)
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
                        Text("多账号 / 批量登录 / 退出登录")
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
                        Text("只看 AppStore 板块（登录/下载/安装）")
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
            accountSection
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
        .sheet(isPresented: $showAccountSheet) {
            AddAccountSheet { account in
                AppStoreDownloadStore.shared.add(account)
                signedEmail = account.email
                toast = "已登录：\(account.email)"
                clearToastLater()
                // 若是被登录拦下的安装请求，登录完自动继续
                if let pending = pendingItem {
                    pendingItem = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        AppStoreInstallManager.shared.start(item: pending)
                    }
                }
            }
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
            signedEmail = AppStoreDownloadStore.shared.selectedAccount?.email
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

    /// 安装：本机 Apple ID 走 App Store 官方源（sinf 按本机身份生成，可直接安装）；
    /// 未登录则**就地弹出登录**（登录后自动继续安装），不再要求去配置分发源。
    private func install(_ app: AppStoreItem) {
        guard !installManager.isRunning(app.id) else { return }
        let hasAccount = !(AppStoreDownloadStore.shared.selectedAccount == nil)
            || signedEmail != nil
        if !hasAccount {
            pendingItem = app
            showAccountSheet = true
            return
        }
        if (AppStoreDownloadStore.shared.selectedAccount == nil),
           let email = signedEmail {
            // 极端情况：本地账号被清掉但界面仍显示已登录 —— 重新拉一次
            LoginLogger.shared.log("[AppStore] 账号状态不一致（\(email)），已重置界面状态", category: .appStoreStore)
            self.signedEmail = nil
            pendingItem = app
            showAccountSheet = true
            return
        }
        AppStoreInstallManager.shared.start(item: app)
        toast = "已开始从 App Store 下载安装「\(app.name)」"
        clearToastLater()
    }

    private func clearToastLater() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toast = nil
        }
    }
}
