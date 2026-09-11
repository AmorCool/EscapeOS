import SwiftUI

/// v0.3.305：IPA 下载管理 —— 管理已下载的安装包并直接安装.
///
/// 列表来自 `Documents/AppStoreDownloads`（免登录下载 / App Store 下载都落在这里），
/// 与磁盘实时对齐：手动放进该目录的 IPA 也会出现在列表里。
///
/// 安装复用既有 RSD 隧道能力（`AppStoreInstallService.installLocalIPA`）：
/// 加密包走 `PackageType: Customer` + 包内 `SC_Info/*.sinf`，明文包走常规安装。
struct IPADownloadManagerView: View {

    @State private var items: [IPADownloadItem] = []
    @State private var selection = Set<String>()
    @ObservedObject private var center = IPADownloadCenter.shared
    @Environment(\.editMode) private var editMode
    private var isEditing: Bool { editMode?.wrappedValue == .active }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        // 只有进入「编辑」才允许勾选（否则点一下就会被选中）
        List(selection: Binding(get: { isEditing ? selection : [] },
                                set: { if isEditing { selection = $0 } })) {
            activeSection
            summarySection
            contentSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .toastHost()
        .task { reload() }
    }

    // MARK: - 下载中（暂停 / 继续 / 删除）

    @ViewBuilder
    private var activeSection: some View {
        if !center.activeJobs.isEmpty {
            Section {
                ForEach(center.activeJobs) { job in
                    activeRow(job)
                }
            } header: {
                HStack {
                    Text("下载中")
                    Spacer(minLength: 0)
                    Text("\(center.activeJobs.count) 个任务")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func activeRow(_ job: IPADownloadCenter.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(job.name).font(.subheadline).lineLimit(1)
                Spacer(minLength: 0)
                Text(job.phase == .paused ? "已暂停" : job.stageText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(Int(job.overall * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, job.overall)))
            HStack(spacing: 14) {
                Button {
                    if job.phase == .paused {
                        center.resume(job.id)
                    } else {
                        center.pause(job.id)
                    }
                } label: {
                    Label(job.phase == .paused ? "继续" : "暂停",
                          systemImage: job.phase == .paused ? "play.fill" : "pause.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(job.canPause ? Color.blue : Color.secondary)
                .disabled(!job.canPause)
                Button {
                    center.cancel(job.id)
                    ToastCenter.shared.show("已取消并删除该安装包")
                } label: {
                    Label("删除安装包", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - 概览

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "shippingbox.fill", tint: .blue, symbolSize: 20, frameSize: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(items.count) 个安装包")
                        .font(.subheadline.weight(.semibold))
                    Text("共占用 \(IPADownloadLibrary.sizeText(items.reduce(0) { $0 + max(0, $1.sizeBytes) }))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !selection.isEmpty {
                    Button("删除(\(selection.count))") {
                        IPADownloadLibrary.shared.remove(fileNames: selection)
                        selection.removeAll()
                        reload()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("包存在 Documents/AppStoreDownloads，放进该目录的 IPA 会自动出现在这里")
                .font(.caption2)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var contentSection: some View {
        if items.isEmpty {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("还没有下载过安装包")
                        .font(.subheadline.weight(.medium))
                    Text("在「免登录下载」里点安装，包会先下载到这里，再自动安装。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        } else {
            Section("已下载") {
                ForEach(items) { item in
                    row(item)
                }
                .onDelete { offsets in
                    let names = Set(offsets.map { items[$0].fileName })
                    IPADownloadLibrary.shared.remove(fileNames: names)
                    reload()
                }
            }
        }
    }

    private func row(_ item: IPADownloadItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            iconView(item)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let v = item.version { chip("v\(v)", .blue) }
                    chip(item.sizeText, .green)
                    chip(item.kindText, item.isEncrypted == true ? .orange : .purple)
                }
                Text(subtitle(item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            if let job = center.activeJob(bundleId: item.bundleId, name: item.title) {
                HStack(spacing: 5) {
                    ProgressView(value: min(1, max(0, job.overall)))
                        .frame(width: 40)
                    Text(job.phase == .paused ? "已暂停" : job.stageText)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    install(item)
                } label: {
                    Text(item.lastInstalledAt == nil ? "安装" : "重装")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                IPADownloadLibrary.shared.remove(item)
                reload()
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                install(item, downgrade: true)
            } label: {
                Label("降级安装", systemImage: "arrow.down.circle")
            }
            .tint(.orange)
        }
    }

    @ViewBuilder
    private func iconView(_ item: IPADownloadItem) -> some View {
        if let s = item.iconURL, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: placeholderIcon
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "app.dashed")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 48, height: 48)
            .background(Color(.tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func subtitle(_ item: IPADownloadItem) -> String {
        var parts: [String] = []
        if let b = item.bundleId, !b.isEmpty { parts.append(b) }
        parts.append(item.source)
        parts.append(Self.dateFormatter.string(from: item.downloadedAt))
        if let t = item.lastInstalledAt {
            parts.append("已安装 \(Self.dateFormatter.string(from: t))")
        }
        return parts.joined(separator: " · ")
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - 数据与安装

    private func reload() {
        items = IPADownloadLibrary.shared.items()
    }

    /// 安装/重装/降级安装 —— 统一交给下载中心（进度统一展示、可取消）
    private func install(_ item: IPADownloadItem, downgrade: Bool = false) {
        let filePath = IPADownloadLibrary.shared.path(for: item)
        guard FileManager.default.fileExists(atPath: filePath) else {
            ToastCenter.shared.show("文件不存在：\(item.fileName)")
            reload()
            return
        }
        _ = IPADownloadCenter.shared.installLocal(fileName: item.fileName,
                                                 displayName: item.title,
                                                 bundleId: item.bundleId,
                                                 version: item.version,
                                                 iconURL: item.iconURL)
        ToastCenter.shared.show(downgrade ? "正在降级安装…" : "正在安装…")
    }
}
