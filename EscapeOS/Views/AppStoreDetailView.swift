import SwiftUI
import UIKit

/// AppStore 应用详情。
struct AppStoreDetailView: View {
    @State var item: AppStoreItem

    @ObservedObject private var center = IPADownloadCenter.shared
    @State private var expanded = false
    @State private var isFavorite = false

    // 安装方式
    @State private var showInstallOptions = false
    @State private var showAccountPicker = false

    // 预览浏览器
    @State private var viewerIndex: Int?

    // 内置网页
    @State private var browserTarget: LinkShareTarget?

    // 下载管理
    @State private var showDownloadManager = false

    var body: some View {
        List {
            headerSection
            if !item.screenshots.isEmpty { screenshotsSection }
            infoSection
            if let notes = item.releaseNotes, !notes.isEmpty { releaseNotesSection(notes) }
            if let desc = item.summary, !desc.isEmpty { descriptionSection(desc) }
            moreSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let added = AppFavoritesStore.shared.toggle(item)
                    isFavorite = added
                    ToastCenter.shared.show(added ? "已加入收藏栏" : "已移出收藏栏")
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDownloadManager = true
                } label: {
                    // 有进行中的任务时带小圆点
                    Image(systemName: center.activeJobs.isEmpty
                          ? "arrow.down.circle" : "arrow.down.circle.fill")
                        .foregroundStyle(center.activeJobs.isEmpty ? Color.secondary : Color.blue)
                }
            }
        }
        .sheet(isPresented: $showDownloadManager) {
            NavigationStack {
                IPADownloadManagerView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showDownloadManager = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showInstallOptions) {
            InstallOptionsSheet(
                appleIDSubtitle: appleIDSubtitle,
                onAppleID: {
                    showInstallOptions = false
                    chooseAppleIDAndInstall()
                },
                onI4: {
                    showInstallOptions = false
                    installFromFreeSource()
                })
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccountPicker) {
            AppleIDPickerSheet { email in
                showAccountPicker = false
                IPADownloadCenter.shared.startWithAppleID(item: item, email: email)
                ToastCenter.shared.show("已开始用「\(email)」下载")
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $browserTarget) { target in
            InAppBrowserView(title: target.title, url: target.url)
        }
        .fullScreenCover(item: Binding(
            get: { viewerIndex.map { ScreenshotTarget(index: $0) } },
            set: { viewerIndex = $0?.index }
        )) { target in
            AppStoreScreenshotViewer(urls: item.screenshots, startIndex: target.index)
        }
        .toastHost()
        .task { await loadDetail() }
        .onAppear { isFavorite = AppFavoritesStore.shared.contains(appId: item.id) }
    }

    /// Apple ID 通道的副标题（未登录时说明清楚）
    private var appleIDSubtitle: String {
        let list = AppStoreDownloadStore.shared.usableAccounts
        if list.isEmpty { return "尚未登录 Apple ID" }
        if list.count == 1 { return list[0].email }
        return "共 \(list.count) 个账号，可自选"
    }

    private var activeJob: IPADownloadCenter.Job? {
        center.activeJob(bundleId: item.bundleId, name: item.name)
    }

    // MARK: 头部（图标 + 信息 + 获取按钮：同一张卡）

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    iconView
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.headline).lineLimit(2)
                        if let seller = item.seller {
                            Text(seller).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            Text(item.priceText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(item.priceText == "免费" ? Color.green : Color.blue)
                            if let r = item.ratingText {
                                Label(r, systemImage: "star.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let c = item.ratingCount {
                                Text("(\(c.formattedCount))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                installArea
            }
            .padding(.vertical, 6)
        }
    }

    /// 图标：长按只弹菜单，点菜单里的「提取图标」才下载（避免误触）
    private var iconView: some View {
        AsyncImage(url: URL(string: item.iconURL ?? item.iconSmallURL ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFit()
            case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
            default: ProgressView().controlSize(.small)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .contextMenu {
            Button {
                extractIcon()
            } label: {
                Label("提取图标", systemImage: "square.and.arrow.down")
            }
        }
    }

    @ViewBuilder
    private var installArea: some View {
        if let job = activeJob {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(job.stageText).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Text("\(Int(job.overall * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, max(0, job.overall)))

                HStack(spacing: 16) {
                    // 暂停/继续：只有直链下载期间可用（安装阶段不可暂停）
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
                        ToastCenter.shared.show("已取消并删除该安装包")
                    } label: {
                        Label("删除安装包", systemImage: "trash")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)

                    Spacer(minLength: 0)

                    Button {
                        showDownloadManager = true
                    } label: {
                        Label("下载管理", systemImage: "list.bullet")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        } else if let failed = center.lastFinishedJob(bundleId: item.bundleId, name: item.name),
                  failed.phase == .failed, let err = failed.error {
            VStack(alignment: .leading, spacing: 6) {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                getButton
            }
        } else {
            getButton
        }
    }

    /// 「获取」按钮：弹出安装方式选择
    private var getButton: some View {
        Button {
            showInstallOptions = true
        } label: {
            Text(item.priceText == "免费" ? "获取" : "购买 \(item.priceText)")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: 截图

    private var screenshotsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(item.screenshots.enumerated()), id: \.offset) { index, url in
                        Button {
                            viewerIndex = index
                        } label: {
                            AsyncImage(url: URL(string: url)) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFill()
                                case .failure: Color(.tertiarySystemFill)
                                default: ProgressView().controlSize(.small)
                                }
                            }
                            .frame(width: 180, height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
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
            infoRow("AppID", item.id)
        }
    }

    private func infoRow(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value?.isEmpty == false ? (value ?? "—") : "—")
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func releaseNotesSection(_ notes: String) -> some View {
        Section("新功能 · \(item.version ?? "")") {
            Text(notes).font(.footnote).padding(.vertical, 2)
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

    // MARK: 更多

    private var moreSection: some View {
        Section {
            NavigationLink {
                AppStoreVersionHistoryView(item: item, country: "cn")
            } label: {
                Label("历史版本", systemImage: "clock.arrow.circlepath")
            }
            Button {
                _ = AppStoreInstaller.openInAppStore(item)
            } label: {
                Label("去 App Store 安装", systemImage: "arrow.up.forward.app")
            }
            if let u = item.webURL {
                Button {
                    browserTarget = LinkShareTarget(title: item.name, url: u)
                } label: {
                    Label("网页版商店页", systemImage: "safari")
                }
            }
            if let job = center.lastFinishedJob(bundleId: item.bundleId, name: item.name),
               job.phase == .failed, let err = job.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: 动作

    /// 多账号 → 弹窗自选；单账号 → 直接用；无账号 → 提示
    private func chooseAppleIDAndInstall() {
        let list = AppStoreDownloadStore.shared.usableAccounts
        guard !list.isEmpty else {
            ToastCenter.shared.show("尚未登录 Apple ID —— 请先用「从爱思源快速安装」")
            return
        }
        if list.count > 1 {
            showAccountPicker = true
            return
        }
        IPADownloadCenter.shared.startWithAppleID(item: item, email: list[0].email)
        ToastCenter.shared.show("已开始用「\(list[0].email)」下载")
    }

    /// 免登录源：按 bundleId 找包 → 下载（可暂停）→ 安装
    private func installFromFreeSource() {
        guard let bid = item.bundleId, !bid.isEmpty else {
            ToastCenter.shared.show("该应用缺少 Bundle ID，无法从源匹配")
            return
        }
        ToastCenter.shared.show("正在查找安装包…")
        Task {
            _ = await IPADownloadCenter.shared.startFromI4Source(
                name: item.name, bundleId: bid, iconURL: item.iconURL)
        }
    }

    /// 长按菜单里的「提取图标」
    private func extractIcon() {
        let raw = item.iconURL ?? item.iconSmallURL ?? ""
        guard !raw.isEmpty else {
            ToastCenter.shared.show("没有可提取的图标")
            return
        }
        ToastCenter.shared.show("正在提取图标…")
        Task {
            do {
                let image = try await MediaSaver.downloadImage(raw.appStoreHighResImage)
                let outcome = try await MediaSaver.save(image,
                                                        fileName: "\(item.bundleId ?? item.id)-icon")
                await MainActor.run {
                    switch outcome {
                    case .photos: ToastCenter.shared.show("图标已存到相册")
                    case .files(let name): ToastCenter.shared.show("已存到文件 App：AppIcons/\(name)")
                    }
                }
            } catch {
                await MainActor.run { ToastCenter.shared.show("提取失败：\(error.localizedDescription)") }
            }
        }
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

private struct ScreenshotTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - 安装方式选择（爱思那条弹窗的加强版）

struct InstallOptionsSheet: View {
    let appleIDSubtitle: String
    let onAppleID: () -> Void
    let onI4: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("选择安装方式")
                .font(.headline)
                .padding(.top, 18)
                .padding(.bottom, 14)

            VStack(spacing: 10) {
                option(icon: "person.crop.circle.badge.checkmark",
                       tint: .blue,
                       title: "使用已登录 AppleID 安装",
                       subtitle: appleIDSubtitle,
                       action: onAppleID)
                option(icon: "bolt.fill",
                       tint: .green,
                       title: "从爱思源快速安装",
                       subtitle: "免登录，服务端已签名",
                       action: onI4)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func option(icon: String, tint: Color, title: String, subtitle: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.14)).frame(width: 40, height: 40)
                    Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AppleID 账号选择（多账号时自选一个下载）

struct AppleIDPickerSheet: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [AppStoreAccount] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(accounts, id: \.email) { account in
                    Button {
                        onPick(account.email)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email).font(.subheadline)
                                Text("store \(account.store)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if account.email == AppStoreDownloadStore.shared.selectedAccount?.email {
                                Text("当前").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择 AppleID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear { accounts = AppStoreDownloadStore.shared.usableAccounts }
    }
}

// MARK: - 预览浏览器（左右滑动 / 长按确认后保存）

struct AppStoreScreenshotViewer: View {
    let urls: [String]
    @State var startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var current: Int = 0
    @State private var confirmSave = false
    @State private var pendingURL: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    AsyncImage(url: URL(string: url.appStoreHighResImage)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                        case .failure:
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
                        default:
                            ProgressView().tint(.white)
                        }
                    }
                    .tag(index)
                    .onLongPressGesture(minimumDuration: 0.4) {
                        pendingURL = url
                        confirmSave = true
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(16)
            }
        }
        .confirmationDialog("保存这张图片？", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("保存到相册") { savePending() }
            Button("取消", role: .cancel) { pendingURL = nil }
        }
        .toastHost()
        .onAppear { current = min(max(0, startIndex), max(0, urls.count - 1)) }
    }

    private func savePending() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        ToastCenter.shared.show("正在保存…")
        Task {
            do {
                let image = try await MediaSaver.downloadImage(url.appStoreHighResImage)
                let outcome = try await MediaSaver.save(image, fileName: "screenshot-\(current + 1)")
                await MainActor.run {
                    switch outcome {
                    case .photos: ToastCenter.shared.show("已保存到相册")
                    case .files(let name): ToastCenter.shared.show("已存到文件 App：AppIcons/\(name)")
                    }
                }
            } catch {
                await MainActor.run { ToastCenter.shared.show("保存失败：\(error.localizedDescription)") }
            }
        }
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
