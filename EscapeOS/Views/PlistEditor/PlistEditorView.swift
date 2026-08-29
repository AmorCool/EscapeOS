import SwiftUI

/// plist 的结构化查看 / 编辑器。
///
/// 移植自 Erosion 的 `PlistViewer` + `ItemRow` + `ModifyItemPage`，去掉了对
/// PartyUI 的依赖，文案改为中文，读写改走 EscapeOS 的沙盒通道（见
/// `PlistEditorViewModel`）。
///
/// 本页面由 `FileViewerView` 在打开 .plist 文件时呈现，是 push 页——
/// 不要嵌套 NavigationStack，导航栏由外层提供。
struct PlistEditorView: View {
    @StateObject private var vm: PlistEditorViewModel

    init(rootPath: String, item: FileItem, initialData: Data) {
        _vm = StateObject(wrappedValue: PlistEditorViewModel(
            rootPath: rootPath,
            item: item,
            initialData: initialData
        ))
    }

    var body: some View {
        content
            .navigationTitle(vm.item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.save()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(vm.isSaving)
                }
            }
            .alert("出错了", isPresented: errorBinding) {
                Button("好", role: .cancel) { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .alert("已保存", isPresented: successBinding) {
                Button("好", role: .cancel) { vm.successMessage = nil }
            } message: {
                Text(vm.successMessage ?? "")
            }
            .overlay {
                if vm.isSaving {
                    ZStack {
                        Color(.systemBackground).opacity(0.6)
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在写入…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .ignoresSafeArea()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            ProgressView("正在解析…")
        } else if vm.errorMessage != nil {
            InfoActionCard(
                icon: "exclamationmark.triangle.fill",
                iconTint: .orange,
                title: "无法解析这个 plist",
                message: vm.errorMessage ?? ""
            )
            .padding()
        } else {
            List {
                ForEach($vm.items) { $item in
                    PlistItemRow(item: $item, hierarchy: 0)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 0)
            .environmentObject(vm)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )
    }

    private var successBinding: Binding<Bool> {
        Binding(
            get: { vm.successMessage != nil },
            set: { if !$0 { vm.successMessage = nil } }
        )
    }
}

// MARK: - 递归行

struct PlistItemRow: View {
    @EnvironmentObject private var vm: PlistEditorViewModel
    @Binding var item: PlistItem
    let hierarchy: Int

    var body: some View {
        Group {
            if item.type.isContainer || item.type == .data {
                containerRow
                if item.isExpanded {
                    if item.type == .data {
                        Text(item.stringVal)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(12)
                            .listRowBackground(PlistHierarchyColor.background(level: hierarchy + 1))
                    } else {
                        ForEach($item.dictVal) { $child in
                            PlistItemRow(item: $child, hierarchy: hierarchy + 1)
                        }
                    }
                }
            } else {
                NavigationLink {
                    PlistModifyView(item: $item)
                } label: {
                    HStack(spacing: 8) {
                        Text(item.key)
                            .lineLimit(1)
                        Spacer()
                        Text(summary)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(PlistHierarchyColor.background(level: hierarchy))
            }
        }
        .contextMenu {
            Menu {
                Button("复制键名") {
                    UIPasteboard.general.string = item.key
                }
                Button("复制值") {
                    UIPasteboard.general.string = summary
                }
            } label: {
                Label("复制…", systemImage: "doc.on.doc")
            }
        }
    }

    /// 字典 / 数组 / 数据的行：点击折叠展开，右侧 info 按钮进详情页。
    private var containerRow: some View {
        HStack(spacing: 8) {
            Button {
                item.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .imageScale(.small)
                        .rotationEffect(.degrees(item.isExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: 0.2), value: item.isExpanded)
                    Text(item.key)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text(item.type == .data ? item.type.displayName : "\(item.type.displayName)（\(item.dictVal.count)）")
                .font(.caption)
                .foregroundStyle(.secondary)

            NavigationLink {
                PlistModifyView(item: $item)
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(PlistHierarchyColor.background(level: hierarchy))
    }

    private var summary: String {
        switch item.type {
        case .bool:
            return item.boolVal ? "true" : "false"
        case .data:
            return "\(item.stringVal.count) 字节"
        default:
            return item.stringVal
        }
    }
}

// MARK: - 层级背景色

/// 层级越深背景越沉，方便看清 plist 的嵌套结构。
/// 移植自 Erosion 的 `UIColor.hierarchyLevelColor`（纯 UIKit 实现，不依赖 PartyUI）。
enum PlistHierarchyColor {
    static func background(level: Int) -> Color {
        Color(UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let base = isDark ? UIColor.secondarySystemBackground : UIColor.systemBackground
            let clamped = max(0, level)
            let factor = isDark
                ? min(1.6, 1 + 0.12 * CGFloat(clamped))
                : max(0.82, 1 - 0.035 * CGFloat(clamped))
            return adjustBrightness(of: base.resolvedColor(with: trait), factor: factor)
        })
    }

    private static func adjustBrightness(of color: UIColor, factor: CGFloat) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            return UIColor(hue: h, saturation: s, brightness: max(0, min(1, b * factor)), alpha: a)
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var bl: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &bl, alpha: &a) else { return color }
        return UIColor(red: r * factor, green: g * factor, blue: bl * factor, alpha: a)
    }
}
