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
        cookies: [Cookie] = []
    ) async throws -> AppStoreAccount {
        let deviceIdentifier = Configuration.deviceIdentifier

        let bagOutput = try await Bag.fetchBag()

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

        while currentAttempt <= 2, redirectAttempt <= 3 {
            defer { currentAttempt += 1 }
            do {
                let request = try makeRequest(
                    endpoint: requestEndpoint,
                    email: email,
                    password: password,
                    code: code,
                    cookies: cookies,
                    deviceIdentifier: deviceIdentifier
                )
                let response = try await client.execute(request: request).get()
                // 用 print 不用 NSLog：iOS 26 SDK 已把 NSLog 的 variadic 形式标为 unavailable
                // （'NSLog' is unavailable: Variadic function is unavailable），但 Swift 的
                // 单参 print 依然受支持。
                print("[EscapeOS][AppStore][Auth] \(requestEndpoint.host ?? "?") status=\(response.status.code)")
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
        email: String,
        password: String,
        code: String,
        cookies: [Cookie],
        deviceIdentifier: String
    ) throws -> HTTPClient.Request {
        let parameters: [String: String] = [
            "appleId": email,
            "attempt": "\(code.isEmpty ? "4" : "2")",
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
        return try HTTPClient.Request(
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
                return .failure("failed to retrieve redirect location")
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
