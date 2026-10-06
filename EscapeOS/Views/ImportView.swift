import SwiftUI
import UniformTypeIdentifiers

// 共享转换 · 接收侧界面（主界面**只负责导入**）
//
// 用户澄清后的职责划分：
//   · 本页（主界面）**只做导入**，不再提供任何修补入口（用户原话：「不要在共享转换主界面那里修补」）；
//   · 导入成功后**自动进入「待修补」页**，修补 / 安装都在二级页里进行；
//   · 「导出修补后的安装包」已移出主界面 —— 「已修补」二级页支持选择导出（`RepairedListPage`）。
//
// 「待修补」的语义（用户澄清，与先前的「磁盘派生集合」不同）：
//   = **本次会话刚导入的 IPA 的临时队列**。
//   · `ImportView` 存活时队列保留（可来回切）；
//   · 退出「共享转换」（返回「更多」）时本视图销毁 ⇒ 队列自然丢弃；
//   · 丢弃**不代表包丢了** —— 包已落在 `Imports/`，用户可在「已导入」里继续修补。
//
// 入口：更多 → 应用安装 →「共享转换」（见 MoreView）。

struct ImportView: View {

    @State private var showPicker = false
    @State private var pendingURL: URL?            // 待确认导入
    @State private var showImportConfirm = false

    @State private var importing = false
    // 单包导入进度（0-1）。**当前恒为 nil** —— `ImportService` 无法上报（`copyItem` 是系统调用，
    // 拿不到内部进度；流式 sha256 同理）。此位与 `ImportFlowBanner.fraction` 的传参**保留为将来的接口**：
    // 若日后改为分块复制，往这里写值即可 —— **不要为了「有进度」而写死一个常量**（曾写死 0.5，是假进度）。
    @State private var importProgress: Double?     // nil = 不确定态（复制/解析阶段无进度上报）
    @State private var importProgressText = ""
    @State private var importResult: ImportResult?
    @State private var record: ImportRecord?

    // 已导入 / 已修补的包。主页**只**用它们给「已导入 (N)」「已修补 (N)」两个入口计数；
    // 列表、选择、批量修补、移除、安装、导出全部在二级页里。
    @State private var packages: [ImportedPackage] = []
    @State private var repairedPackages: [ImportedPackage] = []

    // 「待修补」= 本次会话刚导入的 IPA 的临时队列（用户澄清的语义）。
    // 只存**包名**（`ImportRecord.storedFileName` == `ImportedPackage.name`）；计数时再与磁盘现状
    // 求交 —— 这样包在二级页被修补 / 移除后，这里的计数会跟着降。
    // 作用域 = 本视图存活期间：退出「共享转换」（返回「更多」）时视图销毁 ⇒ 队列随之丢弃。
    // 丢弃**不等于包丢了** —— 包已落在 `Imports/`，用户可在「已导入」里继续修补。
    @State private var sessionPendingNames: Set<String> = []
    /// 导入成功后自动导航到「待修补」页（见 `startImport` / `consumePendingImport`）。
    @State private var showPendingRepair = false

    // 「扫描新文件」的候选（**只列举、不复制**）：扫到的包先落这里，由用户点「导入」才真正收进本机。
    @State private var scanCandidates: [URL] = []

    /// D4：onOpenURL 导入成功时交接过来的记录，在**挂载 / 回前台**时消费（见 `consumePendingImport`）。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            heroSection
            flowSection
            if !scanCandidates.isEmpty { candidateSection }
            pendingLinkSection
            importedLinkSection
            repairedLinkSection
            if let importResult { importStatusSection(importResult) }
            if record == nil && importResult == nil && !importing && packages.isEmpty && repairedPackages.isEmpty { emptySection }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("共享转换")
        .navigationBarTitleDisplayMode(.inline)
        // 右上角：导入 / 扫描 / 日志。原来「导入」栏目里的两个入口（从文件导入、扫描新文件）挪到这里。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(importing)
                .accessibilityLabel("从文件导入")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scanNew()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(importing)
                .accessibilityLabel("扫描新文件")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ShareConvertLogView()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("共享转换日志")
            }
        }
        .documentPicker(isPresented: $showPicker, allowedTypes: [.data]) { urls in
            requestImport(urls.first)
        }
        // 导入前确认（三步确认第一步）。修补 / 安装在二级页的修补流程里各自再确认一次。
        .alert("导入前确认", isPresented: $showImportConfirm) {
            Button("继续导入") { startImport() }
            Button("取消", role: .cancel) { pendingURL = nil }
        } message: {
            Text("你要导入的是别人给的安装包，不是从 App Store 下载的. 它可能被篡改或伪装，也可能带有别人的账号信息. 只导入来源可信的包.")
        }
        // 导入成功后自动进入「待修补」页（用户需求：导入的 IPA 暂时进「待修补」，不停在主界面）。
        // 队列所有权在本页：把 `sessionPendingNames` 的回写口一并传下去，二级页移除 / 修补成功
        // 才能把包名从队列里扣掉（否则计数不变、重进页面被移除的包会复活）。
        .navigationDestination(isPresented: $showPendingRepair) {
            PendingRepairPage(packages: sessionPendingPackages, pendingNames: $sessionPendingNames)
        }
        // D4：消费 onOpenURL 交接过来的导入记录（一次性，见 `PendingImportHandoff`）。
        // 三处互补，覆盖全部挂载/时序状态：
        //   · `onReceive` 覆盖「本页已挂载、AirDrop / 用其他应用打开把 App 从后台带回前台」
        //     那条路径 —— 此时 `scenePhase` 会**早于** `post` 触发（handleOpenURL 要复制整个
        //     IPA，耗时数秒），若只靠 `onChange(of: scenePhase)` 就会空消费一次、之后再无触发点，
        //     挂起值滞留 ⇒ 用户仍须点「扫描新文件」重复复制。裸通知在 `post` 当场唤醒本页。
        //   · `onAppear` 覆盖「通知发出时本页还没挂载」（那种情况通知会丢，但值还在，挂载时取走）。
        //   · `onChange(of: scenePhase)` 是零成本兜底。
        .onReceive(NotificationCenter.default.publisher(for: .escPendingImportHandoff)) { _ in
            consumePendingImport()
        }
        .onAppear { consumePendingImport(); Task { await reloadPackages() } }
        .onChange(of: scenePhase) { _, _ in
            consumePendingImport(); Task { await reloadPackages() }
        }
        .toastHost()
    }

    // MARK: Sections

    /// 主视觉 hero：只立模块身份（大号 tinted 图标 + 标题 + 一句说明），
    /// **不放**「从文件导入 / 扫描新文件」CTA —— 那两个动作的唯一入口是右上角 toolbar.
    private var heroSection: some View {
        Section {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "square.and.arrow.down.on.square",
                           tint: AppTheme.accent, symbolSize: 26, frameSize: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("共享转换")
                        .font(.title3.weight(.semibold))
                    Text("导入他人分享的 IPA，修补后安装到本机.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    /// 步骤条 —— 用共享组件（与三个二级页同一套观感，避免两处各画一份）。
    /// 只做可视化，不承担任何动作语义。
    ///
    /// 导入进度**直接画在「导入」段上**（用户澄清：进度要显示在步骤条里对应的那一段，而不是单独的进度区）：
    ///   · 有确定进度 ⇒ `fraction`；复制 / 解析阶段无进度上报 ⇒ `indeterminate` 转圈。
    private var flowSection: some View {
        ImportFlowBanner(stage: flowStage,
                         fraction: importProgress,
                         indeterminate: importing && importProgress == nil,
                         caption: importProgressText.isEmpty ? nil : importProgressText)
    }

    /// 当前处于流程的哪一段 —— 供共享组件 `ImportFlowBanner` 高亮。
    ///
    /// 本页只做「导入」；修补 / 安装在二级页（「待修补」/「已导入」/「已修补」）里进行。
    /// 高亮取「下一步在哪」：
    ///   · 正在导入 ⇒ 「导入」段；
    ///   · 已导入待修补 / 还有原件包 ⇒ 「修补」段；
    ///   · 只剩修补产物 ⇒ 「安装」段。
    private var flowStage: ImportFlowStage {
        if importing { return .importFile }
        if record != nil || !packages.isEmpty { return .repair }
        if !repairedPackages.isEmpty { return .install }
        return .importFile
    }

    /// 「扫描到的新文件」候选区（**只列举、不复制**）：点「导入」才真正把这个包收进本机。
    /// 与「待修补」区分开 —— 这里是**还没进系统的新文件**，不是待修补的包。
    private var candidateSection: some View {
        Section {
            ForEach(scanCandidates, id: \.self) { url in
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "clock", tint: AppTheme.pending, symbolSize: 16, frameSize: 30)
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("导入") {
                        requestImport(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(importing)
                }
            }
        } header: {
            Text("扫描到的新文件 (\(scanCandidates.count))")
        } footer: {
            Text("扫描只列举、不复制；点「导入」才会把这个包收进本机.")
        }
    }

    /// 「待修补」栏目计数：**本次会话刚导入、且还没修补**的包（用户澄清的会话队列语义）。
    private var sessionPendingCount: Int {
        sessionPendingPackages.count
    }

    /// 本次会话导入、且还没修补掉的包 —— 传给 `PendingRepairPage` 的**会话队列**。
    ///
    /// 与 `PendingRepairPage(packages:pendingNames:)` 的注入模式对接：传了它，那一页就**不扫盘**，
    /// 只显示这几个 —— 这样**主界面的计数与点进去看到的数量一致**。
    /// 队列的**真值在本页**（`sessionPendingNames`），二级页经 `pendingNames` 回写口扣名，
    /// 所以这里派生出的 `count` 会**同帧**跟着降.
    private var sessionPendingPackages: [ImportedPackage] {
        // 判据只有「本次会话导入过」一条 —— `sessionPendingNames` 本身就是该判据.
        // 不再叠加 `status == .awaitingRepair`：本机已装同 bundleId 时导入的包 status == .installed，
        // 叠加后会被滤掉 ⇒ 导入后自动进入的「待修补」页是空的 ⇒ 用户以为包丢了.
        // 已修补的包不会出现在这里：`packages` 是 `scanListing().imported` 块，其 status 只可能是
        // .awaitingRepair / .installed（该块 product 恒为 nil，见 `ImportedPackageList.make`）；
        // 包一经修补即整行移出该块（进 `repairedPackages`），故无需额外排除 .repaired.
        packages.filter { sessionPendingNames.contains($0.name) }
    }

    /// 「待修补」栏目入口：点进去是二级页 `PendingRepairPage`。
    /// 队列随本视图销毁而丢弃（见 `sessionPendingNames`）；页脚把「丢弃 ≠ 包没了」讲清楚。
    private var pendingLinkSection: some View {
        Section {
            NavigationLink {
                PendingRepairPage(packages: sessionPendingPackages, pendingNames: $sessionPendingNames)
            } label: {
                entryRow(title: "待修补", count: sessionPendingCount,
                         symbol: "clock", tint: AppTheme.pending)
            }
        } footer: {
            Text("本次会话导入的包暂存在这里，可来回切换. 退出「共享转换」后这个临时列表会清空，包仍在本机，可在「已导入」里继续修补.")
        }
    }

    /// 「已导入」栏目入口：点进去是二级页 `ImportedListPage`。
    /// 主页只留一行入口 + 计数；列表、选择、批量修补、移除都在二级页里。
    private var importedLinkSection: some View {
        Section {
            NavigationLink {
                ImportedListPage()
            } label: {
                entryRow(title: "已导入", count: packages.count,
                         symbol: "tray.and.arrow.down", tint: AppTheme.accent)
            }
        } footer: {
            Text("点一行进入二级页：查看、选择、批量修补、移除.")
        }
    }

    /// 「已修补」栏目入口：点进去是二级页 `RepairedListPage`。
    /// 主页只留一行入口 + 计数；在线安装 / 覆盖升级安装、导出都在二级页里。
    private var repairedLinkSection: some View {
        Section {
            NavigationLink {
                RepairedListPage()
            } label: {
                entryRow(title: "已修补", count: repairedPackages.count,
                         symbol: "checkmark.seal.fill", tint: AppTheme.success)
            }
        } footer: {
            Text("点一行进入二级页：安装或导出已修补的包.")
        }
    }

    /// 入口行：tinted 圆角图标 + 标题 + 尾部次要计数。
    /// 与 `HomeView` 卡片图标、`statusRow` 同源，避免入口行长得像系统设置项.
    private func entryRow(title: String, count: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: symbol, tint: tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// 空态：还没导入任何包时给出明确引导，而不是一片空白。
    private var emptySection: some View {
        Section {
            InfoActionCard(
                icon: "tray.and.arrow.down",
                iconTint: AppTheme.accent,
                title: "还没有导入安装包",
                message: "从「文件」导入一个别人分享的 .ipa，或点「扫描新文件」找本机已有的包. 导入后会自动进入「待修补」.",
                actionTitle: "从文件导入",
                action: { showPicker = true },
                disabled: importing)
        }
    }

    private func importStatusSection(_ r: ImportResult) -> some View {
        Section("导入结果") {
            statusRow(symbol: importSymbol(r.status),
                      tint: importTint(r.status),
                      title: r.message,
                      subtitle: r.suggestion)
            if !r.details.isEmpty { detailsDisclosure(r.details) }
        }
    }

    /// 结果行：着色图标块 + 一句人话 + 一句建议。
    private func statusRow(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AppRowIcon(systemName: symbol, tint: tint, symbolSize: 18, frameSize: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func importSymbol(_ s: ImportResult.Status) -> String {
        switch s {
        case .ok:             return "checkmark.seal.fill"
        case .rejected:       return "xmark.octagon.fill"
        case .needsUserChoice: return "questionmark.circle.fill"
        }
    }

    private func importTint(_ s: ImportResult.Status) -> Color {
        switch s {
        case .ok:             return AppTheme.success
        case .rejected:       return AppTheme.danger
        case .needsUserChoice: return AppTheme.accent
        }
    }

    private func detailsDisclosure(_ lines: [String]) -> some View {
        DisclosureGroup("详情") {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    /// 消费 onOpenURL 交接过来的导入记录（审计 D4）。
    ///
    /// 目的：AirDrop /「用其他应用打开」导入成功的包**直接接上修补流程**（进入「待修补」态），
    /// 而不是让用户去点「扫描新文件」—— 那会把同一个包**再复制一份**（重复包 + 第一条 record 丢失）。
    ///
    /// **重入门禁**：正在导入时**不覆盖当前状态**，并**保留挂起值**等下一次消费。
    /// 顺序很重要：必须先过门禁、再调 `consume()` —— 后者是「取走即清空」，一旦调用就没了。
    ///
    /// 幂等：`consume()` 取走后清空，因此同一条记录不会被接上两次（重复消费返回 nil）。
    /// 只接上记录并**自动进入「待修补」页**，**不**自动修补 / 安装 —— 三步确认语义不变。
    private func consumePendingImport() {
        guard !importing else { return }
        guard let rec = PendingImportHandoff.consume() else { return }
        importResult = nil      // 清掉上一轮的导入结果，避免旧消息与刚接上的包对不上
        record = rec            // 进入「待修补」态
        sessionPendingNames.insert(rec.storedFileName)   // 进本次会话的「待修补」队列
        // 等扫盘完成再导航（缺陷 1）：`sessionPendingPackages` 由 `packages` 派生，抢在扫盘前导航会把
        // **空数组**注进二级页 ⇒ 页面开成空的。扫盘完成后本页计数会变，但二级页的注入数组是 init 时
        // 定格的，不会自己回补（直到退出重进）—— 所以必须在 `packages` 就绪后再置位 `showPendingRepair`.
        Task {
            await reloadPackages()
            showPendingRepair = true   // 自动进入「待修补」页
        }
    }

    /// 发起一次「从文件导入」：记下待导入 URL 并弹出导入前确认。
    ///
    /// **唯一**设置 `showImportConfirm` 的地方 —— 文件选择器与「扫描到的新文件」候选的「导入」都走这里。
    /// 「扫描新文件」**不**经过此函数（扫描只列举、不复制，见 `scanNew`）。
    private func requestImport(_ url: URL?) {
        guard let url else { return }
        pendingURL = url
        showImportConfirm = true
    }

    private func startImport() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        importing = true
        importProgress = nil
        importProgressText = ""
        importResult = nil
        record = nil
        Task {
            // 不传 progress 回调：导入阶段无可测的确定进度（复制 / 流式 sha256 都拿不到内部进度），
            // 传一个永不触发的闭包只会让下一个人以为「这里有进度上报」。UI 无进度时走 indeterminate（见 flowSection）。
            let r = await ImportService.importFile(at: url, sourceKind: .picker)
            importing = false
            importProgress = nil
            importResult = r
            record = r.record
            await reloadPackages()   // 先等扫盘完成，`packages` 就绪后再决定是否导航（见下）
            if r.status == .ok {
                // 导入成功：收进「待修补」队列，自动进入「待修补」页（用户需求）。
                if let rec = r.record { sessionPendingNames.insert(rec.storedFileName) }
                // 已进系统的候选从候选区移除，避免「已导入」还挂在候选里。
                scanCandidates.removeAll { $0 == url }
                // 缺陷 1：必须等扫盘完成再导航 —— `sessionPendingPackages` 由 `packages` 派生，
                // 若在扫盘前就置位，注入的是空数组，二级页会开成空的（见 `reloadPackages` 注释）.
                showPendingRepair = true
            } else {
                ToastCenter.shared.show(r.message)
            }
        }
    }

    /// 「扫描新文件」：**只列举、不复制**。
    ///
    /// 扫到的包进「扫描到的新文件」候选区（`scanCandidates`），由用户点「导入」才真正收进本机；
    /// 扫描本身**绝不**触发导入 / 复制 —— 旧实现把扫到的第一个包直接送进「导入前确认」，
    /// 于是「扫一遍」就等于把 `Imports/` 里已存在的包**再复制一份**（重复包 + 第一条记录丢失）。
    ///
    /// **去重**：候选区只留「`ImportedPackageList` 覆盖不到的」那些（即**还没进系统的新文件**），
    /// 已能从 `Imports/` 列出来的包一律滤掉 —— 否则候选区与「已导入 / 待修补」两处重复展示。
    private func scanNew() {
        // 把本次会话已导入的包排除掉（否则「扫描新文件」会反复选中同一个旧包）。
        let known = record.map { [$0] } ?? []
        let result = ImportService.scanForNewImports(known: known)
        // 读不出来 ≠ 确定没有：只要有任何目录枚举失败，就**不能**落入「没有新包」分支，
        // 否则用户会把「没能观察到」当成「确实没有」而漏掉真正存在的包。
        guard result.unreadableDirectories.isEmpty else {
            ToastCenter.shared.show("无法读取导入目录，未能确认是否有新包，请重试")
            return
        }
        // 已进系统的包名（来自 `ImportedPackageList.scanListing()`，两个块合并）—— 用于去重。
        let listed = ImportedPackageList.scanListing(installedBundleIds: nil)
        let knownNames = Set((listed.imported + listed.repaired).map(\.name))
        let fresh = result.urls.filter { !knownNames.contains(Self.packageName(ofCandidate: $0)) }
        scanCandidates = fresh
        ToastCenter.shared.show(fresh.isEmpty
            ? "没有发现新的安装包"
            : "发现 \(fresh.count) 个新文件")
    }

    /// 候选 URL → **包名**（去重比对键）。
    ///
    /// 用包名而不是 `url.lastPathComponent`：`ImportedPackageList.name` 是包名，而候选 URL 的末段
    /// 在两种落点形态下不一致（新落点是 `original.ipa`、老平铺是 `<包名>.ipa`）——只有「归一化到包名」
    /// 这一个键能同时匹配两者：
    ///   · `Imports/<包名>/original.ipa` ⇒ 取**父目录名**；
    ///   · `Imports/<包名>.ipa` / `Documents/<包名>.ipa` ⇒ 取**去扩展名的文件名**。
    private static func packageName(ofCandidate url: URL) -> String {
        url.lastPathComponent == "original.ipa"
            ? url.deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
    }

    // MARK: 主页栏目计数

    /// 刷新主页两个入口的计数：已导入（还有 `original.ipa`）与已修补（只剩 `repaired.ipa`）。
    /// 列表本体在二级页 `ImportedListPage` / `RepairedListPage`，这里只取 `count`。
    ///
    /// 「已安装」判定需要本机应用清单（`AppDiscovery`，依赖配对 / 隧道）；**查不到就传 nil**，
    /// `isInstalled` 保持 nil，绝不凭空断言已安装。扫描（判已安装时会解包读 bundleId）放后台。
    ///
    /// **async**：导入 / 接续成功后要「等它完成再导航」（见 `startImport` / `consumePendingImport`）——
    /// `sessionPendingPackages` 由 `packages` 派生，不等它跑完就置位 `showPendingRepair` 会把空数组
    /// 注进二级页。调用方在后台即可 `await`；`onAppear` / `onChange` 里用 `Task { await ... }` 兜住.
    private func reloadPackages() async {
        let installed: Set<String>? = await Task.detached(priority: .userInitiated) { () -> Set<String>? in
            do { return Set(try AppDiscovery().fetchInstalledApps().map(\.bundleIdentifier)) }
            catch { return nil }
        }.value
        let listing = await Task.detached(priority: .userInitiated) {
            ImportedPackageList.scanListing(installedBundleIds: installed)
        }.value
        packages = listing.imported
        repairedPackages = listing.repaired
    }
}
