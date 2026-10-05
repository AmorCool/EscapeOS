import SwiftUI

// 共享转换 ·「待修补」二级页（用户需求 #2，新增栏目）.
//
// 从「共享转换」主页新增的「待修补」栏目**点击进入**。左上角是**向上箭头**，支持搜索；
// 多选 + 全选后走底部批量条：主按钮「批量修补（N）」+「移除（N）」。
//
// 骨架与「已导入」页一致（向上箭头 / 搜索栏 / 多选 + 全选 / 底部批量条），实现见 `ImportedListPage.swift` 顶部注释。
//
// 数据源：`ImportedPackageList.scanListing(...).imported` 中 `status == .awaitingRepair` 的子集。
//   · 「已导入」= imported 全量（含已安装）；「待修补」= 其中还没修补、还没安装、正等着动手的那些。
//   · 两个栏目是**同一份磁盘现状的两种视角**，不引入新的持久化状态。
//
// 「移除」语义（用户需求 #2）：**仅从「待修补」列表移除，不删安装包**。
//   实现：把包落点整体**移动**到 `Imports/.removed/`（移动 ≠ 删除，可恢复），
//   两处扫描都用 `.skipsHiddenFiles` ⇒ 移走后即刻从列表消失，且不会被「扫描新文件」捞回来。
//   详见 `ImportedPackageMover`。这与「已导入」页的「移除 = 删除」是**两种语义**，刻意分开。

struct PendingRepairPage: View {

    @Environment(\.dismiss) private var dismiss

    @State private var packages: [ImportedPackage] = []
    @State private var loading = true
    @State private var searchText = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []

    @State private var busy = false
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
        .navigationBarBackButtonHidden(true)
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
            } else {
                Color.clear.frame(height: 12)
            }
        }
        .alert(item: $alert) { alertContent($0) }
        .onAppear { viewActive = true; reload() }
        .onDisappear { viewActive = false; resumeInstall(false) }
    }

    // MARK: - 子视图

    private var emptyRow: some View {
        Text(searchText.isEmpty ? "没有待修补的安装包." : "没有匹配 “\(searchText)” 的安装包.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func row(_ p: ImportedPackage) -> some View {
        Button {
            handleTap(p)
        } label: {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected.contains(p.id)
                                         ? AppTheme.accent
                                         : Color.secondary.opacity(0.5))
                }
                ImportedPackageMonogram(name: p.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let v = p.version { PackageChip(text: "v\(v)", tint: .blue) }
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
    }

    // MARK: - 弹窗

    private func alertContent(_ a: ActiveAlert) -> Alert {
        switch a {
        case .installConfirm:
            return Alert(title: Text("安装前确认"),
                         message: Text("即将把这个应用安装到本机."),
                         primaryButton: .default(Text("继续安装")) { resumeInstall(true) },
                         secondaryButton: .cancel(Text("取消")) { resumeInstall(false) })
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
        Task {
            let listing = await ImportedPackageScanner.scan()
            // 只留「还没修补、还没安装」的：即 imported 块里 status == .awaitingRepair 的那些。
            packages = listing.imported.filter { $0.status == .awaitingRepair }
            loading = false
            selected.formIntersection(Set(packages.map(\.id)))
        }
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

    private func performRemove(_ items: [ImportedPackage]) {
        busy = true
        resultText = nil
        var ok = 0
        var failed = 0
        for p in items {
            if ImportedPackageMover.moveToRemoved(p) { ok += 1 } else { failed += 1 }
        }
        busy = false
        selected.removeAll()
        selecting = false
        resultText = failed == 0
            ? "已从列表移除 \(ok) 个安装包（文件仍在，可恢复）."
            : "已移除 \(ok) 个，\(failed) 个移除失败."
        reload()
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
