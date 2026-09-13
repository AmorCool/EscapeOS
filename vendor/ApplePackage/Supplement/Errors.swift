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
    /// **v0.3.361 真机实测把这个空包的机制定死了**（旧注释里「该账号没建立过下载权」的说法已被证伪）：
    /// 该端点在 body **不带 `externalVersionId`** 时，对**任何**应用都可能回这种静默空包；
    /// 带上该账号可下的**旧**版本 ID 就出包，而**最新的两个 ID 仍会被拒**
    /// （ChatGPT 实测：890134149 / 857195392 / 857146407 / 856638501 → 出包；
    /// 890363403 / 890707559 → 空包，重跑 5 次稳定）。出包响应里会带
    /// `softwareVersionExternalIdentifiers`（该账号可下的全套 ID）。
    ///
    /// 所以调用方的补救顺序是：**先用候选 `externalVersionId` 重打 volumeStore**（候选只吃一轮）
    /// → 仍为空才刷新会话 / 获取许可。**空包 ≠ 9610**：9610 才是「真没这个应用的许可」，
    /// 两者必须分开处理（实测同一账号对 ChatGPT 的 `buyProduct` 回 5002 已拥有，
    /// 却仍拿不到不带版本号的包）。
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
