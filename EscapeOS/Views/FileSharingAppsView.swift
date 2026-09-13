import SwiftUI
import UIKit

/// v0.3.208：文档共享应用列表（iDescriptor InstalledApps 文件共享过滤移植）.
/// 区分可浏览（UIFileSharingEnabled=true）与不可浏览；点击可浏览项进入文件树.
/// v0.3.219：真实 App 图标（SpringBoardServices）+ 模块板块风格顶栏（.large + searchable）.
struct FileSharingAppsView: View {
    @State private var apps: [FileSharingApp] = []
    @State private var icons: [String: UIImage] = [:]
    @State private var loading = true
    @State private var errorText: String?
    @State private var filterEnabledOnly = true
    @State private var searchText: String = ""
    /// v0.3.270：Documents 容器大小（bundleId → 字节，后台懒算回填）
    @State private var docSizes: [String: Int64] = [:]
    @State private var computingDocs: Set<String> = []
    /// v0.3.291：安装来源详情弹窗（取代已失效的 Archive 深读）
    @State private var detailApp: FileSharingApp?
    /// v0.3.292：图标批量选择导出（原实现只能「全部导出」——改为可多选/全选后导出）
    @State private var selectingIcons = false
    @State private var selectedIcons: Set<String> = []
    @State private var exportingIcons = false

    var body: some View {
        List(selection: $selectedIcons) {
                if loading {
                    Section {
                        HStack { ProgressView(); Text("正在读取已装应用…") }
                    }
                } else if let err = errorText {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        Toggle("仅显示文件共享应用", isOn: $filterEnabledOnly)
                    }
                    Section {
                        ForEach(filtered) { app in
                            appRow(app)
                        }
                    } header: {
                        Text("应用列表（\(filtered.count) 个）")
                    } footer: {
                        Text("安装来源与应用板块同源判定：正版（本人 App Store）/ 共享（他人 App Store）/ AppStore（无法判别）/ 个人签名（自签·调试·Ad-Hoc）/ 企业签名（In-House）/ 隐藏 / 系统（非用户应用）。点击任意胶囊查看来源详情。")
                            .font(.caption2)
                    }
                }
            }
            .listStyle(.insetGrouped)   // v0.3.214：参考模块板块样式
            // v0.3.292：图标批量选择模式
            .environment(\.editMode, .constant(selectingIcons ? .active : .inactive))
        .navigationTitle("文档浏览")
        .navigationBarTitleDisplayMode(.large)  // v0.3.212：参考模块板块顶栏样式
        // v0.3.289：displayMode .always → .automatic——always 时搜索框常驻悬浮，
        // 列表首行会被压在搜索框下面（用户截图实锤「显示不全」）；automatic 随滚动收起.
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索应用")
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)   // v0.3.214：系统搜索框替代自绘
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectingIcons {
                    Button(allIconsSelected ? "取消全选" : "全选") { toggleSelectAllIcons() }
                        .disabled(exportingIcons)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selectingIcons {
                    Button {
                        exportSelectedIcons()
                    } label: {
                        if exportingIcons {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("导出(\(selectedIcons.count))")
                        }
                    }
                    .disabled(exportingIcons || selectedIcons.isEmpty)
                } else {
                    Button {
                        selectedIcons.removeAll()
                        selectingIcons = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .accessibilityLabel("批量选择应用图标")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selectingIcons {
                    Button("完成") { selectingIcons = false }
                        .disabled(exportingIcons)
                }
            }
        }
        .autocorrectionDisabled()
        // v0.3.291：安装来源详情
        .sheet(item: $detailApp) { app in
            NavigationStack {
                appleIdDetailSheet(app)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { detailApp = nil }
                        }
                    }
            }
        }
        .toastHost()
        .task {
            await load()
            // v0.3.288：不再自动跑 AFC 递归算文档大小——v0.3.284 起由 Lookup 的
            // DynamicDiskUsage 一次返回（原实现每 App 开 house_arrest 隧道 + 全树
            // 遍历，20 个 App 时列表长时间「计算中」，用户实测卡顿）.
        }
        // v0.3.270：切换「仅显示文件共享应用」/搜索结果变化时补算新出现项的文档大小

    }

    private var filtered: [FileSharingApp] {
        var list = apps
        if filterEnabledOnly { list = list.filter { $0.supportsFileSharing } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { $0.bundleId.lowercased().contains(q) || $0.name.lowercased().contains(q) }
        }
        return list
    }

    @ViewBuilder
    private func appRow(_ app: FileSharingApp) -> some View {
        Group {
            // v0.3.292：选择模式下禁用导航，避免与多选冲突
            if app.supportsFileSharing && !selectingIcons {
                NavigationLink {
                    AppFileBrowserView(bundleId: app.bundleId, appName: app.name)
                } label: {
                    appContent(app)
                }
            } else {
                appContent(app)
            }
        }
        .tag(app.bundleId)
    }

    /// v0.3.292：图标批量导出——选中的项（原为固定「全部导出」）
    private func exportSelectedIcons() {
        guard !exportingIcons else { return }
        let targets = apps.filter { selectedIcons.contains($0.bundleId) }
        guard !targets.isEmpty else { return }
        exportingIcons = true
        ToastCenter.shared.show("正在导出 \(targets.count) 个图标…")
        Task.detached(priority: .utility) {
            let discovery = AppDiscovery()
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("AppIcons", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var count = 0
            for app in targets {
                if let icon = discovery.appIcon(for: app.bundleId),
                   let data = icon.pngData() {
                    let safeName = app.bundleId.replacingOccurrences(of: "/", with: "_")
                    let url = dir.appendingPathComponent("\(safeName).png")
                    try? data.write(to: url)
                    count += 1
                }
            }
            let total = count
            await MainActor.run {
                exportingIcons = false
                ToastCenter.shared.show("已导出 \(total)/\(targets.count) 个图标到 Documents/AppIcons/")
            }
            LoginLogger.shared.log("[ExportIcons] 导出 \(total)/\(targets.count) 个图标")
        }
    }

    /// 当前列表（受筛选影响）是否已全选
    private var allIconsSelected: Bool {
        !filtered.isEmpty && filtered.allSatisfy { selectedIcons.contains($0.bundleId) }
    }

    private func toggleSelectAllIcons() {
        if allIconsSelected {
            selectedIcons.removeAll()
        } else {
            selectedIcons.formUnion(filtered.map(\.bundleId))
        }
    }

    private func appContent(_ app: FileSharingApp) -> some View {
        HStack(spacing: 12) {
            appIcon(app.bundleId)
            VStack(alignment: .leading, spacing: 4) {
                // v0.3.363：标题允许换行不截断（2 行）
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // v0.3.363：bundleId 去掉 lineLimit(1)，改为可换行（用户要求「可换行但不能显示不全」）
                Text(app.bundleId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // v0.3.363：类型改为与「应用」板块同源的 AppType（正版/共享/个人签名/
                // 企业签名/隐藏/未知），非 User 的系统应用显示「系统」；
                // 所有胶囊都可点开「安装来源」详情（此前只有 AppleID 胶囊能点）。
                HStack(spacing: 5) {
                    tappableCapsule(typeLabel(app), tint: typeTint(app), app: app)
                    appleIdCapsule(app)
                }
                // v0.3.363：尺寸拆成两行，给每个胶囊整行宽度 → 文本 2 行换行，不出现省略号
                HStack(spacing: 5) {
                    if !app.version.isEmpty {
                        tappableCapsule("v\(app.version)", tint: .blue, app: app)
                    }
                    tappableCapsule("应用 \(FileSharingService.formatMB(app.appSize))", tint: .green, app: app)
                }
                HStack(spacing: 5) {
                    tappableCapsule(docCapsuleText(app), tint: .orange, app: app)
                }
            }
            Spacer()
            if app.supportsFileSharing {
                Image(systemName: "doc.text.fill").foregroundStyle(.blue)
            } else {
                Text("未开启")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// v0.3.363：类型显示文案——**与「应用」板块同一套 AppTypeDetector**.
    /// 非 User（System / HiddenSystemApp 之外的非用户应用）统一显示「系统」，
    /// 不再被打成「共享正版」（爱思对系统应用有单独分类）。
    private func typeLabel(_ app: FileSharingApp) -> String {
        if app.applicationType != "User" { return "系统" }
        return (app.appType ?? .unknown).rawValue
    }

    /// v0.3.363：类型胶囊配色——与应用板块 AppTypeBadge 对齐；「系统」单独一档（灰）.
    private func typeTint(_ app: FileSharingApp) -> Color {
        if app.applicationType != "User" { return .gray }
        switch app.appType ?? .unknown {
        case .appStorePersonal: return .blue
        case .appStoreShared:   return .purple
        case .appStore:         return .indigo
        case .enterprise:       return .orange
        case .development:      return .green
        case .hidden, .unknown: return .secondary
        }
    }

    /// v0.3.291：Apple ID 胶囊——直接显示 instproxy 返回的真实账号邮箱
    /// （iTunesMetadata → downloadInfo.accountInfo.AppleID）；无则按爱思显示 "-"。
    /// 点击弹出详情（账号 / DSID / 购买时间 / 签名来源）。
    private func appleIdCapsule(_ app: FileSharingApp) -> some View {
        let text = app.appleId ?? "-"
        let tint: Color = app.appleId != nil ? .purple : .gray
        return tappableCapsule(text, tint: tint, app: app)
    }

    /// v0.3.363：胶囊视觉（文本可换行到 2 行，不截断）
    private func capsuleLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }

    /// v0.3.363：可点击胶囊——点任意胶囊都打开同一个「安装来源」详情
    /// （最小改法：每个胶囊各自 Button，不把整行包成 Button，避免吃掉
    ///  NavigationLink 进入箭头 / 滑动手势）.
    private func tappableCapsule(_ text: String, tint: Color, app: FileSharingApp) -> some View {
        Button {
            detailApp = app
        } label: {
            capsuleLabel(text, tint: tint)
        }
        .buttonStyle(.plain)
    }

    /// v0.3.291：安装来源详情。（原 Archive 深读通道在 iOS 27 已失效——
    /// instproxy Archive 返回 UnknownCommand，真机实证。）
    private func appleIdDetailSheet(_ app: FileSharingApp) -> some View {
        List {
            Section("安装来源") {
                detailRow("类型", typeLabel(app))
                detailRow("Apple ID", app.appleId ?? "-")
                if let dsid = app.dsid { detailRow("账号 DSID", dsid) }
                if let date = app.purchaseDate { detailRow("购买时间", date) }
            }
            if let signer = app.signer, !signer.isEmpty {
                Section("签名身份") {
                    Text(signer).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("应用") {
                detailRow("名称", app.name)
                detailRow("标识", app.bundleId)
                detailRow("版本", app.version.isEmpty ? "-" : app.version)
                detailRow("应用大小", FileSharingService.formatMB(app.appSize))
                detailRow("文档大小", docCapsuleText(app))
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func docCapsuleText(_ app: FileSharingApp) -> String {
        // v0.3.271：优先 Browse 返回的 DynamicDiskUsage（一次请求即得）；缺失才走
        // house_arrest AFC 递归懒算.
        if let size = app.docSize ?? docSizes[app.bundleId] {
            return "文档 \(FileSharingService.formatMB(size))"
        }
        if computingDocs.contains(app.bundleId) {
            return "文档 计算中…"
        }
        return "文档 —"
    }

    /// v0.3.271：后台逐 App 计算 Documents 容器大小——仅对 Browse 未返回
    /// DynamicDiskUsage 的项兜底（Browse 已返回的项不再重复开隧道）.
    private func computeDocumentSizes() {
        let targets = filtered.filter { $0.supportsFileSharing && $0.docSize == nil && docSizes[$0.bundleId] == nil && !computingDocs.contains($0.bundleId) }
        guard !targets.isEmpty else { return }
        for app in targets {
            let bundleId = app.bundleId
            computingDocs.insert(bundleId)
            Task.detached(priority: .utility) {
                let size = try? FileSharingService.computeDocumentsSize(bundleId: bundleId)
                await MainActor.run {
                    computingDocs.remove(bundleId)
                    if let size {
                        docSizes[bundleId] = size
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            apps = try await Task.detached(priority: .userInitiated) {
                try FileSharingService.listAppsWithFileSharing()
            }.value
            errorText = nil
            loadIcons()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// v0.3.219：后台批量拉真实 App 图标（SpringBoardServices，AppDiscovery 同源）
    private func loadIcons() {
        let ids = apps.map { $0.bundleId }
        guard !ids.isEmpty else { return }
        let discovery = AppDiscovery()
        Task.detached(priority: .utility) {
            for id in ids {
                guard let icon = discovery.appIcon(for: id) else { continue }
                await MainActor.run { self.icons[id] = icon }
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ bundleId: String) -> some View {
        if let img = icons[bundleId] {
            Image(uiImage: img)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
        }
    }
}