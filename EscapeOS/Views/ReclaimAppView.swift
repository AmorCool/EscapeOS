import SwiftUI

/// Per-app reclaim: preview buckets, then empty selected folders.
struct ReclaimAppView: View {
    let app: InstalledApp
    @ObservedObject var viewModel: AppListViewModel
    @StateObject private var vm = ReclaimAppViewModel()

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppIconView(icon: viewModel.icons[app.bundleIdentifier], size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline)
                        Text(selectedSummary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("安全"), footer: Text("这些是缓存与临时文件目录，应用通常可以自行重建。")) {
                ForEach(vm.buckets.filter { $0.category.risk == .safe }) { bucket in
                    bucketRow(bucket)
                }
            }

            Section(header: Text("会话"), footer: Text("可能导致应用内网页登录态丢失。默认关闭，需要时可手动开启。")) {
                if vm.isFilling && vm.buckets.filter({ $0.category.risk == .session }).isEmpty {
                    Text("测量中…").foregroundColor(.secondary)
                }
                ForEach(vm.buckets.filter { $0.category.risk == .session }) { bucket in
                    bucketRow(bucket)
                }
            }

            Section(header: Text("保留"), footer: Text("Documents、Preferences 与 Application Support 在此面板中不会被回收。")) {
                if vm.isFilling && vm.buckets.filter({ $0.category.risk == .kept }).isEmpty {
                    Text("测量中…").foregroundColor(.secondary)
                }
                ForEach(vm.buckets.filter { $0.category.risk == .kept }) { bucket in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bucket.category.title)
                            Text(bucket.category.detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(bucket.summary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(footer: Text("请先关闭 \(app.name)。不会删除 Documents、Preferences 或 Application Support。")) {
                Button {
                    vm.confirmReclaim = true
                } label: {
                    Label("回收 \(ReclaimService.formatBytes(vm.selectedBytes))", systemImage: "internaldrive")
                }
                .disabled(vm.selectedBytes == 0 || vm.isBusy || vm.isLoading)
            }
        }
        .navigationTitle("回收空间")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if vm.isBusy || vm.isLoading {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text(vm.isLoading ? "测量中…" : vm.busyTitle)
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .onAppear {
            viewModel.ensureIcon(for: app.bundleIdentifier)
            vm.load(app: app)
        }
        .alert(vm.confirmTitle, isPresented: $vm.confirmReclaim) {
            Button("取消", role: .cancel) {}
            Button("回收", role: .destructive) {
                vm.run(app: app)
            }
        } message: {
            Text(vm.confirmMessage(appName: app.name))
        }
        .alert(item: $vm.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }

    private var selectedSummary: String {
        if vm.isLoading { return "测量目录中…" }
        return "已选 \(ReclaimService.formatBytes(vm.selectedBytes))"
    }

    private func bucketRow(_ bucket: ReclaimBucketStat) -> some View {
        let enabled = Binding<Bool>(
            get: { vm.selected.contains(bucket.id) },
            set: { on in
                if on { vm.selected.insert(bucket.id) }
                else { vm.selected.remove(bucket.id) }
            }
        )
        return Toggle(isOn: enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.category.title)
                Text(bucket.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(!bucket.available || (bucket.files == 0 && bucket.bytes == 0))
    }
}

struct ReclaimNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

final class ReclaimAppViewModel: ObservableObject {
    @Published var buckets: [ReclaimBucketStat] = []
    @Published var selected: Set<String> = []
    @Published var isLoading = false
    @Published var isFilling = false
    @Published var isBusy = false
    @Published var busyTitle = "回收中…"
    @Published var confirmReclaim = false
    @Published var alert: ReclaimNotice?

    private let service = ReclaimService()
    private var loadToken = 0

    var selectedBytes: Int64 {
        buckets.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var selectedHasSession: Bool {
        buckets.contains { selected.contains($0.id) && $0.category.risk == .session }
    }

    var confirmTitle: String {
        selectedHasSession ? "回收包含会话数据吗？" : "回收这些空间？"
    }

    func confirmMessage(appName: String) -> String {
        let count = buckets.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.files }
        var text = "请先关闭 \(appName)。本次将删除 \(count) 个文件（\(ReclaimService.formatBytes(selectedBytes))）。"
        if selectedHasSession {
            text += " 会话类数据可能导致应用内网页登录态丢失。"
        }
        return text
    }

    func load(app: InstalledApp) {
        loadToken += 1
        let token = loadToken
        let cached = ReclaimScanCache.shared.buckets(for: app.bundleIdentifier) ?? []
        let hasSafe = cached.contains { $0.category.risk == .safe }
        if hasSafe {
            apply(cached, resetSelection: true)
            isLoading = false
            fillMissing(app: app, have: cached, token: token)
            return
        }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = (try? self.service.scan(app: app)) ?? []
            ReclaimScanCache.shared.merge(result, for: app.bundleIdentifier)
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }
                self.apply(result, resetSelection: true)
                self.isLoading = false
            }
        }
    }

    private func fillMissing(app: InstalledApp, have: [ReclaimBucketStat], token: Int) {
        var needed: Set<ReclaimRisk> = []
        if !have.contains(where: { $0.category.risk == .session }) { needed.insert(.session) }
        if !have.contains(where: { $0.category.risk == .kept }) { needed.insert(.kept) }
        guard !needed.isEmpty else { return }
        isFilling = true
        DispatchQueue.global(qos: .utility).async {
            let extra = (try? self.service.scan(app: app, risks: needed)) ?? []
            ReclaimScanCache.shared.merge(extra, for: app.bundleIdentifier)
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }
                self.merge(extra)
                self.isFilling = false
            }
        }
    }

    private func apply(_ result: [ReclaimBucketStat], resetSelection: Bool) {
        buckets = result
        if resetSelection {
            selected = Set(
                result.compactMap { bucket in
                    guard bucket.category.risk == .safe, bucket.available, bucket.bytes > 0 else { return nil }
                    return bucket.id
                }
            )
        }
    }

    private func merge(_ extra: [ReclaimBucketStat]) {
        var current = buckets
        for bucket in extra {
            if let i = current.firstIndex(where: { $0.id == bucket.id }) {
                current[i] = bucket
            } else {
                current.append(bucket)
            }
        }
        buckets = current
    }

    func run(app: InstalledApp) {
        let cats = buckets.filter { selected.contains($0.id) }.map(\.category)
        guard !cats.isEmpty else { return }
        loadToken += 1
        let token = loadToken
        isBusy = true
        busyTitle = "回收中…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.service.reclaim(app: app, categories: cats) { title in
                    DispatchQueue.main.async { self.busyTitle = title }
                }
                let refreshed = (try? self.service.scan(app: app)) ?? []
                DispatchQueue.main.async {
                    guard token == self.loadToken else { return }
                    self.isBusy = false
                    self.apply(refreshed, resetSelection: true)
                    ReclaimScanCache.shared.merge(refreshed, for: app.bundleIdentifier)
                    var message = "已释放 \(ReclaimService.formatBytes(result.bytesFreed))（\(result.filesRemoved) 个文件）。"
                    if result.skipped > 0 {
                        message += " 跳过 \(result.skipped) 个无法删除的项目。"
                    }
                    self.alert = ReclaimNotice(title: "已回收", message: message)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.alert = ReclaimNotice(title: "回收失败", message: error.localizedDescription)
                }
            }
        }
    }
}
