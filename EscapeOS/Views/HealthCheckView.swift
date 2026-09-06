import SwiftUI

/// v0.3.197：体检页占位 — 当前只显示分数与基础提示，后续接入
/// SecurityPresets.plist 19 类检查项 + Reveil 方法论后实现各项明细。
struct HealthCheckView: View {
    @State private var score: Int = 92
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                scoreCard
                checkItemsCard
                Text("v0.3.197：基础分占位；详细检测项（基于爱思 SecurityPresets.plist 19 类 + Reveil 方法论）将在后续版本接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("设备体检")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scoreCard: some View {
        VStack(spacing: 8) {
            Text("\(score)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .foregroundStyle(score >= 80 ? Color.blue : Color.orange)
            Text(score >= 80 ? "手机很安全" : "存在风险项")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var checkItemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("检查项")
                .font(.headline)
                .padding(.bottom, 8)
            ForEach(HealthCheckItem.placeholder) { item in
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
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 10)
                Divider().opacity(item == HealthCheckItem.placeholder.last ? 0 : 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

struct HealthCheckItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let color: Color
    static let placeholder: [HealthCheckItem] = [
        .init(id: "1", icon: "doc.text.fill", title: "可疑文件检测",
              detail: "扫描设备可疑可执行/库/符号链接（接入 SecurityPresets）", color: .blue),
        .init(id: "2", icon: "lock.shield.fill", title: "描述文件验证",
              detail: "校验 misagent 描述文件哈希", color: .purple),
        .init(id: "3", icon: "network", title: "可疑端口/URL Scheme",
              detail: "扫描可疑端口与 URL Scheme 注册", color: .indigo),
        .init(id: "4", icon: "gearshape.fill", title: "环境变量检查",
              detail: "检测已知违规的环境变量", color: .gray),
    ]
}