import SwiftUI
import UIKit

/// 把系统控件（标签栏 / 导航栏）调整成与 Liquid Glass 一致的玻璃质感。
///
/// iOS 26 起系统会自动把标签栏、工具栏渲染成 Liquid Glass，App 无需处理；
/// iOS 26 以下系统保持旧样式，这里统一配一层半透明 + 材质模糊的外观，
/// 让整体视觉与页面内的 `LiquidGlassPanel` 一致。
enum LiquidGlassAppearance {

    /// 只需调用一次（外观代理是全局的），重复调用无副作用。
    static func applyTabBarStyle() {
        if #available(iOS 26.0, *) {
            // 系统原生 Liquid Glass，保持默认即可。
            return
        }
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.shadowColor = .clear

        let bar = UITabBar.appearance()
        bar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            bar.scrollEdgeAppearance = appearance
        }
    }
}
