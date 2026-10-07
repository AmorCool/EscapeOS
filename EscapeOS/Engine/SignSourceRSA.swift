import Foundation
import Security

// MARK: - 软件源 RSA 层（命中信封键时启用）
//
// 服务端用配对公钥加密整份源 JSON，客户端用**内嵌私钥**解密（防抓取/防篡改，非按用户分发）。
// 出处：`P3_爱思助手_逆向/EscapeSpace_软件源网络层_规格.md` §4；
// 全能签侧 `P4_全能签逆向/全能签271_RSA层.md`、`全能签271_信封键判定机制.md`。
// 与 `NiuwaCrypto`（AES-GCM）**无关** —— 严禁把本层任何逻辑套进 `NiuwaStoreClient`。
//
// 三段分流（§4.8）：先探明文封装（C1 = `base64(json)`，无加密，直接用）
// → 再判 `%256` 走 RSA（A/B）
// → 非 256 对齐 ⇒ `.unsupportedCipher`（C2 流密码 / D Base62，优雅降级，不崩不误判）。

/// 极简 ASN.1 DER 走查：PKCS#8 PrivateKeyInfo → 内层 PKCS#1 RSAPrivateKey。
///
/// `SecKeyCreateWithData` 对 RSA 私钥只吃 **PKCS#1**（`BEGIN RSA PRIVATE KEY`），
/// 而内嵌 key 是 **PKCS#8**（`BEGIN PRIVATE KEY`）⇒ 必须剥掉算法头 + OCTET STRING 外壳。
/// 不要硬编码偏移 —— 走查对任何长度的 key 都成立（§4.3.2）。
enum SignSourceASN1 {

    /// 读一个 TLV，返回 `(tag, valueRange, nextOffset)`。
    static func read(_ d: Data, _ off: Int) -> (tag: UInt8, range: Range<Int>, next: Int)? {
        guard off < d.count else { return nil }
        let tag = d[off]
        var p = off + 1, len = 0
        guard p < d.count else { return nil }
        let l0 = Int(d[p]); p += 1
        if l0 & 0x80 == 0 {
            len = l0
        } else {
            let n = l0 & 0x7F
            guard p + n <= d.count, n <= 4 else { return nil }
            for _ in 0..<n { len = (len << 8) | Int(d[p]); p += 1 }
        }
        guard p + len <= d.count else { return nil }
        return (tag, p..<(p + len), p + len)
    }
}

/// 软件源的 RSA 层：命中信封键时启用。
enum SignSourceRSA {

    /// 内嵌私钥（2272 字符 base64，PKCS#8 RSA-2048）。
    ///
    /// 实测提取自 `NiuWaCore` 9.0.1 偏移 `0x1607253`（提取命令与指纹见规格 §4.1）。
    /// **与全能签内嵌 key#1 逐字节相同**（`sha256(PEM) = bca9e653…4160`，§4.6）——
    /// 5.1.0 与 9.0.1 同一把 key，跨版本无需替换。
    /// 完整串（单行，勿换行；末尾 `=` padding 必须保留）。
    private static let embeddedPrivateKeyBase64 = "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUV2Z0lCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQktnd2dnU2tBZ0VBQW9JQkFRQ1JiYVo5bDEwWFhuSTkKalZrSzF4ZGpzRDBnckZDNngzRlZDTGllR0N3U3lkdks0Mm92cUdRV2tadkk3UExScERLSGQ1WnJCbk5BS3FIVgplWmJGcTROUVkrQ0QvNjBTekVtOXBrSTY4TXM3R29JYTFDQ1o0eXVBSFowdmR5WmVNMjcyc2JobUx3Ylk2WWlPClRGdW5vU3VKV2xjdkx1clQ5RVFqQVFFcWdxcVdhU1hndEM2TjhwSldqdU5qNHlCM1ZNK3RCVUpCV2dOd090MVcKVjJZNWl3OHFTM2JBb3VqUnlhdlI0dUZVM0FjVzlYbHhBYVZSUXo2cXNYdGx0eC9oWDc2NjE3MDdDR1RnNXUrego1SDJlSWNoUFZ3RXlVT1pXaHpnSGpQNHNSUTVTbjFTVXBlWC9vNWpLQnlBc3BrZnl1Um1GTmxZcFVlZ05iUjY1CldsVXFxYXgvQWdNQkFBRUNnZ0VBQUxTMy9LMHZXQ3JvWERvQ3pqRCsrd2I2RjQvS081MjlLUW13S2duSjZsWWwKQ1F3ZHZteW1NbDl4TzgwMUtMV0M5SUFtaGpRdnBwT04zQXU0RHpHcXJmK0lqdDNxVXVYR0FIa24wZnBzb0JmeQo0K0lHamd2dXlhaVFTNEZrbWtMSUMyUVlRWHpDbUpyV3NDdXo5Sm9PK25FajRkUmFlM3IrbFFpdDZ2YnZRb2EvClhpWlNiVFdiWUJveWxlbHU5eXZXVVJoVGhXRHlxenZ2MGhlcS95NlBJeDI4V2NZUjBxWjZPdnVITHloYXU4a1AKcjJKaC9qQ1BzMmxHWGhJTmJjZG9xWEFDN0xqU1BkR2VNV0pwT0NHQ09hVXFSTXhIQzN2SmRzZmdwRGZxRHpZUwpoczlyTmJ2bDJPak0rcUcyM2FTaFFwQUVYdllaMldRaEpnbGpIM2xKYlFLQmdRREJteVpnMXZuZWdlQVorTEJ2CkRUTUFFUjVpMjlHWVlienJGMDREVlo2ZXhOUmJsbUVkSnlzNDlTbGtLTUlIazNiSUdXTnpTTEJyVmQxWW9yZnIKc3VobVdhOUo2dzlCREQ1Y1YrbVdiM0ZVZjdydEZxVllsWUwvMG51Skl2Uzg1eTUwQ1pmbnNnaXhJRHhmMmN2WQpuYnEyQ05jbzV2WERmTzQrUVpHQWo5OUdYUUtCZ1FEQVM4QVFWbEZsMW1Cci8zc3N0NFhFcngwSktrMTNNVEdPCm1qUDhDdHY0NE84QjNSaW1nQWpYWlB1ckZzemFuNGdYNlZvbzdQT1dnSndDNzdrRWJoMUZybDI5aHJGOUpKODgKckgxOVR4RzloYzdSTjZKUzRjVVVFOFhrQWxjVm8vM3RDdDdDS1VCOHExSy9sSVVyK1ZDV2dVaXhEUjFsKy9FSQpKWm1zbkZEWWl3S0JnQzZ3dVArdnVKREZwNEw3NjZqTWVSa3lCNjcxcmtWZWhNMzVUOUlVQ3UzbE1BVnFiYjgzCkhBQmZkM3oxSzEzaVhVb0NmVzVuQUV6U1oxQWg1ZE1NMFdrbGhkV0F2NndEUk9MR1BNb1AxRGY1bWQzbGtUaWMKemZ2ZUNmYlhuRWdXUktpdFM1b1A0SEsvQUhCcE9QVGpqUXlyY3lBbEd1M3JLaFdQZ0lTTnJkM3RBb0dCQUkvSwpsUTRpWGErWEJIYjlqYSs4Yyt6RlBTTVRYT1hhQlVLckVHQlNCbmN1UzhySzk1blpkOE1KSWgrblp2dTcrMXBXCkJqTkFMRTNJVWVEb1BTT1E2NWFsY2pjOHR3L3JDSitvSkJaRnYvQkdWSWFoNFdHMHJWZjhDU2djajk0QXlPb3UKRExDSGhFODFGU1ZvKzhRTUpEVEc3QUpvMmlqZW9qZ0RWY3g2L3dGTkFvR0JBS0w2TGJ2b3Raamp0OHNTd0dXTApLZEEremxqdERjUUgwNS91VzVBWVY1WEs1S2JyWkJWV0lpMTNYbWs3cWVjU083cDZ3RmVBQkJTVDQybzM0b1F5CmgybCtnK3FGYjZjQzU2T2h3WEpMMDJqL2dYbXpEbWZwbkgyUUVEU0MxV1VPR1pacjFkNEh6d2w3Rm5nMmVzcncKT3RlZ2FPZHkzQVR2RWM0N2hDa1ZrNm1wCi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0="

    /// ★ 候选信封键（**按序精确匹配，不做 `lowercased()` 归一**，§4.2）。
    /// 前三个 = 全能签/轻松签系（全小写）；后三个 = 牛蛙系（驼峰）。命中任一 ⇒ 加密信封。
    private static let envelopeKeys = [
        "appstore",      // 全能签 legacy
        "appstore_v1",   // 全能签 V1（用户手上那批源走这条）
        "appstore_v2",   // 全能签 V2
        "AppStore",      // 牛蛙
        "AppStore_v1",   // 牛蛙
        "AppStore_v2",   // 牛蛙
    ]

    /// 响应顶层若含信封键（**枚举 `envelopeKeys`，各自大小写敏感**）→ 返回解出的源 JSON `Data`。
    /// 返回 nil 表示「无信封键」= 明文分支（调用方直接用原 dict）。
    ///
    /// ★ 判据双保险（全能签就是两套并行，§4.2）：**JSON 键查找**为主 + **响应体前 8KB 带引号字面量扫描**为辅。
    /// 主判据全 miss 时，用辅判据兜底（`body` = 原始响应体）。
    ///
    /// ★ 信封键 ≠ 加密（§4.8）：同键 `appstore` 有两种形态 —— C1 `base64(json)` 明文封装
    /// 与 C2 流密码。故这里**先探明文 JSON**（`looksLikePlainJSON`），命中直接返回（无加密）；
    /// 未命中才走 RSA（A/B）；非 256 对齐由 `decrypt` 抛 `.unsupportedCipher`（C2/D）。
    static func decryptEnvelopeIfPresent(_ root: [String: Any], body: Data? = nil) throws -> Data? {
        // 主判据：JSON 键查找（枚举，各自大小写敏感）
        for key in envelopeKeys {
            guard let b64 = root[key] as? String, !b64.isEmpty else { continue }
            return try unwrapOrDecrypt(key: key, base64: b64)
        }
        // 辅判据：JSON 键全 miss，再扫响应体前 8KB 的带引号字面量（全能签同款双保险）
        if let body, let key = literalEnvelopeKey(in: body),
           let b64 = root[key] as? String, !b64.isEmpty {
            LoginLogger.shared.log("\(SignSourceClient.logTag) 信封键 \(key) 由前 8KB 字面量扫描命中（辅判据）",
                                   category: .signSource)
            return try unwrapOrDecrypt(key: key, base64: b64)
        }
        return nil
    }

    /// 命中键后统一处理：先探明文封装（C1），否则走 RSA（A/B）。
    private static func unwrapOrDecrypt(key: String, base64 b64: String) throws -> Data {
        // ① 明文封装探测（C1）：base64 解码后能解析成 JSON ⇒ 无加密，直接返回
        if let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
           looksLikePlainJSON(decoded) {
            LoginLogger.shared.log("\(SignSourceClient.logTag) 信封键 \(key) = base64(json) 明文封装（C1）",
                                   category: .signSource)
            return decoded
        }
        // ② 否则走 RSA（A/B）；非 256 对齐 → decrypt 内抛 .unsupportedCipher（C2/D）
        return try decrypt(base64Ciphertext: b64)
    }

    /// 辅判据：扫响应体**前 8KB**，找带引号的候选键字面量（`"appstore_v1"` 等）。
    /// 复刻全能签 `rangeOfString:` 扫描（§4.2）。仅在 JSON 键查找全 miss 时兜底。
    private static func literalEnvelopeKey(in body: Data) -> String? {
        let head = body.prefix(8192)
        for key in envelopeKeys where head.range(of: Data("\"\(key)\"".utf8)) != nil { return key }
        return nil
    }

    /// base64(密文) → 明文 Data（**整源两轮试解**：PKCS#1 优先 → raw 兜底）。
    ///
    /// ★ **判别粒度 = 整条源**（填充模式是**源的属性**、不是**块的属性**），
    ///   故**不是**逐块判别 —— 逐块判别会造出「块间模式不一致」这个本不该存在的状态。
    ///
    /// 流程：
    /// ① 逐 256B 用 `.rsaEncryptionRaw` 拿 256B **原块**（**密文只解一次**，模幂只做一遍）；
    /// ② **第一轮**：全部块按 **PKCS#1 v1.5** 反填充 → 拼接 → 整源 JSON 解析成功 ⇒ 用；
    /// ③ 否则 **第二轮**：全部块按 **raw** 反填充 → 拼接 → 整源 JSON 解析成功 ⇒ 用；
    /// ④ 两轮都失败 ⇒ 判「源格式不支持」，日志**区分三种失败**（见 `explainFailure`）。
    static func decrypt(base64Ciphertext: String) throws -> Data {
        guard let key = loadPrivateKey() else { throw SignSourceError.rsa("私钥不可用") }
        guard let cipher = Data(base64Encoded: base64Ciphertext,
                                options: .ignoreUnknownCharacters) else {
            throw SignSourceError.rsa("密文不是合法 base64")
        }
        let block = SecKeyGetBlockSize(key)          // 256（2048-bit）
        guard block > 0 else { throw SignSourceError.rsa("私钥块大小异常") }
        // ★ 非 256 对齐 ⇒ 不是 RSA 分块 ⇒ 判为「未知/流密码源」**优雅降级**（§4.8）
        //   生态普查实证：键 `appstore`（无版本后缀）的载荷 %256 = 113/112/117、熵 7.97
        //   ⇒ 若强行按块解会两轮全失败；这里提前分流，**不崩、不误判成 PKCS1**。
        guard cipher.count % block == 0 else {
            throw SignSourceError.unsupportedCipher(
                "密文 \(cipher.count) B 非 \(block) 整数倍（疑流密码/Base62 源）")
        }
        // ① 密文只解一次：逐块 raw 拿 256B 原块（不做填充判断）
        var blocks: [Data] = []
        var off = 0
        while off < cipher.count {
            let chunk = cipher.subdata(in: off..<(off + block))
            var err: Unmanaged<CFError>?
            guard let out = SecKeyCreateDecryptedData(key, .rsaEncryptionRaw, chunk as CFData, &err) else {
                throw SignSourceError.rsa("分块解密失败：\(err?.takeRetainedValue() as Error? as Any)")
            }
            blocks.append(out as Data)               // 256B
            off += block
        }
        // ② 第一轮：全块 PKCS#1 v1.5 → 拼接 → 整源 JSON
        if let plain = assemblePKCS1(blocks), isJSON(plain) {
            LoginLogger.shared.log("\(SignSourceClient.logTag) RSA 解密完成：mode=pkcs1, \(blocks.count) 块",
                                   category: .signSource)
            return plain
        }
        // ③ 第二轮：全块 raw（扫首个 0x00）→ 拼接 → 整源 JSON
        if let plain = assembleRaw(blocks), isJSON(plain) {
            LoginLogger.shared.log("\(SignSourceClient.logTag) RSA 解密完成：mode=raw, \(blocks.count) 块",
                                   category: .signSource)
            return plain
        }
        // ④ 两轮都失败 → 判「源格式不支持」，区分三种失败
        throw SignSourceError.rsa(explainFailure(blocks))
    }

    /// 第一轮：全块按 PKCS#1 v1.5 反填充（校验 `00 02` 头 + PS 全非零 + 分隔符）。
    /// 任一块不满足 ⇒ 返回 nil（**整轮放弃**，不半途拼接）。
    private static func assemblePKCS1(_ blocks: [Data]) -> Data? {
        var out = Data()
        for em in blocks {
            guard em.count >= 11 else { return nil }
            let i0 = em.startIndex
            guard em[i0] == 0x00, em[em.index(i0, offsetBy: 1)] == 0x02 else { return nil }  // ① 块头不是 00 02
            let psStart = em.index(i0, offsetBy: 2)
            guard let sep = em[psStart...].firstIndex(of: 0x00) else { return nil }          // 无分隔符
            let ps = em[psStart..<sep]
            guard ps.count >= 8, !ps.contains(0x00) else { return nil }                      // PS ≥ 8 且全非零
            out.append(em[em.index(after: sep)...])                                          // 分隔符之后的全部字节
        }
        return out
    }

    /// 第二轮：全块按 raw 反填充（从下标 0 扫首个 `0x00`，取其后的字节；无 `0x00` 则整块原样）。
    /// 复刻牛蛙客户端算法（`0xba904 MOV X9,#0` 起扫；`0xba91c MOV W9,#0xFFFFFFFF` = 无 `0x00` 取整块）。
    private static func assembleRaw(_ blocks: [Data]) -> Data? {
        var out = Data()
        for em in blocks {
            if let z = em.firstIndex(of: 0x00) {
                out.append(em[em.index(after: z)...])       // 取其后的全部字节
            } else {
                out.append(em)                              // 无 0x00 ⇒ 整块原样
            }
        }
        return out
    }

    /// 整源 JSON 判别器（防御性剥尾 + UTF-8 + JSON 对象）。剥尾只动末块 padding。
    private static func isJSON(_ data: Data) -> Bool {
        let d = normalizedForJSON(data)
        guard String(data: d, encoding: .utf8) != nil else { return false }                  // ② UTF-8 解不开
        return (try? JSONSerialization.jsonObject(with: d)) is [String: Any]                 // ③ JSON 不合法
    }

    /// 失败日志：**区分三种** —— ① 块头不是 `00 02`  ② 反填充后 UTF-8 解不开  ③ UTF-8 能解但 JSON 不合法。
    private static func explainFailure(_ blocks: [Data]) -> String {
        let pkcs1 = assemblePKCS1(blocks)
        let candidate = pkcs1 ?? assembleRaw(blocks)
        if pkcs1 == nil, let first = blocks.first, first.count >= 2,
           !(first[first.startIndex] == 0x00 && first[first.index(first.startIndex, offsetBy: 1)] == 0x02) {
            return "源格式不支持：① 块头不是 00 02"
        }
        if let c = candidate, String(data: normalizedForJSON(c), encoding: .utf8) == nil {
            return "源格式不支持：② 反填充后 UTF-8 解不开"
        }
        return "源格式不支持：③ UTF-8 能解但 JSON 不合法"
    }

    /// 最终 JSON 解析前的归一化：剥掉尾部 `0x00` / ASCII 空白（末块 padding）。
    static func normalizedForJSON(_ data: Data) -> Data {
        var d = data
        while let last = d.last, last == 0x00 || last == 0x20 || last == 0x0A || last == 0x0D || last == 0x09 {
            d.removeLast()
        }
        return d
    }

    /// 明文封装探测（§4.8 C1）：base64 解码结果能否 UTF-8 可读 **且** 解析成 JSON 对象。
    /// 命中 ⇒ 该信封是「`base64(json)` 无加密」（开源 PHP 面板 opencry=1 分支），直接用；
    /// 未命中 ⇒ 高熵二进制（RSA 密文 / 流密码）⇒ 继续 RSA 或降级。
    /// **无假阳**：C2 流密码密文熵 7.997（≈全随机），不可能解析成合法 JSON。
    private static func looksLikePlainJSON(_ decoded: Data) -> Bool {
        guard String(data: decoded, encoding: .utf8) != nil else { return false }
        return (try? JSONSerialization.jsonObject(with: decoded)) is [String: Any]
    }

    /// PKCS#8 base64 → SecKey（每次调用重建；SecKey 不跨 await 边界，Swift 6 友好）
    private static func loadPrivateKey() -> SecKey? {
        guard let pemBytes = Data(base64Encoded: embeddedPrivateKeyBase64),
              let pem = String(data: pemBytes, encoding: .utf8) else { return nil }
        let body = pem.split(whereSeparator: \.isNewline)
                      .filter { !$0.hasPrefix("-----") }.joined()
        guard let pkcs8 = Data(base64Encoded: body),
              let pkcs1 = pkcs1(fromPKCS8: pkcs8) else { return nil }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,     // ← 私钥
            kSecAttrKeySizeInBits: 2048,
        ]
        var err: Unmanaged<CFError>?
        return SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &err)
    }

    /// PKCS#8 → PKCS#1（剥掉版本 INTEGER + 算法 SEQUENCE + OCTET STRING 外壳，取内层）。
    private static func pkcs1(fromPKCS8 der: Data) -> Data? {
        guard let seq = SignSourceASN1.read(der, 0), seq.tag == 0x30 else { return nil }
        var off = seq.range.lowerBound
        guard let ver = SignSourceASN1.read(der, off), ver.tag == 0x02 else { return nil }   // INTEGER version
        off = ver.next
        guard let alg = SignSourceASN1.read(der, off), alg.tag == 0x30 else { return nil }   // AlgorithmIdentifier
        off = alg.next
        guard let oct = SignSourceASN1.read(der, off), oct.tag == 0x04 else { return nil }   // OCTET STRING
        return der.subdata(in: oct.range)                                                    // = PKCS#1
    }
}
