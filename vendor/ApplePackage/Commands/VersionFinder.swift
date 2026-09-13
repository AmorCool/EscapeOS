//
//  VersionFinder.swift
//  ApplePackage
//
//  Created by qaq on 9/14/25.
//

import Foundation

public enum VersionFinder {
    /// v0.3.364：`externalVersionID` 可选 —— 静默空包时由调用方用候选版本重打（见下方说明）。
    public nonisolated static func list(
        account: inout AppStoreAccount,
        bundleIdentifier: String,
        externalVersionID: String? = nil
    ) async throws -> [String] {
        guard let countryCode = Configuration.countryCode(for: account.store) else {
            try ensureFailed("unsupported store identifier: \(account.store)")
        }
        let app = try await Lookup.lookup(bundleID: bundleIdentifier, countryCode: countryCode)

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(
                tlsConfiguration: Configuration.tlsConfiguration,
                redirectConfiguration: .disallow,
                timeout: .init(
                    connect: .seconds(Configuration.timeoutConnect),
                    read: .seconds(Configuration.timeoutRead)
                )
            ).then { $0.httpVersion = .http1Only }
        )
        defer { _ = client.shutdown() }

        let deviceIdentifier = Configuration.deviceIdentifier

        var currentURL = try StoreDownloadEndpoint.volumeStore.url(pod: account.pod, deviceIdentifier: deviceIdentifier)
        var redirectAttempt = 0
        var finalResponse: HTTPClient.Response?
        let maxRedirects = 3

        while redirectAttempt <= maxRedirects {
            let request = try makeRequest(
                account: account,
                app: app,
                url: currentURL,
                guid: deviceIdentifier,
                externalVersionID: externalVersionID
            )
            try Task.checkCancellation()
            let response = try await client.execute(request: request).get()
            finalResponse = response
            account.cookie.mergeCookies(response.cookies)

            if (300 ... 399).contains(response.status.code) {
                guard redirectAttempt < maxRedirects,
                      let location = response.headers.first(name: "location"), !location.isEmpty,
                      let next = URL(string: location, relativeTo: currentURL)?.absoluteURL, next != currentURL else {
                    throw StoreAuthenticationError.invalidRedirect
                }
                currentURL = try StoreAuthenticationProtocol.storeURL(next.absoluteString,
                    paths: [StoreDownloadEndpoint.volumeStore.path])
                redirectAttempt += 1
                continue
            }
            break
        }

        guard let finalResponse else { try ensureFailed("no response received") }

        if let pod = finalResponse.headers.first(name: "pod"), Int(pod) != nil { account.pod = pod }
        if let store = finalResponse.headers.first(name: "X-Set-Apple-Store-Front"), !store.isEmpty {
            account.fullStoreFront = store
        }
        if finalResponse.status.code == 401 || finalResponse.status.code == 403 {
            throw ApplePackageError.passwordTokenExpired
        }
        try ensure(finalResponse.status == .ok, "invalid response status \(finalResponse.status.code)")

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
        guard let dict = plist else { try ensureFailed("invalid response") }

        guard let items = dict["songList"] as? [[String: Any]], !items.isEmpty else {
            if let failureType = dict["failureType"] as? String {
                switch failureType {
                case "2034", "2042":
                    // v0.3.335：交给调用方自动重登后重试（与 Download/Purchase 一致）
                    throw ApplePackageError.passwordTokenExpired
                case "9610":
                    throw ApplePackageError.licenseRequired
                default:
                    if let customerMessage = dict["customerMessage"] as? String {
                        try ensureFailed(customerMessage)
                    }
                    throw ApplePackageError.emptyPackage
                }
            }
            // v0.3.364：**空 songList + 无 failureType / customerMessage ≠「该账号没有此应用的获取记录」。**
            //
            // 真机实测（2026-09-13）：
            //   · 相关性实验：ChatGPT / Instagram / TikTok / 微信 在**不带** `externalVersionId` 时
            //     一律是 HTTP 200 + songList=0 + 无任何错误码（Via / Gmail 则正常出包）——
            //     这是 Apple 的**静默空包**，不是「没买过」。
            //   · log4.txt：同一账号对 ChatGPT `buyProduct` 回的正是 5002 LicenseAlreadyExists
            //     （即**已拥有**），却仍然拿不到不带版本号的包。
            //   · 带旧版 `externalVersionId` 重打 volumeStore 就能出包，且响应里带该账号的**全量**
            //     `softwareVersionExternalIdentifiers`（v0.3.361 下载链路已实锤）。
            //
            // 所以这里归一成 `emptyPackage`，让调用方用候选 `externalVersionId` 再试一次 ——
            // 而不是抛一句把责任推给用户「可能缺少获取记录」的假结论。
            throw ApplePackageError.emptyPackage
        }

        let item = items[0]
        guard let metadata = item["metadata"] as? [String: Any],
              let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any]
        else {
            try ensureFailed("missing version identifiers")
        }

        let result = identifiers.map { "\($0)" }
        try ensure(!result.isEmpty, "no versions found")

        return result
    }

    private nonisolated static func createInitialRequestEndpoint(deviceIdentifier: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "p25-buy.itunes.apple.com"
        comps.path = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        comps.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        return try comps.url.get()
    }

    private nonisolated static func makeRequest(
        account: AppStoreAccount,
        app: Software,
        url: URL,
        guid: String,
        externalVersionID: String?
    ) throws -> HTTPClient.Request {
        var payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.id,
            // v0.3.258：对齐上游 ipatool 5f776fe（get_version_metadata 同款）
            "serialNumber": "0",
        ]
        // v0.3.364：带上版本号 Apple 才可能出包（静默空包的唯一决定性变量，见 v0.3.361）
        if let externalVersionID, !externalVersionID.isEmpty {
            payload[StoreDownloadEndpoint.volumeStore.externalVersionIDKey] = externalVersionID
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

        return try .init(
            url: url,
            method: .POST,
            headers: .init(headers),
            body: .data(data)
        )
    }
}
