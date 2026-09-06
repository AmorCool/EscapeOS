import SwiftUI

/// v0.3.207：百宝箱面板 —— 主页原生 sheet 呈现（presentationDetents 0.4↔1.0），
/// 系统上拉展开/下拉关闭，跟手流畅。内含杂七杂八工具的入口集合。
struct TreasureBoxView: View {
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题区（sheet 拖动指示条由 presentationDragIndicator 提供）
            // v0.3.208：拖动指示条与"百宝箱"文字挨太近 → 加 padding 撑开
            Text("百宝箱")
                .font(.headline)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    heroCard
                    itemsCard
                    Text("更多工具持续补充中")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemBackground))
    }

    private var heroCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("百宝箱")
                    .font(.title3.weight(.semibold))
                Text("小工具集 · 持续补充")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工具")
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(TreasureItem.placeholder) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("即将上线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                Divider().opacity(item.id == TreasureItem.placeholder.last?.id ? 0 : 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// 百宝箱工具占位项（后续逐项实现并接真实页面）
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
