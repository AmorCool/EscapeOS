import Foundation
import CommonCrypto
import Compression

/// 免登录下载商店的**第三来源** —— NB（NB Pro，bundle id `com.nbmaster.app`，主二进制 `XNZS`）。
///
/// **NB 与「牛蛙」是两个不同的源，不要混淆**（用户 2026-10-01 纠正）。
/// 与接口一（爱思，见 `I4PCStoreClient`）、接口二（牛蛙 NiuWaCore，见 `NiuwaStoreClient`）并列，
/// 但 NB 是**独立第三方**：服务器、协议、加密全不一样：
///
/// | | 牛蛙 NiuWaCore（第二源） | NB Pro（本文件，第三源） |
/// |---|---|---|
/// | 主二进制 | `NiuwaCore` | `XNZS` |
/// | 基址 | `https://api.ios222.com` | `http://124.222.32.246` 等（domain.txt 下发） |
/// | 加密 | AES-256-GCM | **AES-128-CBC + PKCS7** |
/// | 报文 | base64(密文‖tag)+base64(N) | 请求 hex（E→-，FF→.）/ 响应标准 base64 |
///
/// 注意：NB 服务端的错误文案里自称「牛蛙助手」（见下方 `请将牛蛙助手更新到最新版`），
/// 但那只是它的文案，**不改变两者是独立源**的事实。
///
/// ## 协议来源（全部 IDA 反编译确证，非推测）
///
/// 主二进制 `XNZS`（57,100,512 字节，cryptid=0 未加密），关键函数：
/// - `sub_100004dc0` `+[DXBaseViewUtils xnS2CreateItemView:pav:titles:bk1:bk2:]` —— POST 主入口
/// - `sub_1000046f4` —— 公共参数注入
/// - `sub_100005094` —— 请求体加密 + 大写 hex + 两次字符串替换
/// - `sub_1000042ac` —— 密钥派生 + `CCCrypt`
/// - `sub_100004000` —— 通用字符串替换（`src, find, replace`）
///
/// ## 请求形态
/// ```
/// POST {domain}{pav}          // pav 为空时回落 {domain}/nb/app
/// Content-Type: text/plain
/// body = 加密({"method": "nb9527_<action>", "params": {公共参数…, 业务参数…}})
/// ```
///
/// ## 版本闸门（不移植）
/// 服务端在公共参数不全时会回 `请将牛蛙助手更新到最新版再试`。
/// 这不是"必须升级客户端"，**只是公共参数没带齐** —— 补齐 `pub` 那一组即放行。
/// 本实现**不搬**任何版本检测逻辑。
enum NBStoreClient {

    // MARK: - 常量

    /// 服务器列表（`domain.txt` 由 gitee/gitlab 明文下发；首条为 2026-10-01 抓包实测命中）
    static let hosts = [
        "http://47.243.71.210:9527",
        "http://124.222.32.246",
        "http://117.72.39.157:9527",
        "http://nbtool8.com:9666",
    ]

    /// 当前使用的基址（首个可用的）
    static var host: String { hosts[0] }

    static let logTag = "[NB源]"

    /// 响应体打进日志的上限
    private static let logBodyLimit = 2000

    // MARK: - 加解密

    /// NB 的报文加解密。
    ///
    /// ## 密钥派生（`sub_1000042AC`，逐行还原）
    /// ```c
    /// v4 = NSData(base64: "UmZnOVRHVXNVcld5M01QVA==")   // "Rfg9TGUsUrWy3MPT"
    /// v6 = sub_100004000(v5, "T", "i")                  // 字符串替换：T -> i
    /// v8 = v6 + "nbsigner"
    /// CC_MD5(v8, md, 16)
    /// v11 = hex(md)          // 32 字符小写 hex
    /// v12 = v11[0:16]        // key
    /// v14 = v11[16:32]       // iv
    /// CCCrypt(op, kCCAlgorithmAES, kCCOptionPKCS7Padding, md, 16, v14, ...)
    /// ```
    ///
    /// **易错点**：`CCCrypt` 的 key 参数传的是 `md` 缓冲区 —— 而该缓冲区此前被
    /// `getCString` 写入了 `v12`（hex 前 16 字符）。所以
    /// **key 是 hex 字符串本身（16 字节 ASCII），不是 MD5 的原始 16 字节**。
    /// 两者只差一次 hex 编码，写错会得到完全不同的密文。
    enum Crypto {

        /// 明文种子（base64 常量，来自二进制）
        private static let seedB64 = "UmZnOVRHVXNVcld5M01QVA=="

        /// 派生 (key, iv)。两者都是 16 字节 UTF8（AES-128）。
        static func deriveKeyIV() -> (key: Data, iv: Data) {
            let seed = String(data: Data(base64Encoded: seedB64) ?? Data(), encoding: .utf8) ?? ""
            let seed2 = seed.replacingOccurrences(of: "T", with: "i")
            let md5hex = md5Hex(seed2 + "nbsigner")
            let key = String(md5hex.prefix(16))
            let iv = String(md5hex.dropFirst(16).prefix(16))
            return (Data(key.utf8), Data(iv.utf8))
        }

        /// MD5 的小写十六进制串
        static func md5Hex(_ s: String) -> String {
            let d = Data(s.utf8)
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            d.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(d.count), &digest) }
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        /// 明文 → 可发送的报文串。
        ///
        /// 请求侧的两次替换由 `sub_100005094` 完成，常量已从汇编确认：
        /// `aE`="E"→"-"、`aFf`="FF"→"."（顺序不可颠倒）。
        static func encrypt(_ plain: Data) -> String? {
            let (key, iv) = deriveKeyIV()
            guard let ct = aesCBC(plain, key: key, iv: iv, encrypt: true) else { return nil }
            return ct.map { String(format: "%02x", $0) }.joined()
                .uppercased()
                .replacingOccurrences(of: "E", with: "-")
                .replacingOccurrences(of: "FF", with: ".")
        }

        /// 报文串 → 明文。
        ///
        /// **响应侧是 `gzip( base64( AES密文 ) )`** —— 服务端响应头带
        /// `Content-Encoding: gzip`。若 URLSession 已自动解压（默认会），
        /// 进来的就是纯 base64；若拿到的是原始字节，则需先 gunzip。
        /// 两种都兼容。
        static func decrypt(_ s: String) -> Data? {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw = Data(base64Encoded: trimmed,
                                 options: [.ignoreUnknownCharacters]) else { return nil }
            let (key, iv) = deriveKeyIV()
            return aesCBC(raw, key: key, iv: iv, encrypt: false)
        }

        /// 原始响应字节 → 明文。自行处理 gzip 外壳（不依赖 URLSession 的自动解压）。
        static func decrypt(responseBody data: Data) -> Data? {
            var body = data
            if body.count > 2, body[body.startIndex] == 0x1f,
               body[body.startIndex + 1] == 0x8b {
                guard let inflated = gunzip(body) else { return nil }
                body = inflated
            }
            let s = String(data: body, encoding: .utf8) ?? ""
            return decrypt(s)
        }

        /// gzip 解压（只取 deflate 段交给 Compression，跳过 gzip 头尾）。
        static func gunzip(_ data: Data) -> Data? {
            guard let deflate = gzipPayload(data) else { return nil }
            return inflate(deflate)
        }

        /// 定位 gzip 里的 deflate 数据段（跳过 10 字节固定头 + 可选扩展字段）。
        private static func gzipPayload(_ d: Data) -> Data? {
            guard d.count > 18 else { return nil }
            let b = [UInt8](d)
            guard b[0] == 0x1f, b[1] == 0x8b, b[2] == 0x08 else { return nil }
            let flg = b[3]
            var i = 10
            if flg & 0x04 != 0 {                        // FEXTRA
                guard i + 2 <= b.count else { return nil }
                let xlen = Int(b[i]) | (Int(b[i + 1]) << 8)
                i += 2 + xlen
            }
            if flg & 0x08 != 0 {                        // FNAME
                while i < b.count, b[i] != 0 { i += 1 }
                i += 1
            }
            if flg & 0x10 != 0 {                        // FCOMMENT
                while i < b.count, b[i] != 0 { i += 1 }
                i += 1
            }
            if flg & 0x02 != 0 { i += 2 }               // FHCRC
            guard i < b.count - 8 else { return nil }
            return d.subdata(in: (d.startIndex + i)..<(d.endIndex - 8))
        }

        /// raw deflate → 明文
        private static func inflate(_ deflate: Data) -> Data? {
            guard !deflate.isEmpty else { return nil }
            let cap = max(deflate.count * 8, 64 * 1024)
            var out = Data(count: cap)
            let n = out.withUnsafeMutableBytes { outBuf -> Int in
                deflate.withUnsafeBytes { inBuf -> Int in
                    guard let src = inBuf.bindMemory(to: UInt8.self).baseAddress,
                          let dst = outBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dst, cap, src, deflate.count, nil,
                                                     COMPRESSION_ZLIB)
                }
            }
            guard n > 0 else { return nil }
            out.removeSubrange(n..<out.count)
            return out
        }

        /// AES-128-CBC + PKCS7（走 CommonCrypto，与客户端同款）
        private static func aesCBC(_ data: Data, key: Data, iv: Data, encrypt: Bool) -> Data? {
            let outCap = data.count + kCCBlockSizeAES128
            var out = Data(count: outCap)
            var moved = 0
            let status = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
                data.withUnsafeBytes { inBuf in
                    key.withUnsafeBytes { keyBuf in
                        iv.withUnsafeBytes { ivBuf in
                            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                                    CCAlgorithm(kCCAlgorithmAES),
                                    CCOptions(kCCOptionPKCS7Padding),
                                    keyBuf.baseAddress, key.count,
                                    ivBuf.baseAddress,
                                    inBuf.baseAddress, data.count,
                                    outBuf.baseAddress, outCap,
                                    &moved)
                        }
                    }
                }
            }
            guard status == kCCSuccess else { return nil }
            out.removeSubrange(moved..<out.count)
            return out
        }
    }

    // MARK: - 公共参数

    /// 冷缓存时的**占位 UDID**（不阻塞、发出去也算合法请求）。
    ///
    /// ## 为什么可以有占位（本会话受控实验复现）
    /// NB 服务端对 `searchOffSaleApp`（下架搜索）与 `getAppHistoryList`（取包）
    /// **完全忽略 `udid`**：
    /// - 搜索：真 / 假A / 假B / 空 / 畸形 五种输入 **5/5 均 `code=0`**，结果**逐字段相同**；
    /// - 取包：五种输入 **5/5 均 `code=0`**；url/sinf 的差异经「同一真 udid 连发 3 次」
    ///   验证为**每次请求的随机量**（3 次 url/sinf 各不相同），与 udid 无关；
    ///   偶发的 `code=7` 在真 udid 上也会出现 ⇒ 服务端偶发，非 udid 所致。
    /// （脚本：`P4_全能签逆向/_工作区/验证脚本/nb_search_udid_probe.py`）
    ///
    /// ⇒ **搜索、取包都不需要真设备身份**。占位值只需「非空」，用全 0 便于日志一眼识别。
    private static let placeholderUDID = "00000000-0000000000000000"

    /// 请求体里的 `udid` —— 有本机真值就用真值，取不到就由调用方回落到 `placeholderUDID`。
    ///
    /// ## 取值链路（与全项目其它地方一致，都走 `LocalDeviceIdentity`）
    /// ① 缓存已热 → 本函数返回真 UDID；
    /// ② 缓存冷 → 本函数返回 nil，调用方（`perform`）**用 `placeholderUDID` 直接发出**，
    ///    **不 await、不等隧道**（这是本会话的核心修复，见下）。
    ///
    /// ## 修 P0（三轮）
    ///
    /// - **第一轮（不完整）**：这里原来同步调 `LocalDeviceIdentity.load()` 建 RSD 隧道。
    ///   本工程开了 `SWIFT_APPROACHABLE_CONCURRENCY`（SE-0461 `NonisolatedNonsendingByDefault`，
    ///   `project.yml:172`）⇒ `nonisolated async` 的 `perform` 跑在调用者 MainActor 上
    ///   ⇒ 建隧道落在主线程 ⇒ UI 全局卡死（真机实测单次阻塞 150,311ms / 225,070ms，进程未崩）。
    ///   照牛蛙源 `NiuwaStoreClient.swift:433-441` 的先例改成「只吃缓存」，冷缓存直接返回 nil。
    /// - **第二轮（过度）**：只吃缓存 ⇒ 冷缓存首次搜索必失败，用户不接受；遂改为
    ///   **异步等待就绪**（`awaitRealUDID()` 最多 12s，超时抛 `.deviceNotReady`）。
    /// - **第三轮（本会话，正解）**：等待把「搜个下架应用」这种**不需要身份**的操作
    ///   绑死在「隧道是否就绪」上 —— 隧道起不来时搜索被一起拖死（用户原话：
    ///   「之前只是下架应用无法下载，你改了之后越改越差」）。**既然服务端忽略 udid，
    ///   搜索就不该等隧道** ⇒ 删掉 `awaitRealUDID()` 与 `.deviceNotReady`，
    ///   冷缓存直接用占位发出；后台仍挂一次 `warmUpInBackground()`（幂等、不 await），
    ///   让下一次请求自然用上真 udid。
    ///
    /// ## 旧归因的更正（保留以免重犯）
    /// v0.3.545 曾把「NB 源下的包装上闪退」归因为「伪 UDID → sinf 与本机不匹配」，
    /// **已被实验推翻**：服务端忽略 udid，真因是 **hex 被当 base64** 的编码损坏
    /// （sinf 被写成 1.5 倍垃圾字节，v0.3.563 修复）。**与 udid / 本机硬件无关。**
    /// v0.3.554 另修了一个上游 bug：`LocalDeviceIdentity` 曾把 lockdown 键名写成
    /// `UniqueDeviceIdentifier`（真实键 `UniqueDeviceID`），两条路都取不到 —— 已修正。
    private static func cachedRealUDID() -> String? {
        guard let udid = LocalDeviceIdentity.cachedSnapshot()?.udid,
              !udid.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return udid
    }

    /// 公共参数 —— 就是 NB 的"免登录"身份，没有 token / Authorization / uid。
    ///
    /// 这一组**必须齐**，否则服务端回「请更新到最新版」（那是闸门，不是真要求升级）。
    /// 字段与取值来自 `sub_1000046F4` 反编译。
    ///
    /// ## v0.3.540 修复：**字典字面量里的重复键会让 App 直接崩**
    ///
    /// 原实现把 `phoneName` / `deviceType` / `productType` 各写了**两遍**。
    /// Swift 的字典字面量遇到重复键不是"后者覆盖前者"，而是编译期插入
    /// `_preconditionFailure` —— 运行到这里就是
    /// `Fatal error: Dictionary literal contains duplicate keys`，**进程当场死**。
    ///
    /// 这正是「点 NB 源获取就闪退」的真因：任何 NB 请求的第一步都是构造这一组参数，
    /// 所以还没轮到发 HTTP 就崩了 —— 也解释了为什么日志里 `[NB源]` 一行都没有
    /// （崩溃发生在 `LoginLogger.log("→ POST …")` 之前）。
    ///
    /// 改为在**构造后再赋值**：先建好不发重复键的基底，缺省值用下标写回，
    /// 这样即使将来再加字段也不会重复触发这个坑。
    /// - Parameter realUDID: 调用方（`perform`）传入的 `udid` —— 有本机真值就是真值，
    ///   冷缓存则是 `placeholderUDID`；本函数只负责塞进参数，不判空、不阻塞。
    private static func pubParams(iPad: Bool, udid realUDID: String) -> [String: Any] {
        // v0.3.590：`udid` 由 `perform` 决定 —— 有缓存用真值，否则用 `placeholderUDID`。
        // 服务端**完全忽略 udid**（搜索/取包 5/5 code=0，见 `placeholderUDID` 注释），
        // 所以这里不再要求非空、更不在这里等隧道。
        //
        // 旧归因更正：曾担心「伪 UDID 换回的 sinf 与本机不匹配」，该因果已被受控实验证伪
        // （NB 服务端忽略 udid）。真机闪退的真因是 hex 被当 base64 的编码损坏（v0.3.563 修复）。
        // 实测抓包值（2026-10-01 / 10-02）：客户端 3.9.1 / build 1。
        // 与请求体里的 appVersion 是同一个值，服务端会校验，勿随意改小。
        var p: [String: Any] = [
            "mainBundleID": "com.nbmaster.app",
            // v0.3.554：真机发的是**布尔** `false`，原来写的是整数 `0`。
            // 逐字段对齐真机抓包，别让类型差异成为服务端判参数不合法的理由。
            "mainEmbedded": false,
            "apiVersion": "1.0",
            "version": "3.9.1",
            "build": "1",
            "appVersion": "3.9.1",
            "osVersion": UIDevice.current.systemVersion,
            "udid": realUDID,
            "lang": "zh-cn",
            // v0.3.554：真机两次抓包都是字面量 `"iPhone"`（不是设备名「XX的 iPhone」）。
            // 我们原来发 `UIDevice.current.name`，取值随用户改设备名而变 ——
            // 这属于**身份字段**，客户端自己发的是固定字面量，跟着对齐。
            "phoneName": "iPhone",
            // 机型标识读真机 `hw.machine`（如 `iPhone12,1`）；读不到才兜底。
            "productType": deviceModelIdentifier(),
            "deviceType": iPad ? "iPad" : "iPhone",
        ]
        // 机型标识兜底：`hw.machine` 拿不到时用 `UIDevice` 的机型族，**不再写死 `iPhone12,1`**
        // —— 那是抓包那台设备的值，当常量会让 iPad 请求也报 iPhone 机型。
        if (p["productType"] as? String)?.isEmpty != false {
            p["productType"] = iPad ? "iPad" : "iPhone"
        }
        return p
    }

    /// 机型标识（`hw.machine`，如 `iPhone15,4`）。
    ///
    /// 反编译样本里是 `iPhone12,1`，但那是**抓包那台机器**的值，不是协议常量 ——
    /// 服务端只把它当"这个客户端跑在什么设备上"的信息字段。
    /// 直接读本机 `hw.machine`，取不到才回落到样本值。
    /// 用 `sysctlbyname` 而不是 `uname`，避免 `utsname.machine` 那串 C 数组转字符串的噪音。
    private static func deviceModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    // MARK: - 模型

    /// 历史版本列表里的一项（`getAppHistoryList` 响应）。
    struct NBVersion: Identifiable, Hashable {
        /// App Store 的 `softwareVersionExternalIdentifier`（= NB 的 `appExtId`）
        var externalIdentifier: String
        var version: String
        var releaseTime: String?
        var sizeText: String?
        var id: String { externalIdentifier }
    }

    /// 取件结果（下载接口返回）
    struct NBPackage: Hashable {
        /// 安装包直链（Apple CDN，形如 `…/signed.dpkg.ipa?accessKey=…`）
        var ipaURL: String
        /// base64 的 `.sinf`（安装加密包时必须写回包内 `SC_Info/`）
        var sinfBase64: String?
        var version: String?
        /// v0.3.592：服务端回的真实版本号（`data.metadata.bundleShortVersionString`）。
        /// 供「已回退到 vX.Y.Z」这类提示用；取不到就 nil（界面回落 `version`）。
        var displayVersion: String? = nil
        /// v0.3.592：本包是否**经版本回退**取得（最新版 `code=7` → 换了旧版本命中）。
        /// 界面据此决定要不要给一次「已回退」轻提示（false 时静默，不刷屏）。
        var fellBack: Bool = false
    }

    enum StoreError: Error, LocalizedError {
        case badURL
        case http(Int)
        case decode
        case crypto(String)
        case server(code: String, message: String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址无效"
            case .http(let c): return "请求失败（HTTP \(c)）"
            case .decode: return "响应解析失败"
            case .crypto(let m): return "报文加解密异常：\(m)"
            case .server(let code, let msg):
                return msg.isEmpty ? "服务端返回码 \(code)" : "\(msg)（\(code)）"
            case .network(let m): return "网络错误：\(m)"
            }
        }
    }

    /// 取包失败时，把 NB 的 `code=7` 翻成**用户可读**的结论 —— 界面绝不出现 `code=7` 这类内部码。
    ///
    /// ## 两类成因（2026-10-11 定点实测，StikDebug / appID=6744045754）
    ///
    /// 脚本 `P4_全能签逆向/_工作区/验证脚本/nb_stikdebug_retry.py`：对 `getAppHistoryList`
    /// 的各参数组合各连打 6 次，结果**全部 `code=7`**，msg 只有两种：
    /// - **`未获取到数据`（稳定，主因）** —— NB 库里没有这条 App 的可用 iOS 包。
    ///   StikDebug 的内嵌快照直链（`appStoreData.url`）accessKey 到期 **2025-12-13**、
    ///   实下 `HTTP 403`；现取也回空。⇒ **真的拿不到**，不是 bug、重试无用。
    /// - **`请求异常，参数：，错误：dialing to the given TCP address timed out`（偶发）**
    ///   —— NB 服务端去上游取包时 TCP 超时，属临时故障 ⇒ 稍后重试可能成功。
    ///
    /// ## 更正 v0.3.587 的窄化归因
    ///
    /// v0.3.587 把稳定 `code=7` 归成「都是 Mac App Store 应用（无 iOS 包）」。
    /// **StikDebug 是 iOS 应用**（bundleID `com.stik.sj`、iOS 安装包），同样稳定 `code=7`
    /// ⇒ 稳定 `code=7` 的真实含义是「**NB 库里这条 App 没有可取的包**」，
    /// 与平台无关（快照过期 / 上游无货都会落到这一支）。
    ///
    /// ## 对照组（同一时刻，证「按 App 区分」而非全局故障）
    ///
    /// `appID=6451407032`（官方抓包那条）与 `appID=1517062289` 均 `code=0` 且带**新鲜**直链
    /// （accessKey 到期在未来）；换 `udid` / `osVersion` / `productType` / `country` /
    /// `User-Agent` / 官方抓包身份 / 4 台 host **没有一种**能把 StikDebug 的 7 变成 0。
    enum PackageFailure: Equatable {
        /// NB 库里没有这条 App 的可用安装包（含快照直链已过期）—— 重试无用。
        case notInLibrary
        /// 服务端上游临时故障 —— 稍后重试可能成功。
        case upstreamBusy

        /// 面向用户的文案（英文句点结尾；不含任何内部码）.
        ///
        /// `.notInLibrary` 直接回答「为什么一直修复不了」：**NB 库里这条 App 确实没有可取的包**
        /// （快照直链已过期 + 现取回空），重试无意义，并给一条可走的替代路（另两个源）.
        /// 这是本 App 能给出的最明确答复 —— 不是 bug、不是参数、不是身份问题（见头注释实测）.
        var userMessage: String {
            switch self {
            case .notInLibrary:
                return "该应用在 NB 下架库里没有可用的安装包."
            case .upstreamBusy: return "NB 服务端暂时取不到这个包，请稍后重试."
            }
        }
    }

    /// 把取包抛出的错误归类成 `PackageFailure`；**不是 `code=7` 就回 nil**（交调用方原样处理）。
    ///
    /// 界面侧统一走这里，避免每个页面各自判 `code=7` 时漏判（详情页就曾漏判、把
    /// `未获取到数据（7）` 原样弹给用户）。
    static func packageFailure(from error: Error) -> PackageFailure? {
        guard case StoreError.server(let code, let message) = error, code == "7" else { return nil }
        return isUpstreamBusy(message) ? .upstreamBusy : .notInLibrary
    }

    /// `code=7` 是否属「上游临时故障」——**唯一判据是 msg 里的特征串**。
    /// 其余 `code=7`（含 `未获取到数据`）一律按「库里没包」处理。
    private static func isUpstreamBusy(_ message: String) -> Bool {
        message.contains("dialing") || message.contains("请求异常")
    }

    /// 内嵌快照直链的存活判定（HEAD 探一次）—— v0.3.596.
    ///
    /// 三态**缺一不可**：`.unknown` 存在的意义就是「**判不出绝不判死**」——
    /// 防「判不出 ⇒ 当失败」这类回归（v0.3.588 就是拿 accessKey 时间戳判不出即弃用，
    /// 结果把还能用的链接也丢了，用户「获取不到下载任务」）。
    enum SnapshotLiveness {
        /// 直链还能下（HEAD 200/206）—— 可以用。
        case live
        /// 直链已失效（HEAD 403/404）—— 不能发（发了就是「任务建了、包下不动」）。
        case dead
        /// 判不出（超时 / 网络错 / 其它状态码）—— **保留**，不因判不出而丢弃。
        case unknown
    }

    /// 用 HEAD 探 Apple CDN 直链是否还能下 —— v0.3.596.
    ///
    /// ## 为什么（2026-10-12 实测定案）
    /// `offSalePackage` 现取失败时回落的那条内嵌快照直链，其 `accessKey` **全部已过期**：
    /// 实测（`nb_offsale_url_compare.py`）StikDebug / com.bilibili.inter / live.bilibili.com
    /// 三条 `Range: bytes=0-1048575` **一律 HTTP 403**。而 v0.3.593 无条件 `return embedded`
    /// ⇒ 界面照样建下载任务、URL 是这条死链 ⇒ 进度条出来、包下不动 ⇒ 用户看到「无法下载」。
    ///
    /// ## 探法
    /// 只发 **HEAD**（不拉 body，代价极小）；判据（`t12_probe_head.py` 实测）：
    /// - `200` / `206` ⇒ `.live`（活链 HEAD 200，Range GET 206）
    /// - `403` / `404` ⇒ `.dead`（死链 HEAD 403）
    /// - 其它（超时 / 网络错 / 405 之类）⇒ `.unknown` —— **判不出绝不判死**（防回归）
    private static func probeSnapshot(_ urlString: String) async -> SnapshotLiveness {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return .unknown }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 8
        do {
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 206 { return .live }
            if code == 403 || code == 404 { return .dead }
            return .unknown
        } catch {
            return .unknown
        }
    }

    /// 把「内嵌快照」当**兜底链接**返回 —— **先 HEAD 探活**，死链不发给用户 —— v0.3.596.
    ///
    /// 这是 v0.3.593「现取失败回落内嵌快照」的**收紧版**：保留「有链接优先」的初衷
    /// （探不出就仍给），但**死链（403/404）不再发**（发了 = 有任务下不动 = 用户眼里的「无法下载」）。
    /// 死链返回 `nil`，由调用方按「库里没包」如实处理（与 `PackageFailure.notInLibrary`
    /// 自己的定义「含快照直链已过期」一致 —— v0.3.593 把过期快照当链接发出去，与定义自相矛盾）。
    ///
    /// - Returns: 活链或判不出的快照；**死链返回 `nil`**。
    private static func snapshotFallback(_ embedded: NBPackage?,
                                         app: OffSaleApp,
                                         reason: String) async -> NBPackage? {
        guard let embedded = embedded else { return nil }
        switch await probeSnapshot(embedded.ipaURL) {
        case .live:
            LoginLogger.shared.log("\(logTag) [提示] \(reason)，回落内嵌快照直链"
                                   + "（HEAD 200，可用）（\(app.name)）.", category: .appStore)
            return embedded
        case .unknown:
            LoginLogger.shared.log("\(logTag) [提示] \(reason)，回落内嵌快照直链"
                                   + "（HEAD 判不出，保留）（\(app.name)）.", category: .appStore)
            return embedded
        case .dead:
            LoginLogger.shared.log("\(logTag) [失败] \(reason)，内嵌快照直链已失效（HEAD 403/404），"
                                   + "不再发这条死链（\(app.name)）.", category: .appStore)
            return nil
        }
    }

    // MARK: - 请求

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 发一次请求：加密请求体 → POST → 解密响应。
    ///
    /// `path` 是 `pav`（如 `/nb/appstore-plus`）；为空时服务端回落 `/nb/app`。
    ///
    /// ## v0.3.554 修：`iPad` 默认值从 `true` 改成**自动判定**
    ///
    /// 原来 `iPad: Bool = true`，而四个调用点**没有一个传这个参数** ——
    /// 于是所有 NB 请求都发 `"deviceType":"iPad"`。
    /// 真机抓包（iPhone 11 / iOS 26.0.1）显示 NB 官方客户端发的是
    /// `"deviceType":"iPhone"` + `"productType":"iPhone12,1"`。
    ///
    /// 后果：**下架库是按设备类型分的**，服务端拿 iPad 身份去 iPhone 的下架库里查，
    /// 命中数为 0 —— 表现就是「下架应用怎么搜都搜不到」。
    ///
    /// 现在默认走 `UIDevice` 判定（iPad 才发 iPad），调用方无需再传。
    ///
    /// ## v0.3.590 修：`udid` **不再等待隧道**
    ///
    /// 服务端忽略 `udid`（实验见 `placeholderUDID` 注释）⇒ 本方法**绝不**为取 `udid`
    /// 而 `await` 隧道：缓存热就用真值，冷就用 `placeholderUDID` 直接发。
    /// 这样「搜个下架应用」不再被「隧道是否就绪」拖死（详见下方内联注释）。
    private static func perform(path: String,
                                method: String,
                                params: [String: Any],
                                iPad: Bool? = nil) async throws -> [String: Any] {
        let isPad = iPad ?? (UIDevice.current.userInterfaceIdiom == .pad)
        let url = path.isEmpty ? (host + "/nb/app") : (host + path)
        guard let u = URL(string: url) else { throw StoreError.badURL }

        // v0.3.590：**不再等隧道**。udid 有缓存就用真值，没有就用占位，**永不阻塞这一发**。
        //
        // 依据（受控实验，本会话复现，见 `nb_search_udid_probe.py`）：
        // NB 服务端对 `searchOffSaleApp`（下架搜索）与 `getAppHistoryList`（取包）
        // **完全忽略 `udid`** —— 真 / 假 / 空 / 畸形五种输入，搜索 5/5 均 `code=0`
        // 且结果逐字段相同；取包 5/5 均 `code=0`（url/sinf 的差异经同 udid 连发验证
        // 来自每次请求的随机量，与 udid 无关）。
        //
        // ⇒ **搜索、取包都不需要真设备身份**，也就**不该把「隧道是否就绪」放在关键路径上**：
        //   原来冷缓存时 `await awaitRealUDID()` 最多等 12s，隧道起不来就抛
        //   `.deviceNotReady`，把「搜个下架应用」这种不需要身份的操作也一起弄挂了。
        //   现在改成「有缓存用真值、没有用占位」，后台仍挂 `warmUpInBackground()`（幂等、
        //   不 await），让**下一次**请求能自然用上真 udid。
        let realUDID: String
        if let cached = cachedRealUDID() {
            realUDID = cached
        } else {
            realUDID = placeholderUDID
            LocalDeviceIdentity.warmUpInBackground()   // 幂等：只为下一次请求热缓存，不 await
            LoginLogger.shared.log("\(logTag) [提示] 身份缓存未热，本次请求用占位 UDID 发出"
                                   + "（服务端忽略 udid，不影响搜索/取包）.", category: .appStore)
        }
        var merged = pubParams(iPad: isPad, udid: realUDID)
        for (k, v) in params { merged[k] = v }
        let body: [String: Any] = ["method": "nb9527_" + method, "params": merged]

        guard let plain = try? JSONSerialization.data(withJSONObject: body),
              let sealed = Crypto.encrypt(plain) else {
            throw StoreError.crypto("请求体加密失败")
        }

        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(sealed.utf8)

        LoginLogger.shared.log("\(logTag) → POST \(u) method=nb9527_\(method)", category: .appStore)

        let data: Data
        do {
            let (d, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw StoreError.http(http.statusCode)
            }
            data = d
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.network(error.localizedDescription)
        }

        // 响应体是 gzip(base64(AES))；decrypt(responseBody:) 自行处理 gzip 外壳，
        // 也兼容 URLSession 已自动解压（拿到裸 base64）的情况。
        guard let dec = Crypto.decrypt(responseBody: data),
              let obj = (try? JSONSerialization.jsonObject(with: dec)) as? [String: Any] else {
            let preview = String(data: data.prefix(200), encoding: .utf8)
                ?? data.prefix(200).map { String(format: "%02x", $0) }.joined()
            LoginLogger.shared.log("\(logTag) [失败] 响应解密失败；原始前 200：\(preview)",
                                   category: .appStore)
            throw StoreError.decode
        }

        let code = String(describing: obj["code"] ?? "-")
        let msg = (obj["msg"] as? String) ?? ""
        LoginLogger.shared.log("\(logTag) ← code=\(code) msg=\(truncate(msg))", category: .appStore)

        // code=0 才是成功；其余把服务端原话带出去（用户截图一次即可定案）
        if let n = obj["code"] as? NSNumber, n.intValue != 0 {
            throw StoreError.server(code: code, message: msg)
        }
        return obj
    }

    private static func truncate(_ s: String) -> String {
        s.count <= logBodyLimit ? s : String(s.prefix(logBodyLimit)) + "…（共 \(s.count) 字）"
    }

    // MARK: - 业务

    /// 取指定 App、指定历史版本的安装包信息（IPA 直链 + sinf）。
    ///
    /// ## 这就是「按 `appVerId` 取指定版本」的入口
    /// - 只传 `appID`：回**最新版**的包（实测 2026-10-09 直连：`code=0` + 完整 `url`/`sinf`）。
    /// - 传 `appID` + `appVerId`：回**那个指定版本**的包。
    ///
    /// **对下架 App 一样可用**（此前注释里「那条路是错的」指的是另一个名字相近的
    /// `getOffSaleAppHistoryList`，不是本方法；本方法就是上架通道在用的 `getAppHistoryList`）。
    /// 实测（2026-10-09）：`appID=1517062289` + `appVerId=891589210` → 版本 6.6.0，
    /// 直链 HEAD → HTTP 200。
    ///
    /// ## 典型用法：导入一个 IPA → 用它的 `externalVersionId` 取同版本
    /// 包内 `iTunesMetadata.plist` 的 `softwareVersionExternalIdentifier` 就是 `appVerId`，
    /// `itemId` 就是 `appID` —— 拿这两个值调本方法即可取回**同版本**的包 + sinf，
    /// **不需要任何版本列表**。语义化入口见 `packageByVersion(appID:appVerId:...)`。
    ///
    /// ## 实测报文（2026-10-01 抓包，非推测）
    /// ```
    /// POST http://47.243.71.210:9527/nb/app-downgrade
    /// {"method":"nb9527_getAppHistoryList","params":{
    ///   "plusID":"0", "appID":"6451407032", "appVerId":"889372337",
    ///   "bundleID":"com.phoenix.video", "country":"cn", ...公共参数}}
    /// ```
    /// 响应 `data` = `{ hashMD5, url, sinfs[{id,data,dataHex}] }`，
    /// `url` 直接就是 Apple CDN 的 IPA 直链（`iosapps.itunes.apple.com/itunes-assets/…`），
    /// `sinfs[0].dataHex` 是完整 sinf 授权块。**无需账号、无需 Anisette。**
    ///
    /// ## 关键修正（此前推断有误）
    /// - 路径是 **`/nb/app-downgrade`**，不是 `/nb/appstore-plus`
    /// - `plusID` 的取值**就是字符串 `"0"`**（不是 trackId、不是爱思 appid）
    /// - `appID` = App Store trackId；`appVerId` = 版本的 external identifier
    /// - 返回的是**单个版本的下载信息**（不是版本列表）
    ///
    /// 参数键名由 Swift 表单的小端立即数确认：
    /// `0x444973756C70`="plusID"、`0x4449707061`="appID"、`0x4449656C646E7562`="bundleID"、
    /// `0x7972746E756F63`="country"、`0x6449726556707061`="appVerId"。
    ///
    /// **实测类型**：`plusID` 传 Int 会被判「参数不合法」，传 String 才进入查询 —— 故按字符串发。
    static func package(appID: String,
                        appVerId: String = "",
                        bundleID: String = "",
                        plusID: String = "0",
                        country: String = "cn") async throws -> NBPackage? {
        // 实测（2026-10-01）：**只传 appID 就能取到包**，bundleID 可省。
        // 空串会参与进请求体，所以干脆不塞 —— 少一个字段少一处踩雷。
        var p: [String: Any] = ["plusID": plusID, "appID": appID, "country": country]
        if !appVerId.isEmpty { p["appVerId"] = appVerId }
        if !bundleID.isEmpty { p["bundleID"] = bundleID }

        let obj = try await perform(path: "/nb/app-downgrade",
                                    method: "getAppHistoryList",
                                    params: p)
        let d = (obj["data"] as? [String: Any]) ?? obj
        guard let url = string(d["url"]), !url.isEmpty else { return nil }

        // sinfs 优先取 dataHex（实测字段名），退回 data。
        //
        // 注意： 2026-10-05 真机定案：**这两个字段的编码不同，必须分别处理，不能混在一句 `??` 里。**
        //   · `dataHex` 是 **hex**（2144 字符 = 1072 字节）→ 必须 hex→base64
        //   · `data`    是 **base64**（原样透传）
        //
        // 以前写成 `string(first["dataHex"]) ?? string(first["data"])`，hex 被当 base64 解。
        // 而 **hex 字符集 [0-9a-f] 恰好全在 base64 字母表内**、2144 又是 4 的倍数 ⇒
        // `Data(base64Encoded:)` **静默成功**，产出 1.5 倍长度的垃圾（1056 字节 → 1584 字节），
        // 全程没有一行报错。
        //
        // 真机实证（2026-10-05，设备 iPhone15,4 / iOS 27）：
        //   设备上 NB 源下的 `Via 浏览器-x.ipa`，其 `SC_Info/Via.sinf` 是 **1584 字节垃圾**
        //   （头声明 3545052371、无 sinf 魔数）；而 NB 原版工具下的同一 App 是 **1056 字节正确件**。
        //   同一天走 AppleID 通道下的同一 App 是 1032 字节且结构自洽 ⇒ 只有 NB 这条路径中招。
        //
        // 同一份 hex 在**下架路径** `offSalePackage()` 里早就转了（见本文件 `hexToBase64`），
        // 主路径漏了 —— `hexToBase64` 由 v0.3.557 引入时只补了下架路径。
        var sinf: String?
        if let arr = d["sinfs"] as? [[String: Any]], let first = arr.first {
            if let hex = string(first["dataHex"]) {
                sinf = hexToBase64(hex)
                if sinf == nil {
                    LoginLogger.shared.log("\(logTag) [失败] sinf 的 dataHex 不是合法 hex（\(hex.count) 字符）"
                                           + " —— 这份 sinf 不可用，不会写进包内",
                                           category: .appStore)
                }
            } else if let b64 = string(first["data"]) {
                sinf = b64   // 该字段本来就是 base64，**不要**再跑 hexToBase64（会二次解坏）
            }
        }
        // v0.3.545：拿不到 sinf 不许静默 —— 加密包缺 sinf 装不上，这条日志是唯一的线索
        if sinf == nil {
            LoginLogger.shared.log("\(logTag) [提示] 直链已取到，但服务端没回 sinf（udid=\(cachedRealUDID() ?? "?")）"
                                   + " —— 若包是加密的，安装会报「缺少 SC_Info/*.sinf」",
                                   category: .appStore)
        }
        // v0.3.592：把服务端回的真实版本号也带出去（`data.metadata.bundleShortVersionString`），
        // 供「回退到旧版本」时界面提示「已回退到 vX.Y.Z」用。取不到就不带，界面回落 `version`。
        let displayVersion = string((d["metadata"] as? [String: Any])?["bundleShortVersionString"])
        return NBPackage(ipaURL: normalizeAsset(url),
                         sinfBase64: sinf,
                         version: appVerId,
                         displayVersion: displayVersion)
    }

    /// 按「主版本 + 候选版本（新→旧）」逐个取包；遇**稳定** `code=7` 自动回退到下一个版本。
    ///
    /// ## 为什么需要（2026-10-11 实测定案）
    ///
    /// App 侧此前只发**一个** `appVerId`（= 搜索结果的 `appExtID` = 最新版）。服务端把最新版
    /// 清出库存时稳定回 `code=7 未获取到数据` —— 界面直接报「库里没包」，但**同 App 的旧版本
    /// 可能仍在库**。脚本遍历版本数组时：bilibili 退 3 步（`891589210`→…→`889351059`）即
    /// `code=0` + 新鲜直链（已实下 547MB 整包、MD5 与 API 一致）。⇒ 加版本回退即可修。
    /// （StikDebug 整条 21 个版本链全 `code=7` ⇒ 库里确无包，回退也救不了 —— 如实报「没有」。）
    ///
    /// ## 判据（与 `PackageFailure` 同源）
    /// - 成功（`code=0` 且带 url）→ 立即返回；`i > 0` 时把 `fellBack` 标上（界面提示一次）。
    /// - **稳定** `code=7`（`未获取到数据` 之类）→ 记一行
    ///   `[NB源] appVerId=… 回 code=7，回退到下一个`，继续试下一个候选。
    /// - **上游临时故障**（`code=7` 且 msg 含 `dialing`/`请求异常`）→ **不中断**，记下继续试
    ///   —— 实测这类超时是**随机落在某一步**的（`nb_fallback_chain_probe.py`），换版本可能就躲开；
    ///   全链都没命中且没遇到过稳定 7 时，才把它抛出（界面提示重试）。
    /// - 非 `code=7`（网络 / HTTP / 解码）→ 记下、继续试；全失败且**一次稳定 7 都没遇到**才抛出（提示重试）。
    ///
    /// - Parameter primaryVerID: 首选版本号；空串 = 不传 `appVerId`（服务端回最新版）。
    /// - Parameter embeddedCandidates: **内嵌**候选版本号（**新→旧**）。空数组 = 先只发主版本。
    /// - Parameter fallbackProvider: **惰性**补候选（v0.3.597）—— 主版本/内嵌候选都未命中时才调
    ///   一次（下架路径传 bilin 目录补；上架/详情路径传 `nil` 表示不补）。命中路径因此 0 次外呼。
    /// - Parameter maxAttempts: 尝试的**版本**上限（主版本 + 回退合计），防无限试。
    /// - Parameter sameVersionRetries: 同一版本遇**稳定** `code=7` 时的重试次数（v0.3.596 补）。
    /// - Parameter maxRequests: **总请求**上限（含同版本重试），防「库里全没包」时把用户晾太久。
    /// - Returns: 取到包；`nil` = 所有候选都取不到（库里没包）。
    /// 给一段异步工作套「总超时」——超时即抛 `StoreError.server("timeout", …)`。
    ///
    /// ## 为什么需要它（v0.3.601，用户报「NB 卡在获取中」）
    ///
    /// `packageWithFallback` 的最坏路径是：主版本 1 次 + 同版本重试 1 次 + bilin 补候选 1 次
    /// + 候选回退最多 5 次 + 快照 HEAD 1 次，而 `session.timeoutIntervalForRequest = 15` ⇒
    /// **最坏 ≈113 秒**。用户看到的就是「获取中…」一直转。
    ///
    /// **不改成「缩短单项超时」的原因**：单项超时缩短会把「本来就慢但能成功」的请求误杀
    /// （实测 bilin 在限流下会跑到 10s+，但最终能返回版本列表）——那会退回到「调不出链接」。
    /// **总超时只封顶「用户等待时长」**，不改任何单次请求的行为 ⇒ 快路径不受影响，
    /// 只有「真的取不到」时提前收尾并如实报「暂时取不到」。
    private static func withTotalTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw StoreError.server(code: "timeout", message: "总超时 \(Int(seconds))s")
            }
            guard let first = try await group.next() else {
                throw StoreError.server(code: "timeout", message: "总超时 \(Int(seconds))s")
            }
            group.cancelAll()
            return first
        }
    }

    private static func packageWithFallback(appID: String,
                                            primaryVerID: String,
                                            embeddedCandidates: [String] = [],
                                            fallbackProvider: (@Sendable () async -> [String])? = nil,
                                            bundleID: String,
                                            country: String,
                                            maxAttempts: Int = 6,
                                            sameVersionRetries: Int = 1,
                                            maxRequests: Int = 8) async throws -> NBPackage? {
        // 主版本在前（空串 = 不传 appVerId，服务端回最新版），内嵌候选按新→旧补齐并去重。
        var ordered: [String] = [primaryVerID]
        for c in embeddedCandidates where !c.isEmpty && !ordered.contains(c) { ordered.append(c) }
        var tries = Array(ordered.prefix(max(1, maxAttempts)))

        var sawStable7 = false
        var lastOtherError: StoreError?
        var requests = 0
        // v0.3.597：候选**惰性补** —— 主版本/内嵌候选都试完仍未命中时，才调 `fallbackProvider`
        // 去 bilin 补（见 `offSalePackage`）。主版本能命中 ⇒ 整次 bilin（实测 ~1.4s、限流紧）全省。
        var providerUsed = false
        var idx = 0
        scan: while idx < tries.count {
            if requests >= maxRequests {
                // 请求预算用尽 —— 不再试（防「库里全没包」时把用户晾太久）。已得出的结论仍有效。
                break scan
            }
            let vid = tries[idx]
            let i = idx
            var stable7 = false
            var retried = 0
            attempt: while true {
                if requests >= maxRequests {
                    break scan
                }
                requests += 1
                do {
                    let pkg = try await package(appID: appID, appVerId: vid,
                                                bundleID: bundleID, country: country)
                    if var got = pkg {
                        if i > 0 {
                            got.fellBack = true   // 命中在回退步上 → 界面给一次轻提示
                            LoginLogger.shared.log("\(logTag) [回退] 命中 appVerId=\(vid)"
                                                   + "（第 \(i + 1) 次尝试）.",
                                                   category: .appStore)
                        }
                        return got
                    }
                    break attempt   // code=0 但没有 url —— 当作这一版没包，换下一个。
                } catch let e as StoreError {
                    guard case .server(let code, let message) = e, code == "7" else {
                        lastOtherError = e
                        break attempt
                    }
                    if isUpstreamBusy(message) {
                        // 上游临时故障：**不中断整条链**。实测（`nb_fallback_chain_probe.py`）
                        // 这类 `dialing … timed out` 是**随机落在某一步**的 —— 换一个版本就可能躲开。
                        // 原来在此直接 `throw`，一次抽风就废掉整条回退链（本该走到后面某步命中，
                        // 却当场把「请稍后重试」甩给用户）。记下来继续试，全链都没命中再抛（见函数尾）。
                        lastOtherError = e
                        if i + 1 < tries.count {
                            LoginLogger.shared.log("\(logTag) appVerId=\(vid) 上游临时故障"
                                                   + "（\(truncate(message))），仍试下一个"
                                                   + "（\(i + 2)/\(tries.count)）.",
                                                   category: .appStore)
                        }
                        break attempt
                    }
                    // **稳定** `code=7`（`未获取到数据` 之类）—— 实测（2026-10-12，`nb_offsale_query.py`）
                    // **同一发请求会 `code=7 → code=0`**：首测 `code=7`，随后连打 8/8、15/15 全 `code=0`
                    // ⇒ 这类 7 是**瞬时抖动**。对齐牛蛙源「空直链重试」（`fetchNiuwaPackage` 对空直链
                    // 重试同一发最多 2 次），先**重试同一版本**一次，仍 7 才换下一个版本 ——
                    // 一次抖动不再白烧一个候选名额（原来遇 7 只换版本、绝不重试同一版本）。
                    if retried < sameVersionRetries {
                        retried += 1
                        LoginLogger.shared.log("\(logTag) appVerId=\(vid) 回 code=7，同版本重试"
                                               + "（\(retried + 1)/\(sameVersionRetries + 1)）.",
                                               category: .appStore)
                        continue attempt
                    }
                    sawStable7 = true
                    lastOtherError = e
                    stable7 = true
                    break attempt
                } catch {
                    lastOtherError = .network(error.localizedDescription)
                    break attempt
                }
            }
            if stable7, i + 1 < tries.count {
                LoginLogger.shared.log("\(logTag) appVerId=\(vid) 回 code=7，回退到下一个"
                                       + "（\(i + 2)/\(tries.count)）.",
                                       category: .appStore)
            }
            idx += 1
            // 内嵌候选试完、仍未命中、且还没补过 ⇒ 惰性调 provider（bilin）补候选，追加进 tries 继续回退。
            if idx >= tries.count, !providerUsed, let provider = fallbackProvider {
                providerUsed = true
                let extra = await provider()
                var appended = false
                for c in extra where !c.isEmpty && !ordered.contains(c) {
                    ordered.append(c)
                    appended = true
                }
                if appended {
                    tries = Array(ordered.prefix(max(1, maxAttempts)))
                    LoginLogger.shared.log("\(logTag) 内嵌候选试完未命中，补 \(tries.count - idx) 个候选继续回退.",
                                           category: .appStore)
                }
            }
        }
        // 全试完：遇到过稳定 code=7 ⇒ 库里没包（回 nil）；否则把最后一次错误抛出去（提示重试）。
        if sawStable7 || lastOtherError == nil { return nil }
        throw lastOtherError!
    }

    /// **按 `appID` + `appVerId` 取指定版本的包**（语义化入口，v0.3.586）。
    ///
    /// 与 `package(appID:appVerId:bundleID:country:)` 是**同一发请求**
    /// （`nb9527_getAppHistoryList`，见 `/nb/app-downgrade`）—— 这里只是给它一个
    /// 语义明确的入口名，供「导入一个 IPA → 用它的 `softwareVersionExternalIdentifier`
    /// 去 NB 取同版本的包 + sinf」这类场景调用。
    ///
    /// **实测（2026-10-09 直连）：对下架 App 也完全可用**，`code=0` 且回完整 `url`/`sinf`。
    ///
    /// - Parameters:
    ///   - appID: App Store `trackId`（包内 `iTunesMetadata.itemId`）。
    ///   - appVerId: 版本的 `externalVersionId`（包内 `softwareVersionExternalIdentifier`）。
    ///   - bundleID: 可省；服务端不强制。
    ///   - country: 区域（`cn` / `us` / `hk`）。
    ///   - fallbackCandidates: 可选回退版本号（**新→旧**）。**默认空 = 不回退** ——
    ///     详情页是「用户明确点了某个版本」，按他点的那个取，不擅自换版本。
    static func packageByVersion(appID: String,
                                 appVerId: String,
                                 bundleID: String = "",
                                 country: String = "cn",
                                 fallbackCandidates: [String] = []) async throws -> NBPackage? {
        try await packageWithFallback(appID: appID,
                                      primaryVerID: appVerId,
                                      embeddedCandidates: fallbackCandidates,
                                      bundleID: bundleID,
                                      country: country)
    }

    /// 上报下载（NB 客户端在下载时调，用于它自己的统计；移植时可省）。
    ///
    /// 实测：`POST /nb/app-downgrade`，`method=nb9527_recordDownload`，
    /// 参数含 `appID`/`appExtID`/`bundleId`/`name`/`version`/`cacheKey`/`cacheOriginalKey`。
    /// 响应 `{"code":0,"data":null,"msg":""}`。
    @discardableResult
    static func recordDownload(appID: String,
                               appExtID: String,
                               bundleId: String,
                               name: String,
                               version: String) async throws -> [String: Any] {
        try await perform(path: "/nb/app-downgrade",
                          method: "recordDownload",
                          params: ["appID": appID, "appExtID": appExtID,
                                   "bundleId": bundleId, "name": name, "version": version,
                                   // v0.3.554：原来是写死的 `false`，改成按设备判定 ——
                                   // 与 `deviceType` 同源，别让同一发请求里两个字段互相矛盾。
                                   "isPad": UIDevice.current.userInterfaceIdiom == .pad,
                                   "cacheKey": "appHistoryVersion_\(appID)_\(appExtID)",
                                   "cacheOriginalKey": "appHistoryVersionOriginal_\(appID)_\(appExtID)"])
    }

    /// 历史版本列表。
    ///
    /// ## 为什么不用 NB 自己出列表
    /// NB 的 `getAppHistoryList` 名字像「列表」，**实测是取单个版本的包**
    /// （抓包见报告第十节：传 `appVerId` 回 `data.url`，不传则回当前版本）。
    /// 它没有「一次给全量版本」的接口 —— 硬要的话只能逐版本试错，代价太高。
    ///
    /// ## 用 bilin 目录补上
    /// `apis.bilin.eu.org/history/{trackId}` 一次回**全量版本**，每项带
    /// `external_identifier`（= NB 要的 `appVerId`）。这条目录路径本项目
    /// **已经在用**（`AppStoreService.versionHistoryFromCatalog`，AppleID 商店的历史版本走它），
    /// 这里只是把它的结果**转给 NB 的取包链路**，不新增任何外部依赖。
    ///
    /// ⇒ 落到 UI 上就是：列出版本 → 点某个版本 → 用它的 `externalVersionID`
    /// 打 `/nb/app-downgrade` 取该版本的直链 + sinf。与 NB 客户端的形态一致。
    ///
    /// `trackID` 必须是 App Store 数字 ID（NB 的 `appID` 字段与 bilin 的路径参数同源）。
    static func versionList(trackID: String) async throws -> [NBVersion] {
        let versions = try await AppStoreService.versionHistoryFromCatalog(appId: trackID)
        return versions.map { v in
            NBVersion(externalIdentifier: v.externalVersionID ?? v.version,
                      version: v.version,
                      releaseTime: v.dateText,
                      sizeText: v.sizeText)
        }
    }

    // MARK: - v0.3.545 下架应用（对应 NB 助手的 DXSTOffSaleController）

    /// **下架应用**列表里的一项（`searchOffSaleApp` 响应）.
    ///
    /// ## 字段来源（逐字对齐 `DXSTOffSaleAppModel`，不是猜的）
    ///
    /// 反编译 NB 助手得到的属性表（`_OBJC_IVAR_$__TtC4XNZS19DXSTOffSaleAppModel`）：
    /// ```
    /// id  versionID  createTime  name  bundleID  iconPath  size  version
    /// lookupData  appstoreData  appStoreID  appExtID  lookupResult  historyList
    /// ```
    /// 与接口实测响应逐字一致 —— 所以这里不做改名、不做重组，原样承载.
    ///
    /// ## 两个「应用 ID」都要留
    /// `appStoreID` 与 `lookupData.trackId` 都是 App Store 数字 ID，
    /// 但**实测只有其中一边有值**：
    /// - `"StikDebug"` 那条：`appStoreID` 空、`lookupData` 里是完整 JSON（含 trackId）；
    /// - `"微信"` 那条：反过来，`appStoreID` 有值、`lookupData` 是空串。
    /// ⇒ 所以取包时要按「哪个有值用哪个」兜底，不能只认一个.
    struct OffSaleApp: Identifiable, Hashable {
        /// NB 自己的行号（`id`），不是 App Store ID —— 只用于 `Identifiable`.
        var id: Int
        var name: String
        var bundleID: String?
        /// 图标直链（`iconPath`，mzstatic CDN）.
        var iconPath: String?
        /// 包大小（字节）.
        var size: Int64?
        /// 版本号（可能为空串 —— 实测「微信」那条就是）.
        var version: String?
        /// `lookupData` 是**内嵌的 JSON 字符串**（Apple lookup 的响应体），
        /// 解出来是 `trackId` / `trackName` / `version` / `artworkUrl60` 等.
        /// 用它补 `appStoreID` 缺失的场合，也用它拿图标与版本.
        var lookupTrackID: String?
        var lookupName: String?
        var lookupVersion: String?
        var lookupArtwork: String?

        /// v0.3.559：`lookupData` 里**本来就带完整详情**（43 个键），原样承载.
        ///
        /// 下架应用在 Apple 的 `/lookup` 里查不到 —— 它就是因为下架才搜不到，
        /// 但 NB 在收录时把当初那份 lookup 响应**整段存了下来**，字段与 Apple 官方
        /// 逐字一致（`description` / `screenshotUrls` / `genres` / `releaseNotes` …）。
        /// 所以详情页不再需要打 Apple，直接吃这一份.
        var lookupDetail: NBStoreRankClient.AppDetail?

        /// 接口直接给的 `appStoreID`（实测可能与 `lookupData.trackId` 二选一有值）.
        var appStoreID: String?
        /// NB 侧的版本行号（下架取包要当 `versionID` 发出去；实测「微信」那条是 `0`）.
        var versionID: String?
        /// Apple 的 external version identifier（下架取包要当 `appExtID` 发出去）.
        var appExtID: String?

        /// v0.3.556：**下架包的直链与 sinf 就在搜索响应里**，不用再调第二个接口.
        ///
        /// 搜索响应的每条记录带一个 `appStoreData`（**JSON 字符串**），里面是完整的包信息：
        /// ```json
        /// {"url":"https://iosapps.itunes.apple.com/…/xxx.signed.dpkg.ipa?accessKey=…",
        ///  "sinfs":[{"id":0,"data":null,"dataHex":"0000043073696e66…"}],
        ///  "hashMD5":"4b634d7e…","metadata":{"bundleShortVersionString":"2.3.4", …}}
        /// ```
        /// 实测（2026-10-02 直连）：`url` 499 字符、`dataHex` 2144 字符（1072 字节，
        /// magic 头 `\x00\x00\x040sinf\x00\x00\x00\x0cfrma`，与上架取包同格式）。
        ///
        /// ⇒ **注意区分两个名字相近的 action**（v0.3.586 实测澄清）：
        /// · `getOffSaleAppHistoryList`（NB 助手下架页用的那个）**取不到包**：
        ///   实测它对任何参数组合都只回 `code=7 未获取到数据 / 参数不合法`，
        ///   NB 官方客户端点「获取」也一样失败。**别再走那条路**。
        /// · `getAppHistoryList`（上架通道用的同一个 action）**对下架 App 完全可用**：
        ///   实测（2026-10-09 直连）传 `appID`（或再加 `appVerId`）回 `code=0` 且
        ///   `data` 完整（含 `url` + `sinfs[0].dataHex`），直链 HEAD → HTTP 200。
        ///   见 `package(appID:appVerId:...)` 与 `offSalePackage(from:country:)`。
        ///
        /// ⚠️ 但 `appStoreData` **并非每条都有**：实测搜「哔哩哔哩」10 条里只有 4 条带它，
        /// 另外 6 条既没有 `appStoreData`、`appExtID` 也为空 —— 在搜索响应里就是**没有包**。
        /// ⇒ 那些条目必须回退到 `getAppHistoryList` 取包（见 `offSalePackage(from:country:)`），
        /// 否则界面只能报「这个版本暂时取不到安装包」。
        var packageURL: String?
        /// 服务端算好的包 MD5（`appStoreData.hashMD5`）.
        var packageMD5: String?
        /// 包对应的 sinf（`appStoreData.sinfs[0].dataHex`，十六进制字符串）.
        var packageSinf: String?
        /// 内嵌包信息的原始 JSON 字符串，原样留着备查.
        var appStoreDataRaw: String?

        /// v0.3.592：`appStoreData.metadata.softwareVersionExternalIdentifiers` ——
        /// 该 App 的**全量版本号**（外部标识，**旧→新**排列）。用于「最新版取不到时按新→旧回退」
        /// （见 `packageWithFallback`）。实测（2026-10-11）：bilibili 34 个、StikDebug 21 个；
        /// bilibili 退到第 4 个（`889351059`）即 `code=0` + 新鲜直链。
        /// **没有 `appStoreData` 的记录此数组为空**，那时只能单发（无版本可退）。
        var versionIDs: [String]

        /// 给取包/详情用的 App Store ID —— 先 `appStoreID`，退回 `lookupData.trackId`.
        var storeID: String? {
            if let s = appStoreID, !s.isEmpty { return s }
            if let s = lookupTrackID, !s.isEmpty { return s }
            if let s = lookupDetail?.trackID, !s.isEmpty { return s }
            return nil
        }

        /// 界面显示用的名字.
        var displayName: String { (lookupName?.isEmpty == false) ? lookupName! : name }
        /// 界面显示用的版本.
        var displayVersion: String? { (version?.isEmpty == false) ? version : lookupVersion }
        /// 界面显示用的图标.
        var displayIcon: String? {
            if let p = iconPath, !p.isEmpty { return p }
            return lookupArtwork
        }

        /// 包大小文案（与 App Store 同口径：十进制 MB）.
        var sizeText: String? {
            guard let b = size, b > 0 else { return nil }
            let mb = Double(b) / 1_000_000
            if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
            if mb >= 1 { return String(format: "%.1f MB", mb) }
            return String(format: "%.0f KB", Double(b) / 1000)
        }
    }

    /// **下架应用的搜索** —— `nb9527_searchOffSaleApp`.
    ///
    /// ## 这一条是怎么定的（先反编译，再抓包实测）
    ///
    /// 反编译 `DXSTOffSaleController.textFieldShouldReturn:` → `sub_1001590DC`
    /// → `sub_10020C044` → `sub_10020C11C`，在 `sub_10020C11C` 里逐条指令读出：
    /// ```
    /// 0x10020c160  ADRL X8, aSearchoffsalea   ; "searchOffSaleApp"
    /// 0x10020c188  ADRL X8, aNbAppDowngrade   ; "/nb/app-downgrade"
    /// 0x10020c16c  MOV  X21, #0xD000000000000010   ; 长度 16（"searchOffSaleApp" 正好 16）
    /// ```
    /// 参数字典的键是一个小端立即数 `30571 = 0x776B` → 字节 `6B 77` = **`"kw"`**.
    ///
    /// ## 实测（2026-10-02，本机抓包）
    /// ```
    /// POST http://47.243.71.210:9527/nb/app-downgrade
    /// {"method":"nb9527_searchOffSaleApp","params":{"kw":"stikdebug", …公共参数}}
    /// → {"code":0,"data":[{"id":15993,"name":"StikDebug","bundleID":"com.stik.sj",
    ///                      "iconPath":"https://is1-ssl.mzstatic.com/…",
    ///                      "size":11688960,"version":"2.3.5",
    ///                      "lookupData":"{\"trackId\":6744045754,…}"}]}
    /// ```
    /// `data` 是**数组**；无结果时 `data` 为 `null`.
    ///
    /// ## 为什么界面上必须走这一条
    /// 「下架」在 App Store 里**就是搜不到的**（Apple 的 search/RSS 只回在架应用）——
    /// 实测 `term=stikdebug&country=us` 回的是 TestFlight / GitHub / Debug Anywhere 那批
    /// **在架**应用，恰好是用户截图里看到的错误结果。下架库只有 NB 服务端有.
    static func searchOffSaleApp(keyword: String) async throws -> [OffSaleApp] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }

        let obj = try await perform(path: "/nb/app-downgrade",
                                    method: "searchOffSaleApp",
                                    params: ["kw": kw])
        // `data` 为 null（无结果）时按空数组处理，不抛错.
        guard let arr = obj["data"] as? [[String: Any]] else { return [] }

        let apps = arr.compactMap { item -> OffSaleApp? in
            guard let nid = (item["id"] as? NSNumber)?.intValue else { return nil }
            // lookupData 是**字符串形式的 JSON**，单独解一次
            var lookupTrackID: String?
            var lookupName: String?
            var lookupVersion: String?
            var lookupArtwork: String?
            var lookupDetail: NBStoreRankClient.AppDetail?
            if let raw = item["lookupData"] as? String, !raw.isEmpty,
               let d = raw.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                lookupTrackID = string(o["trackId"])
                lookupName = string(o["trackName"])
                lookupVersion = string(o["version"])
                lookupArtwork = string(o["artworkUrl512"]) ?? string(o["artworkUrl100"])
                    ?? string(o["artworkUrl60"])
                // v0.3.559：整段映射成详情模型，详情页直接用它渲染.
                lookupDetail = NBStoreRankClient.detail(fromLookup: o,
                                                        fallbackTrackID: lookupTrackID ?? "")
            }

            // v0.3.556：从 `appStoreData`（内嵌 JSON 字符串）里直接取**包直链与 sinf**。
            // 这是「下架取包」的正确来源 —— 不用再调 `getOffSaleAppHistoryList`。
            var pkgURL: String?
            var pkgMD5: String?
            var rawStoreData: String?
            var pkgSinf: String?
            var versionIDs: [String] = []
            if let raw = item["appStoreData"] as? String, !raw.isEmpty {
                rawStoreData = raw
                if let d = raw.data(using: .utf8),
                   let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    pkgURL = string(o["url"])
                    pkgMD5 = string(o["hashMD5"])
                    if let arr2 = o["sinfs"] as? [[String: Any]], let first = arr2.first {
                        pkgSinf = string(first["dataHex"]) ?? string(first["data"])
                    }
                    // 版本号也以内嵌 metadata 为准（实测 top-level `version` 有时比它新一档）
                    if let md = o["metadata"] as? [String: Any] {
                        if let v = string(md["bundleShortVersionString"]), !v.isEmpty {
                            lookupVersion = v
                        }
                        // v0.3.592：全量版本号数组（旧→新），供「最新版 code=7 时按新→旧回退」
                        versionIDs = stringArray(md["softwareVersionExternalIdentifiers"])
                    }
                }
            }
            if pkgURL == nil, let inline = item["appStoreData"] as? [String: Any] {
                pkgURL = string(inline["url"])
                pkgMD5 = string(inline["hashMD5"])
                if let arr2 = inline["sinfs"] as? [[String: Any]], let first = arr2.first {
                    pkgSinf = string(first["dataHex"]) ?? string(first["data"])
                }
                if versionIDs.isEmpty, let md = inline["metadata"] as? [String: Any] {
                    versionIDs = stringArray(md["softwareVersionExternalIdentifiers"])
                }
            }

            return OffSaleApp(
                id: nid,
                name: string(item["name"]) ?? "",
                bundleID: string(item["bundleID"]),
                iconPath: string(item["iconPath"]),
                size: (item["size"] as? NSNumber)?.int64Value,
                version: string(item["version"]),
                lookupTrackID: lookupTrackID,
                lookupName: lookupName,
                lookupVersion: lookupVersion,
                lookupArtwork: lookupArtwork,
                lookupDetail: lookupDetail,
                appStoreID: string(item["appStoreID"]),
                versionID: string(item["versionID"]),
                appExtID: string(item["appExtID"]),
                packageURL: pkgURL,
                packageMD5: pkgMD5,
                packageSinf: pkgSinf,
                appStoreDataRaw: rawStoreData,
                versionIDs: versionIDs)
        }
        // 日志只说结论：命中几条、其中几条**可直接取包**（带直链）
        let ready = apps.filter { ($0.packageURL ?? "").isEmpty == false }.count
        LoginLogger.shared.log("\(logTag) [完成] 下架搜索「\(kw)」· \(apps.count) 条"
                               + "（其中 \(ready) 条带包直链）", category: .appStore)
        return apps
    }

    /// **下架应用**的取包（v0.3.586：补上 `getAppHistoryList` 回退）。
    ///
    /// ## 怎么找到这条路的（反编译 NB 助手，不是猜的）
    ///
    /// NB 助手有一整套下架应用页面：
    /// `DXSTOffSaleController`（列表）/ `DXSTOffSaleDetailController`（详情）/
    /// `DXSTOffSaleHistoryListController`（历史版本），配套模型 `DXSTOffSaleAppModel`。
    ///
    /// 反编译 `sub_10031D260`（`getOffSaleAppHistoryList` 的唯一调用点）得到
    /// 真实的请求构造 —— 键名由小端立即数逐字还原：
    ///
    /// ```c
    /// aBlock = 0x4449617069LL;        // "ipaID"
    /// aBlock = 0x496E6F6973726576LL;  // "versionID"
    /// aBlock = 0x4449747845707061LL;  // "appExtID"
    /// aBlock = 0x437972746E756F63LL;  // "countryCode"
    /// // path = "/nb/app-downgrade"，method = "nb9527_getOffSaleAppHistoryList"
    /// ```
    ///
    /// 注意： **别去找 `nb9527_search_offsale_app`** —— 那个字符串确实存在，
    /// 但它是本地弹窗菜单项的标识符，**服务端没有这个 action**（报告第十二/十三节）。
    /// 「下架列表」在 NB 那边是本地 SQLite 表 `load_list` 缓存的。
    ///
    /// ## v0.3.556：优先用**搜索结果里自带的包**，不走第二个接口
    ///
    /// 真机抓包 + 直连实测发现：`searchOffSaleApp` 的每条记录里带一个
    /// `appStoreData`（内嵌 JSON 字符串），**包直链和 sinf 就在里面**：
    ///
    /// ```
    /// appStoreData.url              → Apple CDN 直链（带 accessKey）
    /// appStoreData.sinfs[0].dataHex → 2144 字符 hex = 1072 字节 sinf
    ///                                 （magic `\x00\x00\x040sinf\x00\x00\x00\x0cfrma`）
    /// appStoreData.hashMD5          → 服务端算好的包 MD5
    /// ```
    ///
    /// ## ⚠️ 两个名字相近的 action，别搞混（v0.3.586 实测澄清）
    ///
    /// - `getOffSaleAppHistoryList`（NB 助手下架页用的那个）**取不到包**：实测无论怎么传
    ///   都取不到 —— `ipaID` 传 NB 行号回 `未获取到数据`、传 `"0"` 回 `参数不合法`；
    ///   真机抓包显示 NB 官方客户端点「获取」发出的参数与我们**一字不差**，服务端同样只回
    ///   `code=7`。⇒ **这个 action 不是取包用的**（语义是查版本历史），别再走。
    /// - `getAppHistoryList`（上架通道用的同一个 action）**对下架 App 完全可用**：
    ///   实测（2026-10-09 直连）传 `appID`（或再加 `appVerId`）回 `code=0` 且 `data` 完整
    ///   （含 `url` + `sinfs[0].dataHex`），直链 HEAD → HTTP 200。
    ///   **这才是内嵌包缺失时该走的那条路**（见 `package(appID:appVerId:...)`）。
    ///
    /// ## v0.3.586：修「NB 源无论什么下架 App 都下载获取不了」
    ///
    /// v0.3.556 起本函数**只吃搜索结果内嵌的 `appStoreData`**。但实测（2026-10-09 直连）
    /// 那个字段**不是每条都有**：搜「哔哩哔哩」10 条里只有 4 条带它，另外 6 条既没有
    /// `appStoreData`、`appExtID` 也为空 —— 旧代码对它们直接 `return nil`，界面只报
    /// 「这个版本暂时取不到安装包」。**大多数下架条目都落在这一支**，这就是那个 bug 的根因。
    ///
    /// 现在改成两段：
    /// ① 内嵌包在 → 直接用（`embeddedOffSalePackage`，零额外请求）；
    /// ② 内嵌包不在 → 用 `appStoreID`（+ `appExtID`）打 `getAppHistoryList` 取包。
    ///
    /// ## v0.3.588：内嵌直链的 `accessKey` 会过期 —— 过期就现取（2026-10-10 实测定案）
    ///
    /// v0.3.586 的「内嵌包优先」是一处硬伤：`searchOffSaleApp` 每条记录里内嵌的
    /// `appStoreData.url` 是 NB **收录那一刻**的快照，而 Apple CDN 的 `accessKey` 带
    /// **过期时间**（`accessKey=<过期unix秒>_<num>_<签名>`）。快照一过那点就必然 403。
    ///
    /// **实测（2026-10-10 直连，脚本 `nb_offsale_freshness.py` / `nb_offsale_url_compare.py`）**：
    /// · 搜索内嵌 URL：accessKey 过期时间戳跨 2023-09-29 … 2026-10-09（**全部已过期**），
    ///   逐条 Range 前 1MB 一律 `HTTP 403 Forbidden` —— 搜「哔哩哔哩」/「抖音」/「微信」
    ///   共 8 条内嵌包，**8/8 全 403**。
    /// · 同一 App 走 `getAppHistoryList`：accessKey 是**未来**时间（如 2026-10-12），
    ///   Range 前 1MB 一律 `206 Partial Content` + 头部 `PK\x03\x04`（真 IPA）。
    /// ⇒ **内嵌包不再无条件优先**：先看它的 `accessKey` 过没过期，没过期才用（省一次请求）；
    ///   过期（或拿不到过期时间）就现取新鲜直链。旧行为正是「无条件用内嵌包」⇒ 403 ⇒ 下载必失败。
    ///
    /// ## v0.3.593：现取失败回落内嵌快照 —— 恢复「能获取到下载任务」（2026-10-11）
    ///
    /// v0.3.588 引入了一处**回归**：把内嵌快照降成「过期/判不出即弃用」，且现取失败
    /// （`code=7` → nil、或上游故障 → throw）后**不再回落内嵌快照** ⇒ 有快照的 App 也
    /// 拿不到任何链接，用户看到「**获取不到下载任务**」（原来是「有链接、只是下载 403」）。
    ///
    /// 修法（**现取优先 + 内嵌快照最后兜底**，保证「有 url」优先）：
    /// ① 内嵌快照 `accessKey` 未过期 ⇒ 直接用它（新鲜、省一次请求）；
    /// ② 否则现取 `getAppHistoryList`（含版本回退）——**现取成功用它**（新鲜直链）；
    /// ③ 现取回 nil / 抛错 / 连 storeID 都没有 ⇒ **回落到内嵌快照**（哪怕它可能 403，
    ///   也先把「下载任务」给出来，让下载阶段再决定），只有连快照都没有才回 nil。
    /// `accessKeyExpired` 判不出时间戳时仍返回 `true`（触发**优先现取**），但语义已从
    /// 「这条链接不能用」改成「优先去现取」——现取失败会兜底，不会再丢链接。
    ///
    /// ## v0.3.596：兜底快照**先探活**、候选版本**用 bilin 补**（2026-10-12，治「无法下载」）
    ///
    /// 用户报「最新构建下**无法下载**」—— 上一版的两处修复盖不住真实场景：
    /// 1. **版本回退空转**：`candidates` 只来自内嵌 `appStoreData`，而 7/10 下架条目没有它
    ///    ⇒ `candidates=[]` ⇒ 回退链只有 1 步。**现在** `bilinCandidates` 在内嵌没有时
    ///    用 bilin 目录的 `external_identifier` 补（带缓存、失败不阻塞）。
    /// 2. **兜底发的是 403 死链**：现取失败无条件 `return embedded`，而这些快照 accessKey 全部
    ///    已过期、HEAD/Range 一律 403 ⇒ 任务建了、包下不动。**现在** `snapshotFallback` 先
    ///    HEAD 探活：死链（403/404）返回 `nil`（如实报「库里没包」），活链/判不出才给。
    ///
    /// ## v0.3.597：bilin 补候选从**前置**改**惰性**（2026-10-13，治「获取变慢」）
    ///
    /// 用户报「NB 源获取下架应用**变慢**」—— 实测定案（`nb_perf_probe.py`）：v0.3.596 在取包**前**
    /// 无条件 `await offSaleCandidates(...)`，而 bilin median ~1.4s、3 连打即 429 ⇒ 主版本本来能
    /// 命中的条目也白等一整次 bilin。**现在**改由 `packageWithFallback` 在**主版本/内嵌候选都未命中
    /// 时**才调 `bilinCandidates` ⇒ 命中路径 0 次 bilin（回到改前速度），失败路径仍补候选（能力不丢）。
    ///
    /// ## v0.3.587：`code=7` 如实处理（不再把内部码甩给用户）
    ///
    /// 回退仍会回 `code=7`，实测（2026-10-10）**不是参数问题** —— 换 `appVerId` / `plusID` /
    /// `bundleID` / `country` 的任意组合都不能把 7 变成 0，同一 `appID` 反复打还是 7。
    /// `code=7` 的两种成因见 catch 内注释：一条「NB 库里没 iOS 包」（回 nil），一条「服务端
    /// 上游临时超时」（抛出、提示重试）。**原始码与 msg 只进日志，界面文案由调用方给**。
    static func offSalePackage(from app: OffSaleApp, country: String) async throws -> NBPackage? {
        // ① 先把内嵌快照备好 —— 它现在是**最后兜底**（v0.3.593 恢复；v0.3.596 收紧为「探活后才发」）。
        let embedded = embeddedOffSalePackage(from: app)

        // ② 内嵌快照 accessKey 未过期 ⇒ 直接用它（新鲜，省一次请求）。
        if let embedded = embedded, !accessKeyExpired(embedded.ipaURL) {
            return embedded
        }
        if embedded != nil {
            LoginLogger.shared.log("\(logTag) [提示] 内嵌快照直链的 accessKey 已过期（或无法判定），"
                                   + "先现取新鲜直链，取不到再探活兜底（\(app.name)）.",
                                   category: .appStore)
        }

        // ③ 现取：按 appID(+appVerId) 打 getAppHistoryList，拿**新鲜**直链。
        guard let storeID = app.storeID, !storeID.isEmpty else {
            // v0.3.596：兜底快照**先 HEAD 探活** —— 死链不发给用户（死链 = 任务建了、包下不动）。
            let fb = await snapshotFallback(embedded, app: app,
                                            reason: "拿不到 App Store ID、无法现取")
            if fb == nil {
                LoginLogger.shared.log("\(logTag) [失败] 下架记录既没有可用的快照直链、也拿不到 App Store ID，"
                                       + "无法取包（\(app.name)）.",
                                       category: .appStore)
            }
            return fb
        }

        // v0.3.597：候选**惰性补** —— 内嵌 `metadata` 有就直接当候选；没有（多数条目）**不预打 bilin**，
        // 改成把 bilin 补候选包成 provider，只有主版本/内嵌候选都 `code=7` 时 `packageWithFallback`
        // 才去调（见 `bilinCandidates`）。这样主版本能命中时省掉整次 bilin（实测 ~1.4s，且限流紧易 429），
        // 而主版本 7 时仍能靠 bilin 补候选退到旧版本（**不丢「调出链接」的能力**）。
        let embeddedCandidates: [String] = app.versionIDs.isEmpty ? [] : Array(app.versionIDs.reversed())
        // v0.3.600：闭包**显式标 `@Sendable`** —— 三元表达式 `cond ? { … } : nil` 不会把
        // 上下文类型 `(@Sendable () async -> [String])?` 传进闭包分支，闭包被推断成 non-Sendable
        // ⇒ CI（Xcode 27 / Swift 6.2）报 "converting non-Sendable function value … may introduce
        // data races"（本地 Swift 6.1.3 同根因，措辞为 "cannot convert … to (@Sendable () async …)?"）。
        // 直接赋值（无三元）或 if/else 都能让上下文类型传导，这里保持三元、给闭包自己标 Sendable。
        let fallbackProvider: (@Sendable () async -> [String])? = app.versionIDs.isEmpty
            ? { @Sendable in await bilinCandidates(storeID: storeID, appName: app.name) }
            : nil
        LoginLogger.shared.log("\(logTag) [提示] 现取新鲜直链 getAppHistoryList"
                               + "（appID=\(storeID) appVerId=\(app.appExtID ?? "")"
                               + " 内嵌候选 \(embeddedCandidates.count) 个）.",
                               category: .appStore)
        let pkg: NBPackage?
        do {
            // v0.3.592：主版本（最新版）回 `code=7` 时按候选**新→旧**自动回退 —— 最新版可能已被
            // 服务端清出，但旧版本仍在库（bilibili 退 3 步即命中）。v0.3.596 起同一版本遇稳定 7
            // 还会**重试一次**（瞬时抖动，见 `packageWithFallback`）。稳定 `code=7` 在
            // `packageWithFallback` 里被吞掉、全试完回 nil；这里只会收到「上游临时故障 / 网络错误」
            // 两类**值得重试**的抛出。
            pkg = try await withTotalTimeout(seconds: 25) {
                try await packageWithFallback(appID: storeID,
                                              primaryVerID: app.appExtID ?? "",
                                              embeddedCandidates: embeddedCandidates,
                                              fallbackProvider: fallbackProvider,
                                              bundleID: app.bundleID ?? "",
                                              country: country)
            }
        } catch let e as StoreError {
            // 走到这里 = 上游临时故障（`code=7` 且 msg 含 `dialing`/`请求异常`）或网络错误。
            // 原始码与 msg 一律进日志；界面文案由调用方给（见 `PackageFailure`）。
            if case .server(let code, let message) = e, code == "7" {
                LoginLogger.shared.log("\(logTag) [失败] 现取直链 code=7（\(app.name) appID=\(storeID)）：\(message)",
                                       category: .appStore)
            }
            // v0.3.596：现取抛错也回落内嵌快照，但**先探活** —— 死链不发给用户。
            if let fb = await snapshotFallback(embedded, app: app, reason: "现取失败") {
                return fb
            }
            throw e
        }
        if let pkg = pkg {
            return pkg
        }
        // ④ 现取（含版本回退）也没拿到 ⇒ 回落内嵌快照兜底（**先探活**）。
        if let fb = await snapshotFallback(embedded, app: app,
                                           reason: "现取（含版本回退）都没拿到直链") {
            return fb
        }
        LoginLogger.shared.log("\(logTag) [失败] 现取（含版本回退）都没拿到直链，且无可用内嵌快照可兜底"
                               + "（\(app.name) appID=\(storeID)）.",
                               category: .appStore)
        return nil
    }

    /// bilin 目录补候选（**惰性**：只在主版本/内嵌候选都 `code=7` 时才被 `packageWithFallback` 调）—— v0.3.597.
    ///
    /// ## 为什么（2026-10-13 实测复核）
    /// 版本回退链原来只有内嵌 `appStoreData.metadata.softwareVersionExternalIdentifiers`
    /// 一个来源，而**多数下架条目没有 `appStoreData`**（实测搜「哔哩哔哩」10 条里 **7 条**
    /// `versionIDs=[]`）⇒ `candidates=[]` ⇒ 回退链只有 1 步 = **等于没回退**。这些条目
    /// 「最新版被清出库存」时一步都退不动（`tv.danmaku.biliim` 首测即 `code=7`）。
    ///
    /// ## 怎么补
    /// 走 `versionList(trackID:)`（= `AppStoreService.versionHistoryFromCatalog`，
    /// 本项目**已在用**的 bilin 目录，不新增任何外部依赖）取全量版本，用它的
    /// `external_identifier`（= NB 要的 `appVerId`）当候选。实测 `tv.danmaku.biliim` 用
    /// bilin 候选第 1 步即 `code=0`（`841714489`，新鲜直链）。
    ///
    /// ## v0.3.597：从「无条件前置」改成「惰性」—— 这是「获取变慢」的根因修法
    /// v0.3.596 在 `offSalePackage` 里**先** `await offSaleCandidates(...)` 再取包 ⇒ 主版本本来
    /// 能命中的条目也要先等 bilin（实测 median ~1.4s；且 bilin 限流紧、3 连打即 429，失败还触发
    /// `AppStoreService` 的 400ms 退避重试）。改后由 `packageWithFallback` 在**主版本/内嵌候选都
    /// 未命中时**才调本函数 ⇒ 命中路径 0 次 bilin（回到改前速度），失败路径仍能补候选（能力不丢）。
    ///
    /// ## 两道保险（bilin 限流实测：3 连打第 3 发即 `429`）
    /// - **缓存**：目录自带 **6h 成功缓存 + 3min 负缓存**（`AppStoreService`），重复取包不打网络；
    /// - **非阻塞**：这里 `do/catch` 吞掉任何失败，补不到就回 `[]`、**照常单发**，
    ///   绝不因 bilin 失败把取包整体判死。
    ///
    /// - Note: bilin 目录实测**新→旧**排列（`t13_bilin_order.py`：`1517062289` 是
    ///   2026-09-27 → … → 2020-07-11），与 NB 要的候选方向一致，**不再反转**；
    ///   内嵌数组是**旧→新**，才需要 `.reversed()`。
    private static func bilinCandidates(storeID: String, appName: String) async -> [String] {
        do {
            let list = try await versionList(trackID: storeID)
            let ids = list.map { $0.externalIdentifier }.filter { !$0.isEmpty }
            let capped = Array(ids.prefix(offSaleCandidateLimit))
            if !capped.isEmpty {
                LoginLogger.shared.log("\(logTag) [提示] 内嵌无版本数组，用 bilin 目录补 \(capped.count) 个候选"
                                       + "（\(appName) appID=\(storeID)）.", category: .appStore)
            }
            return capped
        } catch {
            LoginLogger.shared.log("\(logTag) [提示] bilin 目录补候选失败（\(error.localizedDescription)），"
                                   + "照常单发（\(appName)）.", category: .appStore)
            return []
        }
    }

    /// bilin 补候选的**数量上限**：`packageWithFallback` 只用到前 `maxAttempts`（6）个版本，
    /// 目录对某些 App 能回 473 个（如 `736536022`）—— 截断到 6 个（与 `maxAttempts` 对齐）
    /// 足够覆盖回退链，少建长数组（v0.3.597：8 → 6）。
    private static let offSaleCandidateLimit = 6

    /// Apple CDN 直链的 `accessKey` 是否**该让位给现取**（过期，或判不出过期时间）。
    ///
    /// `accessKey` 形如 `<过期unix秒>_<num>_<base64签名>` —— 首个 `_` 前就是**过期时间**。
    /// 实测（2026-10-10）：过期时间戳（过去）→ `HTTP 403`；未来时间戳 → `206`。
    ///
    /// **判不出时间戳时返回 `true`（按「可能已过期」处理）** —— 语义是「**优先去现取**」，
    /// **不是**「这条链接一定不能用」：现取失败时 `offSalePackage` 会回落到这条内嵌快照兜底
    /// （v0.3.593），保证用户至少「看到有下载任务」。返回 `false`（判出且未过期）才直接用它。
    private static func accessKeyExpired(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "accessKey" })?.value,
              let head = value.split(separator: "_").first,
              let epoch = TimeInterval(head) else {
            return true
        }
        return Date().timeIntervalSince1970 >= epoch
    }

    /// 下架取包的**第一段**：把搜索结果里内嵌的那份 `appStoreData` 翻成 `NBPackage`（没有则 nil）。
    ///
    /// `dataHex` 是 **hex**，而下游 `PackageSINFWriter` 吃的是 **base64** —— 这里必须转。
    /// 以前直接把 hex 塞进 `sinfBase64`，`Data(base64Encoded:)` 必然失败 →
    /// 包内写不进 sinf → 安装报「缺少 SC_Info/*.sinf」。
    private static func embeddedOffSalePackage(from app: OffSaleApp) -> NBPackage? {
        guard let url = app.packageURL, !url.isEmpty else { return nil }
        let sinfB64 = app.packageSinf.flatMap { hexToBase64($0) }
        if sinfB64 == nil, (app.packageSinf ?? "").isEmpty == false {
            LoginLogger.shared.log("\(logTag) [失败] sinf hex 转 base64 失败（\(app.name)）",
                                   category: .appStore)
        }
        return NBPackage(ipaURL: normalizeAsset(url),
                         sinfBase64: sinfB64,
                         version: app.displayVersion)
    }

    /// 十六进制字符串 → base64 字符串（NB 的 sinf 是 hex，下游要 base64）。
    ///
    /// 输入可能带空格/换行（服务端偶尔分行发），先清掉再解。
    private static func hexToBase64(_ hex: String) -> String? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes).base64EncodedString()
    }

    /// ATS：明文 http 一律升 https（爱思侧踩过同一个坑，见 `I4PCStoreClient.normalizeAssetURL`）
    private static func normalizeAsset(_ raw: String) -> String {
        raw.hasPrefix("http://") ? "https://" + String(raw.dropFirst(7)) : raw
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// 把「元素是数字/字符串的数组」（如 `softwareVersionExternalIdentifiers`）翻成 `[String]`。
    private static func stringArray(_ v: Any?) -> [String] {
        guard let arr = v as? [Any] else { return [] }
        return arr.compactMap { string($0) }
    }
}
