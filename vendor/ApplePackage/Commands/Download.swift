//
//  Download.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//  v0.2.155: 改为调 StoreDownloadEndpoint.fetchProductWithFallback(pr #84)，
//  不再硬编码 p25 URL —— Apple upstream 会按 account.pod 路由到 pXX。
//

import Foundation

public enum Download {
    public static func download(
        account: inout AppStoreAccount,
        app: Software,
        externalVersionID: String? = nil
    ) async throws -> DownloadOutput {
        let deviceIdentifier = Configuration.deviceIdentifier

        // fetchProduct validates and follows redirects itself, preserving POST/body and updated cookies.
        let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)
        defer { _ = client.shutdown() }

        // v0.3.539：对齐 Asspp `StoreDownloadService.download` —— **至多一次回退**。
        //
        // 回退前解析「当前版本号」再打 redownload 的**理由仍然成立**（未固定版本的
        // redownload 可能返回 tvOS 包）；但**版本一旦有值就必须一直用它**，
        // 且解析失败要抛 `catalogUnavailable` 而不是发出不带版本号的请求。
        // 这两条门现在都收在 `fetchProductWithFallback` 内部。
        let region = Configuration.countryCode(for: account.store) ?? Configuration.countryCode
        let appID = app.id

        // v0.3.543：**先试 `ent/download`**（上游把它贴在最前面）。
        //
        // bag 拉不到 / 键缺失 → `endpoint` 为 nil → `fetchProductWithFallback` 里
        // 那一跳自然跳过，静默落回 volumeStore 链。所以这里**不需要**判错。
        //
        // ⚠️ 顺序有讲究：**必须先算 `endpoint` 再进 fallback**。放进闭包里会有两个问题：
        //   ① 版本解析那一跳本可以并行做，被 bag 串行挡住；
        //   ② 上游的 bag 是「第一次失败后再复用」的（`appstore_download_product.go:52-88`），
        //      我们这里没有后续用 bag 的地方，所以拉一次就够。
        let entEndpoint = await EntDownload.endpointFromBag(
            client: client,
            account: &account,
            deviceIdentifier: deviceIdentifier
        )

        let dict = try await StoreDownloadEndpoint.fetchProductWithFallback(
            client: client,
            account: &account,
            app: app,
            deviceIdentifier: deviceIdentifier,
            externalVersionID: externalVersionID ?? "",
            resolveVersion: { try await StoreCatalog.externalVersionID(appID: appID, countryCode: region) },
            entDownloadEndpoint: entEndpoint
        )

        if let failureType = dict["failureType"] as? String {
            let customerMessage = dict["customerMessage"] as? String
            storeLog("下载被拒：\(StoreDownloadEndpoint.summary(dict))")
            switch failureType {
            case "2034", "2042", "2002":
                // v0.3.330/352：交给调用方自动重登后重试。
                // 2002 = FailureTypePasswordChanged，与 2034/2042 同类（票据不被 Apple 认可）。
                throw ApplePackageError.passwordTokenExpired
            case "9610":
                throw ApplePackageError.licenseRequired
            case retryableFailureType:
                // 已经走过 fallback 才到这里 —— 几乎不可能；保留错误路径。
                try ensureFailed("download failed: persistent \(failureType)")
            default:
                if let customerMessage = customerMessage,
                   customerMessage.contains("password has") // "Your password has been changed"
                {
                    throw ApplePackageError.passwordTokenExpired
                }
                if let customerMessage = customerMessage,
                   customerMessage.contains("Sign In to the iTunes Store")
                {
                    throw ApplePackageError.passwordTokenExpired
                }
                if let customerMessage = customerMessage {
                    try ensureFailed(customerMessage)
                }
                try ensureFailed("download failed: \(failureType)")
            }
        }

        guard let items = dict["songList"] as? [[String: Any]], !items.isEmpty else {
            storeLog("下载响应没有 songList：\(StoreDownloadEndpoint.summary(dict))")
            // v0.3.337：Apple 会返回**静默空包**（HTTP 200 / failureType 空 / songList 空）。
            // 抛可识别的错误类型，让调用方**再走一次「获取许可」再重试** ——
            // 此前空包只回退端点、从不购买，于是这一档永远卡死。
            throw ApplePackageError.emptyPackage
        }

        let item = items[0]
        guard let url = item["URL"] as? String else {
            try ensureFailed("missing download URL")
        }

        guard var metadata = item["metadata"] as? [String: Any] else {
            try ensureFailed("missing metadata")
        }

        // v0.3.329：核对返回的包是不是我们要的那个应用（Apple 有时会按客户端平台
        // 返回 macOS/tvOS 的包；Asspp 65be5b04 同款校验）
        if let returnedBundle = metadata["softwareVersionBundleId"] as? String,
           !returnedBundle.isEmpty, returnedBundle != app.bundleID {
            storeLog("返回的包不属于本应用：期望 \(app.bundleID)，实际 \(returnedBundle)")
            try ensureFailed("Apple 返回了其他应用（或错误平台）的包：\(returnedBundle)")
        }

        let version = (metadata["bundleShortVersionString"] as? String)
        let bundleVersion = metadata["bundleVersion"] as? String

        guard let version, let bundleVersion else {
            try ensureFailed("missing required information")
        }

        // 像 asspp/AssppWeb 一样把 apple-id / userName 注入 metadata（当前
        // DownloadOutput 模型还没加 iTunesMetadata 字段，序列化部分先不写入）。
        metadata["apple-id"] = account.email
        metadata["userName"] = account.email

        var sinfs: [Sinf] = []
        if let sinfData = item["sinfs"] as? [[String: Any]] {
            for sinfItem in sinfData {
                if let id = sinfItem["id"] as? Int64,
                   let data = sinfItem["sinf"] as? Data
                {
                    sinfs.append(Sinf(id: id, sinf: data))
                } else {
                    try ensureFailed("invalid sinf item")
                }
            }
        }
        try ensure(!sinfs.isEmpty, "no sinf found in response")

        storeLog("下载信息就绪：\(app.bundleID) v\(version)(\(bundleVersion)) "
            + "sinf=\(sinfs.count) serialNumber=\(Configuration.deviceSerialNumber)")

        return DownloadOutput(
            downloadURL: url,
            sinfs: sinfs,
            bundleShortVersionString: version,
            bundleVersion: bundleVersion
        )
    }
}
