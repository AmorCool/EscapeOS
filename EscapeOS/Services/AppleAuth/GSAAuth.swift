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

        // 对齐原版 StosSign GSAContext：
        // - sessionKey = S 的 256 字节（sharedSecret.bytes），用于 M2 验证与 spd 的 AES-CBC 解密
        //   （decryptedCBC 用 HMAC(key: sessionKey) 派生，HMAC 允许任意长度 key）；
        // - 进入 apptokens 前 sessionKey 会被 spd 里的 sk 覆盖（Apple 下发的 32 字节密钥），
        //   checksum / GCM 解密都用那个 sk，与这里无关。
        // - K = SHA256(S) 仅用于 M1/M2 证明（hashSharedSecret）。
        let (S, K) = SRP6a.calculateSharedSecret(
            private: clientPrivateKey,
            x: BigInt(bytes: x),
            salt: salt.map { $0 },
            A: publicKey.map { $0 },
            B: serverPublicKey.map { $0 }
        )
        sessionKey = Data(S.bytes(paddedTo: SRP6a.sizeN))

        // 中间值日志：配合 Python 参考实现可精确复算定位（u 不依赖密码）
        let hexOf: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        LoginLogger.shared.log("SRP 中间值 x=\(hexOf(x)) u=\(hexOf(SRP6a.sha256(SRP6a.pad(publicKey.map { $0 }, to: SRP6a.sizeN) + serverPublicKey.map { $0 }))) S=\(hexOf(S.bytes(paddedTo: SRP6a.sizeN))) K=\(hexOf(K))")

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
        // sessionKey 当前是 S（256 字节），证明计算需要 K = SHA256(S)
        let K = SRP6a.sha256(sessionKey.map { $0 })
        let computed = SRP6a.serverProof(
            A: publicKey.map { $0 },
            M1: verificationMessage.map { $0 },
            K: K
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
        return Self.deriveX(inputForPBKDF2: inputForPBKDF2, salt: salt.map { $0 }, iterations: iterations)
    }

    /// x = SHA256(salt + SHA256(0x3A + PBKDF2(passwordInput, salt, iters, 32)))
    private static func deriveX(inputForPBKDF2: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8]? {
        guard let derived = pbkdf2SHA256(password: inputForPBKDF2, salt: salt, rounds: iterations, keyLength: 32) else {
            return nil
        }
        let message = [UInt8(0x3A)] + derived
        let innerHash = SHA256.hash(data: Data(message))
        let xInput = salt + Array(innerHash)
        return Array(SHA256.hash(data: Data(xInput)))
    }

    // MARK: - 自检（对齐 Python 参考实现生成的固定向量，登录前运行并写入诊断日志）

    /// 用固定输入验证 x 推导与 SRP 数学（BigInt modPow / 乘除 / 证明），
    /// 任一 FAIL 即说明实现与原版不一致——这是排查 -22406 的关键证据。
    static func runSelfTest() -> String {
        var lines = ["SRP 自检开始"]
        let hexOf: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        func check(_ name: String, _ got: [UInt8], _ expected: String, _ lines: inout [String]) {
            let g = hexOf(got)
            lines.append("\(name): \(g == expected ? "PASS" : "FAIL got=\(g) want=\(expected)")")
        }

        let salt: [UInt8] = [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
                             0x29, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90]
        let iterations = 50_000
        let digest = Array(SHA256.hash(data: Data("testpassword123".utf8)))

        let xNormal = deriveX(inputForPBKDF2: digest, salt: salt, iterations: iterations) ?? []
        check("X_NORMAL", xNormal, "bd6a87582afe077628b72153e0f603592732e4c75f626395e83157c463554ede", &lines)

        let hexInput = digest.map { String(format: "%02x", $0) }.joined().utf8.map { UInt8($0) }
        let xHex = deriveX(inputForPBKDF2: Array(hexInput), salt: salt, iterations: iterations) ?? []
        check("X_HEX", xHex, "75eb252d5ed74540c5028726759108bb169a7db5a310ee37305f7ab9191a7264", &lines)

        let aBytes = hexToBytes("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF") ?? []
        let A = hexToBytes("109649b7a829a8c071a8dfc2848b2353209cc0e724c7cac408c2414df0d112fa6d024cede973866e7d2f383fdfe9a007774bd0567fff5ffd3c203bc60aa7c1b493efae8a3700193d4c187035d2d7caae4c0bde6b944e53db812c9927771be5849b65a955a5c34b279f692cec8827812875b90c4b34c2c2eeb775872972ae5e116868997f5ea3bf61d8b809a028a0fbff18926bb684f295c66cd44b092f580f5503212b742672875414b4ef499e0cf4407f58ac69883e42e189b70ce04e10406e7d6efad757b908db14daac7346d4d43020e0fbd4d5f81fc5434f8dd94174d9cb92784d52259c3f90018a0e808dfc2fcb07d0b7d3a74f6d62778dbcfc6104e545") ?? []
        let B = hexToBytes("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210") ?? []

        let xBig = BigInt(bytes: xNormal)
        let (S, K) = SRP6a.calculateSharedSecret(
            private: BigInt(bytes: aBytes), x: xBig,
            salt: salt, A: A, B: B
        )
        check("K", K, "b4ef401d9c254eb44931c5aba7dacdab14c9d58bdf396439d880369aa1a94a84", &lines)
        check("S", S.bytes(paddedTo: SRP6a.sizeN), "44a0986e02e4e0f811dfcaf6e862ce2f7a2d38494bc5780c011666a09d17065178d2d8a0ef3bb2a844e49f62e732203466b4d26558f0efffd55bdab790893302eb24da5e60c5342ce57a16fab5fbffec11a3e95b75c078788abc87eba8cbe456d36896adb38da9da0a5d8fc007dd60a5632d9c65d1d015e3c6c49fd4186b92fc6b4c6e74dae39f55386a691d24712d865dc186a1fe0476800cb0e1047b5225f7106005c22e4efd029c0810af64af0ad38937f03e7427fbb171387797345db6ba1dbb1b6bbaf88710280959e992cda4ca4a1637cae4b9f6780a822596f516dee0fd2a21be453bba04d18e400bddfe64cda5af877a17e11d39d3d458a1bcaa0be1", &lines)

        let M1 = SRP6a.clientProof(username: "alice@test.com", salt: salt, A: A, B: B, K: K)
        check("M1", M1, "7315ce4867f64e105c357f7f209c9268d19066cdda4c8da3b0de71dddc626ee1", &lines)

        let M2 = SRP6a.serverProof(A: A, M1: M1, K: K)
        check("M2", M2, "adb31da704dc646e8cd9971dc61c321d7f088e9352b9795d66e3c30246ba4ccc", &lines)

        return lines.joined(separator: " | ")
    }

    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            out.append(b)
            i = next
        }
        return out
    }

    private static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], rounds: Int, keyLength: Int) -> [UInt8]? {
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
