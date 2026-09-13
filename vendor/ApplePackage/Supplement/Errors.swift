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
            // v0.3.366：原为英文 "License required"。这条会经由上层冒到界面上，改中文短句。
            "缺少下载许可"
        case .passwordTokenExpired:
            // v0.3.366：去掉括号里的英文术语（对用户没有意义），与视图里的短文案统一。
            "登录已过期，请重新登录"
        case .emptyPackage:
            "Apple 没有返回可下载内容"
        }
    }
}
