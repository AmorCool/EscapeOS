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
            Text(record?.payload.encrypted == false
                 ? "这是明文包，无需修补；确认后会直接安装到本机. 仅适用于来源可信的包."
                 : "修补会把包内既有的解密授权铺到包内全部 SC_Info 路径，然后安装到本机. 仅适用于与你登录相同 Apple ID 的设备分享的包.")
        }
        // ③ 安装前确认（由 RepairService 在调用 installd 之前 await）
        .confirmationDialog("安装前确认", isPresented: $showInstallConfirm, titleVisibility: .visible) {
            Button("继续安装") { resumeInstall(true) }
            Button("取消", role: .cancel) { resumeInstall(false) }
        } message: {
            Text("即将把这个应用安装到本机.")
        }
        .toastHost()
    }

    // MARK: Sections

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

    private func packageSection(_ rec: ImportRecord) -> some View {
        Section("包信息") {
            LabeledContent("名称", value: rec.app.displayName ?? rec.storedFileName)
            if let b = rec.app.bundleId { LabeledContent("标识", value: b) }
            if let v = rec.app.version { LabeledContent("版本", value: v) }
            LabeledContent("类型", value: rec.payload.encrypted ? "加密包" : "明文包")
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
    @MainActor
    private func awaitInstallConfirm() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            installContinuation = cont
            showInstallConfirm = true
        }
    }

    private func resumeInstall(_ ok: Bool) {
        installContinuation?.resume(returning: ok)
        installContinuation = nil
    }
}
