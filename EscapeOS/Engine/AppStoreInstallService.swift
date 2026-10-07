import Foundation
import UIKit

/// AppStore 商店 / 免登录源 —— IPA 下载与本地安装服务。
///
/// v0.3.315：第三方「分发源」与 itms-services OTA 链路已整体移除，这里只保留两件事：
///   · `downloadIPA`  —— 把远端的 IPA 下载到 `Documents/AppStoreDownloads/`
///   · `installLocalIPA` —— 经 RSD 隧道把本地 IPA 装到设备（按 cryptid 分流：
///     加密包用包内 `SC_Info/*.sinf` 作 `ApplicationSINF`，明文包走普通 Install）
enum AppStoreInstallService {

    enum InstallError: Error, LocalizedError {
        case badTemplate
        case requestFailed(String)
        /// v0.3.571：下载源域不在允许范围内（AppleID 通道要求落在 Apple 自有域）。
        case untrustedHost(String)
        /// v0.3.300：加密包缺少 `SC_Info/*.sinf`，installd 无法解密安装
        case missingSINF(bundleId: String?)
        /// v0.3.570：**无法判定**加密状态（主二进制读不出）且包内无 sinf —— 无法安全安装。
        ///
        /// 与 `missingSINF` 的区别：
        /// · `missingSINF` = **已确认加密**（cryptid≠0）却缺 sinf；
        /// · 本 case     = **连加密状态都判不出**（`.unknown`，主二进制读不出）。
        ///   此时既不能走 ApplicationSINF 通道（没有 sinf），也**不能按明文装** ——
        ///   未知可能是加密包，按明文装会「装不上 / 装后崩」。真明文包的主二进制读得出来，
        ///   判不出即不可信 ⇒ 明确拒绝，不冒险。
        case indeterminateEncryption(bundleId: String?)

        var errorDescription: String? {
            switch self {
            case .badTemplate: return "源模板拼出的地址无效"
            case .requestFailed(let m): return "源接口请求失败：\(m)"
            case .untrustedHost(let h):
                return "下载地址不在 Apple 自有域内（\(h)），已拒绝下载（防止下载源被篡改）."
            case .missingSINF(let bid):
                let who = bid.map { "（\($0)）" } ?? ""
                return "该 IPA\(who) 是加密包，但缺少 SC_Info/*.sinf，installd 无法解密安装，"
                     + "App Store 原始包需要由安装它的同一 Apple ID 在本机下载，才会带可用 sinf."
            case .indeterminateEncryption(let bid):
                let who = bid.map { "（\($0)）" } ?? ""
                return "无法判定该 IPA\(who) 的加密状态（主二进制读不出），且包内没有 SC_Info/*.sinf，"
                     + "无法安全安装：既不能按加密包走 ApplicationSINF 通道（缺 sinf），"
                     + "也不能按明文包安装（可能是加密包，装不上或装后闪退），"
                     + "请改用未加密（已解密 / 已重签）的包，或用带 sinf 的正版包."
            }
        }
    }

    static func downloadIPA(urlString: String,
                            suggestedName: String,
                            progress: ((Double) -> Void)? = nil,
                            // v0.3.571：可选的下载源域策略（AppleID 通道专用）。
                            //
                            // 传 nil（默认）= 不限制，爱思源（`d-app6.i4.cn`）等**非 Apple 域**调用方行为不变。
                            // AppleID 正版通道传 `StoreAuthenticationProtocol.isAppleHost`，把
                            // 「下载地址必须落在 Apple 自有域」这条**隐含前提真正强制**下来：
                            // 初始 URL 与**每一次 HTTP 重定向**都查（只查初始 URL 挡不住 302 换域）。
                            //
                            // 为什么这条前提值得强制：`SignatureInjector` 会拿**下载到的这个 IPA 自带**的
                            // `SC_Info/Manifest.plist` 当写入目标清单（vendor 侧有意不做路径校验，因为输入
                            // 本应来自 Apple 正版包）。若下载地址能被引到第三方域，那份 Manifest 就不可信，
                            // 进而可驱动任意 ZIP 条目名。本校验就是把那个「输入可信」前提锁死。
                            hostPolicy: ((String) -> Bool)? = nil,
                            onLog: ((String) -> Void)? = nil) async throws -> URL {
        guard let url = URL(string: urlString) else { throw InstallError.badTemplate }
        if let hostPolicy {
            guard url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(), hostPolicy(host) else {
                throw InstallError.untrustedHost(url.host ?? urlString)
            }
        }
        onLog?("[下载] 开始：\(urlString)")
        let dir = try downloadDirectory()
        let safe = suggestedName.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appendingPathComponent(safe.hasSuffix(".ipa") ? safe : safe + ".ipa")
        try? FileManager.default.removeItem(at: dest)

        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            IPAFileDownloader(hostPolicy: hostPolicy, progress: progress, completion: { result in
                switch result {
                case .success(let tmp):
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }).start(request: req)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        onLog?("[下载] 完成：\(size / 1024 / 1024) MB → \(dest.lastPathComponent)")
        progress?(1.0)
        return dest
    }

    /// 下载目录（`Documents/AppStoreDownloads`）
    static func downloadDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AppStoreDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 把本地 IPA 装到设备 —— **复用既有 RSD 隧道安装能力**（`IPAInstallService`）。
    ///
    /// 按包的加密状态分两条通道（v0.3.300 修正，对齐 NB Signer / ideviceinstaller）：
    ///
    /// **① 加密包（App Store 原始包，`cryptid == 1`）**
    ///   提取 `SC_Info/<exe>.sinf` → 以 `PackageType: Customer` + `ApplicationSINF`
    ///   交给 installd。installd 用 sinf 向 Apple 请求**本设备**的解密密钥后解密安装。
    ///   前提：sinf 是为**本设备**生成的（用本机 Apple ID 下载得到的包）。
    ///   包里没有 sinf → 直接报错说明，不做无用功。
    ///
    /// **② 明文包（已重签名 / 已解密）**
    ///   直接 `installSignedIPA`（`PackageType: Application`）。
    ///
    /// `allowDowngrade = true` 时用 `Upgrade` 命令 —— installd 不拦降级，装历史版本用。
    ///
    /// v0.3.388：`progress` 回调的口径是**整条安装链的 0~1**：
    /// AFC 上传段 0~0.75（`IPAInstallService.uploadFile` 按字节统计）+ installd 段 0.75~1
    /// （系统自己回报的 0~100）。上传段以前没有任何回调，界面只能停在 0% 干等。
    /// 注意这是**声明式加权**（与下载中心既有的下载 75% / 安装 25% 同口径），不是系统的整体百分比。
    static func installLocalIPA(_ ipaPath: String,
                                allowDowngrade: Bool = false,
                                progress: (@Sendable (Double) -> Void)? = nil,
                                onLog: ((String) -> Void)? = nil) async throws {
        let svc = IPAInstallService.shared
        let ins = IPAPackageInspector.inspect(ipaPath: ipaPath)

        if let ins {
            onLog?("[检测] \(ins.bundleIdentifier ?? "-") \(ins.bundleVersion ?? "-") · \(ins.summary)")
        } else {
            onLog?("[检测] 无法读取包信息（加密状态无法判定，需凭包内 sinf 判断能否安装）")
        }

        // 加密状态三态（v0.3.570）：**只有确定是明文包**才走常规安装。
        // 加密或「无法判定」（主二进制读不出）都先看包内有没有 sinf；**没有 sinf 一律拒绝** ——
        // 否则「读不出加密状态」会被当成「未加密」，把加密包按明文装（装不上 / 装后崩，
        // 即用户最初报的症状）。真明文包的主二进制是读得出来的，判不出即不可信。
        let encryption = ins?.encryption ?? .unknown
        if encryption != .plaintext {
            if let sinf = IPAPackageInspector.extractSINF(ipaPath: ipaPath) {
                // 加密包 → ApplicationSINF 通道
                let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: ipaPath)
                let kindLabel = encryption == .encrypted
                    ? "加密包"
                    : "加密状态未知（主二进制读不出），但包内有 sinf"
                onLog?("[安装] \(kindLabel)：携带 ApplicationSINF（\(sinf.count) 字节）"
                       + (meta != nil ? " + iTunesMetadata" : "") + " 交给 installd 解密安装")
                try await Task.detached(priority: .userInitiated) {
                    try svc.installWithSINF(ipaPath,
                                            sinf: sinf,
                                            iTunesMetadata: meta,
                                            upgrade: allowDowngrade,
                                            progress: { p in progress?(p) })
                }.value
                onLog?("[安装] 完成")
                return
            }
            // 无 sinf ⇒ 走不了 ApplicationSINF 通道，按加密状态分别拒绝（**都不落到明文通道**）：
            //   · 明确加密 → missingSINF（缺 sinf）
            //   · 无法判定 → indeterminateEncryption（连加密状态都判不出，不能按明文装）
            if encryption == .encrypted {
                throw InstallError.missingSINF(bundleId: ins?.bundleIdentifier)
            }
            throw InstallError.indeterminateEncryption(bundleId: ins?.bundleIdentifier)
        }

        // 明文包（明确 cryptid==0）→ 常规安装
        try await Task.detached(priority: .userInitiated) {
            if allowDowngrade {
                try svc.upgradeSignedIPA(ipaPath, progress: { p in progress?(p) })
            } else {
                try svc.installSignedIPA(ipaPath, progress: { p in progress?(p) })
            }
        }.value
        onLog?("[安装] 完成")
    }

    /// 完整链路：源 → manifest → IPA → 下载 → RSD 隧道安装
    @discardableResult

    // MARK: - 工具

    /// `a.b.c` 取值
    private static func value(at path: String, in obj: Any) -> String? {        var cur: Any = obj
        for seg in path.split(separator: ".") {
            let key = String(seg)
            if let dict = cur as? [String: Any], let next = dict[key] {
                cur = next
            } else if let arr = cur as? [Any], let idx = Int(key), idx < arr.count {
                cur = arr[idx]
            } else {
                return nil
            }
        }
        if let s = cur as? String { return s }
        if let n = cur as? NSNumber { return n.stringValue }
        return nil
    }

    /// 解析形如 `{"X-Token":"abc"}` 的请求头
    private static func parseHeaders(_ raw: String) -> [String: String]? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = (v as? String) ?? "\(v)" }
        return out.isEmpty ? nil : out
    }
}

/// v0.3.300：带进度的 IPA 文件下载器（`URLSessionDownloadTask` + delegate）
///
/// 用回调式下载而非 `URLSession.download(for:)`，目的只有一个：**拿到字节级进度**。
/// 每次实例化创建一个独立 `URLSession`（用完即释放），互不干扰，可在多个安装任务中并发使用。
private final class IPAFileDownloader: NSObject, URLSessionDownloadDelegate {

    private let onProgress: ((Double) -> Void)?
    private let completion: (Result<URL, Error>) -> Void
    /// v0.3.571：非空时，每一次 HTTP 重定向的目标 host 都必须通过它（AppleID 通道传 Apple 域白名单）。
    /// nil = 不限制（爱思等非 Apple 源沿用旧行为）。
    private let hostPolicy: ((String) -> Bool)?
    /// 被本下载器拒绝跟随的重定向目标 host（用于给出可诊断的错误，而不是笼统的「HTTP 302」）。
    private var rejectedRedirectHost: String?
    private var session: URLSession?
    private var finished = false

    init(hostPolicy: ((String) -> Bool)?,
         progress: ((Double) -> Void)?,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.hostPolicy = hostPolicy
        self.onProgress = progress
        self.completion = completion
        super.init()
    }

    func start(request: URLRequest) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: request).resume()
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(min(1.0, max(0.0, p)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 先看有没有「被拒绝跟随的重定向」——那种情况下这个回调拿到的只是 3xx 响应体，
        // 不是 IPA。给出明确错误，别让它落到下面的状态码分支里报成笼统的「HTTP 302」。
        if let bad = rejectedRedirectHost {
            finish(.failure(AppStoreInstallService.InstallError.untrustedHost(bad)))
            return
        }
        // 系统在回调返回后即删除临时文件，必须先搬到稳定位置
        let keep = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipa-\(UUID().uuidString).part")
        do {
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.moveItem(at: location, to: keep)
        } catch {
            finish(.failure(error))
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finish(.failure(AppStoreInstallService.InstallError
                .requestFailed("下载 HTTP \(http.statusCode)")))
            return
        }
        finish(.success(keep))
    }

    /// v0.3.571：AppleID 通道要求下载（含重定向）落在 Apple 自有域。
    ///
    /// `hostPolicy == nil` 时**原样放行**（爱思等非 Apple 源行为不变）。
    /// 非 nil 时：目标必须仍是 https 且通过白名单，否则**拒绝跟随**（`completionHandler(nil)`）——
    /// URLSession 会把 3xx 当最终响应交给 `didFinishDownloadingTo`，那里据此报明确错误。
    /// 这样「初始 URL 是 Apple 域、但被 302 引到第三方」这条绕过也被堵住。
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let hostPolicy else {
            completionHandler(request)
            return
        }
        guard request.url?.scheme?.lowercased() == "https",
              let host = request.url?.host?.lowercased(), hostPolicy(host) else {
            rejectedRedirectHost = request.url?.host ?? "?"
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
