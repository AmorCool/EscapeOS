import SwiftUI

/// v0.3.295：AppStore 应用详情（进入时用 Lookup 补全字段）
struct AppStoreDetailView: View {
    @State var item: AppStoreItem
    @ObservedObject private var installManager = AppStoreInstallManager.shared
    @State private var showAccountSheet = false
    @State private var signedEmail: String?
    @State private var expanded = false
    @State private var loadingDetail = false
    @State private var installingSource = false
    @State private var toastText: String?

    /// 是否已有 App Store 账号（有则「获取」直接下载安装，无需任何配置）
    private var hasAccount: Bool {
        signedEmail != nil || !(AppStoreDownloadStore.shared.selectedAccount == nil)
    }

    var body: some View {
        List {
            headerSection
            if !item.screenshots.isEmpty { screenshotsSection }
            infoSection
            if let notes = item.releaseNotes, !notes.isEmpty { releaseNotesSection(notes) }
            if let desc = item.summary, !desc.isEmpty { descriptionSection(desc) }
            actionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toastText {
                Text(toastText)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .task { await loadDetail() }
        .onAppear { signedEmail = AppStoreDownloadStore.shared.selectedAccount?.email }
        .sheet(isPresented: $showAccountSheet) {
            AddAccountSheet { account in
                AppStoreDownloadStore.shared.add(account)
                signedEmail = account.email
                toastText = "已登录：\(account.email)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    installManager.start(item: item)
                }
            }
        }
    }

    // MARK: 头部

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: URL(string: item.iconURL ?? item.iconSmallURL ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                    default: ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                    if let seller = item.seller {
                        Text(seller)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(item.priceText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(item.priceText == "免费" ? Color.green : Color.blue)
                        if let r = item.ratingText {
                            Label(r, systemImage: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let c = item.ratingCount {
                            Text("(\(c.formattedCount))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)

            Button {
                _ = AppStoreInstaller.openInAppStore(item)
            } label: {
                Text(item.priceText == "免费" ? "获取" : "购买 \(item.priceText)")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    // MARK: 截图

    private var screenshotsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(item.screenshots, id: \.self) { url in
                        AsyncImage(url: URL(string: url)) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            case .failure:
                                Color(.tertiarySystemFill)
                            default:
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(width: 180, height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            Text("预览")
        }
    }

    // MARK: 信息

    private var infoSection: some View {
        Section("信息") {
            infoRow("开发者", item.seller)
            infoRow("类别", item.genres.isEmpty ? item.primaryGenre : item.genres.joined(separator: "、"))
            infoRow("大小", item.sizeText)
            infoRow("版本", item.version)
            infoRow("兼容性", item.minimumOS.map { "需要 iOS \($0) 或更高版本" })
            infoRow("语言", item.languages.isEmpty ? nil : "\(item.languages.count) 种语言")
            infoRow("年龄分级", item.contentRating)
            infoRow("上架时间", Self.fmtDate(item.releaseDate))
            infoRow("更新时间", Self.fmtDate(item.updatedDate))
            infoRow("支持设备", item.supportedDevicesCount > 0 ? "\(item.supportedDevicesCount) 款" : nil)
            infoRow("Bundle ID", item.bundleId)
            infoRow("Apple ID", item.id)
        }
    }

    private func infoRow(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value?.isEmpty == false ? (value ?? "—") : "—")
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    // MARK: 新功能 / 简介

    private func releaseNotesSection(_ notes: String) -> some View {
        Section("新功能 · \(item.version ?? "")") {
            Text(notes)
                .font(.footnote)
                .foregroundStyle(.primary)
                .padding(.vertical, 2)
        }
    }

    private func descriptionSection(_ desc: String) -> some View {
        Section("简介") {
            Text(expanded ? desc : String(desc.prefix(220)) + (desc.count > 220 ? "…" : ""))
                .font(.footnote)
                .padding(.vertical, 2)
            if desc.count > 220 {
                Button(expanded ? "收起" : "展开全文") {
                    withAnimation { expanded.toggle() }
                }
                .font(.footnote)
            }
        }
    }

    // MARK: 操作

    private var actionSection: some View {
        Section {
            // v0.3.300：主通道 = 走分发源下载 IPA → RSD 隧道安装（不再只跳转 App Store）
            if let st = installManager.state(for: item.id), st.phase.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(st.phase.title).font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Text("\(Int(st.overall * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: st.overall)
                    if st.phase == .downloading, st.downloadProgress > 0 {
                        Text(String(format: "下载 %.0f%%", st.downloadProgress * 100))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if st.phase == .installing, st.installProgress > 0 {
                        Text(String(format: "安装 %.0f%%", st.installProgress * 100))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    if hasAccount {
                        installManager.start(item: item)
                    } else {
                        showAccountSheet = true
                    }
                } label: {
                    if hasAccount {
                        Label(item.priceText == "免费" ? "下载并安装" : "下载并安装（\(item.priceText)）",
                              systemImage: "arrow.down.circle.fill")
                    } else {
                        Label("登录 Apple ID 后下载安装",
                              systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }

            NavigationLink {
                AppStoreVersionHistoryView(item: item, country: "cn")
            } label: {
                Label("历史版本", systemImage: "clock.arrow.circlepath")
            }

            if let st = installManager.state(for: item.id), st.phase == .failed,
               let err = st.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                installFromSource()
            } label: {
                HStack {
                    if installingSource { ProgressView().controlSize(.small) }
                    Label(installingSource ? "正在交给系统…" : "交给系统 OTA 安装",
                          systemImage: "arrow.down.app.fill")
                }
            }
            .disabled(installingSource)

            Button {
                _ = AppStoreInstaller.openInAppStore(item)
            } label: {
                Label("在 App Store 中打开", systemImage: "arrow.up.forward.app")
            }
            if let u = item.webURL {
                Link(destination: u) {
                    Label("网页版商店页", systemImage: "safari")
                }
            }
            Button {
                AppStoreInstaller.openCertificateTrustSettings()
            } label: {
                Label("证书信任设置", systemImage: "checkmark.shield")
            }
        } footer: {
            Text("「下载并安装」从已配置的分发源取 manifest → 下载 IPA → 经 RSD 隧道安装到本机。"
                 + "App Store 原始包为 FairPlay 加密，无法安装；需源提供已重签名或已解密的 IPA。")
                .font(.caption2)
        }
    }

    // MARK: 加载

    /// 通过已配置的分发源安装（走 itms-services OTA，与爱思手机端同一条系统调用）
    private func installFromSource() {
        guard !installingSource else { return }
        installingSource = true
        Task {
            do {
                let r = try await AppStoreInstallService.installUsingAnySource(item: item) { line in
                    LoginLogger.shared.log("[AppStore] \(line)", category: .appStoreStore)
                }
                await MainActor.run {
                    installingSource = false
                    toastText = "已交给系统安装（\(r.source.name)）"
                }
            } catch {
                await MainActor.run {
                    installingSource = false
                    toastText = "安装失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func loadDetail() async {
        loadingDetail = true
        if let full = try? await AppStoreService.lookup(id: item.id) {
            // 保留榜单里已有但详情接口未返回的图标
            var merged = full
            if merged.iconURL == nil { merged.iconURL = item.iconURL }
            if merged.summary == nil { merged.summary = item.summary }
            item = merged
        }
        loadingDetail = false
    }

    private static func fmtDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return String(iso.prefix(10)) }
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd"
        return out.string(from: d)
    }
}

private extension Int {
    /// 12345 → 1.2万
    var formattedCount: String {
        if self >= 10000 {
            return String(format: "%.1f万", Double(self) / 10000)
        }
        return "\(self)"
    }
}
