//
//  VersionLookup.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//

import Foundation

public enum VersionLookup {
    public nonisolated static func getVersionMetadata(
        account: inout AppStoreAccount,
        app: Software,
        versionID: String
    ) async throws -> VersionMetadata {
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
                versionID: versionID
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
            // v0.3.335：区分「令牌失效」与「真没有」，前者交给调用方自动重登
            if let failureType = dict["failureType"] as? String {
                switch failureType {
                case "2034", "2042":
                    throw ApplePackageError.passwordTokenExpired
                case "9610":
                    throw ApplePackageError.licenseRequired
                default:
                    if let customerMessage = dict["customerMessage"] as? String {
                        try ensureFailed(customerMessage)
                    }
                }
            }
            try ensureFailed("Apple 没有返回该版本的信息 —— 该 Apple ID 可能缺少此应用的获取记录")
        }

        let item = items[0]
        guard let metadata = item["metadata"] as? [String: Any] else {
            try ensureFailed("missing metadata")
        }

        guard let bundleShortVersionString = metadata["bundleShortVersionString"] as? String else {
            try ensureFailed("missing bundleShortVersionString")
        }

        guard let releaseDateString = metadata["releaseDate"] as? String,
              let releaseDate = ISO8601DateFormatter().date(from: releaseDateString)
        else {
            try ensureFailed("missing or invalid releaseDate")
        }

        return VersionMetadata(displayVersion: bundleShortVersionString, releaseDate: releaseDate)
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
        versionID: String
    ) throws -> HTTPClient.Request {
        let payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.id,
            // v0.3.258：对齐上游 ipatool 5f776fe（list_versions 同款）
            "serialNumber": "0",
            "externalVersionId": versionID,
        ]

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
