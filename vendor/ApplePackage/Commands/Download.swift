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

        // fetchProductWithFallback 内部已经处理 302 pod 重定向 + 5002 → redownload fallback。
        let dict = try await StoreDownloadEndpoint.fetchProductWithFallback(
            client: client,
            account: &account,
            app: app,
            deviceIdentifier: deviceIdentifier,
            externalVersionID: externalVersionID ?? ""
        )

        if let failureType = dict["failureType"] as? String {
            let customerMessage = dict["customerMessage"] as? String
            switch failureType {
            case "2034", "2042":
                try ensureFailed("password token is expired")
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
                if let customerMessage = customerMessage {
                    try ensureFailed(customerMessage)
                }
                try ensureFailed("download failed: \(failureType)")
            }
        }

        guard let items = dict["songList"] as? [[String: Any]], !items.isEmpty else {
            try ensureFailed("no items in response")
        }

        let item = items[0]
        guard let url = item["URL"] as? String else {
            try ensureFailed("missing download URL")
        }

        guard var metadata = item["metadata"] as? [String: Any] else {
            try ensureFailed("missing metadata")
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

        return DownloadOutput(
            downloadURL: url,
            sinfs: sinfs,
            bundleShortVersionString: version,
            bundleVersion: bundleVersion
        )
    }
}
