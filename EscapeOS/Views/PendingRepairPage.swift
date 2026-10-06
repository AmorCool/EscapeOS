import SwiftUI

// 共享转换 ·「待修补」二级页（用户需求 #2，新增栏目）.
//
// 从「共享转换」主页新增的「待修补」栏目**点击进入**。左上角在系统返回按钮之外**额外**挂一个向上箭头
//（不隐藏返回键，左滑返回照常可用），支持搜索；多选 + 全选后走底部批量条：主按钮「批量修补（N）」+「移除（N）」。
//
// 骨架与「已导入」页一致（向上箭头 / 搜索栏 / 多选 + 全选 / 底部批量条），实现见 `ImportedListPage.swift` 顶部注释。
//
// 数据源（两种，见 `init(packages:pendingNames:)`）：
//   · **注入模式** —— 「共享转换」主界面把它的**会话队列**（本次会话刚导入的那几个）传进来，
//     本页只显示这几个，**不再扫盘**。主界面计数也用同一份队列，故点进去数量对得上。
//     队列的**所有权在主界面**（`@State sessionPendingNames`）：本页额外拿一个
//     `pendingNames: Binding<Set<String>>` **回写口**，移除 / 修补成功即把包名从队列里扣掉，
//     主界面计数**同帧**跟着降 —— 否则本页改动传不回去，重进本页时被移除的包会「复活」。
//   · **磁盘模式**（默认）—— `ImportedPackageList.scanListing(...).imported` 全量；供其它入口使用。
//   · 「已导入」= imported 全量（含已安装）；「待修补」= 其中还没修补、正等着动手的那些。
//     「是否已安装」与「是否待修补」**解耦**：本机已装同 bundleId 的包 status == .installed，
//     但它仍是一件**没修补过**的包，故也属于「待修补」，不能按 status 滤掉（会凭空少项 / 空列表）。
//
// 「移除」语义（用户需求 #2）：**仅从「待修补」列表移除，不删安装包**，两种模式各有落法：
//   · 磁盘模式：把包落点整体**移动**到 `Imports/.removed/`（移动 ≠ 删除，可恢复），
//     两处扫描都用 `.skipsHiddenFiles` ⇒ 移走后即刻从列表消失，且不会被「扫描新文件」捞回来。
//     详见 `ImportedPackageMover`。
//   · 注入模式：**只从会话队列拿掉，不碰磁盘文件** —— 队列是会话级的临时列表，包还没被用户确认丢弃，
//     没必要为它去挪文件；包仍在「已导入」里，可继续修补。拿掉动作**经 `pendingNames` 回写主界面**。
//   这与「已导入」页的「移除 = 删除」是**两种语义**，刻意分开。

struct PendingRepairPage: View {

    @Environment(\.dismiss) private var dismiss

    /// 会话级注入的包（非 nil ⇒ 只显示这些，不再扫盘）。见 `init(packages:pendingNames:)`.
    private let injectedPackages: [ImportedPackage]?

    /// 会话队列的**回写口**（队列所有权在「共享转换」主界面 `@State sessionPendingNames`）。
    ///
    /// 为什么需要它：队列是主界面的状态，本页若只拿到一份**值拷贝**，本页的移除 / 修补成功就传不回去
    /// —— 主界面计数不变，且重进本页时队列里那个包会「复活」。传了它，本页改动直接落到主界面队列上
    /// （计数同帧变化，重进也不再出现）。`nil` ⇒ 磁盘模式，本页改动只作用于本地列表。
    private let pendingNames: Binding<Set<String>>?

    /// - Parameters:
    ///   - packages: 「共享转换」主界面把它的**会话队列**传进来 ⇒ 只显示这些、不扫盘；
    ///     不传（`nil`，默认）⇒ 保持磁盘全量语义，自己扫盘 —— 现有无参调用不受影响.
    ///   - pendingNames: 会话队列的**回写口**（队列所有权在主界面）；`nil` ⇒ 磁盘模式.
    init(packages: [ImportedPackage]? = nil,
         pendingNames: Binding<Set<String>>? = nil) {
        self.injectedPackages = packages
        self.pendingNames = pendingNames
        _packages = State(initialValue: packages ?? [])
        _loading = State(initialValue: packages == nil)
    }

    @State private var packages: [ImportedPackage] = []
    @State private var loading = true
    @State private var searchText = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []

    @State private var busy = false
    /// 本页已处理掉、应从本地列表立刻消失的包 id（**本地视图态**，只影响本页这一帧的渲染）。
    /// 磁盘模式下 `reload()` 靠重新扫盘自然剔除，用不到它；注入模式不扫盘，靠它让「已移出 /
    /// 已修补成功」的项在本页立刻消失。**队列本身的扣除另经 `pendingNames` 回写主界面**
    ///（见该属性注释）—— 两者分工：`droppedIds` 管本页渲染，`pendingNames` 管跨页真值。
    @State private var droppedIds: Set<String> = []
    /// 包 id → 图标 `file://` 地址（从 IPA 提取后落 Caches）。读不出就没有这一项，行首回落首字母块.
    @State private var iconURLs: [String: String] = [:]
    /// 长按一行 → 「查看图标」打开的全屏预览。图数组随 target 一起写（`ImagePreviewTarget`），
    /// 页面上不再单独留一份预览数组 —— 两次独立写入会让弹窗读到旧的空数组.
    @State private var previewTarget: ImagePreviewTarget?
    /// 需求 #5：流程 banner 的 N/M 进度（如 `(current: 1, total: 14)`）与补充说明。
    @State private var flowProgress: (current: Int, total: Int)?
    @State private var flowCaption: String?
    @State private var resultText: String?

    /// 安装前确认（三步确认第三步）：挂起等用户在 `.alert` 上作答。唯一 resume 点是 `resumeInstall`（幂等）。
    @State private var installContinuation: CheckedContinuation<Bool, Never>?
    /// 页面是否仍在屏上：批量逐条跑时用它兜底，避免对话框无处显示导致 continuation 永久挂起。
    @State private var viewActive = true

    @State private var alert: ActiveAlert?

    private enum ActiveAlert: Identifiable {
        case installConfirm
        case batchRepair(count: Int)
        case remove(items: [ImportedPackage])

        var id: String {
            switch self {
            case .installConfirm:     return "install-confirm"
            case .batchRepair(let n): return "batch-repair-\(n)"
            case .remove(let items):  return "remove-\(items.count)"
            }
        }
    }

    // MARK: - 派生数据

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
            // 需求 #5：流程 banner 常驻（二级页也显示），批量修补时以 N/M 显示进度。
            ImportFlowBanner(stage: .repair, progress: flowProgress, caption: flowCaption)
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
                    Text("勾选后可批量修补或移除；移除只从本列表拿掉，不删除安装包.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("待修补")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索包名 / 应用标识")
        .toolbar {
            // 向上箭头是**额外**入口；系统返回按钮与左滑手势都保留
            //（不隐藏返回键，否则会禁掉左滑）.
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
            VStack(spacing: 0) {
                if selecting {
                    BatchActionBar(selectedCount: selected.count,
                                   subtitle: selectedSizeText,
                                   primaryTitle: "批量修补（\(selected.count)）",
                                   primaryDisabled: selected.isEmpty || busy,
                                   primaryAction: { alert = .batchRepair(count: selected.count) }) {
                        // 待修补页的「移除」= 仅从列表移除（移到 Imports/.removed/），不删安装包。
                        // 这里**不提供在线安装**：待修补的包还没有修补产物。
                        Button("移除（\(selected.count)）") {
                            alert = .remove(items: selectedPackages)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selected.isEmpty || busy)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Color.clear.frame(height: 12)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selecting)
        }
        .alert(item: $alert) { alertContent($0) }
        // 长按一行 → 「查看图标」→ 全屏预览；长按图片「保存到相册」由 `ImageGalleryViewer` 自带
        //（二次确认 → `MediaSaver`，无权限自动回落 `Documents/AppIcons`），这里只负责把 target 递进去.
        .fullScreenCover(item: $previewTarget) { target in
            ImageGalleryViewer(urls: target.urls, startIndex: target.index)
        }
        .toastHost()
        .onAppear { viewActive = true; reload() }
        .onDisappear { viewActive = false; resumeInstall(false) }
        // 防御回补：注入数组变化时把本地列表跟着同步一次。
        // 为什么需要：注入模式只在 `onAppear` 同步过一次；若主界面在扫盘完成前就导航（旧缺陷 1），
        // 注入数组会是空的、页面开成空。导航侧已改成「扫盘后再导航」，这里再兜一道 ——
        // 主界面任何一次重扫让注入数组变了，本页都跟着回补，不会停在旧快照上.
        .onChange(of: injectedPackages) { _, _ in reload() }
    }

    // MARK: - 子视图

    private var emptyRow: some View {
        // 空态与主页 `ImportView.emptySection` 同一套视觉语言（`InfoActionCard`），图标取本栏目自己的入口图标.
        InfoActionCard(
            icon: "clock",
            iconTint: AppTheme.pending,
            title: searchText.isEmpty ? "没有待修补的安装包." : "没有匹配 “\(searchText)” 的安装包.",
            message: "")
    }

    private func row(_ p: ImportedPackage) -> some View {
        Button {
            handleTap(p)
        } label: {
            HStack(spacing: 12) {
                if selecting {
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
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(busy)
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

    // MARK: - 弹窗

    private func alertContent(_ a: ActiveAlert) -> Alert {
        switch a {
        case .installConfirm:
            return Alert(title: Text("安装前确认"),
                         message: Text("即将把这个应用安装到本机."),
                         primaryButton: .default(Text("继续安装")) { resumeInstall(true) },
                         secondaryButton: .cancel(Text("只修补，不安装")) { resumeInstall(false) })
        case .batchRepair(let n):
            return Alert(title: Text("修补前确认"),
                         message: Text("将对选中的 \(n) 个安装包逐个修补并安装；每个在安装前还会再确认一次. 仅适用于来源可信、且与你登录相同 Apple ID 的设备分享的包."),
                         primaryButton: .default(Text("开始修补")) { startBatchRepair() },
                         secondaryButton: .cancel(Text("取消")))
        case .remove(let items):
            return Alert(title: Text("移除确认"),
                         message: Text("将把这 \(items.count) 个安装包从待修补列表拿掉，安装包仍保留在本机（可恢复）. 这不是删除."),
                         primaryButton: .default(Text("移除")) { performRemove(items) },
                         secondaryButton: .cancel(Text("取消")))
        }
    }

    // MARK: - 选择

    private func handleTap(_ p: ImportedPackage) {
        guard !busy else { return }
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
        // 注入模式：列表就是会话队列（扣掉本页已处理掉的），**不扫盘** —— 与主界面计数同源。
        if let injected = injectedPackages {
            packages = injected.filter { !droppedIds.contains($0.id) }
            loading = false
            selected.formIntersection(Set(packages.map(\.id)))
            Task { await loadIcons() }
            return
        }
        Task {
            let listing = await ImportedPackageScanner.scan()
            // 判据只有「有原件、还没修补」一条 —— `imported` 块本身就是该判据，**不再叠加 status 过滤**.
            // 为什么删掉 `status == .awaitingRepair`：`imported` 块的 status 只可能是 .awaitingRepair /
            // .installed（该块 `product` 恒为 nil，见 `ImportedPackageList.make`）；本机已装同 bundleId 的包
            // status == .installed，叠加过滤会被滤掉 ⇒ 「待修补」列表凭空少项 / 空（与 `ImportView`
            // `sessionPendingPackages` 同一类 bug，f4 已修那处）。
            // 已修补的包不会出现在这里：包一经修补即整行移出 `imported` 块（进 `repaired` 块），无需额外排除.
            packages = listing.imported
            loading = false
            selected.formIntersection(Set(packages.map(\.id)))
            await loadIcons()
        }
    }

    /// 逐条解析图标（读 zip 成本高，放后台**串行**；已落盘的直接命中缓存文件）.
    /// 与 `IPADownloadManagerView.loadIcons` 同型：图标只是锦上添花，读不出就留空、界面回落首字母块.
    private func loadIcons() async {
        let targets = packages
        var resolved: [String: String] = [:]
        for p in targets {
            let url = await Task.detached(priority: .utility) {
                ImportedPackageIconStore.iconURL(for: p)
            }.value
            if let url { resolved[p.id] = url }
        }
        iconURLs = resolved
    }

    // MARK: - 批量修补（需求 #2 / #5）

    private func startBatchRepair() {
        let targets = selectedPackages
        guard !targets.isEmpty else { return }
        busy = true
        resultText = nil
        Task {
            var ok = 0
            var failed = 0
            for (idx, p) in targets.enumerated() {
                guard viewActive else { break }
                flowProgress = (current: idx + 1, total: targets.count)
                flowCaption = "正在修补：\(p.name)"
                guard let path = p.originalPath else { failed += 1; continue }
                let rebuilt: ImportRecord? = await Task.detached(priority: .userInitiated) {
                    ImportService.rebuildRecord(forOriginalAt: path)
                }.value
                guard let rec = rebuilt else { failed += 1; continue }

                let r = await ImportService.handOffToRepair(
                    rec,
                    runLaunchCheck: true,
                    progress: nil,
                    confirmInstall: { await awaitInstallConfirm() })

                if r.status == .ok {
                    ImportService.deleteOriginalAfterRepairSuccess(rec)
                    droppedIds.insert(p.id)   // 修补成功的包不再属于「待修补」，从本地列表扣掉
                    dropFromQueue(p.name)     // 回写主界面队列 ⇒ 计数同帧降
                    ok += 1
                } else {
                    failed += 1
                }
            }
            busy = false
            flowProgress = nil
            flowCaption = nil
            selected.removeAll()
            selecting = false
            resultText = "批量修补完成：成功 \(ok) 个，失败 \(failed) 个."
            reload()
        }
    }

    // MARK: - 移除（需求 #2：仅从列表移除，不删安装包）

    /// 两种模式各有落法（见文件头「移除」语义）：
    /// · 磁盘模式：`ImportedPackageMover.moveToRemoved`（移动 ≠ 删除，可恢复）.
    /// · 注入模式：**只从会话队列拿掉，不碰磁盘文件** —— 队列是临时列表，包还没被确认丢弃；
    ///   拿掉动作经 `pendingNames` **回写主界面队列**，主界面计数同帧降、重进本页不再出现.
    /// 两种模式都记进 `droppedIds`：磁盘模式本可省（`reload()` 会重扫），但记上无害且让「移除结果」
    /// 在同一帧内即可见，不必等扫盘回来.
    private func performRemove(_ items: [ImportedPackage]) {
        busy = true
        resultText = nil
        var ok = 0
        var failed = 0
        let queueOnly = injectedPackages != nil
        for p in items {
            if queueOnly {
                droppedIds.insert(p.id)
                dropFromQueue(p.name)   // 回写主界面队列 ⇒ 计数同帧降，重进不再复活
                ok += 1
            } else if ImportedPackageMover.moveToRemoved(p) {
                droppedIds.insert(p.id)
                ok += 1
            } else {
                failed += 1
            }
        }
        busy = false
        selected.removeAll()
        selecting = false
        resultText = failed == 0
            ? "已从列表移除 \(ok) 个安装包（文件仍在，可恢复）."
            : "已移除 \(ok) 个，\(failed) 个移除失败."
        reload()
    }

    /// 把包名从**主界面会话队列**里扣掉（经 `pendingNames` 回写口；`nil` ⇒ 磁盘模式，no-op）。
    ///
    /// 为什么经一个 helper：`Binding.wrappedValue` 是 `nonmutating set` 的计算属性，
    /// 直接 `pendingNames?.wrappedValue.remove(...)` 走「可选链 + 可变方法」写回，语义绕；
    /// 这里显式「读 - 改 - 写」，既确定能编译，也把「队列真值在主界面」这件事写明.
    private func dropFromQueue(_ name: String) {
        guard var names = pendingNames?.wrappedValue else { return }
        names.remove(name)
        pendingNames?.wrappedValue = names
    }

    // MARK: - 安装前确认（三步确认第三步）

    @MainActor
    private func awaitInstallConfirm() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            installContinuation = cont
            alert = .installConfirm
        }
    }

    private func resumeInstall(_ ok: Bool) {
        installContinuation?.resume(returning: ok)
        installContinuation = nil
    }
}
