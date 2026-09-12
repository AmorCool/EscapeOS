import SwiftUI

/// AppStore 商店 —— 历史版本
///
/// 两个通道（v0.3.335）：
/// 1. **账号通道**（优先）：已登录 Apple ID 时走 App Store 下载协议
///    （`VersionFinder` + `VersionLookup`，与 Asspp 同款），拿全量版本身份与发布日期。
///    任何区域都有数据，且能**直接下载指定历史版本**。
/// 2. **商品页通道**（回退）：免登录抓商品页内嵌的 `versionHistory`，
///    数据只有部分区域/应用有，且不能下载。
struct AppStoreVersionHistoryView: View {

    let item: AppStoreItem
    let country: String

    private enum Channel { case account, web }

    @State private var versions: [AppStoreVersion] = []
    /// 账号通道：全量版本身份（新 → 旧）
    @State private var identifiers: [String] = []
    @State private var loadedIDs: Set<String> = []
    @State private var channel: Channel = .web
    @State private var accountEmail: String?

    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var expanded: Set<String> = []
    /// 已知的「版本号 → 真实发布日期」。只来自商品页通道；
    /// Apple 下载协议给不出每版的日期（每版都返回应用首次上架日期）。
    @State private var dateByVersion: [String: Date] = [:]

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
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
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

        // 1) 账号通道（任何区域都有数据，且能下载历史版本）
        // bundleId 缺失时先补一次（协议按 bundleId 查）
        var bundleId = item.bundleId
        if bundleId == nil, let full = try? await AppStoreService.lookup(id: item.id) {
            bundleId = full.bundleId
        }
        var accountError: String?
        if let bundleId, !bundleId.isEmpty,
           let email = AppStoreDownloadStore.shared.selectedEmail
        {
            do {
                let ids = try await AppStoreService.storeVersionIdentifiers(bundleId: bundleId,
                                                                            email: email)
                // 协议返回旧 → 新；展示要新 → 旧
                identifiers = Array(ids.reversed())
                accountEmail = email
                channel = .account
                loading = false
                // 商品页通道能给出**真实**的版本日期（内嵌 versionHistory shelf），
                // 但覆盖不全；能拿到就补上，拿不到就不显示日期。
                Task { await harvestWebDates() }
                await loadMore()
                return
            } catch {
                // 账号通道失败 → 回退商品页通道（下方）
                accountError = error.localizedDescription
                LoginLogger.shared.log("版本历史账号通道失败：\(error.localizedDescription)",
                                       category: .appStore)
            }
        }

        // 2) 商品页通道（免登录，覆盖不全）
        do {
            versions = try await AppStoreService.versionHistory(appId: item.id, country: country)
        } catch {
            errorText = error.localizedDescription
        }
        // 商品页也没有数据时，把账号通道的失败原因说出来（否则只剩一句"没有记录"）
        if versions.isEmpty, let accountError { errorText = accountError }
        loading = false
    }

    /// 商品页通道的真实版本日期 → 按版本号补给账号通道（best-effort）
    private func harvestWebDates() async {
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

    /// 账号通道：分批取版本元数据（每次 5 条）
    private func loadMore() async {
        guard canLoadMore, !loadingMore, let email = accountEmail else { return }
        loadingMore = true
        defer { loadingMore = false }
        for id in identifiers.filter({ !loadedIDs.contains($0) }).prefix(5) {
            do {
                let meta = try await AppStoreService.storeVersionMetadata(item: item,
                                                                         versionID: id,
                                                                         email: email)
                versions.append(AppStoreVersion(version: meta.version,
                                                externalVersionID: id,
                                                dateValue: dateByVersion[meta.version]))
                loadedIDs.insert(id)
            } catch {
                errorText = error.localizedDescription
                return
            }
        }
    }
}
