import SwiftUI

// 共享转换 ·「已导入」二级页（用户需求 #1 / #3）.
//
// 从「共享转换」主页的「已导入」栏目**点击进入**（不再在原页展开 / 收拢）。
// 左上角是**向上箭头**（不是返回键），支持搜索；多选 + 全选后走底部批量条。
//
// 骨架照仓库现成范式拼（不另造）：
//   · 向上箭头：`.navigationBarBackButtonHidden(true)` + leading `ToolbarItem{ Image(systemName: "arrow.up") }`
//     + `dismiss()` —— 箭头画法见 `AFCBrowserView.swift:86-96`。
//   · 搜索栏：`.searchable(placement: .navigationBarDrawer(displayMode: .always), prompt:)`
//     —— 见 `ModuleManagerView.swift:292-293` / `AppListView.swift:523`。
//   · 多选 + 全选：`selected: Set<String>` + 导航栏「选择 / 全选」
//     —— 见 `AppListView.swift:412/484/524-549` / `ReclaimTabView.swift:41-59`（全选在导航栏，不在底条）。
//   · 底部批量条：`.safeAreaInset(edge: .bottom)` 挂 `BatchActionBar`；未进选择态用 `Color.clear.frame(height: 12)` 占位
//     —— 见 `ReclaimTabView.swift:61-69`。
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
    /// 需求 #5：流程 banner 的 N/M 进度（如 `(current: 1, total: 14)`）与补充说明。
    @State private var flowProgress: (current: Int, total: Int)?
    @State private var flowCaption: String?
    @State private var resultText: String?

    /// 安装前确认（三步确认第三步）：挂起等用户在 `.alert` 上作答。唯一 resume 点是 `resumeInstall`（幂等）。
    @State private var installContinuation: CheckedContinuation<Bool, Never>?
    /// 页面是否仍在屏上：批量逐条跑时用它兜底，避免对话框无处显示导致 continuation 永久挂起。
    @State private var viewActive = true

    @State private var alert: ActiveAlert?

    /// 本页的确认弹窗（安装前确认 / 批量修补前确认 / 移除前确认）统一走一个 `.alert(item:)`，
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
                    Text("勾选后可批量修补或移除；点一行即选中它.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("已导入")
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
                    // 已导入 = 还没有修补产物，故这里**不提供在线安装**（无产物可装）。
                    // 「选中 ≥2 去掉在线安装」的规则在「已修补」页生效（见 RepairedListPage）。
                    Button("移除（\(selected.count)）", role: .destructive) {
                        alert = .remove(items: selectedPackages)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selected.isEmpty || busy)
                }
            } else {
                // 未进选择态：留出底部间距，避免列表最后一项顶到 Tab 栏（照 ReclaimTabView:61-69）。
                Color.clear.frame(height: 12)
            }
        }
        .alert(item: $alert) { alertContent($0) }
        .onAppear { viewActive = true; reload() }
        .onDisappear { viewActive = false; resumeInstall(false) }
    }

    // MARK: - 子视图

    private var emptyRow: some View {
        Text(searchText.isEmpty ? "还没有导入过安装包." : "没有匹配 “\(searchText)” 的安装包.")
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
                         message: Text("将从本机删除这 \(items.count) 个安装包及其修补产物. 删除后无法恢复."),
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

                if r.status == .ok {
                    // 修补成功后删原件（与 ImportView 同语义）；条目随即按磁盘现状移入「已修补」块。
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

    // MARK: - 移除（需求 #3：已导入的移除 = 删除）

    /// 「移除」= 真删安装包（连同其产物）。删除前已由弹窗二次确认，不可恢复。
    private func performDelete(_ items: [ImportedPackage]) {
        busy = true
        resultText = nil
        var ok = 0
        var failed = 0
        for p in items {
            if ImportedPackageMover.delete(p) { ok += 1 } else { failed += 1 }
        }
        busy = false
        selected.removeAll()
        selecting = false
        resultText = failed == 0
            ? "已删除 \(ok) 个安装包."
            : "已删除 \(ok) 个安装包，\(failed) 个删除失败."
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
