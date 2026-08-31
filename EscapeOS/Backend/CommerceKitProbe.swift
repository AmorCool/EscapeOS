//
//  CommerceKitProbe.swift
//  EscapeOS
//
//  P0 spike（待删）：在真机上验证 CommerceKit 的 CKSigningSession 能否对本 App
//  上下文签名。结果仅用于决定「App Store 移植」在 iOS 上是否可行，不影响任何功能。
//  C 函数由 EscapeOS/Engine/CommerceKitSpike.m 提供（桥接头已声明）。
//

import Foundation
import Darwin

enum CommerceKitProbe {
    /// 运行探测：对一段 dummy 数据执行 SAP 签名，返回人类可读结论。
    static func run() -> String {
        let dummy = "escapeos-commercekit-sap-spike".data(using: .utf8)!

        var output: UnsafeMutablePointer<CUnsignedChar>? = nil
        var outputLength: size_t = 0
        var errorMessage: UnsafeMutablePointer<CChar>? = nil

        let status: Int32 = dummy.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: CUnsignedChar.self).baseAddress!
            return commercekit_sap_sign(
                base,
                raw.count,
                &output,
                &outputLength,
                &errorMessage
            )
        }

        defer {
            if let o = output { free(UnsafeMutableRawPointer(o)) }
            if let e = errorMessage { free(UnsafeMutableRawPointer(e)) }
        }

        if status != 0 {
            let msg = errorMessage.map { String(cString: $0) } ?? "未知错误"
            return "❌ 失败 (status=\(status)): \(msg)"
        }

        guard let out = output, outputLength > 0 else {
            return "⚠️ 签名返回空（status=0 但无数据）"
        }

        let signature = Data(bytes: out, count: outputLength)
        return "✅ 成功：CommerceKit 可签名。signature \(signature.count) 字节，base64=\(signature.base64EncodedString())"
    }
}
