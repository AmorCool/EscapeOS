import SwiftUI
import UIKit
import SafariServices

/// 监督模式工具共用的小组件：App 图标（私有 API）、已安装应用枚举、底部安装按钮、app 内 Safari。

/// 通过私有 API 取得已安装 App 的图标（与 Lithium 一致）。
/// 需在 EscapeOS-Bridging-Header.h 中声明
/// `+ (instancetype)_applicationIconImageForBundleIdentifier:format:scale:`。
func supervisedAppIcon(_ bundleID: String) -> Image {
    guard let img = UIImage._applicationIconImage(forBundleIdentifier: bundleID, format: 1, scale: UIScreen.main.scale) else {
        return Image(systemName: "app.dashed")
    }
    return Image(uiImage: img)
}

/// 设备本地枚举已安装应用（LSApplicationWorkspace 私有 API，运行时反射调用，
/// 不产生编译期类符号引用，Theos 下无需额外链接 CoreServices）。
/// 不需要配对文件 / 本地隧道，证书直装环境直接可用。
/// 只返回用户安装的应用（User / Internal）——隐藏对系统 App 无效。
func supervisedInstalledApps() -> [InstalledApp] {
    guard let wsClass = NSClassFromString("LSApplicationWorkspace") as AnyObject?,
          let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue(),
          let proxies = ws.perform(NSSelectorFromString("allApplications"))?.takeUnretainedValue() as? [NSObject] else {
        return []
    }
    var result: [InstalledApp] = []
    for proxy in proxies {
        guard let bid = proxy.value(forKey: "bundleIdentifier") as? String else { continue }
        let type = (proxy.value(forKey: "applicationType") as? String) ?? "User"
        if type == "System" || type == "HiddenSystemApp" { continue }
        let nm = (proxy.value(forKey: "localizedName") as? String) ?? ""
        result.append(InstalledApp(
            bundleIdentifier: bid,
            name: nm.isEmpty ? bid : nm,
            containerPath: "",
            version: nil,
            applicationType: type
        ))
    }
    return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// app 内 Safari 的展示目标（URL 需要 Identifiable 才能用 `.sheet(item:)`）。
struct SafariTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// 用 app 内 SFSafariViewController 打开描述文件安装页。
/// 与 Lithium 原版一致：保持本应用前台，本地 HTTP 服务器不会因进程
/// 被挂起而失联（跳外部 Safari 时应用退后台会被 iOS 挂起，accept 线程
/// 停摆，导致 meta refresh 后的第二次请求连不上服务器）。
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
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
