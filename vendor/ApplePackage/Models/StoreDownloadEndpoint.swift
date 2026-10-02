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

// [local patch · Swift 6] StoreDownloadEndpoint 只含 let 不可变存储属性，补 Sendable 以允许 static let 常量并发共享。
public struct StoreDownloadEndpoint: Sendable {
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

    /// updateProduct 端点 —— **这确实是上游功能**（v0.3.537 移植正确，v0.3.539 修正引用）。
    ///
    /// 权威来源（2026-10-02 核对，此前我一度误判为「编造的端点」，特此更正）：
    /// - **ipatool PR #554**（`pkg/appstore/appstore_download_product.go`，新增文件）
    ///   —— 本地 `P3_爱思助手_上游ipatool参考` 是 `a9bd16c`，**早于该 PR**，所以 grep 不到。
    /// - **Asspp `b3c8574a1943d846c4d6b7f023e95fc19bdfd4b4`**（2026-09-15，zetxtech 分叉）：
    ///   > feat: recover empty iOS downloads through the update product endpoint
    ///   > Mirror ipatool's redownload/update recovery chain (majd/ipatool#554) …
    ///   > when redownload still comes back empty, an iOS request (iPhone/iPad)
    ///   > draws the updateProduct endpoint **exactly once** with the **already resolved version**.
    ///
    /// ## 上游的触发条件（4 个必须同时满足）
    ///
    /// ```
    /// if bag.UpdateEndpoint != "" && externalVersionID != "" &&
    ///    (platform == "" || platform == PlatformIPhone || platform == PlatformIPad) &&
    ///    (isEmptyRedownloadError(err) || (err == nil && isUnavailableDownloadProductResponse(redownloadRes)))
    /// ```
    ///
    /// 1. bag 里 `updateProduct` 非空（**端点是服务端下发的，不是硬编码常量**）；
    /// 2. `externalVersionID` 非空（必须 pinned）；
    /// 3. 平台是 iOS 系（**排除 macOS / tvOS / visionOS**）；
    /// 4. redownload 的失败形态必须是这两种之一：
    ///    - `isEmptyRedownloadError`：**裸 HTTP 500，且 `Snippet == ""`**；
    ///    - `isUnavailableDownloadProductResponse`：200 + `failureType` 空 + `items` 空 +
    ///      `customerMessage` 是 `"no longer available"`（或以 `" no longer available"` 结尾）。
    ///
    /// ⚠️ **注意第 4 条**：带 body 的 5xx（如我们真机日志里的 **502 + `kngx` HTML 页**）
    /// 按上游标准 **`Snippet != ""` ⇒ 不满足**，**不应**走 updateProduct。
    ///
    /// ## 本仓保留为常量（与上游差异，需知悉）
    ///
    /// 上游从 bag 动态取 `updateProduct` 地址；本仓没有 bag 拉取链路，
    /// 因此按 `downloaddispatch.itunes.apple.com/up/updateProduct` 硬编码 ——
    /// 与 ipatool `downloadDispatchDomain` + `updateProductPath` 的拼法一致。
    /// 若 Apple 改下发地址，需要补 bag 支持。
    public static let updateProduct = StoreDownloadEndpoint(
        host: "downloaddispatch.itunes.apple.com",
        path: "/up/updateProduct",
        externalVersionIDKey: "appExtVrsId"
    )
}
