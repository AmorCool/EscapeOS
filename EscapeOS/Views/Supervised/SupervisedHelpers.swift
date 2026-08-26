import SwiftUI
import UIKit

/// 监督模式工具共用的小组件：App 图标（私有 API）、底部安装按钮。

/// 通过私有 API 取得已安装 App 的图标（与 Lithium 一致）。
/// 需在 EscapeOS-Bridging-Header.h 中声明
/// `+ (instancetype)_applicationIconImageForBundleIdentifier:format:scale:`。
func supervisedAppIcon(_ bundleID: String) -> Image {
    let img = UIImage._applicationIconImage(forBundleIdentifier: bundleID, format: 1, scale: UIScreen.main.scale)
    return Image(uiImage: img)
}

/// 底部统一的「安装描述文件」按钮条。
struct SupervisedInstallFooter: ViewModifier {
    let title: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
    }
}

extension View {
    /// 给监督模式工具页添加统一的底部安装按钮。
    func supervisedInstallFooter(title: String = "安装描述文件", action: @escaping () -> Void) -> some View {
        self.modifier(SupervisedInstallFooter(title: title, action: action))
    }
}

// MARK: - 已登记应用目录持久化

/// 把「可隐藏 App」与「通知管理 App」的目录以 JSON 存入 UserDefaults。
/// 用 JSON Data 而非 `@AppStorage(Codable)`，避免不同 SDK 对 @AppStorage
/// 的 Codable 支持差异导致编译失败。
extension UserDefaults {
    private enum Keys {
        static let hiddenApps = "esc_hiddenApps"
        static let notificationApps = "esc_notificationApps"
    }

    var esc_hiddenApps: [HiddenAppItem] {
        get {
            guard let data = data(forKey: Keys.hiddenApps) else { return [] }
            return (try? JSONDecoder().decode([HiddenAppItem].self, from: data)) ?? []
        }
        set { set(try? JSONEncoder().encode(newValue), forKey: Keys.hiddenApps) }
    }

    var esc_notificationApps: [NotificationEntry] {
        get {
            guard let data = data(forKey: Keys.notificationApps) else { return [] }
            return (try? JSONDecoder().decode([NotificationEntry].self, from: data)) ?? []
        }
        set { set(try? JSONEncoder().encode(newValue), forKey: Keys.notificationApps) }
    }
}
