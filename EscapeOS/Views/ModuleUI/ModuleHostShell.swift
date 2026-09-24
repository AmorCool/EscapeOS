//
//  ModuleHostShell.swift
//  EscapeSpace
//
//  v0.3.481：模块「原生 SwiftUI 二级界面」的外壳.
//
//  ## ★ v0.3.512：顶栏改成**真正的导航栏**（用户反馈「这个顶栏好丑 其实我一直不喜欢这个」）
//
//  旧实现是自绘的一行：左边两个**带文字**的按钮（「返回上一级」「主页」）+ 标题靠右 +
//  一条 Divider. 问题有三个：
//    1. 标题在右边 —— 不符合 iOS 习惯（应居中）
//    2. 两个文字按钮挤在左边，占掉一半宽度，视觉很重
//    3. 自绘栏 + `.background(.bar)` 与系统导航栏的毛玻璃质感对不上
//
//  新实现直接用 `NavigationStack` + `.navigationBarTitleDisplayMode(.inline)`：
//    · 标题**居中**、系统毛玻璃底、与主程序所有二级页完全一致
//    · 出口改成**图标按钮**（返回 = `chevron.left`，主页 = `house`），放左右两侧
//    · 不再自绘 Divider —— 导航栏自带分隔
//
//  ⚠️ 为什么现在**可以**套 NavigationStack 了（旧注释说不能）
//  旧注释的理由是「外壳已有自绘顶栏，再叠系统导航栏会变双层栏」.
//  现在自绘顶栏**已经删掉**，系统导航栏就是唯一那条 ⇒ 不存在双层问题.
//  而且模块的 tab 内容正好需要它（NavigationLink 下钻、`.navigationTitle`）.
//
//  形态（产品要求，未变）：
//    · 全屏盖住 App 的 TabView ⇒ 看不到 App 默认底栏；
//    · 底部导航栏是**模块自己的**（由 ModuleUITab 列表组装）.
//

import SwiftUI

/// 模块原生二级界面的外壳.
struct ModuleHostShell: View {
    let module: EscapeModule
    let tabs: [ModuleUITab]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var router = ModuleUIRouter.shared
    @State private var selection: String = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(module.ui?.title ?? module.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            // 先关二级界面，再 dismiss（cover 由 router.active 驱动，两者幂等）
                            router.back()
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .imageScale(.large)
                                .fontWeight(.semibold)
                        }
                        .accessibilityLabel("返回上一级")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            router.goHome()
                            dismiss()
                        } label: {
                            Image(systemName: "house")
                                .imageScale(.large)
                        }
                        .accessibilityLabel("回主页")
                    }
                }
        }
        // 让模块自己的底栏贴到屏幕底边
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            selection = tabs.first?.id ?? ""
        }
    }

    // MARK: 内容（模块自己的 TabView = 模块自己的底栏）

    @ViewBuilder
    private var content: some View {
        if tabs.isEmpty {
            // 注册名缺失 / 模块没声明原生界面：给一句人话，不留白屏
            ContentUnavailableView(
                "该模块没有可用的原生界面",
                systemImage: "square.grid.2x2",
                description: Text("模块声明的原生界面未在宿主内注册。")
            )
        } else {
            TabView(selection: $selection) {
                ForEach(tabs) { tab in
                    tab.content(module)
                        .tabItem {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                        .tag(tab.id)
                }
            }
        }
    }
}
