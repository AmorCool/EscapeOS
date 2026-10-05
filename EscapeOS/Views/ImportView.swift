import SwiftUI
import UniformTypeIdentifiers

// 共享转换 · 接收侧界面（导入 + 修补 + 安装）
//
// 三步确认（**不做「一键导入并安装」**）：
//   ① 导入前确认 → ② 修补前确认 → ③ 安装前确认（由 `RepairService.repair(confirmInstall:)` 在安装前 await）。
//
// 入口：更多 → 应用安装 →「共享转换」（见 MoreView）。
//
// 观感改造（v0.3.571）：复用仓库既有设计系统 —— `AppTheme.accent` / `LocusTheme` 语义色、
// `AppRowIcon`（圆角着色图标块）、`InfoActionCard`（空态卡）、以及 IPADownloadManagerView 的
// 胶囊 chip / 首字母块画法。**不另造配色**；状态用「颜色 + SF Symbol」区分，不用星形符号。

struct ImportView: View {

    @State private var showPicker = false
    @State private var pendingURL: URL?            // 待确认导入
    @State private var showImportConfirm = false

    @State private var importing = false
    @State private var importProgress: Double?     // nil = 不确定态（复制/解析阶段无进度上报）
    @State private var importProgressText = ""
    @State private var importResult: ImportResult?
    @State private var record: ImportRecord?

    @State private var showRepairConfirm = false
    @State private var repairing = false
    @State private var repairFraction: Double?     // 仅安装阶段有真实进度（见 RepairService）
    @State private var progressText = ""
    @State private var repairResult: RepairResult?

    @State private var showInstallConfirm = false
    @State private var installContinuation: CheckedContinuation<Bool, Never>?

    // 已导入 / 已修补的包。主页**只**用它们给「已导入 (N)」「已修补 (N)」两个入口计数；
    // 列表、选择、批量修补、移除、安装、导出全部在二级页 `ImportedListPage` / `RepairedListPage` 里。
    @State private var packages: [ImportedPackage] = []
    @State private var repairedPackages: [ImportedPackage] = []

    // 「扫描新文件」的候选（**只列举、不复制**）：扫到的包先落这里，由用户点「导入」才真正收进本机。
    // 旧实现把扫到的第一个包直接送进「导入前确认」⇒ 扫一遍 = 把 `Imports/` 里已存在的包再复制一份。
    @State private var scanCandidates: [URL] = []

    /// 「在线安装」前置检查结果（修补完成后算一次，驱动按钮可用性与说明）。
    /// 有产物 / 无产物 / 读不出应用标识三态 —— 点之前就给出结论，不让用户点了才报错。
    @State private var onlineReadiness: OnlineInstallReadiness = .noArtifact
    /// 「在线安装」发起后到回调返回之间为 true（防连点）。
    @State private var onlineInstalling = false

    /// D4：onOpenURL 导入成功时交接过来的记录，在**挂载 / 回前台**时消费（见 `consumePendingImport`）。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            flowSection
            if !scanCandidates.isEmpty { candidateSection }
            pendingLinkSection
            importedLinkSection
            repairedLinkSection
            if let importResult { importStatusSection(importResult) }
            if record == nil && importResult == nil && !importing && packages.isEmpty && repairedPackages.isEmpty { emptySection }
            if let record { packageSection(record) }
            if importing { importProgressSection }
            if repairing { progressSection }
            if let repairResult { resultSection(repairResult) }
            // 导出修补产物入口（需求 #14）：未修补时禁用并在页脚说明原因，已修补后可导出 repaired.ipa。
            if record != nil { RepairedPackageExportSection(repairResult: repairResult, record: record) }
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
                .disabled(importing || repairing)
                .accessibilityLabel("从文件导入")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scanNew()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(importing || repairing)
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
        // ① 导入前确认
        .alert("导入前确认", isPresented: $showImportConfirm) {
            Button("继续导入") { startImport() }
            Button("取消", role: .cancel) { pendingURL = nil }
        } message: {
            Text("你要导入的是别人给的安装包，不是从 App Store 下载的. 它可能被篡改或伪装，也可能带有别人的账号信息. 只导入来源可信的包.")
        }
        // ② 修补前确认
        .alert("修补前确认", isPresented: $showRepairConfirm) {
            Button("开始修补") { runRepair() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(repairConfirmMessage)
        }
        // ③ 安装前确认（由 RepairService 在调用 installd 之前 await）
        // 取消 = 「只修补，不安装」：产物已落盘、原件保留，按正常结束处理（不再当作半途退出）。
        .alert("安装前确认", isPresented: $showInstallConfirm) {
            Button("继续安装") { resumeInstall(true) }
            Button("只修补，不安装", role: .cancel) { resumeInstall(false) }
        } message: {
            Text("即将把这个应用安装到本机. 选择「只修补，不安装」会保留修补产物，稍后可在「已修补」里安装.")
        }
        // 兜底（审计 D1）：安装前确认挂起期间用户离开本页 / 对话框被关掉而**没点任何按钮** ⇒
        // continuation 永不 resume，`runRepair` 的 Task 会**永久挂起**（此时 sinf 已注入、安装未执行，
        // 包停在「已修补未安装」而 UI 已不在）。两处兜底都按「只修补，不安装」处理（保留产物，正常结束）。
        // `resumeInstall` 幂等（resume 后置 nil），与按钮作答、与两处兜底互相之间都不会重复 resume。
        .onChange(of: showInstallConfirm) { _, presented in
            if !presented { resumeInstall(false) }
        }
        .onDisappear { resumeInstall(false) }
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
        .onAppear { consumePendingImport(); reloadPackages() }
        .onChange(of: scenePhase) { _, _ in
            consumePendingImport(); reloadPackages()
        }
        .toastHost()
    }

    // MARK: - 状态

    /// 当前包所处的阶段（颜色 + 图标区分；**不用星形符号**）。
    private enum ShareStage {
        case empty, pending, repairing, repaired, installed, failed

        var title: String {
            switch self {
            case .empty:     return "未导入"
            case .pending:   return "待修补"
            case .repairing: return "修补中"
            case .repaired:  return "已修补"
            case .installed: return "已安装"
            case .failed:    return "失败"
            }
        }

        var symbol: String {
            switch self {
            case .empty:     return "tray"
            case .pending:   return "clock"
            case .repairing: return "wrench.and.screwdriver.fill"
            case .repaired:  return "checkmark.seal.fill"
            case .installed: return "checkmark.circle.fill"
            case .failed:    return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .empty:     return .secondary
            case .pending:   return .orange
            case .repairing: return AppTheme.accent
            case .repaired:  return LocusTheme.accent
            case .installed: return LocusTheme.statusGood
            case .failed:    return LocusTheme.statusBad
            }
        }
    }

    /// 由现有状态推导当前阶段。语义只看「有没有包 / 在不在跑 / 结果如何」，不引入新状态源。
    private var stage: ShareStage {
        if repairing { return .repairing }
        if let r = repairResult {
            switch r.status {
            case .ok:             return .installed   // RepairService 只在安装完成后才返回 .ok
            case .skipped:        return .repaired    // 只修补、未安装（用户选择不装，产物已保留）
            case .failed:         return .failed
            case .needsUserChoice: return .pending
            }
        }
        if let rec = record { return rec.repairedSha256 != nil ? .repaired : .pending }
        return .empty
    }

    /// 步骤条单个节点的状态
    private enum StepState {
        case idle, active, done

        var tint: Color {
            switch self {
            case .idle:   return .secondary
            case .active: return AppTheme.accent
            case .done:   return LocusTheme.statusGood
            }
        }
    }

    /// 「在线安装」的前置检查结果（三种态）。
    ///
    /// 判定只在**修补完成后算一次**（`IPAPackageInspector.inspect` 要读 ZIP 中央目录，
    /// 不能放进每次 body 求值的计算属性里），结果缓存在 `onlineReadiness`。
    private enum OnlineInstallReadiness {
        /// 产物在盘上、且能拿到应用标识 → 可点。
        case ready(ipaPath: String, bundleId: String)
        /// 没有修补产物（修补失败 / 产物被清理）→ 禁用并说明。
        case noArtifact
        /// 有产物，但包内与台账都读不出 bundle id → 禁用并说明。
        case noBundleId

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    // MARK: Sections

    /// 「修补前确认」的说明文案（v0.3.570：三态）。
    /// `encrypted == nil` 是「无法判定」，**不能**再说成「明文包」。
    private var repairConfirmMessage: String {
        switch record?.payload.encrypted {
        case .some(false):
            return "这是明文包，无需修补；确认后会直接安装到本机. 仅适用于来源可信的包."
        case .some(true):
            return "修补会把包内既有的解密授权写回 sinf 位置，然后安装到本机. 仅适用于与你登录相同 Apple ID 的设备分享的包."
        case nil:
            return "无法判定这个包是否加密（主二进制读不出）. 修补会在结构判定阶段停止，请重新获取一份完整的包."
        }
    }

    /// 顶部步骤条：导入 → 修补 → 安装。只做可视化，不承担任何动作语义。
    /// 当前处于流程的哪一段 —— 供共享组件 `ImportFlowBanner` 高亮。
    ///
    /// 映射依据（`ShareStage` 的实际 case：`empty / pending / repairing / repaired / installed / failed`）：
    ///   · 已修补 / 已安装 ⇒ 当前段是「安装」（导入与修补视为已完成）；
    ///   · 待修补 / 修补中 ⇒ 当前段是「修补」；
    ///   · 空 / 失败 ⇒ 当前段是「导入」（失败可能发生在任一步，回到起点最不误导）。
    private var flowStage: ImportFlowStage {
        switch stage {
        case .installed, .repaired: return .install
        case .pending, .repairing:  return .repair
        case .empty, .failed:       return .importFile
        }
    }

    /// 步骤条 —— 用共享组件（与三个二级页同一套观感，避免两处各画一份）。
    private var flowSection: some View {
        ImportFlowBanner(stage: flowStage)
    }

    // 旧的内联步骤条（flowStep / flowArrow）已删除 ——
    // 现在由共享组件 `ImportFlowBanner` 绘制，主页与三个二级页共用同一套观感。

    /// 「扫描到的新文件」候选区（**只列举、不复制**）：点「导入」才真正把这个包收进本机。
    /// 与「待修补」（`PendingRepairPage`）区分开 —— 这里是**还没进系统的新文件**，不是待修补的包。
    private var candidateSection: some View {
        Section {
            ForEach(scanCandidates, id: \.self) { url in
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "clock", tint: .orange, symbolSize: 16, frameSize: 30)
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
                    .disabled(importing || repairing)
                }
            }
        } header: {
            Text("扫描到的新文件 (\(scanCandidates.count))")
        } footer: {
            Text("扫描只列举、不复制；点「导入」才会把这个包收进本机.")
        }
    }

    /// 「待修补」栏目计数：已导入里还没修补、还没安装的那些（与 `PendingRepairPage` 数据源同口径）。
    private var awaitingRepairCount: Int {
        packages.filter { $0.status == .awaitingRepair }.count
    }

    /// 「待修补」栏目入口：点进去是二级页 `PendingRepairPage`（需求 #2 新增栏目）。
    private var pendingLinkSection: some View {
        Section {
            NavigationLink {
                PendingRepairPage()
            } label: {
                blockLabel("待修补", count: awaitingRepairCount,
                           symbol: "clock", tint: .orange)
            }
        } footer: {
            Text("点一行进入二级页：批量修补、移除（仅从列表移除，不删安装包）.")
        }
    }

    /// 「已导入」栏目入口：点进去是二级页 `ImportedListPage`（用户需求：不再内联展开 / 收拢）。
    /// 主页只留一行入口 + 计数；列表、选择、批量修补、移除都在二级页里。
    private var importedLinkSection: some View {
        Section {
            NavigationLink {
                ImportedListPage()
            } label: {
                blockLabel("已导入", count: packages.count,
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
                blockLabel("已修补", count: repairedPackages.count,
                           symbol: "checkmark.seal.fill", tint: LocusTheme.accent)
            }
        } footer: {
            Text("点一行进入二级页：在线安装 / 覆盖升级安装、导出.")
        }
    }

    /// 栏目入口标题：图标 + 「标题 (条数)」。
    private func blockLabel(_ title: String, count: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text("\(title) (\(count))")
                .font(.subheadline.weight(.semibold))
        }
    }

    /// 空态：还没导入任何包时给出明确引导，而不是一片空白。
    private var emptySection: some View {
        Section {
            InfoActionCard(
                icon: "tray.and.arrow.down",
                iconTint: AppTheme.accent,
                title: "还没有导入安装包",
                message: "从「文件」导入一个别人分享的 .ipa，或点「扫描新文件」找本机已有的包. 导入后这里会显示包信息与修补入口.",
                actionTitle: "从文件导入",
                action: { showPicker = true },
                disabled: importing || repairing)
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

    /// 包类型文案（v0.3.570：三态）—— `nil` 是「无法判定」，不再谎称「明文包」。
    private func payloadKindText(_ encrypted: Bool?) -> String {
        switch encrypted {
        case .some(true):  return "加密包"
        case .some(false): return "明文包"
        case nil:          return "未知（主二进制读不出）"
        }
    }

    private func payloadTint(_ encrypted: Bool?) -> Color {
        switch encrypted {
        case .some(true):  return .purple
        case .some(false): return .green
        case nil:          return .orange
        }
    }

    private func packageSection(_ rec: ImportRecord) -> some View {
        Section {
            packageCard(rec)
            Button {
                showRepairConfirm = true
            } label: {
                Label("开始修补", systemImage: "wrench.and.screwdriver")
            }
            // 需求 #17：修补成功后原件 `original.ipa` 已被删除，无从再次修补 —— 按钮禁用并说明。
            .disabled(repairing || !FileManager.default.fileExists(atPath: rec.storedPath))
        } header: {
            Text("安装包")
        } footer: {
            if !FileManager.default.fileExists(atPath: rec.storedPath) {
                Text("这个包已修补完成，原件已删除；如需重新修补请重新导入.")
            }
        }
    }

    /// 包卡片：首字母块 + 名称 + 版本/类型/授权胶囊 + 状态徽标 + 体检备注。
    private func packageCard(_ rec: ImportRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            monogram(rec.app.displayName ?? rec.storedFileName)

            VStack(alignment: .leading, spacing: 6) {
                Text(rec.app.displayName ?? rec.storedFileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if let v = rec.app.version { chip("v\(v)", .blue) }
                    chip(payloadKindText(rec.payload.encrypted), payloadTint(rec.payload.encrypted))
                    chip(rec.sinf.present ? "含授权" : "无授权", rec.sinf.present ? .green : .secondary)
                }

                if let b = rec.app.bundleId {
                    Text(b)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                ForEach(rec.trust.notes, id: \.self) { n in
                    Text(n)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
            stageBadge
        }
        .padding(.vertical, 4)
    }

    /// 状态徽标（胶囊，画法对齐 `AppTypeBadge`）。
    private var stageBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: stage.symbol)
                .font(.caption2.weight(.bold))
            Text(stage.title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(stage.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(stage.tint.opacity(0.14)))
        .fixedSize()
    }

    /// 导入进度（导入的复制/解析阶段无进度上报 → 不确定态转圈；有值则画确定态条）。
    private var importProgressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AppRowIcon(systemName: "square.and.arrow.down",
                               tint: AppTheme.accent, symbolSize: 16, frameSize: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在导入")
                            .font(.subheadline.weight(.medium))
                        if !importProgressText.isEmpty {
                            Text(importProgressText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let p = importProgress {
                    ProgressView(value: min(1, max(0, p)))
                        .tint(AppTheme.accent)
                } else {
                    ProgressView()
                        .tint(AppTheme.accent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 修补进度：只有安装阶段有真实分数（见 `RepairService`），其余阶段不确定态。
    private var progressSection: some View {
        Section("修补进度") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AppRowIcon(systemName: "wrench.and.screwdriver.fill",
                               tint: AppTheme.accent, symbolSize: 16, frameSize: 30)
                    Text(progressText.isEmpty ? "修补中" : progressText)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                if let f = repairFraction {
                    ProgressView(value: min(1, max(0, f)))
                        .tint(AppTheme.accent)
                } else {
                    ProgressView()
                        .tint(AppTheme.accent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func resultSection(_ r: RepairResult) -> some View {
        Section {
            statusRow(symbol: resultSymbol(r.status),
                      tint: resultTint(r.status),
                      title: r.message,
                      subtitle: r.suggestion)
            if let code = r.code {
                Text("原因码：\(code)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !r.details.isEmpty { detailsDisclosure(r.details) }
            onlineInstallRow
        } header: {
            Text("结果")
        } footer: {
            Text(onlineInstallFooter)
        }
    }

    // MARK: - 在线安装

    /// 「在线安装」入口。**默认流程不变**：这一步不会自动执行，只有用户主动点才发起。
    ///
    /// 三种前置状态（点之前就判好，不让用户点了才报错）：
    /// · 有产物 + 能读到 bundle id ⇒ 可点，走 `OnlineInstallService.install`；
    /// · 无产物 ⇒ 禁用，右侧标「无修补产物」；
    /// · 读不出 bundle id ⇒ 禁用，右侧标「读不出应用标识」。
    private var onlineInstallRow: some View {
        Button {
            guard case .ready(let ipaPath, let bundleId) = onlineReadiness else { return }
            performOnlineInstall(ipaPath: ipaPath, bundleId: bundleId)
        } label: {
            HStack(spacing: 10) {
                Label("在线安装", systemImage: "icloud.and.arrow.down")
                Spacer(minLength: 8)
                if onlineInstalling {
                    ProgressView().controlSize(.small)
                } else if let reason = onlineInstallBlockReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .disabled(!onlineReadiness.isReady || onlineInstalling)
    }

    /// 不可点时的原因（可点时返回 nil）。
    private var onlineInstallBlockReason: String? {
        switch onlineReadiness {
        case .ready:      return nil
        case .noArtifact: return "无修补产物"
        case .noBundleId: return "读不出应用标识"
        }
    }

    /// 说明「在线安装」与「本地安装」的区别（用户会问这两个有什么不同）。
    ///
    /// · 本地安装 = 本页「开始修补」流程里那一步，由本机直接把这个包装上去；
    /// · 在线安装 = 由系统按 OTA 方式装**同一份已修补的包**，两者装的包完全一样。
    private var onlineInstallFooter: String {
        switch onlineReadiness {
        case .ready:
            return "本地安装由本机直接装这个包（上面的修补流程就是）；在线安装让系统按 OTA 方式装同一份已修补的包. 两者装的包相同，按需选一种."
        case .noArtifact:
            return "在线安装需要先有修补产物. 完成上面的修补后，这里即可使用."
        case .noBundleId:
            return "这个包内读不出应用标识（bundle id），无法生成在线安装清单."
        }
    }

    /// 真正发起在线安装（OTA / `itms-services`）。
    ///
    /// **为什么不用 App Store 那条安装接口**：本仓另有一个同名的
    /// `AppStoreLocalInstallService.downloadAndInstall(item:email:)`，它是**按 bundleId 驱动**
    /// 的 —— 它会去商店**重新下载一份原始包**再装，我们刚修补好的产物会被整体丢弃。
    /// 而 `OnlineInstallService.install(ipaURL:bundleId:)` 是**本地路径驱动**的 OTA 通道：
    /// 前置只需要「本地 IPA + bundleId」，装的正是传进去的那个文件，因此才能用于修补包。
    private func performOnlineInstall(ipaPath: String, bundleId: String) {
        onlineInstalling = true
        let url = URL(fileURLWithPath: ipaPath)
        OnlineInstallService.install(ipaURL: url, bundleId: bundleId) { result in
            Task { @MainActor in
                onlineInstalling = false
                switch result {
                case .success:
                    ToastCenter.shared.show("正在安装")
                case .failure(let error):
                    ToastCenter.shared.show(error.localizedDescription)
                }
            }
        }
    }

    /// 修补完成后算一次「在线安装」前置检查结果。
    ///
    /// bundle id 取**包内 Info.plist** 优先（修补产物才是真正要装的包），
    /// 读不到再退回台账 `record.app.bundleId`；两者都空 ⇒ `.noBundleId`。
    private static func resolveOnlineReadiness(result: RepairResult,
                                               record: ImportRecord?) -> OnlineInstallReadiness {
        guard let path = result.repairedIPAPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return .noArtifact
        }
        let fromPackage = IPAPackageInspector.inspect(ipaPath: path)?.bundleIdentifier
        let bundleId = (fromPackage ?? record?.app.bundleId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleId, !bundleId.isEmpty else { return .noBundleId }
        return .ready(ipaPath: path, bundleId: bundleId)
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
        case .ok:             return LocusTheme.statusGood
        case .rejected:       return LocusTheme.statusBad
        case .needsUserChoice: return AppTheme.accent
        }
    }

    private func resultSymbol(_ s: RepairResult.Status) -> String {
        switch s {
        case .ok:             return "checkmark.seal.fill"
        case .failed:         return "xmark.octagon.fill"
        case .skipped:        return "checkmark.seal.fill"   // 只修补、未安装：正常结束态
        case .needsUserChoice: return "questionmark.circle.fill"
        }
    }

    private func resultTint(_ s: RepairResult.Status) -> Color {
        switch s {
        case .ok:             return LocusTheme.statusGood
        case .failed:         return LocusTheme.statusBad
        case .skipped:        return LocusTheme.accent
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

    /// 胶囊标签（画法复用 IPADownloadManagerView 的 `chip`）。
    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
            .fixedSize()
    }

    /// 无图标时的首字母块（画法复用 IPADownloadManagerView 的 `monogram`）。
    private func monogram(_ name: String) -> some View {
        let letter = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AppTheme.accent.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: 48, height: 48)
    }

    // MARK: Actions

    /// 消费 onOpenURL 交接过来的导入记录（审计 D4）。
    ///
    /// 目的：AirDrop /「用其他应用打开」导入成功的包**直接接上修补流程**（进入「待修补」态），
    /// 而不是让用户去点「扫描新文件」—— 那会把同一个包**再复制一份**（重复包 + 第一条 record 丢失）。
    ///
    /// **重入门禁**：正在导入 / 正在修补时**不覆盖当前状态**，并**保留挂起值**等下一次消费。
    /// 顺序很重要：必须先过门禁、再调 `consume()` —— 后者是「取走即清空」，一旦调用就没了。
    ///
    /// 幂等：`consume()` 取走后清空，因此同一条记录不会被接上两次（重复消费返回 nil）。
    /// 只接上记录，**不**自动修补 / 安装 —— 三步确认语义不变。
    private func consumePendingImport() {
        guard !importing, !repairing else { return }
        guard let rec = PendingImportHandoff.consume() else { return }
        importResult = nil      // 清掉上一轮的导入结果，避免旧消息与刚接上的包对不上
        repairResult = nil
        onlineReadiness = .noArtifact   // 换包了：上一轮产物的在线安装结论作废
        record = rec            // 进入「待修补」态（packageSection 里出现「开始修补」）
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
        repairResult = nil
        onlineReadiness = .noArtifact   // 换包了：上一轮产物的在线安装结论作废
        onlineInstalling = false
        Task {
            // Swift 6：progress 回调以 `@Sendable` 显式标注（非 MainActor 隔离），
            // 回主线程再写 @State —— 与 DeviceSlimView 的写法同型。
            let r = await ImportService.importFile(at: url, sourceKind: .picker) { @Sendable p, s in
                Task { @MainActor in
                    importProgress = p
                    importProgressText = s
                }
            }
            importing = false
            importProgress = nil
            importResult = r
            record = r.record
            reloadPackages()
            // 导入成功的候选已进系统（落进 `Imports/`），从候选区移除，避免「已导入」还挂在候选里。
            if r.status == .ok { scanCandidates.removeAll { $0 == url } }
            if r.status != .ok { ToastCenter.shared.show(r.message) }
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

    private func runRepair() {
        guard let rec = record else { return }
        repairing = true
        repairFraction = nil
        progressText = "修补中"
        repairResult = nil
        // 新一轮修补开始：在线安装的前置结论作废，等产物出来再算（避免拿上一轮产物误判可点）。
        onlineReadiness = .noArtifact
        onlineInstalling = false
        Task {
            let r = await ImportService.handOffToRepair(
                rec,
                runLaunchCheck: true,
                progress: { @Sendable p, s in
                    Task { @MainActor in
                        repairFraction = p
                        progressText = s
                    }
                },
                confirmInstall: { await awaitInstallConfirm() })
            repairing = false
            repairFraction = nil
            progressText = "完成"
            repairResult = r
            // 修补产物指纹回填到**新字段** `repairedSha256`；原件指纹 `sha256` 保持不变。
            if let sha = r.repairedIPASha256 { record?.repairedSha256 = sha }
            // 需求 #17：**修补成功**（.ok）后删除原件 `original.ipa`，条目随即移入「已修补」块
            // （reloadPackages 扫到该目录只剩 repaired.ipa 即归类）。只修补不装（.skipped）与失败绝不删 ——
            // 产物已在盘上，`ImportedPackageList` 按「有产物即归已修补」会自动归块。
            if r.status == .ok {
                ImportService.deleteOriginalAfterRepairSuccess(rec)
            }
            // 在线安装前置检查：产物是否在盘上、能否读到 bundle id（只在修补后算一次）。
            onlineReadiness = Self.resolveOnlineReadiness(result: r, record: record)
            reloadPackages()
            if r.status == .failed { ToastCenter.shared.show(r.message) }
        }
    }

    /// 安装前确认：挂起等待用户在 dialog 上作答。
    ///
    /// 注意： 唯一 resume 点是 `resumeInstall(_:)`。它同时被三个地方调用：对话框两个按钮、
    ///    以及 body 上的 `.onChange(of: showInstallConfirm)` / `.onDisappear` 两处兜底。
    ///    因此 `resumeInstall` **必须保持幂等**（resume 后立即置 nil）—— 否则任一路径重复触发
    ///    都会二次 resume 而崩溃（`CheckedContinuation` 二次 resume 是 fatalError）。
    @MainActor
    private func awaitInstallConfirm() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            installContinuation = cont
            showInstallConfirm = true
        }
    }

    /// 唯一的 resume 点；幂等（resume 后置 nil，重复调用是无害的 no-op）。
    private func resumeInstall(_ ok: Bool) {
        installContinuation?.resume(returning: ok)
        installContinuation = nil
    }

    // MARK: 主页栏目计数

    /// 刷新主页两个入口的计数：已导入（还有 `original.ipa`）与已修补（只剩 `repaired.ipa`）。
    /// 列表本体在二级页 `ImportedListPage` / `RepairedListPage`，这里只取 `count`。
    ///
    /// 「已安装」判定需要本机应用清单（`AppDiscovery`，依赖配对 / 隧道）；**查不到就传 nil**，
    /// `isInstalled` 保持 nil，绝不凭空断言已安装。扫描（判已安装时会解包读 bundleId）放后台。
    private func reloadPackages() {
        Task {
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
}
