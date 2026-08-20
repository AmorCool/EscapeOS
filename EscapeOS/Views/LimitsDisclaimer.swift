import SwiftUI

/// Honest product limits. Shown on first launch and in Settings.
enum ProductLimits {
    static let title = "沙盒访问（存在限制）"

    static let body = """
EscapeOS 通过 LocalDevVPN 和配对文件列出已安装的应用（支持 iOS 18 与 iOS 26），然后打开其他应用的数据容器：Documents、Library 和 tmp。House Arrest 只是让电脑能把那份配对文件放进 EscapeOS 的 Documents，并不能替代配对，也不能从 EscapeOS 内部列出或打开其他应用。

你可以浏览、预览、编辑、备份、恢复这些容器中的内容，或回收缓存/临时文件空间。回收操作绝不会删除 Documents、Preferences、Application Support、Keychain、App Group 或系统目录。应用详情页的「重置应用数据」会清空 Documents、Library 和 tmp。

在恢复、回收或编辑实时数据库之前，请先关闭目标应用。恢复操作会覆盖容器中的文件。
"""
}

struct LimitsDisclaimerView: View {
    var onAcknowledge: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text(ProductLimits.title)
                    .font(.title2).bold()
                Text(ProductLimits.body)
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
                Button("我已了解", action: onAcknowledge)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("使用前必读")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}