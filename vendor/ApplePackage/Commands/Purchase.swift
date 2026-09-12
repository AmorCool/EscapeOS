//
//  Purchase.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//

import Foundation

public enum Purchase {
    public nonisolated static func purchase(
        account: inout AppStoreAccount,
        app: Software
    ) async throws {
        let deviceIdentifier = Configuration.deviceIdentifier

        if (app.price ?? 0) > 0 {
            try ensureFailed("purchasing paid apps is not supported")
        }

        do {
            try await purchaseWithParams(account: &account, app: app, guid: deviceIdentifier, pricingParameters: "STDQ")
        } catch let error as NSError {
            if error.localizedDescription.contains("item is temporarily unavailable") {
                try await purchaseWithParams(account: &account, app: app, guid: deviceIdentifier, pricingParameters: "GAME")
            } else {
                throw error
            }
        }
    }

    private nonisolated static func purchaseWithParams(
        account: inout AppStoreAccount,
        app: Software,
        guid: String,
        pricingParameters: String
    ) async throws {
        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(
                tlsConfiguration: Configuration.tlsConfiguration,
                // v0.3.176：buyProduct 返回 302 重定向到正确 pod（Apple 标准 store-pod
                // 分配机制）—— 旧实现 .disallow 直接失败 302，真机下载 100% 报错
                // "purchase request failed with status 302"。改为 .follow(8 hops) 与
                // ipatool 上游对齐（PR #486 实证：购买端点需跟随跨 pod 重定向到真实 pod）。
                redirectConfiguration: .follow(max: 8, allowCycles: false),
                timeout: .init(
                    connect: .seconds(Configuration.timeoutConnect),
                    read: .seconds(Configuration.timeoutRead)
                )
            ).then { $0.httpVersion = .http1Only }
        )
        defer { _ = client.shutdown() }

        let request = try makeRequest(
            account: account,
            app: app,
            guid: guid,
            pricingParameters: pricingParameters
        )
        let response = try await client.execute(request: request).get()

        account.cookie.mergeCookies(response.cookies)

        try ensure(response.status == .ok, "purchase request failed with status \(response.status.code)")

        guard var body = response.body,
              let data = body.readData(length: body.readableBytes)
        else {
            try ensureFailed("response body is empty")
        }

        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        guard let dict = plist else { try ensureFailed("invalid response") }

        if let failureType = dict["failureType"] as? String {
            let customerMessage = dict["customerMessage"] as? String ?? ""
            storeLog("购买被拒：failureType=\(failureType) "
                + "customerMessage=\(customerMessage.isEmpty ? "none" : customerMessage) "
                + "status=\(dict["status"] ?? "none")")
            switch failureType {
            case "2059":
                try ensureFailed("item is temporarily unavailable")
            case "2034", "2042":
                // v0.3.330：交给调用方自动重登后重试（不再是一句死错误）
                throw ApplePackageError.passwordTokenExpired
            case "5002":
                // v0.3.331：5002 = 该账号**已经有这个应用的授权**（ipatool 的
                // FailureTypeLicenseAlreadyExists，cmd/purchase.go 里把它当成功、
                // 继续走下载）。此前我们把它当失败，于是"已经买过的应用"永远报
                // Apple 的 customerMessage「An unknown error has occurred」。
                storeLog("该账号已拥有此应用（5002 LicenseAlreadyExists）→ 视为已入库，继续下载")
                return
            default:
                if let customerMessage = dict["customerMessage"] as? String {
                    if customerMessage == "Subscription Required" {
                        try ensureFailed("subscription required")
                    }
                    // Apple 在令牌失效时也会用这条文案
                    if customerMessage.contains("Sign In to the iTunes Store") {
                        throw ApplePackageError.passwordTokenExpired
                    }
                    try ensureFailed(customerMessage)
                }
                try ensureFailed("purchase failed: \(failureType)")
            }
        }

        if let jingleDocType = dict["jingleDocType"] as? String,
           let status = dict["status"] as? Int
        {
            try ensure(jingleDocType == "purchaseSuccess" && status == 0, "failed to purchase app")
        } else {
            try ensureFailed("invalid purchase response")
        }
    }

    private nonisolated static func makeRequest(
        account: AppStoreAccount,
        app: Software,
        guid: String,
        pricingParameters: String
    ) throws -> HTTPClient.Request {
        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": guid,
            "needDiv": "0",
            "origPage": "Software-\(app.id)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricingParameters,
            "productType": "C",
            "salableAdamId": app.id,
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var headers: [(String, String)] = [
            ("Content-Type", "application/x-apple-plist"),
            ("User-Agent", Configuration.userAgent),
            ("iCloud-DSID", account.directoryServicesIdentifier),
            ("X-Dsid", account.directoryServicesIdentifier),
            ("X-Apple-Store-Front", "\(account.store)-1"),
            ("X-Token", account.passwordToken),
        ]

        // v0.3.337：直接打账号自己的 store pod（对齐上游 `Configuration.purchaseAPIHost`）。
        // 原来硬编码 `buy.itunes.apple.com` 再靠 302 跳到 `p<N>-buy` —— 多一跳，且
        // 重定向由 URLSession 处理时请求头可能被改写（X-Token / X-Apple-Store-Front 都在）。
        let host = (account.pod?.isEmpty == false)
            ? "p\(account.pod!)-buy.itunes.apple.com"
            : "buy.itunes.apple.com"
        let urlString = "https://\(host)/WebObjects/MZFinance.woa/wa/buyProduct"

        for item in account.cookie.buildCookieHeader(URL(string: urlString)!) {
            headers.append(item)
        }

        return try .init(
            url: urlString,
            method: .POST,
            headers: .init(headers),
            body: .data(data)
        )
    }
}
