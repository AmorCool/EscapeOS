//
//  Ensure.swift
//  ApplePackage
//
//  Created by qaq on 9/14/25.
//

import Foundation

func ensure(_ condition: Bool, _ error: String) throws {
    guard condition else { try ensureFailed(error) }
}

/// 统一确定性失败出口：抛出的 NSError domain 固定为 EscapeOS.Ensure，
/// 认证重试循环据此识别并**直接透传中断**（不被 catch 吞掉继续无意义重试）.
func ensureFailed(_ error: String) throws -> Never {
    throw NSError(
        domain: "EscapeOS.Ensure",
        code: 1,
        userInfo: [
            NSLocalizedDescriptionKey: error,
        ]
    )
}
