import SwiftUI

/// **共享转换独立日志页**。
///
/// 只显示共享转换这一类日志（导入 / 修补 / 安装），不再与 AppStore 商店的
/// 登录 / 下载 / 安装混在同一个列表 —— 此前 `ImportService` / `RepairService`
/// 全写 `.appStore`，商店日志页里混着共享转换的记录（用户实测指正）。
///
/// 排版复用 `LogConsoleView`（逐行 `Text` + 行间 `Divider` + 自动滚底 + 复制带元信息头）。
/// 2s 轮询保留：导入 / 修补 / 安装过程中能实时看到每一步。
struct ShareConvertLogView: View {

    /// 该页要显示的日志分类（共享转换专属）
    var categories: [LoginLogger.Category] = [.shareConvert]

    /// 逐行日志（`LogConsoleView` 的输入）
    @State private var lines: [String] = []

    var body: some View {
        LogConsoleView(
            lines: lines,
            title: "共享转换日志",
            onClear: {
                LoginLogger.shared.clear()
                refresh()
            },
            // 不传 onDone：本页是 `ImportView` 工具栏 `NavigationLink` push 出来的，
            // 系统返回按钮已经在做同一件事，再加「完成」就是两个等价按钮。
            clearConfirmTitle: "确定清空共享转换日志？"
        )
        .task {
            refresh()
            // 2s 轮询：导入 / 修补 / 安装过程中能实时看到每一步
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                refresh()
            }
        }
    }

    /// 取该分类最近的日志行。
    ///
    /// 用 `recentLines(_:categories:)` 而不是 `logText(categories:)`：前者直接给逐行数组，
    /// 后者返回拼好的整块字符串还要再拆一次。行数上限取 `LogConsoleView.maxRenderedLines`。
    private func refresh() {
        let fresh = LoginLogger.shared.recentLines(LogConsoleView.maxRenderedLines, categories: categories)
        // 轮询每 2s 重跑一次；内容没变就不重新赋值，避免白白触发 body 重算。
        guard fresh != lines else { return }
        lines = fresh
    }
}
