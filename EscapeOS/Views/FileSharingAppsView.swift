import SwiftUI

/// v0.3.208：文档共享应用列表（iDescriptor InstalledApps 文件共享过滤移植）。
/// 区分可浏览（UIFileSharingEnabled=true）与不可浏览；点击可浏览项进入文件树。
struct FileSharingAppsView: View {
    @State private var apps: [FileSharingApp] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var filterEnabledOnly = true
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            searchBar
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
        }
        .navigationTitle("文档浏览")
        .navigationBarTitleDisplayMode(.inline)
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

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索应用", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
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
            Image(systemName: app.applicationType == "System" ? "app.badge.fill" : "app.fill")
                .foregroundStyle(app.supportsFileSharing ? .blue : .secondary)
                .frame(width: 26)
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
        } catch {
            errorText = error.localizedDescription
        }
    }
}