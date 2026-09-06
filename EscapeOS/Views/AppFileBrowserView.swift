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
    // v0.3.221：新建（文件夹 / 文件.txt 可改后缀）——sheet 替代失效的 alert TextField
    @State private var showCreateSheet = false
    @State private var createIsFolder = true
    @State private var createName = ""
    @State private var createExt = "txt"
    @State private var fileInfoTarget: AfcEntry?
    @State private var fileInfoDetail: String?
    @State private var toast: String?
    // v0.3.217：选择模式 + 查看/编辑 + 导入
    @State private var selectionMode = false
    @State private var selectedPaths = Set<String>()
    // v0.3.219：文件搜索（过滤当前目录）
    @State private var searchText: String = ""
    @State private var editingEntry: AfcEntry?
    /// v0.3.219：分享临时文件 URL（下载到 tmp 后弹 ShareSheet）。URL 不符合 Identifiable，
    /// 用 wrapper 让 sheet(item:) 可用。
    @State private var shareItems: ShareItems?
    @State private var showImportPicker = false

    struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }

    var body: some View {
        content
        .overlay(alignment: .bottom) { toastOverlay }
        .navigationTitle(scope == .documents ? appName : "\(appName) · \(scope.rawValue)")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索当前目录")
        .toolbar {
            // v0.3.223：对齐空间回收板块——独立 ToolbarItem + HStack，
            // 禁用 ToolbarItemGroup 多按钮玻璃胶囊组（用户永久雷点：割裂/遮挡视线）
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if selectionMode {
                        Button(selectedPaths.count == entries.count ? "全不选" : "全选") {
                            if selectedPaths.count == entries.count { selectedPaths.removeAll() }
                            else { selectedPaths = Set(entries.map { $0.path }) }
                        }
                        Button("完成") { exitSelection() }
                    } else {
                        if currentPath != scope.path { Button("上级") { navigateUp() } }
                        Button { importFilePicker() } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入文件")
                        Button { showCreateSheet = true } label: { Image(systemName: "plus.circle") }.accessibilityLabel("新建")
                        Button("选择") { enterSelection() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .sheet(item: $shareItems) { item in ShareSheet(items: item.urls) }
        .sheet(item: $editingEntry) { entry in editorView(entry) }
        .task { await connectForScope() }
        .onDisappear { closeAll() }
        // v0.3.221：新建（文件夹 / 文件）sheet——alert TextField 在部分 iOS 版本取值失效
        .sheet(isPresented: $showCreateSheet) { createSheet }
        .alert("重命名", isPresented: renameAlertBinding) {
            TextField("新名称", text: $renameText)
            Button("确定") { Task { await doRename() } }
            Button("取消", role: .cancel) {}
        } message: { Text(renameTarget?.name ?? "") }
        .confirmationDialog("删除 \(deleteTarget?.name ?? "")？", isPresented: deleteAlertBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await doDelete() } }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作不可恢复") }
        .alert("文件信息", isPresented: fileInfoAlertBinding) {
            Button("好", role: .cancel) {}
        } message: { Text(fileInfoDetail ?? "") }
    }

    // MARK: body 拆分属性（v0.3.219c：规避 type-check 超时）

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            Text(toast)
                .font(.caption)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Capsule().fill(Color(.systemBackground)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(.bottom, 12)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if selectionMode {
            HStack(spacing: 18) {
                Text("已选 \(selectedPaths.count)").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                // v0.3.223：批量分享已删（用户评估不行）；仅保留导出+删除
                Button { exportSelected() } label: { Label("导出", systemImage: "tray.and.arrow.down") }
                    .disabled(selectedPaths.isEmpty)
                Button(role: .destructive) { deleteSelected() } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selectedPaths.isEmpty)
            }
            .font(.footnote)
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
        }
    }

    private func editorView(_ entry: AfcEntry) -> some View {
        AfcTextEditorView(
            load: { try FileSharingService.downloadFile(afc: clientFor(entry), path: entry.path) },
            save: { try FileSharingService.uploadFile(afc: clientFor(entry), data: $0, to: entry.path) },
            fileName: entry.name,
            onDone: { editingEntry = nil }
        )
    }

    private func importFilePicker() {
        SharedDocumentPicker.present(allowedTypes: [.item], onPicked: { urls in importUrls(urls) }, onCancelled: {})
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

    private var filteredEntries: [AfcEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter { $0.name.lowercased().contains(q) }
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

    // v0.3.221：三分支内容视图——scopeBar 固定顶部（不满宽），状态用卡片 banner
    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            scopeBar
            if loading {
                VStack { Spacer(); ProgressView("正在加载…"); Spacer() }
            } else if noPermission {
                stateCard(icon: "lock.fill", title: "无权限",
                          desc: "\(appName) 不允许访问 \(scope.rawValue) 目录")
                Spacer()
            } else {
                fileList
            }
        }
    }

    // MARK: 目录分段（v0.3.221：固定顶部 + 限宽，不再占满整行）
    private var scopeBar: some View {
        Picker("目录", selection: $scope) {
            ForEach(Scope.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onChange(of: scope) { _, _ in
            Task { await connectForScope() }
        }
    }

    /// v0.3.221：状态卡片 banner（IMG_4630 滚动截屏样式——白圆角卡片，不再空旷）
    private func stateCard(icon: String, title: String, desc: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44).padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var fileList: some View {
        List {
            if let err = errorText {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if filteredEntries.isEmpty {
                Section {
                    // v0.3.221：空目录用卡片 banner（不再裸 ContentUnavailableView）
                    stateCard(icon: "folder", title: "空目录",
                              desc: "\(displayCurrentPath) 下没有文件")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filteredEntries) { entry in
                        rowFor(entry)
                    }
                } header: {
                    Text("\(displayCurrentPath) · \(filteredEntries.count) 项").font(.caption.monospaced())
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: 行
    @ViewBuilder
    private func rowFor(_ entry: AfcEntry) -> some View {
        let selected = selectedPaths.contains(entry.path)
        Button {
            if selectionMode {
                toggleSelect(entry)
            } else {
                Task { await openEntry(entry) }
            }
        } label: {
            rowContent(entry, selected: selected)
                .contentShape(Rectangle())   // v0.3.221：整行可点（不只名字）
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !selectionMode { itemMenu(entry) }
        }
    }

    /// v0.3.219：打开条目——目录优先（isDirectory 可能误判，失败回退当文件），
    /// 修"文件夹点击进不去"。
    private func openEntry(_ entry: AfcEntry) async {
        guard let client = activeClient() else { return }
        if entry.isDirectory {
            await loadDir(path: entry.path)
            return
        }
        // 标为文件但仍可能实为目录（AFC st_ifmt 判定失败）→ 尝试列
        do {
            let subs = try FileSharingService.listDirectory(afc: client, path: entry.path)
            await MainActor.run {
                currentPath = entry.path
                entries = subs
                errorText = nil
            }
            return
        } catch {
            // 确为文件 → 文本可编辑直接打开，否则显示信息
        }
        if isEditableText(entry) {
            editingEntry = entry
        } else {
            fileInfoTarget = entry
            fileInfoDetail = fileDetailText(entry)
        }
    }

    @ViewBuilder
    private func rowContent(_ entry: AfcEntry, selected: Bool) -> some View {
        HStack {
            if selectionMode {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .blue : .secondary)
            }
            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(entry.name))
                .foregroundStyle(entry.isDirectory ? .blue : .gray)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline)
                if !entry.isDirectory {
                    Text(formatSize(sizes[entry.path] ?? 0))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !selectionMode && !entry.isDirectory && isEditableText(entry) {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.blue.opacity(0.7))
            }
        }
    }

    private func toggleSelect(_ entry: AfcEntry) {
        if selectedPaths.contains(entry.path) {
            selectedPaths.remove(entry.path)
        } else {
            selectedPaths.insert(entry.path)
        }
    }

    @ViewBuilder
    private func itemMenu(_ entry: AfcEntry) -> some View {
        Button("分享") {
            Task { await shareEntry(entry) }
        }
        // v0.3.223：任意文件均可强制以文本编辑（保存按 UTF-8 写回）
        if !entry.isDirectory {
            Button("以文本进行编辑") {
                editingEntry = entry
            }
        }
        Button("重命名") {
            renameTarget = entry
            renameText = entry.name
        }
        Button("删除", role: .destructive) {
            deleteTarget = entry
        }
        if !entry.isDirectory {
            Button("文件信息") {
                fileInfoDetail = fileDetailText(entry)
            }
        }
    }

    // MARK: 操作
    // v0.3.221：新建 sheet（文件夹 / 文件.txt 可改后缀）
    private var createSheet: some View {
        NavigationStack {
            Form {
                Section("新建类型") {
                    Picker("类型", selection: $createIsFolder) {
                        Text("文件夹").tag(true)
                        Text("文件").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section(createIsFolder ? "文件夹名称" : "文件名称") {
                    TextField(createIsFolder ? "新建文件夹" : "新建文件", text: $createName)
                        .autocorrectionDisabled()
                    if !createIsFolder {
                        TextField("扩展名（默认 txt）", text: $createExt)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                if !createIsFolder {
                    Section {
                        Text("将创建：\(previewCreateName)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("新建")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCreateSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task { await createItem() }
                    }
                    .disabled(trimmedCreateName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var trimmedCreateName: String {
        createName.trimmingCharacters(in: .whitespaces)
    }

    private var previewCreateName: String {
        let base = trimmedCreateName.isEmpty ? "新建文件" : trimmedCreateName
        let ext = createExt.trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func createItem() async {
        let name = trimmedCreateName
        guard !name.isEmpty, let client = activeClient() else { return }
        let finalName: String
        if createIsFolder {
            finalName = name
        } else {
            let ext = createExt.trimmingCharacters(in: .whitespaces)
            finalName = ext.isEmpty ? name : "\(name).\(ext)"
        }
        showCreateSheet = false
        let path = currentPath.hasSuffix("/") ? currentPath + finalName : currentPath + "/" + finalName
        do {
            if createIsFolder {
                try FileSharingService.makeDirectory(afc: client, path: path)
            } else {
                try FileSharingService.uploadFile(afc: client, data: Data(), to: path)
            }
            createName = ""
            createExt = "txt"
            showToast("已创建 \(finalName)")
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

    /// v0.3.219：分享（文件下载到 tmp；文件夹递归下载成目录 → ShareSheet 分享）
    private func shareEntry(_ entry: AfcEntry) async {
        guard let client = activeClient() else { return }
        showToast("准备分享…")
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let tmp = FileManager.default.temporaryDirectory
                let safeName = (entry.name as NSString).lastPathComponent
                let dest = tmp.appendingPathComponent("share-\(UUID().uuidString.prefix(6))-\(safeName)")
                try Self.downloadEntry(client: client, entry: entry, to: dest)
                return dest
            }.value
            await MainActor.run { shareItems = ShareItems(urls: [url]) }
        } catch {
            showToast(error.localizedDescription)
        }
    }
    /// v0.3.221：下载单个条目（文件直接下；文件夹建目录递归）到指定目标路径
    private static func downloadEntry(client: OpaquePointer, entry: AfcEntry, to dest: URL) throws {
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try recursiveDownload(client: client, srcDir: entry.path, toDir: dest)
        } else {
            let data = try FileSharingService.downloadFile(afc: client, path: entry.path)
            try data.write(to: dest)
        }
    }

    /// v0.3.221：批量导出 → EscapeSpace Documents/文件导出浏览/
    private func exportSelected() {
        guard let client = activeClient() else { return }
        let picked = entries.filter { selectedPaths.contains($0.path) }
        guard !picked.isEmpty else { return }
        showToast("正在导出…")
        Task {
            do {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destDir = docs.appendingPathComponent("文件导出浏览", isDirectory: true)
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                let result = try await Task.detached(priority: .userInitiated) {
                    var ok = 0, failed = 0
                    for entry in picked {
                        do {
                            let dest = destDir.appendingPathComponent(entry.name)
                            try Self.downloadEntry(client: client, entry: entry, to: dest)
                            ok += 1
                        } catch { failed += 1 }
                    }
                    return (ok, failed)
                }.value
                await MainActor.run {
                    selectedPaths.removeAll()
                    showToast("已导出 \(result.0) 项 → 文件导出浏览" + (result.1 > 0 ? "（\(result.1) 项失败）" : ""))
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    /// 递归下载目录（保结构）
    private static func recursiveDownload(client: OpaquePointer, srcDir: String, toDir: URL) throws {
        let items = try FileSharingService.listDirectory(afc: client, path: srcDir)
        for item in items {
            let target = toDir.appendingPathComponent(item.name)
            if item.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try recursiveDownload(client: client, srcDir: item.path, toDir: target)
            } else {
                let data = try FileSharingService.downloadFile(afc: client, path: item.path)
                try data.write(to: target)
            }
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

    // MARK: v0.3.217 选择模式
    private func enterSelection() {
        selectionMode = true
        selectedPaths.removeAll()
    }
    private func exitSelection() {
        selectionMode = false
        selectedPaths.removeAll()
    }
    private func deleteSelected() {
        guard let client = activeClient() else { return }
        let paths = Array(selectedPaths)
        Task {
            var failed = 0
            for p in paths {
                do {
                    try FileSharingService.remove(afc: client, path: p, recursive: true)
                } catch { failed += 1 }
            }
            selectedPaths.removeAll()
            if failed == 0 {
                showToast("已删除 \(paths.count) 项")
            } else {
                showToast("\(failed) 项删除失败")
            }
            await loadDir(path: currentPath)
        }
    }
    private func importUrls(_ urls: [URL]) {
        guard let client = activeClient(), let url = urls.first,
              let data = try? Data(contentsOf: url) else { return }
        let name = (url.lastPathComponent as NSString).lastPathComponent
        let dest = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
        showToast("正在导入…")
        Task {
            do {
                try FileSharingService.uploadFile(afc: client, data: data, to: dest)
                showToast("已导入 \(name)")
                await loadDir(path: currentPath)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }
    /// sheet(item:) 需要 Identifiable 的 entry；捕获当时 client
    private func clientFor(_ entry: AfcEntry) -> OpaquePointer {
        if let c = activeClient() { return c }
        // 极端情况（client 被关）——重新开 Documents
        let reopened = (try? FileSharingService.openAppDocuments(bundleId: bundleId))
            ?? (try? FileSharingService.openAppContainer(bundleId: bundleId))
        if let reopened { afcClient = reopened }
        return reopened!
    }
    /// 判断是否可作为文本编辑（小文件 + 文本扩展名）
    private func isEditableText(_ entry: AfcEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let textExts = ["txt", "json", "plist", "xml", "log", "md", "csv", "srt", "conf", "yaml", "yml", "ini"]
        guard textExts.contains(ext) else { return false }
        let size = sizes[entry.path] ?? 0
        return size > 0 && size < 1024 * 1024
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