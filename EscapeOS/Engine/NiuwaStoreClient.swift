import Foundation
import UIKit
import CryptoKit

// MARK: - 牛蛙报文加解密（v0.3.392）

/// 牛蛙接口的**请求/响应都要加解密**，算法由逆向确证、并已用 Python 独立复现。
///
/// ## 报文结构
/// `报文 = base64NoPad(密文‖tag) + base64NoPad(str(N))`
/// - 解密：切尾部 **14 字符** → 解出 `N`（10 位十进制）；前段解出 `密文‖tag`
///   （样本实测 **58 字节 = 42 密文 + 16 tag**）。
/// - `N` 是服务端/客户端约定的时间种子（原始客户端：`time(NULL) + arc4random_uniform(1e8) + 1e8`）。
///
/// ## 算法与参数
/// - **AES-256-GCM**（nonce 12 字节、tag 16 字节）
/// - `key = MD5(前缀A + str(N)).uppercased()` → **32 字符 hex 串直接当 key 的 UTF-8 字节**
/// - `iv  = MD5(前缀B + str(N)).uppercased()` 的 **第 5..<17 字符**（12 字符）
///
/// ## 已验证
/// 用真机抓到的响应样本解出：`{"pub_code":650,"pub_desc":"unknow error"}`
/// ⇒ 这说明**服务端在报「你没按加密格式发请求」** —— 即「HTTP 200 但不是 JSON」的根因是
/// **我们过去一直发明文 JSON**，而不是解密不出来。
private enum NiuwaCrypto {

    /// ★ 本次请求加密时**实际发出去的那个 T**（= 拼在请求体尾部的那串数字）。
    ///
    /// 为什么必须记住它（反汇编证据，`NiuwaCore`）：
    /// `nwcore_decryptByAESWithCipher:timeSlide:` 的 IMP `0x60a50` 里，
    /// `0x060a70 mov x24, x3`（x3 = `timeSlide:` 参数）→ `0x060b30 add x21, x0, x24`
    /// ⇒ 服务端派生密钥用的是 **`N = 响应尾部的数字 + T`**，不是单纯的「尾部数字」。
    ///
    /// 这解释了「小样本能解、大样本解不开」：早期抓到的那个样本对应的请求**没带 T**（参数=0），
    /// 于是 `N = 尾部 + 0` 与我们当时的算法恰好一致；而请求侧加密打通后 `T ≠ 0`，
    /// 服务端按 `尾部 + T` 派生，我们仍用「尾部」→ **GCM tag 必然校验失败**。
    private(set) static var lastRequestT: String?

    /// 前缀 A（**32 字节**）：`~!@#$%^&*()_+` + **3 个空格** + `+_)(*&^%$#@!~` + **3 个空格**
    ///
    /// ⚠️ 空格**必须显式拼接**：直接写在一行里极易被格式化/编辑器吃掉，而**差一个空格整个算法就废**。
    static let prefixA = ["~!@#$%^&*()_+", "   ", "+_)(*&^%$#@!~", "   "].joined()

    /// 前缀 B（**12 字节**）：`%$#@!` + **2 个空格** + `^&*()`
    static let prefixB = ["%$#@!", "  ", "^&*()"].joined()

    /// 新生成一个 N（模仿原客户端；解密侧只认尾部那串数字，所以自造值亦可）
    static func newN() -> String {
        let t = Int(Date().timeIntervalSince1970)
        return "\(t + Int.random(in: 0..<100_000_000) + 100_000_000)"
    }

    /// 由 N 派生 (key, iv)
    static func deriveKeyIV(n: String) -> (key: Data, iv: Data) {
        let keyHex = md5Upper(prefixA + n)
        let ivFull = md5Upper(prefixB + n)
        let ivHex = String(Array(ivFull)[5..<17])
        return (Data(keyHex.utf8), Data(ivHex.utf8))
    }

    /// MD5 的大写十六进制串（`Insecure.MD5` 是 CryptoKit 对常用 MD5 的封装，够用且无第三方依赖）
    static func md5Upper(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8))
            .map { String(format: "%02X", $0) }
            .joined()
    }

    /// 明文 → 可发送的报文串
    static func encrypt(_ plain: Data) -> String? {
        let n = newN()
        // ★ 记住本次发出去的 T —— 解密时要用 `尾部 + T` 派生密钥（见 `lastRequestT` 注释）
        lastRequestT = n
        let (key, iv) = deriveKeyIV(n: n)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let sealed = try? AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce) else {
            return nil
        }
        return b64(sealed.ciphertext + sealed.tag) + b64(Data(n.utf8))
    }

    /// 报文串 → 明文
    static func decrypt(_ s: String) -> Data? {
        // ★ 关键（v0.3.395）：**先去掉整段的 base64 padding 再切分**。
        // 服务端可能带 `=` 返回：小响应恰好是 4 的倍数（92 字）看不出问题，
        // 而大响应真机实测 9106 字、`9106 % 4 == 2` → 一定以 `==` 结尾。
        // 那时「末尾 14 个字符」里会混进 `=` → 尾部取到的不是时间数字 → **分段错误 → 解密必败**。
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "=", with: "")
        // ★ 诊断（v0.3.395）：真机出现「小响应能解开、大响应解不开」——
        // 小响应 92 字符（密文 78 + 尾 14），大响应 9106 字符。**结构可能不同**，
        // 而整体响应被日志截断到 2000 字，看不到尾部，所以这里把**关键分段信息**单独记一份。
        LoginLogger.shared.log("[牛蛙源·诊断] 报文长度=\(trimmed.count) 尾部20=[\(String(trimmed.suffix(20)))]",
                               category: .appStore)
        guard trimmed.count > 14 else { return nil }
        let tail = String(trimmed.suffix(14))
        let head = String(trimmed.dropLast(14))
        guard let nData = base64Decode(tail),
              let n = String(data: nData, encoding: .utf8),
              let blob = base64Decode(head), blob.count > 16 else {
            LoginLogger.shared.log("[牛蛙源·诊断] 分段失败：尾14=[\(tail)] 头长度=\(head.count)",
                                   category: .appStore)
            return nil
        }
        let ciphertext = Data(blob.prefix(blob.count - 16))
        let tag = Data(blob.suffix(16))
        let tailN = n                       // 响应尾部那串数字
        let t = lastRequestT                 // 本次请求发出去的 T
        // ★★ 候选 N，按证据强度排序：
        // ① `尾部 + T` —— 反汇编证据 `add x21, x0, x24`（x0=尾部、x24=timeSlide 参数=我们发的 T）；
        // ② `尾部`     —— T=0 的老路径（早期那个 92 字样本就是这种，所以它能解开）；
        // ③ `T`        —— 兜底。
        // 逐个试，成功即返回 —— GCM 的 tag 校验"非过即挂"，不存在误判。
        var candidates: [(String, String)] = []
        if let t, let sum = decimalSum(tailN, t) { candidates.append((sum, "尾部+T")) }
        candidates.append((tailN, "尾部"))
        if let t { candidates.append((t, "T")) }

        for (nCandidate, label) in candidates {
            let (key, iv) = deriveKeyIV(n: nCandidate)
            guard let nonce = try? AES.GCM.Nonce(data: iv),
                  let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
                  let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else {
                LoginLogger.shared.log("[牛蛙源·诊断] N候选[\(label)]=\(nCandidate) → 失败",
                                       category: .appStore)
                continue
            }
            LoginLogger.shared.log("[牛蛙源·诊断] ✓ 命中 N候选[\(label)]=\(nCandidate)"
                                   + "（尾部=\(tailN) T=\(t ?? "nil")）", category: .appStore)
            return plain
        }
        LoginLogger.shared.log("[牛蛙源·诊断] 全部 N 候选失败：尾部=\(tailN) T=\(t ?? "nil") "
                               + "密文=\(ciphertext.count) 字节", category: .appStore)
        return nil
    }

    /// 两个十进制数字字符串相加 —— `N = 尾部 + T` 可能到 10 位以上，所以用 Int64 而不是 Int32
    static func decimalSum(_ a: String, _ b: String) -> String? {
        guard let x = Int64(a), let y = Int64(b) else { return nil }
        return "\(x + y)"
    }

    /// base64 **去掉 `=` padding**（报文两段都不带 padding）
    static func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// 解 base64（自动补齐 padding；同时容忍 URL-safe 字母表）
    static func base64Decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }
}

/// v0.3.382：免登录下载商店的**第二来源**——牛蛙（NiuWaCore）接口客户端。
///
/// 与接口一（爱思，见 `I4PCStoreClient`）并列：爱思只覆盖国区，牛蛙客户端**硬编码了
/// 中国 / 美国 / 香港三档区域**，所以它比爱思支持更多区。
///
/// 协议形态（已逆向确证，非推测）：
/// - 基址 `https://api.ios222.com`（客户端配置目录名 base64 解出，全库唯一 base）
/// - `POST /appstore/search`，body = `keyword` + `region` + `pub_*` 五项
/// - `POST /appstore/download`，body = `bundleid` + `region` + `pub_*` 五项
/// - **不带任何 token / Authorization / uid** —— 即"免登录"（请求公共参数只有 `pub_*`）
///
/// ## v0.3.387：真机「三档全搜不到」之后的二进制级复核结论
///
/// 用户实测：切到牛蛙源后**任何关键词、任何区域都是空界面**。日志被清过拿不到，
/// 于是直接对 `NiuwaCore`（50,683,616 字节）做「ASCII 串 + base64 解码 + 键名全表」提取，
/// 得到两条强证据 + 一条方法论修正：
///
/// 1. **`region` 很可能是数字索引**：属性编码 `Tq,N,V_nwcore_region`（`q` = `NSInteger`），
///    且与 `nwcore_regionSegmented`（`QMUISegmentedControl`）+ `nwcore_regionItemClicked:`
///    配套 → 分段控件的**索引**就是区域值。而我们传的是 `"cn"/"us"/"hk"`。
///    另外：全库**没有** `cn`/`us`/`hk`/`中国`/`美国`/`香港` 任何一个明文短串
///    （说明区域取值不是这些字符串，也可能标题在 .lproj 里）。
/// 2. **`pub_*` 五项没有漏**：全库 `pub_` 键名共 15 个，其中 5 个正是
///    `pub_version` / `pub_udid` / `pub_lang` / `pub_platform` / `pub_system_version`，
///    其余 10 个是 OpenSSL 符号（`pub_key` / `pub_pem_encode` / `pub_der_*` …）。
///    **不存在 `pub_sign` / `timestamp` / `nonce` 之类的第六个公共参数** → 排除"漏签名"。
/// 3. **属性名 ≠ JSON 键（关键修正）**：该客户端用 **YYModel**（二进制里有
///    `modelCustomPropertyMapper` / `modelContainerPropertyGenericClass`），
///    JSON 键由映射表给出。`nwcore_` 前缀是**他们自己的属性命名约定**（630 个里绝大多数是
///    UI 属性/方法名，如 `nwcore_appIcon` / `nwcore_appNameLab`）。
///    全库像"响应字段"的只有 6 个：`nwcore_apps` / `nwcore_code` / `nwcore_count` /
///    `nwcore_list` / `nwcore_messages` / `nwcore_status`；其中 `nwcore_apps`(NSArray)、
///    `nwcore_list`(NSArray)、`nwcore_messages`(NSArray) 在**同一个类的属性声明区里紧邻**，
///    而 `nwcore_count`(NSString) 与 `nwcore_list` 天然成对（列表 + 总数）
///    → **数组键到底是 `nwcore_apps` 还是 `nwcore_list`，静态侧无法百分之百定死**。
///
/// 因此本版不再赌单一个键/单一形态，而是：
/// - **数组键按序逐个试**（`listKeyCandidates`），命中即用；
/// - **`region` 双形态各试一次**：整数索引优先（有 `Tq` 证据），空/失败再回退 ISO 串；
/// - **失败时把服务端实际返回的键名写进错误与日志** —— 这样用户截图一次就能定案，
///   不用再赌（上一版就是只弹 toast、界面留空，白丢一轮证据）。
///
/// 下载/安装仍走既有 `IPADownloadCenter`（本类只取直链）。
enum NiuwaStoreClient {

    // MARK: - 常量

    static let host = "https://api.ios222.com"
    static let searchPath = "/appstore/search"
    static let downloadPath = "/appstore/download"

    /// 真机上按这个 grep 就能捞到全部牛蛙请求
    static let logTag = "[牛蛙源]"

    /// 响应体原文最多打进日志的字数（一次搜索的 JSON 可能几十 KB，只留头部够定位结构）
    private static let logBodyLimit = 2000

    /// 响应里「应用数组」的候选键（按可能性排序，命中即用）。
    ///
    /// **★ v0.3.403：`ba_apps` 排第一 —— 这是真机实测出来的真实键名。**
    /// 真机拿到（解密成功后的）真实响应结构：
    /// ```json
    /// {"pub_code":0,"pub_desc":"接口调用成功","body":{"ba_apps":[{"trackName":"Via 浏览器","bundleId":"com.tuyafeng.Via", …}]}}
    /// ```
    /// ⇒ **数组不在顶层，而是嵌在 `body` 里**（见 `perform` 的 `scopes`）。
    /// 下面那几个 `nwcore_*` 是从二进制字符串里推的、**至今未在真机命中过**，保留只为兜底。
    private static let listKeyCandidates = [
        "ba_apps", "apps", "list", "nwcore_apps", "nwcore_list", "data", "result",
    ]

    // MARK: - 区域

    /// 客户端硬编码的三档区域（中文串「中国 / 美国 / 香港」来自
    /// `NWCoreClassAppStoreSearchTableViewCell` 附近的 NSInteger 分段索引）。
    ///
    /// **`rawValue` 是 ISO 串（旧口径），`index` 是分段索引（新证据）** ——
    /// 见类型注释 1：`nwcore_region` 的 objc 类型是 `NSInteger`，所以线上更可能要数字。
    /// 请求侧两种都试（`withRegionShapes`），命中哪个由日志定案。
    enum NiuwaRegion: String, CaseIterable, Identifiable {
        case cn = "cn"
        case us = "us"
        case hk = "hk"

        var id: String { rawValue }

        /// 分段控件索引（`nwcore_regionSegmented` 的 selectedSegmentIndex）。
        /// 顺序取自 UI 三档的中文次序：中国 → 美国 → 香港。
        var index: Int {
            switch self {
            case .cn: return 0
            case .us: return 1
            case .hk: return 2
            }
        }

        var title: String {
            switch self {
            case .cn: return "中国"
            case .us: return "美国"
            case .hk: return "香港"
            }
        }
    }

    // MARK: - 模型

    /// 搜索结果 / 详情里的一个应用。
    ///
    /// 字段名两套并存（服务端键惯例 + iTunes 风格），解析时都兼容：
    /// `nwcore_app_id` / `nwcore_bundleid` / `nwcore_name` / `nwcore_desc` /
    /// `nwcore_strVersion` / `nwcore_url` / `nwcore_ipaURL` / `nwcore_strAppSize` /
    /// `nwcore_strAppIconName`，以及 `app_id` / `bundleid` / `name` / `trackName` /
    /// `artworkUrl512` / `iconURL` / `downloadURL` / `fileId` / `stid`。
    struct NiuwaApp: Identifiable, Hashable {
        /// 牛蛙侧 app id（`nwcore_app_id` / `app_id`）
        var appId: String?
        var bundleId: String
        var name: String
        var desc: String?
        var version: String?
        /// 大小文案（`nwcore_strAppSize`，服务端给的就是带单位的字符串）
        var sizeText: String?
        var iconURL: String?
        /// 安装包直链（`nwcore_ipaURL` / `nwcore_url` / `downloadURL` / 下载接口的 `ba_ipaURL`）。
        ///
        /// ⚠️ v0.3.407：这条直链**指向 `iosapps.itunes.apple.com` 是正常的、不是"抓错了源"** ——
        /// 牛蛙服务器自己用它的账号向 Apple 取包，再把 Apple 签发的 CDN 地址（形如
        /// `…/signed.dpkg.ipa?accessKey=…`）连同**针对本机 UDID 的 sinf**（`ba_sinfs`）一起下发。
        /// 所以「包来自 Apple CDN + sinf 由牛蛙给」这两件事同时成立，别把它当成爱思那种
        /// "服务端存着一份已签名 IPA" 的模型。
        var downloadURL: String?
        /// 包校验值（`md5`，客户端模型里有这个字段）
        var md5: String?
        /// 服务端文件 id（`fileId` / `stid`）
        var fileId: String?
        /// 更新时间（`currentVersionReleaseDate`，形如 `2025-06-06T10:00:00+08:00`）
        var releaseDate: String?
        /// v0.3.404：**下载接口**返回的 `ba_sinfs`（base64 文本，安装加密包时要用）。
        /// 只有 `/appstore/download` 的响应带它；搜索接口恒为 nil。
        ///
        /// ## v0.3.407：**已经用起来了**（v0.3.406 留的触发条件已触发）
        ///
        /// 真机上装牛蛙包时报「加密包…缺少 SC_Info/*.sinf」→ 说明牛蛙给的 Apple 原始包
        /// 里没有可用 sinf，必须用这一份。现在的接线：
        /// · `IPADownloadCenter.Job.sinfBase64` 收下它（`start(...)` 的 `sinfBase64:` 参数，
        ///   由 `startNiuwaDownload`（`Views/I4StoreFreeView.swift`）传入）；
        /// · 下载落盘后、安装前，由 `IPADownloadCenter` 的 `PackageSINFWriter`
        ///   把 base64 解码成 `Data`，**追加**写进包内
        ///   `Payload/<App>.app/SC_Info/<CFBundleExecutable>.sinf`。
        ///
        /// **它是什么**：base64 解出来是**标准 `.sinf` 容器**，不是别的包装格式 ——
        /// 真机样本解出 **1032 字节**，头 4 字节 `00 00 04 08`（= 长度 1032）紧跟 ASCII `sinf`，
        /// 正是 `.sinf` 的长度前缀 + tag 结构。所以它是「可以直接丢进 `SC_Info/` 的那份文件」，
        /// **不要再给它加任何包装/加密**。
        ///
        /// **还剩一处没做**（留给下一个需要的人）：`PackageSINFWriter` 只能在条目**不存在**时追加 ——
        /// 现有 ZIP 写入器（`vendor/ApplePackage/Supplement/ZipFoundationShim.swift`）**没有删除条目**的
        /// 能力，所以「包内已有一份别的设备的 sinf、要替换掉」这种情形目前只会记日志跳过。
        /// 真机上若是那种包，症状会是**装上了但启动崩 / installd 报解密失败**，而不是"缺少 sinf"。
        ///
        /// **历史**（为什么非要写回包里）：本项目两条安装链路的 sinf 都不是"传参数"进去的，
        /// 而是**从包里读**：
        /// · `AppStoreInstallService.installLocalIPA`（`Engine/AppStoreInstallService.swift:111`）
        ///   判到加密包后走 `IPAPackageInspector.extractSINF(ipaPath:)`，读的是
        ///   `Payload/<App>.app/SC_Info/<exe>.sinf`；
        /// · AppleID 通道更靠前一步：`SignatureInjector.inject(sinfs:into:)`
        ///   （`Engine/AppStoreLocalInstallService.swift:83`）先把 Apple 签发的 sinf **写回包内**。
        /// ⇒ 介质是**包本身**，光把这个字符串往下传没有任何消费者 —— 所以 v0.3.407 的做法是
        /// 「落盘后写回包内」，而不是给它加一个安装参数。
        ///
        /// **当初为什么绕开 `SignatureInjector`**：它是 AppleID 通道用的，自己从
        /// `SC_Info/Manifest.plist` 的 `SinfPaths` 里挑路径、且「条目已存在就抛错」；
        /// 而我们要写的是由 `CFBundleExecutable` 唯一确定的那个路径，且宁可跳过也不写重名条目。
        var sinfBase64: String?

        /// 列表按 bundleId 去重 → 用 bundleId 当 id
        var id: String { bundleId }

        var icon: URL? {
            guard let s = iconURL, !s.isEmpty else { return nil }
            return URL(string: s)
        }

        var ipa: URL? {
            guard let s = downloadURL, !s.isEmpty else { return nil }
            return URL(string: s)
        }
    }

    enum StoreError: Error, LocalizedError {
        case badURL
        case http(Int)
        case decode
        /// 200 但信封里没有已知的数组键 —— 把 `code` / `messages` / **实际键名**都带上
        case server(code: String, message: String)
        case network(String)
        /// v0.3.392：报文加解密失败（请求体加密 / 响应解密）
        case crypto(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址无效"
            case .http(let c): return "请求失败（HTTP \(c)）"
            /// v0.3.389：真机实测服务端回的是 **base64 密文**，不是 JSON。
            /// 这句要留在界面上，否则用户只会反复点、而我们这边看不出原因。
            case .decode: return "响应不是 JSON（服务端加密了，待解密）"
            case .server(let code, let message):
                return message.isEmpty ? "服务端返回码 \(code)" : "\(message)（\(code)）"
            case .network(let m): return "网络错误：\(m)"
            case .crypto(let m): return "报文加密异常：\(m)"            }
        }
    }

    // MARK: - 请求

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // v0.3.390：请求超时 25s → **10s**。
        // 现状（真机实测）：服务端回的是**加密体**，我们解不开 → 每次搜索都必然以解析失败收场，
        // 25 秒的等待纯属浪费用户时间。等密钥到手、能真正解出数据后，再按需调回。
        cfg.timeoutIntervalForRequest = 10
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// `pub_udid`：优先本机真实 UDID，取不到就用一次生成、持久化的伪 UDID。
    ///
    /// 伪值形如 40 位十六进制（与真 UDID 同形）：`UniqueDeviceIdentifier` 在 iOS 26/27
    /// 与 LiveContainer 下经常取不到，而**请求体必须带这个键**，宁可给个形状合法的稳定值，
    /// 也不要在探测阶段因为一个字段把整次请求变成畸形。
    ///
    /// ## v0.3.408：**改成只吃缓存**（这条是「第一次点获取必失败」的直接嫌疑）
    ///
    /// 原来这里调的是 `LocalDeviceIdentity.load()` —— 那是**会现场建 RSD 隧道**的入口，
    /// 而 `LocalDeviceIdentity` 的文件头明确写着「**绝不能在下载启动这类关键路径上同步调用**」
    ///（真机实测建一次隧道是**秒级**）。于是每一次「获取」在真正发 HTTPS 之前，
    /// 都可能先卡着建一条隧道；而同一时刻 App 自己的 LocalDevVPN 正在被重配，
    /// **这一发请求会被顶掉** → 用户看到「获取安装包失败」，再点一次（缓存已热 / 隧道已起）就成功。
    ///
    /// 现在沿用 v0.3.402 在 AppleID 下载链路上立下的规矩（`warmUpInBackground()` +
    /// 只吃缓存）：**请求路径上零设备 IO**。冷缓存就先给伪 UDID 顶着，并顺手把预热挂到后台；
    /// 缓存一热，后面的请求自然都是真值。
    /// 日志里会写明这一次用的是**真值还是伪值**（只在变化时打一行），
    /// 所以「首次失败」到底是不是它，下一轮真机日志一看便知。
    private static var pubUDID: String {
        if let snap = LocalDeviceIdentity.cachedSnapshot(),
           let real = snap.udid?.trimmingCharacters(in: .whitespaces),
           !real.isEmpty {
            noteUDIDSource("本机真 UDID")
            return real
        }
        // 冷缓存：**不建隧道**，后台预热（下一次请求就可能拿到真值）
        LocalDeviceIdentity.warmUpInBackground()
        noteUDIDSource("伪 UDID（身份缓存未热 / 真 UDID 不可用）")
        let key = "niuwa.pseudoUDID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        var hex = ""
        let digits = "0123456789abcdef"
        for _ in 0..<40 { hex.append(digits.randomElement() ?? "0") }
        UserDefaults.standard.set(hex, forKey: key)
        return hex
    }

    /// `pub_udid` 用的是真值还是伪值 —— **只在变化时打一行**。
    ///
    /// 为什么要专门记它：「第一次点获取必失败、重试才成功」这件事，最需要排除的就是
    /// 「第一次带伪 UDID、第二次带真 UDID」——那会让**同一个应用**的两次请求在服务端看来
    /// 是两个设备。有这一行，下一轮真机日志就能定案（而不是靠猜）。
    private static func noteUDIDSource(_ source: String) {
        paramLock.lock()
        let changed = lastUDIDSource != source
        lastUDIDSource = source
        paramLock.unlock()
        guard changed else { return }
        LoginLogger.shared.log("\(logTag) pub_udid 使用：\(source)", category: .appStore)
    }

    /// 当前 `pub_udid` 的来源（只给日志用）—— 下载响应异常时随诊断一起打出来.
    private static var udidSourceForLog: String {
        paramLock.lock(); defer { paramLock.unlock() }
        return lastUDIDSource ?? "未记录"
    }

    /// 连接设备的 iOS 版本（取不到回落到本机 `UIDevice.current.systemVersion`）
    ///
    /// ## v0.3.408：**改成只吃缓存 + 后台预热**
    /// 原来这里**每次请求**都调 `DeviceInfoService.lockdownFullDict()` —— 那是一条
    /// **要建隧道的设备 IO**（秒级，且不像身份那样有进程内缓存）。
    /// 一次「获取」因此可能连建两条隧道（身份一条 + 本字段一条），
    /// 这正是「第一次点必失败」的另一半原因（同一时刻 App 自己的 LocalDevVPN 在被重配）。
    ///
    /// 现在：缓存里没有就**不建隧道**，直接用本机 `UIDevice.current.systemVersion` 顶上
    ///（同一台设备、同一个值），同时把真正的读取挂到后台；读到了下一轮就用真值。
    private static var pubSystemVersion: String {
        paramLock.lock()
        let cached = prefetchedSystemVersion
        paramLock.unlock()
        if let cached { return cached }
        warmUpDeviceParamsInBackground()
        return UIDevice.current.systemVersion
    }

    private static let paramLock = NSLock()
    /// 后台预热取到的 `ProductVersion`（`nil` = 还没取到 —— 此时用本机 `UIDevice` 版本顶上）
    private static var prefetchedSystemVersion: String?
    /// 是否已有一轮预热在跑（防止每次请求都起一条隧道）
    private static var prefetchingParams = false
    private static var lastUDIDSource: String?

    /// 后台预热 `pub_*` 里那两处**需要设备 IO** 的字段。可重复调用，进程内只真读一次。
    ///
    /// 身份那一半交给 `LocalDeviceIdentity` 自己的预热（同一条 lockdown 隧道，不会重复建）；
    /// 这里只补它不管的 `ProductVersion`。两者都**不在**请求路径上等待。
    static func warmUpDeviceParamsInBackground() {
        paramLock.lock()
        let alreadyHave = prefetchedSystemVersion != nil
        let busy = prefetchingParams
        if !alreadyHave && !busy { prefetchingParams = true }
        paramLock.unlock()
        LocalDeviceIdentity.warmUpInBackground()
        guard !alreadyHave, !busy else { return }
        Task.detached(priority: .utility) {
            var value = ""
            if let root = try? DeviceInfoService.lockdownFullDict(),
               let v = root["ProductVersion"] as? String, !v.isEmpty {
                value = v
            }
            paramLock.lock()
            if !value.isEmpty { prefetchedSystemVersion = value }
            prefetchingParams = false
            paramLock.unlock()
            LoginLogger.shared.log(
                "\(logTag) 设备参数预热完成：pub_system_version="
                + (value.isEmpty ? "未取到（继续用本机 UIDevice 版本）" : value),
                category: .appStore
            )
        }
    }

    /// 本 App 的 build 号（`CFBundleVersion`）—— 牛蛙的 `pub_version` 量级与之相符。
    ///
    /// ⚠️ **不能用 `Bundle.main`**：本 App 常以侧载 / LiveContainer 方式运行，那时
    /// `Bundle.main` 可能指向**宿主**的 bundle，取到的是与牛蛙无关的 build 号
    /// （项目铁律：一律 `Bundle(for: SomeClass.self)`，见 `SAPAssetsLocator`）。
    private final class BundleToken {}

    private static var pubVersion: String {
        Bundle(for: BundleToken.self).infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// 公共参数五项（`pub_*`）—— 这就是牛蛙的"免登录"身份，没有 token / Authorization / uid。
    /// v0.3.387：类型放开成 `[String: Any]`，好让 `region` 能按需发**数字**而不是字符串。
    private static func pubParams(iPad: Bool) -> [String: Any] {
        [
            "pub_version": pubVersion,
            "pub_udid": pubUDID,
            "pub_lang": DeviceInfoService.userLocaleIdentifier() ?? "zh-Hans-CN",
            "pub_platform": iPad ? "iPadOS" : "iOS",
            "pub_system_version": pubSystemVersion,
        ]
    }

    private static func postJSON(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: host + path) else { throw StoreError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // ★ v0.3.392：**请求体必须加密**。
        // 过去我们发的是明文 JSON，服务端直接回 `{"pub_code":650,"pub_desc":"unknow error"}`
        // （HTTP 状态还是 200）—— 这就是「HTTP 200 但不是 JSON」的真正原因。
        // 报文格式与响应一致：`base64NoPad(密文‖tag) + base64NoPad(str(N))`。
        let plain = try JSONSerialization.data(withJSONObject: body)
        guard let sealedBody = NiuwaCrypto.encrypt(plain) else {
            throw StoreError.crypto("请求体加密失败")
        }
        req.httpBody = Data(sealedBody.utf8)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StoreError.http(http.statusCode)
        }
        return data
    }

    // MARK: - 搜索

    /// 关键词搜索（免登录）。`region` 决定区（中国 / 美国 / 香港）。
    static func search(keyword: String, region: NiuwaRegion, iPad: Bool = true) async throws -> [NiuwaApp] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        return try await withRegionShapes(region: region) { regionValue, shape in
            var body = pubParams(iPad: iPad)
            body["keyword"] = kw
            body["region"] = regionValue
            return try await perform(path: searchPath, body: body, region: region, shape: shape)
        }
    }

    // MARK: - 下载（只取直链，不下载文件）

    /// 按 bundleId 取安装包直链；服务端没给直链时返回 `nil`。
    static func download(bundleId: String, region: NiuwaRegion, iPad: Bool = true) async throws -> NiuwaApp? {
        let bid = bundleId.trimmingCharacters(in: .whitespaces)
        guard !bid.isEmpty else { return nil }
        let list = try await withRegionShapes(region: region) { regionValue, shape in
            var body = pubParams(iPad: iPad)
            body["bundleid"] = bid
            body["region"] = regionValue
            return try await perform(path: downloadPath, body: body, region: region, shape: shape)
        }
        return list.first
    }

    // MARK: - region 双形态

    /// ⚠️ **v0.3.389 临时收窄成「只发一种形态」**。
    ///
    /// 原因（真机实测）：`region=cn` 与 `region=us` 两次请求**返回的都是 base64 密文**，不是 JSON ——
    /// 说明「搜不到」的**瓶颈不在 region 取值**，而在**响应体本身要解密**。
    /// 既然三种形态都会失败，串行三发只会让用户白白多等（25s 超时 × 3 = 最长 75 秒，
    /// 表现为「一直卡在加载中」，用户实测正是这个现象）。
    ///
    /// 所以本版**只发数字形态**（证据最强：`nwcore_region` 的 objc 类型是 `Tq` = `NSInteger`），
    /// 快速失败、快速给用户信息。**等响应解密做完**（见 `[牛蛙源] ✗ 响应不是 JSON 对象` 的那条链路），
    /// 再决定要不要把候选形态加回来。
    private static func withRegionShapes(
        region: NiuwaRegion,
        _ attempt: (Any, String) async throws -> [NiuwaApp]
    ) async throws -> [NiuwaApp] {
        let shapes: [(Any, String)] = [
            (region.index, "数字 \(region.index)"),
        ]
        var firstError: Error?
        for shape in shapes {
            do {
                let apps = try await attempt(shape.0, shape.1)
                if !apps.isEmpty { return apps }
                LoginLogger.shared.log("\(logTag) region=\(shape.1) 返回空列表", category: .appStore)
            } catch {
                if firstError == nil { firstError = error }
                LoginLogger.shared.log("\(logTag) region=\(shape.1) 失败（\(error.localizedDescription)）",
                                       category: .appStore)
            }
        }
        if let firstError { throw firstError }
        return []
    }

    // MARK: - 请求 + 全量诊断日志

    /// 发一次请求，**把请求体（UDID 打码）/ HTTP 状态码 / 响应体原文全打进 `LoginLogger`**。
    ///
    /// 失败三分：
    /// - `network`：URLSession 直接抛（没有 HTTP 响应）
    /// - `http(N)`：有响应但非 2xx
    /// - `server(code:message:)`：200 但**没有任何候选数组键命中** ——
    ///   把 `code` / `messages` / **响应里实际存在的键名**原文带上（这条最关键：
    ///   用户截图一次就能定案，不必再赌键名）
    /// 把最近一次响应**完整**写到 `Documents/LoginLogs/niuwa_last_response.txt`（覆盖式）。
    ///
    /// 用途：日志里的响应会被截断到 2000 字，而排查加解密必须看**完整**报文
    ///（尤其尾部那 14 个字符 = `base64(时间数字)`，它决定 key/iv 的派生）。
    /// 电脑侧取回：`python ssh_run.py niuwa`（会打印长度 + 尾部 + T，并把全文存到本地，
    /// 再当场按 `尾部+T` → `尾部` → `T` 顺序试解）。
    ///
    /// ⚠️ 它属于 `NiuwaStoreClient` 而不是 `NiuwaCrypto` —— v0.3.399 曾把它放进
    /// `NiuwaCrypto`（private），结果客户端侧调用不到，CI 报
    /// `error: cannot find 'dumpResponse' in scope`。诊断落盘是客户端的职责，放这里。
    private static func dumpResponse(_ raw: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("LoginLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("niuwa_last_response.txt")
        let header = "len=\(raw.count)\ntail20=\(String(raw.suffix(20)))\n"
            + "T=\(NiuwaCrypto.lastRequestT ?? "nil")\n---\n"
        try? (header + raw).write(to: file, atomically: true, encoding: .utf8)
    }

    private static func perform(path: String, body: [String: Any],
                                region: NiuwaRegion, shape: String) async throws -> [NiuwaApp] {
        let log = LoginLogger.shared
        log.log("\(logTag) → POST \(host)\(path) region=\(shape)", category: .appStore)
        log.log("\(logTag) 请求体 \(describeBody(body))", category: .appStore)

        let data: Data
        do {
            data = try await postJSON(path, body: body)
        } catch let e as StoreError {
            log.log("\(logTag) ✗ \(e.localizedDescription)", category: .appStore)
            throw e
        } catch {
            log.log("\(logTag) ✗ 网络失败 \(error.localizedDescription)", category: .appStore)
            throw StoreError.network(error.localizedDescription)
        }

        let raw = String(data: data, encoding: .utf8) ?? "<非 UTF-8 \(data.count) 字节>"
        // ★ v0.3.399：**把完整响应单独落盘**（覆盖式，只留最后一次）。
        //
        // 为什么必须在日志之外再存一份：日志里的响应被 `truncate()` 截到 **2000 字**，
        // 而真实大响应有 **9106 字** —— 尾部的 14 个字符（= `base64(时间数字)`）
        // 正好在截断之外，于是「分段到底对不对」这件事**永远验证不了**。
        // 存成独立文件后，电脑侧用 `ssh_run.py niuwa` 一条命令取回本地，不受任何截断与行序影响。
        dumpResponse(raw)
        log.log("\(logTag) ← 原始响应 \(truncate(raw))", category: .appStore)

        // ★ v0.3.392：响应是**加密体**，先解密再解析。
        // 解密失败时把原始体前 200 字符留档（否则以后又是「什么都看不到」）。
        guard let plain = NiuwaCrypto.decrypt(raw) else {
            log.log("\(logTag) ✗ 响应解密失败；原始体（前 200）：\(String(raw.prefix(200)))",
                    category: .appStore)
            throw StoreError.crypto("响应解密失败")
        }
        let plainText = String(data: plain, encoding: .utf8) ?? "<非 UTF-8 \(plain.count) 字节>"
        log.log("\(logTag) ← 解密后 \(truncate(plainText))", category: .appStore)

        guard let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            log.log("\(logTag) ✗ 解密后仍不是 JSON 对象", category: .appStore)
            throw StoreError.decode
        }

        // ★ v0.3.403：状态码/描述的真实键名是 `pub_code` / `pub_desc`
        // （真机实测响应：`{"pub_code":0,"pub_desc":"接口调用成功","body":{…}}`）。
        // 旧的 `nwcore_code` / `code` 保留兜底 —— 它们是从二进制字符串推的、至今未在真机命中。
        let code = string(obj["pub_code"]) ?? string(obj["nwcore_code"]) ?? string(obj["code"]) ?? "-"
        let message = string(obj["pub_desc"])
            ?? string(obj["nwcore_messages"])
            ?? (obj["nwcore_messages"] as? [Any])?.map { string($0) ?? "" }.joined(separator: "；")
            ?? string(obj["message"])
            ?? ""

        // ★★ v0.3.407：**把「服务端没有包」与「我们解析漏了形态」分开**（只对下载请求生效）。
        //
        // 起因（真机日志）：同一个接口、同一个 region，`Via` / `SogouExplorer` 成功，
        // `msedge` / `TakeBrowser` 失败，而失败的都掉进下面那条「找数组」分支 ——
        // 说明 `body.ba_ipaURL` 没通过 `!ipa.isEmpty`。但当时**没有任何一行日志打出它的值**，
        // 到底是「没有这个键」「键在但值是空串」还是「值不是 String」只能靠猜。
        // 下面这几行就是给它定性的，一次真机即可判定：
        //   (a) 键根本不在 → 牛蛙服务器对这些应用**确实没有包**（不是我们的 bug，如实告诉用户）；
        //   (b) 键在但取值不可用（空串 / NSNull / 非字符串）→ 是我们漏了某种形态，按实际类型补解析。
        // 日志里带 `bundleId` + `code`/`desc`，所以「某个应用恒失败」与「同一应用时好时坏」也分得开。
        if path == downloadPath {
            let requestTarget = (body["bundleid"] as? String) ?? "-"
            let desc = message.isEmpty ? "-" : message
            // v0.3.408：把 `pub_udid` 的来源一起打出来 —— 「第一次点必失败」的定案依据之一
            // 就是「失败的这次带的是伪 UDID、成功的那次带真 UDID」。
            let udidNote = "udid=\(udidSourceForLog)；"
            if let envelope = obj["body"] as? [String: Any] {
                if let rawIPA = envelope["ba_ipaURL"] {
                    if (string(rawIPA) ?? "").isEmpty {
                        let sinfLength = string(envelope["ba_sinfs"])?.count ?? 0
                        log.log("\(logTag) ⚠ 下载响应 ba_ipaURL 取不到可用值（\(requestTarget)；"
                                + "值类型 \(type(of: rawIPA))；ba_sinfs \(sinfLength) 字符；"
                                + "\(udidNote)"
                                + "code=\(code) desc=\(desc)）", category: .appStore)
                    }
                } else {
                    log.log("\(logTag) ⚠ 下载响应 body 没有 ba_ipaURL 键（\(requestTarget)；"
                            + "\(udidNote)"
                            + "body 键：\(envelope.keys.sorted().joined(separator: ", "))；"
                            + "code=\(code) desc=\(desc)）", category: .appStore)
                }
            } else if let rawBody = obj["body"] {
                log.log("\(logTag) ⚠ 下载响应 body 不是对象（\(requestTarget)；"
                        + "\(udidNote)类型 \(type(of: rawBody))）",
                        category: .appStore)
            }
        }

        // ★★ v0.3.404：**下载接口的响应没有数组** —— `body` 直接给两个字段：
        //   `ba_ipaURL`（安装包直链）、`ba_sinfs`（base64 的 sinf）。
        // 真机实测（v0.3.403 日志）：
        //   {"body":{"ba_ipaURL":"https://iosapps.itunes.apple.com/…signed.dpkg.ipa?accessKey=…",
        //            "ba_sinfs":"AAAECHNpbmY…"},"pub_code":0,"pub_desc":"接口调用成功"}
        // 之前这里和搜索**共用「找数组」的解析** → 永远命中不了 → 用户看到「获取不了」。
        if let body = obj["body"] as? [String: Any],
           let ipa = string(body["ba_ipaURL"]), !ipa.isEmpty {
            let sinfB64 = string(body["ba_sinfs"])
            log.log("\(logTag) ✓ 下载接口返回直链（sinf \(sinfB64?.count ?? 0) 字符）（region=\(shape)）",
                    category: .appStore)
            return [NiuwaApp(appId: string(body["app_id"]),
                             bundleId: string(body["bundleid"]) ?? "",
                             name: string(body["name"]) ?? "",
                             desc: nil,
                             version: string(body["version"]),
                             sizeText: nil,
                             iconURL: nil,
                             downloadURL: ipa,
                             md5: string(body["md5"]),
                             fileId: string(body["fileId"]),
                             releaseDate: nil,
                             sinfBase64: sinfB64)]
        }

        // ★★ v0.3.403：**数组可能嵌在 `body` 里**（真机实测就是 `body.ba_apps`）。
        // 先在 `body` 里找，再回落到顶层 —— 之前的实现只看顶层，
        // 于是明明解密成功、数据也拿到了，却报「无候选数组键命中」。
        var scopes: [[String: Any]] = []
        if let body = obj["body"] as? [String: Any] { scopes.append(body) }
        scopes.append(obj)

        for scope in scopes {
            for key in listKeyCandidates {
                guard let arr = scope[key] as? [[String: Any]] else { continue }
                let apps = arr.compactMap(parse)
                if apps.isEmpty && !arr.isEmpty {
                    // ★ 最关键的诊断：命中了数组、却一条都没解析出来 → 说明**字段键名**不对。
                    // 把服务端首条记录的**实际键名**打出来，一次真机搜索就能定死键名
                    // （上一版就是静默丢弃，白丢了一轮）。
                    let firstKeys = arr[0].keys.sorted().joined(separator: ", ")
                    log.log("\(logTag) ⚠ 命中数组键「\(key)」但 0 条解析成功（服务端给了 \(arr.count) 条）；"
                            + "首条记录的键=[\(firstKeys)]（region=\(shape)）", category: .appStore)
                } else {
                    log.log("\(logTag) ✓ 命中数组键「\(key)」code=\(code) 解析 \(apps.count)/\(arr.count) 条（region=\(shape)）",
                            category: .appStore)
                }
                return apps
            }
        }

        // 一个都没命中 → 把**实际键名**暴露出来（这是下一轮定案的唯一依据）
        let actualKeys = obj.keys.sorted().joined(separator: ", ")
        let bodyKeys = (obj["body"] as? [String: Any])?.keys.sorted().joined(separator: ", ")
        let detail = "响应键：\(actualKeys)" + (bodyKeys.map { "；body 键：\($0)" } ?? "")
        log.log("\(logTag) ✗ 无候选数组键命中（code=\(code) messages=\(message.isEmpty ? "-" : message)）；\(detail)",
                category: .appStore)
        throw StoreError.server(code: code, message: message.isEmpty ? detail : message)
    }

    /// 请求体转日志文本：`pub_udid` 只留前后 4 位
    private static func describeBody(_ body: [String: Any]) -> String {
        let sorted = body.keys.sorted().map { key -> String in
            let value = body[key]
            if key == "pub_udid", let s = value as? String { return "\(key)=\(maskUDID(s))" }
            let text = value.map { String(describing: $0) } ?? ""
            return "\(key)=\(text)"
        }
        return "{" + sorted.joined(separator: ", ") + "}"
    }

    /// UDID 打码：前后各留 4 位，中间省略（日志里不出现完整设备标识）
    static func maskUDID(_ s: String) -> String {
        guard s.count > 8 else { return "****" }
        return "\(s.prefix(4))…\(s.suffix(4))（\(s.count) 位）"
    }

    private static func truncate(_ s: String) -> String {
        s.count <= logBodyLimit ? s : String(s.prefix(logBodyLimit)) + "…（共 \(s.count) 字）"
    }

    // MARK: - 解析

    /// 单条记录 → `NiuwaApp`。
    ///
    /// **键名必须同时兼容三套**（这是 v0.3.387 定位到的「列表全空」真因）：
    /// - **无前缀**（`bundleid` / `name` / `downloadURL` / `app_id` …）：二进制里有
    ///   `currentVersionReleaseDate` 这种**无前缀键与 `nwcore_apps` 物理紧邻**（同在 AppStore 模型区）
    ///   → 搜索返回的记录用的是无前缀键；
    /// - **`nwcore_` 前缀**（`nwcore_bundleid` / `nwcore_name` / `nwcore_strVersion` …）：他们自己的属性命名；
    /// - **`nwcore_strApp*`**：已安装应用那一套模型（`strAppPath`/`strAppExecutable` 同族），
    ///   这里只作兜底。
    ///
    /// 早期只认 `nwcore_bundleid` → 一条都解析不出来 → `compactMap` 静默全丢 →
    /// 返回空数组 → **界面空白且不报错**（正是用户的实测现象）。
    private static func parse(_ d: [String: Any]) -> NiuwaApp? {
        guard let bundleId = string(d["nwcore_strAppBundleId"])
                ?? string(d["nwcore_bundleid"])
                ?? string(d["bundleid"])
                ?? string(d["bundleId"])
                ?? string(d["nwcore_strBundleID"])
                ?? string(d["nwcore_strBundleId"]),
              !bundleId.isEmpty else { return nil }
        let name = string(d["nwcore_strAppName"])
            ?? string(d["nwcore_name"])
            ?? string(d["name"])
            ?? string(d["trackName"])
            ?? string(d["nwcore_strDisplayName"])
            ?? bundleId
        var app = NiuwaApp(bundleId: bundleId, name: name)
        app.appId = string(d["nwcore_app_id"]) ?? string(d["app_id"]) ?? string(d["appId"])
        app.desc = string(d["nwcore_desc"]) ?? string(d["desc"])
        app.version = string(d["nwcore_strAppVersion"])
            ?? string(d["nwcore_strVersion"])
            ?? string(d["version"])
        app.sizeText = string(d["nwcore_strAppSize"]) ?? string(d["sizeText"]) ?? string(d["size"])
        app.iconURL = normalizeAsset(string(d["nwcore_strAppIconName"])
            ?? string(d["artworkUrl512"])
            ?? string(d["iconURL"])
            ?? string(d["icon"]))
        app.downloadURL = normalizeAsset(string(d["nwcore_ipaURL"])
            ?? string(d["nwcore_url"])
            ?? string(d["nwcore_strURL"])
            ?? string(d["downloadURL"])
            ?? string(d["url"]))
        app.md5 = string(d["md5"])
        app.fileId = string(d["fileId"]) ?? string(d["stid"]) ?? string(d["fileid"])
        app.releaseDate = string(d["currentVersionReleaseDate"]) ?? string(d["updateTime"])
        return app
    }

    /// ATS：明文 http 一律升 https（爱思侧踩过同一个坑，见 `I4PCStoreClient.normalizeAssetURL`）
    private static func normalizeAsset(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if v.hasPrefix("http://") {
            v = "https://" + String(v.dropFirst("http://".count))
        }
        return v
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}
