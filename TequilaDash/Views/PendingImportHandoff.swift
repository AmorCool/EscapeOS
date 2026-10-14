import Foundation

// 共享转换 · onOpenURL →「共享转换」页的记录交接（审计 D4）
//
// 背景：AirDrop /「用其他应用打开」走进 `RootView.onOpenURL` → `ImportService.handleOpenURL`
// → 导入成功，`ImportResult.record` 是**有值**的。但旧的 completion 只切 tab + 弹 toast，
// `record` 被就地丢弃 ⇒ 包已落盘却没接上修补流程；用户按提示去点「扫描新文件」，
// 会把同一个包**再复制一份**（重复包 + 第一条 record 永久丢失）。**头号入口是一条死路。**
//
// 为什么不是「只发通知」：`RootView` 收到 URL 后先切到「更多」tab，而 `ImportView`
// 是用户**再点进「共享转换」才挂载**的。若在挂载前 post 通知，订阅者还不存在 ⇒ 通知丢失。
// 所以写入方先**存挂起值**（单一真相源），再补一条**裸通知**作唤醒信号：
//   · 页面已挂载（AirDrop 回前台那条路径）→ 通知即达，`ImportView` 立刻消费；
//   · 页面未挂载 → 通知会丢，但值还在，`ImportView.onAppear` 挂载时取走。
// 两条通道互补，谁先谁后都不丢，覆盖两种挂载状态。
//
// 隔离：写入方只有 `RootView.onOpenURL`（主 actor），消费方只有 `ImportView`（主 actor），
// 因此整体收敛到主 actor，无需锁、无需 Sendable 标注。
//
// 边界：只**接上记录**，不改变三步确认（导入前 / 修补前 / 安装前）的任何语义，
// 也**不**自动开始修补 / 安装。

/// onOpenURL 导入成功后，把「刚导入的那条记录」交接给「共享转换」页的挂起值。
@MainActor
enum PendingImportHandoff {

    /// 尚未被消费的记录（nil = 没有待接上的记录）。
    private static var pending: ImportRecord?

    /// 写入方（`RootView.onOpenURL`）：存入一条「待接上修补流程」的记录，并广播唤醒信号。
    /// 覆盖式写入（同一时刻只可能有一条待接记录）。
    ///
    /// 先存值、再发通知：通知的载荷仍从挂起值读（**单一真相源**），通知只负责叫醒已挂载的
    /// 消费方，避免「post 晚于 scenePhase 触发点」时挂起值滞留到无人再取。
    static func post(_ record: ImportRecord) {
        pending = record
        NotificationCenter.default.post(name: .escPendingImportHandoff, object: nil)
    }

    /// 消费方（`ImportView`）：**一次性**取走并清空。
    ///
    /// 幂等：取走后立即置 nil，重复调用必然返回 nil —— 同一份记录不会被接上两次。
    /// 调用方必须先过「重入门禁」，再调本方法（见 `ImportView.consumePendingImport`）：
    /// 本方法一旦被调用就一定清空，所以**不能在会被拒绝的分支里先调**。
    static func consume() -> ImportRecord? {
        defer { pending = nil }
        return pending
    }
}
