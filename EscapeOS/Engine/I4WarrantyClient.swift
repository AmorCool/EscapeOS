import Foundation
import Security

/// v0.3.531：爱思服务端「保修期限」查询客户端.
///
/// ## 为什么需要它
/// 设备信息面板「保修期限」此前恒为空（`-`）. 该值**不在** lockdown / 设备树 / iTunes 域里
/// （`cache/<SN>_info.txt` 的 91 个键里没有任何 `warranty` / `coverage` / `warDate`），
/// 只能由爱思服务端按**整机序列号（lockdown `SerialNumber`）**查表返回. 本文件在端侧复刻这条查询.
///
/// ## 协议（逆向自 i4Tools 9.21.008，2026-09-25 实测 4/4 稳定复现）
/// ```text
/// POST https://app4.i4.cn/getSerialWarrantyTime.xhtml?pc_vs=9.21.008
/// Content-Type: text/plain                       <-- 【关键】唯一真正的卡点
/// body = base64( RSA_PKCS1v15( json ) )          // 裸 base64，没有 param= 包装
/// json = {"pc_vs":"9.21.008","serial":"HP9GNP43P4"}\n
///  ->  {"code":0,"msg":"Success","data":{"toRequest":0,"toRequestType":0,
///        "warrantyTime":"已过保修期","warrantyDetail":"已过保修期"}}
/// ```
///
/// ## 关键事实（都是实测踩过的坑，改动前务必先读）
/// 1. **`Content-Type` 必须是 `text/plain`**（或 `application/json`）：
///    爱思 PC 端走 libcurl 时把该头写死为 `text/plain`；换成
///    `application/x-www-form-urlencoded` 服务端一律回 `{"code":1,"msg":"参数异常"}`.
///    这正是此前沿用生产日期那套头一直没打通的原因 —— **不是参数名错，是 Content-Type 错**.
/// 2. **`serial` 必须是设备 SN（lockdown `SerialNumber`），不是 MLB**：
///    传 MLB / 电池 SN 会得到 `toRequestType:3` + 空 `warrantyTime`（爱思库里没有该 SN）.
///    因此本客户端在 SN 缺失时**直接放弃请求**（既拿不到结果，又白白把序列号发出去）.
/// 3. **body 必须是裸 base64**：明文 JSON / 包成 `param=<b64>` 一律回「参数异常」.
/// 4. RSA 是 **1024-bit + PKCS1v15**，单段明文上限 117 字节. 本请求只有两个短字段
///    （SN 12 位时明文 43 字节），单段足够；超限说明字段被异常拉长，此时直接放弃（不分段，
///    避免拼出服务端不认的报文）.
/// 5. 公钥与 `getProdate` **完全同一把** —— PC 端 `QCommonPlugins.dll` 里
///    `createPKeyDevValidation(false)` 返回的 1024-bit 公钥.
///    ⚠️ 那个函数有**两把** key，`true` 是另一把，别取错.
///    这里**内置**公钥，**不要**改成运行时去读 DLL / 反查偏移（偏移随爱思版本漂移）.
///
/// ## 隐私与合规（重要）
/// ⚠️ 调用本接口会把设备的**整机序列号（`SerialNumber`）发送到爱思（第三方，非 Apple）
/// 的服务器 `app4.i4.cn`**. 这属于设备标识信息外发.
/// 本客户端**只调用只读查询接口**，**绝不**调用 `putSerialWarrantyTime.xhtml`（写库接口）.
///
/// ## 失败策略
/// 无 SN / 公钥解码失败 / 加密失败 / 网络超时 / HTTP 非 200 / JSON 解析失败 / 服务端空值，
/// 任一情况都**返回 nil**，界面保持原来的 `-` —— 不弹窗、不崩溃、**不重试**（避免轰炸服务端）.
enum I4WarrantyClient {

    // MARK: - 常量

    /// 服务端接口地址. `pc_vs` 服务端不校验（带 / 不带 / 不同版本均 200），保持与爱思 9.21.008 一致.
    private static let endpoint = "https://app4.i4.cn/getSerialWarrantyTime.xhtml?pc_vs=9.21.008"

    /// 请求体里回带的客户端版本，与 URL 的 `pc_vs` 一致.
    private static let pcVersion = "9.21.008"

    /// 请求 UA —— 服务端不校验 UA 内容（实测 `i4Tools` / 伪 IE 均可），保持与爱思客户端一致更稳.
    private static let userAgent = "i4Tools"

    /// 超时 9 秒：服务端正常响应在 1 秒内，给足余量又不至于让用户干等.
    private static let timeoutSeconds: TimeInterval = 9

    /// RSA 公钥（**PKCS#1 / RSAPublicKey 格式**的 base64，1024-bit），与爱思 `getProdate` 接口**同一把**.
    ///
    /// 来源：PC 端 `QCommonPlugins.dll`（`createPKeyDevValidation(false)`），
    /// 原始提取件 `_i4_re/_pubkey_from_dll.pem`；
    /// 剥掉 X.509 外壳后的 PKCS#1 DER 的 sha256 =
    /// `4cabc704e19438333e2d9b3838455ed0d5f003d97475c518219abfd2dadfe829`.
    ///
    /// 为什么存 PKCS#1 而不是 PEM：`SecKeyCreateWithData` 对 RSA 公钥要求的就是
    /// PKCS#1（与 `SecKeyCopyExternalRepresentation` 的输出同格式），
    /// 直接喂 SPKI/PEM 会得到 `errSecDecode`. 仓库里 `I4StoreClient` 也是同样处理.
    private static let publicKeyPKCS1Base64 =
        "MIGJAoGBANZ77Og3N6MFbtWV67t67uTpJlduEM9wErR1Ow0Vqq3iP4vw560t6ISd1BE2iYqygA6uVcw9U/2Y03H2Ddm3buJbkEUe4pZBar6Bx9Od6SkzSy+DfkvDdktP/yf0ijOt4Nk+vwqpcBe4/GRZQcNVSFxJoTxcN2W5B4mYE1+oibrjAgMBAAE="

    /// 1024-bit RSA + PKCS1v15 的**单段明文上限** = 128 - 11 = 117 字节.
    private static let maxPlaintextBytes = 117

    // MARK: - 对外入口

    /// 查询整机保修期限.
    ///
    /// - Parameter serialNumber: 整机序列号（lockdown `SerialNumber`）—— **唯一关键字段**，缺失即放弃.
    /// - Returns: 服务端原样返回的 `warrantyTime` 串（如 `已过保修期`）；
    ///            任何失败返回 `nil`（调用方保持原来的 `-`）.
    static func fetch(serialNumber: String?) async -> String? {
        // SN 是唯一关键字段：没有它服务端只会回 `toRequestType:3` + 空值，没必要发请求.
        guard let serialNumber, !serialNumber.isEmpty else { return nil }

        let json = makeJSON(serial: serialNumber)
        guard let body = encryptBase64(json) else { return nil }
        guard let request = makeRequest(body: body) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parseWarrantyTime(data)
        } catch {
            // 超时 / 断网 / TLS 失败一律静默：界面保持 `-`，不重试.
            return nil
        }
    }

    // MARK: - 报文构造

    /// 拼出明文 JSON（键值间无空格、末尾带一个 `\n`）.
    ///
    /// 爱思用的是 `Json::toStyledString()`（缩进多行），但实测**紧凑形态同样被接受**，
    /// 这里用紧凑形态以省明文长度（1024-bit 上限 117 字节）.
    private static func makeJSON(serial: String) -> String {
        "{\"pc_vs\":\"\(pcVersion)\",\"serial\":\"\(jsonEscaped(serial))\"}\n"
    }

    /// 最小 JSON 字符串转义. 序列号正常都是字母数字，这里是防御性处理
    /// （防止引号 / 反斜杠 / 控制字符把报文拼坏）.
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

    /// 组 POST 请求：`Content-Type: text/plain`（【关键】），body 就是**裸 base64**（不是 form 字段）.
    private static func makeRequest(body: String) -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    // MARK: - 响应解析

    /// 取 `data.warrantyTime`. 失败/异常响应（`data` 为空串或非字典）返回 nil.
    ///
    /// ⚠️ 只做 trim + 非空判断，**不解析日期、不重新格式化**：
    /// 未过保的格式本机没有设备可验（只有一台已过保真机），原样透传才能保证与爱思显示逐字一致.
    private static func parseWarrantyTime(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let warranty = payload["warrantyTime"] as? String else { return nil }
        let trimmed = warranty.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
