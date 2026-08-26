import Foundation
import CommonCrypto
import CryptoKit

/// Apple GrandSlam (gsa.apple.com) SRP-6a 认证上下文。
/// 对应 StosSign 的 GSAContext，但使用本项目自带的纯 Swift `SRP6a` 引擎 +
/// 原生 `CommonCrypto`(PBKDF2/AES-CBC) 与 `CryptoKit`(SHA256/HMAC/AES-GCM)，
/// 不依赖任何第三方 SwiftPM 包（swift-srp / swift-crypto / CryptoSwift 在 Theos 下无法编译）。
final class GSAAuth {
    let username: String
    let password: String

    var salt: Data?
    var serverPublicKey: Data?
    var sessionKey: Data?
    var dsid: String?

    private(set) var publicKey: Data?
    private(set) var verificationMessage: Data?

    private var clientPrivateKey: BigInt?
    private var isHexadecimal = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    // MARK: - SRP 握手

    func start() -> Data? {
        guard publicKey == nil else { return nil }
        let (pub, priv) = SRP6a.generateKeys()
        publicKey = Data(pub)
        clientPrivateKey = priv
        return publicKey
    }

    func makeVerificationMessage(iterations: Int, isHexadecimal: Bool) -> Data? {
        self.isHexadecimal = isHexadecimal
        guard let salt, let serverPublicKey, let clientPrivateKey,
              let publicKey else { return nil }

        guard let x = makeAppleX(password: password, salt: salt, iterations: iterations) else { return nil }

        // S = 完整 SRP 共享密钥（对齐 AltStore/StosSign：256 字节，直接作为 AES 会话密钥）
        // K = SHA256(S)，仅用于 M1/M2 证明计算
        let (_, K) = SRP6a.calculateSharedSecret(
            private: clientPrivateKey,
            x: BigInt(bytes: x),
            salt: salt.map { $0 },
            A: publicKey.map { $0 },
            B: serverPublicKey.map { $0 }
        )
        // 会话密钥 = K = SHA256(S)（32 字节），对齐 AltStore/StosSign：
        // - serverProof/clientProof 与 apptokens 校验和均使用 K；
        // - decryptedGCM 直接拿 sessionKey 当 AES-GCM 密钥（必须 16/24/32 字节），256 字节的 S 会运行时崩溃。
        sessionKey = Data(K)

        let M1 = SRP6a.clientProof(
            username: username,
            salt: salt.map { $0 },
            A: publicKey.map { $0 },
            B: serverPublicKey.map { $0 },
            K: K
        )
        verificationMessage = Data(M1)
        return verificationMessage
    }

    func verifyServerVerificationMessage(_ serverProof: Data) -> Bool {
        guard let verificationMessage, let sessionKey, let publicKey, let serverPublicKey else { return false }
        let computed = SRP6a.serverProof(
            A: publicKey.map { $0 },
            M1: verificationMessage.map { $0 },
            K: sessionKey.map { $0 }
        )
        return computed == serverProof.map { $0 }
    }

    // MARK: - x 派生：x = SHA256(salt | SHA256(0x3A | PBKDF2(SHA256(password), salt, iters)))

    private func makeAppleX(password: String, salt: Data, iterations: Int) -> [UInt8]? {
        let passwordData = Data(password.utf8)
        let digest = SHA256.hash(data: passwordData)
        let inputForPBKDF2: [UInt8]
        if isHexadecimal {
            inputForPBKDF2 = digest.map { String(format: "%02x", $0) }.joined().utf8.map { UInt8($0) }
        } else {
            inputForPBKDF2 = Array(digest)
        }
        guard let derived = pbkdf2SHA256(password: inputForPBKDF2, salt: salt.map { $0 }, rounds: iterations, keyLength: 32) else {
            return nil
        }
        let message = [UInt8(0x3A)] + derived
        let innerHash = SHA256.hash(data: Data(message))
        let xInput = salt.map { $0 } + Array(innerHash)
        return Array(SHA256.hash(data: Data(xInput)))
    }

    private func pbkdf2SHA256(password: [UInt8], salt: [UInt8], rounds: Int, keyLength: Int) -> [UInt8]? {
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { pwdBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBytes.bindMemory(to: CChar.self).baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress, keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return derived
    }

    // MARK: - 校验和 / HMAC key

    func makeChecksum(appName: String) -> Data? {
        guard let sessionKey else { return nil }
        let key = SymmetricKey(data: sessionKey)
        var hmac = HMAC<SHA256>(key: key)
        for s in ["apptokens", dsid ?? "", appName] {
            hmac.update(data: Data(s.utf8))
        }
        return Data(hmac.finalize())
    }

    func makeHMACKey(_ string: String) -> Data {
        guard let sessionKey else { return Data() }
        let key = SymmetricKey(data: sessionKey)
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data(string.utf8))
        return Data(hmac.finalize())
    }

    // MARK: - 服务端返回的解密

    func decryptedCBC(_ data: Data) -> Data? {
        let key = makeHMACKey("extra data key:")
        var iv = makeHMACKey("extra data iv:")
        iv = iv.count >= 16 ? iv.prefix(16) : iv
        return aesCBCDecrypt(data, key: key, iv: iv)
    }

    func decryptedGCM(_ data: Data) -> Data? {
        guard let sessionKey, data.count >= 35 else { return nil }
        let version = data[0..<3]
        let iv = data[3..<19]
        let ciphertext = data[19..<data.count - 16]
        let tag = data.suffix(16)
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(sealed, using: SymmetricKey(data: sessionKey), authenticating: version)
        } catch {
            return nil
        }
    }

    private func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        let keyLen = key.count
        guard [16, 24, 32].contains(keyLen) else { return nil }
        let ivBytes = iv.count >= 16 ? iv.prefix(16) : (iv + Data(repeating: 0, count: 16 - iv.count))
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let outCount = out.count
        let status = data.withUnsafeBytes { db in
            key.withUnsafeBytes { kb in
                ivBytes.withUnsafeBytes { ib in
                    out.withUnsafeMutableBytes { ob in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            kb.bindMemory(to: UInt8.self).baseAddress, keyLen,
                            ib.bindMemory(to: UInt8.self).baseAddress,
                            db.bindMemory(to: UInt8.self).baseAddress, data.count,
                            ob.bindMemory(to: UInt8.self).baseAddress, outCount, &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLen..<out.count)
        return out
    }
}
