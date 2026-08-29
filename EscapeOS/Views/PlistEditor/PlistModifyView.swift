import SwiftUI

/// 单个 plist 条目的查看 / 编辑页（移植自 Erosion 的 `ModifyItemPage`）。
///
/// 交互与 Erosion 一致：默认只读，点「编辑」进入编辑态，可改键名、改类型、改值、
/// 增删子条目；「保存」把改动写回整棵树再落盘，「取消」还原成本页打开时的快照。
struct PlistModifyView: View {
    @EnvironmentObject private var vm: PlistEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Binding var item: PlistItem

    @State private var isEditing = false
    @State private var original: PlistItem?

    var body: some View {
        List {
            Section {
                if isEditing {
                    TextField("键名", text: $item.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Text(item.key)
                        .textSelection(.enabled)
                }
                Picker("类型", selection: $item.type) {
                    ForEach(PlistItemType.allCases.filter { $0 != .unknown }) { type in
                        Text("\(type.displayName)（\(type.label)）").tag(type)
                    }
                }
                .disabled(!isEditing)
            } header: {
                Text("标识")
            }

            Section {
                valueSection
            } header: {
                Text(item.type.isContainer ? "值（\(item.dictVal.count) 项）" : "值")
            } footer: {
                if isEditing {
                    Text("切换类型后请确认值仍然合法，写入时才不会丢失数据。")
                }
            }

            if isEditing {
                Section {
                    Button("删除此条目", role: .destructive, action: remove)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle(item.key)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditing {
                    Button("保存", action: commit)
                } else {
                    Button("编辑") {
                        original = item
                        isEditing = true
                    }
                }
            }
            if isEditing {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        if let original { item = original }
                        isEditing = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var valueSection: some View {
        switch item.type {
        case .dict, .array:
            if isEditing {
                Button {
                    item.dictVal.insert(PlistItem(key: "新条目", value: ""), at: 0)
                } label: {
                    Label("新增条目", systemImage: "plus")
                }
            }
            ForEach($item.dictVal) { $child in
                PlistItemRow(item: $child, hierarchy: 0)
            }
            .onDelete { offsets in
                item.dictVal.remove(atOffsets: offsets)
            }
        case .data:
            Text(item.stringVal)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        case .bool:
            Toggle(item.boolVal ? "true" : "false", isOn: $item.boolVal)
                .disabled(!isEditing)
        case .date:
            Text(item.stringVal)
                .foregroundStyle(.secondary)
        default:
            TextField(item.type.displayName, text: $item.stringVal)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!isEditing)
        }
    }

    // MARK: - 动作

    /// 显式替换一次树中同 id 的节点，再整体写盘。
    /// `ForEach($item.dictVal)` 的动态 Binding 通常已写回数组，这里多一步是保险：
    /// 树结构一旦和当前 item 不同步，保存就会丢改动。
    private func commit() {
        vm.replace(item)
        vm.save()
        isEditing = false
    }

    private func remove() {
        vm.delete(item)
        vm.save()
        dismiss()
    }
}
