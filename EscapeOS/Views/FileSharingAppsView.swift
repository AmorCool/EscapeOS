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
    /// v0.3.364：类型筛选（nil = 全部，默认不分类）
    @State private var typeFilter: FileSharingTypeClass?
    @State private var searchText: String = ""
    /// v0.3.364：渐进式类型标签——首屏不等 profile，后台算完一批回填一批
    @State private var appTypes: [String: AppType] = [:]
    @State private var typesSettled = false
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
                        HStack(spacing: 8) {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer(minLength: 0)
                            // v0.3.378：超时/失败态下必须能一键重来
                            //（用户实测反馈：只有「读取超时」没有重试入口 = 完全用不了）
                            Button("重试") { Task { await load() } }
                                .font(.subheadline)
                        }
                    }
                } else {
                    Section {
                        Toggle("仅显示文件共享应用", isOn: $filterEnabledOnly)
                        Picker("类型", selection: $typeFilter) {
                            Text("全部").tag(FileSharingTypeClass?.none)
                            ForEach(FileSharingTypeClass.allCases) { type in
                                Text(type.rawValue).tag(FileSharingTypeClass?.some(type))
                            }
                        }
                    }
                    Section {
                        ForEach(filtered) { app in
                            appRow(app)
                        }
                    } header: {
                        Text("应用列表（\(filtered.count) 个）")
                    }
                }
            }
            .listStyle(.insetGrouped)   // v0.3.214：参考模块板块样式
            // v0.3.378：超时/失败后下拉即可重试（与错误行上的「重试」按钮成对）
            .refreshable { await load() }
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

    /// v0.3.364：三个条件取交集——文件共享开关 ∩ 类型筛选 ∩ 搜索
    private var filtered: [FileSharingApp] {
        var list = apps
        if filterEnabledOnly { list = list.filter { $0.supportsFileSharing } }
        if let typeFilter {
            list = list.filter { (typeClass($0) ?? .unrecognized) == typeFilter }
        }
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
                // v0.3.364：类型文案统一为爱思五类（苹果正版/共享正版/个人签名/
                // 企业签名/系统，算不出=未识别），由 FileSharingTypeClass 单点映射；
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

    /// v0.3.364：类型归类——**判定与文案全部交给 FileSharingTypeClass**（唯一映射点）.
    /// nil = 类型还没算出来（后台渐进加载中），UI 显示占位、不做判断.
    private func typeClass(_ app: FileSharingApp) -> FileSharingTypeClass? {
        FileSharingTypeClass.resolve(
            applicationType: app.applicationType,
            appType: app.appType ?? appTypes[app.bundleId],
            settled: app.appType != nil || typesSettled
        )
    }

    /// v0.3.364：类型显示文案（爱思五类：苹果正版 / 共享正版 / 个人签名 / 企业签名 / 系统）.
    /// 未算出来 → 「识别中」占位，算完（含算不出）→ 收敛到「未识别」.
    private func typeLabel(_ app: FileSharingApp) -> String {
        typeClass(app)?.rawValue ?? "识别中"
    }

    /// v0.3.364：类型胶囊配色——正版蓝 / 共享紫 / 个人签名绿 / 企业签名橙 / 越狱版粉 / 系统灰.
    private func typeTint(_ app: FileSharingApp) -> Color {
        guard let type = typeClass(app) else { return .secondary }   // 识别中 → 灰
        switch type {
        case .appStorePersonal: return .blue
        case .appStoreShared:   return .purple
        case .development:      return .green
        case .enterprise:       return .orange
        case .jailbroken:       return .pink
        case .system:           return .gray
        case .unrecognized:     return .secondary
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

    /// v0.3.364：首屏只等 instproxy 一次 Lookup（名称/标识/大小/Apple ID…），
    /// **不等 profile**；类型标签交给 loadTypes() 后台渐进补齐.
    ///
    /// v0.3.376：**20 秒硬超时**——此前 `defer { loading = false }` 只有在函数返回
    /// 时才执行，而 FFI 全程无超时（见 FileSharingService.listAppsWithFileSharing
    /// (timeout:) 注释），设备/隧道一不应答就永远停在「正在读取已装应用…」。
    /// 现在超时即收口：解除 loading、给最短提示「读取超时」、并把类型占位收敛
    ///（typesSettled = true，不留「识别中」）.
    /// 注：若被放弃的那次读取随后真的返回，下面的 .ok 分支仍会照常填列表
    ///（= 迟到的自愈），不会把用户锁死在超时态.
    private func load() async {
        loading = true
        typesSettled = false
        appTypes = [:]
        defer { loading = false }
        let outcome = await Task.detached(priority: .userInitiated) {
            FileSharingService.listAppsWithFileSharing(timeout: 20)
        }.value
        switch outcome {
        case .ok(let list):
            apps = list
            errorText = nil
            loadIcons()
            loadTypes(for: list)
        case .failed(let message):
            errorText = message
            typesSettled = true
            LoginLogger.shared.log("[文件共享] 文档浏览读取失败：\(message)")
        case .timedOut:
            errorText = "读取超时"
            typesSettled = true
            LoginLogger.shared.log("[文件共享] 文档浏览读取超时（20s），已显示「读取超时」")
        }
    }

    /// v0.3.364：**渐进式**类型补齐——首屏返回后，后台拉一次 profile 快照
    /// （fetchAppTypeContext 内部两条隧道串行、各自释放），再分批判定并回填
    /// `appTypes`（每批算完即刷 @State，不必等全部算完）。
    /// 全部跑完 → typesSettled = true，未判定者收敛到「未识别」，不会停在占位.
    ///
    /// v0.3.378：顺序改成「先可选增强、再判定」，理由：
    ///   - 主列表已改走 `get_apps` 快路径（不带大小/账号字段），而这五个胶囊的
    ///     大小与账号只能来自带属性的 `Lookup`；
    ///   - 增强独立 8 秒、失败就不补（大小胶囊保持「—」），**不影响首屏**
    ///     （列表在 load() 返回时就已渲染）；
    ///   - 先补元数据再判定，共享正版/苹果正版才判得准（isGenuine/appleId 是判据）.
    /// 看门狗 40 秒（= 增强 8s + 上下文 + 分批的余量），到期把占位收敛，不停在「识别中」.
    private func loadTypes(for list: [FileSharingApp]) {
        guard !list.isEmpty else {
            typesSettled = true
            return
        }
        LoginLogger.shared.log("[文件共享] 类型补齐开始：\(list.count) 个应用")
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 40 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !self.typesSettled else { return }
                LoginLogger.shared.log("[文件共享] 类型上下文超时（40s），占位收敛为「未识别」")
                self.typesSettled = true
            }
        }
        Task.detached(priority: .utility) {
            // ① 可选增强：带属性 Lookup（独立 8s，失败就不补）
            var workList = list
            let enhanced = FileSharingService.lookupAppAttributes(timeout: 8)
            if !enhanced.isEmpty {
                let byId = Dictionary(
                    enhanced.map { ($0.bundleId, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                var patched = 0
                for index in workList.indices {
                    guard let e = byId[workList[index].bundleId] else { continue }
                    if workList[index].appSize == nil { workList[index].appSize = e.appSize }
                    if workList[index].docSize == nil { workList[index].docSize = e.docSize }
                    if workList[index].appleId == nil { workList[index].appleId = e.appleId }
                    if workList[index].dsid == nil { workList[index].dsid = e.dsid }
                    if workList[index].purchaseDate == nil { workList[index].purchaseDate = e.purchaseDate }
                    if workList[index].signer == nil { workList[index].signer = e.signer }
                    if e.isGenuine { workList[index].isGenuine = true }
                    patched += 1
                }
                LoginLogger.shared.log("[文件共享] 文档浏览：增强回填 \(patched) 条（大小/账号/正版存在性）")
                await MainActor.run { self.apps = workList }
            }
            // ② profile 上下文 + 分批判定（get_apps 字段 + profile）
            let context = FileSharingService.fetchAppTypeContext()
            let batchSize = 8
            var index = 0
            while index < workList.count {
                let batch = Array(workList[index..<min(index + batchSize, workList.count)])
                let resolved = FileSharingService.detectTypes(for: batch, context: context)
                await MainActor.run {
                    var merged = self.appTypes
                    for (bundleId, type) in resolved { merged[bundleId] = type }
                    self.appTypes = merged
                }
                index += batchSize
            }
            watchdog.cancel()
            await MainActor.run { self.typesSettled = true }
            LoginLogger.shared.log("[文件共享] 类型补齐完成：\(workList.count) 个应用")
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