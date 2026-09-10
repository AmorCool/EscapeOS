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
                    Section("应用列表（\(filtered.count) 个）") {
                        ForEach(filtered) { app in
                            appRow(app)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)   // v0.3.214：参考模块板块样式
        .navigationTitle("文档浏览")
        .navigationBarTitleDisplayMode(.large)  // v0.3.212：参考模块板块顶栏样式
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用")
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)   // v0.3.214：系统搜索框替代自绘
        .autocorrectionDisabled()
        .task {
            await load()
            computeDocumentSizes()
        }
        // v0.3.270：切换「仅显示文件共享应用」/搜索结果变化时补算新出现项的文档大小
        .onChange(of: filterEnabledOnly) { _, _ in computeDocumentSizes() }
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
                // v0.3.270：信息胶囊（版本 / 应用大小 / 文档大小 / 安装来源 Apple ID）
                HStack(spacing: 5) {
                    if !app.version.isEmpty {
                        capsule("v\(app.version)", tint: .blue)
                    }
                    capsule("应用 \(FileSharingService.formatMB(app.appSize))", tint: .green)
                    capsule(docCapsuleText(app), tint: .orange)
                    if let appleId = app.appleId, !appleId.isEmpty {
                        capsule(appleId, tint: .purple)
                    }
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