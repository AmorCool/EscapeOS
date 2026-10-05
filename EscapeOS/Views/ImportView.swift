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

    // 已导入的包列表（用户需求：把已导入的包列出来）
    // 两个块：`packages` = 已导入（还有 original.ipa，可修补）；`repairedPackages` = 已修补
    // （原件已按需求 #17 删除，只剩 repaired.ipa，只支持安装）。
    @State private var packages: [ImportedPackage] = []
    @State private var repairedPackages: [ImportedPackage] = []
    @State private var preparingPackageId: String?   // 正在重读原件、准备进入修补流程

    // 需求 #18：两个块可展开 / 收拢。默认展开「已导入」（待办），收拢「已修补」（已完成，条目多时不占屏）。
    @State private var importedExpanded = true
    @State private var repairedExpanded = false

    // 需求 #19：已导入列表多选 + 批量修补（逐条串行）。
    @State private var selectedPackageIds: Set<String> = []
    @State private var showBatchRepairConfirm = false
    @State private var batchRepairing = false
    @State private var batchProgressText = ""
    @State private var batchLog: [BatchLogItem] = []

    // 需求 #20：已修补条目的安装状态（在线安装 / 覆盖升级各自一条在跑）。
    @State private var onlineInstallingPackageId: String?
    @State private var installingPackageId: String?

    /// 页面是否仍在屏上。批量修补逐条串行时用它兜底：中途离开本页就停止后续条目，
    /// 避免「安装前确认」对话框已无处可显示、`CheckedContinuation` 永久挂起。
    @State private var viewActive = true

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
            pickerSection
            importedSection
            repairedSection
            if !batchLog.isEmpty { batchResultSection }
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
        // 右上角「日志板块」入口：只打开共享转换这一类的日志（`ShareConvertLogView`
        // 内部按 `.shareConvert` 分类筛），与 AppStore 商店日志互不串台。
        .toolbar {
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
            guard let u = urls.first else { return }
            pendingURL = u
            showImportConfirm = true
        }
        // ① 导入前确认
        .confirmationDialog("导入前确认", isPresented: $showImportConfirm, titleVisibility: .visible) {
            Button("继续导入") { startImport() }
            Button("取消", role: .cancel) { pendingURL = nil }
        } message: {
            Text("你要导入的是别人给的安装包，不是从 App Store 下载的. 它可能被篡改或伪装，也可能带有别人的账号信息. 只导入来源可信的包.")
        }
        // ② 修补前确认
        .confirmationDialog("修补前确认", isPresented: $showRepairConfirm, titleVisibility: .visible) {
            Button("开始修补") { runRepair() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(repairConfirmMessage)
        }
        // ② 修补前确认（批量，需求 #19）：同样在动手前确认一次；每条安装前仍会各自再确认一次。
        .confirmationDialog("修补前确认", isPresented: $showBatchRepairConfirm, titleVisibility: .visible) {
            Button("开始修补") { runBatchRepair() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将对选中的 \(selectedPackageIds.count) 个安装包逐个修补并安装；每个在安装前还会再确认一次. 仅适用于来源可信、且与你登录相同 Apple ID 的设备分享的包.")
        }
        // ③ 安装前确认（由 RepairService 在调用 installd 之前 await）
        .confirmationDialog("安装前确认", isPresented: $showInstallConfirm, titleVisibility: .visible) {
            Button("继续安装") { resumeInstall(true) }
            Button("取消", role: .cancel) { resumeInstall(false) }
        } message: {
            Text("即将把这个应用安装到本机.")
        }
        // 兜底（审计 D1）：安装前确认挂起期间用户离开本页 / 对话框被关掉而**没点任何按钮** ⇒
        // continuation 永不 resume，`runRepair` 的 Task 会**永久挂起**（此时 sinf 已注入、安装未执行，
        // 包停在「已修补未安装」而 UI 已不在）。两处兜底都按「取消安装」处理。
        // `resumeInstall` 幂等（resume 后置 nil），与按钮作答、与两处兜底互相之间都不会重复 resume。
        .onChange(of: showInstallConfirm) { _, presented in
            if !presented { resumeInstall(false) }
        }
        .onDisappear { viewActive = false; resumeInstall(false) }
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
        .onAppear { viewActive = true; consumePendingImport(); reloadPackages() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewActive = true }
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
            case .skipped:        return .repaired    // 已修补但用户取消了安装
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

    /// 批量修补里单条的成败（需求 #19：每条分别可见，不用一个总的「完成 / 失败」）。
    private enum BatchOutcome {
        case success
        case failed(String)

        var text: String {
            switch self {
            case .success:        return "成功"
            case .failed:         return "失败"
            }
        }

        var symbol: String {
            switch self {
            case .success:        return "checkmark.circle.fill"
            case .failed:         return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success:        return LocusTheme.statusGood
            case .failed:         return LocusTheme.statusBad
            }
        }

        /// 失败原因（成功时为 nil）。
        var reason: String? {
            if case .failed(let r) = self { return r }
            return nil
        }
    }

    /// 批量修补结果里的一行。
    private struct BatchLogItem: Identifiable {
        let id: String
        let name: String
        let outcome: BatchOutcome
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
    private var flowSection: some View {
        Section {
            HStack(spacing: 0) {
                flowStep("导入", "square.and.arrow.down",
                         state: record != nil ? .done : (importing ? .active : .idle))
                flowArrow
                flowStep("修补", "wrench.and.screwdriver",
                         state: stage == .repaired || stage == .installed ? .done
                              : (stage == .pending || stage == .repairing ? .active : .idle))
                flowArrow
                flowStep("安装", "checkmark.circle",
                         state: stage == .installed ? .done
                              : (stage == .repaired ? .active : .idle))
            }
            .padding(.vertical, 6)
        } footer: {
            Text("三步都需你确认，包来源要可信.")
        }
    }

    private func flowStep(_ title: String, _ symbol: String, state: StepState) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(state.tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: state == .done ? "checkmark" : symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.tint)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(state.tint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var flowArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var pickerSection: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                Label("从文件导入", systemImage: "square.and.arrow.down")
            }
            .disabled(importing || repairing)

            Button {
                scanNew()
            } label: {
                Label("扫描新文件", systemImage: "arrow.clockwise")
            }
            .disabled(importing || repairing)
        } header: {
            Text("导入")
        } footer: {
            Text("把你从别处收到的 .ipa 放到本机后，从这里导入.")
        }
    }

    /// 已导入的包列表（可折叠块，需求 #18）：每行 包名 / 状态 / 导入时间 / 大小。
    ///
    /// 有原件 `original.ipa` 的包落在这里，可修补、可勾选批量修补（需求 #19）。
    /// 状态与元数据都来自 `ImportedPackageList.scanListing` 的磁盘证据（见该文件），本视图不另做推断。
    private var importedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $importedExpanded) {
                if packages.isEmpty {
                    Text("还没有导入过安装包.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(packages) { p in
                        importedRowView(p)
                    }
                    batchControls
                }
            } label: {
                blockLabel("已导入", count: packages.count,
                           symbol: "tray.and.arrow.down", tint: AppTheme.accent)
            }
        } footer: {
            Text("勾选后可批量修补；点一行进入这个包的修补流程.")
        }
    }

    /// 已修补的包列表（可折叠块，需求 #18）：原件已删、只剩 `repaired.ipa`。
    ///
    /// 需求 #20：这里只提供**在线安装**与**覆盖/升级安装**；不提供重新修补与本地安装 ——
    /// 已修补的包无需再修，且原件已按需求 #17 删除，重新修补无从下手。
    private var repairedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $repairedExpanded) {
                ForEach(repairedPackages) { p in
                    repairedRow(p)
                }
            } label: {
                blockLabel("已修补", count: repairedPackages.count,
                           symbol: "checkmark.seal.fill", tint: LocusTheme.accent)
            }
        } footer: {
            Text("已修补的包只支持在线安装与覆盖/升级安装；原件已删除，不再提供重新修补.")
        }
    }

    /// 折叠块标题：图标 + 「标题 (条数)」。
    private func blockLabel(_ title: String, count: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text("\(title) (\(count))")
                .font(.subheadline.weight(.semibold))
        }
    }

    /// 批量修补结果（需求 #19）：每条分别给出成败，不用一个总的「完成 / 失败」。
    private var batchResultSection: some View {
        Section {
            ForEach(batchLog) { item in
                HStack(alignment: .top, spacing: 10) {
                    AppRowIcon(systemName: item.outcome.symbol, tint: item.outcome.tint,
                               symbolSize: 14, frameSize: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let reason = item.outcome.reason {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    chip(item.outcome.text, item.outcome.tint)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("批量修补结果")
        }
    }

    /// 已导入行：左侧勾选框（多选，需求 #19）+ 行体（点进入修补流程）。
    private func importedRowView(_ p: ImportedPackage) -> some View {
        let locked = importing || repairing || batchRepairing || preparingPackageId != nil
        return HStack(spacing: 10) {
            Button {
                toggleSelection(p)
            } label: {
                Image(systemName: selectedPackageIds.contains(p.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selectedPackageIds.contains(p.id)
                                     ? AppTheme.accent
                                     : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityLabel(selectedPackageIds.contains(p.id) ? "取消选择" : "选择")

            Button {
                openPackage(p)
            } label: {
                importedRow(p)
            }
            .buttonStyle(.plain)
            .disabled(locked)
        }
    }

    private func importedRow(_ p: ImportedPackage) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: importedStatusSymbol(p.status),
                       tint: importedStatusTint(p.status),
                       symbolSize: 16, frameSize: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(p.importedAt.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(p.sizeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // 批量修补里这条失败的原因（成功条目已移出本块，不在此行）。
                if let reason = failedReason(for: p.id) {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(LocusTheme.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if preparingPackageId == p.id {
                ProgressView()
            } else {
                chip(p.status.text, importedStatusTint(p.status))
            }
        }
        .contentShape(Rectangle())
    }

    /// 批量修补里某条的失败原因（成功 / 未参与时为 nil）。
    private func failedReason(for id: String) -> String? {
        batchLog.first { $0.id == id }?.outcome.reason
    }

    /// 已修补行（需求 #20）：只给「在线安装」「覆盖/升级安装」两个入口。
    private func repairedRow(_ p: ImportedPackage) -> some View {
        let busy = installingPackageId == p.id || onlineInstallingPackageId == p.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "checkmark.seal.fill",
                           tint: LocusTheme.accent, symbolSize: 16, frameSize: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(p.importedAt.formatted(date: .numeric, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(p.sizeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                chip(p.status == .installed ? "已安装" : "已修补",
                     p.status == .installed ? LocusTheme.statusGood : LocusTheme.accent)
            }

            HStack(spacing: 8) {
                Button {
                    performRepairedOnlineInstall(p)
                } label: {
                    Label("在线安装", systemImage: "icloud.and.arrow.down")
                }
                .disabled(!canOnlineInstall(p) || busy)

                Button {
                    performOverwriteInstall(p)
                } label: {
                    Label("覆盖/升级安装", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canOverwriteInstall(p) || busy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if busy {
                ProgressView().controlSize(.small)
            } else if let reason = repairedInstallBlockReason(p) {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// 批量修补控制条（需求 #19）：显示进度，或「批量修补 (n)」入口。
    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if batchRepairing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(batchProgressText.isEmpty ? "批量修补中" : batchProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        showBatchRepairConfirm = true
                    } label: {
                        Text("批量修补（\(selectedPackageIds.count)）")
                    }
                    .disabled(selectedPackageIds.isEmpty || importing || repairing)

                    if !selectedPackageIds.isEmpty {
                        Button("清除选择") { selectedPackageIds.removeAll() }
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// 状态图标（语义对齐本页 `ShareStage`：待修补=clock / 已修补=seal / 已安装=check）。
    private func importedStatusSymbol(_ s: ImportedPackage.Status) -> String {
        switch s {
        case .awaitingRepair: return "clock"
        case .repaired:       return "checkmark.seal.fill"
        case .installed:      return "checkmark.circle.fill"
        }
    }

    private func importedStatusTint(_ s: ImportedPackage.Status) -> Color {
        switch s {
        case .awaitingRepair: return .orange
        case .repaired:       return LocusTheme.accent
        case .installed:      return LocusTheme.statusGood
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
                    Text(progressText.isEmpty ? "修补并安装中" : progressText)
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

    // MARK: - 已修补条目的安装（需求 #20）

    /// 「已修补」条目**只**提供在线安装与覆盖/升级安装：
    ///   · 不提供重新修补 —— 已修补的包无需再修，且原件已按需求 #17 删除，无从下手；
    ///   · 不提供本地安装（修补流程里那一步）—— 它属于「开始修补」链路，不属于已修补清单。
    ///
    /// 在线安装前置：包内有应用标识（bundle id）。
    private func canOnlineInstall(_ p: ImportedPackage) -> Bool {
        guard let path = p.repairedPath, !path.isEmpty else { return false }
        return !(p.bundleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 覆盖/升级安装前置：本机已装同 bundleId 的应用（否则无「已装」可覆盖）。
    /// `isInstalled == nil`（查不到清单）时不可点，不让用户点了才报错。
    private func canOverwriteInstall(_ p: ImportedPackage) -> Bool {
        guard let path = p.repairedPath, !path.isEmpty else { return false }
        return p.isInstalled == true
    }

    /// 已修补条目不可安装时的原因（两个入口都可用时返回 nil）。
    private func repairedInstallBlockReason(_ p: ImportedPackage) -> String? {
        if let path = p.repairedPath, !path.isEmpty, canOnlineInstall(p), canOverwriteInstall(p) {
            return nil
        }
        guard let path = p.repairedPath, !path.isEmpty else {
            return "找不到修补产物，无法安装."
        }
        var reasons: [String] = []
        if !canOnlineInstall(p) { reasons.append("包内读不出应用标识，无法在线安装") }
        if !canOverwriteInstall(p) {
            reasons.append(p.isInstalled == nil
                           ? "无法确认本机安装状态，覆盖升级不可用"
                           : "本机未安装同款应用，无法覆盖升级")
        }
        return reasons.joined(separator: "；") + "."
    }

    /// 已修补条目的在线安装（OTA / `itms-services`，装的就是这份修补产物）。
    private func performRepairedOnlineInstall(_ p: ImportedPackage) {
        guard canOnlineInstall(p), let path = p.repairedPath,
              let bundleId = p.bundleId else { return }
        onlineInstallingPackageId = p.id
        let url = URL(fileURLWithPath: path)
        OnlineInstallService.install(ipaURL: url, bundleId: bundleId) { result in
            Task { @MainActor in
                onlineInstallingPackageId = nil
                switch result {
                case .success:
                    ToastCenter.shared.show("正在安装")
                case .failure(let error):
                    ToastCenter.shared.show(error.localizedDescription)
                }
            }
        }
    }

    /// 已修补条目的覆盖/升级安装：本地装这份产物，覆盖本机已装的同 bundleId 应用。
    /// `allowDowngrade: true` 走 installd 的 Upgrade 命令，正是「覆盖 / 升级」语义。
    private func performOverwriteInstall(_ p: ImportedPackage) {
        guard canOverwriteInstall(p), let path = p.repairedPath else { return }
        installingPackageId = p.id
        Task {
            do {
                try await AppStoreInstallService.installLocalIPA(
                    path,
                    allowDowngrade: true,
                    progress: { _ in },
                    onLog: { _ in })
                ToastCenter.shared.show("覆盖/升级安装完成")
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
            installingPackageId = nil
            reloadPackages()
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
        case .skipped:        return "pause.circle.fill"
        case .needsUserChoice: return "questionmark.circle.fill"
        }
    }

    private func resultTint(_ s: RepairResult.Status) -> Color {
        switch s {
        case .ok:             return LocusTheme.statusGood
        case .failed:         return LocusTheme.statusBad
        case .skipped:        return .orange
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
            if r.status != .ok { ToastCenter.shared.show(r.message) }
        }
    }

    private func scanNew() {
        // 把本次会话已导入的包排除掉（否则「扫描新文件」会反复选中同一个旧包）。
        // 已知限制（登记 D5，非缺陷）：`known` **只含当前这一条 record**，所以「已在 Imports/ 但
        // 不是当前 record」的包会被当成新包**再复制一份**（例：导入 A → 导入 B → 点扫描 → 生成
        // `A 2.ipa`）；**单线程即可命中**，不需要并发。重启后 `record` 为 nil、`known` 为空，
        // `Imports/` 里的包会**全部**被当成新的（比 A→B 更常见）。
        // 后果只是多一个重复文件，**不是数据丢失**（原包仍在 `Imports/`，仍可修补）。
        // 治本 = `ImportRecord` 持久化（D5）。注意：把 `PendingImportHandoff` 的单槽改成队列
        // **收不了这个问题** —— 队列只解决并发覆盖，管不到 `known` 的单条语义，别再走那条路。
        let known = record.map { [$0] } ?? []
        let result = ImportService.scanForNewImports(known: known)
        // 读不出来 ≠ 确定没有：只要有任何目录枚举失败，就**不能**落入「没有新包」分支，
        // 否则用户会把「没能观察到」当成「确实没有」而漏掉真正存在的包。
        guard result.unreadableDirectories.isEmpty else {
            ToastCenter.shared.show("无法读取导入目录，未能确认是否有新包，请重试")
            return
        }
        guard let first = result.urls.first else {
            ToastCenter.shared.show("没有发现新的安装包")
            return
        }
        if result.urls.count > 1 {
            ToastCenter.shared.show("发现 \(result.urls.count) 个安装包，已选中最近修改的一个.")
        }
        pendingURL = first
        showImportConfirm = true
    }

    private func runRepair() {
        guard let rec = record else { return }
        repairing = true
        repairFraction = nil
        progressText = "修补并安装中"
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
            // （reloadPackages 扫到该目录只剩 repaired.ipa 即归类）。失败 / 取消（.skipped）绝不删。
            if r.status == .ok {
                ImportService.deleteOriginalAfterRepairSuccess(rec)
            }
            // 在线安装前置检查：产物是否在盘上、能否读到 bundle id（只在修补后算一次）。
            onlineReadiness = Self.resolveOnlineReadiness(result: r, record: record)
            reloadPackages()
            if r.status == .failed { ToastCenter.shared.show(r.message) }
        }
    }

    // MARK: 批量修补（需求 #19）

    /// 勾选 / 取消勾选一条已导入的包。
    private func toggleSelection(_ p: ImportedPackage) {
        if selectedPackageIds.contains(p.id) {
            selectedPackageIds.remove(p.id)
        } else {
            selectedPackageIds.insert(p.id)
        }
    }

    /// 批量修补：对选中的包**逐条串行**执行（不并发 —— 修补是重 I/O，且会踩已知并发问题）。
    ///
    /// 每条各自走完整流程（含「安装前确认」），成败分别记入 `batchLog`：
    ///   · 成功（.ok）⇒ 按需求 #17 删原件，条目移入「已修补」块；
    ///   · 失败 / 取消 ⇒ 原件保留，条目留在「已导入」块并标出原因。
    /// 中途离开本页（`viewActive == false`）⇒ 停止后续条目，避免对话框无处显示导致永久挂起。
    private func runBatchRepair() {
        let targets = packages.filter { selectedPackageIds.contains($0.id) }
        guard !targets.isEmpty else { return }
        batchRepairing = true
        batchLog = []
        batchProgressText = "准备中"
        onlineReadiness = .noArtifact
        onlineInstalling = false

        Task {
            for (idx, p) in targets.enumerated() {
                guard viewActive else { break }
                batchProgressText = "正在修补 \(idx + 1)/\(targets.count)：\(p.name)"

                guard let path = p.originalPath else {
                    batchLog.append(.init(id: p.id, name: p.name,
                                          outcome: .failed("找不到原件.")))
                    continue
                }
                let rebuilt: ImportRecord? = await Task.detached(priority: .userInitiated) {
                    ImportService.rebuildRecord(forOriginalAt: path)
                }.value
                guard let rec = rebuilt else {
                    batchLog.append(.init(id: p.id, name: p.name,
                                          outcome: .failed("无法读取这个安装包.")))
                    continue
                }

                let r = await ImportService.handOffToRepair(
                    rec,
                    runLaunchCheck: true,
                    progress: nil,
                    confirmInstall: { await awaitInstallConfirm() })

                switch r.status {
                case .ok:
                    // 需求 #17：修补成功后删原件，条目移入「已修补」块。
                    ImportService.deleteOriginalAfterRepairSuccess(rec)
                    batchLog.append(.init(id: p.id, name: p.name, outcome: .success))
                case .skipped:
                    batchLog.append(.init(id: p.id, name: p.name,
                                          outcome: .failed("已取消安装，原件保留.")))
                case .failed, .needsUserChoice:
                    batchLog.append(.init(id: p.id, name: p.name, outcome: .failed(r.message)))
                }
                reloadPackages()
            }
            batchRepairing = false
            batchProgressText = ""
            selectedPackageIds.removeAll()
            let ok = batchLog.filter { if case .success = $0.outcome { return true } else { return false } }.count
            ToastCenter.shared.show("批量修补完成：成功 \(ok) 个，失败 \(batchLog.count - ok) 个")
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

    // MARK: 已导入的包列表

    /// 刷新两个块：已导入（还有 `original.ipa`）与已修补（原件已删、只剩 `repaired.ipa`）。
    ///
    /// 「已安装」判定需要本机应用清单（`AppDiscovery`，依赖配对 / 隧道）；**查不到就传 nil**，
    /// 列表只落「待修补 / 已修补」且 `isInstalled` 保持 nil，绝不凭空断言已安装。
    /// 扫描（判已安装时会解包读 bundleId）放后台。
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
            // 选择集只保留仍在「已导入」块里的条目（成功的已移走，不能留着悬空选择）。
            selectedPackageIds.formIntersection(Set(listing.imported.map(\.id)))
        }
    }

    /// 点一行：重读原件、重建记录，复用既有的「包信息 → 开始修补」入口。
    /// 原件读不出时给一句反馈，不静默。
    private func openPackage(_ p: ImportedPackage) {
        guard !importing, !repairing, preparingPackageId == nil else { return }
        guard let path = p.originalPath else { return }
        preparingPackageId = p.id
        Task {
            let rec = await Task.detached(priority: .userInitiated) {
                ImportService.rebuildRecord(forOriginalAt: path)
            }.value
            preparingPackageId = nil
            guard let rec else {
                ToastCenter.shared.show("无法读取这个安装包.")
                return
            }
            importResult = nil
            repairResult = nil
            onlineReadiness = .noArtifact   // 换包了：上一轮产物的在线安装结论作废
            record = rec
        }
    }
}
