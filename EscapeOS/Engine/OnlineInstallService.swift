import Foundation
import UIKit
import SwiftUI

/// v0.3.379：在线安装（OTA / `itms-services`）—— 把本地已下载的 IPA 交给系统安装。
///
/// ## 机制（ipa-re 逆向牛蛙 `NiuWaCore`，照做）
/// 1. **IPA 由设备本机 HTTP 服务器发**：`GET /package.ipa`（带 `Accept-Ranges`，
///    支持断点续传）→ `IPALocalHTTPServer`。IPA 可以是 `http://127.0.0.1:<port>/…`。
/// 2. **manifest.plist 必须托管在 HTTPS**（iOS 7.1 起不收 http 清单，自签证书也不认）
///    → `ManifestPublisher`（用户自带 HTTPS 地址优先；没填才走匿名免账号 paste 候选）。
/// 3. 打开 `itms-services://?action=download-manifest&url=<清单地址>`，由系统拉清单 + 装包。
///
/// ## 与「覆盖安装」的关系
/// 覆盖安装走 AFC + `installation_proxy`（`IPADownloadCenter.installLocal` →
/// `AppStoreInstallService.installLocalIPA`），是**另一条通道**，本文件一行都不碰。
///
/// ## 前提
/// · OTA 只要求：清单在 HTTPS、安装包签名有效、且本设备/账号对该应用有许可。
/// · **是否 FairPlay 加密（`cryptid=1`）不影响 OTA 通道本身**：App Store 自己的安装
///   走的就是 itms-services，同类工具也在装 App Store 下载的加密包。
///   ⚠️ 曾据「加密包装不了」的说法在 `prepare` 里提前拦截 —— 该假设**无证据，已撤回**，
///   现在加密包照常走完整链路（只记一条非阻断日志）。别再把这条当规则写回来。
enum OnlineInstallService {

    /// 是否已接入真实实现（UI 的「未接入」标记由它驱动）。
    static let isImplemented = true

    /// 本机服务器保活时长：iOS 点了「安装」才会来拉包，打开清单后不能立刻关。
    private static let serverLifetime: TimeInterval = 15 * 60

    private static let logCategory = LoginLogger.Category.appStore

    enum OnlineInstallError: Error, LocalizedError {
        /// 没有任何可用的包地址
        case noPackage
        /// 本地包文件不存在
        case packageMissing
        /// 包本身有问题（缺解析结果/结构异常），原因由解析层给出
        case packageBlocked(String)
        /// 包内 Info.plist 缺 bundle id
        case metadataMissing
        /// 本机服务器起不来
        case serverFailed
        /// 无法调起系统安装
        case openFailed
        /// 三种打开方式都不被系统受理（已复制链接）
        case fallbackClipboard

        var errorDescription: String? {
            switch self {
            case .noPackage: return "未找到安装包"
            case .packageMissing: return "安装包已不存在"
            case .packageBlocked(let reason): return reason
            case .metadataMissing: return "安装包信息缺失"
            case .serverFailed: return "本机服务启动失败"
            case .openFailed: return "无法调起安装"
            case .fallbackClipboard: return "已复制，请在 Safari 打开"
            }
        }
    }

    // MARK: - 入口

    /// 在线安装入口。
    ///
    /// - Parameters:
    ///   - ipaURL: **本地已下载 IPA 的文件 URL**（`file://…`，由下载管理传入）；
    ///             只有在本地文件缺失时才退回传远端 `http(s)` 直链（跳过本机服务器）。
    ///   - bundleId: 目标应用标识（本地包读不到 Info.plist 时兜底）
    ///   - alternatePackageURL: 台账里的远端 `https` 直链，作为清单里的备选 `software-package`
    ///   - completion: 主线程回调
    static func install(ipaURL: URL?,
                        bundleId: String?,
                        alternatePackageURL: String? = nil,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared: Prepared
            do {
                prepared = try prepare(ipaURL: ipaURL,
                                       bundleId: bundleId,
                                       alternatePackageURL: alternatePackageURL)
            } catch {
                LoginLogger.shared.log("[在线安装] ❌ 失败：\(reasonText(error))", category: logCategory)
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let manifestURL: String
            do {
                manifestURL = try publish(prepared)
            } catch {
                if prepared.localFile != nil { IPALocalHTTPServer.shared.stop() }
                LoginLogger.shared.log("[在线安装] ❌ 失败：\(reasonText(error))", category: logCategory)
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            // 打开清单后不马上关服务器：iOS 用户点「安装」才会来拉 IPA。
            if prepared.localFile != nil {
                IPALocalHTTPServer.shared.stop(after: serverLifetime)
                LoginLogger.shared.log("[在线安装] 本机服务器将在 \(Int(serverLifetime / 60)) 分钟后自动关闭",
                                       category: logCategory)
            }

            DispatchQueue.main.async {
                open(manifestURL: manifestURL, completion: completion)
            }
        }
    }

    // MARK: - 准备（读元数据 + 起本机服务器）

    private struct Prepared {
        var bundleId: String
        var version: String
        var title: String
        var packageURL: String
        var alternatePackageURL: String?
        var localFile: URL?
    }

    private static func prepare(ipaURL: URL?,
                                bundleId: String?,
                                alternatePackageURL: String?) throws -> Prepared {
        guard let ipaURL else {
            LoginLogger.shared.log("[在线安装] 没有可用的安装包地址", category: logCategory)
            throw OnlineInstallError.noPackage
        }

        var ipaPath: String?
        var localFile: URL?

        if ipaURL.isFileURL {
            guard FileManager.default.fileExists(atPath: ipaURL.path) else {
                LoginLogger.shared.log("[在线安装] 本地安装包不存在：\(ipaURL.path)", category: logCategory)
                throw OnlineInstallError.packageMissing
            }
            ipaPath = ipaURL.path
            localFile = ipaURL
        } else if let scheme = ipaURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            LoginLogger.shared.log("[在线安装] 本地文件缺失，改用远端直链作为 software-package（跳过本机服务器）",
                                   category: logCategory)
        } else {
            LoginLogger.shared.log("[在线安装] 不支持的安装包地址：\(ipaURL.absoluteString)", category: logCategory)
            throw OnlineInstallError.noPackage
        }

        // 读包内元数据（复用 IPAPackageInspector 的 zip/Info.plist 解析）
        let inspection = ipaPath.flatMap { IPAPackageInspector.inspect(ipaPath: $0) }
        if let inspection {
            let sizeText: String = {
                guard let path = ipaPath,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let number = attrs[.size] as? NSNumber else { return "未知大小" }
                return IPADownloadLibrary.sizeText(number.int64Value)
            }()
            let where_ = ipaURL.isFileURL ? ipaURL.path : ipaURL.absoluteString
            LoginLogger.shared.log("[在线安装] 包信息：\(where_)（\(sizeText)）· \(inspection.summary)",
                                   category: logCategory)

            if inspection.isEncrypted {
                // 只记录、不拦截：OTA 通道本身不检查 FairPlay；能否安装取决于签名有效性与许可。
                LoginLogger.shared.log("[在线安装] 包信息：FairPlay 加密（cryptid=\(inspection.cryptid)），不拦截",
                                       category: logCategory)
            }
        } else if ipaPath != nil {
            LoginLogger.shared.log("[在线安装] ⚠ 未能解析包内 Info.plist，将用台账里的 bundleId 兜底",
                                   category: logCategory)
        }

        let resolvedBundleId = inspection?.bundleIdentifier ?? bundleId
        let version = inspection?.bundleVersion ?? "1.0"
        let title = (inspection?.displayName?.isEmpty == false ? inspection?.displayName : nil)
            ?? ipaURL.deletingPathExtension().lastPathComponent
        guard let resolvedBundleId, !resolvedBundleId.isEmpty else {
            LoginLogger.shared.log("[在线安装] 缺少 bundle-identifier，无法生成清单", category: logCategory)
            throw OnlineInstallError.metadataMissing
        }

        // 起本机服务器（放最后：此前的检查失败都不会留下服务器）
        var packageURL = ipaURL.absoluteString
        if let localFile {
            do {
                let port = try IPALocalHTTPServer.shared.start(fileURL: localFile)
                packageURL = "http://127.0.0.1:\(port)/package.ipa"
                LoginLogger.shared.log("[在线安装] 本机服务器已启动：127.0.0.1:\(port)（仅回环，支持 Range）",
                                       category: logCategory)
            } catch {
                LoginLogger.shared.log("[在线安装] 本机服务器启动失败：\(error.localizedDescription)", category: logCategory)
                throw OnlineInstallError.serverFailed
            }
        }

        // 备选直链：只在它是 https 且与主地址不同时追加
        let alternate: String? = {
            guard let alternatePackageURL, alternatePackageURL.lowercased().hasPrefix("https://"),
                  alternatePackageURL != packageURL else { return nil }
            return alternatePackageURL
        }()

        return Prepared(bundleId: resolvedBundleId, version: version, title: title,
                        packageURL: packageURL, alternatePackageURL: alternate, localFile: localFile)
    }

    // MARK: - 发布清单

    private static func publish(_ prepared: Prepared) throws -> String {
        let info = ManifestPublisher.ManifestInfo(bundleId: prepared.bundleId,
                                                  version: prepared.version,
                                                  title: prepared.title,
                                                  packageURL: prepared.packageURL,
                                                  alternatePackageURL: prepared.alternatePackageURL)
        let manifest = try ManifestPublisher.makeManifest(info)

        var published: Result<String, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        ManifestPublisher.publish(manifest: manifest) { result in
            published = result
            semaphore.signal()
        }
        semaphore.wait()

        guard let published else {
            throw ManifestPublisher.PublishError.noHosting
        }
        switch published {
        case .success(let url):
            LoginLogger.shared.log("[在线安装] 清单地址就绪：\(hostPrefix(url))", category: logCategory)
            return url
        case .failure(let error):
            throw error
        }
    }

    // MARK: - 打开 itms-services（三级兜底）

    private static func open(manifestURL: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // 只保留 unreserved 字符，避免清单地址里的 &/? 之类破坏 query
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = manifestURL.addingPercentEncoding(withAllowedCharacters: allowed),
              let itmsURL = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
            LoginLogger.shared.log("[在线安装] ❌ itms-services 链接拼装失败", category: logCategory)
            completion(.failure(OnlineInstallError.openFailed))
            return
        }

        LoginLogger.shared.log("[在线安装] 打开安装清单：\(itmsURL.absoluteString)", category: logCategory)

        UIApplication.shared.open(itmsURL, options: [:]) { accepted in
            LoginLogger.shared.log("[在线安装] UIApplication.open 是否受理=\(accepted)", category: logCategory)
            if accepted {
                completion(.success(()))
                return
            }
            // 兜底 1：内置 WebView（InAppBrowserView）里再跳一次
            presentBrowserFallback(itmsURL)
            // 兜底 2：复制清单链接，让用户去 Safari 打开
            UIPasteboard.general.string = manifestURL
            LoginLogger.shared.log("[在线安装] 系统未受理，已回退内置浏览器并复制链接（可改用 Safari 打开）",
                                   category: logCategory)
            completion(.failure(OnlineInstallError.fallbackClipboard))
        }
    }

    /// 在 App 内置浏览器里再尝试一次（部分 iOS 版本会拦 App 内的 itms-services）。
    private static func presentBrowserFallback(_ url: URL) {
        guard let top = topViewController() else {
            LoginLogger.shared.log("[在线安装] 无可用控制器，跳过内置浏览器兜底", category: logCategory)
            return
        }
        let host = UIHostingController(rootView: InAppBrowserView(title: "正在安装", url: url))
        host.modalPresentationStyle = .pageSheet
        top.present(host, animated: true)
        LoginLogger.shared.log("[在线安装] 已回退到内置浏览器再跳一次", category: logCategory)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - 日志

    /// 日志用：只记 host + 路径前 8 个字符
    private static func hostPrefix(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return "<invalid>" }
        let host = parsed.host ?? "?"
        let path = parsed.path.hasPrefix("/") ? String(parsed.path.dropFirst()) : parsed.path
        return "\(host)/\(path.prefix(8))"
    }

    private static func reasonText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
