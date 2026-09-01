import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 延迟创建 NavigationLink destination —— 修复"闪退回上级"：
/// destination 在 list 渲染时就被 eager 创建，父级 state 刷新会重建
/// destination 导致 navigation stack 重置。包装后 destination 只在
/// 用户实际点击 push 时才创建一次，父级刷新不再影响子级。
struct NavigationLazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }
    var body: some View {
        build()
    }
}

/// Filza-style file browser for a single app container.
struct FileBrowserView: View {
    let rootPath: String
    let title: String

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

    /// 浏览某个已安装 App 的容器（原入口：App 详情 / 空间回收）。
    init(app: InstalledApp) {
        self.init(rootPath: app.containerPath, title: app.name)
    }

    init(app: InstalledApp, initialPath: String) {
        self.init(rootPath: app.containerPath, title: app.name, initialPath: initialPath)
    }

    /// 浏览任意路径（根级文件浏览器用）。
    /// - Parameters:
    ///   - rootPath: 沙盒扩展的签发锚点 —— 容器内所有读写都以它为基准申请扩展。
    ///   - title: 根层级的显示标题（子目录会用目录名）。
    ///   - initialPath: 起始目录，缺省即 `rootPath`。
    ///   - appNameIndex: bundle id → App 显示名（可选，用于容器行显示「全名 (bundle id)」）。
    init(rootPath: String, title: String, initialPath: String? = nil, appNameIndex: [String: String] = [:]) {
        self.rootPath = rootPath
        self.title = title
        _vm = StateObject(wrappedValue: FileBrowserViewModel(
            rootPath: rootPath,
            title: title,
            initialPath: initialPath,
            appNameIndex: appNameIndex
        ))
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
                        FileViewerView(rootPath: rootPath, item: request.item, mode: request.mode)
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
                FilePropertiesView(rootPath: rootPath, item: item)
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
        // 索引：目录名（UUID）+ 解析出的容器名（「全名 (bundle id)」/ group id），
        // 让用户可以直接搜 App 名 / bundle id 定位到对应容器。
        return vm.items.filter { item in
            if item.name.localizedCaseInsensitiveContains(query) { return true }
            if let resolved = vm.containerNames[item.path],
               resolved.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
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
                    NavigationLink(destination: NavigationLazyView(
                        vm.isContainerRoot
                            ? AnyView(FileBrowserView(rootPath: item.path,
                                                      title: vm.containerNames[item.path] ?? item.name,
                                                      appNameIndex: vm.appNameIndex))
                            : AnyView(FileBrowserView(rootPath: rootPath, title: title,
                                                      initialPath: item.path,
                                                      appNameIndex: vm.appNameIndex))
                    )) {
                        FileRow(item: item, subtitle: vm.containerNames[item.path])
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
                    NavigationLink(destination: NavigationLazyView(
                        FileViewerView(rootPath: rootPath, item: item, mode: .auto)
                    )) {
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
                    FileClipboard.shared.copy(selectedItems, containerPath: rootPath)
                }
                selectionAction("剪切", "scissors", enabled: !selectedItems.isEmpty) {
                    FileClipboard.shared.cut(selectedItems, containerPath: rootPath)
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
                FileClipboard.shared.copy([item], containerPath: rootPath)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                FileClipboard.shared.cut([item], containerPath: rootPath)
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

private struct OpenRequest: Identifiable {
    let id = UUID()
    let item: FileItem
    let mode: FileOpenMode
}

struct ActivityShareView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
