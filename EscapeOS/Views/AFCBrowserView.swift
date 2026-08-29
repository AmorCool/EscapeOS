import SwiftUI
import UniformTypeIdentifiers

/// AFC 管理：通过「配对文件 + LocalDevVPN」隧道连接本机 AFC 服务，
/// 浏览 /var/mobile/media（AFC 根目录）下的文件：
/// 浏览、下载到本机、上传、新建目录、重命名、删除。
struct AFCBrowserView: View {
    /// AFC 服务端路径栈（"/" = AFC 根 = /var/mobile/media）。
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
    @State private var toast: String?

    private let service = AFCService.shared

    private var currentPath: String { pathStack.last ?? "/" }

    /// 下载目录（EscapeSpace Documents，文件 App 可见）。
    private var downloadDir: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AFCDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
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
                    Text("AFC 根目录对应设备的 /var/mobile/media（照片、下载、录音等）。")
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
            Text("删除后无法恢复。")
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
        if currentPath == "/" { return "路径：/var/mobile/media" }
        return "路径：/var/mobile/media" + currentPath
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

    private func download(_ entry: AFCService.Entry) {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try service.readFile(entry.path)
                let target = URL(fileURLWithPath: downloadDir).appendingPathComponent(entry.name)
                try data.write(to: target)
                DispatchQueue.main.async {
                    toast = "已下载到 App 的 AFCDownloads 目录（文件 App 可见）"
                    loading = false
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
