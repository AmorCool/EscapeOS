//
//  SignedStoreAuthenticator.swift
//  移植来源：CloudOfEquality/Asspp（提交 595fdbf / 01eda33 / 01037b0）
//  适配：EscapeOS —— 去掉 `import ApplePackage`（本项目 vendor 源码同 target 编译）、
//        日志改走 LoginLogger、账号类型改 AppStoreAccount（非可选 init）。
//
//  作用：**不依赖任何 anisette 服务器**，用本地 Unicorn 解释执行 Apple 的
//  CommerceKit/CoreFP（`SAPAssets/`），对登录请求体做 SAP 签名放
//  `X-Apple-ActionSignature`，从而绕开 Apple 认证边缘对第三方客户端的 503/404 软拒绝。
//
import Foundation

/// 一次登录使用一套独立的 transport + signer；凭据只发往已验证的 Apple 域名。
actor SignedStoreAuthenticator {

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let session: URLSession
    private var cookies: [Cookie] = []
    private let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    /// - Parameters:
    ///   - guid: 12 位十六进制设备标识（与下载链路用的 deviceIdentifier 必须一致）
    ///   - cookies: 轮换（rotate）时带上旧 cookie，避免每次都要验证码
    func authenticate(email: String, password: String, code: String,
                      guid: String, cookies: [Cookie]) async throws -> AppStoreAccount {
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        let normalizedCode = code.filter { !$0.isWhitespace }
        self.cookies = cookies

        let bagURL = URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(guid)")!
        let (bagData, bagResponse) = try await send(URLRequest(url: bagURL))
        guard bagResponse.statusCode == 200, let bag = StoreAuthenticationProtocol.plist(bagData) else {
            throw StoreAuthenticationError.serviceResponse(bagResponse.statusCode)
        }
        let nested = bag["urlBag"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { bag[key] ?? nested[key] }
        let endpoint = try StoreAuthenticationProtocol.authenticationURL(
            StoreAuthenticationProtocol.string(value("authenticateAccount")))
        guard StoreAuthenticationProtocol.string(value("sign-sap-version")) == "200",
              let certificateURL = publicSAPURL(value("sign-sap-setup-cert"), host: "s.mzstatic.com"),
              let setupURL = publicSAPURL(value("sign-sap-setup"), host: "fpinit.itunes.apple.com"),
              let assets = SAPAssetsLocator.url,
              guid.count == 12
        else {
            LoginLogger.shared.log("[SAP] SAP 资产未找到：\(SAPAssetsLocator.describe())",
                                   category: .appStore)
            throw StoreAuthenticationError.invalidConfiguration
        }
        LoginLogger.shared.log("[SAP] 资产目录 \(assets.path)", category: .appStore)

        let hardware = stride(from: 0, to: 12, by: 2).compactMap { offset -> UInt8? in
            let start = guid.index(guid.startIndex, offsetBy: offset)
            return UInt8(guid[start ..< guid.index(start, offsetBy: 2)], radix: 16)
        }
        guard hardware.count == 6 else { throw StoreAuthenticationError.invalidConfiguration }
        let signer = try SAPContext(assetsURL: assets, hardwareID: Data(hardware))
        let assetNotes = SAPContext.assetNotes()
        if !assetNotes.isEmpty {
            LoginLogger.shared.log("[SAP] 资产 \(assetNotes)", category: .appStore)
        }

        // ① 取 SAP setup 证书 → 交给本地解释器交换
        let (certificateData, certificateResponse) = try await send(URLRequest(url: certificateURL))
        guard certificateResponse.statusCode == 200,
              let certificate = StoreAuthenticationProtocol.plist(certificateData)?["sign-sap-setup-cert"] as? Data
        else { throw StoreAuthenticationError.serviceResponse(certificateResponse.statusCode) }
        let exchange = try signer.exchangeData(certificate, version: 200)
        var setup = URLRequest(url: setupURL)
        setup.httpMethod = "POST"
        setup.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        setup.httpBody = try PropertyListSerialization.data(
            fromPropertyList: ["sign-sap-setup-buffer": exchange], format: .xml, options: 0)
        let (setupData, setupResponse) = try await send(setup)
        guard setupResponse.statusCode == 200,
              let reply = StoreAuthenticationProtocol.plist(setupData)?["sign-sap-setup-buffer"] as? Data
        else { throw StoreAuthenticationError.serviceResponse(setupResponse.statusCode) }
        _ = try signer.exchangeData(reply, version: 200)
        guard signer.complete else { throw StoreAuthenticationError.invalidConfiguration }

        // ② 正式登录（-5000 是协议挑战，换一次 body 重来）
        var url = endpoint
        var protocolAttempt = 1
        var redirects = 0
        var storefront = ""
        var pod: String?
        var body = try StoreAuthenticationProtocol.body(email: email, password: password,
                                                       code: normalizedCode, guid: guid,
                                                       attempt: protocolAttempt)
        // v0.3.355：边缘按 Content-Type 路由（见 StoreAuthenticationProtocol 注释）。
        // 被边缘拒（拿不到 plist）时换一种 Content-Type 把同一份 body 再打一次，
        // 好把「请求形状被拒」和「真的被 Apple 拒」区分开 —— 这一点只有真机能定案。
        var contentType = StoreAuthenticationProtocol.primaryContentType
        var triedAlternateContentType = false
        var triedTrailingSlash = false
        while protocolAttempt <= 2, redirects <= 3 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            let (data, response) = try await sendAuthentication(request, signer: signer)
            if let v = response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front") { storefront = v }
            if let v = response.value(forHTTPHeaderField: "pod") { pod = v }
            if (300 ... 399).contains(response.statusCode) {
                // A 3xx without Location is not a usable redirect; do not guess its cause or replay credentials.
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let next = URL(string: location, relativeTo: url)?.absoluteURL
                else { throw StoreAuthenticationError.missingRedirect(response.statusCode) }
                guard redirects < 3, next != url else { throw StoreAuthenticationError.tooManyAttempts }
                url = try StoreAuthenticationProtocol.authenticationURL(next.absoluteString)
                redirects += 1
                continue
            }
            guard let plist = StoreAuthenticationProtocol.plist(data) else {
                if response.statusCode == 429 {
                    throw StoreAuthenticationError.rateLimited(retryAfter: StoreAuthenticationProtocol.retryAfter(
                        response.value(forHTTPHeaderField: "Retry-After")))
                }
                if !triedAlternateContentType || !triedTrailingSlash {
                    let switchingContentType = !triedAlternateContentType
                    if switchingContentType {
                        triedAlternateContentType = true
                        contentType = StoreAuthenticationProtocol.alternateContentType
                    } else {
                        // 两条 Content-Type 都被前置拒 → 试参考客户端的尾斜杠端点形态。
                        triedTrailingSlash = true
                        contentType = StoreAuthenticationProtocol.primaryContentType
                        if let variant = StoreAuthenticationProtocol.trailingSlashVariant(endpoint) {
                            url = variant
                        }
                    }
                    protocolAttempt = 1
                    redirects = 0
                    if switchingContentType { url = endpoint }
                    body = try StoreAuthenticationProtocol.body(email: email, password: password,
                                                               code: normalizedCode, guid: guid,
                                                               attempt: protocolAttempt)
                    LoginLogger.shared.log("[SAP] 认证入口 HTTP \(response.statusCode)（\(data.count) 字节，无 plist）"
                        + " → 换 \(switchingContentType ? "Content-Type=\(contentType)" : "端点=\(url.path)") 重打一次",
                        category: .appStore)
                    continue
                }
                throw StoreAuthenticationError.unstructuredResponse(response.statusCode, empty: data.isEmpty)
            }
            if protocolAttempt == 1, StoreAuthenticationProtocol.string(plist["failureType"]) == "-5000" {
                protocolAttempt += 1
                body = try StoreAuthenticationProtocol.body(email: email, password: password,
                                                           code: normalizedCode, guid: guid,
                                                           attempt: protocolAttempt)
                continue
            }
            if let error = StoreAuthenticationProtocol.rejection(plist, code: normalizedCode) { throw error }
            guard response.statusCode == 200,
                  let info = plist["accountInfo"] as? [String: Any],
                  let address = info["address"] as? [String: Any],
                  let token = plist["passwordToken"] as? String, !token.isEmpty,
                  !StoreAuthenticationProtocol.string(plist["dsPersonId"]).isEmpty
            else { throw StoreAuthenticationError.serviceResponse(response.statusCode) }

            let store = StoreAuthenticationProtocol.storeIdentifier(storefront)
            guard !store.isEmpty else {
                LoginLogger.shared.log("[SAP] 未取到 X-Set-Apple-Store-Front", category: .appStore)
                throw StoreAuthenticationError.invalidConfiguration
            }
            return AppStoreAccount(
                email: email,
                password: password,
                appleId: (info["appleId"] as? String) ?? email,
                store: store,
                firstName: (address["firstName"] as? String) ?? "",
                lastName: (address["lastName"] as? String) ?? "",
                passwordToken: token,
                directoryServicesIdentifier: StoreAuthenticationProtocol.string(plist["dsPersonId"]),
                cookie: self.cookies,
                pod: pod,
                fullStoreFront: storefront,
                // v0.3.354：记下这份会话是在哪个机器身份下签发的；换身份后不能再带它的 Cookie 登录。
                deviceGuid: guid)
        }
        throw StoreAuthenticationError.tooManyAttempts
    }

    // MARK: - 网络

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // 与上游 Asspp 一致：客户端保真度（缺它更容易被边缘软拒绝）
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "),
                         forHTTPHeaderField: "Accept-Language")
        // v0.3.356：参考客户端（AssppPro 4.2.5）的登录请求带这条 Accept，我们此前没有。
        // 它影响 Apple 前置的路由（PC 实测带不带它返回的状态码不同）。
        if request.url?.path.hasSuffix("/authenticate") == true
            || request.url?.path.hasSuffix("/authenticate/") == true {
            request.setValue(StoreAuthenticationProtocol.storeClientAccept, forHTTPHeaderField: "Accept")
        }
        request.httpShouldHandleCookies = false
        if let url = request.url {
            for (name, value) in cookies.buildCookieHeader(url) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw StoreAuthenticationError.serviceResponse(0)
        }
        let received = HTTPClientCookie.parseResponse(response.allHeaderFields, for: url)
        cookies.mergeCookies(received)
        // Log only shape/status, never body, credentials, signatures, cookie values or redirect queries.
        let location = response.value(forHTTPHeaderField: "Location")
        let targetHost = location.flatMap { URL(string: $0, relativeTo: url)?.host } ?? "none"
        LoginLogger.shared.log("[SAP] \(request.url?.host ?? "?") → HTTP \(response.statusCode)，\(data.count) 字节；LocationHost=\(targetHost)；Set-Cookie=\(received.count)", category: .appStore)
        return (data, response)
    }

    /// 每次重试都**用同一份 body + 新签名**（与 ipatool 一致）。
    ///
    /// v0.3.353：重试条件与次数都对齐 ipatool —— **204 / 404 / 5xx / 3xx 无 Location**，
    /// 最多 3 次，延迟 250ms × 第几次。`Retry-After` 存在时按 429 语义交给上层，不重发。
    private func sendAuthentication(_ request: URLRequest,
                                    signer: SAPContext) async throws -> (Data, HTTPURLResponse) {
        let maxAttempts = 3
        for attempt in 1 ... maxAttempts {
            var signedRequest = request
            signedRequest.setValue(try signer.sign(request.httpBody ?? Data()).base64EncodedString(),
                                   forHTTPHeaderField: "X-Apple-ActionSignature")
            let result = try await send(signedRequest)
            let status = result.1.statusCode
            let location = result.1.value(forHTTPHeaderField: "Location")
            let hasRedirect = !(location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let shouldRetry = attempt < maxAttempts
                && result.1.value(forHTTPHeaderField: "Retry-After") == nil
                && StoreAuthenticationProtocol.retryable(status: status, hasRedirect: hasRedirect)
            if !shouldRetry { return result }
            LoginLogger.shared.log("[SAP] 认证请求 HTTP \(status)（第 \(attempt) 次，重发同一 body + 新签名）",
                                   category: .appStore)
            try await Task.sleep(for: StoreAuthenticationProtocol.retryDelay(attempt: attempt))
        }
        throw StoreAuthenticationError.tooManyAttempts
    }

    /// 只接受 https + 指定 host + 443 + 无 userinfo/fragment 的 SAP 端点
    private func publicSAPURL(_ value: Any?, host: String) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme == "https", url.host?.lowercased() == host,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

}
