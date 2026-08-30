import SwiftUI
import UIKit

/// 把系统栏（标签栏 / 导航栏）渲染成与页面一致的液态玻璃。
///
/// ## 三个必须遵守的坑（v0.2.149 实测修正）
///
/// 1. **必须在 App 启动前调用**。`UIAppearance` 代理只对**之后创建**的
///    实例生效；SwiftUI 的 `TabView` 在第一帧就建好了 `UITabBar`。
///    v0.2.148 把它放在 `View.onAppear` 里 —— 设置时机太晚，等于没设。
///    现在由 `EscapeSpaceApp.init()` 调用。
///
/// 2. **不能配 `.toolbarBackground(.visible, for: .tabBar)`**。该修饰器让
///    SwiftUI 给标签栏加一层**不透明**背景，直接盖掉这里的透明 + 材质。
///    `RootView` 已移除这一行。
///
/// 3. **光有 `UIBlurEffect` 只有模糊没有玻璃感**。液态玻璃的辨识特征是
///    **上缘镜面高光** + **通透提亮**，所以这里额外叠一层极淡白底 +
///    一条顶部高光渐变线。
///
/// iOS 26 起系统自动把标签栏 / 工具栏渲染成 Liquid Glass，无需处理。
enum LiquidGlassAppearance {

    /// 只需调用一次（外观代理是全局的），重复调用无副作用。
    static func apply() {
        applyTabBarStyle()
        applyNavigationBarStyle()
    }

    // MARK: - 标签栏

    private static func applyTabBarStyle() {
        if #available(iOS 26.0, *) {
            // 系统原生 Liquid Glass，保持默认即可。
            return
        }
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        // iOS 18 没有系统级液态玻璃，用 systemChromeMaterial 毛玻璃当“玻璃”底：
        // 自带模糊 + 通透感，是系统栏默认材质，最接近 iOS 26 的玻璃质感。
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        // 关键修正：不要叠加白色实底，否则在浅色页面上会被渲染成“实色亮条”
        // （v0.2.149 实测的“很丑”来源）。纯毛玻璃即可透出底部内容。
        appearance.backgroundColor = .clear
        // 顶边不画刺眼的白色镜面高光线，保持纯净毛玻璃，对齐 iOS 26。
        appearance.shadowImage = nil
        appearance.shadowColor = nil

        let bar = UITabBar.appearance()
        // 清掉系统默认的不透明底板，让上面的材质透出来。
        bar.backgroundImage = UIImage()
        bar.isTranslucent = true
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
    }

    // MARK: - 导航栏

    /// 导航栏同步成同一种玻璃，否则顶部是普通毛玻璃、底部是液态玻璃，
    /// 视觉上会割裂。
    private static func applyNavigationBarStyle() {
        if #available(iOS 26.0, *) {
            return
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        // 与底栏一致：systemChromeMaterial 毛玻璃 + 纯透底，去掉刺眼白色高光线。
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        appearance.backgroundColor = .clear
        appearance.shadowImage = nil
        appearance.shadowColor = nil

        let bar = UINavigationBar.appearance()
        bar.isTranslucent = true
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
    }
}
