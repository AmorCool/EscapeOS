//
//  StoreDownloadEndpoint.swift
//  ApplePackage
//
//  Created on 2026/6/12. (Ported from ApplePackage 1.2.7 to the shim environment)
//

import Foundation

/// volumeStore 端点间歇性返回 failureType 5002；需要 fallback 到 redownload 端点。
/// 这是 ApplePackage 1.2.7 + asspp PR #84 (2026-06-12) 的关键修复点。
public let retryableFailureType = "5002"

public struct StoreDownloadEndpoint {
    public let host: String
    public let path: String
    /// volumeStore 端点用 `externalVersionId` 字段名；redownload 端点用 `appExtVrsId`。
    public let externalVersionIDKey: String

    public init(host: String, path: String, externalVersionIDKey: String) {
        self.host = host
        self.path = path
        self.externalVersionIDKey = externalVersionIDKey
    }

    /// 拼接完整的 store pod URL。`deviceIdentifier` 用作 `guid` 查询参数 —— Apple
    /// Volume Store API 要求 guid 在 URL 上，body 与 query 同时携带也能工作但 URL 上
    /// 才是 Apple 官方 watch key。
    public func url(pod: String?, deviceIdentifier: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = resolvedHost(pod: pod)
        comps.path = path
        comps.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        guard let url = comps.url else {
            try ensureFailed("failed to construct store URL")
        }
        return url
    }

    private func resolvedHost(pod: String?) -> String {
        guard let pod, !pod.isEmpty else { return host }
        // `host` 形如 `p25-buy.itunes.apple.com`（默认 pod）或
        // `downloaddispatch.itunes.apple.com`（红下载 fallback —— 这种直接用 host，不替换）。
        if host.contains("downloaddispatch") {
            return host
        }
        // volumeStore host 通常是 `p<数字>-buy...` 格式，按 Apple 实践用 pod 替换数字段。
        if let podInt = Int(pod) {
            return "p\(podInt)-buy.itunes.apple.com"
        }
        return host
    }
}

extension StoreDownloadEndpoint {
    /// 默认 volumeStore 端点（p25 占位 —— 实际由 `pod` 头替换）。这是 ApplePackage 1.2.7
    /// 主线量定终点的缺省 host。Apple upstream volumeStore API 要求 plist 体。
    public static let volumeStore = StoreDownloadEndpoint(
        host: "p25-buy.itunes.apple.com",
        path: "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct",
        externalVersionIDKey: "externalVersionId"
    )

    /// redownload 端点（PR #84 fallback 目标）。注意 payload 字段名换为 `appExtVrsId`。
    public static let redownload = StoreDownloadEndpoint(
        host: "downloaddispatch.itunes.apple.com",
        path: "/r/redownload",
        externalVersionIDKey: "appExtVrsId"
    )
}
