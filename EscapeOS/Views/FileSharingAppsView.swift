import SwiftUI
import UIKit

/// v0.3.208：文档共享应用列表（iDescriptor InstalledApps 文件共享过滤移植）。
/// 区分可浏览（UIFileSharingEnabled=true）与不可浏览；点击可浏览项进入文件树。
/// v0.3.219：真实 App 图标（SpringBoardServices）+ 模块板块风格顶栏（.large + searchable）。
struct FileSharingAppsView: View {
    @State private var apps: [FileSharingApp] = []
    @State private var icons: [String: UIImage] = [:]
    @State private var loading = true
    @State private var errorText: String?
    @State private var filterEnabledOnly = true
    @State private var searchText: String = ""

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
        .searchable(text: $searchText, prompt: "搜索应用")   // v0.3.214：系统搜索框替代自绘
        .autocorrectionDisabled()
        .task { await load() }
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
            VStack(alignment: .leading, spacing: 2) {
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