import SwiftUI
import UIKit   // `UIPasteboard`（左滑「复制」源地址）

/// 单源拉取的**超时上限**（秒）。
///
/// 取值 30s 的理由：`SignSourceClient` 的 URLSession 是 `timeoutIntervalForRequest = 15` /
/// `timeoutIntervalForResource = 30`（`SignSourceClient.swift:212-213`）—— 正常情况下 URLSession
/// 会先抛 `.network("请求超时")`；本上限与资源超时同量级，只兜「URLSession 自身超时未触发」的
/// 病态挂起（连接卡死 / 协程未被唤醒）。它的存在意义：让 `await` **一定会退出**，
/// 从而 `updating` 的 `defer` 移除一定会执行（挂起 = `defer` 永不执行 = 永久转圈）。
private let signSourceUpdateTimeout: Duration = .seconds(30)

/// 软件源管理页（源列表）—— 对应规格 `EscapeSpace_软件源管理_实现规格.md` §4.1（截图 1）。
///
/// 职责：
/// · 展示**已添加**的源（源图标 + 源名 + 源地址）；
/// · 添加源（对话框 + 输入校验，对齐全能签的严格规则）、删除源、下拉刷新全部源；
/// · 点一行进入源内 App 列表（`SignSourceAppListView`）。
///
/// ## 依赖（本文件**只引用**，不定义 —— 规格 §2「模型归属」）
/// · `SignSource`（模型）：`EscapeOS/Engine/SignSourceModels.swift`（**已落地**，唯一真源）。
/// · `SignSourceClient.fetch(sourceURL:)`：`EscapeOS/Engine/SignSourceClient.swift`（**已落地**）。
/// · `SignSourceStore.shared`：源清单持久化（规格 §2.2）—— **尚未落地**，由另一位同事补。
///   本文件实际引用的成员见简报「依赖的外部接口清单」。
///
/// ## 右上角工具栏（**接线点**）
/// 规格 §4.1 要求右上角放「**下载管理**」入口（D1=A：进入后默认过滤到软件源）。
/// 本文件**不**直接引用 `IPADownloadManagerView(filterSource: .thirdPartySource)`，
/// 只留一个目标页回调 `downloadManagerDestination`：接线方传入后该项才渲染，
/// 并由**本页自己** `navigationDestination(isPresented:)` 把目标页 push 上去
/// （二级页因此是标准子级 push，带系统返回箭头；详见该属性注释）。
struct SignSourceListView: View {

    // MARK: - 接线点（由另一位同事接线）

    /// 右上角「下载管理」入口的目标页 —— **接线点**（规格 §4.1 / §2.5 / D1）。
    ///
    /// 传 `nil`（默认）时该工具栏项**不渲染**，本文件因此不依赖 `IPADownloadManagerView`，
    /// 可独立编译。接线方传入目标页（如 `IPADownloadManagerView(filterSource: .thirdPartySource)`）
    /// 后，本页右上角渲染「下载管理」入口，点它时**由本页自己**把目标页 push 上去。
    ///
    /// ⚠️ 为什么这个 push 必须声明在**本页**、不能交给 `HomeView` 的根级
    /// `navigationDestination(isPresented:)` 代劳：`isPresented` 目的地在其绑定为 `true` 期间
    /// 会被系统**钉在栈顶**。一级页（本页）自己的 `isPresented` 绑定此时仍为 `true`，
    /// 若再从根级另挂一个 `isPresented` 目的地去 push 二级页，二级页就不是本页的正常子级 push ——
    /// 表现为「二级页没有系统返回箭头、不像二级界面」。把 push 声明在本页即恢复标准子级 push
    /// （系统自动给左上角返回箭头，跟随系统惯例）。
    var downloadManagerDestination: (() -> AnyView)? = nil

    // MARK: - State

    @State private var sources: [SignSource] = []
    @State private var showAddSheet = false
    /// 右上角「下载管理」入口的 push 状态（目标页由接线方经 `downloadManagerDestination` 提供）。
    @State private var showDownloadManager = false
    /// 左上角「日志」入口的呈现状态。
    ///
    /// 用 `.sheet` 而非 push：复用的既有日志页 `LoginLogView` 自带 `NavigationStack` +
    /// 「完成」按钮（它是为 sheet 设计的）—— 若再 push 一层，会嵌出第二套导航栏、
    /// 与系统返回箭头重复（该页的 `onDone` 与返回是同一件事）。sheet 呈现与其设计一致。
    @State private var showLog = false
    @State private var addText = ""
    /// 正在「更新」的源（按 `sourceURL`）—— 行上显示转圈。
    ///
    /// **不变式**：成员只在 `updateOne(_:)` / `refreshAll()` 里成对地「插入 → 移除」，
    /// 且有 `fetchWithTimeout` 的硬超时兜底 ⇒ **任何情况下都会回到空集**（论证见 `updateOne` 注释）。
    @State private var updating: Set<String> = []
    /// 正在「添加」（拉源 + 解析）—— 期间禁用 `+`，防重复提交。
    @State private var adding = false

    var body: some View {
        List {
            if sources.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                } header: {
                    Text("已添加 \(sources.count) 个源")
                } footer: {
                    disclaimer
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("软件源管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // ⓪ 日志（**左上角**，用户指定位置）
            //
            // ⚠️ 本页是 push 进来的，左上角已有**系统返回箭头**。`.topBarLeading` 的自定义项
            // **不会**挤掉返回箭头 —— iOS 会把返回箭头留在最左、自定义项排在其右侧，两者共存，
            // 故「左上角」这一位置可用，无需退让到右上角。
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showLog = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("软件源日志")
            }
            // ① 下载管理（**接线点**，见 `downloadManagerDestination`）
            if downloadManagerDestination != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDownloadManager = true
                    } label: {
                        Image(systemName: "shippingbox")
                    }
                    .accessibilityLabel("下载管理")
                }
            }
            // ② 添加源（对应牛蛙截图 1 的右上角 `+`）
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(adding)
                .accessibilityLabel("添加软件源")
            }
        }
        // 二级页 push 声明在**本页**（而非 `HomeView` 根级）—— 保证是标准子级 push，带系统返回箭头。
        .navigationDestination(isPresented: $showDownloadManager) {
            downloadManagerDestination?() ?? AnyView(EmptyView())
        }
        // 下拉刷新：刷新**全部**源（规格 §4.1）
        .refreshable { await refreshAll() }
        // 左上角「日志」入口 → 复用既有日志页 `LoginLogView`，只显示「软件源」这一类
        // （`categories: [.signSource]` 按分类预筛）。清除也限定本分类，不穿透其它板块。
        .sheet(isPresented: $showLog) {
            LoginLogView(categories: [.signSource],
                         title: "软件源日志",
                         clearCategories: [.signSource])
        }
        // 添加源对话框（规格 §4.1：title「添加软件源」/ message 提示 JSON 地址 / 按钮 添加·取消）
        .alert("添加软件源", isPresented: $showAddSheet) {
            TextField("请输入源地址", text: $addText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("添加") { addSource() }
            Button("取消", role: .cancel) { addText = "" }
        } message: {
            Text("请输入软件源 JSON 地址（http/https）")
        }
        .toastHost()
        .task {
            // 进页面复位「更新中」集合：清掉历史残留 —— 旧实现里泄漏的成员会让该源
            // 被 `refreshAll` 的过滤条件永久跳过（转圈永不清），此处一并抹掉。
            updating.removeAll()
            reload()
        }
    }

    // MARK: - 空态 / 免责声明

    private var emptySection: some View {
        Section {
            InfoActionCard(
                icon: "shippingbox",
                iconTint: .purple,
                title: "还没有添加软件源",
                message: "点右上角 + 添加软件源，软件源内容由第三方提供，请自行确认源的合法性与有效性.",
                actionTitle: "添加软件源",
                action: { showAddSheet = true },
                disabled: adding)
        } footer: {
            disclaimer
        }
    }

    /// 页脚免责声明（规格 §4.1，合规必做）。
    private var disclaimer: some View {
        Text("软件源内容由第三方提供，与 EscapeSpace 无关；请自行确认源的合法性与有效性，勿添加非法应用源.")
            .font(.caption2)
    }

    // MARK: - 源行

    /// 一行：源图标 + 源名 + 源地址；更新中显示转圈；左滑「复制 / 更新 / 删除」；点行进源内 App 列表。
    private func sourceRow(_ source: SignSource) -> some View {
        NavigationLink {
            SignSourceAppListView(source: source)
        } label: {
            HStack(spacing: 12) {
                sourceIcon(source.sourceIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(source.sourceURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if updating.contains(source.sourceURL) {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 复制源地址（非破坏性，排在删除之前）
            Button {
                copy(source)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .tint(.indigo)
            Button {
                update(source)
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
            .tint(.blue)
            // 删除是破坏性操作，排在最后
            Button(role: .destructive) {
                remove(source)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 源图标（模型属性名是 `sourceIcon`，JSON 键才是小写 `sourceicon` —— 见
    /// `SignSourceModels.swift` 的 `CodingKeys`）。
    ///
    /// 渲染交给 `SourceIconView`：它给「加载中」的转圈加了**超时上限**，
    /// 不会再出现「图标地址不返回 ⇒ 行内一直转圈」（详见该类型注释）。
    private func sourceIcon(_ urlString: String?) -> some View {
        SourceIconView(urlString: urlString)
    }

    // MARK: - 动作

    /// 读源清单（本地，同步）。
    private func reload() {
        sources = SignSourceStore.shared.sources()
    }

    /// 添加源：先归一化 + 严格校验，再拉源 → 落库。
    private func addSource() {
        let raw = addText
        addText = ""
        guard !adding else { return }
        guard let normalized = Self.normalizeSourceURLString(raw) else {
            // 规格 §4.1：「无效源地址」→ Toast
            ToastCenter.shared.show("无效源地址")
            return
        }
        if SignSourceStore.shared.contains(sourceURL: normalized) {
            ToastCenter.shared.show("该软件源已添加")
            return
        }
        adding = true
        Task {
            defer { adding = false }
            do {
                let source = try await SignSourceClient.fetch(sourceURL: normalized)
                if SignSourceStore.shared.add(source) {
                    reload()
                    ToastCenter.shared.show("已成功添加")
                } else {
                    ToastCenter.shared.show("添加失败")
                }
            } catch {
                // 规格 §4.1：「添加失败 / 此源不受支持」—— 具体文案由 `SignSourceError` 给出
                ToastCenter.shared.show("添加失败：\(error.localizedDescription)")
            }
        }
    }

    /// 删除源。
    private func remove(_ source: SignSource) {
        SignSourceStore.shared.remove(sourceURL: source.sourceURL)
        reload()
    }

    /// 复制该源的地址到剪贴板（左滑「复制」）。
    ///
    /// 复制内容 = 该源的 `sourceURL`（归一化后的地址，与列表显示一致）。
    private func copy(_ source: SignSource) {
        UIPasteboard.general.string = source.sourceURL
        ToastCenter.shared.show("已复制源地址")
    }

    /// 更新单个源：重拉后覆盖（规格 §2.2 `update(_:)`）。
    ///
    /// 「进入 / 退出 `updating`」的配对收口在 `updateOne(_:)`（见该函数注释）。
    private func update(_ source: SignSource) {
        Task { await updateOne(source.sourceURL) }
    }

    /// 单源「重拉 + 覆盖」的**唯一实现** —— 保证「进入 `updating`」必有「移出 `updating`」。
    ///
    /// ## 一进一出的出口清单（「一定回到空集」论证 · 上半）
    /// · 进入：本函数的 `updating.insert`（**唯一**单源进入点；`update(_:)` 只调它）。
    ///   进入前的 `guard` 与 `insert` 之间**无 `await`**（同一段主 actor 同步代码）⇒ 不会重复拉。
    /// · 退出：`defer` 里的 `updating.remove`，三条路径**都会**执行：
    ///   ① 拉取成功 → 落库 + `reload()`，函数正常返回 → `defer` 执行；
    ///   ② 拉取失败 → `catch` 弹 Toast，函数返回 → `defer` 执行；
    ///   ③ 任务取消（页面消失 / 下拉刷新被中断）→ `await` 抛出 → `catch` 返回 → `defer` 执行。
    /// · 第 ④ 条兜底：`fetchWithTimeout` 在 `signSourceUpdateTimeout` 秒后**强制**抛出，
    ///   保证 `await` 不会永远挂起（挂起 = 函数不退出 = `defer` 不执行 = 永久转圈）。
    private func updateOne(_ sourceURL: String) async {
        guard !updating.contains(sourceURL) else { return }   // 已在更新 ⇒ 幂等跳过
        updating.insert(sourceURL)
        defer { updating.remove(sourceURL) }   // ← 唯一出口
        do {
            let fresh = try await Self.fetchWithTimeout(sourceURL)
            SignSourceStore.shared.update(fresh)
            reload()
            ToastCenter.shared.show("已更新")
        } catch {
            // 取消不是失败：页面消失 / 刷新被中断时不弹「更新失败」。
            if !Task.isCancelled { ToastCenter.shared.show("更新失败") }
        }
    }

    /// 下拉刷新：重拉全部源。
    ///
    /// ## 串行 → 受限并发
    /// 旧实现串行 `await`：N 个源 = Σ 单源耗时（真机实测 2 源 ≈ 5s），转圈逐个亮。
    /// 现按 `maxConcurrentRefreshes` 路并发：墙钟 ≈ ⌈N/上限⌉ × 最慢单源；上限用于压住
    /// 「瞬时网络压力」与「主线程落库（`SignSourceStore` 同步全量读写）的堆积」。
    ///
    /// ## 与 `updating` 的关系（「一定回到空集」论证 · 下半）
    /// · 进入：`for url in targets { updating.insert(url) }`（**唯一**批量进入点）；
    /// · 退出：`while let finished = await group.next() { updating.remove(finished) }` ——
    ///   每个目标**完成即移除**；子任务 `refreshOne` 不抛错（失败被 `try?` 吞掉后仍**返回 url**），
    ///   故 `group.next()` 一定把全部目标逐个交回 ⇒ 全部移除；
    /// · 子任务受 `fetchWithTimeout` 硬上限约束，不会永久挂起 ⇒ 上面的 `while` 一定会结束。
    /// 所有 `updating` 读写都在主 actor（本 View 的隔离域）内，多源并发更新 UI 状态无数据竞争。
    private func refreshAll() async {
        reload()
        let targets = sources.map(\.sourceURL).filter { !updating.contains($0) }
        guard !targets.isEmpty else { return }

        for url in targets { updating.insert(url) }   // 并发 ⇒ 多个转圈同时亮

        await withTaskGroup(of: String.self) { group in
            var next = 0
            let limit = min(Self.maxConcurrentRefreshes, targets.count)
            while next < limit {
                let url = targets[next]
                group.addTask { await Self.refreshOne(url) }
                next += 1
            }
            while let finished = await group.next() {
                updating.remove(finished)              // 该源完成 ⇒ 立即停转圈
                if next < targets.count {
                    let url = targets[next]
                    group.addTask { await Self.refreshOne(url) }
                    next += 1
                }
            }
        }
        reload()
    }

    /// 并发刷新时**同时在途的源数上限**：压瞬时网络压力 + 压主线程落库的堆积。
    private static let maxConcurrentRefreshes = 4

    /// 并发子任务：拉单源并落库，返回 `sourceURL`（供父任务按「完成事件」移除 `updating`）。
    ///
    /// `nonisolated`：网络与解码在后台执行；落库切回主 actor（`SignSourceStore` 按设计只在主线程用）。
    /// 失败静默（与旧 `try?` 语义一致）—— **不抛错**，保证父任务的 `group.next()` 一定收得到结果。
    nonisolated private static func refreshOne(_ sourceURL: String) async -> String {
        if let fresh = try? await fetchWithTimeout(sourceURL) {
            await MainActor.run { SignSourceStore.shared.update(fresh) }
        }
        return sourceURL
    }

    /// 拉单源，**带独立超时**：超过 `signSourceUpdateTimeout` 仍未返回 ⇒ 抛超时错误（并取消底层请求）。
    nonisolated private static func fetchWithTimeout(_ sourceURL: String) async throws -> SignSource {
        try await withThrowingTaskGroup(of: SignSource.self) { group in
            group.addTask { try await SignSourceClient.fetch(sourceURL: sourceURL) }
            group.addTask {
                try await Task.sleep(for: signSourceUpdateTimeout)
                LoginLogger.shared.log("\(SignSourceClient.logTag) 更新超时：\(sourceURL)（\(signSourceUpdateTimeout)）",
                                       category: .signSource)
                throw SignSourceError.network("请求超时")
            }
            defer { group.cancelAll() }
            // 先到者胜：成功 → 返回源；超时 → 抛错（另一子任务被 `cancelAll` 取消）。
            guard let first = try await group.next() else {
                throw SignSourceError.network("请求超时")
            }
            return first
        }
    }

    // MARK: - 源地址归一化 + 校验（规格 §4.1「添加源校验」，对齐全能签的严格规则）

    /// 归一化源地址；不合格返回 `nil`（调用方提示「无效源地址」）。
    ///
    /// 归一化：去首尾空白 → 缺 scheme 补 `http://` → scheme/host 转小写 → 去尾 `/`。
    /// 校验：① 归一化后长度 ≥ 12；② `URL(string:)` 非 nil；③ scheme ∈ {http, https}；
    ///       ④ host 非空且满足「IPv4 正则 ∨ 含 `.` 且 len>3 ∨ 含 `:` 且 len>1」。
    ///
    /// ⚠️ 规格 §5.5 要求本归一化与 `SignSourceStore` 的唯一键归一化**共用同一份**。
    /// 本文件按 §4.1 把它实现为视图内的静态方法（校验属 UI 层）；若 `SignSourceStore`
    /// 另行暴露归一化，请以 store 的为唯一真源并替换此处调用（见简报「与规格不一致处」）。
    static func normalizeSourceURLString(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        guard var comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(),
              let rawHost = comps.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.lowercased()
        // ③ scheme 检查
        guard scheme == "http" || scheme == "https" else { return nil }
        // ④ host 规则
        guard isValidSourceHost(host) else { return nil }
        comps.scheme = scheme
        comps.host = host
        var normalized = comps.string ?? s
        while normalized.hasSuffix("/") { normalized.removeLast() }
        // ① 长度检查（按归一化后的字符串计）
        guard normalized.count >= 12 else { return nil }
        return normalized
    }

    /// host 规则（照抄全能签，规格 §4.1）：
    /// IPv4 正则 `^\d{1,3}(?:\.\d{1,3}){3}$` ∨ 含 `.` 且长度 > 3 ∨ 含 `:` 且长度 > 1。
    private static func isValidSourceHost(_ host: String) -> Bool {
        if host.range(of: #"^\d{1,3}(?:\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return true
        }
        if host.contains(".") && host.count > 3 { return true }
        if host.contains(":") && host.count > 1 { return true }   // IPv6 字面量
        return false
    }
}

// MARK: - 源图标（带超时兜底）

/// 源图标：异步加载 + **转圈超时兜底**。
///
/// ## 为什么需要它（现象）
/// 用户报「软件源管理页第 2 条源左侧一直有个灰色 spinner 不消失」。
/// 左侧那个 spinner 就是 `AsyncImage` 的 `default`（`.empty` / `.loading`）相位渲染的 `ProgressView`：
/// 图标地址来自第三方源（如 `qnq.nuosike.cn` 的 `sourceicon`），当它长时间不返回时，
/// `AsyncImage` 会**一直停在 `default` 相位**（底层 `URLSession` 默认超时很长，≈60s），
/// 表现为行内一个几乎永不消失的小转圈。
///
/// ## 修法
/// 给「转圈」加一个**上限** `spinnerTimeout` 秒：到点无论相位如何都落静态占位。
/// 于是三条出口齐备，spinner **一定会终止**：
/// · 成功 → `.success` 渲染图片；
/// · 失败 → `.failure` 渲染静态图标；
/// · 超时 → 本条 `.task` 置 `timedOut`，渲染静态图标。
private struct SourceIconView: View {

    /// 图标地址（源的 `sourceIcon`；空 / 非法则直接落静态占位）。
    let urlString: String?

    /// 转圈最长可见时长（秒）。超时后转静态占位 —— **不再有永久 spinner**。
    private static let spinnerTimeout: Double = 15

    @State private var timedOut = false

    var body: some View {
        if let s = urlString, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                case .failure:
                    failedIcon
                default:
                    // empty / loading：未超时才转圈；超时后落静态占位
                    if timedOut { failedIcon } else { ProgressView().controlSize(.mini) }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task {
                // 超时兜底：到点即停转圈（视图消失时任务被取消，则不置状态）
                try? await Task.sleep(for: .seconds(Self.spinnerTimeout))
                if !Task.isCancelled { timedOut = true }
            }
        } else {
            placeholder
        }
    }

    /// 加载失败 / 超时的静态占位（灰底图标）—— **不转圈**。
    private var failedIcon: some View {
        Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
    }

    /// 无图标地址时的静态占位（紫色卡片）。
    private var placeholder: some View {
        Image(systemName: "shippingbox.fill")
            .font(.title3)
            .foregroundStyle(.purple)
            .frame(width: 44, height: 44)
            .background(Color.purple.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
