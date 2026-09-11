import Foundation
import UIKit

/// v0.3.297：AppStore 商店 —— 安装服务（全新独立实现，不复用 IPAInstallService / ApplePackage）
///
/// 职责：把「某个 App」解析成一个 manifest plist 地址，然后交给 iOS 系统的
/// itms-services 通道安装（与爱思助手手机端完全同一条系统调用）。
///
/// 解析顺序：
///   1) 源的 `plistURLTemplate`（模板直接拼出 plist 地址）
///   2) 源的 `infoURLTemplate`（请求接口，按 `plistFieldPath` 从 JSON 取 plist 地址）
/// 安装动作：`itms-services://?action=download-manifest&url=<plist>`
enum AppStoreInstallService {

    enum InstallError: Error, LocalizedError {
        case noSource
        case badTemplate
        case requestFailed(String)
        case plistNotFound
        case cannotOpen
        /// v0.3.300：加密包缺少 `SC_Info/*.sinf`，installd 无法解密安装
        case missingSINF(bundleId: String?)

        var errorDescription: String? {
            switch self {
            case .badTemplate: return "源模板拼出的地址无效"
            case .requestFailed(let m): return "源接口请求失败：\(m)"
            case .plistNotFound: return "源返回里没有找到 plist 地址"
            case .cannotOpen: return "无法打开安装链接"
            case .missingSINF(let bid):
                let who = bid.map { "（\($0)）" } ?? ""
                return "该 IPA\(who) 是加密包，但缺少 SC_Info/*.sinf，installd 无法解密安装。"
                     + "App Store 原始包需要由安装它的同一 Apple ID 在本机下载，才会带可用 sinf。"
            }
        }
    }

    static func downloadIPA(urlString: String,
                            suggestedName: String,
                            progress: ((Double) -> Void)? = nil,
                            onLog: ((String) -> Void)? = nil) async throws -> URL {
        guard let url = URL(string: urlString) else { throw InstallError.badTemplate }
        onLog?("[下载] 开始：\(urlString)")
        let dir = try downloadDirectory()
        let safe = suggestedName.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appendingPathComponent(safe.hasSuffix(".ipa") ? safe : safe + ".ipa")
        try? FileManager.default.removeItem(at: dest)

        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            IPAFileDownloader(progress: progress, completion: { result in
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
    static func installLocalIPA(_ ipaPath: String,
                                allowDowngrade: Bool = false,
                                progress: ((Double) -> Void)? = nil,
                                onLog: ((String) -> Void)? = nil) async throws {
        let svc = IPAInstallService.shared
        let ins = IPAPackageInspector.inspect(ipaPath: ipaPath)

        if let ins {
            onLog?("[检测] \(ins.bundleIdentifier ?? "-") \(ins.bundleVersion ?? "-") · \(ins.summary)")
        } else {
            onLog?("[检测] 无法读取包信息，按已签名包继续")
        }

        if ins?.isEncrypted == true {
            // 加密包 → ApplicationSINF 通道
            guard let sinf = IPAPackageInspector.extractSINF(ipaPath: ipaPath) else {
                throw InstallError.missingSINF(bundleId: ins?.bundleIdentifier)
            }
            let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: ipaPath)
            onLog?("[安装] 加密包：携带 ApplicationSINF（\(sinf.count) 字节）"
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

        // 明文包 → 常规安装
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
    private var session: URLSession?
    private var finished = false

    init(progress: ((Double) -> Void)?,
         completion: @escaping (Result<URL, Error>) -> Void) {
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

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
