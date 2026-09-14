import Foundation
import UIKit
import SwiftUI

/// v0.3.379：在线安装（OTA / `itms-services`）—— 把本地已下载的 IPA 交给系统安装。
///
/// ## 机制（ipa-re 逆向牛蛙 `NiuWaCore`，照做）
/// 1. **IPA 由设备本机 HTTP 服务器发**：`GET /package.ipa`（带 `Accept-Ranges`，
///    支持断点续传）→ `IPALocalHTTPServer`，监听 `0.0.0.0:<随机端口>`，
///    包地址默认用**局域网 IP**（`http://<LAN-IP>:<port>/package.ipa`），
///    取不到 LAN IP 才回落 `127.0.0.1`。
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

    /// v0.3.396（B 项）：「系统没来拉包」的判定窗口（一次性看门狗）。
    private static let noBytesWindow: TimeInterval = 60

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
                // 这次 OTA 没跑起来 → 清掉可能已经开始的进度会话（别让列表里挂个假进度）
                OnlineInstallProgress.shared.reset()
                LoginLogger.shared.log("[在线安装] ❌ 失败：\(reasonText(error))", category: logCategory)
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let manifestURL: String
            do {
                manifestURL = try publish(prepared)
            } catch {
                if prepared.localFile != nil { IPALocalHTTPServer.shared.stop() }
                OnlineInstallProgress.shared.reset()
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
            // v0.3.388：进度会话同样在保活到期时收尾。
            // ⚠️ 这只是「我们的观测窗口结束了」，**不是「系统装完了」** —— 系统安装阶段不可观测。
            OnlineInstallProgress.shared.scheduleIdleReset(after: serverLifetime)

            DispatchQueue.main.async {
                open(manifestURL: manifestURL, completion: completion)
                // v0.3.396（B 项）：清单已发起 → 挂一次性「系统没来拉包」看门狗。
                // 只在**经本机服务器发包**（localFile != nil）时挂：远端直链路径我们一个字节都量不到，
                // 那里挂这个看门狗会在 60 秒时误报「系统未开始下载」，反而是假信号 —— 那条路径的
                // 兜底交给 `OnlineInstallProgress` 的 3 分钟 `.installing` 窗口。
                if prepared.localFile != nil { armNoBytesWatchdog() }
            }
        }
    }

    // MARK: - 看门狗（B 项）

    /// v0.3.396（B 项）：**一次性**「系统没来拉包」看门狗 —— 必须在主线程调。
    ///
    /// 现象：设备上已装同一版本、或系统直接拒装时，`itms-services` 会走完（`open` 受理成功），
    /// 但系统**一个字节都不会来拉** → 进度环停在 0% 转圈，而唯一的收尾是 15 分钟保活到期。
    /// 用户看到的就是「一直卡在在线安装圆圈」。
    ///
    /// 判定：发起后 `noBytesWindow`（60 秒）内已发字节始终为 0 → 判「系统未开始下载」→
    /// `reset()` + 短提示。**只 `asyncAfter` 一次**（不是轮询）；60 秒内只要来过任何字节，
    /// 到期时这道判定就静默作废（不会 reset、不会提示）。
    ///
    /// 两道守卫（读的都是主线程状态）：
    /// · `sessionToken == token` —— 期间又发起了新 OTA（`begin` 会涨会话号）→ 这次判定作废，
    ///   否则同一个包连点两次时，第一次留下的看门狗会把**第二次**的进度环误收掉；
    /// · `stage != .idle && sentBytes == 0` —— 期间已被别的路径（手动点环 / 传输完成进入系统安装）
    ///   清空或推进 → 不作声、不重复提示。`reset()` 本身不涨会话号，所以这道状态守卫是第二层。
    private static func armNoBytesWatchdog() {
        let token = OnlineInstallProgress.shared.sessionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + noBytesWindow) {
            let progress = OnlineInstallProgress.shared
            guard progress.sessionToken == token else { return }
            guard progress.stage != .idle, progress.sentBytes == 0 else { return }
            LoginLogger.shared.log("[在线安装] 60 秒内系统未拉包（设备已装同一版本 / 被拒装）→ 收掉进度环",
                                   category: logCategory)
            progress.reset()
            ToastCenter.shared.show("系统未开始下载")
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
            // v0.3.388：进度回调先挂上（在服务器队列上触发 → 载体自己 hop 回主线程）。
            // 系统来拉包的每一个字节都会经过这里，这是我们**唯一**能测到 OTA 进度的来源。
            IPALocalHTTPServer.shared.onProgress = { sent, total in
                OnlineInstallProgress.shared.update(sent: sent, total: total)
            }
            do {
                let serving = try IPALocalHTTPServer.shared.start(fileURL: localFile, purpose: .ota)
                packageURL = serving.packageURL
                OnlineInstallProgress.shared.begin(fileName: localFile.lastPathComponent,
                                                   bundleId: resolvedBundleId,
                                                   total: serving.packageSize,
                                                   observable: true)
                LoginLogger.shared.log("[在线安装] 本机服务器已启动：监听 \(serving.listenHost):\(serving.port)（只读单文件 /package.ipa，支持 Range）",
                                       category: logCategory)
                LoginLogger.shared.log("[在线安装] software-package.url=\(serving.packageURL)（\(serving.usesLAN ? "局域网 IP" : "局域网 IP 取不到，回落回环")）",
                                       category: logCategory)
            } catch {
                LoginLogger.shared.log("[在线安装] 本机服务器启动失败：\(error.localizedDescription)", category: logCategory)
                throw OnlineInstallError.serverFailed
            }
        } else {
            // 远端直链：包不经本机服务器 → 我们**一个字节都测不到** → 直接进不确定态，不显示假百分比
            OnlineInstallProgress.shared.begin(fileName: nil,
                                               bundleId: resolvedBundleId,
                                               total: 0,
                                               observable: false)
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
            OnlineInstallProgress.shared.reset()
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
            // 系统没受理 = 不会真的安装 → 收掉进度会话，别在列表里挂个永远转的圈
            OnlineInstallProgress.shared.reset()
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
