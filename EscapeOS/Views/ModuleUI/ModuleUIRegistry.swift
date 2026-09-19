//
//  ModuleUIRegistry.swift
//  EscapeSpace
//
//  v0.3.481：模块「原生 SwiftUI 二级界面」的视图注册表.
//
//  为什么需要注册表：模块清单（module.json）可以声明 `ui.view = "xxx"`，
//  但 SwiftUI 视图**没法从 zip 里加载** —— 它必须编译进宿主。所以清单里写的
//  只是一个**注册名**，真正的视图由宿主内的代码向本表注册：
//
//      ModuleUIRegistry.shared.register("airlift-poc") { module in
//          [ModuleUITab(id: "main", title: "概览", systemImage: "square.grid.2x2") { m in
//              AirliftModuleView(module: m)     // 视图本身由宿主编译，这里只是登记
//          }]
//      }
//
//  注册名没注册（模块比宿主新、或宿主降级）⇒ `tabs(for:)` 返回空 ⇒
//  模块卡片**不显示「打开」入口**（不会给用户一个点进去是空白的按钮）。
//

import SwiftUI

/// 模块原生界面的一个 Tab.
///
/// 每个 Tab 自带标题与图标，由 `ModuleHostShell` 组装成模块**自己的**底部导航栏
///（与 App 默认底栏无关）.
struct ModuleUITab: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// 该 Tab 的内容；入参是模块本身，调用方按需渲染.
    let content: (EscapeModule) -> AnyView

    /// **唯一的**初始化器：调用方给 `@ViewBuilder` 闭包，内部包成 `AnyView`.
    ///
    /// 注册表必须把异质视图存进同一个 `[ModuleUITab]`，所以存储形态是 `AnyView`；
    /// 但调用方只写视图本身即可，不用手写 `AnyView(...)`.
    ///
    /// 刻意**只保留这一个**：若再加一个 `content: @escaping (EscapeModule) -> AnyView`
    /// 的重载，调用点写 `content: { AnyView(X) }` 时两个重载都能匹配，胜负要靠
    /// 「非泛型优先」的消解规则去赌 —— 那是可以避免的脆弱点。只留一个 ⇒
    /// 歧义在**类型层面**就不可能发生.
    ///
    /// 另外这里是**直接写存储属性**而不是 `self.init(...)` 委托（本类型也只有这一个
    /// 初始化器，没有可委托的对象）.
    init<V: View>(id: String, title: String, systemImage: String,
                  @ViewBuilder content: @escaping (EscapeModule) -> V) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.content = { module in AnyView(content(module)) }
    }
}

/// 视图注册表：模块清单只声明「注册名」，真正的 SwiftUI 视图必须编译进宿主.
///
/// `@MainActor`：注册表只在启动期（`registerBuiltinModuleUIs()`）写、在 UI 构建期读，
/// 全部发生在主 actor 上；标注后 `static let shared` 也是 MainActor 隔离的，
/// `View` 里直接访问是安全的（`View` 的 body 本身就在主 actor）.
@MainActor
final class ModuleUIRegistry {
    static let shared = ModuleUIRegistry()

    /// 注册名 → (模块) -> Tab 列表
    private var builders: [String: (EscapeModule) -> [ModuleUITab]] = [:]

    private init() {}

    /// 注册某个注册名对应的 Tab 构造器.
    /// 同名重复注册：**后者覆盖前者**（便于调试期反复注册），并打一行日志.
    func register(_ name: String, tabs: @escaping (EscapeModule) -> [ModuleUITab]) {
        if builders[name] != nil {
            print("[ModuleUIRegistry] 注册名「\(name)」重复注册，后者覆盖前者")
        }
        builders[name] = tabs
    }

    /// 该注册名是否有可用的原生界面（nil / 空串 / 未注册都返回 false）.
    func hasTabs(named name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return builders[name] != nil
    }

    /// 取模块的原生界面 Tab 列表.
    /// `nativeUIViewName` 为 nil（模块没声明原生界面）或该注册名没注册 → 返回 `[]`.
    func tabs(for module: EscapeModule) -> [ModuleUITab] {
        guard let name = module.nativeUIViewName, let build = builders[name] else { return [] }
        return build(module)
    }

    /// 已注册的全部注册名（排查「模块比宿主新」时看这个）.
    var registeredNames: [String] { builders.keys.sorted() }
}

/// 宿主内置模块原生界面的统一注册入口.
///
/// 各模块的 SwiftUI 视图分别在自己的文件里向 `ModuleUIRegistry.shared` 注册，
/// 由本函数一次性触发（调用点：`EscapeSpaceApp.init()`）.
/// 之所以集中在一个函数里，是为了让「宿主支持哪些模块原生界面」有**单一可读清单**，
/// 而不是散落在各处的副作用.
@MainActor
func registerBuiltinModuleUIs() {
    // 由各模块 UI 文件追加注册
}
