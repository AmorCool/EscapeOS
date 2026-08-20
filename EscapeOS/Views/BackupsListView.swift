import SwiftUI

/// Lists backup archives and drives restore confirmation + progress.
struct BackupsListView: View {
    @ObservedObject var appList: AppListViewModel
    @StateObject private var vm = BackupsListViewModel()

    var body: some View {
        Group {
            if vm.isLoading && vm.records.isEmpty {
                ProgressView("正在加载备份…")
            } else if let error = vm.errorMessage, vm.records.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { vm.reload() }
                        .buttonStyle(.bordered)
                }
                .padding()
            } else if vm.records.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("暂无备份")
                        .font(.headline)
                    Text("可在「应用」或「容器管理」页进入任意应用，再点击「备份数据」导出备份。归档文件保存在「文件 → 我的iPhone → EscapeOS → Backups」。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            } else {
                List {
                    ForEach(vm.records) { record in
                        BackupRow(
                            record: record,
                            icon: appList.icons[record.metadata.bundleIdentifier],
                            eligibility: vm.eligibility(for: record, apps: appList.apps)
                        ) {
                            vm.beginRestore(record: record, apps: appList.apps)
                        }
                    }
                    .onDelete { offsets in
                        vm.delete(at: offsets)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("备份")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    vm.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .onAppear {
            vm.reload()
        }
        .sheet(item: $vm.activeRestore) { session in
            RestoreView(session: session, appList: appList)
        }
        .alert(item: $vm.alertError) { error in
            Alert(title: Text("无法开始恢复"), message: Text(error.message), dismissButton: .default(Text("好")))
        }
    }
}

private struct BackupRow: View {
    let record: BackupRecord
    let icon: UIImage?
    let eligibility: RestoreEligibility
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIconView(icon: icon, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(record.displayTitle)
                            .font(.headline)
                        if record.metadata.isContainerApp {
                            Text("容器")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    Text(record.metadata.bundleIdentifier)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(record.displaySubtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let modified = record.modified {
                        Text(BackupPaths.displayStamp.string(from: modified))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            switch eligibility {
            case .ready:
                Button(action: onRestore) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                        Text("恢复到设备")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            case .appNotInstalled(_, let appName):
                Label("\(appName) 未安装", systemImage: "app.badge.checkmark.fill")
                    .font(.footnote)
                    .foregroundColor(.orange)
            case .invalidArchive(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Shared app icon rendering with placeholder while icons load.
struct AppIconView: View {
    let icon: UIImage?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let icon = icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: "app.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(size * 0.22)
    }
}

/// Confirmation + progress sheet for restoring a backup.
struct RestoreView: View {
    let session: RestoreSession
    @ObservedObject var appList: AppListViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = RestoreViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                switch vm.state {
                case .confirm:
                    confirmContent
                case .running(let current, let done, let total):
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("\(done) / \(total) 个文件")
                        Text(current)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("取消", role: .destructive) {
                            vm.cancel()
                        }
                    }
                    .padding()
                case .done(let result):
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("恢复完成")
                            .font(.headline)
                        Text("已恢复 \(result.filesRestored) 个文件到 \(result.targetApp.name)")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                        Button("完成") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.red)
                        Text("恢复失败")
                            .font(.headline)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("关闭") { dismiss() }
                    }
                    .padding()
                case .cancelled:
                    VStack(spacing: 12) {
                        Text("恢复已取消")
                            .font(.headline)
                        Button("关闭") { dismiss() }
                    }
                    .padding()
                }
                Spacer()
            }
            .navigationTitle("恢复备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if case .confirm = vm.state {
                        Button("取消") { dismiss() }
                    }
                }
            }
            .onAppear {
                vm.prepare(session: session)
            }
        }
    }

    @ViewBuilder
    private var confirmContent: some View {
        if case .ready(let app, let metadata, let warnings) = session.eligibility {
            VStack(spacing: 16) {
                AppIconView(icon: appList.icons[app.bundleIdentifier], size: 64)
                    .padding(.top, 24)

                Text("恢复到 \(app.name)？")
                    .font(.title3).bold()

                VStack(alignment: .leading, spacing: 8) {
                    detailRow("应用", app.name)
                    detailRow("Bundle ID", app.bundleIdentifier)
                    detailRow("文件数", "\(metadata.fileCount)")
                    detailRow("数据大小", formatBytes(metadata.totalBytes))
                    detailRow("备份文件", session.record.archiveFileName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                    Text("将覆盖 Documents、Library 和 tmp 中现有的同名文件。Keychain 数据不会被恢复。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                Button {
                    vm.start(session: session)
                } label: {
                    Text("恢复备份")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            }
        } else {
            Text("此备份无法恢复。")
                .foregroundColor(.secondary)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.leading)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

struct RestoreSession: Identifiable {
    let id = UUID()
    let record: BackupRecord
    let eligibility: RestoreEligibility
}

struct IdentifiedAlert: Identifiable {
    let id = UUID()
    let message: String
}

final class BackupsListViewModel: ObservableObject {
    @Published var records: [BackupRecord] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeRestore: RestoreSession?
    @Published var alertError: IdentifiedAlert?

    private let catalog = BackupCatalog()
    private let restoreService = RestoreService()

    func reload() {
        isLoading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let found = try self.catalog.loadRecords()
                DispatchQueue.main.async {
                    self.records = found
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

    func eligibility(for record: BackupRecord, apps: [InstalledApp]) -> RestoreEligibility {
        restoreService.eligibility(for: record, installedApps: apps)
    }

    func beginRestore(record: BackupRecord, apps: [InstalledApp]) {
        let eligibility = restoreService.eligibility(for: record, installedApps: apps)
        switch eligibility {
        case .ready:
            activeRestore = RestoreSession(record: record, eligibility: eligibility)
        case .appNotInstalled(_, let appName):
            alertError = IdentifiedAlert(message: "\(appName) 未安装。请先安装该应用后再恢复此备份。")
        case .invalidArchive(let message):
            alertError = IdentifiedAlert(message: message)
        }
    }

    func delete(at offsets: IndexSet) {
        let targets = offsets.map { records[$0] }
        for record in targets {
            try? catalog.delete(record: record)
        }
        records.remove(atOffsets: offsets)
    }
}

final class RestoreViewModel: ObservableObject {
    enum State {
        case confirm
        case running(current: String, done: Int, total: Int)
        case done(RestoreResult)
        case failed(String)
        case cancelled
    }

    @Published var state: State = .confirm
    private let service = RestoreService()
    private var cancelled = false

    func prepare(session: RestoreSession) {
        cancelled = false
        state = .confirm
    }

    func start(session: RestoreSession) {
        guard case .ready(let app, _, _) = session.eligibility else { return }
        cancelled = false
        state = .running(current: "Starting…", done: 0, total: session.record.metadata.fileCount)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.service.restore(
                    record: session.record,
                    to: app,
                    progress: { done, total, current in
                        DispatchQueue.main.async {
                            self.state = .running(current: current, done: done, total: total)
                        }
                    },
                    isCancelled: { self.cancelled }
                )
                DispatchQueue.main.async {
                    self.state = .done(result)
                }
            } catch let error as BackupError {
                DispatchQueue.main.async {
                    if case .cancelled = error {
                        self.state = .cancelled
                    } else {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
    }
}
