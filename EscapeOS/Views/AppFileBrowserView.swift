import SwiftUI
import UIKit

/// v0.3.214：App 文档浏览（重做版）——
/// - 顶部目录分段：Documents（默认）/ Library / tmp
/// - Documents 走 vend_documents（文件共享 App 必可开）；Library/tmp 需要完整容器
///   （vend_container），多数第三方 App 无权限 → 显示「无权限」
/// - 文件操作移植 FileBrowserView 能力：新建文件夹 / 重命名 / 删除 / 属性 / 下载到本地
struct AppFileBrowserView: View {
    let bundleId: String
    let appName: String

    enum Scope: String, CaseIterable, Identifiable {
        case documents = "Documents"
        case library = "Library"
        case tmp = "tmp"
        var id: String { rawValue }
        var path: String { "/\(rawValue)" }
        var needsContainer: Bool { self != .documents }
    }

    @State private var scope: Scope = .documents
    @State private var currentPath = "/Documents"
    @State private var entries: [AfcEntry] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var loading = true
    @State private var errorText: String?
    /// 当前活动的 AFC 会话
    @State private var afcClient: OpaquePointer?
    /// 完整容器会话（vend_container 成功才有；Documents 会话不足够时补）
    @State private var containerAfc: OpaquePointer?
    /// 本 scope 是否无权限（vend_container 失败）
    @State private var noPermission = false
    @State private var title = "Documents"
    /// 操作状态
    @State private var renameTarget: AfcEntry?
    @State private var renameText = ""
    @State private var deleteTarget: AfcEntry?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var fileInfoTarget: AfcEntry?
    @State private var fileInfoDetail: String?
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            scopePicker
            if loading {
                ProgressView("正在加载…").padding(.vertical, 50)
            } else if noPermission {
                ContentUnavailableView("无权限", systemImage: "lock.fill",
                    description: Text("\(appName) 不允许访问 \(scope.rawValue) 目录"))
            } else if let err = errorText {
                ContentUnavailableView("无法访问", systemImage: "folder.badge.questionmark",
                                       description: Text(err))
            } else if entries.isEmpty {
                ContentUnavailableView("空目录", systemImage: "folder",
                                       description: Text("\(displayCurrentPath) 下没有文件"))
            } else {
                List {
                    Section {
                        ForEach(entries) { entry in
                            rowFor(entry)
                        }
                    } header: {
                        Text(displayCurrentPath).font(.caption.monospaced())
                    }
                }
                .listStyle(.insetGrouped)
            }
            if let toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(Color(.systemGray6)))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .navigationTitle(scope == .documents ? appName : "\(appName) · \(scope.rawValue)")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if currentPath != scope.path {
                    Button("上级") { navigateUp() }
                }
                Button {
                    showNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("新建文件夹")
            }
        }
        .task { await connectForScope() }
        .onDisappear { closeAll() }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名", text: $newFolderName)
            Button("创建") { Task { await createFolder() } }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: renameAlertBinding) {
            TextField("新名称", text: $renameText)
            Button("确定") { Task { await doRename() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(renameTarget?.name ?? "")
        }
        .confirmationDialog("删除 \(deleteTarget?.name ?? "")？", isPresented: deleteAlertBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await doDelete() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可恢复")
        }
        .alert("文件信息", isPresented: fileInfoAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fileInfoDetail ?? "")
        }
    }

    // MARK: 状态绑定
    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
    private var fileInfoAlertBinding: Binding<Bool> {
        Binding(get: { fileInfoDetail != nil }, set: { if !$0 { fileInfoDetail = nil } })
    }

    private var displayCurrentPath: String {
        if scope == .documents {
            if currentPath == "/Documents" || currentPath == "/" { return "/Documents" }
            let trimmed = currentPath.hasPrefix("/") ? String(currentPath.dropFirst()) : currentPath
            return "/\(trimmed)"
        }
        if currentPath == scope.path || currentPath == "/" { return scope.path }
        return currentPath
    }

    // MARK: 顶部目录分段
    private var scopePicker: some View {
        Picker("目录", selection: $scope) {
            ForEach(Scope.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: scope) { _, _ in
            Task { await connectForScope() }
        }
    }

    // MARK: 连接与列目录
    private func connectForScope() async {
        closeClient()
        loading = true
        noPermission = false
        errorText = nil
        defer { loading = false }
        do {
            if scope.needsContainer {
                // Library / tmp：需要完整容器。Documents 会话不足以访问 → vend_container
                if containerAfc == nil {
                    do {
                        let c = try await Task.detached(priority: .userInitiated) {
                            try FileSharingService.openAppContainer(bundleId: bundleId)
                        }.value
                        containerAfc = c
                    } catch {
                        noPermission = true
                        entries = []
                        currentPath = scope.path
                        return
                    }
                }
                afcClient = containerAfc
                currentPath = scope.path
                await loadDir(path: scope.path)
            } else {
                // Documents
                if afcClient == nil {
                    let c = try await Task.detached(priority: .userInitiated) {
                        try FileSharingService.openAppDocuments(bundleId: bundleId)
                    }.value
                    afcClient = c
                }
                currentPath = "/Documents"
                await loadDir(path: "/Documents")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadDir(path: String) async {
        guard let client = activeClient() else { return }
        loading = true
        defer { loading = false }
        do {
            let results = try FileSharingService.listDirectory(afc: client, path: path)
            var sizeMap: [String: Int64] = [:]
            for e in results where !e.isDirectory {
                sizeMap[e.path] = FileSharingService.fileSize(afc: client, path: e.path) ?? 0
            }
            await MainActor.run {
                currentPath = path
                entries = results
                sizes = sizeMap
                errorText = nil
            }
        } catch {
            await MainActor.run { errorText = error.localizedDescription; entries = [] }
        }
    }

    private func activeClient() -> OpaquePointer? {
        scope.needsContainer ? (containerAfc ?? afcClient) : afcClient
    }

    private func navigateUp() {
        var p = currentPath
        if p == scope.path || p == "/" { return }
        if p.hasSuffix("/") { p.removeLast() }
        if let last = p.lastIndex(of: "/") {
            let parent = String(p[..<last])
            Task { await loadDir(path: parent.isEmpty ? scope.path : parent) }
        }
    }

    // MARK: 行
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
            .contextMenu { itemMenu(entry) }
        } else {
            HStack {
                Image(systemName: fileIcon(entry.name)).foregroundStyle(.gray).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.subheadline)
                    Text(formatSize(sizes[entry.path] ?? 0))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .contextMenu { itemMenu(entry) }
            .onTapGesture {
                fileInfoTarget = entry
                fileInfoDetail = fileDetailText(entry)
            }
        }
    }

    @ViewBuilder
    private func itemMenu(_ entry: AfcEntry) -> some View {
        Button("重命名") {
            renameTarget = entry
            renameText = entry.name
        }
        Button("删除", role: .destructive) {
            deleteTarget = entry
        }
        if !entry.isDirectory {
            Button("下载到本地") {
                Task { await download(entry) }
            }
            Button("文件信息") {
                fileInfoDetail = fileDetailText(entry)
            }
        }
    }

    // MARK: 操作
    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty, let client = activeClient() else { return }
        let path = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
        do {
            try FileSharingService.makeDirectory(afc: client, path: path)
            showToast("已创建 \(name)")
            await loadDir(path: currentPath)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func doRename() async {
        guard let t = renameTarget, let client = activeClient() else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        renameTarget = nil
        guard !name.isEmpty else { return }
        let parent = (t.path as NSString).deletingLastPathComponent
        let dest = parent + "/" + name
        do {
            try FileSharingService.rename(afc: client, from: t.path, to: dest)
            showToast("已重命名")
            await loadDir(path: currentPath)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func doDelete() async {
        guard let t = deleteTarget, let client = activeClient() else { return }
        deleteTarget = nil
        do {
            try FileSharingService.remove(afc: client, path: t.path, recursive: t.isDirectory)
            showToast("已删除")
            await loadDir(path: currentPath)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func download(_ entry: AfcEntry) async {
        guard let client = activeClient() else { return }
        showToast("正在下载…")
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try FileSharingService.downloadFile(afc: client, path: entry.path)
            }.value
            // 存到本 App 文档目录
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = (entry.name as NSString).lastPathComponent
            let dest = dir.appendingPathComponent("\(appName)-\(safeName)")
            try data.write(to: dest)
            showToast("已保存：\(dest.lastPathComponent)")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func fileDetailText(_ entry: AfcEntry) -> String {
        var lines = [entry.name, entry.isDirectory ? "类型：文件夹" : "类型：文件"]
        if !entry.isDirectory {
            lines.append("大小：\(formatSize(sizes[entry.path] ?? 0))")
        }
        lines.append("路径：\(entry.path)")
        return lines.joined(separator: "\n")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    private func closeClient() {
        if let c = afcClient { afc_client_free(c); afcClient = nil }
        // containerAfc 保留（复用）——除非离开页面
    }
    private func closeAll() {
        closeClient()
        if let c = containerAfc { afc_client_free(c); containerAfc = nil }
    }

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo.fill"
        case "mp4", "mov", "m4v": return "film.fill"
        case "mp3", "m4a", "wav", "aac", "flac": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "json", "plist", "xml": return "curlybraces"
        default: return "doc.fill"
        }
    }

    private func formatSize(_ b: Int64) -> String {
        if b <= 0 { return "—" }
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        if b < Int64(1024 * 1024 * 1024) { return String(format: "%.1f MB", Double(b) / 1024 / 1024) }
        return String(format: "%.1f GB", Double(b) / 1024 / 1024 / 1024)
    }
}