import SwiftUI

/// v0.3.240：配对文件缺失引导卡（统一组件，严格对齐应用管理页 IMG_4642 样式）——
/// 橙色三角+标题同行 / 灰色说明 / 钥匙导航行（蓝字+右箭头）。自带白卡背景。
/// 所有依赖配对文件的功能页统一接入.
struct PairingGuideCard: View {
    /// 附加说明（可选；默认给通用提示）
    var note: String? = nil
    @State private var viewModel = AppListViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("配对文件未导入")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
            Text(note ?? "重置配对文件后，到「更多 → 配对文件导入」重新导入即可恢复本功能.")
                .font(.caption)
                .foregroundStyle(.secondary)
            NavigationLink(destination: NavigationLazyView(PairingSetupView(viewModel: viewModel))) {
                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal")
                        .foregroundStyle(.blue)
                    Text("去导入配对文件")
                        .foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.vertical, 4)
    }
}

/// v0.3.238：配对缺失统一判定——各服务的配对错误文案均含「未检测到配对文件」
enum PairingGate {
    static func isPairingError(_ message: String) -> Bool {
        message.contains("未检测到配对文件")
    }
}
