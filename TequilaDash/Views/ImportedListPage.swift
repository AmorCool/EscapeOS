import SwiftUI

// 共享转换 ·「已导入」二级页（用户需求 #1 / #3）.
//
// 从「共享转换」主页的「已导入」栏目**点击进入**（不再在原页展开 / 收拢）。
// 左上角在**系统返回按钮**之外**额外**挂一个向上箭头（不隐藏返回键，左滑返回照常可用）；
// 支持搜索；多选 + 全选后走底部批量条。
//
// 骨架照仓库现成范式拼（不另造）：
//   · 向上箭头：leading `ToolbarItem{ Image(systemName: "arrow.up") }` + `dismiss()`
//     —— 箭头画法见 `AFCBrowserView.swift:86-96`。
//     **刻意不隐藏返回键**：隐藏它会连带禁掉系统左滑返回手势（用户明确要求保留左滑）.
//   · 搜索栏：`.searchable(placement: .navigationBarDrawer(displayMode: .always), prompt:)`
//     —— 见 `ModuleManagerView.swift:292-293` / `AppListView.swift:523`。
//   · 多选 + 全选：`selected: Set<String>` + 导航栏「选择 / 全选」
//     —— 见 `AppListView.swift:412/484/524-549` / `ReclaimTabView.swift:41-59`（全选在导航栏，不在底条）。
//   · 底部批量条：`.safeAreaInset(edge: .bottom)` 挂 `BatchActionBar`；未进选择态用 `Color.clear.frame(height: 12)` 占位
//     —— 见 `ReclaimTabView.swift:61-69`。
//   · 行首真图标 + 长按菜单：`ImportedPackageIconView` + `.contextMenu { iconMenuItems(...) }`
//     —— 图标提取 / 缓存见 `Shared/ImportedPackageUI.swift`；菜单项复用 `ImagePreviewSupport.iconMenuItems`.
//
// 数据源：`ImportedPackageList.scanListing(...).imported`（磁盘证据，本页不另做推断）。
//
// 接入（给 `impl-importview`）：主页「已导入」栏目改成一行
//   `NavigationLink { ImportedListPage() } label: { ... }`
// 本页**自己扫描 / 自己刷新**，不依赖外部传入状态。
//
// 界面文案：不用星形符号做强调 / 分级；不用黄色感叹号；中文句号一律用英文 `.`；「为什么」类解释只写注释。

struct ImportedListPage: View {

    @Environment(\.dismiss) private var dismiss

    @State private var packages: [ImportedPackage] = []
    @State private var loading = true
    @State private var searchText = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []

    @State private var busy = false
    /// 单条安装进行中的包 id（在线安装 / 覆盖安装各自一条在跑）.
    /// 用途：该行行尾画转圈、banner 高亮「安装」段并以不确定态呈现.
    @State private var workingId: String?
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

    /// 本页的确认弹窗（安装前确认 / 修补前确认 / 删除前确认）统一走一个 `.alert(item:)`，
    /// 避免「同一视图挂多个 `.alert` 只有最后一个生效」的老问题。
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
            // 需求 #5：流程 banner 常驻（二级页也显示）。
            //   · 批量修补 ⇒ 高亮「修补」段，进度以 N/M 显示；
            //   · 单条安装（在线安装 / 覆盖安装）⇒ 高亮「安装」段，无确定进度可报时以转圈呈现.
            ImportFlowBanner(stage: workingId != nil ? .install : .repair,
                             progress: flowProgress,
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
                    // 未修补包提示：本页的包都是**未修补的原始包**（只有 original.ipa，没有产物），
                    // 左滑可直接安装，用于对比「修补前」的安装行为（尤其是否弹出账户验证）。
                    // 判断：**允许 + 提示**，不阻断 —— 用户的用途就是测试未修补包的效果，
                    // 拦下来反而挡住了测试。App Store 加密包（cryptid=1）装了也可能闪退，
                    // 但这是用户要观察的现象本身，不是我们该替用户挡掉的错误。
                    Text("勾选后可修补或删除安装包；点一行即选中它. 左滑可在线安装、覆盖安装或删除安装包，安装后可能无法运行，或要求账户验证.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("已导入")
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
                                   primaryTitle: "修补（\(selected.count)）",
                                   primaryDisabled: selected.isEmpty || busy,
                                   primaryAction: { alert = .batchRepair(count: selected.count) }) {
                        // 底栏批量条**不提供在线安装**：在线安装是单包 OTA 通道（`itms-services` 清单
                        // 一次只服务一个包），多选批量语义不成立 —— 它只在行内 `.swipeActions` 提供
                        //（「已修补」页同理，见 RepairedListPage 底栏注释）。
                        // 与「有没有产物」无关：在线安装装的是**未修补原件**（`p.originalPath`），本就不需要产物。
                        // 「删除（N）」= 真删安装包（连同其产物与专属目录镜像），破坏性 ⇒ 先二次确认（见 `alertContent`）。
                        Button("删除（\(selected.count)）", role: .destructive) {
                            alert = .remove(items: selectedPackages)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selected.isEmpty || busy)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    // 未进选择态：留出底部间距，避免列表最后一项顶到 Tab 栏（照 ReclaimTabView:61-69）。
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
    }

    // MARK: - 子视图

    private var emptyRow: some View {
        // 空态与主页 `ImportView.emptySection` 同一套视觉语言（`InfoActionCard`），图标取本栏目自己的入口图标.
        InfoActionCard(
            icon: "tray.and.arrow.down",
            title: searchText.isEmpty ? "还没有导入过安装包." : "没有匹配 “\(searchText)” 的安装包.",
            message: "")
    }

    private func row(_ p: ImportedPackage) -> some View {
        // 行**恒为 `Button`**（`selecting` 只控制勾选圈显不显示，见 `rowBody`），
        // 首次点按由 `handleTap` 自动进入选择态 —— 与「已修补」页同一口径.
        // `.swipeActions` 与 `.contextMenu` 挂在行外层，与这个 `Button` 并存.
        VStack(alignment: .leading, spacing: 6) {
            Button {
                handleTap(p)
            } label: {
                rowBody(p)
            }
            .buttonStyle(.plain)
            .disabled(busy)

            // 行内不常驻大按钮：安装收进下方 `.swipeActions`，行回归「图标 + 标题 + chip」的干净形态.
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
        // 左滑（从右向左）三个动作：在线安装 / 覆盖安装 / 删除安装包。
        // 前两个对象都是**未修补的原件**（`originalPath`）—— 这正是本页存在的意义：
        // 让用户把未修补包直接装上，对比「修补前」的行为（尤其是否弹账户验证）。
        // 「删除安装包」= 单条删除入口（批量入口在底栏）；破坏性 ⇒ 走二次确认，不整滑触发.
        // 不做全滑（`allowsFullSwipe: false`）：三个动作语义不同，不能一滑就默认触发其中一个.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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

            // 「删除安装包」：复用本页既有的 `.remove` 确认弹窗（真删安装包 + 产物，不可恢复）.
            Button(role: .destructive) {
                alert = .remove(items: [p])
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

    /// 行主体（图标 + 标题 + chip）。抽出来只为让 `row` 能在外层挂 `.swipeActions` 与行尾转圈.
    private func rowBody(_ p: ImportedPackage) -> some View {
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
            return Alert(title: Text("删除确认"),
                         message: Text("将从本机删除这 \(items.count) 个安装包及其修补产物，并清除专属目录里的副本. 删除后无法恢复."),
                         primaryButton: .destructive(Text("删除")) { performDelete(items) },
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
        Task {
            let listing = await ImportedPackageScanner.scan()
            packages = listing.imported
            loading = false
            // 选择集只保留仍在列表里的条目，避免悬空选择。
            selected.formIntersection(Set(packages.map(\.id)))
            await loadIcons()
        }
    }

    /// 逐条解析图标（读 zip 成本高，放后台**串行**；已落盘的直接命中缓存文件）.
    /// 与 `IPADownloadManagerView.loadIcons` 同型：图标只是锦上添花，读不出就留空、界面回落首字母块.
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

    // MARK: - 安装（左滑：在线安装 / 覆盖安装）

    // 两个动作装的对象都是**未修补的原件**（`originalPath`），不是产物 —— 本页没有产物。
    // 这正是本页左滑安装的意义：把未修补包直接装上，对比「修补前」的行为。
    //
    // 两者是**两条独立通道**（不是同一个动作的两种叫法）：
    //   · 在线安装 → OTA / `itms-services`：本地 IPA 经本机 HTTP 服务器发出，
    //     清单托管到 HTTPS，由**系统**拉包安装。走系统通道，App Store 加密包会由系统
    //     向 Apple 请求许可 —— 用户要观察的「账户验证」就出在这条通道上.
    //   · 覆盖安装 → AFC 上传 + `installation_proxy`（RSD 隧道）直接交给 installd 装.
    //     加密包需要包内 `SC_Info/*.sinf`（用本机 Apple ID 下载的包才有），否则直接报错.

    /// 在线安装前置：有原件、且包内有应用标识（bundle id）。
    /// OTA 清单必须带 `bundle-identifier`，读不出就没法生成清单.
    private func canOnlineInstall(_ p: ImportedPackage) -> Bool {
        guard let path = p.originalPath, !path.isEmpty else { return false }
        return !(p.bundleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 覆盖安装前置：只要有原件就能装。
    /// 已装同款走 Upgrade，未装 / 状态未知走 Install，查不到清单不再是阻断理由.
    private func canInstallOrOverwrite(_ p: ImportedPackage) -> Bool {
        guard let path = p.originalPath, !path.isEmpty else { return false }
        return true
    }

    /// 行下方说明：某个安装通道**不可用**时给一句原因，让置灰的左滑按钮有解释；两个通道都可用就不显示，保持行干净.
    ///
    /// 覆盖安装只要有原件就能装（`canInstallOrOverwrite` 在原件非空时恒真），故本页唯一会置灰的是
    /// 「在线安装」—— OTA 清单必须带应用标识（`bundle-identifier`），读不出就没法生成清单。此时说明原因
    /// 并指出可改用覆盖安装。
    /// （改前此函数的非 nil 分支**不可达**：`guard` 已保证原件非空 ⇒ `canInstallOrOverwrite` 恒真 ⇒ 永远
    ///  `return nil`，于是置灰的「在线安装」按钮没有任何解释。现改为「按通道置灰即给原因」，让该分支可达。）
    private func installBlockReason(_ p: ImportedPackage) -> String? {
        // 防御分支：已导入块恒有原件（`ImportedPackageList.scanListing` 只在 hasOriginal 时入 imported），
        // 保留它是为了让「找不到原件」这种数据异常也能给出正确原因，而不是误报成「读不出应用标识」。
        guard let path = p.originalPath, !path.isEmpty else {
            return "找不到安装包，无法安装."
        }
        if !canOnlineInstall(p) {
            return "读不出应用标识，无法在线安装，可改用覆盖安装."
        }
        return nil
    }

    /// 在线安装（OTA / `itms-services`）：装的正是这份**未修补**的原件。
    /// `OnlineInstallService` 是本地路径驱动（`file://` 会起本机服务器发 IPA），
    /// 只给最终结果、**不给中间进度**，故 banner 以不确定态转圈呈现（见 `body`），不伪造进度条.
    private func runOnlineInstall(_ p: ImportedPackage) {
        guard canOnlineInstall(p), let path = p.originalPath, let bundleId = p.bundleId else { return }
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

    /// 覆盖安装：本地装这份**未修补**的原件。已装同款走 Upgrade（覆盖 / 升级），
    /// 未装或状态未知走 Install（全新安装）。多选时**逐条串行**，进度以 `N/M` 显示.
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
                guard let path = p.originalPath else { failed += 1; continue }
                // 已装同款 → Upgrade（覆盖 / 升级）；未装 / 状态未知 → Install（全新安装）.
                let upgrade = (p.isInstalled == true)
                do {
                    try await AppStoreInstallService.installLocalIPA(
                        path,
                        allowDowngrade: upgrade,
                        progress: { _ in },
                        onLog: { line in
                            // 日志归共享转换分类：installLocalIPA 自身不写日志，
                            // 此前这里传 `{ _ in }` 会把步骤全丢了，导致安装成败在本页日志里零记录.
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

    // MARK: - 批量修补（需求 #3 / #5）

    /// 对选中的包**逐条串行**修补并安装（修补是重 I/O，且会踩已知并发问题，不并发）。
    /// 每条各自走完整流程（含安装前确认）；进度以 `N/M` 显示。
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

                // 修补出产物即删原件（不再要求安装成功）—— 删与不删由
                // `deleteOriginalAfterRepairSuccess` 自证安全决定：产物不存在 / 非独立文件时不删.
                // `.skipped`（用户选择「只修补、不安装」）是**正常结束**且产物已生成，同样适用；
                // 原实现把它归进 else 报成失败，与 `RepairService` 的语义相反.
                ImportService.deleteOriginalAfterRepairSuccess(rec)
                if r.status == .ok || r.status == .skipped {
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
            resultText = "修补完成：成功 \(ok) 个，失败 \(failed) 个."
            reload()
        }
    }

    // MARK: - 删除安装包（需求 #3：已导入的删除 = 真删安装包 + 产物）

    /// 「删除安装包」：把所选包在本机的**全部落点**删掉（原件 / 修补产物 / `Documents/Repaired/` 镜像），
    /// 并按**实际结果**提示 —— 不做假成功。与「已修补」页**共用** `ImportedPackageDeleter`，
    /// 两页删除语义一致（同为 4 个落点、同一套二次确认、同一套失败可见）。
    ///
    /// 单条（左滑）与批量（底栏）共用本方法；删除前已由弹窗二次确认，不可恢复.
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
            case .failed:             failed += 1
            }
        }
        busy = false
        selected.removeAll()
        selecting = false
        resultText = failed == 0
            ? "已删除 \(ok) 个安装包."
            : "已删除 \(ok) 个安装包，\(failed) 个删除失败."
        // 失败必须**可见**（不静默）：与「已修补」页同一套提示，两页观感一致.
        ToastCenter.shared.show(failed == 0
            ? "已删除安装包"
            : "未删除安装包：\(failed) 个文件删除失败")
        reload()
    }

    // MARK: - 安装前确认（三步确认第三步）

    /// 挂起等待用户在弹窗上作答。唯一 resume 点是 `resumeInstall`（幂等：resume 后置 nil）。
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
