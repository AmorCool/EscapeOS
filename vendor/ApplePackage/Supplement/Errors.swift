//
//  Errors.swift
//  ApplePackage
//
//  Created by luca on 15.09.2025.
//

import Foundation

public enum ApplePackageError: Error {
    case licenseRequired
    /// v0.3.330：Apple 判定登录令牌失效（`failureType` 2034 / 2042，或
    /// `customerMessage` = "Sign in to the iTunes Store"）。
    /// 调用方应**用已保存的凭据自动重登后重试一次**（ipatool cmd/purchase.go 同款）。
    case passwordTokenExpired
    /// v0.3.337：`volumeStoreDownloadProduct` 回了 **HTTP 200 + 空 songList**，
    /// 且 `failureType` / `customerMessage` 都为空（Apple 不给原因）。
    ///
    /// **v0.3.539 起语义收紧**（全量对齐 Asspp / ipatool）：
    /// 这条只表示「两个端点都回了**业务性**空包，该账号确实没有这个包的下载权」。
    /// HTTP 5xx **不再**被归一成它（那会把网络/服务端故障伪装成业务结论，
    /// 诱发上层的刷新会话 / 获取许可连环补救 —— 详见 `fetchProductWithFallback` 的注释）。
    ///
    /// 调用方应当走「获取许可 → 再试一次」那一档，而不是无限重试。
    /// **空包 ≠ 9610**：9610 才是「真没这个应用的许可」。
    case emptyPackage
    /// v0.3.539（新增，对齐 Asspp `StoreDownloadError.catalogUnavailable`）。
    ///
    /// **无法确定当前平台/地区的版本号** —— 目录查询失败、返回空 ID、
    /// 或调用方既没给 `externalVersionID` 又没有可用的 `resolveVersion`。
    ///
    /// 为什么需要单列一类而不是退化成空包/空版本：Asspp 的注释写得很明确 ——
    /// > A failed catalog lookup must not turn into an unpinned redownload.
    ///
    /// 不带版本号的 redownload 有两重害处：① 可能返回 tvOS / macOS 的包；
    /// ② 真机实测（iPhone 15 / iOS 27.0，2026-10-02）会走 Apple 的「现算授权」路径，
    /// 请求挂 9–10 秒直到 CDN 网关兜底返回 **502**。所以宁可明确报错，也不发这种请求。
    case catalogUnavailable
    /// v0.3.539（新增，对齐上游 `StoreDownloadError.response(Int)`）。
    ///
    /// **传输层/服务端失败**：带 body 的 4xx/5xx（如金山云网关的 502 HTML 页）、
    /// 网络中断、DNS 失败等。
    ///
    /// 为什么必须与 `emptyPackage` 分开：`emptyPackage` 是**业务结论**
    /// （「这个账号没有这个包的下载权」），会触发上层「获取许可 → 重试」；
    /// 而 502 是**基础设施状态**，正确的反应是**如实告诉用户、稍后重试**，
    /// 不是去刷新会话或买许可 —— 那样只会把一次点击放大成十几次请求
    /// （真机日志：一次点击 → 4 次 5xx + 10 次 volumeStore）。
    ///
    /// 上游语义见 ipatool PR #554：只有**裸 500（`Snippet == ""`）**才被视为
    /// 「redownload 空错误」并允许走 updateProduct 第三跳；带 body 的 5xx 一律
    /// 保留原本的错误处理。
    case transportFailure(status: Int)
}

extension ApplePackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .licenseRequired:
            // v0.3.366：原为英文 "License required"。这条会经由上层冒到界面上，改中文短句。
            "缺少下载许可"
        case .passwordTokenExpired:
            // v0.3.366：去掉括号里的英文术语（对用户没有意义），与视图里的短文案统一。
            "登录已过期，请重新登录"
        case .emptyPackage:
            "Apple 没有返回可下载内容"
        case .catalogUnavailable:
            "无法确定该应用的版本，请稍后重试或指定一个历史版本"
        case let .transportFailure(status):
            status > 0 ? "Apple 下载服务暂时不可用（HTTP \(status)），请稍后重试" : "网络异常，请稍后重试"
        }
    }
}
