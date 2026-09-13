import SwiftUI

/// AppStore 商店 —— 历史版本
///
/// 两个来源（界面分别叫「三方 API」/「苹果 API」，v0.3.364 改名前是「版本目录」/「Apple 账号」）：
/// 1. **苹果 API**（优先）：已登录 Apple ID 时走 App Store 下载协议
///    （`VersionFinder` + `VersionLookup`，与 Asspp 同款），拿全量版本身份与发布日期。
///    任何区域都有数据，且能**直接下载指定历史版本**。
/// 2. **三方 API**（回退）：免登录打第三方版本目录接口，一次拿全且带发布日期；
///    另外商品页内嵌的 `versionHistory` 也会被用来补真实日期。
struct AppStoreVersionHistoryView: View {

    let item: AppStoreItem
    let country: String

    private enum Channel { case account, web, catalog }

    /// 查询方式：两条来源各有所长，让用户自己选（失败会自动回退另一条）。
    enum Source: String, CaseIterable, Identifiable {
        case catalog
        case account

        var id: String { rawValue }

        var title: String {
            switch self {
            case .catalog: return "三方 API"
            case .account: return "苹果 API"
            }
        }
    }

    @AppStorage("VersionHistory.Source") private var sourceRaw = Source.catalog.rawValue

    private var source: Source { Source(rawValue: sourceRaw) ?? .catalog }

    @State private var versions: [AppStoreVersion] = []
    /// 账号通道：全量版本身份（新 → 旧）
    @State private var identifiers: [String] = []
    @State private var loadedIDs: Set<String> = []
    @State private var channel: Channel = .web
    @State private var accountEmail: String?

    @State private var loading = true
    @State private var loadingMore = false
    /// 账号通道回报后，还会在后台补一次「商品页真实日期」——这段也算读取中
    @State private var harvesting = false
    /// v0.3.365：**整次加载唯一的一次重登额度**（对齐 `downloadInformation` 的 `refreshed`）。
    /// 原来每个版本身份取元数据失败都会各自 rotate，一次「加载更多」最坏 20 次重登；
    /// 现在额度在 `loadAccount` 里**优先发给身份通道**（它一次拿全量版本身份），
    /// 后面的 metadata 批次一律不重登 —— 整次加载 rotate 上界 = 1。
    @State private var didUseRotateQuota = false
    @State private var errorText: String?
    @State private var expanded: Set<String> = []
    /// 已知的「版本号 → 真实发布日期」。只来自商品页通道；
    /// Apple 下载协议给不出每版的日期（每版都返回应用首次上架日期）。
    @State private var dateByVersion: [String: Date] = [:]

    /// 读取中（含分页、后台补日期）：这段时间**不允许切换来源**，
    /// 否则会把正在跑的请求打断成半截结果。
    private var isBusy: Bool { loading || loadingMore || harvesting }

    private var canLoadMore: Bool { channel == .account && loadedIDs.count < identifiers.count }

    private static let dayText: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func relativeText(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        List {
            if loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("读取中…").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            } else if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            } else if versions.isEmpty {
                Section {
                    Text("没有可读取的版本记录。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(Array(versions.enumerated()), id: \.element.id) { idx, v in
                        versionRow(v, isCurrent: idx == 0)
                    }
                    if canLoadMore {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack {
                                Spacer()
                                if loadingMore {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("加载更多")
                                }
                                Spacer()
                            }
                        }
                        .disabled(loadingMore)
                    }
                } header: {
                    Text(summaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("历史版本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("查询方式", selection: $sourceRaw) {
                        ForEach(Source.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                } label: {
                    Label(source.title, systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                // v0.3.364：读取中禁止切换来源（loading / 分页 / 后台补日期都算）
                .disabled(isBusy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isBusy)
            }
        }
        .onChange(of: sourceRaw) { _, _ in Task { await load() } }
        .task { await load() }
    }

    private var summaryText: String {
        if channel == .account, loadedIDs.count < identifiers.count {
            return "已读 \(loadedIDs.count) / 共 \(identifiers.count) 个版本"
        }
        return "共 \(versions.count) 个版本"
    }

    // MARK: - 行

    @ViewBuilder
    private func versionRow(_ v: AppStoreVersion, isCurrent: Bool) -> some View {
        let isExpanded = expanded.contains(v.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(v.version)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if isCurrent {
                    Text("当前")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
                // 只在**确实知道**该版本发布日期时才显示。
                // Apple 的下载协议对每个版本都回同一个 `releaseDate`（= 应用首次上架日期，
                // 实测 Gmail 无论请求哪个 externalVersionId 都是 2011-11-02），
                // 拿它当版本日期会整列显示同一个错误日期 —— 所以宁可留空。
                if let date = v.date {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.dayText.string(from: date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(Self.relativeText(date))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if let raw = v.dateRaw, !raw.isEmpty {
                    // 商品页通道给的原文（本来就是日期，只是格式因区域而异）
                    Text(raw)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let notes = v.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                if notes.count > 60 {
                    Button {
                        if isExpanded { expanded.remove(v.id) } else { expanded.insert(v.id) }
                    } label: {
                        Text(isExpanded ? "收起" : "展开")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            if v.externalVersionID != nil, !isCurrent {
                Button {
                    download(v)
                } label: {
                    Text("下载此版本").font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expanded.remove(v.id) } else { expanded.insert(v.id) }
        }
    }

    private func download(_ v: AppStoreVersion) {
        guard let email = accountEmail, let vid = v.externalVersionID else { return }
        IPADownloadCenter.shared.startWithAppleID(item: item, email: email,
                                                  externalVersionID: vid,
                                                  displayVersion: v.version)
        ToastCenter.shared.show("已开始下载 \(v.version)")
    }

    // MARK: - 加载

    private func load() async {
        loading = true
        errorText = nil
        versions = []
        identifiers = []
        loadedIDs = []
        channel = .web
        accountEmail = nil
        didUseRotateQuota = false

        // 按用户选的查询方式先来一条，失败/为空则自动回退另一条，
        // 最后兜底商品页通道（免登录，覆盖不全）。
        if source == .catalog {
            if await loadCatalog() { loading = false; return }
            if await loadAccount() { loading = false; return }
        } else {
            if await loadAccount() { loading = false; return }
            if await loadCatalog() { loading = false; return }
        }
        await loadWeb()
        loading = false
    }

    /// 三方 API 通道（免登录，一次拿全 + 带发布日期 + 带 externalVersionID）。
    /// Apple 的苹果 API 通道不带版本号时对不少应用回静默空包，这条通道不受影响；
    /// 与 IPARanger 2.6.0 用的是同一个接口。
    @discardableResult
    private func loadCatalog() async -> Bool {
        do {
            let list = try await AppStoreService.versionHistoryFromCatalog(appId: item.id)
            versions = list
            channel = .catalog
            // 通道成功就必须清掉上一条通道留下的警告 —— 否则回退拿到了数据，
            // 界面仍被那句橙色警告盖住（列表永远显示不出来）。
            errorText = nil
            LoginLogger.shared.log("版本历史：三方 API 通道 \(list.count) 条", category: .appStore)
            return true
        } catch {
            LoginLogger.shared.log("版本历史：三方 API 通道失败（\(error.localizedDescription)）",
                                   category: .appStore)
            return false
        }
    }

    /// 账号通道（走 App Store 下载协议）
    @discardableResult
    private func loadAccount() async -> Bool {
        // bundleId 缺失时先补一次（协议按 bundleId 查）
        var bundleId = item.bundleId
        if bundleId == nil, let full = try? await AppStoreService.lookup(id: item.id) {
            bundleId = full.bundleId
        }
        guard let bundleId, !bundleId.isEmpty,
              let email = AppStoreDownloadStore.shared.selectedEmail
        else { return false }
        // v0.3.365：整次加载唯一的重登额度**先给身份通道** —— 无论它是否真的用到，
        // 后面的 metadata 批次都不再重登，保证整次加载 rotate 上界 = 1
        // （每帧 metadata 各 rotate 一次的老写法最坏 20 次完整 SAP 登录）。
        let allowRotate = !didUseRotateQuota
        didUseRotateQuota = true
        do {
            let ids = try await AppStoreService.storeVersionIdentifiers(bundleId: bundleId,
                                                                        appId: item.id,
                                                                        email: email,
                                                                        allowRotate: allowRotate)
            // 协议返回旧 → 新；展示要新 → 旧
            identifiers = Array(ids.reversed())
            accountEmail = email
            channel = .account
            errorText = nil
            // 商品页通道能给出**真实**的版本日期（内嵌 versionHistory shelf），
            // 但覆盖不全；能拿到就补上，拿不到就不显示日期。
            Task { await harvestWebDates() }
            await loadMore()
            return true
        } catch {
            LoginLogger.shared.log("版本历史账号通道失败：\(error.localizedDescription)",
                                   category: .appStore)
            errorText = error.localizedDescription
            return false
        }
    }

    /// 商品页通道（免登录，覆盖不全）
    private func loadWeb() async {
        do {
            let list = try await AppStoreService.versionHistory(appId: item.id, country: country)
            if !list.isEmpty {
                versions = list
                channel = .web
                errorText = nil
            }
        } catch {
            if versions.isEmpty { errorText = error.localizedDescription }
        }
    }

    /// 商品页通道的真实版本日期 → 按版本号补给账号通道（best-effort）
    private func harvestWebDates() async {
        harvesting = true
        defer { harvesting = false }
        guard let list = try? await AppStoreService.versionHistory(appId: item.id, country: country),
              !list.isEmpty
        else { return }
        var map: [String: Date] = [:]
        for w in list {
            if let d = w.date { map[w.version] = d }
        }
        guard !map.isEmpty else { return }
        await MainActor.run {
            dateByVersion = map
            for i in versions.indices {
                if let d = map[versions[i].version] { versions[i].dateValue = d }
            }
        }
    }

    /// v0.3.365：单次「加载更多」的两个上界。
    ///
    /// · `versionsPerFetch = 5`：一批补 5 条，与改前一致（用户可预期的节奏）。
    /// · `versionsPerBatch = 10`：最多往后扫 10 个版本身份。选 10 的理由 ——
    ///   真机实测 Apple 只拒**最新 1~2 个**版本（v0.3.361 结论），留 5 倍余量足够
    ///   跨过被拒的前缀；同时把单次点击的最坏请求数从 20 次 volumeStore 砍半到 10 次。
    private static let versionsPerFetch = 5
    private static let versionsPerBatch = 10

    /// 账号通道：分批取版本元数据。
    ///
    /// v0.3.364：Apple 只对**该账号真正可下的那些版本**回元数据，最新的一两个会被拒。
    /// 所以不能「第一条失败就把整列报错」—— 那会让账号通道永远显示不出任何东西。
    /// v0.3.365：整批一条都没取到、或重登后仍失效 → **失败即停**（剩下身份标成已读），
    /// 否则用户每点一次就再打 10 发，纯放大（审计结论）。
    private func loadMore() async {
        guard canLoadMore, !loadingMore, let email = accountEmail else { return }
        loadingMore = true
        defer { loadingMore = false }
        let pending = identifiers.filter { !loadedIDs.contains($0) }
        var fetched = 0
        var authBroken = false
        for id in pending.prefix(Self.versionsPerBatch) {
            if fetched >= Self.versionsPerFetch { break }
            if authBroken { break }
            do {
                let meta = try await AppStoreService.storeVersionMetadata(item: item,
                                                                         versionID: id,
                                                                         email: email,
                                                                         allowRotate: !didUseRotateQuota)
                versions.append(AppStoreVersion(version: meta.version,
                                                externalVersionID: id,
                                                dateValue: dateByVersion[meta.version]))
                loadedIDs.insert(id)
                fetched += 1
            } catch ApplePackageError.passwordTokenExpired {
                // 整次加载的重登额度已被身份通道花掉（或刚花掉仍失效）→ 关闸并停下，
                // 剩下几十条不再各自重登。文案只描述接口行为，不牵扯账号/用户。
                didUseRotateQuota = true
                loadedIDs.insert(id)
                authBroken = true
                LoginLogger.shared.log("版本历史：重登后仍失效，停止翻页", category: .appStore)
            } catch {
                loadedIDs.insert(id)
                LoginLogger.shared.log("版本历史：版本 \(id) 取不到元数据，跳过（\(error.localizedDescription)）",
                                       category: .appStore)
            }
        }
        guard authBroken || fetched == 0 else { return }
        for id in identifiers where !loadedIDs.contains(id) { loadedIDs.insert(id) }
        LoginLogger.shared.log("版本历史：停止翻页（本批 \(fetched) 条\(authBroken ? "，重登后仍失效" : "")）",
                               category: .appStore)
        if versions.isEmpty {
            // 同一原因同一说法：直接取源头文案（ApplePackageError），视图不再抄一份，
            // 否则源头改了文案这里会静默变成另一种说法。
            errorText = authBroken ? ApplePackageError.passwordTokenExpired.localizedDescription
                                   : "Apple 没有返回这批版本"
        }
    }
}
