import SwiftUI
import UniformTypeIdentifiers

// 共享转换 · 接收侧界面（导入 + 修补 + 安装）
//
// 三步确认（**不做「一键导入并安装」**）：
//   ① 导入前确认 → ② 修补前确认 → ③ 安装前确认（由 `RepairService.repair(confirmInstall:)` 在安装前 await）。
//
// 入口：更多 → 应用安装 →「共享转换」（见 MoreView）。

struct ImportView: View {

    @State private var showPicker = false
    @State private var pendingURL: URL?            // 待确认导入
    @State private var showImportConfirm = false

    @State private var importing = false
    @State private var importResult: ImportResult?
    @State private var record: ImportRecord?

    @State private var showRepairConfirm = false
    @State private var repairing = false
    @State private var progressText = ""
    @State private var repairResult: RepairResult?

    @State private var showInstallConfirm = false
    @State private var installContinuation: CheckedContinuation<Bool, Never>?

    /// D4：onOpenURL 导入成功时交接过来的记录，在**挂载 / 回前台**时消费（见 `consumePendingImport`）。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            pickerSection
            if let importResult { importStatusSection(importResult) }
            if let record { packageSection(record) }
            if repairing { progressSection }
            if let repairResult { resultSection(repairResult) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("共享转换")
        .navigationBarTitleDisplayMode(.inline)
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
        .onAppear { consumePendingImport() }
        .onChange(of: scenePhase) { _, _ in consumePendingImport() }
        .toastHost()
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
        } footer: {
            Text("把你从别处收到的 .ipa 放到本机后，从这里导入.")
        }
    }

    private func importStatusSection(_ r: ImportResult) -> some View {
        Section("导入结果") {
            Text(r.message)
            if !r.suggestion.isEmpty { Text(r.suggestion).font(.footnote).foregroundStyle(.secondary) }
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

    private func packageSection(_ rec: ImportRecord) -> some View {
        Section("包信息") {
            LabeledContent("名称", value: rec.app.displayName ?? rec.storedFileName)
            if let b = rec.app.bundleId { LabeledContent("标识", value: b) }
            if let v = rec.app.version { LabeledContent("版本", value: v) }
            LabeledContent("类型", value: payloadKindText(rec.payload.encrypted))
            LabeledContent("包内授权", value: rec.sinf.present ? "有" : "无")
            if !rec.trust.notes.isEmpty {
                ForEach(rec.trust.notes, id: \.self) { n in
                    Text(n).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                showRepairConfirm = true
            } label: {
                Label("开始修补", systemImage: "wrench.and.screwdriver")
            }
            .disabled(repairing)
        }
    }

    private var progressSection: some View {
        Section("修补进度") {
            HStack {
                ProgressView()
                Text(progressText).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func resultSection(_ r: RepairResult) -> some View {
        Section("结果") {
            Text(r.message)
            if !r.suggestion.isEmpty { Text(r.suggestion).font(.footnote).foregroundStyle(.secondary) }
            if let code = r.code { Text("原因码：\(code)").font(.footnote).foregroundStyle(.secondary) }
            if !r.details.isEmpty { detailsDisclosure(r.details) }
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
        record = rec            // 进入「待修补」态（packageSection 里出现「开始修补」）
    }

    private func startImport() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        importing = true
        importResult = nil
        record = nil
        repairResult = nil
        Task {
            let r = await ImportService.importFile(at: url, sourceKind: .picker)
            importing = false
            importResult = r
            record = r.record
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
        let found = ImportService.scanForNewImports(known: known)
        guard let first = found.first else {
            ToastCenter.shared.show("没有发现新的安装包")
            return
        }
        if found.count > 1 {
            ToastCenter.shared.show("发现 \(found.count) 个安装包，已选中最近修改的一个.")
        }
        pendingURL = first
        showImportConfirm = true
    }

    private func runRepair() {
        guard let rec = record else { return }
        repairing = true
        progressText = "修补并安装中"
        repairResult = nil
        Task {
            let r = await ImportService.handOffToRepair(
                rec,
                runLaunchCheck: true,
                confirmInstall: { await awaitInstallConfirm() })
            repairing = false
            progressText = "完成"
            repairResult = r
            if r.status == .failed { ToastCenter.shared.show(r.message) }
        }
    }

    /// 安装前确认：挂起等待用户在 dialog 上作答。
    ///
    /// ⚠️ 唯一 resume 点是 `resumeInstall(_:)`。它同时被三个地方调用：对话框两个按钮、
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
}
