import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Filza-style file browser for a single app container.
struct FileBrowserView: View {
    let app: InstalledApp

    @StateObject private var vm: FileBrowserViewModel
    @ObservedObject private var clipboard = FileClipboard.shared
    @State private var createKind: CreateKind?
    @State private var createName = ""
    @State private var renameItem: FileItem?
    @State private var renameName = ""
    @State private var searchText = ""
    @State private var openRequest: OpenRequest?
    @State private var propertiesItem: FileItem?
    @State private var showImporter = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var pendingDelete: [FileItem] = []
    @State private var archivePassword = ""

    init(app: InstalledApp) {
        self.app = app
        _vm = StateObject(wrappedValue: FileBrowserViewModel(app: app))
    }

    init(app: InstalledApp, initialPath: String) {
        self.app = app
        _vm = StateObject(wrappedValue: FileBrowserViewModel(app: app, initialPath: initialPath))
    }

    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selecting {
                Button(allVisibleSelected ? "全部取消选择" : "全选") {
                    if allVisibleSelected {
                        selected.removeAll()
                    } else {
                        selected.formUnion(visibleItems.map(\.path))
                    }
                }
                .disabled(visibleItems.isEmpty)
                Button("完成") { exitSelection() }
            } else {
                if !clipboard.isEmpty {
                    Button {
                        vm.paste()
                    } label: {
                        Image(systemName: clipboard.payload?.mode == .cut ? "scissors" : "doc.on.clipboard")
                    }
                    .disabled(vm.isPasting)
                    .accessibilityLabel(clipboard.pasteTitle)
                }
                Button("选择") { enterSelection() }
                Menu {
                    if !clipboard.isEmpty {
                        Button {
                            vm.paste()
                        } label: {
                            Label(clipboard.pasteTitle, systemImage: "doc.on.clipboard")
                        }
                        .disabled(vm.isPasting)
                        Button("清空剪贴板", role: .destructive) {
                            clipboard.clear()
                        }
                    }
                    Button {
                        createName = "新文件.txt"
                        createKind = .file
                    } label: {
                        Label("新建文件", systemImage: "doc.badge.plus")
                    }
                    Button {
                        createName = "新建文件夹"
                        createKind = .folder
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("从文件导入", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var busyOverlayContent: some View {
        if vm.isBusy {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.15)
                    Text(vm.busyTitle)
                        .font(.headline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(vm.busyTitle)
        }
    }

    /// Core browser content with its navigation chrome. Split out of `body`
    /// so the (large) expression is type-checked independently — the iOS 26
    /// SDK's expanded SwiftUI overload set pushes a single monolithic `body`
    /// past the compiler's type-check time budget.
    private var contentWithChrome: some View {
        Group {
            if vm.isLoading && vm.items.isEmpty {
                ProgressView("正在打开容器…")
            } else if let error = vm.errorMessage, vm.items.isEmpty {
                List {
                    Section {
                        InfoActionCard(
                            icon: "exclamationmark.triangle.fill",
                            iconTint: .orange,
                            title: "无法打开目录",
                            message: error,
                            actionTitle: "重试",
                            action: { vm.open(vm.currentPath) }
                        )
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                fileList
            }
        }
        .navigationTitle(selecting ? selectionTitle : vm.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "筛选此目录")
        .toolbar { browserToolbar }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                selectionBar
            }
        }
        .overlay { busyOverlayContent }
        .onAppear { vm.open(vm.currentPath) }
        .background(
            NavigationLink(
                destination: Group {
                    if let request = openRequest {
                        FileViewerView(app: app, item: request.item, mode: request.mode)
                    }
                },
                isActive: Binding(
                    get: { openRequest != nil },
                    set: { if !$0 { openRequest = nil } }
                )
            ) { EmptyView() }
            .hidden()
        )
    }

    var body: some View {
        contentWithChrome
            .sheet(item: $vm.sharePayload) { payload in
                ActivityShareView(url: payload.url)
            }
            .alert(item: $vm.exportError) { err in
                Alert(title: Text("无法分享文件"), message: Text(err.message), dismissButton: .default(Text("好")))
            }
            .alert(item: $vm.operationError) { err in
                Alert(title: Text("文件操作失败"), message: Text(err.message), dismissButton: .default(Text("好")))
            }
            .alert("压缩包密码", isPresented: Binding(
                get: { vm.unzipPasswordItem != nil },
                set: { if !$0 { vm.clearUnzipPasswordPrompt() } }
            )) {
                SecureField("密码", text: $archivePassword)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                Button("取消", role: .cancel) {
                    archivePassword = ""
                    vm.clearUnzipPasswordPrompt()
                }
                Button("解压") {
                    if let item = vm.unzipPasswordItem {
                        vm.unzip(item: item, password: archivePassword)
                    }
                    archivePassword = ""
                }
            } message: {
                Text(vm.unzipPasswordMessage)
            }
            .alert("新建 \(createKind == .folder ? "文件夹" : "文件")", isPresented: Binding(
                get: { createKind != nil },
                set: { if !$0 { createKind = nil } }
            )) {
                TextField("名称", text: $createName)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                Button("取消", role: .cancel) { createKind = nil }
                Button("创建") {
                    if let kind = createKind {
                        vm.create(name: createName, kind: kind)
                    }
                    createKind = nil
                }
            }
            .alert("重命名", isPresented: Binding(
                get: { renameItem != nil },
                set: { if !$0 { renameItem = nil } }
            )) {
                TextField("新名称", text: $renameName)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                Button("取消", role: .cancel) { renameItem = nil }
                Button("重命名") {
                    if let item = renameItem {
                        vm.rename(item: item, to: renameName)
                    }
                    renameItem = nil
                }
            }
            .alert(deleteTitle, isPresented: Binding(
                get: { !pendingDelete.isEmpty },
                set: { if !$0 { pendingDelete = [] } }
            )) {
                Button("取消", role: .cancel) { pendingDelete = [] }
                Button("删除", role: .destructive) {
                    vm.delete(items: pendingDelete)
                    selected.subtract(pendingDelete.map(\.path))
                    pendingDelete = []
                }
            } message: {
                Text("此操作不可撤销。若文件可能被占用，请先关闭目标应用。")
            }
            .sheet(item: $propertiesItem) { item in
                FilePropertiesView(app: app, item: item)
            }
            .documentPicker(
                isPresented: $showImporter,
                allowedTypes: [.item, .data, .content, .archive, .image, .text, .sourceCode, .propertyList],
                allowsMultipleSelection: true
            ) { urls in
                vm.importFiles(from: urls)
            }
    }

    private var visibleItems: [FileItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vm.items }
        return vm.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedItems: [FileItem] {
        visibleItems.filter { selected.contains($0.path) }
    }

    private var allVisibleSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selected.contains($0.path) }
    }

    private var selectionTitle: String {
        let n = selectedItems.count
        if n == 0 { return "选择项目" }
        return n == 1 ? "已选 1 项" : "已选 \(n) 项"
    }

    private var deleteTitle: String {
        let items = pendingDelete
        if items.count == 1 { return "删除 \(items[0].name)？" }
        if items.isEmpty { return "删除？" }
        return "删除 \(items.count) 项？"
    }

    private var fileList: some View {
        List {
            ForEach(visibleItems) { item in
                if selecting {
                    Button {
                        toggleSelection(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(item.path) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(item.path) ? .accentColor : .secondary)
                                .imageScale(.large)
                            FileRow(item: item)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selected.contains(item.path) ? Color.accentColor.opacity(0.12) : nil)
                } else if item.isDirectory {
                    NavigationLink(destination: FileBrowserView(app: app, initialPath: item.path)) {
                        FileRow(item: item)
                    }
                    .contentShape(Rectangle())
                    .contextMenu { itemMenu(for: item) }
                } else if FileContentKind.classify(name: item.name, isDirectory: false) == .archive {
                    Button {
                        vm.unzip(item: item)
                    } label: {
                        FileRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(vm.isZipping)
                    .contextMenu { itemMenu(for: item) }
                } else {
                    NavigationLink(destination: FileViewerView(app: app, item: item, mode: .auto)) {
                        FileRow(item: item)
                    }
                    .contentShape(Rectangle())
                    .contextMenu { itemMenu(for: item) }
                }
            }
            .onDelete(perform: deleteAtOffsets)
        }
        .environment(\.editMode, .constant(.inactive))
        .refreshable {
            vm.open(vm.currentPath)
        }
        .onChange(of: vm.items.map(\.path)) { paths in
            selected.formIntersection(Set(paths))
        }
    }

    private func deleteAtOffsets(_ offsets: IndexSet) {
        guard !selecting else { return }
        let snapshot = visibleItems
        requestDelete(offsets.compactMap { $0 < snapshot.count ? snapshot[$0] : nil })
    }

    /// Files delete immediately. Folders still confirm — that’s harder to undo.
    private func requestDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if items.contains(where: \.isDirectory) {
            pendingDelete = items
            return
        }
        vm.delete(items: items)
        selected.subtract(items.map(\.path))
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                selectionAction("复制", "doc.on.doc", enabled: !selectedItems.isEmpty) {
                    FileClipboard.shared.copy(selectedItems, containerPath: app.containerPath)
                }
                selectionAction("剪切", "scissors", enabled: !selectedItems.isEmpty) {
                    FileClipboard.shared.cut(selectedItems, containerPath: app.containerPath)
                }
                selectionAction("粘贴", "doc.on.clipboard", enabled: !clipboard.isEmpty && !vm.isPasting) {
                    vm.paste()
                }
                Menu {
                    Button {
                        vm.zip(items: selectedItems)
                    } label: {
                        Label(selectedItems.count == 1 ? "压缩" : "打包为 Zip", systemImage: "doc.zipper")
                    }
                    .disabled(selectedItems.isEmpty || vm.isZipping)
                    Button {
                        vm.duplicate(items: selectedItems)
                    } label: {
                        Label("复制副本", systemImage: "plus.square.on.square")
                    }
                    .disabled(selectedItems.isEmpty)
                    Button {
                        FileClipboard.copyText(
                            selectedItems.map(\.path).joined(separator: "\n"),
                            confirmation: selectedItems.count == 1 ? "已复制路径" : "已复制路径"
                        )
                    } label: {
                        Label(selectedItems.count == 1 ? "复制路径" : "复制路径", systemImage: "list.clipboard")
                    }
                    .disabled(selectedItems.isEmpty)
                    if selectedItems.count == 1, let item = selectedItems.first {
                        Button {
                            renameName = item.name
                            renameItem = item
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button {
                            propertiesItem = item
                        } label: {
                            Label("属性", systemImage: "info.circle")
                        }
                        if !item.isDirectory {
                            Button {
                                vm.export(item: item)
                            } label: {
                                Label("分享 / 保存到文件", systemImage: "square.and.arrow.up")
                            }
                            .disabled(vm.isExporting || vm.isZipping)
                        } else {
                            Button {
                                vm.export(item: item)
                            } label: {
                                Label("打包分享", systemImage: "square.and.arrow.up")
                            }
                            .disabled(vm.isExporting || vm.isZipping)
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                        Text("更多")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .disabled(selectedItems.isEmpty)
                selectionAction("删除", "trash", enabled: !selectedItems.isEmpty, destructive: true) {
                    requestDelete(selectedItems)
                }
            }
            .padding(.horizontal, 4)
        }
        .background(.bar)
    }

    private func selectionAction(
        _ title: String,
        _ systemImage: String,
        enabled: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundColor(destructive && enabled ? .red : nil)
        }
        .disabled(!enabled)
    }

    private func enterSelection(preselect item: FileItem? = nil) {
        selecting = true
        selected = Set(item.map { [$0.path] } ?? [])
    }

    private func exitSelection() {
        selecting = false
        selected.removeAll()
    }

    private func toggleSelection(_ item: FileItem) {
        if selected.contains(item.path) {
            selected.remove(item.path)
        } else {
            selected.insert(item.path)
        }
    }

    @ViewBuilder
    private func itemMenu(for item: FileItem) -> some View {
        Group {
            if !item.isDirectory {
                if FileContentKind.classify(name: item.name, isDirectory: false) == .archive {
                    Button {
                        vm.unzip(item: item)
                    } label: {
                        Label("解压", systemImage: "archivebox")
                    }
                    .disabled(vm.isZipping)
                    Button {
                        openRequest = OpenRequest(item: item, mode: .hex)
                    } label: {
                        Label("以十六进制打开", systemImage: "number")
                    }
                } else {
                    Button {
                        openRequest = OpenRequest(item: item, mode: .auto)
                    } label: {
                        Label("打开", systemImage: "eye")
                    }
                    Button {
                        openRequest = OpenRequest(item: item, mode: .preview)
                    } label: {
                        Label("预览", systemImage: "doc.viewfinder")
                    }
                    Button {
                        openRequest = OpenRequest(item: item, mode: .text)
                    } label: {
                        Label("以文本打开", systemImage: "doc.plaintext")
                    }
                    Button {
                        openRequest = OpenRequest(item: item, mode: .hex)
                    } label: {
                        Label("以十六进制打开", systemImage: "number")
                    }
                }
            }
            Button {
                vm.export(item: item)
            } label: {
                Label(
                    item.isDirectory ? "打包分享" : "分享 / 保存到文件",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(vm.isExporting || vm.isZipping)
            Button {
                vm.zip(items: [item])
            } label: {
                Label("压缩", systemImage: "doc.zipper")
            }
            .disabled(vm.isZipping)
        }
        Group {
            Button {
                enterSelection(preselect: item)
            } label: {
                Label("选择", systemImage: "checkmark.circle")
            }
            Button {
                FileClipboard.shared.copy([item], containerPath: app.containerPath)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                FileClipboard.shared.cut([item], containerPath: app.containerPath)
            } label: {
                Label("剪切", systemImage: "scissors")
            }
            Button {
                FileClipboard.copyText(item.path, confirmation: "已复制路径")
            } label: {
                Label("复制路径", systemImage: "list.clipboard")
            }
            Button {
                vm.duplicate(item: item)
            } label: {
                Label("复制副本", systemImage: "plus.square.on.square")
            }
            Button {
                propertiesItem = item
            } label: {
                Label("属性", systemImage: "info.circle")
            }
            Button {
                renameName = item.name
                renameItem = item
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                requestDelete([item])
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

enum CreateKind {
    case file
    case folder
}

private struct OpenRequest: Identifiable {
    let id = UUID()
    let item: FileItem
    let mode: FileOpenMode
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbolName)
                .foregroundColor(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body)
                HStack(spacing: 8) {
                    if !item.isDirectory {
                        Text(formatBytes(item.size))
                    }
                    if let modified = item.modified {
                        Text(Self.stamp.string(from: modified))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var kind: FileContentKind {
        FileContentKind.classify(name: item.name, isDirectory: item.isDirectory)
    }

    private var iconColor: Color {
        switch kind {
        case .directory: return .accentColor
        case .image: return .green
        case .pdf: return .red
        case .audio, .video: return .purple
        case .text, .json, .xml, .plist: return .orange
        default: return .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// View model driving the file browser.
final class FileBrowserViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentPath: String = "/"
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sharePayload: SharePayload?
    @Published var isExporting = false
    @Published var isZipping = false
    @Published var isPasting = false
    @Published var busyTitle = "处理中…"
    @Published var exportError: IdentifiedError?
    @Published var operationError: IdentifiedError?
    @Published var unzipPasswordItem: FileItem?
    @Published var unzipPasswordMessage = "该压缩包已加密，请输入密码后解压。"

    var isBusy: Bool { isZipping || isExporting || isPasting }

    let app: InstalledApp
    private let escape = SandboxEscape()
    private let files = FileService()

    init(app: InstalledApp, initialPath: String? = nil) {
        self.app = app
        if let initialPath = initialPath {
            self.currentPath = initialPath
        } else {
            self.currentPath = app.containerPath
        }
    }

    var displayTitle: String {
        let last = (currentPath as NSString).lastPathComponent
        return last.isEmpty ? app.name : last
    }

    func open(_ path: String) {
        isLoading = true
        errorMessage = nil
        currentPath = path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let listed = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try self.files.list(directory: path)
                }
                DispatchQueue.main.async {
                    self.items = listed
                    self.isLoading = false
                }
            } catch let e as SandboxEscapeError {
                DispatchQueue.main.async {
                    self.errorMessage = e.localizedDescription
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func create(name: String, kind: CreateKind) {
        guard let safe = FileNameRules.sanitize(name) else {
            operationError = IdentifiedError(message: "请输入不含斜杠的文件名。")
            return
        }
        let dest = (currentPath as NSString).appendingPathComponent(safe)
        mutate {
            if kind == .folder {
                try self.files.createDirectory(at: dest)
            } else {
                try self.files.createEmptyFile(at: dest)
            }
        }
    }

    func rename(item: FileItem, to newName: String) {
        guard let safe = FileNameRules.sanitize(newName) else {
            operationError = IdentifiedError(message: "请输入不含斜杠的文件名。")
            return
        }
        mutate {
            try self.files.renameItem(at: item.path, to: safe)
        }
    }

    func delete(item: FileItem) {
        delete(items: [item])
    }

    func delete(items: [FileItem]) {
        guard !items.isEmpty else { return }
        mutate {
            for item in items {
                try self.files.deleteItem(at: item.path)
            }
        }
    }

    func paste() {
        guard let clip = FileClipboard.shared.payload, !clip.items.isEmpty else { return }
        isPasting = true
        busyTitle = "粘贴中…"
        let destDir = currentPath
        let destContainer = app.containerPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.paste(clip, into: destDir, destContainer: destContainer)
                DispatchQueue.main.async {
                    self.isPasting = false
                    if clip.mode == .cut {
                        FileClipboard.shared.clear()
                    }
                    self.open(self.currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isPasting = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    private func paste(_ clip: FileClipboard.Payload, into destDir: String, destContainer: String) throws {
        for item in clip.items {
            if Self.wouldNest(source: item.path, inside: destDir) {
                throw FileServiceError.operationFailed("无法将文件夹粘贴到自身内部。")
            }
        }
        if clip.containerPath == destContainer {
            try escape.withHandle(for: destContainer) { _ in
                try self.transferSameContainer(clip, destDir: destDir)
            }
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapeos-clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try escape.withHandle(for: clip.containerPath) { _ in
            for item in clip.items {
                try self.files.copyItem(
                    at: item.path,
                    to: staging.appendingPathComponent(item.name).path
                )
            }
        }
        try escape.withHandle(for: destContainer) { _ in
            for item in clip.items {
                let dest = self.files.uniqueDestination(in: destDir, preferredName: item.name)
                try self.files.copyItem(
                    at: staging.appendingPathComponent(item.name).path,
                    to: dest
                )
            }
        }
        if clip.mode == .cut {
            try escape.withHandle(for: clip.containerPath) { _ in
                for item in clip.items {
                    try self.files.deleteItem(at: item.path)
                }
            }
        }
    }

    private func transferSameContainer(_ clip: FileClipboard.Payload, destDir: String) throws {
        let destNorm = (destDir as NSString).standardizingPath
        for item in clip.items {
            let parent = ((item.path as NSString).deletingLastPathComponent as NSString).standardizingPath
            if clip.mode == .cut && parent == destNorm {
                continue
            }
            let dest = files.uniqueDestination(in: destDir, preferredName: item.name)
            if clip.mode == .cut {
                try files.moveItem(at: item.path, to: dest)
            } else {
                try files.copyItem(at: item.path, to: dest)
            }
        }
    }

    private static func wouldNest(source: String, inside destDir: String) -> Bool {
        let src = (source as NSString).standardizingPath
        let dest = (destDir as NSString).standardizingPath
        return dest == src || dest.hasPrefix(src + "/")
    }

    func duplicate(item: FileItem) {
        duplicate(items: [item])
    }

    func duplicate(items: [FileItem]) {
        guard !items.isEmpty else { return }
        mutate {
            for item in items {
                let parent = (item.path as NSString).deletingLastPathComponent
                let ns = item.name as NSString
                let ext = ns.pathExtension
                let base = ns.deletingPathExtension
                let preferred = ext.isEmpty ? "\(item.name) copy" : "\(base) copy.\(ext)"
                let dest = self.files.uniqueDestination(in: parent, preferredName: preferred)
                try self.files.copyItem(at: item.path, to: dest)
            }
        }
    }

    func importFiles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        isZipping = true
        busyTitle = urls.count == 1 ? "正在导入…" : "正在导入 \(urls.count) 项…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.escape.withHandle(for: self.app.containerPath) { _ in
                    for url in urls {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        let dest = self.files.uniqueDestination(
                            in: self.currentPath,
                            preferredName: url.lastPathComponent
                        )
                        try self.files.writeFile(data: data, to: dest)
                    }
                }
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.open(self.currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func export(item: FileItem) {
        isExporting = true
        busyTitle = "准备中…"
        exportError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dest = try Self.shareStagingURL(named: Self.shareName(for: item))
                try self.escape.withHandle(for: self.app.containerPath) { _ in
                    if item.isDirectory {
                        let zip = ZipWriter()
                        try zip.begin(at: dest)
                        do {
                            try zip.addItems([item], files: self.files, skipPath: dest.path)
                            try zip.finish()
                        } catch {
                            try? zip.finish()
                            throw error
                        }
                    } else {
                        let data = try self.files.readFile(at: item.path)
                        try data.write(to: dest, options: .atomic)
                    }
                }
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.sharePayload = SharePayload(url: dest)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.exportError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func zip(items: [FileItem]) {
        guard !items.isEmpty, !isZipping else { return }
        isZipping = true
        busyTitle = items.count == 1 ? "正在压缩…" : "正在压缩 \(items.count) 项…"
        operationError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destPath: String = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    let dest = self.files.uniqueDestination(
                        in: self.currentPath,
                        preferredName: Self.zipName(for: items)
                    )
                    let zip = ZipWriter()
                    try zip.begin(at: URL(fileURLWithPath: dest))
                    do {
                        try zip.addItems(items, files: self.files, skipPath: dest)
                        try zip.finish()
                    } catch {
                        try? zip.finish()
                        try? FileManager.default.removeItem(atPath: dest)
                        throw error
                    }
                    return dest
                }
                DispatchQueue.main.async {
                    self.isZipping = false
                    let name = (destPath as NSString).lastPathComponent
                    CopyFeedback.shared.show("已创建「\(name)」")
                    self.open(self.currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func clearUnzipPasswordPrompt() {
        unzipPasswordItem = nil
        unzipPasswordMessage = "该压缩包已加密，请输入密码后解压。"
    }

    func unzip(item: FileItem, password: String? = nil) {
        guard !isZipping else { return }
        isZipping = true
        busyTitle = "正在解压…"
        operationError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destName: String = try self.escape.withHandle(for: self.app.containerPath) { _ in
                    let bytes = try self.files.readFile(at: item.path)
                    if ArchiveExtractor.archiveNeedsPassword(bytes, name: item.name),
                       password == nil || password?.isEmpty == true {
                        throw ZipReaderError.passwordRequired
                    }
                    let preferred = ArchiveExtractor.folderName(from: item.name)
                    let dest = self.files.uniqueDestination(
                        in: self.currentPath,
                        preferredName: preferred.isEmpty ? "归档" : preferred
                    )
                    do {
                        try ArchiveExtractor.extract(
                            data: bytes,
                            originalName: item.name,
                            into: dest,
                            files: self.files,
                            password: password
                        )
                    } catch {
                        try? FileManager.default.removeItem(atPath: dest)
                        throw error
                    }
                    return (dest as NSString).lastPathComponent
                }
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.clearUnzipPasswordPrompt()
                    CopyFeedback.shared.show("已解压到「\(destName)」")
                    self.open(self.currentPath)
                }
            } catch ZipReaderError.passwordRequired {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.unzipPasswordMessage = "该压缩包已加密，请输入密码后解压。"
                    self.unzipPasswordItem = item
                }
            } catch ZipReaderError.wrongPassword {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.unzipPasswordMessage = "密码错误，请重试。"
                    self.unzipPasswordItem = item
                }
            } catch {
                DispatchQueue.main.async {
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    private static func zipName(for items: [FileItem]) -> String {
        if items.count == 1 {
            let name = items[0].name
            let ns = name as NSString
            if ns.pathExtension.lowercased() == "zip" {
                return "\(ns.deletingPathExtension) 归档.zip"
            }
            return "\(name).zip"
        }
        return "归档.zip"
    }

    private static func shareName(for item: FileItem) -> String {
        if item.isDirectory {
            return "\(item.name).zip"
        }
        return item.name
    }

    /// Stage a share file in EscapeOS Documents under the original name (no `shared_` prefix).
    private static func shareStagingURL(named name: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let dest = docs.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        return dest
    }

    private func mutate(_ body: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.escape.withHandle(for: self.app.containerPath) { _ in
                    try body()
                }
                DispatchQueue.main.async {
                    self.open(self.currentPath)
                }
            } catch {
                DispatchQueue.main.async {
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct IdentifiedError: Identifiable {
    let id = UUID()
    let message: String
}

struct ActivityShareView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
