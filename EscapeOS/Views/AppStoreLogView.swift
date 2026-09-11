import SwiftUI
import UIKit

/// v0.3.308：**AppStore 独立日志页**。
///
/// 只显示指定分类的日志（默认 = AppStore 商店：登录 / 下载 / 安装 / 账号管理），不再与证书管理、
/// IPA 侧载、爱思源等其它板块共用同一个列表 —— 之前复用的是全局「登录日志」页，
/// 各板块输出全混在一起（用户实测指正）。
struct AppStoreLogView: View {

    /// 该页要显示的日志分类（默认 = AppStore 商店板块；下载板块传 [.appStoreDownload]）
    var categories: [LoginLogger.Category] = [.appStoreStore]

    @State private var text = ""
    @State private var copied = false

    private static let empty = "（暂无该板块日志，先试一次登录或下载）"

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? Self.empty : text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .navigationTitle("AppStore 日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(text.isEmpty)
                Button {
                    LoginLogger.shared.clear()
                    refresh()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task {
            refresh()
            // 2s 轮询：登录/下载过程中能实时看到每一步
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                refresh()
            }
        }
    }

    private func refresh() {
        text = LoginLogger.shared.logText(categories: categories)
    }
}
