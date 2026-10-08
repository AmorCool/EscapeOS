import SwiftUI
import Foundation
import UIKit

/// 源内 App 列表页 —— 对应规格 `EscapeSpace_软件源管理_实现规格.md` §4.2（截图 2）。
///
/// 职责：展示**某个源**里的 App（图标 / 名称 / 版本 / 大小 / 日期 / 描述）；
/// 顶部渲染**源公告 banner**（`SignSource.message`，照全能签原版；见 `announcementSection(_:)`）；
/// 搜索框 + 筛选弹层（分类 / 价格 / 排序 / **类型排除**，**全部本地过滤**）；
/// 每行右侧控件由 `lock` 与 `downloadURL` 的 scheme 共同决定 —— `lock == true` → 「解锁」；
/// http(s) 直链 → 「获取」；自定义 scheme 深链（`nsk-sign://web|bookmark…`）→ 「跳转」（见 `RowKind`）。
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
    /// 公告同理由 `source.message` 起头（见 `announcementText`）。
    init(source: SignSource) {
        self.source = source
        _apps = State(initialValue: source.apps)
        _announcementText = State(initialValue: source.message)
    }

    // MARK: - State

    /// 源内 App。初值取 `source.apps`（见 `init`），解锁成功后重拉源时更新。
    @State private var apps: [SignSourceApp] = []
    /// 源公告原文（`SignSource.message`）。初值取 `source.message`，重拉源时随 `apps` 一起更新
    /// —— 对标全能签在网络刷新回调里重刷公告（`applyAnnouncementText:` @`0x1003631c8` 的两个调用点
    /// 之一即 `ais_startManifestNetworkRefreshFromUserPull:` 的 block）。
    @State private var announcementText: String?
    @State private var keyword = ""
    /// 分类分段索引（0 = 全部）。**与 `type` 等值匹配**，不是语义映射（规格 §6 ★）。
    @State private var typeFilter: AppTypeFilter = .all
    @State private var priceFilter: PriceFilter = .all
    /// 排序段（抄全能签新增，规格 §6 / §0.1 裁决 4）。
    @State private var sortFilter: SortFilter = .sourceOrder
    @State private var showFilter = false

    /// 类型筛选（**否定式**）：开启后**排除**不可下载的行（网页 / 书签深链 + 无下载链接）。
    ///
    /// ⚠️ 与上面三个**等值匹配**筛选（分类 / 价格 / 排序）**语义不同** —— 那三个是「选一个值去相等」，
    /// 这个是「布尔否定」。故它在弹层里**独立成组**、用 `Toggle` 而非 `Picker`，不与等值筛选混在一起。
    @State private var excludeNonDownloadable = false

    /// 深链「跳转」的内置浏览器目标（复用既有 `InAppBrowserView`，即用户说的「EscapeSpace 弹出界面」）。
    @State private var browserTarget: LinkShareTarget?

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
            // 源公告 banner —— 搜索框下方、App 列表上方（照全能签原版：公告是表格的 header，
            // 见 `announcementSection(_:)`）。`message` 为空 ⇒ 不渲染，不留空块。
            if let notice = announcement {
                announcementSection(notice)
            }
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
        // 深链「跳转」：用内置浏览器打开内层 http(s) 地址（不是跳到外部 App）。
        .sheet(item: $browserTarget) { target in
            InAppBrowserView(title: target.title, url: target.url)
        }
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

        // 类型（**否定式**，独立于上面三个**等值**筛选）：开启后排除**不可下载**的行 ——
        // 网页 / 书签深链（`nsk-sign://web|bookmark…`）与无 `downloadURL` 的条目。
        // 判据 = `rowKind(_:) != .downloadable`，与「跳转」按钮同一套分类，避免两处口径漂移。
        if excludeNonDownloadable {
            result = result.filter { rowKind($0) == .downloadable }
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

    // MARK: - 源公告 banner（照全能签原版）

    /// 源公告的「标题 + 正文」两段。
    ///
    /// 全能签把 `message` 用**第一个换行**切成两段分别渲染（`_AISSoftwareSourceSplitAnnouncementTitleBody`
    /// @`0x100363550`）：首行 = 标题、其余 = 正文。无换行 ⇒ 标题为空、整段作正文。
    private struct Announcement: Equatable {
        /// 首行（原版 17pt semibold 居中）。可为空。
        let title: String
        /// 其余行（原版 13pt regular 次级色居中）。可为空。
        let body: String
    }

    /// 源公告原文 → 标题 / 正文；空或全空白 ⇒ `nil`（不显示 banner）。
    ///
    /// 归一化：先把 `\r\n` / `\r` 统一成 `\n`（源 JSON 用 `\r\n` 断行），再按**第一个换行**切分。
    /// 出处：全能签 `_AISSoftwareSourceSplitAnnouncementTitleBody` @`0x100363550`
    /// （反编译与字符串解码见 `P4_全能签逆向/_impl/功能_软件源公告banner.md`）。
    private var announcement: Announcement? {
        guard let raw = announcementText else { return nil }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let nl = text.firstIndex(of: "\n") else {
            return Announcement(title: "", body: text)
        }
        let title = String(text[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(text[text.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Announcement(title: title, body: body)
    }

    /// 公告卡片 —— 居中多行文字，首行加重、其余次级色（对齐全能签观感，落在本仓 `List` 的分组卡片里）。
    ///
    /// 原版把它设成 `tableView.tableHeaderView`（`applyAnnouncementText:` @`0x1003631c8`），
    /// 即**列表之上、随内容滚动**；这里用 `List` 顶部的独立 `Section` 表达同一层级。
    /// **刻意不做折叠 / 限行**：原版全量显示，且它随列表滚动、不会长期占屏（判断见简报 §③）。
    private func announcementSection(_ notice: Announcement) -> some View {
        Section {
            VStack(spacing: 6) {
                if !notice.title.isEmpty {
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                if !notice.body.isEmpty {
                    Text(notice.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 筛选弹层（分类 / 价格 / 类型 / 排序，四段）

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
                // 类型：**独立分组 + 布尔开关**（否定式），刻意不用 `Picker` ——
                // 避免与上面两个等值筛选混淆（规格 §6 ★ 的等值匹配只适用于分类 / 价格）。
                Section {
                    Toggle("排除不可下载", isOn: $excludeNonDownloadable)
                } header: {
                    Text("类型")
                } footer: {
                    Text("开启后隐藏网页 / 书签等深链，以及没有下载链接的条目.")
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
                        excludeNonDownloadable = false
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

    /// 能否下载：`downloadURL` 必须是**非空且 http/https** 的安装包直链。
    ///
    /// 根因（用户截图「整页朦胧灰 + 获取点不动」）：模型 `SignSourceApp.isInstallable`
    /// （`Engine/SignSourceModels.swift`）要求 `bundleIdentifier` 与 `downloadURL` **同时非空**；
    /// 但全能签 / 牛蛙这一支 `appstore` schema 家族（实测 `qnq.nuosike.cn` 34/34、
    /// `hujiao.xyz` 1991/1991、`xiaoxin.kaluo.xyz` 28026/28026）**整源都没有 `bundleIdentifier` 键**
    /// ⇒ 恒为 nil ⇒ 每行都 `isInstallable == false` ⇒ 整页 `.opacity(0.45)` + 「获取」恒禁用。
    /// 而下载真正需要的只有 `downloadURL`（这些源都有值）。故视图层改按 `downloadURL` 判定。
    ///
    /// ⚠️ 本轮追加 **scheme 校验**：`nsk-sign://web…` / `nsk-sign://bookmark…` 这类**深链**
    /// 不是安装包直链（全能签把它们当「访问 / 书签」行处理，对照报告 §1.3）。`qnq.nuosike.cn` 实测
    /// 34 条里有 **7 条**是这种深链 —— 旧判据只看「非空」⇒ 会给它们渲染可点的「获取」，
    /// 一点就起一个**必然失败**的下载任务。故只有 http/https 才算「可下载」。
    private func canDownload(_ app: SignSourceApp) -> Bool {
        downloadURLString(app) != nil
    }

    /// 本行是否还有可用动作：需解锁 → 看解锁入口；否则 → 看能否下载。
    /// 与 `trailingControl` 里按钮的**渲染条件同一判据**，避免「有按钮可点但整行发灰」。
    ///
    /// ⚠️ 深链行（`nsk-sign://web|bookmark…`）此处仍为 `false` ⇒ 左侧内容保持灰显（用户要求
    /// 「这种状态可以保持」）；但它有「跳转」按钮，故右侧控件**不参与灰显**（见 `rowContentOpacity(_:)`）。
    private func rowEnabled(_ app: SignSourceApp) -> Bool {
        app.lock ? (app.unlockURL != nil) : canDownload(app)
    }

    // MARK: - 深链分类（网页 / 书签 / 其它）与「跳转」

    /// 行类型 —— 分类依据是 `downloadURL` 的 **scheme**（真实数据统计见
    /// `P4_全能签逆向/_impl/修复_深链跳转与筛选排除.md` ①）。
    ///
    /// ⚠️ 本枚举**只服务视图层的按钮选择与「排除」筛选**，**不改动**模型层 `isInstallable`
    /// （那个属性还被别处引用）。分档：
    /// · `.downloadable`：`http` / `https` 直链 → 现有「获取」；
    /// · `.web`：`nsk-sign://web?url=…`（全能签「访问网址」，共 10 条）→ 「跳转」；
    /// · `.bookmark`：`nsk-sign://bookmark?url=…`（全能签「添加书签」，共 1 条）→ 「跳转」；
    /// · `.otherScheme`：其它自定义 scheme 深链 → 「跳转」（交系统处理）；
    /// · `.none`：无 `downloadURL`（或脏值）→ 无按钮（灰显）。
    private enum RowKind: Equatable {
        case downloadable
        case web
        case bookmark
        case otherScheme
        case none

        /// 是否**深链**（非 http(s) 的自定义 scheme）—— 「跳转」按钮与「排除」筛选都按它判定。
        var isDeepLink: Bool {
            switch self {
            case .web, .bookmark, .otherScheme: return true
            case .downloadable, .none:          return false
            }
        }
    }

    /// 归类某一行（判据见 `RowKind` 注释）。
    private func rowKind(_ app: SignSourceApp) -> RowKind {
        if canDownload(app) { return .downloadable }
        guard let raw = deepLinkString(app) else { return .none }
        switch deepLinkAction(raw) {
        case "web":      return .web
        case "bookmark": return .bookmark
        default:         return .otherScheme
        }
    }

    /// 深链原始串 —— `downloadURL` 非空、且 scheme **不是** http(s) 时返回它。
    ///
    /// 额外要求「含 `://` 且能解析出 scheme」：源里存在**脏值**（实测 `yy.v9z.xyz` 有一条
    /// `downloadURL = "220000.1.192"`，是版本号被误填），它不是一个可打开的链接 ⇒ 归 `.none`。
    private func deepLinkString(_ app: SignSourceApp) -> String? {
        guard let raw = app.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return nil }
        guard raw.range(of: "://") != nil,
              let scheme = URLComponents(string: raw)?.scheme, !scheme.isEmpty else { return nil }
        return raw
    }

    /// 深链的「动作」段 —— `nsk-sign://<动作>?url=…` 里的 `<动作>`（`web` / `bookmark` / …）。
    /// 取不到（无动作段）→ `""`，调用方归到 `.otherScheme`。
    private func deepLinkAction(_ raw: String) -> String {
        guard let range = raw.range(of: "://") else { return "" }
        let rest = raw[range.upperBound...]
        let action = rest.prefix { $0 != "?" && $0 != "/" }
        return action.lowercased()
    }

    /// 从深链里取出**内层 http(s) 地址** —— `nsk-sign://web?url=<URL>` / `…bookmark?url=<URL>`。
    /// 取不到（无 `url=` / 内层非 http(s)）→ `nil`，调用方退回系统打开原始深链。
    private func deepLinkInnerURL(_ raw: String) -> URL? {
        guard let range = raw.range(of: "url=") else { return nil }
        let trimmed = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              let url = URL(string: trimmed) else { return nil }
        return url
    }

    /// 深链行「跳转」—— 优先把**内层 http(s) 地址**交给内置浏览器（`InAppBrowserView`，
    /// 即用户说的「跳转后 EscapeSpace 弹出界面」）；取不到内层地址时退回**系统打开原始深链**
    /// （如 `nsk-sign://bookmark…`，交给全能签之类的宿主处理）。
    private func jump(_ app: SignSourceApp) {
        guard let raw = deepLinkString(app) else { return }
        if let inner = deepLinkInnerURL(raw) {
            browserTarget = LinkShareTarget(title: displayName(app), url: inner)
            return
        }
        guard let url = URL(string: raw) else {
            ToastCenter.shared.show("这个链接无法打开")
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            // 系统 open 的完成回调**不在** MainActor 隔离下 ⇒ 显式回主线程再弹 toast。
            Task { @MainActor in
                if !ok { ToastCenter.shared.show("这个链接无法打开") }
            }
        }
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
                                   category: .signSource)
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
            // 灰显**只作用在左侧内容**（图标 + 文本）：深链行要保持「灰」的观感（用户要求
            // 「这种状态可以保持」），但右侧「跳转」按钮必须**清晰可点** ⇒ 不参与灰显。
            // 其余行：可下载 → 1；无下载链接 → 0.45（与旧观感逐像素一致，`trailingControl` 此时为空）。
            appIcon(app.iconURL)
                .opacity(rowContentOpacity(app))
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
            .opacity(rowContentOpacity(app))
            Spacer(minLength: 6)
            trailingControl(app)
        }
        .padding(.vertical, 3)
    }

    /// 左侧内容（图标 + 文本）的灰显透明度 —— 该行**没有任何可用动作**时压暗到 0.45。
    ///
    /// ⚠️ 判据**不是** `app.isInstallable`：那个属性还要求 `bundleIdentifier` 非空，
    /// 而全能签 / 牛蛙这一支 `appstore` schema 家族**整源没有 `bundleIdentifier` 键**
    /// ⇒ 会让整页每行都恒灰、「获取」恒禁用（用户截图）。详见 `rowEnabled(_:)`。
    private func rowContentOpacity(_ app: SignSourceApp) -> Double {
        rowEnabled(app) ? 1 : 0.45
    }

    /// App 图标；无地址 / 加载中 / 失败一律静态占位（见共享件 `RemoteIconView`），**不转圈**。
    ///
    /// 尺寸 / 圆角 / 占位样式按本页旧观感传入（54pt / 圆角 12 / 灰底 `app.dashed`）⇒ 逐像素不变；
    /// 本页原本就「加载中画静态占位」，故迁到共享件后**本页观感零变化**。
    private func appIcon(_ urlString: String?) -> some View {
        RemoteIconView(
            urlString: urlString,
            side: 54,
            cornerRadius: 12,
            placeholderStyle: IconPlaceholderStyle(
                icon: "app.dashed",
                tint: .secondary,
                background: Color.secondary.opacity(0.12)
            )
        )
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

    // MARK: - 认行（照全能签用「内容指纹」，一个任务只挂一行）

    /// 本行的**可下载直链** —— 仅当 `downloadURL` 非空且 scheme ∈ {http, https} 时返回它。
    ///
    /// 返回 `nil` 的两类行：① `downloadURL` 为空（真机样本第 34 条）；② 深链
    /// （`nsk-sign://…`，样本 7 条）。二者都**不是安装包直链** ⇒ 不给「获取」按钮、也不参与认行。
    /// 用 `hasPrefix` 而非 `URL(string:)`：直链路径里含中文（如 `…/IPA/全能签.ipa`），
    /// 前缀判断对这类串更稳，且与 `SignSourceListView.normalizeSourceURLString` 同一写法。
    private func downloadURLString(_ app: SignSourceApp) -> String? {
        guard let raw = app.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return raw
    }

    /// 内容指纹 —— 对标全能签 `ss|<URL>|<name>|<version>|<versionDate>|<size>`
    /// （`ais_downloadContentStampForApp:canonicalURL:` @`0x10035830c`，对照报告 §1.2）。
    ///
    /// ⚠️ 只复现了**前三项**：`Job` 上只有 `remoteURL` / `name` / `version`，
    /// **没有** `versionDate` / `size`（`IPADownloadCenter.swift` 本轮不可改）。
    /// 缺的两项只在「URL、名称、版本**全同**、仅日期或大小不同」时才会造成歧义 ——
    /// 而 URL 相同即同一个文件，两行此时本就应共享同一任务，故不影响「一个任务只挂一行」。
    /// URL 两侧都 `trim`：`download(_:)` 把 `downloadURL` **原样**写进 `Job.remoteURL`，
    /// 这里对两端做同一化，避免首尾空白导致误判。
    private func contentStamp(url: String, name: String, version: String) -> String {
        "ss|\(url.trimmingCharacters(in: .whitespacesAndNewlines))|\(name)|\(version)"
    }

    /// 本行正在进行的任务 —— **按内容指纹（直链 + 名称 + 版本）匹配**。
    ///
    /// 关键：`download(_:)` 起任务时把本行的 `downloadURL` 与 `displayName` / `version`
    /// **原样**写进 `Job`（`start(name:bundleId:version:iconURL:remoteURL:…)`），且第三方软件源
    /// 这条链路**不会改写**它们 ⇒ 指纹相等就是「这个任务由这一行发起」的精确判据。
    ///
    /// 由此得到两个保证：
    /// · **一个任务只挂一行**：指纹由本行的直链 + 名称 + 版本唯一确定；同一 `Job` 的指纹是常量
    ///   ⇒ 至多命中「指纹与它相等的那一行」；
    /// · **取消 / 暂停作用在自己那个任务上**：按钮拿到的 `job` 就是本行发起的那一个，
    ///   `cancel(job.id)` / `pause(job.id)` 只作用于它。
    ///
    /// 相比上一轮的「只比 `remoteURL`」，加入 `name` / `version` 后，
    /// **两行直链相同但名称或版本不同**时不再误挂同一个任务（全能签靠 `stamp` 区分同名不同包，同一道理）。
    ///
    /// ⚠️ 这里**刻意不复用** `center.activeJob(bundleId:name:)`：那个重载在 `bundleId == nil`
    /// 时退化成 `job.name == name`，正是「3 条同名全能签同时显示下载中」的根因。
    private func activeJob(for app: SignSourceApp) -> IPADownloadCenter.Job? {
        guard let url = downloadURLString(app) else { return nil }
        let want = contentStamp(url: url, name: displayName(app), version: app.version ?? "")
        return center.jobs.first { job in
            guard job.phase.isBusy, let remote = job.remoteURL else { return false }
            return contentStamp(url: remote, name: job.name, version: job.version ?? "") == want
        }
    }

    // MARK: - 右侧控件（文案由 `lock` 与 `downloadURL` 的 scheme 决定）

    /// 有任务 → 进度 + 暂停 / 删除；否则按 `lock` 给「解锁」/「获取」/「跳转」。
    ///
    /// · `lock == true` → 「解锁」（规格 §4.2 / D6）；
    /// · `lock == false` 且可下载 → 「获取」（全能签文案，规格 §0.1 裁决 4）；
    /// · `lock == false` 且是深链（`nsk-sign://web|bookmark…`）→ 「跳转」（本轮新增，见 `jump(_:)`）；
    /// · 空直链（`.none`）→ **不渲染任何按钮**（见 `rowKind(_:)`）；
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
        } else if canDownload(app) {
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
        } else if rowKind(app).isDeepLink {
            // 深链行（`nsk-sign://web|bookmark?url=…` 等）→ 「跳转」。
            // 文案统一用「跳转」（用户原话）—— 不再区分「访问 / 书签」：后者会暗示我们实现了
            // 书签功能（实际没有，只是把内层地址交给内置浏览器打开）。
            Button {
                jump(app)
            } label: {
                Text("跳转")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.teal.opacity(0.16), in: Capsule())
                    .foregroundStyle(.teal)
            }
            .buttonStyle(.plain)
        }
        // 空直链行（`.none`）：**不给按钮**（没有任何可跳转目标，见 `rowKind(_:)`）。
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
        announcementText = fresh.message
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

