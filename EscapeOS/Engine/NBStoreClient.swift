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

    /// 请求体里的 `udid`。
    ///
    /// ## v0.3.545：**不再造假 UDID —— 这就是「NB 源下的包装上闪退」的真因**
    ///
    /// 旧实现（v0.3.53x）随便生成一个 40 位 hex 冒充 UDID。抓包对照过 NB 助手真机：
    /// 它发的是**真 UDID**（`00008030-001A446A0260402E`）。
    ///
    /// 为什么这个字段决定生死：NB 服务端拿到 `udid` 去 Apple 那边换取
    /// **针对该设备的 FairPlay 授权（sinf）**。伪 UDID 换回来的 sinf 是无效的 ——
    /// 但注意它的失败形态**分两种**（这也是之前判断跑偏的地方）：
    ///
    /// - 服务端「识破」伪 UDID（比如形状/校验位不过）→ `sinfs` 直接给空串
    ///   → 客户端 `PackageSINFWriter` 记一行「这一份没有 sinf，跳过」
    ///   → 装的时候报「该 IPA 是加密包，但缺少 SC_Info/*.sinf」。
    /// - 服务端「照发一份 sinf」但那份不是为本机签的 → **装得上，一启动就崩**
    ///   （`ApplicationSINF` 与本机硬件不匹配，解密出来的 `__TEXT` 是垃圾）。
    ///
    /// 第二种形态正是用户报的「不缺 sinf，但安装后闪退」——所以修法不是
    /// 「补 sinf 写回」（那个逻辑早就有了），而是**把真 UDID 喂进去**。
    ///
    /// ## 取值顺序（与全项目其它地方一致，都走 `LocalDeviceIdentity`）
    /// ① `LocalDeviceIdentity.cachedSnapshot()`（缓存已热 → 0 成本）
    /// ② `LocalDeviceIdentity.load()`（冷缓存，同步读一次、建隧道秒级 —— 值得）
    /// ③ 兜底仍留一份稳定的伪值 —— **但要留下日志**，因为这份包大概率装不上，
    ///    不能静默降级（静默降级是上一轮排查绕远的根源）。
    private static var udid: String {
        if let real = LocalDeviceIdentity.cachedSnapshot()?.udid, !real.isEmpty {
            return real
        }
        // 冷缓存 → 同步读一次真 UDID。这一步会建 RSD 隧道（秒级），
        // 但：① NB 取包本来就要求用户点一下「获取」，不是下载启动的关键路径；
        //     ② 伪 UDID 会直接导致「装了闪退」，宁可慢一次也不许再假。
        // 读不到（隧道没起来）才落到下面的伪值兜底，并留下日志。
        if let real = LocalDeviceIdentity.load().udid, !real.isEmpty {
            return real
        }
        let key = "nb.pseudoUDID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            LoginLogger.shared.log("\(logTag) ○ 本次请求用历史伪 UDID（非本机真值）：\(saved)"
                                   + " —— 取回的 sinf 大概率装不上/装后闪退",
                                   category: .appStore)
            return saved
        }
        let digits = "0123456789abcdef"
        let v = String((0..<40).map { _ in digits.randomElement() ?? "0" })
        UserDefaults.standard.set(v, forKey: key)
        LoginLogger.shared.log("\(logTag) ○ 本机真 UDID 不可用，改用伪 UDID：\(v)"
                               + " —— 取回的 sinf 与本机不匹配，装了会闪退",
                               category: .appStore)
        return v
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
    private static func pubParams(iPad: Bool) -> [String: Any] {
        // 实测抓包值（2026-10-01）：客户端 3.9.1 / build 1。
        // 与请求体里的 appVersion 是同一个值，服务端会校验，勿随意改小。
        var p: [String: Any] = [
            "mainBundleID": "com.nbmaster.app",
            "mainEmbedded": 0,
            "apiVersion": "1.0",
            "version": "3.9.1",
            "build": "1",
            "appVersion": "3.9.1",
            "osVersion": UIDevice.current.systemVersion,
            "udid": udid,
            "lang": "zh-cn",
            // 反编译里这几项在请求体中是「有值就用真机值」；
            // `UIDevice.current.name` 在 iOS 16+ 未授权时会回落到 "iPhone"，
            // 所以这里不需要额外的空值保护。
            "phoneName": UIDevice.current.name,
            "productType": deviceModelIdentifier(),
            "deviceType": iPad ? "iPad" : "iPhone",
        ]
        // 机型标识再兜一次：真机取不到时保持与反编译样本一致的形状。
        if (p["productType"] as? String)?.isEmpty != false {
            p["productType"] = "iPhone12,1"
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
    private static func perform(path: String,
                                method: String,
                                params: [String: Any],
                                iPad: Bool = true) async throws -> [String: Any] {
        let url = path.isEmpty ? (host + "/nb/app") : (host + path)
        guard let u = URL(string: url) else { throw StoreError.badURL }

        var merged = pubParams(iPad: iPad)
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
            LoginLogger.shared.log("\(logTag) ✗ 响应解密失败；原始前 200：\(preview)",
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

        // sinfs 优先取 dataHex（实测字段名），退回 data
        var sinf: String?
        if let arr = d["sinfs"] as? [[String: Any]], let first = arr.first {
            sinf = string(first["dataHex"]) ?? string(first["data"])
        }
        // v0.3.545：拿不到 sinf 不许静默 —— 加密包缺 sinf 装不上，这条日志是唯一的线索
        if sinf == nil {
            LoginLogger.shared.log("\(logTag) ○ 直链已取到，但服务端没回 sinf（udid=\(udid)）"
                                   + " —— 若包是加密的，安装会报「缺少 SC_Info/*.sinf」",
                                   category: .appStore)
        }
        return NBPackage(ipaURL: normalizeAsset(url),
                         sinfBase64: sinf,
                         version: appVerId)
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
                                   "isPad": false,
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

    /// **下架应用**的取包。
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
    /// ⇒ **与上架应用走同一个端点，差别只有两处**：
    /// 1. `method` 换成 `getOffSaleAppHistoryList`；
    /// 2. 应用 ID 的键名是 **`ipaID`**（不是 `appID`），区域键是 **`countryCode`**（不是 `country`）。
    ///
    /// ⚠️ **别去找 `nb9527_search_offsale_app`** —— 那个字符串确实存在，
    /// 但它是本地弹窗菜单项的标识符，**服务端没有这个 action**（报告第十二/十三节）。
    /// 「下架列表」在 NB 那边是本地 SQLite 表 `load_list` 缓存的。
    /// 我们的做法：**下架状态由 lookup 结果判定 + 用本方法取包**，不建本地库。
    ///
    /// ## 参数
    /// - `trackID`: App Store 数字 ID（作为 `ipaID` 发出去）。
    /// - `appVerId`: 版本的 external identifier（不传则取当前最靠后的那版）。
    /// - `country`: 区域码（`cn` / `us`）。
    static func offSalePackage(ipaID: String,
                               appVerId: String = "",
                               country: String = "cn") async throws -> NBPackage? {
        var p: [String: Any] = [
            "ipaID": ipaID,
            "countryCode": country,
        ]
        if !appVerId.isEmpty {
            p["versionID"] = appVerId
            p["appExtID"] = appVerId
        }

        let obj = try await perform(path: "/nb/app-downgrade",
                                    method: "getOffSaleAppHistoryList",
                                    params: p)
        let d = (obj["data"] as? [String: Any]) ?? obj
        guard let url = string(d["url"]), !url.isEmpty else { return nil }

        var sinf: String?
        if let arr = d["sinfs"] as? [[String: Any]], let first = arr.first {
            sinf = string(first["dataHex"]) ?? string(first["data"])
        }
        if sinf == nil {
            LoginLogger.shared.log("\(logTag) ○ 下架包直链已取到，但服务端没回 sinf（ipaID=\(ipaID)）",
                                   category: .appStore)
        }
        return NBPackage(ipaURL: normalizeAsset(url),
                         sinfBase64: sinf,
                         version: appVerId)
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
}
