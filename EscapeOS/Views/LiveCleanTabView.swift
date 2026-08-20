import SwiftUI

/// One guest app (inside LiveContainer) ranked by reclaimable safe space.
struct LiveCleanAppRank: Identifiable {
    var id: String { guest.id }
    let guest: LiveContainerGuest
    let safeBytes: Int64
    let safeFiles: Int
    let failed: Bool

    var subtitle: String {
        if failed { return "无法打开容器 · \(guest.hostName)" }
        if safeBytes == 0 { return "没有可安全清理的内容 · \(guest.hostName)" }
        return "可安全清理 \(ReclaimService.formatBytes(safeBytes)) · \(guest.hostName)"
    }

    /// Convenience accessor for `ReclaimService` (needs an `InstalledApp`).
    var installedApp: InstalledApp { guest.installedApp }
}

/// Cleans cache and temp files of apps installed *inside* LiveContainer.
/// Functionally identical to the Reclaim tab, but the targets are the guest
/// apps hosted in LiveContainer's own Data container rather than system apps.
struct LiveCleanTabView: View {
    @ObservedObject var appList: AppListViewModel
    @StateObject private var vm = LiveCleanTabViewModel()
    @State private var selecting = false
    @State private var searchText = ""

    private var filteredRows: [LiveCleanAppRank] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vm.rows }
        return vm.rows.filter { row in
            row.guest.displayName.localizedCaseInsensitiveContains(query)
                || row.guest.bundleIdentifier.localizedCaseInsensitiveContains(query)
                || row.guest.hostName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if appList.needsPairing {
                Text("请先在「应用」页导入配对文件。")
                    .foregroundColor(.secondary)
                    .padding()
            } else if vm.instances.isEmpty && !vm.isScanning && !vm.didRun {
                discoverPrompt
            } else if vm.rows.isEmpty && !vm.isScanning {
                Text(vm.discoveryError ?? "LiveContainer 内未找到已安装的应用。")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                rankedList
            }
        }
        .navigationTitle("容器清理")
        .onAppear {
            vm.refreshRanksFromCache()
        }
        .searchable(text: $searchText, prompt: "搜索 LiveContainer 应用")
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
                        vm.discover(apps: appList.apps)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isScanning || vm.isBusy || vm.rows.isEmpty || appList.apps.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                batchBar
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
        .alert("清理安全空间？", isPresented: $vm.confirmBatch) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                vm.runBatch(guests: vm.guests)
            }
        } message: {
            Text(vm.batchMessage)
        }
        .alert(item: $vm.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }

    private var discoverPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("清理 LiveContainer 内安装的应用的缓存与临时文件。确认清理前不会删除任何内容。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                selecting = false
                vm.discover(apps: appList.apps)
            } label: {
                Text("扫描 LiveContainer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appList.apps.isEmpty || vm.isScanning)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rankedList: some View {
        let visible = filteredRows
        return List {
            if !vm.progressText.isEmpty && vm.isScanning {
                Text(vm.progressText)
                    .foregroundColor(.secondary)
            }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && visible.isEmpty && !vm.rows.isEmpty {
                Text("没有匹配「\(searchText)」的应用。")
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
                    NavigationLink(destination: ReclaimAppView(app: row.installedApp, viewModel: appList, guestIcon: row.guest.iconData)) {
                        rankRow(row, selected: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func rankRow(_ row: LiveCleanAppRank, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
            }
            GuestIcon(data: row.guest.iconData)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.guest.displayName)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var batchBar: some View {
        let bytes = vm.selectedSafeBytes
        return HStack {
            Text("已选 \(vm.selected.count) 项 · \(ReclaimService.formatBytes(bytes))")
                .font(.subheadline)
            Spacer()
            Button("清理安全项") {
                vm.confirmBatch = true
            }
            .disabled(vm.selected.isEmpty || bytes == 0)
        }
        .padding()
        .background(.bar)
    }
}

/// Renders a LiveContainer guest icon from pre-decoded `Data`, with a
/// shippingbox placeholder when the guest bundle shipped no icon.
struct GuestIcon: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, !data.isEmpty, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "shippingbox")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.secondary)
            }
        }
    }
}

final class LiveCleanTabViewModel: ObservableObject {
    @Published var rows: [LiveCleanAppRank] = []
    @Published var selected: Set<String> = []
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var busyTitle = "扫描中…"
    @Published var progressText = ""
    @Published var confirmBatch = false
    @Published var alert: ReclaimNotice?
    @Published var instances: [LiveContainerInstance] = []
    @Published var discoveryError: String?
    @Published var didRun = false

    /// Flattened guest apps across all instances (used for batch reclaim).
    var guests: [LiveContainerGuest] { instances.flatMap { $0.guests } }

    /// Legacy accessor kept for the batch alert copy.
    var guestApps: [InstalledApp] { guests.map(\.installedApp) }

    private let service = ReclaimService()
    private let discovery = LiveContainerDiscovery()
    private var scanToken = 0

    var selectedSafeBytes: Int64 {
        rows.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.safeBytes }
    }

    var batchMessage: String {
        let n = selected.count
        let files = rows.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.safeFiles }
        return "请先关闭这些应用。本次仅清理 LiveContainer 内 \(n) 个应用的安全缓存与临时文件（\(files) 个文件，\(ReclaimService.formatBytes(selectedSafeBytes))）。不包含会话数据。"
    }

    func refreshRanksFromCache() {
        guard !rows.isEmpty else { return }
        rows = rows.map { row in
            guard let buckets = ReclaimScanCache.shared.buckets(for: row.guest.id) else { return row }
            let safe = buckets.filter { $0.category.risk == .safe }
            return LiveCleanAppRank(
                guest: row.guest,
                safeBytes: safe.reduce(0) { $0 + $1.bytes },
                safeFiles: safe.reduce(0) { $0 + $1.files },
                failed: row.failed
            )
        }.sorted { lhs, rhs in
            if lhs.failed != rhs.failed { return !lhs.failed && rhs.failed }
            if lhs.safeBytes != rhs.safeBytes { return lhs.safeBytes > rhs.safeBytes }
            return lhs.guest.displayName.localizedCaseInsensitiveCompare(rhs.guest.displayName) == .orderedAscending
        }
    }

    /// Find LiveContainer instances, then rank their guest apps by safe space.
    func discover(apps: [InstalledApp]) {
        didRun = true
        let instances = discovery.discover(installedApps: apps)
        self.instances = instances
        let guests = instances.flatMap { $0.guests }
        if instances.isEmpty {
            discoveryError = "未检测到 LiveContainer。请先在设备上安装 LiveContainer。"
        } else if let failed = instances.first(where: { $0.error != nil }) {
            discoveryError = "无法打开 LiveContainer 容器：\(failed.error ?? "未知错误")"
        } else if guests.isEmpty {
            discoveryError = "LiveContainer 内未找到已安装的应用。"
        } else {
            discoveryError = nil
        }
        scan(guests: guests)
    }

    func scan(guests: [LiveContainerGuest]) {
        scanToken += 1
        let token = scanToken
        isScanning = true
        busyTitle = "扫描中…"
        progressText = ""
        selected.removeAll()

        let hostNames = Dictionary(uniqueKeysWithValues: instances.flatMap { inst in
            inst.guests.map { ($0.id, inst.host.name) }
        })

        DispatchQueue.global(qos: .utility).async {
            let lock = NSLock()
            var ranks: [LiveCleanAppRank] = []
            let total = guests.count
            var completedCount = 0
            // Two at a time: faster than one-by-one without exhausting bad_query.
            let gate = DispatchSemaphore(value: 2)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "escapeos.liveclean.scan", qos: .utility, attributes: .concurrent)
            for guest in guests {
                if token != self.scanToken { break }
                gate.wait()
                group.enter()
                queue.async {
                    defer {
                        gate.signal()
                        group.leave()
                    }
                    if token != self.scanToken { return }
                    let hostName = hostNames[guest.id] ?? guest.hostName
                    let installed = guest.installedApp
                    let rank: LiveCleanAppRank
                    if installed.containerPath.isEmpty {
                        rank = LiveCleanAppRank(guest: guest, safeBytes: 0, safeFiles: 0, failed: true)
                    } else {
                        do {
                            let buckets = try self.service.scan(app: installed, risks: [.safe])
                            ReclaimScanCache.shared.merge(buckets, for: guest.id)
                            let safe = buckets.filter { $0.category.risk == .safe }
                            rank = LiveCleanAppRank(
                                guest: guest,
                                safeBytes: safe.reduce(0) { $0 + $1.bytes },
                                safeFiles: safe.reduce(0) { $0 + $1.files },
                                failed: false
                            )
                        } catch {
                            rank = LiveCleanAppRank(guest: guest, safeBytes: 0, safeFiles: 0, failed: true)
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
                return lhs.guest.displayName.localizedCaseInsensitiveCompare(rhs.guest.displayName) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard token == self.scanToken else { return }
                self.rows = ranks
                self.isScanning = false
                self.progressText = ""
            }
        }
    }

    func runBatch(guests: [LiveContainerGuest]) {
        let ids = selected
        let targets = rows.filter { ids.contains($0.id) && !$0.failed && $0.safeBytes > 0 }.map { $0.guest }
        guard !targets.isEmpty else { return }
        isBusy = true
        busyTitle = "清理中…"
        let installedTargets = targets.map(\.installedApp)
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var files = 0
            var skipped = 0
            var failures = 0
            for (index, app) in installedTargets.enumerated() {
                DispatchQueue.main.async {
                    self.busyTitle = "清理 \(index + 1) / \(installedTargets.count)"
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
                var message = "已释放 \(ReclaimService.formatBytes(freed))（\(files) 个文件），来自 LiveContainer 内 \(installedTargets.count) 个应用。"
                if skipped > 0 {
                    message += " 跳过 \(skipped) 个无法删除的项目。"
                }
                if failures > 0 {
                    message += " \(failures) 个失败。"
                }
                self.alert = ReclaimNotice(title: "已清理", message: message)
                self.scan(guests: guests)
            }
        }
    }
}
