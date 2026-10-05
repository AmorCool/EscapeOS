//
//  ModuleUIRouter.swift
//  EscapeSpace
//
//  v0.3.481：模块「原生 SwiftUI 二级界面」的路由（谁在展示、怎么退出）.
//
//  二级界面本身用 `fullScreenCover(item:)` 盖住 App 的 TabView（看不到默认底栏），
//  但「回主页」这件事必须让 **RootView** 去切自己的 tab —— 而 `MainTab` 是
//  `RootView.swift` 里的 private 枚举，别的文件引用不到，所以这里走 NotificationCenter：
//  路由只负责关掉二级界面 + 广播一个「切到主页」的通知.
//

import SwiftUI
import Combine

extension Notification.Name {
    /// 二级界面点「主页」时发；RootView 收到后切到主页 tab
    static let escSelectHomeTab = Notification.Name("esc.selectHomeTab")

    /// `PendingImportHandoff.post(_:)` 写入挂起记录后广播（裸通知，**不带 payload**）。
    /// `ImportView` 收到后去消费挂起值。载荷只走挂起值这**一个真相源**，通知只作唤醒信号：
    /// 覆盖「页面已挂载、AirDrop 回前台把 App 带回」时 `scenePhase` 早于 `post` 触发、
    /// 之后再无触发点的那条路径（见 `PendingImportHandoff` 顶部注释）。
    static let escPendingImportHandoff = Notification.Name("esc.pendingImportHandoff")
}

/// 模块原生二级界面的展示状态（单例，全局只有一个二级界面）.
@MainActor
final class ModuleUIRouter: ObservableObject {
    static let shared = ModuleUIRouter()

    /// 当前展示的模块原生界面；nil = 不展示
    @Published var active: EscapeModule?

    private init() {}

    /// 打开某模块的原生二级界面.
    func open(_ module: EscapeModule) {
        active = module
    }

    /// 返回上一级（只关闭二级界面，回到模块卡片所在的页面）.
    func back() {
        active = nil
    }

    /// 一键回默认界面（关二级界面 + 通知 RootView 切主页 tab）.
    func goHome() {
        active = nil
        NotificationCenter.default.post(name: .escSelectHomeTab, object: nil)
    }
}
