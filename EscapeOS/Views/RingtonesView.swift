import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// 铃声在线播放器（AVAudioPlayer 包装）.
final class RingtonePlayer: NSObject, AVAudioPlayerDelegate, ObservableObject {
    @Published var playingID: String?
    private var player: AVAudioPlayer?

    /// 播放内存中的音频；同一 id 再次调用则停止.
    func play(data: Data, id: String) {
        if playingID == id { stop(); return }
        stop()
        guard !data.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.delegate = self
        p.play()
        player = p
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        playingID = nil
    }
}

/// 铃声管理：经 RSD 隧道（AFC）管理 /var/mobile/media 内的铃声文件，
/// 支持导入 / 导出 / 删除 / 重命名 / 在线播放 / 刷新.
///
/// ⚠️ 硬限制说明（页面 footer 会展示）：系统铃声库
/// /var/mobile/Library/Ringtones 在 AFC 根（= /var/mobile/media）之外，
/// 隧道不可达，因此只能管理媒体目录内的铃声文件.
struct RingtonesView: View {
    @State private var ringtones: [RingtonesService.Entry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var showImporter = false
    @State private var confirmDelete: RingtonesService.Entry?
    @State private var renameTarget: RingtonesService.Entry?
    @State private var renameText = ""
    @State private var shareItem: ShareURL?
    @StateObject private var player = RingtonePlayer()

    private let service = RingtonesService.shared

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    if PairingGate.isPairingError(errorMessage) {
                        PairingGuideCard(showsBackground: false)
                            .listRowInsets(EdgeInsets())
                    } else {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                        Button("重试") { reload() }
                    }
                }
            }

            Section {
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在扫描铃声…")
                            .foregroundColor(.secondary)
                    }
                } else if ringtones.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("没有找到文件")
                            .foregroundColor(.secondary)
                        Text("已扫描 iTunes_Control/Ringtones、PublicStaging、Downloads 与媒体根.点右上角导入音频（自动转 .m4r）.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(ringtones) { entry in
                        row(entry)
                    }
                }
            } header: {
                Text("铃声（/var/mobile/media）")
            } footer: {
                Text("导入音频（mp3/wav/m4a，超 40 秒自动截取）→ 转 .m4r 上传至 iTunes_Control/Ringtones 并注册铃声库.导入后到「设置 → 声音 → 铃声」查看；未立即出现可重启设备.")
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
            Text("删除后无法恢复.")
        }
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("新名称", text: $renameText)
            Button("确定") { doRename() }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
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
        .toastHost()
        .onAppear {
            if ringtones.isEmpty && errorMessage == nil {
                reload()
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    private func row(_ entry: RingtonesService.Entry) -> some View {
        let isPlaying = player.playingID == entry.id
        return HStack(spacing: 12) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "music.note")
                .foregroundColor(isPlaying ? .green : .blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    Text((entry.path as NSString).deletingLastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                .font(.title3)
                .foregroundColor(isPlaying ? .red : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !busy else { return }
            play(entry)
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
                export(entry)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .tint(.green)
        }
    }

    // MARK: - 操作

    private func reload() {
        loading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try service.listUserRingtones()
                DispatchQueue.main.async {
                    ringtones = list
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
                // 同步通知失败不阻塞导入（注册表已写入，铃声已进系统铃声库），
                // 但提示用户
                let syncFailed: String? = {
                    do {
                        try service.postSyncNotification("com.apple.itunes-mobdev.syncDidFinish")
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }()
                DispatchQueue.main.async {
                    busy = false
                    if let syncFailed {
                        ToastCenter.shared.show("已导入并注册铃声 \(url.lastPathComponent)；媒体库刷新通知失败（\(syncFailed)）——若设置里未出现，重启设备即可")
                    } else {
                        ToastCenter.shared.show("已导入并注册到铃声库：\(url.lastPathComponent)（到「设置 → 声音 → 铃声」查看；未出现请重启设备）")
                    }
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

    /// 在线播放 / 停止（v0.2.130）：AFC 拉取数据到内存，AVAudioPlayer 播放.
    private func play(_ entry: RingtonesService.Entry) {
        if player.playingID == entry.id {
            player.stop()
            return
        }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try service.readData(path: entry.path)
                DispatchQueue.main.async {
                    busy = false
                    player.play(data: data, id: entry.id)
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    ToastCenter.shared.show("播放失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 导出：下载到本地后弹系统分享面板.
    private func export(_ entry: RingtonesService.Entry) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let local = try service.download(path: entry.path)
                DispatchQueue.main.async {
                    busy = false
                    shareItem = ShareURL(url: URL(fileURLWithPath: local))
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    ToastCenter.shared.show("导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func doRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try service.renameRingtone(path: target.path, to: name)
                DispatchQueue.main.async {
                    busy = false
                    renameTarget = nil
                    ToastCenter.shared.show("已重命名为 \(name)")
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    ToastCenter.shared.show("重命名失败：\(error.localizedDescription)")
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
                    ToastCenter.shared.show("已删除 \(target.name)")
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    ToastCenter.shared.show("删除失败：\(error.localizedDescription)")
                }
            }
        }
    }
}

/// UIActivityViewController 的 SwiftUI 包装（分享面板）.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// sheet(item:) 用的小包装（避免给 URL 全局加 Identifiable 扩展）.
struct ShareURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
