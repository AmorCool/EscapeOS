import SwiftUI

/// 收藏与最近使用的地点（移植自 locus-ZH，汉化）。
struct PlacesView: View {
    @ObservedObject private var session = SpoofSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("收藏") {
                    if session.favorites.isEmpty {
                        Text("在地图上给图钉点亮星标即可收藏。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.favorites) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("删除", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                    renameText = place.name
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                Section("最近使用") {
                    if session.recents.isEmpty {
                        Text("传送过的位置会出现在这里。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.recents) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("删除", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
            .navigationTitle("地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("重命名收藏", isPresented: Binding(
                get: { placeToRename != nil },
                set: { if !$0 { placeToRename = nil } }
            )) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) {
                    placeToRename = nil
                }
                Button("保存") {
                    if let place = placeToRename {
                        session.renameFavorite(place, to: renameText)
                    }
                    placeToRename = nil
                }
            } message: {
                Text("起一个以后能认出来的名字。")
            }
        }
    }

    private func placeButton(_ place: SavedPlace) -> some View {
        Button {
            session.teleport(to: place.coordinate)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
