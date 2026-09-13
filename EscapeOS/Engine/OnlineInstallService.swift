import Foundation

/// v0.3.378：在线安装（OTA）—— 用 `itms-services://` 清单把远端安装包交给系统安装。
///
/// ⚠️ **当前不可用，且不是「还没写完」**：机制已查明（见下），但本仓库缺两个硬前提，
/// 所以这里只留接口，**不落任何「看起来能用」的分支**。UI 按本类型真实返回值原样提示。
///
/// ## 机制（ipa-re 逆向牛蛙 `NiuWaCore`）
/// `itms-services://?action=download-manifest&url=<HTTPS manifest.plist>`；
/// manifest 是明文 plist：`items[].assets[]`（`software-package` / `display-image` /
/// `full-size-image`）与 `items[].metadata`（`bundle-identifier` / `bundle-version` / `title`）。
///
/// ## 两个硬前提（本仓库都不满足）
/// 1. **manifest.plist 与 .ipa 都必须是 HTTPS，且证书被设备信任**（iOS 7.1 起不接受 http 清单）。
///    本仓库唯一的本地服务器 `ProfileHTTPServer` 是裸 HTTP + `127.0.0.1`，只用来发
///    `.mobileconfig`，**不能**用于 OTA 清单。
/// 2. **IPA 必须是设备信任的签名**（企业 in-house，或含本机 UDID 的开发 / Ad-Hoc 证书）；
///    App Store 签名包、随便一个 p12 重签都不行。
///
/// 所以「对本地已下载的 IPA 做在线安装」在当前能力下不成立 —— 也别拿本地 server 去凑。
/// 另注：在线安装走 OTA，与「覆盖安装」的 AFC / instproxy 直装是两条互不替代的路。
/// 将来拿到 HTTPS 托管 + 可信签名（或换一条私有通道）后，只改本文件的实现体即可。
enum OnlineInstallService {

    /// 是否已接入真实实现。
    /// UI 用它给「在线安装」行加「未接入」标记；接真实现后置 `true`，标记自动消失。
    static let isImplemented = false

    enum OnlineInstallError: Error, LocalizedError {
        case notImplemented

        var errorDescription: String? {
            switch self {
            case .notImplemented: return "在线安装需 HTTPS 托管，当前不可用"
            }
        }
    }

    /// 在线安装入口。
    ///
    /// - Parameters:
    ///   - ipaURL: 远端安装包地址（台账里没有来源直链时传 `nil`）
    ///   - bundleId: 目标应用标识
    ///   - completion: 主线程回调；当前恒为 `.failure(.notImplemented)`
    static func install(ipaURL: URL?,
                        bundleId: String?,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            completion(.failure(OnlineInstallError.notImplemented))
        }
    }
}
