import SwiftUI

/// 蓝牙位置模拟的**独立日志页**。
///
/// ## 与其它日志页的关系
///
/// 完全独立：数据源是 `BluetoothLogStore`（`Documents/BLELogs/ble.log`），
/// **不碰 `LoginLogger`**，也不混任何其它板块的行。
/// 参考 AppStore 商店的日志板块做法（`AppStoreLogView`）：逐行渲染 + 2s 轮询 + 清除确认。
///
/// 注意：**2s 轮询保留** —— 蓝牙链路的状态变化（扫到对端 / 连上 / 掉线重连）
/// 都是秒级发生的，不实时刷新就看不到现场。
struct BluetoothLogView: View {
    @State private var lines: [String] = []

    var body: some View {
        LogConsoleView(
            lines: lines,
            title: "蓝牙位置模拟日志",
            onClear: {
                BluetoothLogStore.shared.clear()
                BLECoordinator.shared.clearLog()
                refresh()
            },
            clearConfirmTitle: "确定清空蓝牙位置模拟日志？"
        )
        .task {
            refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                refresh()
            }
        }
    }

    private func refresh() {
        // 独立存储里的行**自带** `[HH:mm:ss]` 前缀，这里不再补。
        let fresh = BluetoothLogStore.shared.recentLines(LogConsoleView.maxRenderedLines)
        guard fresh != lines else { return }
        lines = fresh
    }
}
