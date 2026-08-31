import Foundation
import Security

/// 纯软件 SAP 签名桥（ipatool PR #525 移植）。
///
/// 在进程内用 Unicorn 解释执行 Apple 私有 CommerceKit / CoreFP 的 x86-64 二进制，
/// 对其做 SAP（Store Activation Protocol）签名，输出即 App Store 请求所需的
/// `X-Apple-ActionSignature`（base64）。无需宿主 CommerceKit，也无需主机 JIT——
/// Unicorn 是解释器，访客代码在 app 进程内被模拟执行（LiveContainer 侧载环境即可）。
///
/// 典型调用：
/// ```swift
/// let signer = try SapSigner(setupURL: setup, certURL: cert, hardwareID: hw)
/// let sig = try signer.sign(requestBody: body)   // base64
/// signer.close()
/// ```
///
/// C 桥由 `sapbridge/build-sap.sh` 生成（`libsap.a` + `sap.h`），经
/// `EscapeOS-Bridging-Header.h` 暴露 `SapInit/SapSign/SapLastError/SapClose/SapFree`。
final class SapSigner {

    enum SapError: Error, LocalizedError {
        case notInitialized
        case initializationFailed(String)
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "SAP 签名器未初始化"
            case .initializationFailed(let m): return "SAP 初始化失败：\(m)"
            case .signingFailed(let m): return "SAP 签名失败：\(m)"
            }
        }
    }

    private var initialized = false

    /// - Parameters:
    ///   - setupURL:   App Store bag 的 `sign-sap-setup` 端点。
    ///   - certURL:    App Store bag 的 `sign-sap-setup-cert` 端点。
    ///   - version:    SAP 协议版本，通常 200。
    ///   - hardwareID: 1–20 字节的稳定设备标识；可任意取值（ipatool 用机器序列号）。
    init(setupURL: String, certURL: String, version: Int32 = 200, hardwareID: Data) throws {
        let hwB64 = hardwareID.base64EncodedString()
        // Go 的 //export 把 *C.char 生成成 C 的 `char*`（非 const），
        // Swift 将其导入为 UnsafeMutablePointer<CChar>!，不会自动把 String 转过去，
        // 故显式经 withCString + UnsafeMutablePointer(mutating:) 传参（保证两种规则下都能编过）。
        let err = setupURL.withCString { su in
            certURL.withCString { cu in
                hwB64.withCString { hw in
                    SapInit(
                        UnsafeMutablePointer(mutating: su),
                        UnsafeMutablePointer(mutating: cu),
                        version,
                        UnsafeMutablePointer(mutating: hw)
                    )
                }
            }
        }
        if let err {
            defer { SapFree(err) }
            throw SapError.initializationFailed(String(cString: err))
        }
        initialized = true
    }

    /// 对请求体签名，返回 base64 编码的 `X-Apple-ActionSignature`。
    func sign(requestBody: Data) throws -> String {
        guard initialized else { throw SapError.notInitialized }
        let b64 = requestBody.base64EncodedString()
        guard let raw = b64.withCString({ SapSign(UnsafeMutablePointer(mutating: $0)) }) else {
            if let errPtr = SapLastError() {
                defer { SapFree(errPtr) }
                throw SapError.signingFailed(String(cString: errPtr))
            }
            throw SapError.signingFailed("未知错误")
        }
        defer { SapFree(raw) }
        guard let sig = String(validatingUTF8: raw) else {
            throw SapError.signingFailed("签名结果不是合法字符串")
        }
        return sig
    }

    /// 释放模拟器。重复调用安全。
    func close() {
        guard initialized else { return }
        SapClose()
        initialized = false
    }

    deinit { close() }
}

extension SapSigner {
    /// 生成并持久化一个随机 20 字节硬件标识（首次调用后写入 UserDefaults）。
    /// SAP 握手对硬件标识无强制校验，任意稳定的 1–20 字节值即可。
    static func persistentHardwareID() -> Data {
        let key = "com.ipaside.escapeos.sap.hardwareID"
        if let existing = UserDefaults.standard.data(forKey: key), !existing.isEmpty {
            return existing
        }
        var bytes = Data(count: 20)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!)
        }
        if status != errSecSuccess {
            // 退化为时间戳 + 随机数填充
            let t = UInt64(Date().timeIntervalSince1970)
            var fallback = Data(withUnsafeBytes(of: t) { Data($0) })
            fallback.append(contentsOf: (0..<12).map { _ in UInt8.random(in: 0...255) })
            bytes = fallback
        }
        UserDefaults.standard.set(bytes, forKey: key)
        return bytes
    }
}
