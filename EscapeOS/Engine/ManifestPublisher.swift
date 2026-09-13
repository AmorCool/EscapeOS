import Foundation

/// v0.3.379：在线安装（OTA）的**清单生成 + HTTPS 托管**。
///
/// iOS 自 iOS 7.1 起**不收 http 清单**，manifest.plist 必须落在 HTTPS 且证书受设备信任。
/// 本机 `127.0.0.1` 只用来发 IPA 本体（`software-package`），清单必须放到公网 HTTPS：
///
/// 1. **用户自带的 HTTPS 地址**（设置 → HTTPS 托管）**优先**，且一旦填了就**不再对外发任何请求**：
///    · 填**完整 URL**（已含路径）→ `PUT` 覆盖它；
///    · 填**基址** → `POST <基址>/sign/install.plist`，响应体若是纯文本 URL 就用它，否则用请求地址本身。
/// 2. 没填才走**匿名、免账号**的 paste 候选，逐个上传 + **GET 回读校验**，失败静默换下一个：
///    `litterbox.catbox.moe`（临时 1 小时）→ `0x0.st` → `envs.sh` → `paste.rs`。
///    临时件排第一：清单只活几分钟，且里面含 bundleId/版本，少留痕。
///
/// **IPA 本体一字节都不上传**，这里只上传那份几百字节的 plist。
enum ManifestPublisher {

    /// 清单里 `items[0]` 需要的字段
    struct ManifestInfo {
        var bundleId: String
        var version: String
        var title: String
        /// `software-package` 主地址：本机 `http://127.0.0.1:<port>/package.ipa`
        var packageURL: String
        /// 备选 `software-package`（台账里有远端 https 直链时追加一条）
        var alternatePackageURL: String?
    }

    enum PublishError: Error, LocalizedError {
        case badManifest
        /// 所有托管候选都不可用
        case noHosting
        /// 用户自有托管不可用
        case endpointUnavailable

        var errorDescription: String? {
            switch self {
            case .badManifest: return "清单生成失败"
            case .noHosting: return "无可用托管"
            case .endpointUnavailable: return "托管不可用"
            }
        }
    }

    // MARK: - 生成清单

    /// 生成标准明文 plist（`items[].assets[]` + `items[].metadata`）。
    static func makeManifest(_ info: ManifestInfo) throws -> Data {
        var assets: [[String: Any]] = [
            ["kind": "software-package", "url": info.packageURL]
        ]
        if let alternate = info.alternatePackageURL, !alternate.isEmpty {
            assets.append(["kind": "software-package", "url": alternate])
        }
        let metadata: [String: Any] = [
            "bundle-identifier": info.bundleId,
            "bundle-version": info.version,
            "kind": "software",
            "title": info.title
        ]
        let item: [String: Any] = ["assets": assets, "metadata": metadata]
        let root: [String: Any] = ["items": [item]]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    // MARK: - 发布（阻塞式；调用方已在后台队列）

    /// 发布清单，回调返回可直接 GET 的 HTTPS 地址。全部失败才报错。
    static func publish(manifest: Data, completion: @escaping (Result<String, Error>) -> Void) {
        if let endpoint = OnlineInstallConfig.endpoint {
            // 用户自有托管：只用它，不向任何第三方发请求。
            LoginLogger.shared.log("[在线安装] 使用自有 HTTPS 托管（未对外发起任何第三方请求）", category: .appStore)
            do {
                let url = try publishToUserEndpoint(manifest: manifest, endpoint: endpoint)
                completion(.success(url))
            } catch {
                LoginLogger.shared.log("[在线安装] ❌ 自有托管不可用（不回落匿名服务）", category: .appStore)
                completion(.failure(PublishError.endpointUnavailable))
            }
            return
        }

        guard let url = publishToAnonymous(manifest: manifest) else {
            completion(.failure(PublishError.noHosting))
            return
        }
        completion(.success(url))
    }

    // MARK: - 用户自有托管

    private static func publishToUserEndpoint(manifest: Data, endpoint raw: String) throws -> String {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            LoginLogger.shared.log("[在线安装] 自有托管地址无效（必须是 https://…）", category: .appStore)
            throw PublishError.endpointUnavailable
        }

        let isBase = url.path.isEmpty || url.path == "/"
        var finalURL: String
        var request: URLRequest

        if isBase {
            let target = url.appendingPathComponent("sign/install.plist")
            request = URLRequest(url: target)
            request.httpMethod = "POST"
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = manifest
            LoginLogger.shared.log("[在线安装] 自有托管：POST 基址 \(shortURL(target.absoluteString))",
                                   category: .appStore)
            let (status, _) = try perform(request)
            LoginLogger.shared.log("[在线安装] 自有托管 POST 状态码=\(status)", category: .appStore)
            guard (200...299).contains(status) else { throw PublishError.endpointUnavailable }
            finalURL = target.absoluteString
        } else {
            request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = manifest
            LoginLogger.shared.log("[在线安装] 自有托管：PUT 完整地址 \(shortURL(url.absoluteString))",
                                   category: .appStore)
            let (status, _) = try perform(request)
            LoginLogger.shared.log("[在线安装] 自有托管 PUT 状态码=\(status)", category: .appStore)
            guard (200...299).contains(status) else { throw PublishError.endpointUnavailable }
            finalURL = url.absoluteString
        }

        // 校验：能 GET 回来即视为通过（CDN 可能短暂回旧内容，自有地址仍照用）
        let verified = verify(url: finalURL, expected: manifest)
        LoginLogger.shared.log("[在线安装] 自有托管校验\(verified ? "通过" : "未通过（仍按自有地址使用）")：\(shortURL(finalURL))",
                               category: .appStore)
        return finalURL
    }

    // MARK: - 匿名候选（逐个探测 + 回退）

    private static func publishToAnonymous(manifest: Data) -> String? {
        let candidates: [(name: String, upload: (Data) throws -> String)] = [
            // 临时件优先（清单只活几分钟，少留痕）
            ("litterbox.catbox.moe", { try uploadLitterbox(data: $0) }),
            ("0x0.st", { try uploadMultipart(url: "https://0x0.st", data: $0) }),
            ("envs.sh", { try uploadMultipart(url: "https://envs.sh", data: $0) }),
            ("paste.rs", { try uploadRaw(url: "https://paste.rs", data: $0) })
        ]

        for candidate in candidates {
            LoginLogger.shared.log("[在线安装] 尝试匿名托管：\(candidate.name)", category: .appStore)
            let url: String
            do {
                url = try candidate.upload(manifest)
            } catch {
                LoginLogger.shared.log("[在线安装] \(candidate.name) 上传失败，换下一个", category: .appStore)
                continue
            }
            guard verify(url: url, expected: manifest) else {
                LoginLogger.shared.log("[在线安装] \(candidate.name) 回读校验不通过（\(shortURL(url))），换下一个",
                                       category: .appStore)
                continue
            }
            LoginLogger.shared.log("[在线安装] ✓ 匿名托管成功：\(candidate.name) → \(shortURL(url))",
                                   category: .appStore)
            return url
        }
        LoginLogger.shared.log("[在线安装] ❌ 所有匿名托管候选均不可用", category: .appStore)
        return nil
    }

    /// `POST` 原始 body，响应体是纯文本 URL（paste.rs）
    private static func uploadRaw(url: String, data: Data) throws -> String {
        guard let endpoint = URL(string: url) else { throw PublishError.noHosting }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        let (status, body) = try perform(request)
        guard (200...299).contains(status) else { throw PublishError.noHosting }
        return try extractURL(from: body)
    }

    /// `multipart/form-data` 字段 `file`（0x0.st / envs.sh）
    private static func uploadMultipart(url: String, data: Data) throws -> String {
        guard let endpoint = URL(string: url) else { throw PublishError.noHosting }
        let boundary = "----EscapeSpace\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"install.plist\"\r\n".utf8))
        body.append(Data("Content-Type: application/xml\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let (status, response) = try perform(request)
        guard (200...299).contains(status) else { throw PublishError.noHosting }
        return try extractURL(from: response)
    }

    /// litterbox：`reqtype=fileupload` + `time=1h`（临时 1 小时）
    private static func uploadLitterbox(data: Data) throws -> String {
        guard let endpoint = URL(string: "https://litterbox.catbox.moe/resources/internals/api.php") else {
            throw PublishError.noHosting
        }
        let boundary = "----EscapeSpace\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("reqtype", "fileupload")
        field("time", "1h")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"install.plist\"\r\n".utf8))
        body.append(Data("Content-Type: application/xml\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let (status, response) = try perform(request)
        guard (200...299).contains(status) else { throw PublishError.noHosting }
        return try extractURL(from: response)
    }

    // MARK: - 校验 / 网络 / 小工具

    /// 立刻 GET 回读，确认内容一致（或至少含清单关键字段）。
    private static func verify(url: String, expected: Data) -> Bool {
        guard let endpoint = URL(string: url) else { return false }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 25
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        guard let (status, body) = try? perform(request), (200...299).contains(status) else { return false }
        if body == expected { return true }
        guard let text = String(data: body, encoding: .utf8) else { return false }
        return text.contains("software-package") && text.contains("bundle-identifier")
    }

    @discardableResult
    private static func perform(_ request: URLRequest) throws -> (Int, Data) {
        var status = -1
        var body = Data()
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            body = data ?? Data()
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let failure { throw failure }
        return (status, body)
    }

    /// 响应体里取第一个 `http(s)://…` 形式的 URL
    private static func extractURL(from body: Data) throws -> String {
        guard let text = String(data: body, encoding: .utf8) else { throw PublishError.noHosting }
        for token in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" || $0 == "\"" }) {
            let value = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix("https://") { return value }
        }
        throw PublishError.noHosting
    }

    /// 日志用：**只记 host + 路径前 8 个字符**，不泄露完整地址
    private static func shortURL(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return "<invalid>" }
        let host = parsed.host ?? "?"
        let path = parsed.path.hasPrefix("/") ? String(parsed.path.dropFirst()) : parsed.path
        return "\(host)/\(path.prefix(8))"
    }
}

/// v0.3.379：在线安装的配置。
///
/// 只有一项：**HTTPS 托管地址**（用户可填自己的服务器；留空则用匿名免账号 paste 候选）。
/// 不是账号凭证，存 `UserDefaults`（键与设置页的 `@AppStorage` 一致）。
enum OnlineInstallConfig {

    static let endpointKey = "escape.onlineInstallEndpoint"

    /// 用户自带的 HTTPS 托管地址；空/未配置时返回 `nil`。
    static var endpoint: String? {
        guard let value = UserDefaults.standard.string(forKey: endpointKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else { return nil }
        return value
    }
}
