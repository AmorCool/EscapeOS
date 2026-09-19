//
//  ModuleHostShell.swift
//  EscapeSpace
//
//  v0.3.481：模块「原生 SwiftUI 二级界面」的外壳.
//
//  形态（产品要求）：
//    · 全屏盖住 App 的 TabView ⇒ 看不到 App 默认底栏；
//    · 底部导航栏是**模块自己的**（由 ModuleUITab 列表组装）；
//    · 顶部常驻两个出口：左上「返回上一级」+ 紧邻的「主页」（一键回默认界面）；
//    · 标题放顶栏中间，**不用** `.navigationTitle` —— 避免和 App 默认导航栏混淆.
//
//  本文件刻意不 import UIKit：外壳只用 SwiftUI 原生件.
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
        VStack(spacing: 0) {
            topBar
            content
        }
        // 让模块自己的底栏贴到屏幕底边（顶栏仍尊重顶部安全区）
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            selection = tabs.first?.id ?? ""
        }
    }

    // MARK: 顶栏（常驻，不随 tab 切换消失）

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    // 先关二级界面，再 dismiss（cover 由 router.active 驱动，两者幂等）
                    router.back()
                    dismiss()
                } label: {
                    Label("返回上一级", systemImage: "chevron.left")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)

                Button {
                    router.goHome()
                    dismiss()
                } label: {
                    Label("主页", systemImage: "house.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Text(module.ui?.title ?? module.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
        }
        .background(.bar)
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
            // 注意：这里**刻意不套 NavigationStack**。
            // 外壳已经有自己的常驻顶栏，再叠一层系统导航栏会在顶栏下面多出一条
            // 空的细条（tab 内容通常不设 navigationTitle），视觉上变成双层栏。
            // 需要下钻/自带导航栏的模块，由它**自己的 tab 内容内部**去套 NavigationStack.
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
