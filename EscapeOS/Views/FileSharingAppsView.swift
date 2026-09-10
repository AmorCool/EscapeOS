import SwiftUI
import UIKit

/// v0.3.208：文档共享应用列表（iDescriptor InstalledApps 文件共享过滤移植）.
/// 区分可浏览（UIFileSharingEnabled=true）与不可浏览；点击可浏览项进入文件树.
/// v0.3.219：真实 App 图标（SpringBoardServices）+ 模块板块风格顶栏（.large + searchable）.
struct FileSharingAppsView: View {
    @State private var apps: [FileSharingApp] = []
    @State private var icons: [String: UIImage] = [:]
    @State private var loading = true
    @State private var errorText: String?
    @State private var filterEnabledOnly = true
    @State private var searchText: String = ""
    /// v0.3.270：Documents 容器大小（bundleId → 字节，后台懒算回填）
    @State private var docSizes: [String: Int64] = [:]
    @State private var computingDocs: Set<String> = []
    /// v0.3.281：深度读取的真实 Apple ID（Archive 通道，点击胶囊触发）
    @State private var deepAppleIds: [String: String] = [:]
    @State private var deepLoading: Set<String> = []
    /// v0.3.287：导出 IPA（Archive→AFC 拉回本地）与图标批量导出
    @State private var exportingIPA: Set<String> = []
    @State private var exportingIcons = false
    @State private var toastText: String?

    var body: some View {
        List {
                if loading {
                    Section {
                        HStack { ProgressView(); Text("正在读取已装应用…") }
                    }
                } else if let err = errorText {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        Toggle("仅显示文件共享应用", isOn: $filterEnabledOnly)
                    }
                    Section {
                        ForEach(filtered) { app in
                            appRow(app)
                        }
                    } header: {
                        Text("应用列表（\(filtered.count) 个）")
                    } footer: {
                        Text("点击 Apple ID 胶囊可深度读取安装来源账号：App 会被临时归档到设备（耗时与体积成正比），读取后自动清理。")
                            .font(.caption2)
                    }
                }
            }
            .listStyle(.insetGrouped)   // v0.3.214：参考模块板块样式
        .navigationTitle("文档浏览")
        .navigationBarTitleDisplayMode(.large)  // v0.3.212：参考模块板块顶栏样式
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用")
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)   // v0.3.214：系统搜索框替代自绘
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportAllIcons()
                } label: {
                    if exportingIcons {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                }
                .disabled(exportingIcons)
                .accessibilityLabel("导出全部应用图标")
            }
        }
        .autocorrectionDisabled()
        .overlay(alignment: .bottom) {
            if let toastText {
                Text(toastText)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            withAnimation { self.toastText = nil }
                        }
                    }
            }
        }
        .task {
            await load()
            // v0.3.288：不再自动跑 AFC 递归算文档大小——v0.3.284 起由 Lookup 的
            // DynamicDiskUsage 一次返回（原实现每 App 开 house_arrest 隧道 + 全树
            // 遍历，20 个 App 时列表长时间「计算中」，用户实测卡顿）.
        }
        // v0.3.270：切换「仅显示文件共享应用」/搜索结果变化时补算新出现项的文档大小

    }

    private var filtered: [FileSharingApp] {
        var list = apps
        if filterEnabledOnly { list = list.filter { $0.supportsFileSharing } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { $0.bundleId.lowercased().contains(q) || $0.name.lowercased().contains(q) }
        }
        return list
    }

    @ViewBuilder
    private func appRow(_ app: FileSharingApp) -> some View {
        Group {
            if app.supportsFileSharing {
                NavigationLink {
                    AppFileBrowserView(bundleId: app.bundleId, appName: app.name)
                } label: {
                    appContent(app)
                }
            } else {
                appContent(app)
            }
        }
        // v0.3.287：导出 IPA（爱思「导出应用」同款——Archive 归档后拉回本机）
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                exportIPA(app)
            } label: {
                Label(exportingIPA.contains(app.bundleId) ? "导出中…" : "导出 IPA", systemImage: "square.and.arrow.down")
            }
            .tint(.blue)
            .disabled(exportingIPA.contains(app.bundleId))
        }
    }

    /// v0.3.287：导出 IPA 到本机 Documents/AppStoreDownloads/（后台执行，归档耗时随体积）
    private func exportIPA(_ app: FileSharingApp) {
        let bundleId = app.bundleId
        guard !exportingIPA.contains(bundleId) else { return }
        exportingIPA.insert(bundleId)
        toastText = "正在归档 \(app.name)…（耗时与体积成正比）"
        LoginLogger.shared.log("[ExportIPA] 开始导出 \(bundleId)")
        Task.detached(priority: .userInitiated) {
            do {
                let url = try AppStoreIdReader.exportIPA(bundleId: bundleId) { line in
                    LoginLogger.shared.log("[ExportIPA] \(line)")
                }
                await MainActor.run {
                    exportingIPA.remove(bundleId)
                    toastText = "已导出：Documents/AppStoreDownloads/\(url.lastPathComponent)"
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    exportingIPA.remove(bundleId)
                    toastText = "导出失败：\(msg)"
                }
                LoginLogger.shared.log("[ExportIPA] 失败：\(msg)")
            }
        }
    }

    /// v0.3.287：批量导出全部应用图标到 Documents/AppIcons/（SpringBoardServices）
    private func exportAllIcons() {
        guard !exportingIcons else { return }
        exportingIcons = true
        let appsSnapshot = apps
        toastText = "正在导出 \(appsSnapshot.count) 个图标…"
        Task.detached(priority: .utility) {
            let discovery = AppDiscovery()
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("AppIcons", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var count = 0
            for app in appsSnapshot {
                if let icon = discovery.appIcon(for: app.bundleId),
                   let data = icon.pngData() {
                    let safeName = app.bundleId.replacingOccurrences(of: "/", with: "_")
                    let url = dir.appendingPathComponent("\(safeName).png")
                    try? data.write(to: url)
                    count += 1
                }
            }
            let total = count
            await MainActor.run {
                exportingIcons = false
                toastText = "已导出 \(total) 个图标到 Documents/AppIcons/"
            }
            LoginLogger.shared.log("[ExportIcons] 导出 \(total)/\(appsSnapshot.count) 个图标")
        }
    }

    private func appContent(_ app: FileSharingApp) -> some View {
        HStack(spacing: 12) {
            appIcon(app.bundleId)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).font(.subheadline.weight(.medium))
                    if app.applicationType == "System" {
                        Text("(系统)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(app.bundleId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // v0.3.270/284：信息胶囊（版本 / 应用大小 / 文档大小）+ 第二行安装来源
                HStack(spacing: 5) {
                    if !app.version.isEmpty {
                        capsule("v\(app.version)", tint: .blue)
                    }
                    capsule("应用 \(FileSharingService.formatMB(app.appSize))", tint: .green)
                    capsule(docCapsuleText(app), tint: .orange)
                }
                HStack(spacing: 5) {
                    appleIdCapsule(app)
                }
            }
            Spacer()
            if app.supportsFileSharing {
                Image(systemName: "doc.text.fill").foregroundStyle(.blue)
            } else {
                Text("未开启")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// v0.3.281：Apple ID 胶囊——点击触发深度读取（instproxy Archive → 归档包内
    /// iTunesMetadata.plist，爱思同款通道；耗时与 App 大小成正比）。
    @ViewBuilder
    private func appleIdCapsule(_ app: FileSharingApp) -> some View {
        let bundleId = app.bundleId
        let loading = deepLoading.contains(bundleId)
        let deep = deepAppleIds[bundleId]
        let shown: String = {
            if loading { return "读取中…" }
            if let deep { return deep.isEmpty ? "无 Apple ID" : deep }
            return app.appleId ?? "—"
        }()
        let tint: Color = {
            if loading { return .secondary }
            if let deep { return deep.isEmpty ? .gray : .purple }
            return app.appleId != nil ? .purple : .gray
        }()
        Button {
            deepRead(app)
        } label: {
            HStack(spacing: 3) {
                if loading { ProgressView().controlSize(.mini) }
                Text(shown).font(.caption2.weight(.medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    /// 深度读取：Archive 该 App 并从归档包解析 iTunesMetadata.appleId（后台执行）。
    private func deepRead(_ app: FileSharingApp) {
        let bundleId = app.bundleId
        guard !deepLoading.contains(bundleId) else { return }
        deepLoading.insert(bundleId)
        LoginLogger.shared.log("[AppleID] 开始深度读取 \(bundleId)（Archive 通道）")
        Task.detached(priority: .userInitiated) {
            let result = try? AppStoreIdReader.installingAppleId(bundleId: bundleId) { line in
                LoginLogger.shared.log("[AppleID] \(line)")
            }
            await MainActor.run {
                deepLoading.remove(bundleId)
                if let result {
                    deepAppleIds[bundleId] = result.appleId
                } else {
                    deepAppleIds[bundleId] = ""
                }
            }
        }
    }

    private func capsule(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    private func docCapsuleText(_ app: FileSharingApp) -> String {
        // v0.3.271：优先 Browse 返回的 DynamicDiskUsage（一次请求即得）；缺失才走
        // house_arrest AFC 递归懒算.
        if let size = app.docSize ?? docSizes[app.bundleId] {
            return "文档 \(FileSharingService.formatMB(size))"
        }
        if computingDocs.contains(app.bundleId) {
            return "文档 计算中…"
        }
        return "文档 —"
    }

    /// v0.3.271：后台逐 App 计算 Documents 容器大小——仅对 Browse 未返回
    /// DynamicDiskUsage 的项兜底（Browse 已返回的项不再重复开隧道）.
    private func computeDocumentSizes() {
        let targets = filtered.filter { $0.supportsFileSharing && $0.docSize == nil && docSizes[$0.bundleId] == nil && !computingDocs.contains($0.bundleId) }
        guard !targets.isEmpty else { return }
        for app in targets {
            let bundleId = app.bundleId
            computingDocs.insert(bundleId)
            Task.detached(priority: .utility) {
                let size = try? FileSharingService.computeDocumentsSize(bundleId: bundleId)
                await MainActor.run {
                    computingDocs.remove(bundleId)
                    if let size {
                        docSizes[bundleId] = size
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            apps = try await Task.detached(priority: .userInitiated) {
                try FileSharingService.listAppsWithFileSharing()
            }.value
            errorText = nil
            loadIcons()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// v0.3.219：后台批量拉真实 App 图标（SpringBoardServices，AppDiscovery 同源）
    private func loadIcons() {
        let ids = apps.map { $0.bundleId }
        guard !ids.isEmpty else { return }
        let discovery = AppDiscovery()
        Task.detached(priority: .utility) {
            for id in ids {
                guard let icon = discovery.appIcon(for: id) else { continue }
                await MainActor.run { self.icons[id] = icon }
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ bundleId: String) -> some View {
        if let img = icons[bundleId] {
            Image(uiImage: img)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
        }
    }
}