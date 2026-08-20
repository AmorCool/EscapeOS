import SwiftUI
import UIKit

/// View model for the app picker.
final class AppListViewModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var needsPairing = false
    @Published var icons: [String: UIImage] = [:]
    @Published var uninstallStatus: String?

    private let discovery = AppDiscovery()
    private let uninstaller = UninstallService.shared

    var hasPairingFile: Bool { discovery.hasPairingFile }

    var canUninstall: Bool { discovery.canUninstallApps() }

    func reload() {
        isLoading = true
        errorMessage = nil
        needsPairing = false
        uninstallStatus = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let found = try self.discovery.fetchInstalledApps()
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.apps = found
                    self.errorMessage = nil
                    self.icons = [:]
                }
                self.loadIcons(for: found)
            } catch let e as AppDiscoveryError {
                DispatchQueue.main.async {
                    self.isLoading = false
                    if case .noPairingFile = e {
                        self.needsPairing = true
                    } else {
                        self.errorMessage = e.localizedDescription
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Fetch icons concurrently and publish each one as soon as it arrives.
    private func loadIcons(for apps: [InstalledApp]) {
        let ids = apps.map { $0.bundleIdentifier }
        guard !ids.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                let bundleId = ids[index]
                guard let icon = self.discovery.appIcon(for: bundleId) else { return }
                DispatchQueue.main.async {
                    self.icons[bundleId] = icon
                }
            }
        }
    }

    func importPairingFile(_ contents: String) throws {
        try discovery.importPairingFile(contents)
    }

    func resetPairing() {
        discovery.resetPairing()
        apps = []
        icons = [:]
        reload()
    }

    /// Load a single icon on demand (e.g. when opening app detail before batch fetch finishes).
    func ensureIcon(for bundleId: String) {
        guard icons[bundleId] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let icon = self.discovery.appIcon(for: bundleId) else { return }
            DispatchQueue.main.async {
                self.icons[bundleId] = icon
            }
        }
    }

    /// Sequentially uninstall a batch of user apps. Each call goes through
    /// the pairing-file + LocalDevVPN tunnel (`TunnelContext` →
    /// `installation_proxy_uninstall`), authenticated by the trusted pairing
    /// file so `installd` accepts it without a private entitlement. Failures
    /// are collected and surfaced in `uninstallStatus` once the batch
    /// completes — we keep going rather than aborting, so the user gets
    /// partial progress even when one bundle id rejects.
    func uninstallBatch(_ targets: [InstalledApp], completion: @escaping ([InstalledApp], [(InstalledApp, Error)]) -> Void) {
        guard canUninstall else {
            completion([], targets.map { ($0, UninstallServiceError.callFailed("尚未导入配对文件")) })
            return
        }
        var successes: [InstalledApp] = []
        var failures: [(InstalledApp, Error)] = []
        let queue = DispatchQueue(label: "escapeos.uninstall", qos: .userInitiated)
        queue.async {
            for app in targets {
                DispatchQueue.main.async {
                    self.uninstallStatus = "正在卸载 \(app.name) (\(successes.count + failures.count + 1) / \(targets.count))…"
                }
                do {
                    try self.uninstaller.uninstall(bundleId: app.bundleIdentifier)
                    successes.append(app)
                } catch {
                    failures.append((app, error))
                }
            }
            DispatchQueue.main.async {
                self.uninstallStatus = nil
                completion(successes, failures)
                // Refresh app list so system apps-removed / leftover apps reflect.
                self.reload()
            }
        }
    }
}

/// Scrollable list of installed user apps, with search, A–Z jump index,
/// and a multi-select mode that uninstalls chosen apps through the
/// pairing-file + LocalDevVPN tunnel (`installation_proxy_uninstall`).
struct AppListView: View {
    @ObservedObject var viewModel: AppListViewModel
    @State private var searchText = ""
    @State private var iconShare: IconSharePayload?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pendingUninstall: [InstalledApp] = []
    @State private var uninstallResult: UninstallResultNotice?

    var body: some View {
        let visible = filteredApps
        ScrollViewReader { proxy in
            List {
                if let status = viewModel.uninstallStatus {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text(status)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                if visible.isEmpty {
                    Text(emptyListMessage)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sections(in: visible), id: \.letter) { section in
                        Section(header: Text(section.letter).id(section.letter)) {
                            ForEach(section.apps) { app in
                                if selecting {
                                    Button {
                                        toggleSelection(app.bundleIdentifier)
                                    } label: {
                                        appRow(app, mode: .select(isSelected: selected.contains(app.bundleIdentifier)))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink(destination: AppDetailView(app: app, viewModel: viewModel)) {
                                        appRow(app, mode: .normal)
                                    }
                                    .contextMenu {
                                        Button {
                                            FileClipboard.copyText(
                                                app.bundleIdentifier,
                                                confirmation: "已复制 Bundle ID"
                                            )
                                        } label: {
                                            Label("复制 Bundle ID", systemImage: "doc.on.doc")
                                        }
                                        Button {
                                            FileClipboard.copyText(app.name, confirmation: "已复制名称")
                                        } label: {
                                            Label("复制名称", systemImage: "character.cursor.ibeam")
                                        }
                                        if let icon = viewModel.icons[app.bundleIdentifier] {
                                            Button {
                                                iconShare = IconSharePayload(image: icon, suggestedName: "\(app.name) 图标.png")
                                            } label: {
                                                Label("提取图标", systemImage: "square.and.arrow.down")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .trailing) {
                if !selecting, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   visible.count > 8 {
                    sectionIndex(letters: sections(in: visible).map(\.letter), proxy: proxy)
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索应用")
        .toolbar {
            if selecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        selecting = false
                        selected.removeAll()
                    }
                    .disabled(viewModel.uninstallStatus != nil)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selectingAllVisible ? "取消全选" : "全选") {
                        toggleSelectAll(visible: visible)
                    }
                    .disabled(viewModel.uninstallStatus != nil || visible.isEmpty)
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("选择") {
                        selected.removeAll()
                        selecting = true
                    }
                    .disabled(viewModel.apps.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                selectionBar
            }
        }
        .alert("卸载选中应用？", isPresented: Binding(
            get: { !pendingUninstall.isEmpty },
            set: { if !$0 { pendingUninstall = [] } }
        )) {
            Button("取消", role: .cancel) { pendingUninstall = [] }
            Button("卸载", role: .destructive) { startUninstall() }
        } message: {
            Text(uninstallConfirmMessage)
        }
        .alert(item: $uninstallResult) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
        .sheet(item: $iconShare) { payload in
            IconShareSheet(image: payload.image, fileName: payload.suggestedName)
        }
    }

    // MARK: - Selection helpers

    private func toggleSelection(_ bundleId: String) {
        if selected.contains(bundleId) {
            selected.remove(bundleId)
        } else {
            selected.insert(bundleId)
        }
    }

    private var selectingAllVisible: Bool {
        !filteredApps.isEmpty && filteredApps.allSatisfy { selected.contains($0.bundleIdentifier) }
    }

    private func toggleSelectAll(visible: [InstalledApp]) {
        if selectingAllVisible {
            for app in visible {
                selected.remove(app.bundleIdentifier)
            }
        } else {
            for app in visible {
                selected.insert(app.bundleIdentifier)
            }
        }
    }

    private var selectionBar: some View {
        let apps = filteredApps.filter { selected.contains($0.bundleIdentifier) }
        return HStack {
            Text("已选 \(apps.count) 项")
                .font(.subheadline)
            Spacer()
            Button(role: .destructive) {
                pendingUninstall = apps
            } label: {
                Label("卸载", systemImage: "trash")
            }
            .disabled(apps.isEmpty || !viewModel.canUninstall || viewModel.uninstallStatus != nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var uninstallConfirmMessage: String {
        let n = pendingUninstall.count
        let prefix = "将卸载 \(n) 个应用。iOS 可能会弹出系统确认对话框。"
        if !viewModel.canUninstall {
            return prefix + "（⚠️ 配对文件未导入 — 请先在「设置」重置后再导入配对文件。）"
        }
        return prefix
    }

    private func startUninstall() {
        let toRemove = pendingUninstall
        pendingUninstall = []
        viewModel.uninstallBatch(toRemove) { _, failures in
            // Successful apps are removed by installd; we just refresh.
            let succeeded = toRemove.count - failures.count
            var msg = "已卸载 \(succeeded) 个应用。"
            if !failures.isEmpty {
                let names = failures.map { "\($0.0.name)（\($0.1.localizedDescription)）" }.joined(separator: "\n")
                msg += "\n失败 \(failures.count) 个：\n\(names)"
            }
            uninstallResult = UninstallResultNotice(title: "卸载完成", message: msg)
            selected.removeAll()
            selecting = false
        }
    }

    // MARK: - Row layout

    private enum RowMode { case normal, select(isSelected: Bool) }

    private func appRow(_ app: InstalledApp, mode: RowMode) -> some View {
        HStack(spacing: 12) {
            if case let .select(checked) = mode {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(checked ? .accentColor : .secondary)
            }
            AppIconView(icon: viewModel.icons[app.bundleIdentifier])
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var emptyListMessage: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "未找到应用。"
        }
        return "没有匹配 “\(query)” 的应用。"
    }

    private var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.apps }
        return viewModel.apps.filter { app in
            app.name.localizedCaseInsensitiveContains(query)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private func sections(in apps: [InstalledApp]) -> [(letter: String, apps: [InstalledApp])] {
        let grouped = Dictionary(grouping: apps) { app -> String in
            let folded = app.name.folding(options: .diacriticInsensitive, locale: .current)
            guard let ch = folded.uppercased().first, ch.isLetter else { return "#" }
            return String(ch)
        }
        let keys = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return keys.map { letter in
            let rows = (grouped[letter] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return (letter, rows)
        }
    }

    private func sectionIndex(letters: [String], proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(minWidth: 14, minHeight: 12)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 1)
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                jumpToLetter(
                                    at: value.location.y,
                                    height: geo.size.height,
                                    letters: letters,
                                    proxy: proxy
                                )
                            }
                    )
            }
        }
    }

    private func jumpToLetter(at y: CGFloat, height: CGFloat, letters: [String], proxy: ScrollViewProxy) {
        guard !letters.isEmpty, height > 0 else { return }
        let unit = height / CGFloat(letters.count)
        let index = Int((y / unit).rounded(.down))
        let clamped = min(max(index, 0), letters.count - 1)
        proxy.scrollTo(letters[clamped], anchor: .top)
    }
}

/// Local `Identifiable` wrapper for showing the post-batch uninstall summary.
struct UninstallResultNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Payload passed to `IconShareSheet` when sharing an extracted app icon.
struct IconSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let suggestedName: String
}

/// Wraps `UIActivityViewController` to share an extracted app icon. The user
/// can save it to the Photos library, Files, AirDrop, etc.
struct IconShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    let fileName: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Materialize the PNG into a temp file so "Save to Files" gives the
        // icon a meaningful name. `UIActivityViewController` will copy the
        // file when the user chooses a file destination.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
