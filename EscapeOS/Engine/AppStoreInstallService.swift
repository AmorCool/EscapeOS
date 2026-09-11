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
            case .noSource: return "没有可用的分发源，请先在「分发源管理」里添加并启用"
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

    // MARK: - 解析 plist 地址

    /// 从源解析出该 App 的 manifest plist 地址
    static func resolvePlistURL(item: AppStoreItem, source: AppStoreSource) async throws -> String {
        // 1) 模板直出
        let tpl = source.plistURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tpl.isEmpty {
            let filled = source.fill(tpl, item: item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filled.isEmpty else { throw InstallError.badTemplate }
            return filled
        }
        // 2) 请求接口再取字段
        let infoTpl = source.infoURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !infoTpl.isEmpty else { throw InstallError.noSource }
        let urlStr = source.fill(infoTpl, item: item)
        guard let url = URL(string: urlStr) else { throw InstallError.badTemplate }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let hdrs = parseHeaders(source.extraHeaders) {
            for (k, v) in hdrs { req.setValue(v, forHTTPHeaderField: k) }
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw InstallError.requestFailed(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.requestFailed("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw InstallError.requestFailed("返回不是 JSON")
        }
        let path = source.plistFieldPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let value = value(at: path, in: obj) else {
            throw InstallError.plistNotFound
        }
        var plist = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plist.isEmpty else { throw InstallError.plistNotFound }
        // 协议相对地址补 https
        if plist.hasPrefix("//") { plist = "https:" + plist }
        return plist
    }

    // MARK: - 安装

    /// 用某个源安装该 App（交给系统 OTA）
    @discardableResult
    static func install(item: AppStoreItem, source: AppStoreSource,
                        onLog: ((String) -> Void)? = nil) async throws -> String {
        onLog?("[源] 使用「\(source.name)」解析 plist…")
        let plist = try await resolvePlistURL(item: item, source: source)
        onLog?("[源] plist = \(plist)")
        let ok = AppStoreInstaller.installViaOTA(manifestURL: plist)
        guard ok else { throw InstallError.cannotOpen }
        onLog?("[安装] 已交给系统 itms-services 安装")
        return plist
    }

    /// 依次尝试所有启用的源，直到有一个能解析成功
    @discardableResult
    static func installUsingAnySource(item: AppStoreItem,
                                      onLog: ((String) -> Void)? = nil) async throws -> (plist: String, source: AppStoreSource) {
        let list = AppStoreSourceStore.shared.enabledSources
        guard !list.isEmpty else { throw InstallError.noSource }
        var lastError: Error = InstallError.noSource
        for s in list {
            do {
                onLog?("[源] 尝试「\(s.name)」…")
                let plist = try await resolvePlistURL(item: item, source: s)
                onLog?("[源] 命中：\(plist)")
                guard AppStoreInstaller.installViaOTA(manifestURL: plist) else {
                    throw InstallError.cannotOpen
                }
                return (plist, s)
            } catch {
                lastError = error
                onLog?("[源] 「\(s.name)」失败：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    // MARK: - v0.3.300：真下载（解析 manifest → 取 IPA → 下载 → RSD 隧道安装）

    /// OTA manifest 里解析出的安装载荷
    struct ManifestPayload {
        var ipaURL: String
        var bundleIdentifier: String?
        var bundleVersion: String?
        var title: String?
        var displayImage: String?
        var fullSizeImage: String?
    }

    /// 下载并解析源的 manifest plist（返回原始字典，含 assets/metadata）
    static func fetchManifest(item: AppStoreItem, source: AppStoreSource) async throws -> [String: Any] {
        let plistURL = try await resolvePlistURL(item: item, source: source)
        guard let url = URL(string: plistURL) else { throw InstallError.badTemplate }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        if let hdrs = parseHeaders(source.extraHeaders) {
            for (k, v) in hdrs { req.setValue(v, forHTTPHeaderField: k) }
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.requestFailed("manifest HTTP \(http.statusCode)")
        }
        // OTA manifest 是 XML plist（也可能是二进制）
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            throw InstallError.requestFailed("manifest 不是有效 plist")
        }
        return dict
    }

    /// 从 OTA manifest 里取出 IPA 直链与元信息
    ///
    /// 结构（iOS 官方 OTA manifest）：
    ///   items[0].assets[]  → { kind: software-package, url: <ipa> }
    ///   items[0].metadata  → { bundle-identifier, bundle-version, title }
    static func payload(from manifest: [String: Any]) -> ManifestPayload? {
        guard let items = manifest["items"] as? [[String: Any]],
              let first = items.first else { return nil }
        var ipa: String?
        var display: String?
        var fullSize: String?
        for case let asset as [String: Any] in (first["assets"] as? [Any] ?? []) {
            let kind = (asset["kind"] as? String) ?? ""
            let url = asset["url"] as? String
            if kind == "software-package" { ipa = url }
            else if kind == "display-image" { display = url }
            else if kind == "full-size-image" { fullSize = url }
        }
        guard let ipaURL = ipa, !ipaURL.isEmpty else { return nil }
        let meta = first["metadata"] as? [String: Any] ?? [:]
        return ManifestPayload(ipaURL: ipaURL,
                               bundleIdentifier: meta["bundle-identifier"] as? String,
                               bundleVersion: meta["bundle-version"] as? String,
                               title: meta["title"] as? String,
                               displayImage: display,
                               fullSizeImage: fullSize)
    }

    /// 用当前启用的源解析出该 App 的安装载荷（依次尝试，返回首个成功的）
    static func resolvePayloadUsingAnySource(item: AppStoreItem,
                                            onLog: ((String) -> Void)? = nil)
        async throws -> (payload: ManifestPayload, source: AppStoreSource) {
        let list = AppStoreSourceStore.shared.enabledSources
        guard !list.isEmpty else { throw InstallError.noSource }
        var lastError: Error = InstallError.noSource
        for s in list {
            do {
                onLog?("[源] 尝试「\(s.name)」…")
                let manifest = try await fetchManifest(item: item, source: s)
                guard let p = payload(from: manifest) else { throw InstallError.plistNotFound }
                onLog?("[源] 命中 IPA：\(p.ipaURL)")
                return (p, s)
            } catch {
                lastError = error
                onLog?("[源] 「\(s.name)」失败：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// 下载 IPA 到 `Documents/AppStoreDownloads/`
    ///
    /// - Returns: 落地文件 URL
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
    static func downloadAndInstall(item: AppStoreItem,
                                   allowDowngrade: Bool = false,
                                   downloadProgress: ((Double) -> Void)? = nil,
                                   installProgress: ((Double) -> Void)? = nil,
                                   onLog: ((String) -> Void)? = nil) async throws -> URL {
        let (p, source) = try await resolvePayloadUsingAnySource(item: item, onLog: onLog)
        onLog?("[链路] 源「\(source.name)」→ \(p.bundleIdentifier ?? "-") \(p.bundleVersion ?? "-")")
        let name = (p.bundleIdentifier ?? item.bundleId ?? item.id) + ".ipa"
        let ipa = try await downloadIPA(urlString: p.ipaURL,
                                       suggestedName: name,
                                       progress: downloadProgress,
                                       onLog: onLog)
        try await installLocalIPA(ipa.path,
                                  allowDowngrade: allowDowngrade,
                                  progress: installProgress,
                                  onLog: onLog)
        return ipa
    }

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
