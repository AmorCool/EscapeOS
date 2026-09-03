import SwiftUI

struct ReclaimAppRank: Identifiable {
    var id: String { app.bundleIdentifier }
    let app: InstalledApp
    let safeBytes: Int64
    let safeFiles: Int
    let failed: Bool

    var subtitle: String {
        if failed { return "无法打开容器" }
        if safeBytes == 0 { return "没有可安全回收的内容" }
        return "可回收 \(ReclaimService.formatBytes(safeBytes))"
    }
}

/// Ranked reclaim across installed apps. Batch only uses Safe buckets.
struct ReclaimTabView: View {
    @ObservedObject var appList: AppListViewModel
    @Binding var segment: ReclaimSegment
    @StateObject private var vm = ReclaimTabViewModel()
    @State private var selecting = false
    @State private var searchText = ""

    var body: some View {
        mainContent
        .onAppear {
            vm.refreshRanksFromCache()
        }
        .searchable(text: $searchText, prompt: "搜索应用")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if selecting {
                    Button("取消") {
                        selecting = false
                        vm.selected.removeAll()
                    }
                    .disabled(vm.isScanning || vm.isBusy)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button(selecting ? "全选" : "选择") {
                        if selecting {
                            vm.selected = Set(vm.rows.filter { !$0.failed && $0.safeBytes > 0 }.map(\.id))
                        } else {
                            selecting = true
                        }
                    }
                    .disabled(vm.isScanning || vm.isBusy || vm.rows.isEmpty)
                    Button {
                        selecting = false
                        vm.scan(apps: appList.apps)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isScanning || vm.isBusy || appList.apps.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                batchBar
            } else {
                // 留出底部间距，避免列表最后一项直接顶到 Tab 栏，
                // 消除"Tab 栏压住内容"的观感（SpaceReclaimView 嵌套 VStack 会使默认 safe area 失效）.
                Color.clear.frame(height: 12)
            }
        }
        .overlay {
            if vm.isScanning || vm.isBusy {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text(vm.busyTitle)
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .alert("回收安全空间？", isPresented: $vm.confirmBatch) {
            Button("取消", role: .cancel) {}
            Button("回收", role: .destructive) {
                vm.runBatch(apps: appList.apps)
            }
        } message: {
            Text(vm.batchMessage)
        }
        .alert(item: $vm.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }

    private var mainContent: some View {
        List {
            // 分段控件作为列表首项随内容滚动，避免固定在顶部遮挡列表.
            Section {
                Picker("清理范围", selection: $segment) {
                    ForEach(ReclaimSegment.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color(.systemGroupedBackground))
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if appList.needsPairing {
                Section {
                    InfoActionCard(
                        icon: "network.badge.shield.half.filled",
                        title: "需要配对文件",
                        message: "请先在「应用」页导入配对文件，建立 LocalDevVPN 隧道后才能扫描设备应用."
                    )
                }
            } else if appList.apps.isEmpty && !appList.isLoading {
                Section {
                    InfoActionCard(
                        icon: "internaldrive",
                        title: "没有可扫描的应用",
                        message: "设备尚未返回任何应用.请确认 LocalDevVPN 已连接且配对文件有效."
                    )
                }
            } else if vm.rows.isEmpty && !vm.isScanning {
                Section {
                    InfoActionCard(
                        icon: "internaldrive",
                        title: "扫描应用缓存与临时文件",
                        message: "扫描会测量每个应用的缓存与临时文件占用.在你确认回收之前，不会删除任何内容.",
                        actionTitle: "立即扫描",
                        action: {
                            selecting = false
                            vm.scan(apps: appList.apps)
                        },
                        disabled: appList.apps.isEmpty || vm.isScanning
                    )
                }
            } else {
                rowsSection
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
    }

    private var rowsSection: some View {
        let visible = filteredRows
        return Group {
            if !vm.isScanning {
                summaryCard
            }
            if !vm.progressText.isEmpty && vm.isScanning {
                Text(vm.progressText)
                    .foregroundColor(.secondary)
            }
            if visible.isEmpty && !vm.isScanning {
                Text(searchText.isEmpty ? "" : "没有匹配 “\(searchText)” 的应用.")
                    .foregroundColor(.secondary)
            }
            ForEach(visible) { row in
                if selecting {
                    Button {
                        if vm.selected.contains(row.id) {
                            vm.selected.remove(row.id)
                        } else if !row.failed && row.safeBytes > 0 {
                            vm.selected.insert(row.id)
                        }
                    } label: {
                        rankRow(row, selected: vm.selected.contains(row.id))
                    }
                    .disabled(row.failed || row.safeBytes == 0)
                } else {
                    NavigationLink(destination: ReclaimAppView(app: row.app, viewModel: appList)) {
                        rankRow(row, selected: false)
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        let reclaimable = vm.rows.filter { !$0.failed && $0.safeBytes > 0 }
        let total = reclaimable.reduce(0) { $0 + $1.safeBytes }
        let count = reclaimable.count
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.14))
                Image(systemName: "leaf.arrow.circlepath")
                    .font(.system(size: 26))
                    .foregroundColor(AppTheme.accent)
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text("可回收空间")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(ReclaimService.formatBytes(total))
                    .font(.title2.bold())
                    .foregroundColor(AppTheme.accent)
                Text("来自 \(count) 个应用的安全缓存")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var filteredRows: [ReclaimAppRank] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vm.rows }
        return vm.rows.filter { row in
            row.app.name.localizedCaseInsensitiveContains(query)
                || row.app.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private func rankRow(_ row: ReclaimAppRank, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(selected ? AppTheme.accent : .secondary)
            }
            AppIconView(icon: appList.icons[row.app.bundleIdentifier], size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.app.name)
                    .font(.headline)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if !selecting, !row.failed, row.safeBytes > 0 {
                SizePill(text: ReclaimService.formatBytes(row.safeBytes))
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var batchBar: some View {
        let bytes = vm.selectedSafeBytes
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(vm.selected.count) 项")
                    .font(.subheadline.weight(.semibold))
                Text(ReclaimService.formatBytes(bytes))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("回收安全项") {
                vm.confirmBatch = true
            }
            .disabled(vm.selected.isEmpty || bytes == 0)
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
        }
        .padding()
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

final class ReclaimTabViewModel: ObservableObject {
    @Published var rows: [ReclaimAppRank] = []
    @Published var selected: Set<String> = []
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var busyTitle = "扫描中…"
    @Published var progressText = ""
    @Published var confirmBatch = false
    @Published var alert: ReclaimNotice?

    private let service = ReclaimService()
    private var scanToken = 0

    var selectedSafeBytes: Int64 {
        rows.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.safeBytes }
    }

    var batchMessage: String {
        let n = selected.count
        let files = rows.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.safeFiles }
        return "请先关闭这些应用.本次仅回收 \(n) 个应用的安全缓存与临时文件（\(files) 个文件，\(ReclaimService.formatBytes(selectedSafeBytes))）.不包含会话数据."
    }

    func refreshRanksFromCache() {
        guard !rows.isEmpty else { return }
        rows = rows.map { row in
            guard let buckets = ReclaimScanCache.shared.buckets(for: row.app.bundleIdentifier) else { return row }
            let safe = buckets.filter { $0.category.risk == .safe }
            return ReclaimAppRank(
                app: row.app,
                safeBytes: safe.reduce(0) { $0 + $1.bytes },
                safeFiles: safe.reduce(0) { $0 + $1.files },
                failed: row.failed
            )
        }.sorted { lhs, rhs in
            if lhs.failed != rhs.failed { return !lhs.failed && rhs.failed }
            if lhs.safeBytes != rhs.safeBytes { return lhs.safeBytes > rhs.safeBytes }
            return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
        }
    }

    func scan(apps: [InstalledApp]) {
        scanToken += 1
        let token = scanToken
        isScanning = true
        busyTitle = "扫描中…"
        progressText = ""
        selected.removeAll()
        DispatchQueue.global(qos: .utility).async {
            let lock = NSLock()
            var ranks: [ReclaimAppRank] = []
            let total = apps.count
            var completedCount = 0
            // Two apps at a time: faster than one-by-one, without opening every
            // container handle at once (that can make bad_query fail).
            let gate = DispatchSemaphore(value: 2)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "escapeos.reclaim.scan", qos: .utility, attributes: .concurrent)
            for app in apps {
                if token != self.scanToken { break }
                gate.wait()
                group.enter()
                queue.async {
                    defer {
                        gate.signal()
                        group.leave()
                    }
                    if token != self.scanToken { return }
                    let rank: ReclaimAppRank
                    if app.containerPath.isEmpty {
                        rank = ReclaimAppRank(app: app, safeBytes: 0, safeFiles: 0, failed: true)
                    } else {
                        do {
                            let buckets = try self.service.scan(app: app, risks: [.safe])
                            ReclaimScanCache.shared.merge(buckets, for: app.bundleIdentifier)
                            let safe = buckets.filter { $0.category.risk == .safe }
                            rank = ReclaimAppRank(
                                app: app,
                                safeBytes: safe.reduce(0) { $0 + $1.bytes },
                                safeFiles: safe.reduce(0) { $0 + $1.files },
                                failed: false
                            )
                        } catch {
                            rank = ReclaimAppRank(app: app, safeBytes: 0, safeFiles: 0, failed: true)
                        }
                    }
                    lock.lock()
                    ranks.append(rank)
                    completedCount += 1
                    let done = completedCount
                    lock.unlock()
                    DispatchQueue.main.async {
                        guard token == self.scanToken else { return }
                        self.busyTitle = "扫描 \(done) / \(total)"
                        self.progressText = "扫描 \(done) / \(total)"
                    }
                }
            }
            group.wait()
            ranks.sort { lhs, rhs in
                if lhs.failed != rhs.failed { return !lhs.failed && rhs.failed }
                if lhs.safeBytes != rhs.safeBytes { return lhs.safeBytes > rhs.safeBytes }
                return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard token == self.scanToken else { return }
                self.rows = ranks
                self.isScanning = false
                self.progressText = ""
            }
        }
    }

    func runBatch(apps: [InstalledApp]) {
        let ids = selected
        let targets = rows.filter { ids.contains($0.id) && !$0.failed && $0.safeBytes > 0 }.map(\.app)
        guard !targets.isEmpty else { return }
        isBusy = true
        busyTitle = "回收中…"
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var files = 0
            var skipped = 0
            var failures = 0
            for (index, app) in targets.enumerated() {
                DispatchQueue.main.async {
                    self.busyTitle = "回收 \(index + 1) / \(targets.count)"
                }
                do {
                    let result = try self.service.reclaim(
                        app: app,
                        categories: ReclaimService.safeCategories
                    )
                    freed += result.bytesFreed
                    files += result.filesRemoved
                    skipped += result.skipped
                } catch {
                    failures += 1
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                var message = "已释放 \(ReclaimService.formatBytes(freed))（\(files) 个文件），来自 \(targets.count) 个应用."
                if skipped > 0 {
                    message += " 跳过 \(skipped) 个无法删除的项目."
                }
                if failures > 0 {
                    message += " \(failures) 个失败."
                }
                self.alert = ReclaimNotice(title: "已回收", message: message)
                self.scan(apps: apps)
            }
        }
    }
}
