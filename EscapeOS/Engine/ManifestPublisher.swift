import Foundation
import Security

/// v0.3.383：在线安装（OTA）的**清单生成 + HTTPS 托管**。
///
/// iOS 自 iOS 7.1 起**不收 http 清单**，manifest.plist 必须落在 HTTPS 且证书受设备信任。
/// 本机 HTTP 服务器（局域网 IP / 回环）只用来发 IPA 本体（`software-package`），
/// 清单必须放到公网 HTTPS。托管方式按优先级：
///
/// 1. **用户自定义的 HTTPS 地址**（更多 → 设置 → HTTPS 托管）→ 只用它，不向任何第三方发请求：
///    · 填**完整 URL**（已含路径）→ `PUT` 覆盖它；
///    · 填**基址** → `POST <基址>/sign/install.plist`，响应体若是纯文本 URL 就用它，否则用请求地址本身。
/// 2. **GitHub Token**（下载管理右上角齿轮 → GitHub Token）→ 只用 gist（私有 gist，
///    `raw_url` 是可信 HTTPS）；上传/解析失败才回落匿名候选，并记「gist 失败，回落匿名」。
/// 3. **匿名、免账号**候选（仅在没填上面两项时），逐个上传 + **GET 回读校验**，失败静默换下一个：
///    `litterbox.catbox.moe`（1h）→ `0x0.st` → `tmpfiles.org`（1h）→ `uguu.se`（3h）→ `paste.rs`。
///    临时件排前（清单只活几分钟，且含 bundleId/版本，少留痕）；**单候选超时 8s**。
///    ⚠️ `envs.sh` 已删除：真机回读被劫持到广告域名（`ob.sd559908.js.2gnc.com`），有安全风险。
///
/// **回读校验**：内容必须一致；匿名候选另需 `Content-Type` 属 XML 家族
/// （`application/xml` / `text/xml` / `application/x-plist` / 任意 `*+xml`）。
/// 若所有匿名候选都不是 XML 类型，则用第一个「内容一致」的兜底并**明确记日志**
/// （iOS 是否接受非 XML 清单**未验证**，不把这条当结论）。gist / 自有地址不套这条闸，
/// 但会把回读到的 `Content-Type` 写进日志。
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
    ///
    /// 托管方式优先级：
    /// 1. **用户自定义的 HTTPS 地址**（设置项）→ 只用它，不向任何第三方发请求；
    /// 2. **GitHub Token（下载管理右上角设置）**→ 只用 gist，失败才回落匿名候选；
    /// 3. 匿名候选链。
    static func publish(manifest: Data, completion: @escaping (Result<String, Error>) -> Void) {
        if let endpoint = OnlineInstallConfig.endpoint {
            // 用户自有托管：只用它，不向任何第三方发请求。
            LoginLogger.shared.log("[在线安装] 托管方式：自有 HTTPS 地址（未对外发起任何第三方请求）", category: .appStore)
            do {
                let url = try publishToUserEndpoint(manifest: manifest, endpoint: endpoint)
                completion(.success(url))
            } catch {
                LoginLogger.shared.log("[在线安装] ❌ 自有托管不可用（不回落匿名服务）", category: .appStore)
                completion(.failure(PublishError.endpointUnavailable))
            }
            return
        }

        if let token = OnlineInstallConfig.githubToken {
            LoginLogger.shared.log("[在线安装] 托管方式：gist（token \(OnlineInstallConfig.tokenPrefix ?? "?")…）",
                                   category: .appStore)
            if let url = publishToGist(manifest: manifest, token: token) {
                completion(.success(url))
                return
            }
            LoginLogger.shared.log("[在线安装] gist 失败，回落匿名", category: .appStore)
        } else {
            LoginLogger.shared.log("[在线安装] 托管方式：匿名候选（未配置 GitHub Token）", category: .appStore)
        }

        guard let url = publishToAnonymous(manifest: manifest) else {
            completion(.failure(PublishError.noHosting))
            return
        }
        completion(.success(url))
    }

    // MARK: - GitHub gist 托管

    /// 私有 gist 托管：`POST /gists` → 取 `files["install.plist"].raw_url`。
    ///
    /// 注意：`raw_url` 落在 `gist.githubusercontent.com`，回读的 `Content-Type` 多为
    /// `text/plain`，所以这里**以「内容一致」为准**，Content-Type **只记录、不拒绝**
    /// （用户显式选择了 gist 这条通道）。任何上传/解析失败都返回 nil，由调用方回落匿名候选。
    private static func publishToGist(manifest: Data, token: String) -> String? {
        guard let content = String(data: manifest, encoding: .utf8),
              let endpoint = URL(string: "https://api.github.com/gists"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "description": "EscapeSpace OTA manifest",
                  "public": false,
                  "files": ["install.plist": ["content": content]]
              ]) else {
            LoginLogger.shared.log("[在线安装] gist 请求构造失败", category: .appStore)
            return nil
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = candidateTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard let result = try? perform(request) else {
            LoginLogger.shared.log("[在线安装] gist 网络失败", category: .appStore)
            return nil
        }
        LoginLogger.shared.log("[在线安装] gist POST 状态码=\(result.status)", category: .appStore)

        guard (200...299).contains(result.status),
              let json = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let files = json["files"] as? [String: Any],
              let entry = files["install.plist"] as? [String: Any],
              let raw = entry["raw_url"] as? String,
              raw.lowercased().hasPrefix("https://") else {
            LoginLogger.shared.log("[在线安装] gist 未返回可用 raw_url", category: .appStore)
            return nil
        }
        LoginLogger.shared.log("[在线安装] gist raw_url=\(shortURL(raw))", category: .appStore)

        let outcome = verify(url: raw, expected: manifest, requireXML: false)
        let shownType = outcome.contentType.isEmpty ? "缺失" : outcome.contentType
        LoginLogger.shared.log("[在线安装] gist 回读 Content-Type=\(shownType)"
                               + "（\(outcome.ok ? "内容一致" : (outcome.reason ?? "校验未过"))）",
                               category: .appStore)
        guard outcome.ok else { return nil }
        return raw
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
            request.timeoutInterval = candidateTimeout
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = manifest
            LoginLogger.shared.log("[在线安装] 自有托管：POST 基址 \(shortURL(target.absoluteString))",
                                   category: .appStore)
            let result = try perform(request)
            LoginLogger.shared.log("[在线安装] 自有托管 POST 状态码=\(result.status)", category: .appStore)
            guard (200...299).contains(result.status) else { throw PublishError.endpointUnavailable }
            finalURL = target.absoluteString
        } else {
            request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.timeoutInterval = candidateTimeout
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = manifest
            LoginLogger.shared.log("[在线安装] 自有托管：PUT 完整地址 \(shortURL(url.absoluteString))",
                                   category: .appStore)
            let result = try perform(request)
            LoginLogger.shared.log("[在线安装] 自有托管 PUT 状态码=\(result.status)", category: .appStore)
            guard (200...299).contains(result.status) else { throw PublishError.endpointUnavailable }
            finalURL = url.absoluteString
        }

        // 校验：内容一致即按用户地址使用（Content-Type 只记录，自有地址仍照用）
        let verified = verify(url: finalURL, expected: manifest, requireXML: false)
        let shownType = verified.contentType.isEmpty ? "缺失" : verified.contentType
        LoginLogger.shared.log("[在线安装] 自有托管校验\(verified.ok ? "通过" : "未通过（仍按自有地址使用）")"
                               + "：Content-Type=\(shownType) \(shortURL(finalURL))",
                               category: .appStore)
        return finalURL
    }

    // MARK: - 匿名候选（逐个探测 + 回退）

    /// 单候选超时：一个候选最长只等这么久（实测 litterbox 会拖满 25s，把用户晾住）
    private static let candidateTimeout: TimeInterval = 8

    private static func publishToAnonymous(manifest: Data) -> String? {
        let candidates: [(name: String, upload: (Data) throws -> String)] = [
            // 临时件优先（清单只活几分钟，少留痕）
            ("litterbox.catbox.moe", { try uploadLitterbox(data: $0) }),
            ("0x0.st", { try uploadMultipart(url: "https://0x0.st", data: $0) }),
            ("tmpfiles.org", { try uploadTmpfiles(data: $0) }),
            ("uguu.se", { try uploadUguu(data: $0) }),
            ("paste.rs", { try uploadRaw(url: "https://paste.rs", data: $0) })
            // 已删 envs.sh：真机回读被劫持到广告域名（ob.sd559908.js.2gnc.com），有安全风险
        ]

        // 「内容一致、但 Content-Type 不是 XML」的候选，留作最后兜底
        var contentOnlyFallback: (name: String, url: String, contentType: String)?

        for candidate in candidates {
            LoginLogger.shared.log("[在线安装] 尝试匿名托管：\(candidate.name)", category: .appStore)
            let url: String
            do {
                url = try candidate.upload(manifest)
            } catch {
                LoginLogger.shared.log("[在线安装] \(candidate.name) 上传失败，换下一个（单候选超时 \(Int(candidateTimeout))s）",
                                       category: .appStore)
                continue
            }
            let outcome = verify(url: url, expected: manifest)
            let shownType = outcome.contentType.isEmpty ? "缺失" : outcome.contentType
            LoginLogger.shared.log("[在线安装] \(candidate.name) 回读 Content-Type=\(shownType)"
                                   + "（\(outcome.ok ? "可用" : (outcome.reason ?? "不可用"))）",
                                   category: .appStore)
            if outcome.ok {
                LoginLogger.shared.log("[在线安装] ✓ 匿名托管成功：\(candidate.name) → \(shortURL(url))",
                                       category: .appStore)
                return url
            }
            if outcome.reason == reasonContentType, contentOnlyFallback == nil {
                contentOnlyFallback = (candidate.name, url, shownType)
            }
        }

        // 兜底：所有候选的 Content-Type 都不是 XML 时，用第一个「内容一致」的。
        // ⚠️ **iOS 的 OTA 安装器是否接受非 XML 清单未验证** —— 这里只陈述事实：
        //    内容校验通过、只是 Content-Type 不是 XML，比直接失败更值得一赌。
        if let fallback = contentOnlyFallback {
            LoginLogger.shared.log("[在线安装] ⚠ 无 XML 类型候选可用，兜底使用 \(fallback.name)"
                                   + "（Content-Type=\(fallback.contentType)，内容一致；iOS 是否接受未验证）→ \(shortURL(fallback.url))",
                                   category: .appStore)
            return fallback.url
        }
        LoginLogger.shared.log("[在线安装] ❌ 所有匿名托管候选均不可用", category: .appStore)
        return nil
    }

    /// 通用 `multipart/form-data` POST（0x0.st / tmpfiles.org / uguu.se / litterbox）
    private static func multipartPost(url: String,
                                      fields: [(name: String, value: String)],
                                      fileField: String,
                                      filename: String,
                                      data: Data) throws -> HTTPResult {
        guard let endpoint = URL(string: url) else { throw PublishError.noHosting }
        let boundary = "----EscapeSpace\(UUID().uuidString)"
        var body = Data()
        for field in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".utf8))
            body.append(Data("\(field.value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/xml\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = candidateTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return try perform(request)
    }

    /// `POST` 原始 body，响应体是纯文本 URL（paste.rs）
    private static func uploadRaw(url: String, data: Data) throws -> String {
        guard let endpoint = URL(string: url) else { throw PublishError.noHosting }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = candidateTimeout
        // 用 XML 类型上传，尽量让服务端回读时也标成 XML
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        let result = try perform(request)
        guard (200...299).contains(result.status) else { throw PublishError.noHosting }
        return try extractURL(from: result.body)
    }

    /// `multipart/form-data` 字段 `file`，响应体是纯文本 URL（0x0.st）
    private static func uploadMultipart(url: String, data: Data) throws -> String {
        let result = try multipartPost(url: url, fields: [], fileField: "file",
                                       filename: "install.plist", data: data)
        guard (200...299).contains(result.status) else { throw PublishError.noHosting }
        return try extractURL(from: result.body)
    }

    /// tmpfiles.org（1 小时临时）：字段 `file`，响应 JSON；直链要把 `/dl/` 插进路径
    private static func uploadTmpfiles(data: Data) throws -> String {
        let result = try multipartPost(url: "https://tmpfiles.org/api/v1/upload",
                                       fields: [], fileField: "file",
                                       filename: "install.plist", data: data)
        guard (200...299).contains(result.status) else { throw PublishError.noHosting }
        guard let json = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let raw = payload["url"] as? String, raw.hasPrefix("https://") else {
            throw PublishError.noHosting
        }
        // https://tmpfiles.org/<id>/install.plist → https://tmpfiles.org/dl/<id>/install.plist
        return raw.replacingOccurrences(of: "://tmpfiles.org/", with: "://tmpfiles.org/dl/")
    }

    /// uguu.se（3 小时临时）：字段 `files[]`，响应 JSON
    private static func uploadUguu(data: Data) throws -> String {
        let result = try multipartPost(url: "https://uguu.se/upload.php",
                                       fields: [], fileField: "files[]",
                                       filename: "install.plist", data: data)
        guard (200...299).contains(result.status) else { throw PublishError.noHosting }
        guard let json = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let files = json["files"] as? [[String: Any]],
              let first = files.first,
              let raw = first["url"] as? String, raw.lowercased().hasPrefix("https://") else {
            throw PublishError.noHosting
        }
        return raw
    }

    /// litterbox：`reqtype=fileupload` + `time=1h`（临时 1 小时）
    private static func uploadLitterbox(data: Data) throws -> String {
        let result = try multipartPost(url: "https://litterbox.catbox.moe/resources/internals/api.php",
                                       fields: [("reqtype", "fileupload"), ("time", "1h")],
                                       fileField: "fileToUpload",
                                       filename: "install.plist", data: data)
        guard (200...299).contains(result.status) else { throw PublishError.noHosting }
        return try extractURL(from: result.body)
    }

    // MARK: - 校验 / 网络 / 小工具

    /// 一个 HTTP 响应（header 键统一转小写，便于查 `content-type`）
    private struct HTTPResult {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private struct VerifyOutcome {
        var ok: Bool
        var contentType: String
        var reason: String?
    }

    /// Content-Type 不合格的判定文案（仅用作内部标记，不直接展示给用户）
    private static let reasonContentType = "Content-Type 非 XML"

    /// 立刻 GET 回读，两道关：
    /// ① 内容必须一致（或至少含清单关键字段）；
    /// ② `requireXML == true` 时，**`Content-Type` 必须是 XML 家族** —— 这是真机失败那次
    ///    留下的教训：只比对内容会让 `text/plain` 的候选通过，而 iOS 是把清单当 plist 解析的，
    ///    类型不对就白装（该相关性**未在真机确证**，所以只做「优先换 XML 候选」，
    ///    全部候选都不是 XML 时见 `publishToAnonymous` 的兜底分支）。
    ///    gist / 用户自有地址传 `false`：那是用户显式选的通道，Content-Type 只记录不拒绝。
    private static func verify(url: String, expected: Data, requireXML: Bool = true) -> VerifyOutcome {
        guard let endpoint = URL(string: url) else {
            return VerifyOutcome(ok: false, contentType: "", reason: "地址无效")
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = candidateTimeout
        request.setValue("EscapeSpace/1.0", forHTTPHeaderField: "User-Agent")
        guard let result = try? perform(request), (200...299).contains(result.status) else {
            return VerifyOutcome(ok: false, contentType: "", reason: "回读失败")
        }
        let contentType = result.headers["content-type"] ?? ""

        if result.body != expected {
            guard let text = String(data: result.body, encoding: .utf8),
                  text.contains("software-package"), text.contains("bundle-identifier") else {
                return VerifyOutcome(ok: false, contentType: contentType, reason: "内容不一致")
            }
        }
        if requireXML, !isXMLContentType(contentType) {
            return VerifyOutcome(ok: false, contentType: contentType, reason: reasonContentType)
        }
        return VerifyOutcome(ok: true, contentType: contentType, reason: nil)
    }

    /// 可接受的清单类型：`application/xml` / `text/xml` / `application/x-plist` / 任意 `+xml`
    private static func isXMLContentType(_ raw: String) -> Bool {
        let value = raw.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !value.isEmpty else { return false }
        if value.hasSuffix("+xml") { return true }
        return ["application/xml", "text/xml", "application/x-plist"].contains(value)
    }

    private static func perform(_ request: URLRequest) throws -> HTTPResult {
        var result = HTTPResult(status: -1, headers: [:], body: Data())
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let http = response as? HTTPURLResponse {
                result.status = http.statusCode
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
                result.headers = headers
            }
            result.body = data ?? Data()
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let failure { throw failure }
        return result
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

/// v0.3.383：在线安装配置。
///
/// · **GitHub Token**：只存 **Keychain**（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，
///   不做 iCloud 同步、不落 UserDefaults）；日志最多只记前 8 位。
/// · **HTTPS 托管地址**（可选）：非机密，存 `UserDefaults`（与设置页 `@AppStorage` 同键）。
enum OnlineInstallConfig {

    static let endpointKey = "escape.onlineInstallEndpoint"

    private static let keychainService = "com.ipaside.escapeos.onlineinstall"
    private static let tokenAccount = "githubToken"

    // MARK: - 自有 HTTPS 托管地址

    /// 用户自带的 HTTPS 托管地址；空/未配置时返回 `nil`。
    static var endpoint: String? {
        guard let value = UserDefaults.standard.string(forKey: endpointKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else { return nil }
        return value
    }

    // MARK: - GitHub Token（Keychain）

    /// 已配置的 token；未配置返回 `nil`。
    static var githubToken: String? {
        var query = tokenQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// 保存 token（传 `nil`/空串 = 清除）。
    static func setGitHubToken(_ raw: String?) {
        clearGitHubToken()
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var attributes = tokenQuery()
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clearGitHubToken() {
        SecItemDelete(tokenQuery() as CFDictionary)
    }

    /// 日志用：**只记前 8 位**，其余一律不落日志。
    static var tokenPrefix: String? {
        guard let token = githubToken else { return nil }
        return String(token.prefix(8))
    }

    private static func tokenQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount
        ]
    }
}
