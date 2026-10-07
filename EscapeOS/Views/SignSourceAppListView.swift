import SwiftUI

/// 源内 App 列表页 —— 对应规格 `EscapeSpace_软件源管理_实现规格.md` §4.2（截图 2）。
///
/// 职责：展示**某个源**里的 App（图标 / 名称 / 版本 / 大小 / 日期 / 描述）；
/// 搜索框 + 筛选弹层（分类 / 价格 / 排序，**全部本地过滤**）；
/// 每行右侧控件由 `lock` 决定文案 —— `lock == true` → 「解锁」，否则「获取」。
///
/// ## 依赖（本文件**只引用**，不定义）
/// · `SignSource` / `SignSourceApp`（模型）：`EscapeOS/Engine/SignSourceModels.swift`（**已落地**，
///   唯一真源）。本文件**严禁**再定义一份（否则 UI 会出现两套 `type` 类型）。
///   ⚠️ 实况：`name` / `bundleIdentifier` 是 **`String?`**；`unlockURL` / `payURL` 的源级继承
///   已由 `SignSource.applyInheritance()` 在解析层完成 ⇒ 视图**只读 App 级字段**即可。
/// · `SignSourceClient.unlock(unlockURL:code:)`：`EscapeOS/Engine/SignSourceClient.swift`（**已落地**）。
/// · `SignSourceStore.shared.update(_:)`：规格 §2.2 的源清单持久化 —— **尚未落地**，由另一位同事补。
/// · `IPADownloadCenter.shared.start(...)` + `IPADownloadCenter.Source.thirdPartySource`：
///   统一下载中心（规格 §5.4；`.thirdPartySource` 档位由规格 §3 #7 新增）。
///
/// ## 职责边界（用户硬边界）
/// 本页**只负责下载**，**不写任何签名 / 安装代码**（规格 §5.4 / §8.3）。
///
/// ## 行排版
/// 行排版与右侧进度控件**复制**自 `I4StoreFreeView`（D4 = 复制，规格 §7.2）：
/// `ChipFlow` / `ChipItem` / `chip` / `trailingControl` 在那份文件里是 file-private，
/// 跨文件用不了，所以在本文件内写一份等价实现，**不改** `I4StoreFreeView`。
struct SignSourceAppListView: View {

    /// 当前源（由源列表页 push 进来）。
    let source: SignSource

    /// 用 `source.apps` 作为 `apps` 初值 —— 避免首帧先渲染一次空态再填数据（源已带 `apps` 缓存）。
    init(source: SignSource) {
        self.source = source
        _apps = State(initialValue: source.apps)
    }

    // MARK: - State

    /// 源内 App。初值取 `source.apps`（见 `init`），解锁成功后重拉源时更新。
    @State private var apps: [SignSourceApp] = []
    @State private var keyword = ""
    /// 分类分段索引（0 = 全部）。**与 `type` 等值匹配**，不是语义映射（规格 §6 ★）。
    @State private var typeFilter: AppTypeFilter = .all
    @State private var priceFilter: PriceFilter = .all
    /// 排序段（抄全能签新增，规格 §6 / §0.1 裁决 4）。
    @State private var sortFilter: SortFilter = .sourceOrder
    @State private var showFilter = false

    /// 正在解锁的那一行（sheet item；规格 §2.4 的 `showUnlock` 用 item 形式表达，见简报）。
    @State private var unlockTarget: SignSourceApp?
    @State private var unlockCode = ""
    @State private var unlockError: String?
    @State private var unlocking = false

    @ObservedObject private var center = IPADownloadCenter.shared
    @Environment(\.openURL) private var openURL

    // MARK: - 筛选档位（文案照抄牛蛙；价格档用「收费」对齐全能签）

    /// 分类分段：**只提供 index** —— `type == rawValue` 等值匹配。
    ///
    /// ⚠️ `case` 名刻意**不写语义**（规格 §6 明令禁止 `case .ipa = 1` 这类
    /// 「把 `type` 取值写进代码常量」的写法）。标签文案在 `title` 里，仅作 UI 文案，
    /// **不代表** `type` 的语义 —— `type` 是源作者的自定义分类，客户端不解释。
    enum AppTypeFilter: Int, CaseIterable, Identifiable {
        case all = 0
        case index1 = 1
        case index2 = 2
        case index3 = 3
        case index4 = 4
        case index5 = 5

        var id: Int { rawValue }

        /// 档位文案（照抄牛蛙 6 档，规格 §6）。**不得新增「其它」兜底档。**
        var title: String {
            switch self {
            case .all:    return "全部"
            case .index1: return "应用"
            case .index2: return "游戏"
            case .index3: return "影音"
            case .index4: return "工具"
            case .index5: return "插件"
            }
        }
    }

    /// 价格分段：免费 → `lock == false`、收费 → `lock == true`（规格 §6）。
    /// 档位文案用「**收费**」（对齐全能签；牛蛙是「付费」，规格 §0.1 裁决 4）。
    enum PriceFilter: Int, CaseIterable, Identifiable {
        case all = 0
        case free = 1
        case paid = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .all:  return "全部"
            case .free: return "免费"
            case .paid: return "收费"
            }
        }
    }

    /// 排序段（抄全能签新增，牛蛙没有 —— 规格 §6 / §0.1 裁决 4）。
    /// case 名用 `sourceOrder`（源序）而非 `default` —— 避开 `default` 关键字。
    enum SortFilter: Int, CaseIterable, Identifiable {
        case sourceOrder = 0
        case name = 1
        case newest = 2
        case oldest = 3

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .sourceOrder: return "默认"
            case .name:        return "名称"
            case .newest:      return "最新"
            case .oldest:      return "最旧"
            }
        }
    }

    var body: some View {
        List {
            if filteredApps.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(filteredApps) { app in
                        appRow(app)
                    }
                } header: {
                    Text("共 \(filteredApps.count) 款")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        // 搜索框常驻（抄 `I4StoreFreeView.swift:154-156` 的写法）
        .searchable(text: $keyword,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("筛选") { showFilter = true }
            }
        }
        .sheet(isPresented: $showFilter) { filterSheet }
        .sheet(item: $unlockTarget) { app in unlockSheet(app) }
        .toastHost()
    }

    // MARK: - 过滤（**全部本地**，不传服务端；规格 §6）

    /// 过滤 + 排序后的列表。**只算一次**（不在 `ForEach` 的行 body 里重复 filter ——
    /// 大源可达数万条，规格 §6「大源性能注记」）。
    private var filteredApps: [SignSourceApp] {
        var result = apps

        // 搜索：`name` / `bundleIdentifier` 本地不区分大小写子串匹配（规格 §6）
        // 两者在模型里都是 `String?` ⇒ 先归一到 `""`。
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kw.isEmpty {
            result = result.filter {
                ($0.name ?? "").localizedCaseInsensitiveContains(kw)
                    || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(kw)
            }
        }

        // 分类：**等值匹配** `type == 分段索引`（规格 §6 ★，绝不做语义映射）
        if typeFilter != .all {
            result = result.filter { $0.type == typeFilter.rawValue }
        }

        // 价格：免费 → lock == false；收费 → lock == true（per-app，规格 §6）
        switch priceFilter {
        case .all:  break
        case .free: result = result.filter { !$0.lock }
        case .paid: result = result.filter { $0.lock }
        }

        // 排序（本地；默认 = 源序）
        switch sortFilter {
        case .sourceOrder: break
        case .name:        result.sort { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
        case .newest:      result.sort { ($0.versionDate ?? "") > ($1.versionDate ?? "") }
        case .oldest:      result.sort { ($0.versionDate ?? "") < ($1.versionDate ?? "") }
        }

        return result
    }

    // MARK: - 空态

    private var emptySection: some View {
        Section {
            if apps.isEmpty {
                Text("这个源里没有应用").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("没有匹配的应用，试试换个关键词或筛选条件")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 筛选弹层（分类 / 价格 / 排序，三段）

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("分类") {
                    Picker("分类", selection: $typeFilter) {
                        ForEach(AppTypeFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("价格") {
                    Picker("价格", selection: $priceFilter) {
                        ForEach(PriceFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("排序") {
                    Picker("排序", selection: $sortFilter) {
                        ForEach(SortFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("重置") {
                        typeFilter = .all
                        priceFilter = .all
                        sortFilter = .sourceOrder
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showFilter = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - App 行

    /// 一行：图标 + 名称 + 胶囊（版本 / 大小 / 日期）+ 描述 + 右侧控件。
    ///
    /// ⚠️ **缺 `downloadURL` 的行不丢弃**（规格 §4.2 / §5.2 步骤⑤）：保留显示但**灰显 + 按钮禁用**
    /// —— 否则 `napi.ltd/pan` 这类「瘦身变体」会让整个源看起来是空的。
    private func appRow(_ app: SignSourceApp) -> some View {
        HStack(alignment: .center, spacing: 12) {
            appIcon(app.iconURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(app))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ChipFlow(spacing: 6) {
                    ForEach(chips(app), id: \.text) { item in
                        chip(item.text, item.tint)
                    }
                }
                if let d = app.versionDescription ?? app.localizedDescription, !d.isEmpty {
                    Text(d)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trailingControl(app)
        }
        .padding(.vertical, 3)
        // 缺 downloadURL ⇒ 整行灰显（按钮在 `trailingControl` 里另外禁用）
        .opacity(app.isInstallable ? 1 : 0.45)
    }

    /// App 图标；无地址时给静态占位（不要一个永远转圈的 `AsyncImage`）。
    @ViewBuilder
    private func appIcon(_ urlString: String?) -> some View {
        if let s = urlString, !s.isEmpty, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                default: ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Image(systemName: "app.dashed")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 版本 / 大小 / 日期 —— 一行放不下由 `ChipFlow` 整块换行（与 `I4StoreFreeView` 同款）。
    private func chips(_ app: SignSourceApp) -> [ChipItem] {
        var out: [ChipItem] = []
        if let v = app.version, !v.isEmpty { out.append(ChipItem(text: "v\(v)", tint: .blue)) }
        if let s = app.size, s > 0 {
            out.append(ChipItem(text: IPADownloadLibrary.sizeText(Int64(s)), tint: .green))
        }
        if let d = app.versionDate, !d.isEmpty { out.append(ChipItem(text: d, tint: .orange)) }
        return out
    }

    /// 胶囊：单行 + 定宽，绝不折行（复制自 `I4StoreFreeView.chip`）。
    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }

    // MARK: - 右侧控件（文案由 `lock` 决定）

    /// 有任务 → 进度 + 暂停 / 删除；否则按 `lock` 给「解锁」或「获取」。
    ///
    /// · `lock == true` → 「解锁」（规格 §4.2 / D6）；
    /// · `lock == false` → 「获取」（全能签文案，规格 §0.1 裁决 4）；
    /// · 缺 `downloadURL` → 「获取」按钮**禁用**；
    /// · `lock == true` 但 App 级与源级 `unlockURL` **都为空** → **禁用解锁入口**
    ///   （ESign / AltStore 家族无源级 `unlockURL`，规格 §4.2 / R8）。
    @ViewBuilder
    private func trailingControl(_ app: SignSourceApp) -> some View {
        if let job = center.activeJob(bundleId: app.bundleIdentifier, name: displayName(app)) {
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, job.overall)))
                    .frame(width: 40)
                Text(job.phase == .paused ? "已暂停" : job.stageText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    if job.phase == .paused {
                        center.resume(job.id)
                    } else {
                        center.pause(job.id)
                    }
                } label: {
                    Image(systemName: job.phase == .paused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(job.canPause ? Color.blue : Color.secondary)
                .disabled(!job.canPause)
                Button {
                    center.cancel(job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .fixedSize()
        } else if app.lock {
            // 解锁入口：模型已把源级 `unlockURL` 继承进 App 级（`applyInheritance()`），
            // 所以这里只看 App 级；为空 ⇒ 禁用解锁（ESign/AltStore 家族无源级 unlockURL，规格 §4.2 / R8）。
            let unlockable = app.unlockURL != nil
            Button {
                beginUnlock(app)
            } label: {
                Text("解锁")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .disabled(!unlockable)
            .opacity(unlockable ? 1 : 0.4)
        } else {
            Button {
                download(app)
            } label: {
                Text("获取")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.14), in: Capsule())
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(!app.isInstallable)
        }
    }

    // MARK: - 下载（**只调下载中心**，不签名 / 不安装）

    private func download(_ app: SignSourceApp) {
        guard let url = app.downloadURL else {
            ToastCenter.shared.show("该应用没有可用的安装包")
            return
        }
        _ = IPADownloadCenter.shared.start(name: displayName(app),
                                           bundleId: app.bundleIdentifier,
                                           version: app.version,
                                           iconURL: app.iconURL,
                                           remoteURL: url,
                                           // 新档位（规格 §3 #7，由另一位同事加入 `Source` 枚举）
                                           source: .thirdPartySource,
                                           // 源链无 sinf（规格 §5.4 / D2）
                                           sinfBase64: nil)
    }

    /// 行标题 / 下载任务名：`name` 在模型里是 `String?` ⇒ 退回 bundleId，再退回占位。
    /// 行与下载任务必须用**同一个**名字，否则 `activeJob` 按名字匹配时挂不上进度。
    private func displayName(_ app: SignSourceApp) -> String {
        if let n = app.name, !n.isEmpty { return n }
        if let b = app.bundleIdentifier, !b.isEmpty { return b }
        return "未知应用"
    }

    // MARK: - 解锁（D6）

    // 说明：`unlockURL` / `payURL` 的**源级继承**已由 `SignSource.applyInheritance()` 在
    // `SignSourceClient.parse` 里完成（模型 `SignSourceApp.unlockURL/payURL` 即为生效值），
    // 所以本层直接读 App 级字段，**不再**在视图里重做一遍继承。

    private func beginUnlock(_ app: SignSourceApp) {
        unlockCode = ""
        unlockError = nil
        unlocking = false
        unlockTarget = app
    }

    private func closeUnlock() {
        unlockTarget = nil
        unlockCode = ""
        unlockError = nil
    }

    private func performUnlock(_ app: SignSourceApp) {
        let code = unlockCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            // 规格 §4.2 / R6：空码拦截
            unlockError = "解锁码不能为空"
            return
        }
        guard let url = app.unlockURL else {
            unlockError = "该源未提供解锁接口"
            return
        }
        unlocking = true
        unlockError = nil
        Task {
            defer { unlocking = false }
            do {
                try await SignSourceClient.unlock(unlockURL: url, code: code)
                ToastCenter.shared.show("解锁成功")
                closeUnlock()
                await reloadSource()
            } catch {
                unlockError = error.localizedDescription
            }
        }
    }

    /// 解锁成功后重拉源，刷新本页列表并覆盖本地缓存（规格 §4.2）。
    private func reloadSource() async {
        guard let fresh = try? await SignSourceClient.fetch(sourceURL: source.sourceURL) else { return }
        apps = fresh.apps
        SignSourceStore.shared.update(fresh)
    }

    /// 解锁弹窗（TextField「请输入解锁码」+「解锁 / 获取解锁码」）。
    private func unlockSheet(_ app: SignSourceApp) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("请输入解锁码", text: $unlockCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("解锁软件源")
                } footer: {
                    if let unlockError {
                        Text(unlockError).foregroundStyle(AppTheme.danger)
                    }
                }
                Section {
                    Button {
                        performUnlock(app)
                    } label: {
                        HStack {
                            Spacer()
                            if unlocking { ProgressView().controlSize(.small) }
                            Text("解锁")
                            Spacer()
                        }
                    }
                    .disabled(unlocking)
                    // 「获取解锁码」只在提供了 `payURL` 时渲染（规格 §4.2「无解锁入口可渲染」）
                    if let pay = app.payURL, let url = URL(string: pay) {
                        Button("获取解锁码") { openURL(url) }
                    }
                }
            }
            .navigationTitle(displayName(app))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { closeUnlock() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 胶囊自动换行布局（**复制**自 `I4StoreFreeView`，D4 = 复制，规格 §7.2）

/// 一颗胶囊（文本 + 着色），供 `ChipFlow` 使用。
private struct ChipItem {
    let text: String
    let tint: Color
}

/// 一行放得下就横排，放不下就把**整个胶囊**挪到下一行 —— 不缩字号、不折行内文字、不截断。
///
/// 与 `I4StoreFreeView.swift` 里的同名类型**各自 file-private**，互不可见，故可同名共存。
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > limit {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widest = max(widest, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widest, limit), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
