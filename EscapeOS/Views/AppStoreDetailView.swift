import SwiftUI
import UIKit

/// AppStore 应用详情。
struct AppStoreDetailView: View {
    @State var item: AppStoreItem
    @ObservedObject private var installManager = AppStoreInstallManager.shared
    @State private var expanded = false
    @State private var loadingDetail = false
    @State private var toastText: String?

    // 免登录源直装
    @State private var installingFree = false
    @State private var freeStage: String?
    @State private var freeProgress: Double = 0

    // 预览浏览器
    @State private var viewerIndex: Int?

    /// 是否已有 App Store 账号（有则走本机 Apple ID 通道）
    private var hasAccount: Bool {
        !(AppStoreDownloadStore.shared.selectedAccount == nil)
    }

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
        .overlay(alignment: .bottom) {
            if let toastText {
                Text(toastText)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .fullScreenCover(item: Binding(
            get: { viewerIndex.map { ScreenshotTarget(index: $0) } },
            set: { viewerIndex = $0?.index }
        )) { target in
            AppStoreScreenshotViewer(urls: item.screenshots, startIndex: target.index)
        }
        .task { await loadDetail() }
    }

    // MARK: 头部（图标 + 信息 + 获取按钮：同一张卡）

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    iconView
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

                installArea
            }
            .padding(.vertical, 6)
        }
    }

    /// 图标：长按弹出「提取图标」
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
        .onLongPressGesture(minimumDuration: 0.35) { extractIcon() }
        .contextMenu {
            Button {
                extractIcon()
            } label: {
                Label("提取图标", systemImage: "square.and.arrow.down")
            }
        }
    }

    /// 获取 / 下载安装 / 进度
    @ViewBuilder
    private var installArea: some View {
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
            }
        } else if installingFree {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(freeStage ?? "下载中").font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Text("\(Int(freeProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, max(0, freeProgress)))
            }
        } else {
            Button {
                startInstall()
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
    }

    // MARK: 截图（点击进浏览器）

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
                Label("在 App Store 中打开", systemImage: "arrow.up.forward.app")
            }
            if let u = item.webURL {
                Link(destination: u) {
                    Label("网页版商店页", systemImage: "safari")
                }
            }
            if let st = installManager.state(for: item.id), st.phase == .failed,
               let err = st.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: 动作

    /// 有 Apple ID → 官方源；否则走免登录源直装（RSD 隧道）
    private func startInstall() {
        if hasAccount {
            installManager.start(item: item)
            return
        }
        installFromFreeSource()
    }

    /// 免登录源：按 bundleId 找包 → 下载 → RSD 隧道安装
    private func installFromFreeSource() {
        guard !installingFree else { return }
        installingFree = true
        freeProgress = 0
        freeStage = "查找安装包"
        Task {
            do {
                guard let bid = item.bundleId, !bid.isEmpty else {
                    await MainActor.run {
                        installingFree = false
                        toastText = "该应用缺少 Bundle ID，无法从源匹配"
                    }
                    return
                }
                guard let hit = await SourcePackageLocator.find(bundleId: bid, name: item.name) else {
                    await MainActor.run {
                        installingFree = false
                        toastText = "源里没有该应用，已为你打开 App Store"
                        _ = AppStoreInstaller.openInAppStore(item)
                    }
                    return
                }
                await MainActor.run { freeStage = "下载安装包" }
                let ipa = try await AppStoreInstallService.downloadIPA(
                    urlString: hit.ipaURL,
                    suggestedName: "\(bid)-\(hit.version ?? "x").ipa",
                    progress: { p in
                        DispatchQueue.main.async { freeProgress = p * 0.6 }
                    },
                    onLog: { LoginLogger.shared.log("[商店] \($0)", category: .appStore) })
                await MainActor.run {
                    IPADownloadLibrary.shared.record(fileURL: ipa,
                                                     displayName: item.name,
                                                     bundleId: bid,
                                                     version: hit.version,
                                                     iconURL: item.iconURL,
                                                     source: "爱思免登录")
                    freeStage = "安装中"
                    freeProgress = 0.6
                }
                try await AppStoreInstallService.installLocalIPA(
                    ipa.path,
                    progress: { p in
                        DispatchQueue.main.async { freeProgress = 0.6 + p * 0.4 }
                    },
                    onLog: { LoginLogger.shared.log("[商店] \($0)", category: .appStore) })
                IPADownloadLibrary.shared.markInstalled(fileName: ipa.lastPathComponent)
                await MainActor.run {
                    installingFree = false
                    freeStage = nil
                    toastText = "已安装：\(item.name)"
                }
            } catch {
                await MainActor.run {
                    installingFree = false
                    freeStage = nil
                    toastText = "安装失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 长按图标 → 提取（优先存相册，失败存沙盒）
    private func extractIcon() {
        let raw = item.iconURL ?? item.iconSmallURL ?? ""
        guard !raw.isEmpty else {
            toastText = "没有可提取的图标"
            return
        }
        toastText = "正在提取图标…"
        Task {
            do {
                let image = try await MediaSaver.downloadImage(raw.appStoreHighResImage)
                let outcome = try await MediaSaver.save(image,
                                                        fileName: "\(item.bundleId ?? item.id)-icon")
                await MainActor.run {
                    switch outcome {
                    case .photos: toastText = "图标已存到相册"
                    case .files(let name): toastText = "已存到文件 App：AppIcons/\(name)"
                    }
                }
            } catch {
                await MainActor.run { toastText = "提取失败：\(error.localizedDescription)" }
            }
        }
    }

    private func loadDetail() async {
        loadingDetail = true
        if let full = try? await AppStoreService.lookup(id: item.id) {
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

private struct ScreenshotTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - 预览浏览器（左右滑动 / 长按保存到相册）

struct AppStoreScreenshotViewer: View {
    let urls: [String]
    @State var startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var current: Int = 0
    @State private var toast: String?

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
                    .onLongPressGesture(minimumDuration: 0.35) { save(url) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
        }
        .onAppear { current = min(max(0, startIndex), max(0, urls.count - 1)) }
    }

    private func save(_ url: String) {
        toast = "正在保存…"
        Task {
            do {
                let image = try await MediaSaver.downloadImage(url.appStoreHighResImage)
                let outcome = try await MediaSaver.save(image, fileName: "screenshot-\(current + 1)")
                await MainActor.run {
                    switch outcome {
                    case .photos: toast = "已保存到相册"
                    case .files(let name): toast = "已存到文件 App：AppIcons/\(name)"
                    }
                }
            } catch {
                await MainActor.run { toast = "保存失败：\(error.localizedDescription)" }
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
