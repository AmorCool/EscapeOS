import Foundation
import UIKit

/// v0.3.295：AppStore 安装通道
///
/// 逆向爱思助手手机端（AsTools.app / HotJs main.jsbundle）得到的结论：
///   它的「在线安装」并不是客户端私有协议，而是调用 **iOS 系统自带的 OTA 分发机制**：
///
///       Linking.openURL("itms-services://?action=download-manifest&url=" + plist)
///
///   plist 是托管在它服务器（dl.i4.cn）上的 manifest 描述文件，其中指向**已重签名的 IPA**；
///   系统读 plist → 自行下载 IPA → 安装 → 用户到「设置 → VPN与设备管理」信任证书
///   （爱思用 cerTrust 弹窗引导，跳 prefs:root=General&path=ManagedConfigurationList）。
///
///   即：**免费的关键不在客户端，而在服务端托管了重签名的 IPA**。客户端只做两件事：
///   ①拿 plist URL ②用 itms-services 交给系统。本文件把这两件事完整实现，
///   分发源由用户自行提供（自有服务器 / 自建 manifest），不依赖任何第三方分发服务。
enum AppStoreInstaller {

    // MARK: - 通道一：系统 App Store（合规、无需任何额外条件）

    /// 打开系统 App Store 的安装页，由 App Store 完成下载与安装
    @discardableResult
    static func openInAppStore(_ item: AppStoreItem) -> Bool {
        if let u = item.storeURL, open(u) { return true }
        if let u = item.webURL, open(u) { return true }
        return false
    }

    // MARK: - 通道二：itms-services OTA（爱思同款系统机制）

    /// 用系统 OTA 机制安装一个 manifest plist 指向的 IPA
    /// - Parameter manifestURL: 指向 manifest plist 的原始 URL（http/https）
    @discardableResult
    static func installViaOTA(manifestURL: String) -> Bool {
        let raw = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let escaped = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        guard let url = URL(string: "itms-services://?action=download-manifest&url=\(escaped)") else { return false }
        return open(url)
    }

    /// 同 installViaOTA，但使用本地生成的 manifest（plist 需自行托管后把 URL 传进来）
    @discardableResult
    static func installViaOTA(manifest: OTAInstallRequest) -> Bool {
        guard let url = manifest.manifestURL else { return false }
        return installViaOTA(manifestURL: url)
    }

    /// 引导用户到「设置 → 通用 → VPN与设备管理」信任分发证书（爱思 cerTrust 同款引导）
    static func openCertificateTrustSettings() {
        let candidates = [
            "App-Prefs:root=General&path=ManagedConfigurationList",
            "prefs:root=General&path=ManagedConfigurationList",
            "App-Prefs:root=General",
            "prefs:root=General",
        ]
        for c in candidates {
            if let u = URL(string: c), open(u) { return }
        }
        // 全部 scheme 被拒时退化为打开「设置」App
        if let u = URL(string: UIApplication.openSettingsURLString) { open(u) }
    }

    // MARK: - manifest plist 生成（OTA 分发的描述文件）

    /// 一次 OTA 安装所需的描述信息
    struct OTAInstallRequest {
        var bundleId: String
        var version: String
        var title: String
        var ipaURL: String
        var iconURL: String?
        var fullSizeIconURL: String?
        /// manifest plist 的托管地址（必须由分发方提供）
        var manifestURL: URL?

        init(bundleId: String, version: String, title: String, ipaURL: String,
             iconURL: String? = nil, fullSizeIconURL: String? = nil, manifestURL: URL? = nil) {
            self.bundleId = bundleId
            self.version = version
            self.title = title
            self.ipaURL = ipaURL
            self.iconURL = iconURL
            self.fullSizeIconURL = fullSizeIconURL
            self.manifestURL = manifestURL
        }
    }

    /// 生成 OTA manifest plist（iOS 官方格式，与爱思服务器下发的 plist 同构）
    static func makeManifestXML(_ req: OTAInstallRequest) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var assets = """
                <dict>
                    <key>kind</key>
                    <string>software-package</string>
                    <key>url</key>
                    <string>\(esc(req.ipaURL))</string>
                </dict>
        """
        if let icon = req.iconURL {
            assets += """
                        <dict>
                            <key>kind</key>
                            <string>display-image</string>
                            <key>needs-shine</key>
                            <false/>
                            <key>url</key>
                            <string>\(esc(icon))</string>
                        </dict>
            """
        }
        if let icon = req.fullSizeIconURL ?? req.iconURL {
            assets += """
                        <dict>
                            <key>kind</key>
                            <string>full-size-image</string>
                            <key>needs-shine</key>
                            <false/>
                            <key>url</key>
                            <string>\(esc(icon))</string>
                        </dict>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>items</key>
            <array>
                <dict>
                    <key>assets</key>
                    <array>
        \(assets)
                    </array>
                    <key>metadata</key>
                    <dict>
                        <key>bundle-identifier</key>
                        <string>\(esc(req.bundleId))</string>
                        <key>bundle-version</key>
                        <string>\(esc(req.version))</string>
                        <key>kind</key>
                        <string>software</string>
                        <key>title</key>
                        <string>\(esc(req.title))</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
    }

    // MARK: - 工具

    @discardableResult
    private static func open(_ url: URL) -> Bool {
        // 白名单已在 Info.plist 的 LSApplicationQueriesSchemes 声明；
        // 无论 canOpenURL 结果如何都发起一次 open（避免误判导致点击无反应），
        // 返回值仅用于调用方决定是否走兜底链接。
        let can = UIApplication.shared.canOpenURL(url)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return can
    }
}
