import SwiftUI

// 共享转换 ·「已修补」二级页（用户需求 #1 / #3 / #4）.
//
// 从「共享转换」主页的「已修补」栏目**点击进入**（不再在原页展开 / 收拢）。
// 左上角**系统返回键 + 额外向上箭头并存**（两者都返回上一级，用户明确接受两个入口）；
// **不隐藏返回键** —— 隐藏会连带禁掉系统左滑返回手势。支持搜索；
// 行内**不常驻按钮**，单条动作收进 `.swipeActions`：导出 / 在线安装 / 覆盖安装 / 删除安装包
// （**不给重新修补** —— 已修补的包无需再修，且原件已按需求 #17 删除，无从下手）。
//
// 骨架与「已导入」页一致（搜索栏 / 多选 + 全选 / 底部批量条），实现见 `ImportedListPage.swift` 顶部注释。
//
// 数据源：`ImportedPackageList.scanListing(...).repaired`（磁盘证据）。
//
// 底栏：主按钮「覆盖安装（N）」+ 附加「删除（N）」「导出（N）」，主按钮语义不随选中数翻转。
// 在线安装是 OTA 单包通道，多选语义不成立，只在行内 `.swipeActions` 提供（见 `batchBar`）。
//
// 批量导出（用户需求）：已修补产物额外镜像一份到**专属目录** `Documents/Repaired/`
// （见 `RepairedProductStore`）；一次把所选 IPA **全部**交给系统分享面板
// （`UIActivityViewController` 原生支持多 URL）—— **不逐个导出、不先压缩成 zip**。
// 单条导出仍走同一套 `ShareSheet` 机制（对象同为 `package.repairedPath`，修补产物，不是原件）。

struct RepairedListPage: View {

    @Environment(\.dismiss) private var dismiss

    @State private var packages: [ImportedPackage] = []
    @State private var loading = true
    @State private var searchText = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []

    /// 包 id → 图标 `file://` 地址（从 IPA 提取后落 Caches）。读不出就没有这一项，行首回落首字母块.
    @State private var iconURLs: [String: String] = [:]
    /// 长按一行 → 「查看图标」打开的全屏预览。图数组随 target 一起写（`ImagePreviewTarget`），
    /// 页面上不再单独留一份预览数组 —— 两次独立写入会让弹窗读到旧的空数组.
    @State private var previewTarget: ImagePreviewTarget?

    @State private var busy = false
    /// 需求 #5：流程 banner 的 N/M 进度（如 `(current: 1, total: 14)`）与补充说明。
    @State private var flowProgress: (current: Int, total: Int)?
    @State private var flowCaption: String?
    @State private var resultText: String?

    /// 单条安装进行中的包 id（在线安装 / 覆盖升级各自一条在跑）。
    @State private var workingId: String?
    /// 单条 / 批量导出共用一个分享入口（多 URL 一次交给系统面板）。
    @State private var sharePayload: RepairedSharePayload?
    /// 待二次确认的「删除安装包」目标（非空即弹确认）。删除是破坏性操作（落盘文件不可恢复），
    /// 必须先确认再动手 —— 与「已导入」页的删除同一取向.
    @State private var pendingDelete: DeleteConfirm?

    /// 删除确认的载荷（`Identifiable` ⇒ 直接喂给 `.alert(item:)`）。
    private struct DeleteConfirm: Identifiable {
        let id = UUID()
        let items: [ImportedPackage]
    }

    private var visible: [ImportedPackage] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return packages }
        return packages.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.bundleId ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var selectedPackages: [ImportedPackage] {
        packages.filter { selected.contains($0.id) }
    }

    private var selectingAllVisible: Bool {
        !visible.isEmpty && visible.allSatisfy { selected.contains($0.id) }
    }

    private var selectedSizeText: String? {
        let total = selectedPackages.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return total > 0 ? IPADownloadLibrary.sizeText(total) : nil
    }

    // MARK: - body

    var body: some View {
        List {
            // 需求 #5：流程 banner 常驻（二级页也显示）。
            //   · 批量覆盖安装 ⇒ `progress` 以 N/M 显示确定进度；
            //   · 单条在线安装 ⇒ 无确定进度可报（OTA 只等系统回调），以 `indeterminate` 转圈显示在「安装」段。
            ImportFlowBanner(stage: .install, progress: flowProgress,
                             indeterminate: workingId != nil && flowProgress == nil,
                             caption: flowCaption)
            if let resultText {
                Section {
                    Text(resultText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !loading && visible.isEmpty {
                Section { emptyRow }
            } else {
                Section {
                    ForEach(visible) { p in
                        row(p)
                    }
                } footer: {
                    Text("已修补的包支持在线安装、覆盖安装与导出；原件已删除，不再提供重新修补.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("已修补")
        .navigationBarTitleDisplayMode(.inline)
        // 刻意**不隐藏**系统返回键：隐藏返回键会连带禁掉系统左滑返回手势
        // （用户反馈「删了返回键还会导致无法左滑返回」）。系统返回键与额外向上箭头并存，
        // 两者都返回上一级（用户明确接受两个返回入口）。
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索包名 / 应用标识")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .accessibilityLabel("返回")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if selecting {
                    Button(selectingAllVisible ? "取消全选" : "全选") { toggleSelectAll() }
                        .disabled(visible.isEmpty || busy)
                    Button("完成") { exitSelection() }
                } else {
                    Button("选择") { enterSelection() }
                        .disabled(packages.isEmpty || busy)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // 底栏自成一个 `VStack`，动画**只挂在这条底栏上** ——
            // 挂到外层 `List` 上会让整张列表随选择态一起动（切换时「突兀」的根因）.
            VStack(spacing: 0) {
                if selecting {
                    batchBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 12)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selecting)
        }
        .sheet(item: $sharePayload) { payload in
            // 单条 / 批量同一入口：`UIActivityViewController` 支持一次传入多个 URL，
            // 批量导出即「一次把所选 IPA 全部交给分享面板」，不逐个、不压缩。
            ShareSheet(items: payload.urls)
        }
        // 「删除安装包」的二次确认。破坏性操作（落盘文件 + 专属目录镜像不可恢复），先确认再动手.
        .alert(item: $pendingDelete) { confirm in
            Alert(title: Text("删除确认"),
                  message: Text("将从本机删除这 \(confirm.items.count) 个安装包及其修补产物，并清除专属目录里的副本. 删除后无法恢复."),
                  primaryButton: .destructive(Text("删除")) { performDelete(confirm.items) },
                  secondaryButton: .cancel(Text("取消")))
        }
        // 长按一行 → 「查看图标」→ 全屏预览；长按图片「保存到相册」由 `ImageGalleryViewer` 自带
        //（二次确认 → `MediaSaver`，无权限自动回落 `Documents/AppIcons`），这里只负责把 target 递进去.
        .fullScreenCover(item: $previewTarget) { target in
            ImageGalleryViewer(urls: target.urls, startIndex: target.index)
        }
        // 本页已在多处调用 `ToastCenter.shared.show`，必须挂上展示层，否则这些提示全部静默.
        .toastHost()
        .onAppear { reload() }
    }

    // MARK: - 子视图

    private var emptyRow: some View {
        // 空态与主页 `ImportView.emptySection` / 「已导入」「待修补」两页同一套视觉语言（`InfoActionCard`）.
        // 无按钮形态（不传 `actionTitle` / `action`）；`message` 必填且**不传空串**，避免多渲染一个空 `Text`.
        InfoActionCard(
            icon: "checkmark.seal.fill",
            iconTint: AppTheme.success,
            title: "已修补",
            message: searchText.isEmpty ? "还没有修补过的安装包." : "没有匹配 “\(searchText)” 的安装包."
        )
    }

    /// 底部批量条。主按钮「覆盖安装（N）」+ 附加「删除（N）」「导出（N）」。
    /// 主按钮语义稳定，不随选中数翻转；在线安装是单包通道，只在行内 `.swipeActions` 提供。
    private var batchBar: some View {
        BatchActionBar(selectedCount: selected.count,
                       subtitle: selectedSizeText,
                       primaryTitle: "覆盖安装（\(selected.count)）",
                       primaryDisabled: batchPrimaryDisabled,
                       primaryAction: { runOverwriteInstall(selectedPackages) }) {
            HStack(spacing: 8) {
                // 「删除安装包」：批量入口（左滑是单条入口）。破坏性操作，先二次确认。
                Button("删除（\(selected.count)）", role: .destructive) {
                    pendingDelete = DeleteConfirm(items: selectedPackages)
                }
                .buttonStyle(.bordered)
                .disabled(selected.isEmpty || busy)
                Button("导出（\(selected.count)）") { exportSelection() }
                    .buttonStyle(.bordered)
                    .disabled(selected.isEmpty || busy)
            }
        }
    }

    private var batchPrimaryDisabled: Bool {
        if selected.isEmpty || busy { return true }
        return selectedPackages.contains { !canInstallOrOverwrite($0) }
    }

    /// 底栏「导出（N）」：单条走单条、多选走批量。
    private func exportSelection() {
        if selected.count == 1, let p = selectedPackages.first {
            export(p)
        } else {
            exportSelected()
        }
    }

    private func row(_ p: ImportedPackage) -> some View {
        // 行**恒为 `Button`**：`selecting` 只控制勾选圈显不显示（见 `rowBody`），
        // 首次点按由 `handleTap` 自动进入选择态 —— 与「已导入」「待修补」两页同一口径.
        // `.swipeActions` 与 `.contextMenu` 挂在行外层，与这个 `Button` 并存.
        VStack(alignment: .leading, spacing: 6) {
            Button {
                handleTap(p)
            } label: {
                rowBody(p, showsSelection: selecting)
            }
            .buttonStyle(.plain)
            .disabled(busy)

            // 行内不常驻大按钮：安装 / 导出收进下方 `.swipeActions`，
            // 行回归「图标 + 标题 + chip」的干净形态。
            if workingId == p.id {
                ProgressView().controlSize(.small)
            } else if let reason = installBlockReason(p) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                export(p)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .tint(AppTheme.accent)

            Button {
                runOnlineInstall(p)
            } label: {
                Label("在线安装", systemImage: "icloud.and.arrow.down")
            }
            .disabled(!canOnlineInstall(p) || busy)

            Button {
                runOverwriteInstall([p])
            } label: {
                Label("覆盖安装", systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(AppTheme.accent)
            .disabled(!canInstallOrOverwrite(p) || busy)

            // 「删除安装包」：单条入口（批量入口在底栏）。破坏性 ⇒ 不整滑删除，必须走二次确认。
            Button(role: .destructive) {
                pendingDelete = DeleteConfirm(items: [p])
            } label: {
                Label("删除安装包", systemImage: "trash")
            }
            .disabled(busy)
        }
        // 长按一行 → 「查看图标 / 提取图标」。菜单项与行首缩略图用**同一个**图标地址；
        // 没有图标（地址为空）时整组置灰，不让用户点下去才发现没图可看.
        // 「保存图标」不在这里：进预览后长按图片即可（`ImageGalleryViewer` 自带），不重复一份.
        // 「查看图标」走 `showPackageIconPreview`：从 IPA **现取**原图，不复用列表缩略图那份缓存.
        .contextMenu {
            iconMenuItems(iconURL: iconURLs[p.id], fileNameBase: p.bundleId ?? p.name) {
                showPackageIconPreview(p, target: $previewTarget)
            }
            .disabled((iconURLs[p.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func rowBody(_ p: ImportedPackage, showsSelection: Bool) -> some View {
        HStack(spacing: 12) {
            if showsSelection {
                Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppTheme.selectionIconSize))
                    .foregroundStyle(selected.contains(p.id)
                                     ? AppTheme.accent
                                     : AppTheme.unselected)
            }
            ImportedPackageIconView(name: p.name, url: iconURLs[p.id])
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let v = p.version { PackageChip(text: "v\(v)", tint: AppTheme.accent) }
                    Text(p.sizeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(p.importedAt.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            PackageChip(text: p.status.text, tint: p.status.tint)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 前置检查（照 ImportView.canOnlineInstall / canInstallOrOverwrite）

    /// 在线安装前置：包内有应用标识（bundle id）。
    private func canOnlineInstall(_ p: ImportedPackage) -> Bool {
        guard let path = p.repairedPath, !path.isEmpty else { return false }
        return !(p.bundleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 安装 / 覆盖升级前置：只要有修补产物就能装。
    /// 已装同款走 Upgrade，未装 / 状态未知走 Install，查不到清单不再是阻断理由。
    private func canInstallOrOverwrite(_ p: ImportedPackage) -> Bool {
        guard let path = p.repairedPath, !path.isEmpty else { return false }
        return true
    }

    private func installBlockReason(_ p: ImportedPackage) -> String? {
        guard let path = p.repairedPath, !path.isEmpty else {
            return "找不到修补产物，无法安装."
        }
        if canOnlineInstall(p) || canInstallOrOverwrite(p) { return nil }
        return "包内读不出应用标识，无法在线安装."
    }

    // MARK: - 选择

    private func handleTap(_ p: ImportedPackage) {
        guard !busy else { return }
        // 非选择态首次点按即进入选择态（行恒为 `Button`，故任何一次点按都会到这里）.
        if !selecting { selecting = true }
        if selected.contains(p.id) {
            selected.remove(p.id)
        } else {
            selected.insert(p.id)
        }
    }

    private func enterSelection() {
        selected.removeAll()
        selecting = true
    }

    private func exitSelection() {
        selecting = false
        selected.removeAll()
    }

    private func toggleSelectAll() {
        if selectingAllVisible {
            selected.subtract(visible.map(\.id))
        } else {
            selected.formUnion(visible.map(\.id))
        }
    }

    // MARK: - 数据刷新

    private func reload() {
        Task {
            let listing = await ImportedPackageScanner.scan()
            packages = listing.repaired
            loading = false
            selected.formIntersection(Set(packages.map(\.id)))
            await loadIcons()
            // 产物落进专属目录 `Documents/Repaired/`：进页面即同步，批量导出时直接取用。
            // 放后台（硬链接优先、不占额外空间），大包镜像不卡主线程。
            let snapshot = packages
            Task.detached(priority: .utility) {
                RepairedProductStore.sync(snapshot)
                // 镜像落盘后才知道「哪些包还在」——此刻清掉 `Repaired/` 里已无对应包的孤儿镜像，
                // 否则该目录只增不减（见 `RepairedProductStore.prune`）。
                RepairedProductStore.prune(keeping: snapshot)
            }
        }
    }

    /// 逐条解析图标（读 zip 成本高，放后台**串行**；已落盘的直接命中缓存文件）.
    /// 与 `ImportedListPage.loadIcons` 同型：图标只是锦上添花，读不出就留空、界面回落首字母块.
    private func loadIcons() async {
        // 先清掉「`Imports/` 里已无对应包」的旧图标缓存（判据见 `ImportedPackageIconStore.pruneStaleIcons`）.
        await Task.detached(priority: .utility) {
            ImportedPackageIconStore.pruneStaleIcons()
        }.value
        let targets = packages
        var resolved: [String: String] = [:]
        for p in targets {
            let url = await Task.detached(priority: .utility) {
                ImportedPackageIconStore.iconURL(for: p)
            }.value
            if let url {
                resolved[p.id] = url
                // 每解析出一个就发布一次 ⇒ 图标逐个出现，不等全部完成（本方法在主 actor 上，直接写 @State）.
                iconURLs = resolved
            }
        }
    }

    // MARK: - 安装

    /// 在线安装（OTA / `itms-services`）：装的正是这份修补产物（`OnlineInstallService` 是本地路径驱动）。
    /// `OnlineInstallService` 只给最终结果、**不给中间进度**，故 banner 以 `indeterminate` 转圈呈现（见 `body`），
    /// 不伪造确定进度条。
    private func runOnlineInstall(_ p: ImportedPackage) {
        guard canOnlineInstall(p), let path = p.repairedPath, let bundleId = p.bundleId else { return }
        workingId = p.id
        resultText = nil
        flowCaption = "正在安装：\(p.name)"
        let url = URL(fileURLWithPath: path)
        OnlineInstallService.install(ipaURL: url, bundleId: bundleId, logCategory: .shareConvert) { result in
            Task { @MainActor in
                workingId = nil
                flowCaption = nil
                switch result {
                case .success: ToastCenter.shared.show("正在安装")
                case .failure(let error): ToastCenter.shared.show(error.localizedDescription)
                }
            }
        }
    }

    /// 安装 / 覆盖升级：本地装这份产物。已装同款走 Upgrade（覆盖 / 升级），
    /// 未装或状态未知走 Install（全新安装）。多选时**逐条串行**，进度以 `N/M` 显示。
    private func runOverwriteInstall(_ targets: [ImportedPackage]) {
        let valid = targets.filter { canInstallOrOverwrite($0) }
        guard !valid.isEmpty else { return }
        busy = true
        resultText = nil
        Task {
            var ok = 0
            var failed = 0
            for (idx, p) in valid.enumerated() {
                flowProgress = (current: idx + 1, total: valid.count)
                flowCaption = "正在安装：\(p.name)"
                guard let path = p.repairedPath else { failed += 1; continue }
                // 已装同款 → Upgrade（覆盖 / 升级）；未装 / 状态未知 → Install（全新安装）。
                let upgrade = (p.isInstalled == true)
                do {
                    try await AppStoreInstallService.installLocalIPA(
                        path,
                        allowDowngrade: upgrade,
                        progress: { _ in },
                        onLog: { line in
                            // 日志归共享转换分类：installLocalIPA 自身不写日志，此前这里传 `{ _ in }`
                            // 把步骤全丢了，导致覆盖/升级安装无论成败在本页日志里零记录.
                            LoginLogger.shared.log("[共享安装] \(line)", category: .shareConvert)
                        })
                    ok += 1
                } catch {
                    failed += 1
                }
            }
            busy = false
            flowProgress = nil
            flowCaption = nil
            selecting = false
            selected.removeAll()
            resultText = "安装完成：成功 \(ok) 个，失败 \(failed) 个."
            reload()
        }
    }

    // MARK: - 删除安装包（需求：已修补页也能删）

    /// 「删除安装包」：把所选包在本机的**全部落点**删掉（原件 / 修补产物 / 专属目录镜像），
    /// 并按**实际结果**提示 —— 不做假成功（见 `ImportedPackageDeleter`）。
    ///
    /// 删除前已由弹窗二次确认（见 `body` 的 `.alert`），此处不再确认、直接动手.
    /// `.notFound`（磁盘上已无落点）计入成功：结果与「删掉了」一致，不该报失败.
    private func performDelete(_ items: [ImportedPackage]) {
        guard !items.isEmpty else { return }
        busy = true
        resultText = nil
        var ok = 0
        var failed = 0
        for p in items {
            switch ImportedPackageDeleter.delete(p) {
            case .removed, .notFound: ok += 1
            case .failed:           failed += 1
            }
        }
        busy = false
        selecting = false
        selected.removeAll()
        resultText = failed == 0
            ? "已删除 \(ok) 个安装包."
            : "已删除 \(ok) 个安装包，\(failed) 个删除失败."
        ToastCenter.shared.show(failed == 0
            ? "已删除安装包"
            : "未删除安装包：\(failed) 个文件删除失败")
        reload()
    }

    // MARK: - 导出（专属目录 + ShareSheet，多选一次导出全部）

    // 导出**不上报 banner 进度**，理由：
    //   · 真正的导出是 `UIActivityViewController`（系统分享面板），进度归系统、本页无从上报；
    //   · 前置的镜像到 `Documents/Repaired/` 优先**硬链接**（O(1)、瞬间完成），退化复制也无确定进度；
    //   · 本页 banner 固定在「安装」段 —— 把导出进度画在「安装」段上语义也不对（导出 ≠ 安装）。
    // 故不画：与其画个测不出来的东西，不如不画。

    /// 单条导出：把该包的产物镜像进专属目录后，单独分享它。
    private func export(_ p: ImportedPackage) {
        busy = true
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                RepairedProductStore.ensure(p)
            }.value
            busy = false
            guard let url else {
                ToastCenter.shared.show("没有可导出的安装包")
                return
            }
            sharePayload = RepairedSharePayload(urls: [url])
        }
    }

    /// 批量导出：把所选全部产物镜像进专属目录，**一次**交给系统分享面板（不逐个、不压缩）。
    private func exportSelected() {
        let targets = selectedPackages
        guard !targets.isEmpty else { return }
        busy = true
        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                RepairedProductStore.sync(targets)
            }.value
            busy = false
            guard !urls.isEmpty else {
                ToastCenter.shared.show("没有可导出的安装包")
                return
            }
            sharePayload = RepairedSharePayload(urls: urls)
        }
    }
}

// MARK: - 一次分享的载荷（单条 / 批量共用一个 `.sheet` 入口）

/// 分享目标集合。单条时 1 个 URL，批量时 N 个 —— 同一入口，避免同一视图挂两个 `.sheet`。
private struct RepairedSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - 「已修补」产物专属目录

/// 「已修补」产物的**专属目录**：`Documents/Repaired/`。
///
/// 需求：已修补的产物单独放一个目录，多选时能直接一次批量导出，不逐个压缩、不逐个 ipa 导出。
/// 多选导出 = 把这个目录里的多个文件**一次性**交给系统分享面板（`UIActivityViewController` 支持多 URL）。
///
/// 与 `Imports/` 的关系：**只镜像、不搬移**。
/// `ImportedPackageList.scanListing` 按 `Imports/<包名>/repaired.ipa`（老平铺为
/// `Imports/repaired/<包名>.ipa`）判定「已修补」块 —— 把产物搬走会让该块当场清空。
/// 故这里优先**硬链接**（同卷、不额外占空间），失败再退**复制**。
/// 目录本身是 Documents 下的一级子目录，`ImportService.scanForNewImports` 只下探 `Imports/`、
/// 不递归子目录，故镜像进来的 `.ipa` 不会被当成「新导入」重复捞回。
///
/// 只增不减的问题：镜像若不清理，包被移除后 `Repaired/` 仍留着（硬链接还让数据无法释放）。
/// 故在镜像之后调用 `prune(keeping:)`，按包名集合删掉无主镜像（见该方法注释）。
enum RepairedProductStore {

    /// 专属目录：`Documents/Repaired/`（不存在则创建）。
    static func directory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Repaired", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 确保该包的产物已落在专属目录里，返回其 URL；无产物 / 落盘失败返回 nil。
    static func ensure(_ package: ImportedPackage) -> URL? {
        guard let src = package.repairedPath, !src.isEmpty else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { return nil }
        let dest = directory().appendingPathComponent(leafName(for: package))
        return mirror(from: URL(fileURLWithPath: src), to: dest, fm: fm) ? dest : nil
    }

    /// 把 `packages` 的产物**全部**镜像进专属目录，返回落点 URL（进页面 / 导出前调用）。
    @discardableResult
    static func sync(_ packages: [ImportedPackage]) -> [URL] {
        packages.compactMap { ensure($0) }
    }

    /// 清理**孤儿镜像**：扫 `Repaired/`，删掉「在 `Imports/` 里找不到对应包」的镜像文件。
    ///
    /// 判据用**镜像文件名**：`ensure` 落盘名恒为 `leafName(for:)`（即 `<包名>.ipa`），
    /// 而 `packages` 来自对 `Imports/` 的磁盘扫描（`ImportedPackageList.scanListing().repaired`），
    /// 是「当前仍有修补产物的包」的权威集合。两个名字集合一比对，不在集合内的即为孤儿：
    /// 该包已被「从列表移除」（移进 `Imports/.removed/`）或「彻底删除」，镜像不该再留着占空间。
    ///
    /// 删除安全性：`removeItem` 只摘掉 `Repaired/` 这一个目录项，**不会**动 `Imports/` 里的源。
    /// 硬链接是两个目录项指向同一 inode，摘掉其中一个不影响另一个；复制兜底本就是独立文件，
    /// 删它也只是删掉这份副本，源产物仍在 `Imports/`（或在 `.removed/` 里可恢复）。
    /// 故「删镜像」永不波及源产物，最坏情况也只是镜像没了、下次进页面重新镜像。
    ///
    /// - Parameter packages: 当前仍存在的已修补包（**全量**，不是导出选中的子集 —— 传子集会误删未选中的镜像）。
    /// - Returns: 实际删掉的孤儿镜像数。
    @discardableResult
    static func prune(keeping packages: [ImportedPackage]) -> Int {
        // 扫描为空可能是 `Imports/` 瞬时不可读，而非「用户删光了」。此时宁可不删：
        // 孤儿镜像非破坏性（源在 `Imports/` 或 `.removed/` 都还在），留到下次非空扫描再清更稳。
        guard !packages.isEmpty else { return 0 }
        let fm = FileManager.default
        let keep = Set(packages.map { leafName(for: $0) })
        guard let items = try? fm.contentsOfDirectory(at: directory(),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for item in items {
            guard item.pathExtension.lowercased() == "ipa" else { continue }
            guard !keep.contains(item.lastPathComponent) else { continue }
            do {
                try fm.removeItem(at: item)
                removed += 1
            } catch {
                LoginLogger.shared.log(
                    "[共享修补] 清理无主产物 \(item.lastPathComponent) 失败：\(error.localizedDescription)",
                    category: .shareConvert)
            }
        }
        return removed
    }

    /// 镜像落盘名：`ensure` 与 `prune` 必须用**同一个**名字口径，否则清理会误判。
    private static func leafName(for package: ImportedPackage) -> String {
        FileNameRules.sanitize("\(package.name).ipa") ?? "\(package.name).ipa"
    }

    /// 镜像单个文件：专属目录里已有且不旧于源 → 直接用；否则硬链接优先、复制兜底。
    private static func mirror(from src: URL, to dest: URL, fm: FileManager) -> Bool {
        if fm.fileExists(atPath: dest.path) {
            let srcDate = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let dstDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let s = srcDate, let d = dstDate, d >= s { return true }
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.linkItem(at: src, to: dest)   // 硬链接：同卷、不额外占空间
            return true
        } catch {
            do {
                try fm.copyItem(at: src, to: dest)
                // 硬链接失败（跨卷等）才退到复制：这是唯一让磁盘占用翻倍的路径，必须让用户知道。
                // 进页面即镜像，若此处静默，用户只会在空间告急时才发现。
                Task { @MainActor in
                    ToastCenter.shared.show("已复制一份产物，磁盘占用会翻倍.")
                }
                return true
            } catch {
                LoginLogger.shared.log(
                    "[共享修补] 镜像产物到 Repaired/ 失败：\(error.localizedDescription)",
                    category: .shareConvert)
                return false
            }
        }
    }
}
