import Foundation
import Security

/// v0.3.530：爱思服务端「整机生产日期」查询客户端.
///
/// ## 为什么需要它
/// 设备信息面板「生产日期」此前恒显示「未知」. 该值**不在** lockdown / 设备树 / iTunes 域里
/// （iOS 27 已把这些键清空，见 `DeviceInfoService` 里对 `com.apple.mobile.iTunes` 的注释），
/// 只能由爱思服务端按**主板序列号（mlbSerial）**查表返回. 本文件在端侧直接复刻这条查询.
///
/// ## 协议（逆向自 i4Tools 9.21.008.0，2026-09-25 实测 4/4 稳定复现）
/// ```text
/// POST https://app4.i4.cn/getProdate.xhtml
/// Content-Type: application/x-www-form-urlencoded
/// User-Agent:   i4Tools
/// body = base64( RSA_PKCS1v15( json ) )        // 裸 base64，没有 param= 包装
/// json = {"ProductType":"iPhone15,4","SerialNumber":"HP9GNP43P4","mlbSerial":"F3XH89002VT00008LH"}
///  ->  {"code":0,"msg":"Success","data":{"prodate":"2024年07月29日(第31周)"}}
/// ```
///
/// ## 关键事实（都是实测踩过的坑，改动前务必先读）
/// 1. **`mlbSerial` 是唯一决定字段**：`SerialNumber` 留空照样返回真日期；
///    `mlbSerial` 为空则服务端一律回「未知」. 因此本客户端在 `mlbSerial` 缺失时
///    **直接放弃请求**（既拿不到结果，又白白把序列号发出去）.
/// 2. **body 必须是裸 base64**：包成 `param=<b64>` / 明文 JSON / 普通 form
///    一律回 `{"code":-1,"data":"Service Exception"}`；空 body / GET 回 `Parameter exception`.
/// 3. RSA 是 **1024-bit + PKCS1v15**，明文是 jsoncpp `FastWriter` 的输出：
///    键按 **ASCII 升序**排列、键值间无空格、**末尾带一个 `\n`**.
///    本文件只用三个键，其 ASCII 升序恰好是 `ProductType` < `SerialNumber` < `mlbSerial`
///    （P=0x50 < S=0x53 < m=0x6D），与 FastWriter 的输出逐字节一致.
/// 4. 公钥取自 PC 端 `QCommonPlugins.dll`，**偏移随爱思版本漂移**
///    （实测 0x9abc0 -> 0x9b5e0，但内容是同一把 key）.
///    所以这里**内置**公钥，**不要**改成运行时去读 DLL / 反查偏移.
///
/// ## 隐私与合规（重要）
/// ⚠️ 调用本接口会把设备的 `ProductType` / `SerialNumber` / `mlbSerial`
/// **发送到爱思（第三方，非 Apple）的服务器 `app4.i4.cn`**.
/// 这属于设备标识信息外发，请在用户知情的前提下使用.
/// 本客户端**只调用只读查询接口**，不写任何服务端数据.
///
/// ## 失败策略
/// 无 `mlbSerial` / 公钥解码失败 / 加密失败 / 网络超时 / HTTP 非 200 / JSON 解析失败，
/// 任一情况都**返回 nil**，界面保持「未知」——不弹窗、不崩溃、**不重试**（避免轰炸服务端）.
enum I4ProdateClient {

    // MARK: - 常量

    /// 服务端接口地址（PC 端 i4Tools 的同名接口，无 query 参数）
    private static let endpoint = "https://app4.i4.cn/getProdate.xhtml"

    /// 请求 UA —— 服务端不校验 UA 内容，但保持与爱思客户端一致更稳
    private static let userAgent = "i4Tools"

    /// 超时 9 秒：服务端正常响应在 1 秒内，给足余量又不至于让用户干等
    private static let timeoutSeconds: TimeInterval = 9

    /// RSA 公钥（**PKCS#1 / RSAPublicKey 格式**的 base64，1024-bit）.
    ///
    /// 来源：PC 端 `QCommonPlugins.dll` 偏移 `0x9b5e0`（新版 216 字节）/ `0x9abc0`（旧版），
    /// 两处内容为同一把 key. 原始提取件（PEM/SPKI）：
    /// `_i4_re/_pubkey_from_dll.pem`，其 SPKI DER 的 sha256 =
    /// `6a3e2de6435868beac57fb7d2952899506c440aa0c61ef74515be797b9565d1c`；
    /// 剥掉 X.509 外壳后的 PKCS#1 DER 的 sha256 =
    /// `4cabc704e19438333e2d9b3838455ed0d5f003d97475c518219abfd2dadfe829`.
    ///
    /// 为什么存 PKCS#1 而不是 PEM：`SecKeyCreateWithData` 对 RSA 公钥要求的就是
    /// PKCS#1（与 `SecKeyCopyExternalRepresentation` 的输出同格式），
    /// 直接喂 SPKI/PEM 会得到 `errSecDecode`. 仓库里 `I4StoreClient` 也是同样处理.
    private static let publicKeyPKCS1Base64 =
        "MIGJAoGBANZ77Og3N6MFbtWV67t67uTpJlduEM9wErR1Ow0Vqq3iP4vw560t6ISd1BE2iYqygA6uVcw9U/2Y03H2Ddm3buJbkEUe4pZBar6Bx9Od6SkzSy+DfkvDdktP/yf0ijOt4Nk+vwqpcBe4/GRZQcNVSFxJoTxcN2W5B4mYE1+oibrjAgMBAAE="

    /// 1024-bit RSA + PKCS1v15 的**单段明文上限** = 128 - 11 = 117 字节.
    /// 本请求的 json 固定约 90 字节（三个短字段），单段足够；
    /// 一旦超限说明字段被异常拉长，此时直接放弃（不做分段，避免拼出服务端不认的报文）.
    private static let maxPlaintextBytes = 117

    // MARK: - 对外入口

    /// 查询整机生产日期.
    ///
    /// - Parameters:
    ///   - productType:  机型标识（`hw.machine`，如 `iPhone15,4`）. 服务端可空，带上无妨.
    ///   - serialNumber: 整机序列号（lockdown `SerialNumber`）. 服务端可空.
    ///   - mlbSerial:    主板序列号（lockdown `MLBSerialNumber`）—— **唯一决定字段**，缺失即放弃.
    /// - Returns: 服务端原样返回的日期串（如 `2024年07月29日(第31周)`）；
    ///            任何失败返回 `nil`（调用方保持「未知」）.
    static func fetch(productType: String,
                      serialNumber: String?,
                      mlbSerial: String?) async -> String? {
        // mlbSerial 是唯一决定字段：没有它服务端只会回「未知」，没必要发请求.
        guard let mlbSerial, !mlbSerial.isEmpty else { return nil }

        let json = makeJSON(productType: productType,
                            serialNumber: serialNumber,
                            mlbSerial: mlbSerial)
        guard let body = encryptBase64(json) else { return nil }
        guard let request = makeRequest(body: body) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parseProdate(data)
        } catch {
            // 超时 / 断网 / TLS 失败一律静默：界面保持「未知」，不重试.
            return nil
        }
    }

    // MARK: - 报文构造

    /// 拼出 jsoncpp `FastWriter` 等价的 json 字符串（**键 ASCII 升序**、无空格、末尾 `\n`）.
    ///
    /// 顺序写死为 ProductType -> SerialNumber -> mlbSerial，即这三个键的 ASCII 升序.
    /// 若日后新增键，必须按 ASCII 升序重新插入，否则服务端会判 `Service Exception`.
    private static func makeJSON(productType: String,
                                 serialNumber: String?,
                                 mlbSerial: String) -> String {
        let pt = jsonEscaped(productType)
        let sn = jsonEscaped(serialNumber ?? "")
        let mlb = jsonEscaped(mlbSerial)
        return "{\"ProductType\":\"\(pt)\",\"SerialNumber\":\"\(sn)\",\"mlbSerial\":\"\(mlb)\"}\n"
    }

    /// 最小 JSON 字符串转义，对齐 jsoncpp `FastWriter` 的行为.
    /// 序列号/机型名正常都是字母数字，这里是防御性处理（防止引号或反斜杠拼坏报文）.
    /// 用码点（UInt32）匹配而非字符字面量，避免 `Unicode.Scalar` 字面量匹配的歧义.
    private static func jsonEscaped(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""          // 双引号
            case 0x5C: out += "\\\\"          // 反斜杠
            case 0x0A: out += "\\n"           // 换行
            case 0x0D: out += "\\r"           // 回车
            case 0x09: out += "\\t"           // 制表
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// RSA PKCS1v15 加密 -> 裸 base64.
    /// 全部在函数内完成，`SecKey` 不跨 await / actor 边界，天然满足 Swift 6 并发检查.
    private static func encryptBase64(_ plain: String) -> String? {
        guard let plainData = plain.data(using: .utf8),
              plainData.count <= maxPlaintextBytes else { return nil }
        guard let keyData = Data(base64Encoded: publicKeyPKCS1Base64) else { return nil }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData,
                                             attributes as CFDictionary,
                                             &keyError) else { return nil }

        var encryptError: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(key,
                                                     .rsaEncryptionPKCS1,
                                                     plainData as CFData,
                                                     &encryptError) else { return nil }
        return (cipher as Data).base64EncodedString()
    }

    /// 组 POST 请求：body 就是**裸 base64**（不是 form 字段）.
    private static func makeRequest(body: String) -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    // MARK: - 响应解析

    /// 取 `data.prodate`. 失败/异常响应（如 `data` 是 `"Service Exception"` 字符串）返回 nil.
    private static func parseProdate(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let prodate = payload["prodate"] as? String else { return nil }
        let trimmed = prodate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
