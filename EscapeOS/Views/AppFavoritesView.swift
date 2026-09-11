import SwiftUI

/// 收藏栏 —— AppStore 商店右上角「…」里的入口。
///
/// 每条记录 = **一次收藏**（`id` 为 UUID），同一个应用可以收藏多次，
/// 列表里以收藏时间区分；支持编辑态多选批量删除与滑动删除。
struct AppFavoritesView: View {

    @State private var query = ""
    @State private var all: [FavoriteApp] = []
    @State private var confirmClear = false
    @State private var selection: Set<String> = []
    @Environment(\.editMode) private var editMode

    private var isEditing: Bool { editMode?.wrappedValue == .active }
    private var filtered: [FavoriteApp] { all.filter { $0.matches(query) } }

    var body: some View {
        List(selection: Binding(get: { isEditing ? selection : [] },
                                set: { if isEditing { selection = $0 } })) {
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
                        let targets = Set(indexSet.map { filtered[$0].id })
                        AppFavoritesStore.shared.remove(ids: targets)
                        selection.subtract(targets)
                        reload()
                    }
                } header: {
                    Text(query.isEmpty ? "共 \(all.count) 条收藏" : "匹配 \(filtered.count) / \(all.count) 条")
                } footer: {
                    if isEditing {
                        Text("已选 \(selection.count) 条")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, editMode)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索名称 / AppID / BundleID")
        .navigationTitle("收藏栏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !all.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "完成" : "选择") {
                        withAnimation {
                            editMode?.wrappedValue = isEditing ? .inactive : .active
                            if isEditing { selection.removeAll() }
                        }
                    }
                }
                if isEditing {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            let targets = selection.isEmpty ? Set(filtered.map(\.id)) : selection
                            AppFavoritesStore.shared.remove(ids: targets)
                            selection.removeAll()
                            reload()
                            ToastCenter.shared.show("已删除 \(targets.count) 条收藏")
                        } label: {
                            Label(selection.isEmpty ? "删除全部" : "删除选中 \(selection.count) 条",
                                  systemImage: "trash")
                        }
                        .disabled(filtered.isEmpty)
                    }
                } else {
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
        }
        .confirmationDialog("清空收藏栏？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空 \(all.count) 条收藏", role: .destructive) {
                AppFavoritesStore.shared.removeAll()
                selection.removeAll()
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
                Text("收藏于 \(fav.addedText)")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("AppID \(fav.appId)")
                    if let b = fav.bundleId, !b.isEmpty { Text(b) }
                }
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        all = AppFavoritesStore.shared.items()
    }
}
