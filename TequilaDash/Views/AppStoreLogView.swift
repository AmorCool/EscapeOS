import SwiftUI
import UIKit

/// v0.3.308：**AppStore 独立日志页**。
///
/// 只显示指定分类的日志（默认 = AppStore 商店：登录 / 下载 / 安装 / 账号管理），不再与证书管理、
/// IPA 侧载、爱思源等其它板块共用同一个列表 —— 之前复用的是全局「登录日志」页，
/// 各板块输出全混在一起（用户实测指正）。
///
/// 排版改为 `LogConsoleView`（逐行 `Text` + 行间 `Divider` + 自动滚底 + 复制带元信息头，
/// 参考 YangJiiii/3105 的日志页）。此前是**一整块 `Text`**，长日志糊成一坨。
/// 注意：**2s 轮询是本页自己的优势，保留**（3105 没有实时刷新）——
/// 只换渲染方式，不换取数方式。
struct AppStoreLogView: View {

    /// 该页要显示的日志分类（默认 = AppStore 商店板块）
    var categories: [LoginLogger.Category] = [.appStore]

    /// 逐行日志（`LogConsoleView` 的输入；不再是拼好的整块字符串）
    @State private var lines: [String] = []

    var body: some View {
        LogConsoleView(
            lines: lines,
            title: "AppStore 日志",
            onClear: {
                LoginLogger.shared.clear()
                refresh()
            },
            // 不传 onDone：本页是 `AppStoreView` 里 `NavigationLink` push 出来的，
            // 系统返回按钮已经在做同一件事，再加「完成」就是两个等价按钮。
            clearConfirmTitle: "确定清空 AppStore 日志？"
        )
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

    /// 取该板块最近的日志行。
    ///
    /// - 用 `recentLines(_:categories:)` 而**不是** `logText(categories:)`：
    ///   后者返回的是拼好的整块字符串，这里要的是逐行数组（还要再按 "\n" 拆一次，
    ///   纯属白干）。
    /// - 行数上限直接取 `LogConsoleView.maxRenderedLines`：逐行 `LazyVStack` 的成本随行数
    ///   线性增长，取更多行也渲染不出来（原因写在该常量的注释里）。
    private func refresh() {
        let fresh = LoginLogger.shared.recentLines(LogConsoleView.maxRenderedLines, categories: categories)
        // 轮询每 2s 重跑一次；内容没变就不重新赋值 —— 否则每 2s 白白触发一次
        // body 重算（几百行 `Text` 的 diff）。
        guard fresh != lines else { return }
        lines = fresh
    }
}
