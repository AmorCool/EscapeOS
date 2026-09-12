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

        // v0.3.176：下载流程与 Purchase 同——Apple CDN 重定向到正确 pod 需跟随
        let client = Configuration.makeHTTPClient(redirectConfiguration: .follow(max: 8, allowCycles: false))
        defer { _ = client.shutdown() }

        // fetchProductWithFallback 内部处理 302 pod 重定向 + 空包/5002 → redownload 回退。
        // v0.3.329：回退前先解析「当前版本号」再打 redownload（未固定版本的 redownload
        // 可能返回 tvOS 包）。region 在这里先取出来，避免闭包捕获 inout 的 account。
        let region = Configuration.countryCode(for: account.store) ?? Configuration.countryCode
        let appID = app.id
        let dict = try await StoreDownloadEndpoint.fetchProductWithFallback(
            client: client,
            account: &account,
            app: app,
            deviceIdentifier: deviceIdentifier,
            externalVersionID: externalVersionID ?? "",
            resolveVersion: { try await StoreCatalog.externalVersionID(appID: appID, countryCode: region) }
        )

        if let failureType = dict["failureType"] as? String {
            let customerMessage = dict["customerMessage"] as? String
            storeLog("下载被拒：\(StoreDownloadEndpoint.summary(dict))")
            switch failureType {
            case "2034", "2042":
                // v0.3.330：交给调用方自动重登后重试
                throw ApplePackageError.passwordTokenExpired
            case "9610":
                throw ApplePackageError.licenseRequired
            case retryableFailureType:
                // 已经走过 fallback 才到这里 —— 几乎不可能；保留错误路径。
                try ensureFailed("download failed: persistent \(failureType)")
            default:
                if let customerMessage = customerMessage,
                   customerMessage == "Your password has been changed"
                {
                    try ensureFailed("password token is expired")
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
