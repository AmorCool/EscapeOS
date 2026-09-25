import SwiftUI

/// 顽固图标清理 —— 移植自爱思 9.0「删除顽固图标」.
///
/// 版式（对齐爱思的两步式）：**扫描** → 列出发现的残留 → **确认后删除**，
/// 另给一个「恢复图标位置」回滚入口。
///
/// 视图只做渲染与状态机；判定与读写全在 `IconCleanupService`。
/// 界面只留必要信息（项目铁律 4）：不放原理解释、不放 footnote 长句。
struct IconCleanupView: View {

    private enum Phase: Equatable {
        case idle, scanning, ready, cleaning
    }

    @State private var phase: Phase = .idle
    @State private var result: IconCleanupService.ScanResult?
    @State private var selected: Set<UUID> = []
    @State private var statusText = ""
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var confirmClean = false
    @State private var confirmRestore = false
    @State private var backupDate: Date?

    private var isBusy: Bool { phase == .scanning || phase == .cleaning }

    private var selectedGhosts: [IconCleanupService.GhostIcon] {
        (result?.ghosts ?? []).filter { selected.contains($0.id) }
    }

    var body: some View {
        List {
            scanSection
            if let result, !result.ghosts.isEmpty { ghostSection(result) }
            restoreSection
        }
        .navigationTitle("顽固图标清理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { backupDate = IconCleanupService.backupDate }
        .alert("删除选中的图标？", isPresented: $confirmClean) {
            Button("删除", role: .destructive) { clean() }
            Button("取消", role: .cancel) {}
        }
        .alert("恢复图标位置？", isPresented: $confirmRestore) {
            Button("恢复", role: .destructive) { restore() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 扫描

    private var scanSection: some View {
        Section {
            Button {
                scan()
            } label: {
                HStack {
                    Text("扫描设备图标")
                    Spacer()
                    if phase == .scanning { ProgressView() }
                }
            }
            .disabled(isBusy)

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let resultText {
                Text(resultText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 结果

    private func ghostSection(_ result: IconCleanupService.ScanResult) -> some View {
        Section {
            ForEach(result.ghosts) { ghost in
                Button {
                    toggle(ghost.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected.contains(ghost.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(ghost.id) ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ghost.displayName.isEmpty ? "无名称" : ghost.displayName)
                                .foregroundStyle(.primary)
                            Text(ghost.bundleID.isEmpty ? ghost.kind.label : ghost.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ghost.location)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("找到 \(result.ghosts.count) 个")
        } footer: {
            Text("已选 \(selected.count) 个")
        }

        Section {
            Button(role: .destructive) {
                confirmClean = true
            } label: {
                HStack {
                    Text("删除选中的图标")
                    Spacer()
                    if phase == .cleaning { ProgressView() }
                }
            }
            .disabled(selected.isEmpty || isBusy)
        }
    }

    // MARK: - 恢复

    private var restoreSection: some View {
        Section {
            Button {
                confirmRestore = true
            } label: {
                Text("恢复图标位置")
            }
            .disabled(!IconCleanupService.hasBackup || isBusy)

            if let backupDate {
                Text("备份时间 " + Self.formatter.string(from: backupDate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    // MARK: - 动作

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func scan() {
        phase = .scanning
        statusText = "正在读取桌面布局"
        errorText = nil
        resultText = nil

        Task {
            do {
                // 两条隧道是**串行**的（先拿已安装清单，再读桌面布局），
                // 不并发建隧道 —— 遵守 RSD 隧道并发铁律.
                let installed = try await Task.detached(priority: .userInitiated) {
                    try AppDiscovery().fetchInstalledApps().map(\.bundleIdentifier)
                }.value

                let scanned = try await Task.detached(priority: .userInitiated) {
                    try IconCleanupService.scan(installedBundleIDs: Set(installed))
                }.value

                await MainActor.run {
                    result = scanned
                    // 默认只勾「应用已不在设备上」那一类 —— 判据最硬，不会误删
                    selected = Set(scanned.ghosts.filter { $0.kind == .missingApp }.map(\.id))
                    phase = .ready
                    statusText = scanned.ghosts.isEmpty
                        ? "本机没有发现顽固图标"
                        : "布局里共 \(scanned.iconCount) 个图标位，已装 \(scanned.installedCount) 个应用"
                }
            } catch {
                await MainActor.run {
                    phase = .idle
                    statusText = ""
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func clean() {
        guard let result else { return }
        let targets = selectedGhosts
        guard !targets.isEmpty else { return }
        phase = .cleaning
        errorText = nil
        resultText = nil

        Task {
            do {
                let removed = try await Task.detached(priority: .userInitiated) {
                    try IconCleanupService.clean(result, removing: targets)
                }.value
                await MainActor.run {
                    phase = .idle
                    self.result = nil
                    selected = []
                    statusText = ""
                    resultText = "已删除 \(removed) 个图标"
                    backupDate = IconCleanupService.backupDate
                }
            } catch {
                await MainActor.run {
                    phase = .ready
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func restore() {
        phase = .cleaning
        errorText = nil
        resultText = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try IconCleanupService.restore()
                }.value
                await MainActor.run {
                    phase = .idle
                    resultText = "已按备份恢复图标位置"
                }
            } catch {
                await MainActor.run {
                    phase = .idle
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
