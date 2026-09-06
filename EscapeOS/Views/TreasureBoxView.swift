import SwiftUI

/// v0.3.197：百宝箱占位页 — 后续放杂七杂八工具。从主页通过
/// NavigationLink（按钮）或下滑手势进入。上滑返回上一级（系统默认 + 显式按钮）。
struct TreasureBoxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                topHandle    // v0.3.199：顶部把手——下滑返回主页（下拉关闭）
                heroCard
                itemsCard
                Text("v0.3.199：百宝箱占位。后续版本逐步填充：设备日志导出、随机设备 ID、设备网络信息等小工具。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("百宝箱")
        .navigationBarTitleDisplayMode(.inline)
        .simultaneousGesture(dismissGesture)
    }

    /// 顶部把手：提示下滑返回；拖动放大反馈
    private var topHandle: some View {
        VStack(spacing: 5) {
            Capsule()
                .fill(Color(.separator))
                .frame(width: 36, height: 5)
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.semibold))
                Text("下滑返回主页")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
            .scaleEffect(1 + (max(0, min(dragOffset, 60)) / 60) * 0.18)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// v0.3.199：下滑返回手势（ScrollView 顶时触发）
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                dragOffset = value.translation.height > 0 ? value.translation.height : 0
            }
            .onEnded { value in
                dragOffset = 0
                guard value.translation.height > 90,
                      abs(value.translation.width) < 80 else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dismiss()
            }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.title)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("百宝箱")
                        .font(.title2.weight(.semibold))
                    Text("小工具集 · 持续补充中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工具")
                .font(.headline)
                .padding(.bottom, 8)
            ForEach(TreasureItem.placeholder) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 12)
                Divider().opacity(item.id == TreasureItem.placeholder.last?.id ? 0 : 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

struct TreasureItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let color: Color
    static let placeholder: [TreasureItem] = [
        .init(id: "1", icon: "doc.text.magnifyingglass", title: "设备日志导出",
              detail: "一键导出系统日志/Sysmon/诊断数据", color: .blue),
        .init(id: "2", icon: "key.fill", title: "随机设备 ID",
              detail: "重置 ApplePackage/Anisette 设备标识", color: .indigo),
        .init(id: "3", icon: "wifi", title: "设备网络信息",
              detail: "查看局域网 IP / 端口占用", color: .purple),
        .init(id: "4", icon: "trash", title: "清理应用残留",
              detail: "扫描并清理卸载残留的容器/缓存", color: .gray),
    ]
}