import SwiftUI
import Foundation

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
/// `ChipFlow` / `ChipItem` 已提升为共享件（`Shared/ChipFlow.swift`），本文件直接用；
/// 胶囊 `chip` 已改用共享 `PackageChip`；`trailingControl` 仍是本文件内的等价实现。
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

    // MARK: - 可操作性判定（**只看真正需要的字段**）

    /// 能否下载：**只要求 `downloadURL` 非空**，不看 `bundleIdentifier`。
    ///
    /// 根因（用户截图「整页朦胧灰 + 获取点不动」）：模型 `SignSourceApp.isInstallable`
    /// （`Engine/SignSourceModels.swift:96`）要求 `bundleIdentifier` 与 `downloadURL` **同时非空**；
    /// 但全能签 / 牛蛙这一支 `appstore` schema 家族（实测 `qnq.nuosike.cn` 34/34、
    /// `hujiao.xyz` 1991/1991、`xiaoxin.kaluo.xyz` 28026/28026）**整源都没有 `bundleIdentifier` 键**
    /// ⇒ 恒为 nil ⇒ 每行都 `isInstallable == false` ⇒ 整页 `.opacity(0.45)` + 「获取」恒禁用。
    /// 而下载真正需要的只有 `downloadURL`（这些源都有值）。故视图层改按 `downloadURL` 判定。
    private func canDownload(_ app: SignSourceApp) -> Bool {
        !(app.downloadURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 本行是否还有可用动作：需解锁 → 看解锁入口；否则 → 看能否下载。
    /// 与 `trailingControl` 里按钮各自的 `.disabled(...)` **同一判据**，避免「按钮可点但整行发灰」。
    private func rowEnabled(_ app: SignSourceApp) -> Bool {
        app.lock ? (app.unlockURL != nil) : canDownload(app)
    }

    // MARK: - 日期格式化

    /// `versionDate`（ISO8601 串）→ `MM-dd HH:mm`。
    ///
    /// 解析与显示统一交给共享工具 `DateText`（`Engine/DateText.swift`）。本页原先自写了一套
    /// 等价实现（两个 `ISO8601DateFormatter` + 一个 `DateFormatter`），那是全仓第 4 份重复的
    /// 日期解析；且 Swift 6 并发检查下 `ISO8601DateFormatter` 非 Sendable，不能作静态实例。
    /// 收敛到 `DateText` 后，口径与各详情页一致，也一并消掉了那三个静态实例。
    ///
    /// · 字段缺失 / 空串 → `nil`（**不记日志**，属正常缺省）；
    /// · 有值但解析失败 → 记一条日志并返回 `nil`（**绝不把原始串丢到界面上**）。
    private func formattedVersionDate(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        guard let text = DateText.string(from: trimmed, style: .compact) else {
            LoginLogger.shared.log("\(SignSourceClient.logTag) versionDate 解析失败：\(trimmed)",
                                   category: .appStore)
            return nil
        }
        return text
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
                        PackageChip(text: item.text, tint: item.tint, horizontalPadding: 5)
                    }
                }
                if let d = app.versionDescription ?? app.localizedDescription, !d.isEmpty {
                    // 可换行 + 「展开 / 收起」；默认 3 行、**不画省略号**（见共享 `ExpandableText`）。
                    // 组件默认值与旧私有实现逐项一致 ⇒ 视觉零变化（首帧 3 行、不画 `…`、仅真截断出「展开」）。
                    ExpandableText(text: d)
                }
            }
            Spacer(minLength: 6)
            trailingControl(app)
        }
        .padding(.vertical, 3)
        // 该行没有任何可用动作（既不能下载、也不能解锁）⇒ 整行灰显
        // （按钮在 `trailingControl` 里用同一判据另外禁用）。
        // ⚠️ 判据**不是** `app.isInstallable`：那个属性还要求 `bundleIdentifier` 非空，
        // 而全能签 / 牛蛙这一支 `appstore` schema 家族**整源没有 `bundleIdentifier` 键**
        // ⇒ 会让整页每行都恒灰、「获取」恒禁用（用户截图）。详见 `rowEnabled(_:)`。
        .opacity(rowEnabled(app) ? 1 : 0.45)
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
        if let d = formattedVersionDate(app.versionDate) {
            out.append(ChipItem(text: d, tint: .orange))
        }
        return out
    }

    // MARK: - 行键与状态认行（修「一个任务挂到多行」）

    /// 本行的**唯一行键** —— 该行的 `downloadURL`。
    ///
    /// 为什么用它：源里可能有多条**同名** App（真机样本 `qnq.nuosike.cn` 有 3 条「全能签」，
    /// 且整源 `bundleIdentifier` 恒为 nil），而**同一个源里每条 App 的 `downloadURL` 唯一**。
    /// 用 `downloadURL` 当行键 ⇒ 行与任务一一对应，不再靠 `name` / `bundleId` 这种会撞车的字段。
    ///
    /// 无 `downloadURL` 的行返回 `nil`：这类行**不能下载**（`download(_:)` 里有 guard），
    /// 也**绝不允许**退化成「同名即命中」—— 返回 nil 后该行恒走「获取 / 解锁」分支。
    private func rowKey(_ app: SignSourceApp) -> String? {
        guard let s = app.downloadURL, !s.isEmpty else { return nil }
        return s
    }

    /// 本行正在进行的任务 —— **只按行键（`downloadURL`）匹配**。
    ///
    /// 关键：`download(_:)` 起任务时把本行的 `downloadURL` **原样**写进 `Job.remoteURL`
    /// （`start(remoteURL:)`），且第三方软件源这条链路**不会改写**它
    /// ⇒ `job.remoteURL == 本行 downloadURL` 就是「这个任务由这一行发起」的精确判据。
    ///
    /// 由此得到两个保证：
    /// · **一个任务只挂一行**：一个 `Job` 只有一个 `remoteURL`，而行键逐行唯一
    ///   ⇒ 至多命中「`downloadURL` 等于它的那一行」；
    /// · **取消 / 暂停作用在自己那个任务上**：按钮拿到的 `job` 就是本行发起的那一个，
    ///   `cancel(job.id)` / `pause(job.id)` 只作用于它。
    ///
    /// ⚠️ 这里**刻意不复用** `center.activeJob(bundleId:name:)`：那个重载在 `bundleId == nil`
    /// 时退化成 `job.name == name`，正是「3 条同名全能签同时显示下载中」的根因。
    private func activeJob(for app: SignSourceApp) -> IPADownloadCenter.Job? {
        guard let key = rowKey(app) else { return nil }
        return center.jobs.first { $0.phase.isBusy && $0.remoteURL == key }
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
        if let job = activeJob(for: app) {
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
                    // 按**实际结果**提示：台账只读 / 文件被占用时删除被拒，不能默默当成功
                    // （口径同 `IPADownloadManagerView.reportRemoval`）。
                    if let result = center.cancel(job.id) {
                        switch result {
                        case .removed:
                            ToastCenter.shared.show("已删除安装包")
                        case .rejectedReadOnly:
                            ToastCenter.shared.show("未删除安装包：下载台账文件损坏，本次改动未保存")
                        case .fileRemovalFailed:
                            ToastCenter.shared.show("未删除安装包：文件无法删除（可能被占用）")
                        }
                    } else {
                        // `nil` = 还没有落地文件（任务还在下载）→ 只是取消，没有删除动作。
                        ToastCenter.shared.show("已取消下载")
                    }
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
            .disabled(!canDownload(app))
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
    /// **仅用于展示与任务名**；状态认行已改为按行键（`downloadURL`，见 `activeJob(for:)`），
    /// 不再依赖「行与任务同名」。
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

