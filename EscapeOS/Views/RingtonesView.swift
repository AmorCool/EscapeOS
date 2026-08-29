import SwiftUI
import UniformTypeIdentifiers

/// 铃声管理：经 RSD 隧道（AFC）访问设备铃声目录，
/// 支持用户铃声的导入 / 导出 / 删除，以及系统提示音的提取 / 导出 / 刷新。
struct RingtonesView: View {
    @State private var userRingtones: [RingtonesService.Entry] = []
    @State private var systemSounds: [RingtonesService.Entry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var showImporter = false
    @State private var toast: String?
    @State private var confirmDelete: RingtonesService.Entry?
    @State private var shareItem: ShareURL?

    private let service = RingtonesService.shared

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                    Button("重试") { reload() }
                }
            }

            Section {
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在连接 AFC 服务…")
                            .foregroundColor(.secondary)
                    }
                } else if userRingtones.isEmpty {
                    Text("没有用户铃声")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(userRingtones) { entry in
                        row(entry)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    confirmDelete = entry
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("用户铃声（/var/mobile/Library/Ringtones）")
            } footer: {
                Text("导入 .m4r / .caf 铃声文件；点击条目可导出；滑动删除。删除后系统铃声列表需重启后刷新。")
            }

            Section {
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在加载…")
                            .foregroundColor(.secondary)
                    }
                } else if systemSounds.isEmpty {
                    Text("没有可提取的提示音")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(systemSounds) { entry in
                        row(entry)
                    }
                }
            } header: {
                Text("系统提示音（/System/Library/Audio/UISounds）")
            } footer: {
                Text("只读目录。点击条目提取（下载）到 App 的 Ringtones 目录，文件 App 可见。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("铃声管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(busy)
                .accessibilityLabel("导入铃声")

                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(busy)
                .accessibilityLabel("刷新")
            }
        }
        .documentPicker(isPresented: $showImporter, allowedTypes: [
            UTType(filenameExtension: "m4r") ?? .audio,
            UTType(filenameExtension: "caf") ?? .audio,
            .audio
        ]) { urls in
            guard let url = urls.first else { return }
            importRingtone(url: url)
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
        .sheet(item: $shareItem) { url in
            ActivityView(items: [url])
        }
        .overlay {
            if busy {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在处理…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)
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
            if userRingtones.isEmpty && systemSounds.isEmpty && errorMessage == nil {
                reload()
            }
        }
    }

    private func row(_ entry: RingtonesService.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundColor(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "square.and.arrow.up")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !busy else { return }
            export(entry)
        }
    }

    // MARK: - 操作

    private func reload() {
        loading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let users = try service.listUserRingtones()
                let sounds = try service.listSystemSounds()
                DispatchQueue.main.async {
                    userRingtones = users
                    systemSounds = sounds
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

    private func importRingtone(url: URL) {
        busy = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let remote = try service.importRingtone(localURL: url)
                DispatchQueue.main.async {
                    busy = false
                    toast = "已导入 \(url.lastPathComponent)"
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    errorMessage = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 导出 / 提取：下载到本地后弹系统分享面板。
    /// 用户铃声走 AFC 隧道路径，系统提示音走 bad_query 路径（已授权），
    /// 按 path 前缀区分。
    private func export(_ entry: RingtonesService.Entry) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let local: String
                if entry.path.hasPrefix(RingtonesService.systemSoundsRoot) {
                    local = try service.downloadSystemSound(path: entry.path)
                } else {
                    local = try service.download(path: entry.path)
                }
                DispatchQueue.main.async {
                    busy = false
                    shareItem = ShareURL(url: URL(fileURLWithPath: local))
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    toast = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func doDelete() {
        guard let target = confirmDelete else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.deleteRingtone(path: target.path)
                DispatchQueue.main.async {
                    busy = false
                    confirmDelete = nil
                    toast = "已删除 \(target.name)"
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    toast = "删除失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

/// UIActivityViewController 的 SwiftUI 包装（分享面板）。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// sheet(item:) 用的小包装（避免给 URL 全局加 Identifiable 扩展）。
struct ShareURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
