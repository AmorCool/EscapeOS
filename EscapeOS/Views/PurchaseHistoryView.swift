//
//  PurchaseHistoryView.swift
//  EscapeOS
//
//  「已购列表」—— 某个已登录 Apple ID 在 App Store 里的购买记录（DMAP）。
//  支持按 名称 / Bundle ID / App ID 搜索；每条可直接下载（含已下架应用 —— 只要买过）。
//

import SwiftUI
import UIKit

struct PurchaseHistoryView: View {

    let email: String

    @Environment(\.dismiss) private var dismiss

    @State private var apps: [OwnedApp] = []
    @State private var icons: [Int64: String] = [:]
    /// 已购里有、Apple lookup 查不到 ⇒ 判为已下架（判据见 `loadIcons`）。
    @State private var delistedIds: Set<Int64> = []
    @State private var keyword = ""
    @State private var loading = false
    @State private var errorText: String?
    @ObservedObject private var center = IPADownloadCenter.shared

    private var filtered: [OwnedApp] {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? apps
            : apps.filter { $0.matches(keyword) }
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("读取已购列表…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else if let errorText {
                    Section {
                        Label(errorText, systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        Button("重试") { Task { await load() } }
                            .font(.subheadline.weight(.medium))
                    }
                } else if apps.isEmpty {
                    Section {
                        Text("Apple 未返回已购记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(filtered) { app in
                            row(app)
                        }
                    } header: {
                        Text(summaryText)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $keyword, prompt: "名称 / Bundle ID / App ID")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("已购列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
            .refreshable { await load() }
        }
        .task { if apps.isEmpty { await load() } }
        .toastHost()
    }

    private var summaryText: String {
        let total = apps.count
        if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if delistedIds.isEmpty { return "共 \(total) 个已购应用" }
            return "共 \(total) 个已购应用 · \(delistedIds.count) 个已下架"
        }
        return "匹配 \(filtered.count) / \(total)"
    }

    // MARK: - 行

    private func row(_ app: OwnedApp) -> some View {
        HStack(spacing: 12) {
            icon(for: app)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name.isEmpty ? app.bundleId : app.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if delistedIds.contains(app.id) {
                        Text("已下架")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(app))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !app.version.isEmpty {
                Text(app.version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            downloadButton(app)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = app.bundleId
                ToastCenter.shared.show("已复制 Bundle ID")
            } label: {
                Label("复制 Bundle ID", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = app.idText
                ToastCenter.shared.show("已复制 App ID")
            } label: {
                Label("复制 App ID", systemImage: "number")
            }
        }
    }

    /// 已购条目 → AppleID 通道下载。已购（含已下架）都能下：许可在账号里，Apple 仍发直链。
    private func downloadButton(_ app: OwnedApp) -> some View {
        let bid = app.bundleId.isEmpty ? nil : app.bundleId
        let busy = center.activeJob(bundleId: bid, name: app.name) != nil
        return Button {
            download(app)
        } label: {
            if busy {
                ProgressView().controlSize(.mini).frame(width: 32)
            } else {
                Text("下载")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func download(_ app: OwnedApp) {
        let item = AppStoreItem(id: app.idText,
                                name: app.name.isEmpty ? app.bundleId : app.name,
                                bundleId: app.bundleId.isEmpty ? nil : app.bundleId,
                                version: app.version.isEmpty ? nil : app.version)
        IPADownloadCenter.shared.startWithAppleID(item: item, email: email)
        ToastCenter.shared.show("已开始下载")
    }

    /// 副标题：`App ID · Bundle ID`（有购买日期再补一段）
    private func subtitle(_ app: OwnedApp) -> String {
        var parts: [String] = []
        parts.append(app.idText)
        if !app.bundleId.isEmpty { parts.append(app.bundleId) }
        if let date = app.purchaseDate {
            parts.append(DateText.string(from: date, style: .day))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func icon(for app: OwnedApp) -> some View {
        let side: CGFloat = 36
        if let urlString = icons[app.id], let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                monogram(app)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            monogram(app)
        }
    }

    private func monogram(_ app: OwnedApp) -> some View {
        let letter = String((app.name.isEmpty ? app.bundleId : app.name).prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.accent.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - 加载

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorText = nil
        do {
            let list = try await PurchaseHistoryService.ownedApps(email: email)
            apps = list
            LoginLogger.shared.log("[已购] \(email) 共 \(list.count) 条", category: .appStore)
        } catch {
            errorText = error.localizedDescription
            LoginLogger.shared.log("[已购] \(email) 失败：\(error.localizedDescription)",
                                   category: .appStore)
        }
        loading = false
        await loadIcons()
    }

    /// 图标只是锦上添花：批量 lookup，失败就退回字母块。
    /// 顺带判定「已下架」：**已购里有、Apple lookup 查不到** ⇒ 该 App 已下架
    /// （对齐 ipatool 的 `ErrAppNotFound`：下架应用在公开 lookup 里天然缺席，但已购许可还在，仍能下）。
    /// 只对「确实查回来过」的批次下结论 —— 整批空多半是接口/网络不可用，不能据此误标已下架。
    private func loadIcons() async {
        let ids = apps.prefix(150).map { $0.idText }
        guard !ids.isEmpty else { delistedIds = []; return }
        var table: [Int64: String] = [:]
        var delisted = Set<Int64>()
        // 步长与 lookupBatch 内部一致（40），保证「一批 = 一次 lookup」，成败可判。
        for chunk in stride(from: 0, to: ids.count, by: 40) {
            let slice = Array(ids[chunk ..< min(chunk + 40, ids.count)])
            guard let items = try? await AppStoreService.lookupBatch(ids: slice) else { continue }
            guard !items.isEmpty else { continue }   // 整批没查到：不下「已下架」结论
            var found = Set<Int64>()
            for item in items {
                guard let id = Int64(item.id) else { continue }
                found.insert(id)
                if let icon = item.iconSmallURL ?? item.iconURL { table[id] = icon }
            }
            delisted.formUnion(Set(slice.compactMap { Int64($0) }).subtracting(found))
        }
        if !table.isEmpty { icons = table }
        delistedIds = delisted
    }
}
