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
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        // 提亮：纯模糊偏灰，加一层极淡白才有玻璃的通透感。
        appearance.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        // 顶边镜面高光 —— 液态玻璃最标志性的视觉特征。
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.50)
        appearance.shadowImage = specularLineImage()

        let bar = UITabBar.appearance()
        // 清掉系统默认的不透明底板，让上面的材质 + 高光透出来。
        bar.backgroundImage = UIImage()
        bar.isTranslucent = true
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        // 注意：不要在这里设 `bar.shadowImage`，它会覆盖 appearance 的高光线。
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
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.35)
        appearance.shadowImage = specularLineImage()

        let bar = UINavigationBar.appearance()
        bar.isTranslucent = true
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
    }

    // MARK: - 镜面高光线

    /// 1px 顶部高光线：中间最亮、两端渐隐，模拟玻璃上缘的镜面反射。
    ///
    /// 生成一张可拉伸的横条图，交给 `UIBarAppearance.shadowImage`。
    private static func specularLineImage(width: CGFloat = 64) -> UIImage? {
        let scale = UIScreen.main.scale
        let size = CGSize(width: width, height: 1)
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        let colors = [
            UIColor.white.withAlphaComponent(0.04).cgColor,
            UIColor.white.withAlphaComponent(0.90).cgColor,
            UIColor.white.withAlphaComponent(0.04).cgColor
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.5, 1]
        ) else { return nil }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: 0),
            options: []
        )
        return UIGraphicsGetImageFromCurrentImageContext()?
            .resizableImage(withCapInsets: .zero, resizingMode: .stretch)
    }
}
