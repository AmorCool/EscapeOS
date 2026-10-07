import SwiftUI

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
    @State private var addText = ""
    /// 正在「更新」的源（按 `sourceURL`）—— 行上显示转圈。
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
        .task { reload() }
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

    /// 一行：源图标 + 源名 + 源地址；更新中显示转圈；左滑「删除 / 更新」；点行进源内 App 列表。
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
            Button(role: .destructive) {
                remove(source)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                update(source)
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
            .tint(.blue)
        }
    }

    /// 源图标（模型属性名是 `sourceIcon`，JSON 键才是小写 `sourceicon` —— 见
    /// `SignSourceModels.swift` 的 `CodingKeys`）。
    /// 没有图标地址时给一个静态占位块，**不要**用一个永远转圈的 `AsyncImage`。
    @ViewBuilder
    private func sourceIcon(_ urlString: String?) -> some View {
        if let s = urlString, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
                default: ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 44, height: 44)
                .background(Color.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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

    /// 更新单个源：重拉后覆盖（规格 §2.2 `update(_:)`）。
    private func update(_ source: SignSource) {
        guard !updating.contains(source.sourceURL) else { return }
        updating.insert(source.sourceURL)
        Task {
            defer { updating.remove(source.sourceURL) }
            do {
                let fresh = try await SignSourceClient.fetch(sourceURL: source.sourceURL)
                SignSourceStore.shared.update(fresh)
                reload()
                ToastCenter.shared.show("已更新")
            } catch {
                ToastCenter.shared.show("更新失败")
            }
        }
    }

    /// 下拉刷新：逐个重拉全部源（串行，避免同时压满网络）。
    private func refreshAll() async {
        reload()
        for source in sources where !updating.contains(source.sourceURL) {
            updating.insert(source.sourceURL)
            if let fresh = try? await SignSourceClient.fetch(sourceURL: source.sourceURL) {
                SignSourceStore.shared.update(fresh)
            }
            updating.remove(source.sourceURL)
        }
        reload()
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
