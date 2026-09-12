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
            dict = try await StoreDownloadEndpoint.redownload.fetchProduct(
                client: client,
                account: &account,
                app: app,
                deviceIdentifier: deviceIdentifier,
                externalVersionID: version
            )
            storeLog("redownload 返回；\(summary(dict))")
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

            if response.status == .found {
                guard let location = response.headers.first(name: "location"),
                      let newURL = URL(string: location)
                else {
                    try ensureFailed("failed to retrieve redirect location")
                }
                currentURL = newURL
                redirectAttempt += 1
                continue
            }
            break
        }

        guard let finalResponse else { try ensureFailed("no response received") }

        guard finalResponse.status == .ok else {
            let code = finalResponse.status.code
            let ct = finalResponse.headers.first(name: "content-type") ?? "(unknown)"
            let bodyData = finalResponse.body?.data ?? Data()
            let snippet = String(data: bodyData.prefix(512), encoding: .utf8) ?? "(非 UTF-8)"
            let detail = "store fetch failed: HTTP \(code) ct=\(ct) body=\(snippet.prefix(200))"
            storeLog("\(detail)")
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
            // v0.3.258：对齐上游 ipatool 5f776fe —— 缺 serialNumber 时 Apple 按
            // 无效设备校验，直接回「Your device or computer could not be verified」.
            // v0.3.301：改为可配置 —— 传入本机真实序列号后，Apple 才能关联本机
            // FairPlay 证书，生成可被本机 installd 解密的 sinf。默认仍是 "0"。
            "serialNumber": Configuration.deviceSerialNumber,
        ]

        if !externalVersionID.isEmpty {
            payload[externalVersionIDKey] = externalVersionID
        }

        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var headers: [(String, String)] = [
            ("Content-Type", "application/x-apple-plist"),
            ("User-Agent", Configuration.userAgent),
            ("iCloud-DSID", account.directoryServicesIdentifier),
            ("X-Dsid", account.directoryServicesIdentifier),
        ]

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
