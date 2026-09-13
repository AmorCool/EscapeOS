import SwiftUI

/// v0.3.305：IPA 下载管理 —— 管理已下载的安装包并直接安装.
///
/// 列表来自 `Documents/AppStoreDownloads`（免登录下载 / App Store 下载都落在这里），
/// 与磁盘实时对齐：手动放进该目录的 IPA 也会出现在列表里。
///
/// 安装复用既有 RSD 隧道能力（`AppStoreInstallService.installLocalIPA`）：
/// 加密包走 `PackageType: Customer` + 包内 `SC_Info/*.sinf`，明文包走常规安装。
///
/// v0.3.378：点任意一行弹出操作面板（`IPADownloadActionsSheet`）。
struct IPADownloadManagerView: View {

    @State private var items: [IPADownloadItem] = []
    /// 正在弹操作面板的条目
    @State private var actionItem: IPADownloadItem?
    /// bundleId → 图标 URL。历史记录里没持久化 `iconURL`（真机 `ipa_downloads.json` 实测没有该字段），
    /// 进入页面时按 bundleId 查回来补上；查不到就退回字母块。
    @State private var icons: [String: String] = [:]
    @State private var selection = Set<String>()
    /// v0.3.382：在列表里出现**多于一次**的 bundleId。
    /// 用途：行状态判定时，若某个任务的版本还未知（只能按 bundleId 认行），
    /// 而这些行共享同一个 bundleId，就**宁可都不显示**进行中/失败 —— 不能显示错（见 activeJob 注释）。
    @State private var duplicatedBundleIds: Set<String> = []
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
        .sheet(item: $actionItem) { item in
            IPADownloadActionsSheet(
                item: item,
                iconURL: item.iconURL ?? icons[item.bundleId ?? ""],
                onOverwriteInstall: { install(item) },
                onDelete: { delete(item) })
        }
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
            // 点击区只覆盖「图标 + 文字」，右侧安装按钮各管各的，避免手势互相抢。
            // v0.3.378：点这里弹出操作面板（编辑模式下点行是勾选，不弹）。
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
                    }
                    // v0.3.363：包类型从胶囊同行里挪到**独立一行**。
                    // 原来和两个胶囊挤同一个 HStack，空间不够时被压成竖排窄列
                    // （真机截图里「加密 / 包 · / 带 / sinf」一列一个字的那个别扭样式）。
                    Text(item.kindText)
                        .font(.caption2)
                        .foregroundStyle(kindTint(item))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isEditing else { return }
                actionItem = item
            }

            // v0.3.381：按**文件名（含版本）**判本行的进行中状态 —— 只按 bundleId 会让
            // 同一应用的多版本条目一起显示「安装中」（用户实测 BUG）。
            if let job = activeJob(for: item) {
                HStack(spacing: 6) {
                    ProgressView(value: min(1, max(0, job.overall)))
                        .frame(width: 44)
                    Text(job.phase == .paused ? "已暂停" : job.stageText)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .fixedSize()
            } else {
                // v0.3.382：这一行上一次装失败 → 红字「安装失败」，**仍可点**（点了就是重试）。
                // 不再静默变回「重装」按钮：用户点了安装、什么都没发生、按钮又变回去，他根本不知道失败了。
                let failed = finishedJob(for: item)?.phase == .failed
                Button {
                    install(item)
                } label: {
                    Text(failed ? "安装失败" : (item.lastInstalledAt == nil ? "安装" : "重装"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(minWidth: 40)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background((failed ? Color.red : Color.blue).opacity(0.14), in: Capsule())
                        .foregroundStyle(failed ? Color.red : Color.blue)
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
        syncSourceURLs()
        items = IPADownloadLibrary.shared.items()
        // 同一个 bundleId 在列表里出现两次以上 → 记下来：任务版本未知时不允许按 bundleId 认行
        duplicatedBundleIds = Set(
            Dictionary(grouping: items.compactMap { $0.bundleId }, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys)
    }

    /// 本行当前正在进行的任务（文件名优先；bundleId 只有在列表里唯一时才允许用来认行）
    private func activeJob(for item: IPADownloadItem) -> IPADownloadCenter.Job? {
        center.activeJob(fileName: item.fileName,
                         bundleId: item.bundleId,
                         version: item.version,
                         name: item.title,
                         allowBundleIdFallback: !bundleIdIsDuplicated(item))
    }

    /// 本行最近一次结束的任务（判「这一行装失败了」用，口径与 `activeJob(for:)` 一致）
    private func finishedJob(for item: IPADownloadItem) -> IPADownloadCenter.Job? {
        center.lastFinishedJob(fileName: item.fileName,
                               bundleId: item.bundleId,
                               version: item.version,
                               name: item.title,
                               allowBundleIdFallback: !bundleIdIsDuplicated(item))
    }

    /// 该行的 bundleId 是否在列表里有多行
    private func bundleIdIsDuplicated(_ item: IPADownloadItem) -> Bool {
        guard let bid = item.bundleId, !bid.isEmpty else { return false }
        return duplicatedBundleIds.contains(bid)
    }

    /// v0.3.378：把下载中心任务里记着的**来源直链**回填进台账并落盘。
    /// 「复制下载链接」只认台账里真实存在的直链，不拿本地路径冒充。
    private func syncSourceURLs() {
        for job in center.jobs {
            guard let name = job.localFileName,
                  let url = job.remoteURL, !url.isEmpty else { continue }
            IPADownloadLibrary.shared.updateSourceURL(fileName: name, url: url)
        }
    }

    /// v0.3.378：删除一个安装包（文件 + 台账），操作面板调用
    private func delete(_ item: IPADownloadItem) {
        IPADownloadLibrary.shared.remove(item)
        reload()
        ToastCenter.shared.show("已删除安装包")
    }

    /// 补齐列表图标：历史记录没存 `iconURL`，按 bundleId 逐个查 App Store。
    /// 整体串行、同一 bundleId 只查一次（Gmail 有两条记录）、失败静默跳过 ——
    /// 图标只是锦上添花，不能让缺失影响列表渲染。
    @MainActor
    private func loadIcons() async {
        // v0.3.360：查到就**落盘**（`IPADownloadLibrary.updateIconURL`），否则每次进页面都要重发
        // 一轮 lookup。单次最多补 30 条，超出的留到下次，避免条目多时变成请求风暴。
        var queried = Set<String>()
        var budget = 30
        for item in items {
            guard budget > 0 else { break }
            guard item.iconURL == nil else { continue }
            guard let bid = item.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty else { continue }
            guard icons[bid] == nil, queried.insert(bid).inserted else { continue }
            budget -= 1
            if let hit = try? await AppStoreService.lookup(bundleId: bid),
               let icon = hit.iconSmallURL ?? hit.iconURL {
                icons[bid] = icon
                IPADownloadLibrary.shared.updateIconURL(fileName: item.fileName, url: icon)
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
