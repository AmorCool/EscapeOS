//
//  StoreDownloadEndpoint+Fetch.swift
//  ApplePackage
//
//  Created on 2026/6/12. (Ported from ApplePackage 1.2.7 to the shim environment)
//

import Foundation

extension StoreDownloadEndpoint {
    /// 完整取下载信息：volumeStore 默认端点 → 需要回退时改走 redownload 端点。
    ///
    /// 回退判定对齐 Asspp dev `65be5b04`（fix: recover empty store downloads）：
    /// 不只看 failureType 5002 —— Apple 还会**静默返回空包**（什么错误字段都没有、
    /// songList 缺失或为空），这时换个端点就能取到。老实现只认 5002，于是
    /// 「An unknown error has occurred / 空包」两种都直接失败。
    static func fetchProductWithFallback(
        client: HTTPClient,
        account: inout AppStoreAccount,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String,
        resolveVersion: (() async throws -> String)? = nil
    ) async throws -> [String: Any] {
        var dict = try await StoreDownloadEndpoint.volumeStore.fetchProduct(
            client: client,
            account: &account,
            app: app,
            deviceIdentifier: deviceIdentifier,
            externalVersionID: externalVersionID
        )

        if let reason = fallbackReason(dict) {
            storeLog("volumeStore 需要回退（\(reason)）→ redownload；\(summary(dict))")
            // v0.3.329：未固定版本号时先解析出当前版本 —— 未固定版本的 redownload
            // 可能返回 tvOS 包（Asspp 65be5b04 同款）
            var version = externalVersionID
            if version.isEmpty, let resolveVersion {
                do {
                    version = try await resolveVersion()
                    storeLog("目录解析到当前版本 \(version)")
                } catch {
                    storeLog("目录版本解析失败：\(error.localizedDescription)")
                }
            }
            do {
                dict = try await StoreDownloadEndpoint.redownload.fetchProduct(
                    client: client,
                    account: &account,
                    app: app,
                    deviceIdentifier: deviceIdentifier,
                    externalVersionID: version
                )
                storeLog("redownload 返回；\(summary(dict))")
            } catch {
                // v0.3.338：回退也失败（redownload 常见 HTTP 500 空 body）时，
                // **本质仍然是「Apple 没有给包」**，必须把原始的空包结论抛给上层。
                // 否则上层的「空包 → 获取许可 → 重试」分支永远不会被触发
                // （337 就是这个缺陷：这里抛的是 500，不是 emptyPackage）。
                storeLog("redownload 失败：\(error.localizedDescription)")
                if fallbackReason(dict) != nil { throw ApplePackageError.emptyPackage }
                throw error
            }
        }

        return dict
    }

    /// 是否需要换端点重取（对齐 Asspp dev 的 fallbackReason）
    static func fallbackReason(_ response: [String: Any]) -> String? {
        if response["failureType"] as? String == retryableFailureType {
            return "failure-5002"
        }
        // 有明确的业务错误 → 是真实拒绝，不要换端点重试
        guard (response["failureType"] as? String ?? "").isEmpty,
              (response["customerMessage"] as? String ?? "").isEmpty,
              response["dialog"] == nil, response["action"] == nil
        else { return nil }
        if let status = response["status"] as? Int, status != 0 { return nil }
        if let status = response["status"] as? String, !status.isEmpty, status != "0" { return nil }
        if let items = response["songList"] as? [Any] {
            return items.isEmpty ? "empty-songList" : nil
        }
        return response["songList"] == nil ? "missing-songList" : nil
    }

    /// 结构化摘要 —— 只报字段形态与数字码，便于定位又不泄露内容
    static func summary(_ response: [String: Any]) -> String {
        let failure = response["failureType"] as? String ?? ""
        let message = response["customerMessage"] as? String ?? ""
        let items: String
        if let list = response["songList"] as? [Any] {
            items = "\(list.count)"
        } else {
            items = response["songList"] == nil ? "missing" : "invalid"
        }
        let status: String
        if let value = response["status"] as? Int { status = "\(value)" }
        else if let value = response["status"] as? String, !value.isEmpty { status = value }
        else { status = "none" }
        let shown = message.count <= 160 ? message : String(message.prefix(160)) + "…"
        return "songList=\(items) failure=\(failure.isEmpty ? "none" : failure) "
            + "status=\(status) customerMessage=\(message.isEmpty ? "none" : shown) "
            + "dialog=\(response["dialog"] != nil) action=\(response["action"] != nil)"
    }

    /// 对单个端点发起 product 请求，处理 pod 重定向，解析返回 plist。
    func fetchProduct(
        client: HTTPClient,
        account: inout AppStoreAccount,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String
    ) async throws -> [String: Any] {
        var currentURL = try url(pod: account.pod, deviceIdentifier: deviceIdentifier)
        var redirectAttempt = 0
        var finalResponse: HTTPClient.Response?
        let maxRedirects = 3

        while redirectAttempt <= maxRedirects {
            let request = try makeRequest(
                account: account,
                app: app,
                url: currentURL,
                deviceIdentifier: deviceIdentifier,
                externalVersionID: externalVersionID
            )
            let response = try await client.execute(request: request).get()
            defer { finalResponse = response }

            account.cookie.mergeCookies(response.cookies)

            // v0.3.334：按 Asspp 的做法接受全部 3xx（301/302/303/307/308），
            // 并把 4 跳上限对齐 —— 原来只认 302，301 会直接当失败。
            if (300 ... 399).contains(response.status.code) {
                guard let location = response.headers.first(name: "location"),
                      let next = URL(string: location, relativeTo: currentURL)?.absoluteURL
                else {
                    storeLog("重定向缺少 Location（HTTP \(response.status.code)）")
                    try ensureFailed("failed to retrieve redirect location")
                }
                currentURL = next
                redirectAttempt += 1
                continue
            }
            break
        }

        guard let finalResponse else { try ensureFailed("no response received") }

        // v0.3.336：把 Apple 侧能表明原因的响应头记下来（App 内日志）。
        // 排查「静默空包」时最有用的是 `X-Apple-Request-Store-Front`（Apple 回显它认到的
        // storefront，`<null>` 表示没认到）与 Set-Cookie 数（会话是否被接受）。
        let rsf = finalResponse.headers.first(name: "x-apple-request-store-front") ?? "(无)"
        let podHeader = finalResponse.headers.first(name: "pod") ?? "-"
        let cookieCount = finalResponse.cookies.count
        storeLog("\(self.host)\(path) → HTTP \(finalResponse.status.code) · "
                 + "X-Apple-Request-Store-Front=\(rsf) · pod=\(podHeader) · Set-Cookie=\(cookieCount)")

        guard finalResponse.status == .ok else {
            let code = finalResponse.status.code
            let ct = finalResponse.headers.first(name: "content-type") ?? "(unknown)"
            let bodyData = finalResponse.body?.data ?? Data()
            let snippet = String(data: bodyData.prefix(512), encoding: .utf8) ?? "(非 UTF-8)"
            storeLog("store fetch failed: HTTP \(code) ct=\(ct) body=\(snippet.prefix(200))")
            if (500 ... 599).contains(code) {
                // redownload 端点在「该账号没有此应用的获取记录」时会直接回 5xx 空 body，
                // 不是我们可以重试修复的错。给一句能看懂的话，别把裸 HTTP 码丢给用户。
                try ensureFailed("Apple 下载服务拒绝了本次请求（HTTP \(code)）——该 Apple ID 可能缺少此应用的获取记录")
            }
            try ensureFailed("store request failed with status \(code)")
        }

        guard var body = finalResponse.body,
              let data = body.readData(length: body.readableBytes)
        else {
            try ensureFailed("response body is empty")
        }

        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        guard let dict = plist else { try ensureFailed("invalid plist response") }

        return dict
    }

    private func makeRequest(
        account: AppStoreAccount,
        app: Software,
        url: URL,
        deviceIdentifier: String,
        externalVersionID: String
    ) throws -> HTTPClient.Request {
        var payload: [String: Any] = [
            "creditDisplay": "",
            "guid": deviceIdentifier,
            "salableAdamId": app.id,
            // v0.3.334：回到 `"0"`。上游两个可用的实现都发 "0"
            // （ipatool PR #500：Apple 对热门应用给 volumeStore 加了校验，补
            //   serialNumber 且**用 "0" 就能过**；Asspp StoreDownloadProtocol.payload 同款 "0"）。
            // 我们 v0.3.301 曾改成 `Configuration.deviceSerialNumber`（本机真序列号），
            // 理由是"sinf 要绑本机证书"——但那时没有任何可用的 Apple ID 登录，整条链路
            // 都是盲写的。真机实测（v0.3.331 日志）：带真序列号时 volumeStore 回空包、
            // redownload 回 HTTP 500，链路走不下去。
            "serialNumber": "0",
        ]

        if !externalVersionID.isEmpty {
            payload[externalVersionIDKey] = externalVersionID
        }

        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var headers: [(String, String)] = [
            ("Content-Type", "application/x-apple-plist"),
            ("User-Agent", Configuration.userAgent),
            // v0.3.334：Asspp 的下载请求带 Accept-Language，补上（客户端保真度）
            ("Accept-Language", Locale.preferredLanguages.prefix(3).joined(separator: ", ")),
            ("iCloud-DSID", account.directoryServicesIdentifier),
            ("X-Dsid", account.directoryServicesIdentifier),
        ]
        // v0.3.336：带上 storefront（与购买同款写法）。实测它不改变 Apple 的给包结果，
        // 但能让响应头 `X-Apple-Request-Store-Front` 回显真实值 —— 排查空包时这行是关键证据
        // （不回显 `<null>` 只能说明「请求没声明区域」，看不出账号到底认的哪个区）。
        if !account.store.isEmpty {
            headers.append(("X-Apple-Store-Front", "\(account.store)-1"))
        }

        for item in account.cookie.buildCookieHeader(url) {
            headers.append(item)
        }

        return try HTTPClient.Request(
            url: url,
            method: .POST,
            headers: HTTPHeaders(headers),
            body: .data(data)
        )
    }
}
