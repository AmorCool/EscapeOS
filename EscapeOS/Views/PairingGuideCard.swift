import SwiftUI

/// v0.3.238：配对文件缺失引导卡（统一组件）——
/// 所有依赖配对文件的功能页在错误分支用它替换裸错误 Label，
/// 样式对齐应用管理页（橙卡 + 说明 + 「去导入配对文件」直达）.
struct PairingGuideCard: View {
    /// 附加说明（可选；默认给通用提示）
    var note: String? = nil
    @State private var viewModel = AppListViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("配对文件未导入", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(note ?? "重置配对文件后，到「更多 → 配对文件导入」重新导入即可恢复本功能.")
                .font(.caption)
                .foregroundStyle(.secondary)
            NavigationLink(destination: NavigationLazyView(PairingSetupView(viewModel: viewModel))) {
                HStack {
                    Label("去导入配对文件", systemImage: "key.horizontal")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// v0.3.238：配对缺失统一判定——各服务的配对错误文案均含「未检测到配对文件」
enum PairingGate {
    static func isPairingError(_ message: String) -> Bool {
        message.contains("未检测到配对文件")
    }
}
