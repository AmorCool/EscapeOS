import SwiftUI

/// 收藏栏 —— AppStore 商店右上角「…」里的入口。
///
/// 条目记录 AppID / BundleID / 应用名 / App Store 链接，支持按三者搜索。
struct AppFavoritesView: View {

    @State private var query = ""
    @State private var all: [FavoriteApp] = []
    @State private var confirmClear = false

    private var filtered: [FavoriteApp] { all.filter { $0.matches(query) } }

    var body: some View {
        List {
            if all.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("还没有收藏", systemImage: "star")
                            .font(.subheadline.weight(.medium))
                        Text("在应用详情页点右上角星号即可加入收藏栏")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(filtered) { fav in
                        NavigationLink {
                            AppStoreDetailView(item: AppStoreItem(id: fav.appId, name: fav.name,
                                                                 bundleId: fav.bundleId,
                                                                 iconURL: fav.iconURL))
                        } label: {
                            row(fav)
                        }
                    }
                    .onDelete { indexSet in
                        let targets = Set(indexSet.map { filtered[$0].appId })
                        AppFavoritesStore.shared.remove(appIds: targets)
                        reload()
                    }
                } header: {
                    Text(query.isEmpty ? "共 \(all.count) 个" : "匹配 \(filtered.count) / \(all.count) 个")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索名称 / AppID / BundleID")
        .navigationTitle("收藏栏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !all.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label("清空收藏栏", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("清空收藏栏？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空 \(all.count) 个收藏", role: .destructive) {
                AppFavoritesStore.shared.remove(appIds: Set(all.map(\.appId)))
                reload()
            }
            Button("取消", role: .cancel) {}
        }
        .toastHost()
        .onAppear { reload() }
    }

    private func row(_ fav: FavoriteApp) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: fav.iconURL ?? "")) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: Image(systemName: "app.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(fav.name).font(.subheadline).lineLimit(1)
                Text("AppID \(fav.appId)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let b = fav.bundleId, !b.isEmpty {
                    Text(b).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        all = AppFavoritesStore.shared.items()
    }
}
