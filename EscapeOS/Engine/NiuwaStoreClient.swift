import Foundation
import UIKit

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
    /// **顺序已按二进制证据校正**（v0.3.387 二次复核）：
    /// - `nwcore_apps` 与 `NWCoreClassAppStoreAppModel` **物理紧邻**
    ///   （同一段 `__cstring` 里前后脚出现）→ **它才是 App Store 搜索的数组键**，排第一；
    /// - `nwcore_list` 紧邻的是 **`NWCoreClassTaskModel`**（且旁边就是 `task/list`、`task/signin`、
    ///   `device/cdkey` 这些端点）→ 它是**任务列表**用的，与搜索无关，降为备选。
    private static let listKeyCandidates = [
        "nwcore_apps", "nwcore_list", "apps", "list", "data", "result",
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
        /// 安装包直链（`nwcore_ipaURL` / `nwcore_url` / `downloadURL`）
        var downloadURL: String?
        /// 包校验值（`md5`，客户端模型里有这个字段）
        var md5: String?
        /// 服务端文件 id（`fileId` / `stid`）
        var fileId: String?
        /// 更新时间（`currentVersionReleaseDate`，形如 `2025-06-06T10:00:00+08:00`）
        var releaseDate: String?

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

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址无效"
            case .http(let c): return "请求失败（HTTP \(c)）"
            case .decode: return "返回数据解析失败"
            case .server(let code, let message):
                return message.isEmpty ? "服务端返回码 \(code)" : "\(message)（\(code)）"
            case .network(let m): return "网络错误：\(m)"
            }
        }
    }

    // MARK: - 请求

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// `pub_udid`：优先本机真实 UDID，取不到就用一次生成、持久化的伪 UDID。
    ///
    /// 伪值形如 40 位十六进制（与真 UDID 同形）：`UniqueDeviceIdentifier` 在 iOS 26/27
    /// 与 LiveContainer 下经常取不到，而**请求体必须带这个键**，宁可给个形状合法的稳定值，
    /// 也不要在探测阶段因为一个字段把整次请求变成畸形。
    private static var pubUDID: String {
        if let real = LocalDeviceIdentity.load().udid?.trimmingCharacters(in: .whitespaces),
           !real.isEmpty {
            return real
        }
        let key = "niuwa.pseudoUDID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        var hex = ""
        let digits = "0123456789abcdef"
        for _ in 0..<40 { hex.append(digits.randomElement() ?? "0") }
        UserDefaults.standard.set(hex, forKey: key)
        return hex
    }

    /// 连接设备的 iOS 版本（取不到回落到本机 `UIDevice.current.systemVersion`）
    private static var pubSystemVersion: String {
        if let root = try? DeviceInfoService.lockdownFullDict(),
           let v = root["ProductVersion"] as? String, !v.isEmpty {
            return v
        }
        return UIDevice.current.systemVersion
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
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
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

    /// **三种 region 形态逐个试**（按证据强度排序）：
    /// ① JSON 数字 `0`（最贴证据：`nwcore_region` 的 objc 类型是 `Tq` = `NSInteger`）；
    /// ② JSON **字符串**数字 `"0"`（服务端常把这类枚举参数当字符串收）；
    /// ③ ISO 串 `"cn"`（我们最早的猜测口径，留作最后兜底）。
    ///
    /// 为什么「返回空列表」也要继续试下一种：服务端不认这个取值时很可能是**安静地给空列表**
    /// 而不是报错（用户实测正是"不报错、就是空"）。
    ///
    /// 收敛判据（看日志，一次真机搜索即可定案）：
    /// · `M>0 且 N>0` → region 形态对了（M = 服务端给的条数，N = 我们解析成功的条数）；
    /// · `M=0` → 三种形态都不认，需要再反汇编 `nwcore_regionItemClicked:` 找常量；
    /// · `M>0 但 N=0` → region 对了但**字段键名**不对（看同日志里打出的"首条记录的键"）。
    private static func withRegionShapes(
        region: NiuwaRegion,
        _ attempt: (Any, String) async throws -> [NiuwaApp]
    ) async throws -> [NiuwaApp] {
        let log = LoginLogger.shared
        let shapes: [(Any, String)] = [
            (region.index, "数字 \(region.index)"),
            (String(region.index), "字符串 \"\(region.index)\""),
            (region.rawValue, "字符串 \"\(region.rawValue)\""),
        ]
        var firstError: Error?
        for (i, shape) in shapes.enumerated() {
            let isLast = (i == shapes.count - 1)
            do {
                let apps = try await attempt(shape.0, shape.1)
                if !apps.isEmpty { return apps }
                // 空列表不一定是错（可能真没这款应用），所以只记日志继续试
                log.log("\(logTag) region=\(shape.1) 返回空列表" + (isLast ? "" : " → 换下一种形态"),
                        category: .appStore)
            } catch {
                if firstError == nil { firstError = error }
                log.log("\(logTag) region=\(shape.1) 失败（\(error.localizedDescription)）"
                        + (isLast ? "" : " → 换下一种形态"), category: .appStore)
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
        log.log("\(logTag) ← 响应体 \(truncate(raw))", category: .appStore)

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.log("\(logTag) ✗ 响应不是 JSON 对象", category: .appStore)
            throw StoreError.decode
        }

        let code = string(obj["nwcore_code"]) ?? string(obj["code"]) ?? "-"
        let message = string(obj["nwcore_messages"])
            ?? (obj["nwcore_messages"] as? [Any])?.map { string($0) ?? "" }.joined(separator: "；")
            ?? string(obj["message"])
            ?? ""

        // 候选键逐个试（顺序见 `listKeyCandidates`）
        for key in listKeyCandidates {
            guard let arr = obj[key] as? [[String: Any]] else { continue }
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

        // 一个都没命中 → 把**实际键名**暴露出来（这是下一轮定案的唯一依据）
        let actualKeys = obj.keys.sorted().joined(separator: ", ")
        let detail = "响应键：\(actualKeys)"
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
