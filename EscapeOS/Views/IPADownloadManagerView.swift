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
    /// v0.3.387：正在弹操作面板的**下载中任务**（还没落台账，包不成条目）。
    /// 用途：下载过程也能「提取下载链接」—— 那行的直链只在 `Job.remoteURL` 上。
    @State private var actionJob: IPADownloadCenter.Job?
    /// bundleId → 图标 URL。历史记录里没持久化 `iconURL`（真机 `ipa_downloads.json` 实测没有该字段），
    /// 进入页面时按 bundleId 查回来补上；查不到就退回字母块。
    @State private var icons: [String: String] = [:]
    @State private var selection = Set<String>()
    /// v0.3.383：右上角「在线安装设置」sheet（GitHub Token）
    @State private var showOnlineInstallSettings = false
    /// v0.3.382：在列表里出现**多于一次**的 bundleId。
    /// 用途：行状态判定时，若某个任务的版本还未知（只能按 bundleId 认行），
    /// 而这些行共享同一个 bundleId，就**宁可都不显示**进行中/失败 —— 不能显示错（见 activeJob 注释）。
    @State private var duplicatedBundleIds: Set<String> = []
    @ObservedObject private var center = IPADownloadCenter.shared
    /// v0.3.388：在线安装（OTA）的进度 —— 唯一真实来源是**本机服务器已发给系统的字节数**
    /// （系统进入安装阶段后 App 观测不到，那时显示不确定态，见 `OnlineInstallProgress`）。
    @ObservedObject private var otaProgress = OnlineInstallProgress.shared
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showOnlineInstallSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("在线安装设置")
            }
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
        .sheet(isPresented: $showOnlineInstallSettings) {
            OnlineInstallSettingsSheet()
        }
        .sheet(item: $actionItem) { item in
            IPADownloadActionsSheet(
                item: item,
                iconURL: item.iconURL ?? icons[item.bundleId ?? ""],
                onOverwriteInstall: { install(item) },
                onDelete: { delete(item) })
        }
        .sheet(item: $actionJob) { job in
            // v0.3.387：「下载中」那行 → 同一个面板，但本地还没有包，
            // 所以只渲染「提取下载链接」（值取 `job.remoteURL`，见 `pendingItem`）。
            // 那两个闭包在 pending 模式下不会被渲染/调用，给空实现即可。
            IPADownloadActionsSheet(
                item: pendingItem(job),
                iconURL: icons[job.bundleId ?? ""] ?? job.iconURL,
                onOverwriteInstall: {},
                onDelete: {},
                isPendingDownload: true)
        }
        .task {
            reload()
            await loadIcons()
        }
    }

    // MARK: - 下载中（暂停 / 继续 / 删除）

    /// v0.3.388：这一区**只放下载阶段的任务**（`center.downloadJobs`）——
    /// 安装阶段不再占用顶部这条横条，改在「已下载」对应行内画圆环（用户明确要求）。
    @ViewBuilder
    private var activeSection: some View {
        if !center.downloadJobs.isEmpty {
            Section {
                ForEach(center.downloadJobs) { job in
                    activeRow(job)
                }
            } header: {
                HStack {
                    Text("下载中")
                    Spacer(minLength: 0)
                    Text("\(center.downloadJobs.count) 个任务")
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
            // v0.3.387：点这一条标题行也能弹操作面板 —— 下载过程就能「提取下载链接」。
            // 手势只加在这条标题行上：横向进度条与下面的暂停/删除按钮行为一律不动，行布局也不变。
            .contentShape(Rectangle())
            .onTapGesture { actionJob = job }
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
            // v0.3.388：把原来那条 44pt 横向进度条换成**圆形进度环 + 百分比**（覆盖安装与在线安装都有），
            // 高度仍是 44pt，不动行高、不挤掉右侧信息。
            if let progress = rowProgress(item) {
                HStack(spacing: 8) {
                    InstallProgressRing(fraction: progress.fraction)
                    Text(progress.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .fixedSize()
            } else {
                // v0.3.383：这一行上一次失败 → 红字标出**失败阶段**，**仍可点**（点了就是重试）。
                // 「下载失败」（文件可能不完整/不存在）与「安装失败」（文件是好的、卡在安装环节）
                // 对用户是两件事，不能都报「安装失败」——错标比不标更糟。
                // 不再静默变回「重装」按钮：用户点了安装、什么都没发生、按钮又变回去，他根本不知道失败了。
                let last = finishedJob(for: item)
                let failText: String? = last?.phase == .failed
                    ? (last?.failureStage == .download ? "下载失败" : "安装失败")
                    : nil
                let isFailed = failText != nil
                Button {
                    install(item)
                } label: {
                    Text(failText ?? (item.lastInstalledAt == nil ? "安装" : "重装"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(minWidth: 40)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background((isFailed ? Color.red : Color.blue).opacity(0.14), in: Capsule())
                        .foregroundStyle(isFailed ? Color.red : Color.blue)
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

    /// v0.3.388：这一行要不要显示**安装/下载进度环**，以及环里的分数（nil = 不确定态）与右侧文字。
    ///
    /// 两个来源，按「谁在动这一行」优先：
    /// 1. **在线安装（OTA）**：分数 = 本机服务器**已经发给系统的字节 / 包大小**（真实测量值）；
    ///    包发完 → `fraction = nil` → 转圈：**系统安装阶段 App 看不到任何进度**，
    ///    宁可转圈也不显示假百分比。
    /// 2. **覆盖安装 / 下载中**：用下载中心任务的 `overall`（链路 0~1，见 `Job.overall`）。
    ///    只有「排队等待」阶段是未开始，显示不确定态。
    private func rowProgress(_ item: IPADownloadItem) -> (fraction: Double?, text: String)? {
        if otaProgress.isActive,
           otaProgress.matches(fileName: item.fileName, bundleId: item.bundleId) {
            switch otaProgress.stage {
            case .transferring: return (otaProgress.fraction, "在线安装")
            case .installing: return (nil, "安装中")
            case .idle: break
            }
        }
        guard let job = activeJob(for: item) else { return nil }
        switch job.phase {
        case .waiting: return (nil, job.stageText)
        case .paused: return (job.overall, "已暂停")
        default: return (job.overall, job.stageText)
        }
    }

    /// v0.3.378：把下载中心任务里记着的**来源直链**回填进台账并落盘。
    /// **v0.3.386 起**该直链是操作面板「**提取下载链接**」的取值（IPA 包原链接）；
    /// 「复制下载链接」另取包内 `iTunesMetadata.itemId`，与本台账无关。
    /// **v0.3.387 起**直链已在下载时（`IPADownloadCenter`）就写台账，这里**只剩幂等兜底**。
    private func syncSourceURLs() {
        for job in center.jobs {
            guard let name = job.localFileName,
                  let url = job.remoteURL, !url.isEmpty else { continue }
            IPADownloadLibrary.shared.updateSourceURL(fileName: name, url: url)
        }
    }

    /// v0.3.387：把「下载中」的任务包成一个**只读条目**喂给操作面板。
    ///
    /// 下载中的任务还没落台账（本地无文件），所以体积记为 0、没有安装时间，这些字段面板在
    /// pending 模式下也不渲染。关键是 **`sourceURL` 直接取 `job.remoteURL`** ——
    /// 面板「提取下载链接」读的就是这个字段，于是**下载过程也能提取直链**。
    /// 文件名用 `job.localFileName ?? job.expectedFileName`（与下载中心落地的名字同源）：
    /// 下载中它指向一个尚不存在的文件，面板里任何依赖文件的行都已按 pending 模式收起。
    private func pendingItem(_ job: IPADownloadCenter.Job) -> IPADownloadItem {
        IPADownloadItem(fileName: job.localFileName ?? job.expectedFileName,
                        displayName: job.name,
                        bundleId: job.bundleId,
                        version: job.version,
                        sizeBytes: 0,
                        downloadedAt: Date(),
                        iconURL: job.iconURL,
                        source: job.source.rawValue,
                        sourceURL: job.remoteURL,
                        packageName: nil,
                        isEncrypted: nil,
                        hasSINF: nil,
                        lastInstalledAt: nil)
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
            // v0.3.383：文件类失败也要落到行上（红字「下载失败」），别只弹个转瞬即逝的 toast
            center.recordFileFailure(fileName: item.fileName, displayName: item.title,
                                     bundleId: item.bundleId, version: item.version,
                                     iconURL: item.iconURL, reason: "文件不存在")
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

/// v0.3.388：行内**安装进度圆环**（44pt，与行首 48pt 图标等高，不动行高）。
///
/// · `fraction != nil` → 圆环 + 环内等宽百分比：12 点起画、圆头 3pt、主题青（`LocusTheme.accent`）；
/// · `fraction == nil` → **不确定态**：一段持续旋转的弧，**不写百分比**
///   —— 这是「在线安装进了系统阶段、App 量不到进度」时唯一诚实的画法。
private struct InstallProgressRing: View {

    let fraction: Double?

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(LocusTheme.accent.opacity(0.18), lineWidth: 3)

            if let fraction {
                let clamped = min(1, max(0, fraction))
                Circle()
                    .trim(from: 0, to: max(0.02, clamped))
                    .stroke(LocusTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LocusTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(LocusTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            }
        }
        .frame(width: 44, height: 44)
        .onAppear { spinning = true }
    }
}

/// v0.3.383：下载管理右上角齿轮弹出的**极简**设置 —— 只放一行 GitHub Token。
///
/// 用途：把在线安装的**清单**托管到私有 gist（`raw_url` 是可信 HTTPS），
/// 比公共临时托管可靠。token 存 **Keychain**（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，
/// 不做 iCloud 同步、不落 UserDefaults），日志最多只记前 8 位。
/// 注意：**这只换了一个更可靠的托管通道，不代表「在线安装装不上」被修好了**。
struct OnlineInstallSettingsSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("GitHub Token", text: $token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.footnote)
                } footer: {
                    Text("仅用于托管安装清单.")
                        .font(.caption2)
                }

                Section {
                    Button("保存") {
                        OnlineInstallConfig.setGitHubToken(token)
                        token = OnlineInstallConfig.githubToken ?? ""
                        ToastCenter.shared.show("已保存")
                    }
                    Button("清除", role: .destructive) {
                        OnlineInstallConfig.clearGitHubToken()
                        token = ""
                        ToastCenter.shared.show("已清除")
                    }
                }
            }
            .navigationTitle("在线安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .toastHost()
        }
        .presentationDetents([.medium])
        .onAppear { token = OnlineInstallConfig.githubToken ?? "" }
    }
}
