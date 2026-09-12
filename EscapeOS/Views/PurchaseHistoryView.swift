//
//  PurchaseHistoryView.swift
//  EscapeOS
//
//  「已购列表」—— 某个已登录 Apple ID 在 App Store 里的购买记录（DMAP）。
//  支持按 名称 / Bundle ID / App ID 搜索；数据只读。
//

import SwiftUI
import UIKit

struct PurchaseHistoryView: View {

    let email: String

    @Environment(\.dismiss) private var dismiss

    @State private var apps: [OwnedApp] = []
    @State private var icons: [Int64: String] = [:]
    @State private var keyword = ""
    @State private var loading = false
    @State private var errorText: String?

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
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
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
    }

    private var summaryText: String {
        let total = apps.count
        if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "共 \(total) 个已购应用"
        }
        return "匹配 \(filtered.count) / \(total)"
    }

    // MARK: - 行

    private func row(_ app: OwnedApp) -> some View {
        HStack(spacing: 12) {
            icon(for: app)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name.isEmpty ? app.bundleId : app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
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

    /// 副标题：`App ID · Bundle ID`（有购买日期再补一段）
    private func subtitle(_ app: OwnedApp) -> String {
        var parts: [String] = []
        parts.append(app.idText)
        if !app.bundleId.isEmpty { parts.append(app.bundleId) }
        if let date = app.purchaseDate {
            parts.append(Self.dayFormatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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
                .fill(Color.blue.opacity(0.14))
            Text(letter.isEmpty ? "?" : letter)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
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

    /// 图标只是锦上添花：批量 lookup，失败就退回字母块
    private func loadIcons() async {
        let ids = apps.prefix(150).map { $0.idText }
        guard !ids.isEmpty else { return }
        var table: [Int64: String] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 50) {
            let slice = Array(ids[chunk ..< min(chunk + 50, ids.count)])
            guard let items = try? await AppStoreService.lookupBatch(ids: slice) else { continue }
            for item in items {
                if let icon = item.iconSmallURL ?? item.iconURL, let id = Int64(item.id) {
                    table[id] = icon
                }
            }
        }
        if !table.isEmpty { icons = table }
    }
}
