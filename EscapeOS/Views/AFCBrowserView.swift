import SwiftUI
import UniformTypeIdentifiers

/// AFC 管理：通过「配对文件 + LocalDevVPN」隧道连接本机 AFC 服务
/// （com.apple.afc.shim.remote，**根 = /var/mobile/media**）.
/// 浏览媒体目录（DCIM / Downloads / Recordings 等）：
/// 下载 / 导出（分享）、上传、新建目录、移动、重命名、删除.
struct AFCBrowserView: View {
    /// AFC 服务端路径栈（"/" = AFC 根 = /var/mobile/media）.
    @State private var pathStack: [String] = ["/"]
    @State private var entries: [AFCService.Entry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: AFCService.Entry?
    @State private var renameText = ""
    @State private var confirmDelete: AFCService.Entry?
    @State private var activeSheet: SheetItem?
    @State private var toast: String?

    /// 单一 sheet 入口（分享 / 移动），避免多个 .sheet 修饰符互相覆盖.
    private enum SheetItem: Identifiable {
        case share(ShareURL)
        case move(AFCService.Entry)

        var id: String {
            switch self {
            case .share(let url): return "share:\(url.id)"
            case .move(let entry): return "move:\(entry.path)"
            }
        }
    }

    private let service = AFCService.shared

    private var currentPath: String { pathStack.last ?? "/" }

    /// 下载目录（EscapeSpace Documents，文件 App 可见）.
    private var downloadDir: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AFCDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// 上一级路径（用于"移动"目标选择）.
    private var parentPath: String? {
        guard pathStack.count > 1 else { return nil }
        return pathStack[pathStack.count - 2]
    }

    var body: some View {
        List {
            Section {
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在连接 AFC 服务…")
                            .foregroundColor(.secondary)
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                    Button("重试") { reload() }
                } else if entries.isEmpty {
                    Text("目录为空")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            } header: {
                Text(pathText)
            } footer: {
                if !loading && errorMessage == nil {
                    Text("AFC 根目录 = 设备的 /var/mobile/media（照片、下载、录音等）.支持下载 / 导出（分享）、移动、删除.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AFC 管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if pathStack.count > 1 {
                        pathStack.removeLast()
                        reload()
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(pathStack.count <= 1)
                .accessibilityLabel("返回上级")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("新建目录")

                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("上传文件")
            }
        }
        .documentPicker(isPresented: $showImporter, allowedTypes: [.item]) { urls in
            guard let url = urls.first else { return }
            upload(url: url)
        }
        .alert("新建目录", isPresented: $showNewFolder) {
            TextField("目录名", text: $newFolderName)
            Button("创建") { createFolder() }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("新名称", text: $renameText)
            Button("确定") { doRename() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除 \(confirmDelete?.name ?? "")？",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { doDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复.")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let item):
                ActivityView(items: [item.url])
            case .move(let source):
                moveSheet(source: source)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
        .onAppear {
            if entries.isEmpty && errorMessage == nil { reload() }
        }
    }

    private var pathText: String {
        "路径：\(currentPath)"
    }

    // MARK: - 移动目标选择

    private func moveSheet(source: AFCService.Entry) -> some View {
        NavigationView {
            List {
                Section {
                    if let parentPath {
                        Button {
                            performMove(source: source, to: parentPath)
                        } label: {
                            Label("上一级（\(parentPath)）", systemImage: "arrow.up")
                        }
                    }
                    ForEach(entries.filter(\.isDirectory)) { dir in
                        Button {
                            performMove(source: source, to: dir.path)
                        } label: {
                            Label(dir.name, systemImage: "folder.fill")
                        }
                    }
                } header: {
                    Text("目标目录（当前：\(currentPath)）")
                }
                if entries.filter(\.isDirectory).isEmpty && parentPath == nil {
                    Text("没有可移动的目标目录")
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("移动 \(source.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func performMove(source: AFCService.Entry, to targetDir: String) {
        let target = (targetDir == "/" ? "" : targetDir) + "/" + source.name
        loading = true
        activeSheet = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.renamePath(source.path, to: target)
                DispatchQueue.main.async {
                    toast = "已移动到 \(target)"
                    loading = false
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "移动失败：\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ entry: AFCService.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundColor(entry.isDirectory ? .blue : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                pathStack.append(entry.path)
                reload()
            } else {
                download(entry)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDelete = entry
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                renameTarget = entry
                renameText = entry.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                activeSheet = .move(entry)
            } label: {
                Label("移动", systemImage: "arrow.right.square")
            }
            .tint(.blue)
            if !entry.isDirectory {
                Button {
                    download(entry)
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .tint(.green)
            }
        }
    }

    // MARK: - 操作

    private func reload() {
        loading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try service.listDirectory(currentPath)
                DispatchQueue.main.async {
                    entries = list
                    loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    private func upload(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "读取本地文件失败：\(url.lastPathComponent)"
            return
        }
        let name = url.lastPathComponent
        let target = (currentPath == "/" ? "" : currentPath) + "/" + name
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.writeFile(data, to: target)
                DispatchQueue.main.async {
                    toast = "已上传 \(name)"
                    loading = false
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "上传失败：\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    /// 下载 + 导出（v0.2.125：下载后弹系统分享面板；旧版只存到 App 容器）.
    private func download(_ entry: AFCService.Entry) {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try service.readFile(entry.path)
                let target = URL(fileURLWithPath: downloadDir).appendingPathComponent(entry.name)
                try data.write(to: target)
                DispatchQueue.main.async {
                    loading = false
                    activeSheet = .share(ShareURL(url: target))
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "下载失败：\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let target = (currentPath == "/" ? "" : currentPath) + "/" + name
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.makeDirectory(target)
                DispatchQueue.main.async {
                    toast = "已创建 \(name)"
                    newFolderName = ""
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "创建失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func doRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let parent = (target.path as NSString).deletingLastPathComponent
        let newPath = (parent == "/" ? "" : parent) + "/" + name
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.renamePath(target.path, to: newPath)
                DispatchQueue.main.async {
                    toast = "已重命名"
                    renameTarget = nil
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "重命名失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func doDelete() {
        guard let target = confirmDelete else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.removePath(target.path, includingContents: target.isDirectory)
                DispatchQueue.main.async {
                    toast = "已删除 \(target.name)"
                    confirmDelete = nil
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "删除失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
