import Foundation
import UIKit

/// AppStore 安装通道：**只保留「在系统 App Store 中打开」**。
///
/// v0.3.315：原先的 itms-services OTA 通道与「证书信任设置」跳转已整体移除
/// （不再需要自定义 manifest 分发源）。
enum AppStoreInstaller {

    /// 打开系统 App Store 的安装页，由 App Store 完成下载与安装
    @discardableResult
    static func openInAppStore(_ item: AppStoreItem) -> Bool {
        if let u = item.storeURL, open(u) { return true }
        if let u = item.webURL, open(u) { return true }
        return false
    }

    @discardableResult
    private static func open(_ url: URL) -> Bool {
        let can = UIApplication.shared.canOpenURL(url)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return can
    }
}
