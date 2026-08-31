//
//  Authenticate.swift
//  ApplePackage
//
//  Created by QAQ on 2023/10/4. (Ported from ApplePackage 1.2.7 to the shim environment;
//  diagnosis-on-plist-failure detail layer (v0.2.151) preserved.)
//
// v0.2.155 起对齐 ApplePackage 1.2.7 主线（PR #84 2026-06-12）：
//   - 通过 Bag.fetchBag() 动态发现并规范化 native auth 端点（带 /fast/ 尾斜杠）
//   - 跟随重定向 301/302/303/307/308（不只是 302）
//   - 提取 `pod` 响应头（Apple 分配的 store pod），给下游 Download 路由用
//   - 循环上限 currentAttempt ≤ 2（**不再**对 204/404 重试 —— 加重 Apple 边缘 IP 限流）
//   - plist 解析失败时：JSON 回退 + HTTP 状态/Content-Type/响应体前 512B 透传诊断
//
// v0.2.157：修复 `auth.itunes.apple.com/auth/v1/native/fast/` 持续返回 403 HTML 的根因 ——
//   该 vendored 移植版在 shim 化时**丢失了 anisette 设备认证头**（X-Apple-I-MD /
//   X-Apple-I-MD-M 等），Apple 边缘对缺头请求直接 403。修复方式：由 Swift 侧通过
//   `anisetteProvider` 闭包在每次尝试时注入**全新** anisette 头（复用已验证可用的
//   AppleAuthenticator 头部集合）。同时新增健壮性分类：403 HTML / 5xx 区分为
//   「可重试（新鲜 anisette 重试一次）/ 永久失败（明确报错，不再盲目重试）」。
//
// v0.2.159：修复 `native/fast/` 返回 **301 Moved Permanently 但无 Location 头** 的裸重定向
//   （日志实证 xcradn@163.com 两次尝试均 301 无 Location → "redirect status 301 but no
//   usable Location header"）。根因：v0.2.158 把 UA 换成 iTunes Windows 后，缺头 403 已消除，
//   但 Apple 边缘对限流/标记/地域的客户端直接返回裸 301（不带 Location，无法跟随）。
//   修复：30x 无 Location 单独分类为「Apple 边缘裸重定向」，首轮用全新 anisette 重试一次，
//   否则明确报错并给出「换网络/切 Anisette 服务器/换时段」的可操作建议。
//
// v0.2.160：修复最新日志 `HTTP 204 No Content` 导致 plist 解析失败。
//   根因：ipatool 最新主线（commit #507 16 天前）明确把 204/404 与 5xx 同列为可重试状态码；
//   Apple 边缘在 auth 握手期间会不定期返回 204/404/301，需要配合递增 attempt + 全新 anisette
//   重试。此前 attempt 固定为 "4" 或 "2"、重试上限仅 2 次、且 anisetteProvider 未强制 refresh，
//   导致 OTP 复用，Apple 以 204 静默拒绝。修复：① attempt 按当前尝试次数递增；② 204/404 与
//   5xx 一样可重试，上限提到 4 次；③ 依赖调用方 `fetchFreshAppStoreAnisetteHeaders` 传
//   refresh=true 确保每次尝试都是全新 OTP。
//

import Foundation

public enum Authenticator {
    private enum LoginResponse {
        case success(AppStoreAccount)
        case codeRequired
        case redirect(URL)
        case retry
        case failure(String)
    }

    public static func authenticate(
        email: String,
        password: String,
        code: String = "",
        cookies: [Cookie] = [],
        anisetteProvider: (() async throws -> [(String, String)])? = nil
    ) async throws -> AppStoreAccount {
        let deviceIdentifier = Configuration.deviceIdentifier

        let bagOutput = try await Bag.fetchBag()
        // v0.2.156：把 Bag 的端点决策写进登录日志 —— 用户在「更多 → 登录日志」
        // 能直接看到 bag.xml 给了什么端点、我们实际用哪个，不再靠猜。
        LoginLogger.shared.log("Bag 解析认证端点: \(bagOutput.authEndpoint.absoluteString)")

        let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)
        defer { _ = client.shutdown() }

        var requestEndpoint: URL = try createInitialRequestEndpoint(
            baseURL: bagOutput.authEndpoint,
            deviceIdentifier: deviceIdentifier
        )
        var cookies: [Cookie] = cookies
        var storeFront = ""
        var pod: String?
        var currentAttempt = 1
        var redirectAttempt = 0
        var lastError: Error?

        // v0.2.160：上限提到 4 次，对齐 ipatool 对 204/404/5xx 的重试策略。
        while currentAttempt <= 4, redirectAttempt <= 3 {
            defer { currentAttempt += 1 }
            do {
                // 每次尝试都用**全新** Anisette 设备认证头：Apple 的 anisette OTP 一次性，
                // 重试必须用新值，否则等价于对同一个被拒请求重复打（v0.2.157 修复 403 的根因）。
                // v0.2.160：每次尝试都期望调用方提供**全新** anisette（OTP 一次性）。
                // `fetchFreshAppStoreAnisetteHeaders` 已改为 `refresh: true` 保证这一点。
                let anisetteHeaders: [(String, String)] = try await anisetteProvider?() ?? []
                let request = try makeRequest(
                    endpoint: requestEndpoint,
                    attempt: currentAttempt,
                    email: email,
                    password: password,
                    code: code,
                    cookies: cookies,
                    deviceIdentifier: deviceIdentifier,
                    anisetteHeaders: anisetteHeaders
                )
                let response = try await client.execute(request: request).get()
                // 用 print 不用 NSLog：iOS 26 SDK 已把 NSLog 的 variadic 形式标为 unavailable
                // （'NSLog' is unavailable: Variadic function is unavailable），但 Swift 的
                // 单参 print 依然受支持。
                print("[EscapeOS][AppStore][Auth] \(requestEndpoint.host ?? "?") status=\(response.status.code)")
                // ===== v0.2.157 健壮性：区分暂态 / 永久失败，避免无意义重试 =====
                let status = response.status
                // 1) Apple 边缘 403 HTML：缺失 anisette 设备头 或 出口 IP 被风控。
                //    首轮若还能刷新 anisette，用全新 anisette 重试一次（排除 anisette 失效）；
                //    否则（已重试过 / 无 anisette 可刷）直接明确报错，不再盲目重试。
                if status == .forbidden,
                   let ct = response.headers.first(name: "content-type"),
                   ct.lowercased().contains("html") {
                    let bodyData = response.body?.data ?? Data()
                    let bodySnippet = String(data: bodyData.prefix(200), encoding: .utf8) ?? "(空体)"
                    LoginLogger.shared.log("App Store 认证被 Apple 边缘拒绝(403 HTML): \(bodySnippet)")
                    if currentAttempt < 4, anisetteProvider != nil {
                        LoginLogger.shared.log("… 用全新 Anisette 重试（attempt=\(currentAttempt)/4）")
                        continue
                    }
                    try ensureFailed(
                        "iTunes 认证被 Apple 拒绝（HTTP 403，返回 HTML 而非 plist）。\n" +
                        "常见原因：① 请求缺少 Anisette 设备认证头；② 本机出口 IP 被 Apple 风控；③ 该 Apple ID 触发了额外网页验证。\n" +
                        "建议：更换网络/代理、到「更多 → 设置 → Anisette 服务器」切换并重连，或确认 Apple ID 未开启强风控验证。"
                    )
                }
                // 2) 服务端 5xx / Apple 边缘 204/404：ipatool 最新主线把这些状态码列为
                //    可重试（Apple auth 握手期间会不定期返回空响应或 404，需配合新 OTP
                //    与递增 attempt 再试）。上限内继续循环，不直接报错。
                if (500...599).contains(status.code) || status.code == 204 || status.code == 404 {
                    LoginLogger.shared.log("App Store 认证 Apple 边缘返回 \(status.code)（ipatool 可重试状态），attempt=\(currentAttempt)/4")
                    if currentAttempt < 4 { continue }
                    try ensureFailed("iTunes 认证服务端错误（HTTP \(status.code)），已重试 4 次仍未成功，请稍后重试。")
                }
                // 3) Apple 边缘 30x 但无 Location：裸重定向（IP 信誉 / 风控 / 地域墙）。
                //    `native/fast/` 在客户端被限流/标记时，Apple 边缘会返回「301 Moved
                //    Permanently」却不带 Location 头（裸重定向），无法跟随。这是 v0.2.159
                //    修复的阻塞项（日志实证：2 次尝试均 301 无 Location，认证失败）。
                //    首轮用全新 anisette 重试一次（设备标识变化可能改变边缘决策）；
                //    否则明确报错，给出可操作建议，避免无意义重试。
                if (300...399).contains(status.code),
                   response.headers.first(name: "location") == nil {
                    let bodyData = response.body?.data ?? Data()
                    let bodySnippet = String(data: bodyData.prefix(200), encoding: .utf8) ?? "(空体)"
                    LoginLogger.shared.log("App Store 认证 Apple 边缘返回 \(status.code) 裸重定向（无 Location 头，疑似 IP 信誉/风控）：\(bodySnippet)")
                    if currentAttempt < 4, anisetteProvider != nil {
                        LoginLogger.shared.log("… 用全新 Anisette 重试（attempt=\(currentAttempt)/4，设备标识变化可能改变边缘决策）")
                        continue
                    }
                    try ensureFailed(
                        "iTunes 认证被 Apple 边缘裸重定向拒绝（HTTP \(status.code)，无 Location 头，无法跟随）。\n" +
                        "常见原因：① 本机出口 IP 被 Apple 风控/限流；② 地域/网络环境触发重定向墙；③ Anisette 设备标识被标记。\n" +
                        "建议：更换网络/代理、到「更多 → 设置 → Anisette 服务器」切换并重连后重试，或稍后更换时段再试。"
                    )
                }
                let result = try parseResponse(
                    response,
                    email: email,
                    password: password,
                    code: code,
                    cookies: &cookies,
                    storeFront: &storeFront,
                    pod: &pod
                )
                switch result {
                case let .success(account):
                    return account
                case let .redirect(uRL):
                    requestEndpoint = uRL
                    currentAttempt -= 1 // allow one more attempt when redirect
                    redirectAttempt += 1
                    continue
                case .codeRequired:
                    currentAttempt += 65535 // stop attempts
                    try ensureFailed(
                        "Authentication requires verification code\n" +
                        "If no verification code prompted, try logging in at https://account.apple.com " +
                        "to trigger the alert and fill the code in the 2FA Code here."
                    )
                case .retry:
                    continue
                case let .failure(string):
                    try ensureFailed("authentication failed: \(string)")
                }
            } catch {
                lastError = error
            }
        }

        if let lastError = lastError { throw lastError }
        try ensureFailed("authentication failed for an unknown reason")
    }

    public static func rotatePasswordToken(for account: inout AppStoreAccount) async throws {
        let newAccount = try await authenticate(
            email: account.email,
            password: account.password,
            code: "",
            cookies: account.cookie
        )
        account = newAccount
    }

    private static func createInitialRequestEndpoint(
        baseURL: URL,
        deviceIdentifier: String
    ) throws -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            try ensureFailed("invalid auth endpoint: \(baseURL)")
        }
        comps.queryItems = [
            URLQueryItem(name: "guid", value: deviceIdentifier),
        ]
        return try comps.url.get()
    }

    private static func makeRequest(
        endpoint: URL,
        attempt: Int,
        email: String,
        password: String,
        code: String,
        cookies: [Cookie],
        deviceIdentifier: String,
        anisetteHeaders: [(String, String)] = []
    ) throws -> HTTPClient.Request {
        // v0.2.160：attempt 按当前尝试次数递增，不再固定为 "4"/"2"。
        // ipatool 主线的 204/404 重试依赖 Apple 把多次尝试视为同一认证会话；
        // 固定 attempt 会让服务端误判为同一请求重复发送，从而触发风控/静默拒绝。
        let attemptValue = max(1, attempt)
        let parameters: [String: String] = [
            "appleId": email,
            "attempt": "\(attemptValue)",
            "guid": deviceIdentifier,
            "password": "\(password)\(code)",
            "rmp": "0",
            "why": "signIn",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: parameters,
            format: .xml,
            options: 0
        )
        var headers: [(String, String)] = [
            ("User-Agent", Configuration.userAgent),
            ("Content-Type", "application/x-apple-plist"),
        ]
        for item in cookies.buildCookieHeader(endpoint) {
            headers.append(item)
        }
        // v0.2.157：追加 anisette 设备认证头（X-Apple-I-* / X-Mme-*）。
        // `native/fast/` 端点强制要求这些头，缺失会被 Apple 边缘直接 403。
        for (name, value) in anisetteHeaders {
            headers.append((name, value))
        }
        return HTTPClient.Request(
            url: endpoint.absoluteString,
            method: .POST,
            headers: HTTPHeaders(headers),
            body: .data(data)
        )
    }

    private static func parseResponse(
        _ response: HTTPClient.Response,
        email: String,
        password: String,
        code: String,
        cookies: inout [Cookie],
        storeFront: inout String,
        pod: inout String?
    ) throws -> LoginResponse {
        cookies.mergeCookies(response.cookies)

        // 提取 Apple 分配的 store front（用于地区路由）。
        let readStoreFrontValue = response.headers["x-set-apple-store-front"]
            .filter { !$0.isEmpty }
            .compactMap { $0.components(separatedBy: "-").first }
            .filter { !$0.isEmpty }
        assert(readStoreFrontValue.count <= 1)
        if let first = readStoreFrontValue.first {
            storeFront = first
        }

        // 提取 store pod（Apple 分配的 pXX 编号）—— 给下游 Download 路由用。
        if let podValue = response.headers.first(name: "pod"), !podValue.isEmpty {
            pod = podValue
        }

        let redirectStatuses: [HTTPResponseStatus] = [
            .movedPermanently, // 301
            .found,            // 302
            .seeOther,         // 303
            .temporaryRedirect,// 307
            .permanentRedirect,// 308
        ]
        if redirectStatuses.contains(response.status) {
            guard let location = response.headers.first(name: "location"),
                  let url = URL(string: location)
            else {
                // v0.2.156：诊断增强 —— 30x 却拿不到 Location 时，把状态码与响应体
                // 摘要一并透传（v0.2.155 真机「failed to retrieve redirect location」
                // 的直接来源；多为 legacy 端点 302 链撞 SAP 签名墙）。
                let bodyData = response.body?.data ?? Data()
                let bodySnippet = String(data: bodyData.prefix(200), encoding: .utf8) ?? "(空体)"
                let locationKeys = response.headers.all.map { $0.name }.joined(separator: ",")
                return .failure(
                    "redirect status \(response.status.code) but no usable Location header " +
                    "(headers: \(locationKeys)); body: \(bodySnippet)"
                )
            }
            return .redirect(url)
        }

        guard var body = response.body,
              let data = body.readData(length: body.readableBytes)
        else {
            return .failure("response body is empty (code: \(response.status.code))")
        }

        // ===== v0.2.151 诊断透传（保留）=====
        // Apple 认证边缘偶尔会返回非 plist（HTML 错误页、JSON 业务错误）。1.2.7 主线
        // 在 parseResponse 里直接 `try PropertyListSerialization...`，失败抛 NSError
        // 但调用方看不到 HTTP 上下文。这里先尝试 JSON 业务错误，否则把 HTTP 状态/
        // Content-Type/响应体前 512B 一起透传进 ensureFailed，让「更多 → 登录日志」
        // 能看到 Apple 的真实返回内容。
        let parsePlist: (Data) throws -> Any = { payload in
            try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
        }
        let listItem: Any
        do {
            listItem = try parsePlist(data)
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = (json["customerMessage"] as? String)
                    ?? (json["failureType"] as? String)
                    ?? (json["errorMessage"] as? String)
                    ?? (json["message"] as? String)
            {
                print("[EscapeOS][AppStore][Auth] Apple 业务错误: \(msg)")
                try ensureFailed("authentication failed: \(msg)")
            }
            let statusCode = response.status.code
            let contentType = response.headers.first(name: "content-type") ?? "(unknown)"
            let bodySnippet = String(data: data.prefix(512), encoding: .utf8)
                ?? "(非 UTF-8 数据，\(data.count) 字节)"
            let detail = """
            iTunes 认证返回的数据不是 plist，无法解析。
            HTTP 状态：\(statusCode)
            Content-Type：\(contentType)
            响应体前 512 字节：
            \(bodySnippet)
            原始解析错误：\(error.localizedDescription)
            """
            print("[EscapeOS][AppStore][Auth] iTunes 认证返回非 plist：\(detail)")
            try ensureFailed(detail)
        }
        let dic = try (listItem as? [String: Any]).get("response is not a dictionary")

        if let failureType = dic["failureType"] as? String,
           failureType.isEmpty,
           code.isEmpty,
           let customerMessage = dic["customerMessage"] as? String,
           customerMessage == "MZFinance.BadLogin.Configurator_message"
        {
            return .codeRequired
        }

        if let failureType = dic["failureType"] as? String, failureType == "5005" {
            return .failure("invalid 2FA code")
        }

        let failureMessage = (dic["dialog"] as? [String: Any])?["explanation"] as? String
            ?? (dic["customerMessage"] as? String)
        let accountInfoDic = try (dic["accountInfo"] as? [String: Any])
            .get(failureMessage ?? "missing accountInfo")
        let addressInfoDic = try (accountInfoDic["address"] as? [String: Any])
            .get(failureMessage ?? "missing address")

        let account = try AppStoreAccount(
            email: email,
            password: password,
            appleId: accountInfoDic["appleId"] as? String,
            store: storeFront,
            firstName: addressInfoDic["firstName"] as? String,
            lastName: addressInfoDic["lastName"] as? String,
            passwordToken: dic["passwordToken"] as? String,
            directoryServicesIdentifier: dic["dsPersonId"] as? String,
            cookie: cookies,
            pod: pod
        )
        return .success(account)
    }
}
