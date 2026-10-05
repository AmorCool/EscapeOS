import SwiftUI

// 共享转换 ·「已修补」二级页（用户需求 #1 / #3 / #4）.
//
// 从「共享转换」主页的「已修补」栏目**点击进入**（不再在原页展开 / 收拢）。
// 左上角是**向上箭头**，支持搜索；每行**只给两个操作**：在线安装 / 覆盖升级安装
// （**不给重新修补** —— 已修补的包无需再修，且原件已按需求 #17 删除，无从下手）。
//
// 骨架与「已导入」页一致（向上箭头 / 搜索栏 / 多选 + 全选 / 底部批量条），实现见 `ImportedListPage.swift` 顶部注释。
//
// 数据源：`ImportedPackageList.scanListing(...).repaired`（磁盘证据）。
//
// 用户需求 #4：批量操作**选中 ≥2 时去掉「在线安装」** —— 在线安装是 OTA 单包通道，
// 多选时语义不成立，故仅在恰好选中 1 个时给出（见 `batchBar` 里的 `selected.count == 1` 判断）。
//
// 导出入口：`RepairedPackageExportSection` 绑定的是**单条** `ImportRecord` / `RepairResult`
// （见 `RepairedPackageExport.swift:18-24`），列表页拿不到该上下文，无法按行内嵌。
// 故本页复用同一套导出机制（`ShareTarget` + `ShareSheet`，见 `DesignSystem.swift:133-149`）按行导出，
// 导出对象同为 `package.repairedPath`（修补产物，不是原件）。

struct RepairedListPage: View {

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

    /// 单条安装进行中的包 id（在线安装 / 覆盖升级各自一条在跑）。
    @State private var workingId: String?
    @State private var shareTarget: ShareTarget?

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
            // 需求 #5：流程 banner 常驻（二级页也显示），批量安装时以 N/M 显示进度。
            ImportFlowBanner(stage: .install, progress: flowProgress, caption: flowCaption)
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
                    Text("已修补的包只支持在线安装与覆盖 / 升级安装；原件已删除，不再提供重新修补.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("已修补")
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
                batchBar
            } else {
                Color.clear.frame(height: 12)
            }
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .onAppear { reload() }
    }

    // MARK: - 子视图

    private var emptyRow: some View {
        Text(searchText.isEmpty ? "还没有修补过的安装包." : "没有匹配 “\(searchText)” 的安装包.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// 底部批量条：主按钮「覆盖 / 升级安装（N）」；
    /// **恰好选中 1 个**时另给「在线安装」与「导出」（需求 #4：选中 ≥2 去掉在线安装）。
    private var batchBar: some View {
        BatchActionBar(selectedCount: selected.count,
                       subtitle: selectedSizeText,
                       primaryTitle: "覆盖 / 升级安装（\(selected.count)）",
                       primaryDisabled: selected.isEmpty
                           || selectedPackages.contains { !canOverwriteInstall($0) }
                           || busy,
                       primaryAction: { runOverwriteInstall(selectedPackages) }) {
            if selected.count == 1, let p = selectedPackages.first {
                Button("在线安装") { runOnlineInstall(p) }
                    .buttonStyle(.bordered)
                    .disabled(!canOnlineInstall(p) || busy)

                Button("导出") { export(p) }
                    .buttonStyle(.bordered)
                    .disabled(busy)
            }
        }
    }

    @ViewBuilder
    private func row(_ p: ImportedPackage) -> some View {
        if selecting {
            Button {
                handleTap(p)
            } label: {
                rowBody(p, showsSelection: true)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                rowBody(p, showsSelection: false)
                HStack(spacing: 8) {
                    Button {
                        runOnlineInstall(p)
                    } label: {
                        Label("在线安装", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(!canOnlineInstall(p) || busy)

                    Button {
                        runOverwriteInstall([p])
                    } label: {
                        Label("覆盖 / 升级安装", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!canOverwriteInstall(p) || busy)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

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
            }
        }
    }

    private func rowBody(_ p: ImportedPackage, showsSelection: Bool) -> some View {
        HStack(spacing: 12) {
            if showsSelection {
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
    }

    // MARK: - 前置检查（照 ImportView.canOnlineInstall / canOverwriteInstall）

    /// 在线安装前置：包内有应用标识（bundle id）。
    private func canOnlineInstall(_ p: ImportedPackage) -> Bool {
        guard let path = p.repairedPath, !path.isEmpty else { return false }
        return !(p.bundleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 覆盖 / 升级安装前置：本机已装同 bundleId 的应用（否则无「已装」可覆盖）。
    /// `isInstalled == nil`（查不到清单）时不可点，不让用户点了才报错。
    private func canOverwriteInstall(_ p: ImportedPackage) -> Bool {
        guard let path = p.repairedPath, !path.isEmpty else { return false }
        return p.isInstalled == true
    }

    private func installBlockReason(_ p: ImportedPackage) -> String? {
        guard let path = p.repairedPath, !path.isEmpty else {
            return "找不到修补产物，无法安装."
        }
        if canOnlineInstall(p) || canOverwriteInstall(p) { return nil }
        var reasons: [String] = []
        if !canOnlineInstall(p) { reasons.append("包内读不出应用标识，无法在线安装") }
        if !canOverwriteInstall(p) {
            reasons.append(p.isInstalled == nil
                           ? "无法确认本机安装状态，覆盖升级不可用"
                           : "本机未安装同款应用，无法覆盖升级")
        }
        return reasons.joined(separator: "；") + "."
    }

    // MARK: - 选择

    private func handleTap(_ p: ImportedPackage) {
        guard !busy else { return }
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
        }
    }

    // MARK: - 安装

    /// 在线安装（OTA / `itms-services`）：装的正是这份修补产物（`OnlineInstallService` 是本地路径驱动）。
    private func runOnlineInstall(_ p: ImportedPackage) {
        guard canOnlineInstall(p), let path = p.repairedPath, let bundleId = p.bundleId else { return }
        workingId = p.id
        resultText = nil
        let url = URL(fileURLWithPath: path)
        OnlineInstallService.install(ipaURL: url, bundleId: bundleId) { result in
            Task { @MainActor in
                workingId = nil
                switch result {
                case .success: ToastCenter.shared.show("正在安装")
                case .failure(let error): ToastCenter.shared.show(error.localizedDescription)
                }
            }
        }
    }

    /// 覆盖 / 升级安装：本地装这份产物，覆盖本机已装的同 bundleId 应用。
    /// `allowDowngrade: true` 走 installd 的 Upgrade 命令，正是「覆盖 / 升级」语义。
    /// 多选时**逐条串行**，进度以 `N/M` 显示。
    private func runOverwriteInstall(_ targets: [ImportedPackage]) {
        let valid = targets.filter { canOverwriteInstall($0) }
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
                do {
                    try await AppStoreInstallService.installLocalIPA(
                        path,
                        allowDowngrade: true,
                        progress: { _ in },
                        onLog: { _ in })
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

    // MARK: - 导出（复用 ShareTarget + ShareSheet，与 RepairedPackageExport 同一套机制）

    private func export(_ p: ImportedPackage) {
        guard let path = p.repairedPath, FileManager.default.fileExists(atPath: path) else {
            ToastCenter.shared.show("没有可导出的安装包")
            return
        }
        shareTarget = ShareTarget(url: URL(fileURLWithPath: path))
    }
}
