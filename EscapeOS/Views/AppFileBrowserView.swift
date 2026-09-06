import SwiftUI

/// v0.3.208：App 文档浏览（house_arrest vend_documents 拿 AFC，仅 Documents 根）。
/// 路径导航 + 大小/类型显示（iDescriptor FileExplorer 简化版）。
struct AppFileBrowserView: View {
    let bundleId: String
    let appName: String
    @State private var currentPath = "/Documents"   // v0.3.213：iDescriptor rootPath 同款
    @State private var entries: [AfcEntry] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var loading = true
    @State private var errorText: String?
    @State private var afcClient: OpaquePointer?
    @State private var title: String = "Documents"

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if loading {
                ProgressView().padding(.vertical, 40)
            } else if let err = errorText {
                ContentUnavailableView("无法访问文档", systemImage: "folder.badge.questionmark",
                                       description: Text(err))
            } else if entries.isEmpty {
                ContentUnavailableView("空目录", systemImage: "folder",
                                       description: Text("该目录下没有文件"))
            } else {
                List {
                    ForEach(entries) { entry in
                        rowFor(entry)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)  // v0.3.212：参考模块板块顶栏样式
        .task { await connectAndList() }
        .onDisappear { closeAFC() }
    }

    private var pathBar: some View {
        HStack {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(displayPath)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if currentPath != "/Documents" {
                Button("上级") { navigateUp() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// v0.3.212：去掉"//"——根目录显示"Documents"，子目录去掉前导斜杠
    private var displayPath: String {
        if currentPath == "/" { return "Documents" }
        let trimmed = currentPath.hasPrefix("/") ? String(currentPath.dropFirst()) : currentPath
        return "\(appName) / \(trimmed)"
    }

    @ViewBuilder
    private func rowFor(_ entry: AfcEntry) -> some View {
        if entry.isDirectory {
            Button {
                Task { await loadDir(path: entry.path) }
            } label: {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.blue).frame(width: 24)
                    Text(entry.name).font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                Image(systemName: "doc.fill").foregroundStyle(.gray).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.subheadline)
                    Text(formatSize(sizes[entry.path] ?? 0))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func navigateUp() {
        // v0.3.213：根 = /Documents（house_arrest AFC 根之上不可访问）
        if currentPath == "/Documents" { return }
        var p = currentPath
        if p.hasSuffix("/") { p.removeLast() }
        if let last = p.lastIndex(of: "/") {
            let parent = String(p[..<last])
            Task { await loadDir(path: parent.isEmpty ? "/Documents" : parent) }
        } else {
            Task { await loadDir(path: "/Documents") }
        }
    }

    private func connectAndList() async {
        loading = true
        defer { loading = false }
        do {
            let client = try await Task.detached(priority: .userInitiated) {
                try FileSharingService.openAppDocuments(bundleId: bundleId)
            }.value
            afcClient = client
            title = appName
            errorText = nil
            // v0.3.213：iDescriptor rootPath="/Documents" — house_arrest AFC 根是数据容器，
            // 文件共享根在 /Documents 子目录；列 "/" 会被 house_arrest 拒（之前吞成空目录）
            await loadDir(path: "/Documents")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadDir(path: String) async {
        guard let client = afcClient else { return }
        loading = true
        defer { loading = false }
        // v0.3.213：错误显示在 UI 上，不再吞成空目录
        let results: [AfcEntry]
        do {
            results = try FileSharingService.listDirectory(afc: client, path: path)
            await MainActor.run { errorText = nil }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                entries = []
            }
            return
        }
        var sizeMap: [String: Int64] = [:]
        for e in results where !e.isDirectory {
            sizeMap[e.path] = FileSharingService.fileSize(afc: client, path: e.path) ?? 0
        }
        await MainActor.run {
            currentPath = path
            entries = results
            sizes = sizeMap
        }
    }

    private func closeAFC() {
        if let client = afcClient {
            afc_client_free(client)
            afcClient = nil
        }
    }

    private func formatSize(_ b: Int64) -> String {
        if b <= 0 { return "—" }
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }
}