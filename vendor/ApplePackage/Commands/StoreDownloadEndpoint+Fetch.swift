//
//  StoreDownloadEndpoint+Fetch.swift
//  ApplePackage
//
//  Created on 2026/6/12. (Ported from ApplePackage 1.2.7 to the shim environment)
//

import Foundation

extension StoreDownloadEndpoint {
    /// 完整取下载信息（v0.3.361 起为**有界三段**）：
    ///   ① volumeStore（带调用方给的 `externalVersionID`）；
    ///   ② ① 为空包、调用方没指定版本且给了 `versionCandidates` → 逐个用候选打 volumeStore（最多 6 个，命中即停）；
    ///   ③ 候选也没包 → redownload 兜底。
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
        resolveVersion: (() async throws -> String)? = nil,
        versionCandidates: [String] = []
    ) async throws -> [String: Any] {
        var dict = try await StoreDownloadEndpoint.volumeStore.fetchProduct(
            client: client,
            account: &account,
            app: app,
            deviceIdentifier: deviceIdentifier,
            externalVersionID: externalVersionID
        )

        // v0.3.361：**空包时先用候选 `externalVersionId` 重打 volumeStore，而不是直接退到 redownload。**
        //
        // 真机实测（2026-09-13，同一份新会话，对照 ChatGPT 6448311069 / Via 1639085829）：
        // `volumeStoreDownloadProduct` 返回「HTTP 200 + 空 songList + 无任何错误码」的**唯一**决定性变量
        // 就是 body 里有没有 `externalVersionId` —— 不带 → 空包；带该账号可下的旧 ID
        // （856638501 / 857146407 / 857195392 / 890134149）→ `songList=1`；而**最新的两个**
        // （890363403 / 890707559）仍是空包。重跑 5 次结论稳定，且 Via 不受影响。
        // 出包响应里带回 `softwareVersionExternalIdentifiers`（212 个）——该账号对 ChatGPT
        // 只认前面的那些。也就是说：**空包 = 该账号没有「最新版」的下载记录，但旧版可以下。**
        // 公开情报一致：社区教程就是用 `--external-version-id 856638501` 把 ChatGPT 下下来的。
        if let reason = fallbackReason(dict), externalVersionID.isEmpty, !versionCandidates.isEmpty {
            storeLog("volumeStore 空包（\(reason)）→ 用候选 externalVersionId 重试（最多 6 个）")
            for candidate in versionCandidates.prefix(6) {
                try Task.checkCancellation()
                do {
                    let hit = try await StoreDownloadEndpoint.volumeStore.fetchProduct(
                        client: client,
                        account: &account,
                        app: app,
                        deviceIdentifier: deviceIdentifier,
                        externalVersionID: candidate
                    )
                    if fallbackReason(hit) == nil {
                        // 命中行必须能看出**用的是哪个** externalVersionId
                        storeLog("候选版本命中 externalVersionId=\(candidate)；\(summary(hit))")
                        return hit
                    }
                    storeLog("候选版本仍是空包 externalVersionId=\(candidate)；\(summary(hit))")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    storeLog("候选版本请求失败 externalVersionId=\(candidate)：\(error.localizedDescription)")
                }
            }
            storeLog("候选版本全部为空包 → 退回 redownload")
        }

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
                // v0.3.352：redownload 也是空包 → 两个端点都没给包，这就是「该账号
                // 还没建立这个应用的下载权」。必须把它识别成 emptyPackage 抛给上层，
                // 否则上层的「空包 → 获取许可 → 重试」分支永远不触发
                // （v0.3.351 就是漏了这里：空包走到 redownload 5xx 后抛的是裸 HTTP 错误，
                //  上层 catch 不匹配 → 直接失败，真机日志里 ChatGPT 就是这样挂的）。
                if let reason = fallbackReason(dict) {
                    storeLog("redownload 同样没有包（\(reason)）→ 判定为缺少下载授权")
                    throw ApplePackageError.emptyPackage
                }
            } catch let error as ApplePackageError {
                // 认证失效 / 缺许可必须原样上抛，只有「没拿到包」才归一成 emptyPackage。
                storeLog("redownload 失败：\(error.localizedDescription)")
                throw error
            } catch {
                storeLog("redownload 失败：\(error.localizedDescription)")
                if isPackageUnavailable(error) {
                    throw ApplePackageError.emptyPackage
                }
                throw error
            }
        }

        return dict
    }

    /// Apple 在大体上「没有包可给」时长这样：5xx + 空 body（redownload 经典形态）、
    /// 或 200 但结构里没有 songList。这类失败是**业务结论**，不是网络抖动，
    /// 归一成 `emptyPackage` 才能走「获取许可」补救。
    private static func isPackageUnavailable(_ error: Error) -> Bool {
        if case ApplePackageError.emptyPackage = error { return true }
        let ns = error as NSError
        if ns.domain == "EscapeOS.Ensure" {
            let text = ns.localizedDescription
            return text.contains("HTTP 5") || text.contains("可下载内容") || text.contains("获取记录")
        }
        return false
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
            try Task.checkCancellation()
            let response = try await client.execute(request: request).get()
            finalResponse = response
            account.cookie.mergeCookies(response.cookies)
            if let pod = response.headers.first(name: "pod"), Int(pod) != nil { account.pod = pod }
            if let store = response.headers.first(name: "X-Set-Apple-Store-Front"), !store.isEmpty {
                account.fullStoreFront = store
            }

            if (300 ... 399).contains(response.status.code) {
                guard redirectAttempt < maxRedirects,
                      let location = response.headers.first(name: "location"), !location.isEmpty,
                      let next = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                      next != currentURL else {
                    throw StoreAuthenticationError.invalidRedirect
                }
                currentURL = try StoreAuthenticationProtocol.storeURL(next.absoluteString,
                    paths: [StoreDownloadEndpoint.volumeStore.path, StoreDownloadEndpoint.redownload.path])
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
            if code == 401 || code == 403 {
                // 会话票据被拒 → 交给上层重登一次再试（对齐 ipatool/Asspp 的 401/403 语义）。
                throw ApplePackageError.passwordTokenExpired
            }
            if (500 ... 599).contains(code) {
                // v0.3.352：5xx（redownload 常见 500/502 空 body）就是「Apple 没有包给你」，
                // 归一成 emptyPackage，让上层去「获取许可」补救；不再抛裸 HTTP 字符串错误。
                throw ApplePackageError.emptyPackage
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
            headers.append(("X-Apple-Store-Front", account.requestStoreFront))
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
