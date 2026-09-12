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
    /// bundleId → 图标 URL。历史记录里没持久化 `iconURL`（真机 `ipa_downloads.json` 实测没有该字段），
    /// 进入页面时按 bundleId 查回来补上；查不到就退回字母块。
    @State private var icons: [String: String] = [:]
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
        .task {
            reload()
            await loadIcons()
        }
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

            // 三行信息：标题 / 版本 + 体积 + 包类型 / 来源与时间。
            // 版本、体积两个胶囊固定单行（`.fixedSize()`），其余文字一律「换行、不截断」：
            // 用户明确要求「可以换行显示但不能显示不全」。
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let v = item.version { chip("v\(v)", .blue) }
                    chip(item.sizeText, .green)
                    Text(item.kindText)
                        .font(.caption2)
                        .foregroundStyle(kindTint(item))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(subtitle(item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let job = center.activeJob(bundleId: item.bundleId, name: item.title) {
                HStack(spacing: 6) {
                    ProgressView(value: min(1, max(0, job.overall)))
                        .frame(width: 44)
                    Text(job.phase == .paused ? "已暂停" : job.stageText)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .fixedSize()
            } else {
                Button {
                    install(item)
                } label: {
                    Text(item.lastInstalledAt == nil ? "安装" : "重装")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(minWidth: 40)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.14), in: Capsule())
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .fixedSize()
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
        // 优先用记录里持久化的 iconURL，其次用按 bundleId 查回来的 icons 表。
        if let s = item.iconURL ?? icons[item.bundleId ?? ""], let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: monogram(item)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            monogram(item)
        }
    }

    /// 没有图标时的首字母方块（参考 `PurchaseHistoryView.monogram`）：
    /// 虚框看着像「加载失败」，字母块看着是有意设计。
    private func monogram(_ item: IPADownloadItem) -> some View {
        let source = item.title.isEmpty ? (item.bundleId ?? "") : item.title
        let letter = String(source.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.blue.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
        }
        .frame(width: 48, height: 48)
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
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }

    /// 包类型只在「有风险」时着色：缺 sinf 的加密包装不上，必须显眼。
    private func kindTint(_ item: IPADownloadItem) -> Color {
        item.isEncrypted == true && item.hasSINF != true ? .orange : .secondary
    }

    // MARK: - 数据与安装

    private func reload() {
        items = IPADownloadLibrary.shared.items()
    }

    /// 补齐列表图标：历史记录没存 `iconURL`，按 bundleId 逐个查 App Store。
    /// 整体串行、同一 bundleId 只查一次（Gmail 有两条记录）、失败静默跳过 ——
    /// 图标只是锦上添花，不能让缺失影响列表渲染。
    @MainActor
    private func loadIcons() async {
        var queried = Set<String>()
        for item in items {
            guard item.iconURL == nil else { continue }
            guard let bid = item.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty else { continue }
            guard icons[bid] == nil, queried.insert(bid).inserted else { continue }
            if let hit = try? await AppStoreService.lookup(bundleId: bid),
               let icon = hit.iconSmallURL ?? hit.iconURL {
                icons[bid] = icon
            }
        }
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
