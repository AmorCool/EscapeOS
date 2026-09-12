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
    /// `customerMessage` = "Sign In to the iTunes Store"）。
    /// 调用方应**用已保存的凭据自动重登后重试一次**（ipatool cmd/purchase.go 同款）。
    case passwordTokenExpired
}

extension ApplePackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .licenseRequired:
            "License required"
        case .passwordTokenExpired:
            "登录状态已过期（password token is expired），请重新登录该 Apple ID"
        }
    }
}
