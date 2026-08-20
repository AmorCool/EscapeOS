import SwiftUI

/// Per-app actions: browse, backup, restore existing archives, container inventory.
struct AppDetailView: View {
    let app: InstalledApp
    @ObservedObject var viewModel: AppListViewModel

    @StateObject private var access = ContainerAccessModel()
    @StateObject private var backup = BackupViewModel()
    @StateObject private var appBackups = AppBackupsModel()
    @StateObject private var inventory = ContainerInventoryModel()
    @State private var activeRestore: RestoreSession?
    @State private var restoreAlert: IdentifiedAlert?
    @State private var confirmReset = false
    @State private var isResetting = false
    @State private var resetNotice: ReclaimNotice?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppIconView(icon: viewModel.icons[app.bundleIdentifier], size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline)
                        Text(app.bundleIdentifier).font(.caption).foregroundColor(.secondary)
                        if let version = app.version {
                            Text("版本 \(version)").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .contextMenu {
                    Button {
                        FileClipboard.copyText(app.bundleIdentifier, confirmation: "已复制 Bundle ID")
                    } label: {
                        Label("复制 Bundle ID", systemImage: "doc.on.doc")
                    }
                    Button {
                        FileClipboard.copyText(app.name, confirmation: "已复制名称")
                    } label: {
                        Label("复制名称", systemImage: "character.cursor.ibeam")
                    }
                    if !app.containerPath.isEmpty {
                        Button {
                            FileClipboard.copyText(app.containerPath, confirmation: "已复制路径")
                        } label: {
                            Label("复制容器路径", systemImage: "folder")
                        }
                    }
                }
            }

            Section {
                Button {
                    FileClipboard.copyText(app.bundleIdentifier, confirmation: "已复制 Bundle ID")
                } label: {
                    Label("复制 Bundle ID", systemImage: "doc.on.doc")
                }
            }

            Section(header: Text("访问权限")) {
                switch access.state {
                case .unknown, .checking:
                    HStack {
                        ProgressView()
                        Text("正在检查容器访问…").foregroundColor(.secondary)
                    }
                case .granted:
                    Label("容器可访问", systemImage: "checkmark.shield.fill")
                        .foregroundColor(.green)
                case .denied(let reason):
                    Label(reason, systemImage: "xmark.shield.fill")
                        .foregroundColor(.red)
                }
            }

            if access.isGranted {
                Section(header: Text("容器内容")) {
                    if inventory.isLoading && inventory.roots.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在统计文件…").foregroundColor(.secondary)
                        }
                    } else if inventory.roots.isEmpty {
                        Text("未找到 Documents、Library 或 tmp。")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(inventory.roots) { root in
                            HStack {
                                Text(root.name)
                                Spacer()
                                Text(root.summary)
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }

            Section(footer: Text("将 Documents、Library 与 tmp 备份到「文件 → 我的iPhone → EscapeOS → Backups」。不包含 Keychain。请先关闭 \(app.name) 以获得一致快照。")) {
                NavigationLink(destination: FileBrowserView(app: app)) {
                    Label("浏览文件", systemImage: "folder.fill")
                }
                .disabled(!access.isGranted)

                NavigationLink(destination: ReclaimAppView(app: app, viewModel: viewModel)) {
                    Label("回收空间", systemImage: "internaldrive")
                }
                .disabled(!access.isGranted)

                Button {
                    backup.start(app: app, isContainerApp: false) {
                        appBackups.reload(bundleIdentifier: app.bundleIdentifier)
                    }
                } label: {
                    Label("备份数据", systemImage: "externaldrive.fill.badge.plus")
                }
                .disabled(!access.isGranted || backup.isBusy)

                backupStatus
            }

            Section(footer: Text("清空该应用的 Documents、Library 与 tmp。请先关闭 \(app.name)。这些目录中的登录态与存档将丢失。Keychain 与 App Group 不受影响。")) {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("重置应用数据", systemImage: "trash.fill")
                        .foregroundColor(.red)
                }
                .disabled(!access.isGranted || isResetting)
            }

            Section(
                header: Text(appBackups.records.isEmpty ? "备份" : "备份 (\(appBackups.records.count))"),
                footer: Text("恢复操作将写入该应用当前容器。请先关闭应用。")
            ) {
                if appBackups.isLoading && appBackups.records.isEmpty {
                    HStack {
                        ProgressView()
                        Text("正在加载备份…").foregroundColor(.secondary)
                    }
                } else if appBackups.records.isEmpty {
                    Text("暂无 \(app.name) 的备份。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appBackups.records) { record in
                        AppBackupRow(record: record) {
                            beginRestore(record)
                        }
                    }
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            access.check(app: app)
            viewModel.ensureIcon(for: app.bundleIdentifier)
            appBackups.reload(bundleIdentifier: app.bundleIdentifier)
        }
        .onChange(of: access.isGranted) { granted in
            if granted {
                inventory.load(app: app)
            }
        }
        .sheet(item: $activeRestore) { session in
            RestoreView(session: session, appList: viewModel)
        }
        .alert(item: $restoreAlert) { error in
            Alert(title: Text("无法开始恢复"), message: Text(error.message), dismissButton: .default(Text("好")))
        }
        .alert("重置全部应用数据？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重置应用数据", role: .destructive) {
                resetAppData()
            }
        } message: {
            Text(resetConfirmMessage)
        }
        .alert(item: $resetNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
        .overlay {
            if isResetting {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text("重置中…")
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var resetConfirmMessage: String {
        var text = "请先关闭 \(app.name)。本次将清空 Documents、Library 与 tmp，之后需要重新登录并设置。Keychain 不会被删除。"
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            text += " 当前选中的是的是它本身——Documents 中的配对文件也将被删除。"
        }
        return text
    }

    private func resetAppData() {
        isResetting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let skipped = try ReclaimService().resetAppData(app: app)
                DispatchQueue.main.async {
                    self.isResetting = false
                    self.inventory.load(app: app)
                    var message = "Documents、Library 与 tmp 已清空。"
                    if skipped > 0 {
                        message = "已尽可能清理。跳过 \(skipped) 个无法删除的项目。"
                    }
                    self.resetNotice = ReclaimNotice(
                        title: "应用数据已重置",
                        message: message
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.isResetting = false
                    self.resetNotice = ReclaimNotice(title: "重置失败", message: error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private var backupStatus: some View {
        switch backup.state {
        case .idle:
            EmptyView()
        case .running(let files, let bytes, let current):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView()
                Text("\(files) 个文件 · \(formatBytes(bytes))")
                    .font(.subheadline)
                Text(current)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("取消", role: .destructive) {
                    backup.cancel()
                }
            }
            .padding(.vertical, 4)
        case .done(let result):
            VStack(alignment: .leading, spacing: 4) {
                Label("备份完成", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(result.fileCount) 个文件 · \(formatBytes(result.totalBytes))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("已保存到 EscapeOS → Backups")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("备份失败", systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("重试") {
                    backup.start(app: app, isContainerApp: false) {
                        appBackups.reload(bundleIdentifier: app.bundleIdentifier)
                    }
                }
            }
        }
    }

    private func beginRestore(_ record: BackupRecord) {
        let eligibility = RestoreService().eligibility(for: record, installedApps: [app])
        switch eligibility {
        case .ready:
            activeRestore = RestoreSession(record: record, eligibility: eligibility)
        case .appNotInstalled(_, let name):
            restoreAlert = IdentifiedAlert(message: "\(name) 未安装。")
        case .invalidArchive(let message):
            restoreAlert = IdentifiedAlert(message: message)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

private struct AppBackupRow: View {
    let record: BackupRecord
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.displaySubtitle)
                .font(.subheadline)
            if let modified = record.modified {
                Text(BackupPaths.displayStamp.string(from: modified))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button(action: onRestore) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                    Text("恢复")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

final class AppBackupsModel: ObservableObject {
    @Published var records: [BackupRecord] = []
    @Published var isLoading = false

    private let catalog = BackupCatalog()

    func reload(bundleIdentifier: String) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = (try? self.catalog.loadRecords(forBundleIdentifier: bundleIdentifier)) ?? []
            DispatchQueue.main.async {
                self.records = found
                self.isLoading = false
            }
        }
    }
}

struct ContainerRootStat: Identifiable {
    var id: String { name }
    let name: String
    let files: Int
    let directories: Int
    let bytes: Int64
    let available: Bool

    var summary: String {
        guard available else { return "未找到" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(files) 个文件 · \(f.string(fromByteCount: bytes))"
    }
}

final class ContainerInventoryModel: ObservableObject {
    @Published var roots: [ContainerRootStat] = []
    @Published var isLoading = false

    private let escape = SandboxEscape()
    private let files = FileService()

    func load(app: InstalledApp) {
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            var stats: [ContainerRootStat] = []
            do {
                try self.escape.withHandle(for: app.containerPath) { _ in
                    for name in BackupService.backupRoots {
                        let path = (app.containerPath as NSString).appendingPathComponent(name)
                        if !self.files.isDirectory(at: path) {
                            stats.append(ContainerRootStat(name: name, files: 0, directories: 0, bytes: 0, available: false))
                            continue
                        }
                        let counted = try self.files.countTree(at: path)
                        stats.append(ContainerRootStat(
                            name: name,
                            files: counted.files,
                            directories: counted.directories,
                            bytes: counted.bytes,
                            available: true
                        ))
                    }
                }
            } catch {
                stats = []
            }
            DispatchQueue.main.async {
                self.roots = stats
                self.isLoading = false
            }
        }
    }
}

/// Tracks whether we can currently consume a sandbox extension for the app's container.
final class ContainerAccessModel: ObservableObject {
    enum State {
        case unknown
        case checking
        case granted
        case denied(String)
    }

    @Published var state: State = .unknown
    var isGranted: Bool { if case .granted = state { return true } ; return false }

    private let escape = SandboxEscape()
    private let files = FileService()

    func check(app: InstalledApp) {
        state = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.escape.withHandle(for: app.containerPath) { _ in
                    if !self.files.isDirectory(at: app.containerPath) {
                        throw FileServiceError.notDirectory(app.containerPath)
                    }
                }
                DispatchQueue.main.async { self.state = .granted }
            } catch let e as SandboxEscapeError {
                DispatchQueue.main.async { self.state = .denied(e.localizedDescription) }
            } catch {
                DispatchQueue.main.async { self.state = .denied(error.localizedDescription) }
            }
        }
    }
}
