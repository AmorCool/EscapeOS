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
    /// 调用方应据此**再走一次「获取许可」再重试**：真机实测同一会话下，
    /// 该 Apple ID 真正下载过的应用（Gmail）能拿到完整包，没建立过下载权的
    /// （ChatGPT/Instagram/…）就是这种静默空包，而 **9610 那条路我们只在
    /// 「明确报 9610」时才会去购买 —— 空包这一档此前永远不会触发购买**。
    case emptyPackage
}

extension ApplePackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .licenseRequired:
            "License required"
        case .passwordTokenExpired:
            "登录状态已过期（password token is expired），请重新登录该 Apple ID"
        case .emptyPackage:
            "Apple 没有返回可下载内容"
        }
    }
}
