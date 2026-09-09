import SwiftUI

/// v0.3.241：配对文件缺失引导卡（统一组件）——
/// InfoActionCard 视觉基因（图标块 + 标题 + 描述）+ 「去导入配对文件」导航行.
/// 独立区块呈现，List 场景需 clear row 背景；非 List 场景传 showChevron: true.
/// 所有依赖配对文件的功能页统一接入.
struct PairingGuideCard: View {
    var note: String? = nil
    /// 非 List 容器（VStack）需要手动 chevron；List 场景 row 自带
    var showChevron: Bool = false
    @State private var viewModel = AppListViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AppRowIcon(systemName: "exclamationmark.triangle.fill",
                           tint: .orange, symbolSize: 18, frameSize: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("配对文件未导入")
                        .font(.subheadline.weight(.semibold))
                    Text(note ?? "重置配对文件后，到「更多 → 配对文件导入」重新导入即可恢复本功能.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NavigationLink(destination: NavigationLazyView(PairingSetupView(viewModel: viewModel))) {
                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .foregroundStyle(.blue)
                    Text("去导入配对文件")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    Spacer()
                    if showChevron {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        // v0.3.251: 本组件即独立卡片 —— 自带背景与 16pt continuous 圆角,
        // 不再加 .padding(.vertical, 4) (那会让卡片在 List/ScrollView 里出现
        // 不对称空隙, 圆角看着不协调).
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// v0.3.238：配对缺失统一判定——各服务的配对错误文案均含「未检测到配对文件」
enum PairingGate {
    static func isPairingError(_ message: String) -> Bool {
        message.contains("未检测到配对文件")
    }
}
