import SwiftUI

/// v0.3.300：AppStore 商店 —— 历史版本列表
///
/// 数据来自 Apple 商品页内嵌的 `versionHistory`（桌面 UA 抓取，无需登录）。
/// 每条显示版本号、发布日期、更新说明；首条即当前版本。
struct AppStoreVersionHistoryView: View {

    let item: AppStoreItem
    let country: String

    @State private var versions: [AppStoreVersion] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            if loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在读取版本历史…").font(.subheadline).foregroundStyle(.secondary)
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
                    Text("该应用没有可读取的版本历史。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(Array(versions.enumerated()), id: \.element.id) { idx, v in
                        versionRow(v, isCurrent: idx == 0)
                    }
                } header: {
                    Text("共 \(versions.count) 个版本")
                } footer: {
                    Text("版本信息来自 App Store 商品页。安装历史版本需要分发源提供对应版本的 IPA，"
                         + "且该 IPA 必须已重签名或已解密（App Store 原始包为 FairPlay 加密，无法安装）。")
                        .font(.caption2)
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

    // MARK: - 行

    @ViewBuilder
    private func versionRow(_ v: AppStoreVersion, isCurrent: Bool) -> some View {
        let isExpanded = expanded.contains(v.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(v.version)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if isCurrent {
                    Text("当前版本")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
                Text(v.dateText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let rel = v.relativeText {
                Text(rel).font(.caption2).foregroundStyle(.tertiary)
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
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded { expanded.remove(v.id) } else { expanded.insert(v.id) }
        }
    }

    // MARK: - 加载

    private func load() async {
        loading = true
        errorText = nil
        do {
            versions = try await AppStoreService.versionHistory(appId: item.id, country: country)
            if versions.isEmpty { errorText = nil }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}
