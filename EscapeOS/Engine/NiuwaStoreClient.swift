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
/// - 响应信封 `{ nwcore_code, nwcore_list, nwcore_messages }`（另有 `nwcore_status`），
///   搜索结果数组属性名为 `nwcore_apps`
///
/// **本版只做探测 + 接线**：只取直链（`download` 只回 `NiuwaApp`，不落盘、不安装），
/// 下载/安装仍走既有 `IPADownloadCenter`（下一轮再考虑接牛蛙直链）。
///
/// 因为区域到底传什么字符串**未确证**，本版把请求体（UDID 打码）、HTTP 状态码、
/// 响应体原文全量写进 `LoginLogger`（`category: .appStore`），前缀 `[牛蛙源]` ——
/// 目的是让一次真机点击就能拿到真实响应，再据此校正。
enum NiuwaStoreClient {

    // MARK: - 常量

    static let host = "https://api.ios222.com"
    static let searchPath = "/appstore/search"
    static let downloadPath = "/appstore/download"

    /// v0.3.382：日志前缀（真机上按这个 grep 就能捞到全部牛蛙请求）
    static let logTag = "[牛蛙源]"

    /// 响应体原文最多打进日志的字数（一次搜索的 JSON 可能几十 KB，只留头部够定位结构）
    private static let logBodyLimit = 2000

    // MARK: - 区域

    /// 客户端硬编码的三档区域（中文串「中国 / 美国 / 香港」来自
    /// `NWCoreClassAppStoreSearchTableViewCell` 附近的 NSInteger 分段索引）。
    ///
    /// **`rawValue` 就是线上 `region` 参数**。当前用 ISO 3166-1 alpha-2 小写试；
    /// 若真机日志里 `nwcore_code` 非 0 / 列表为空，改这里的 `rawValue` 即可（一行）。
    enum NiuwaRegion: String, CaseIterable, Identifiable {
        case cn = "cn"
        case us = "us"
        case hk = "hk"

        var id: String { rawValue }

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
    /// 字段名两套并存（服务端键惯例 `nwcore_` 前缀 + iTunes 风格），解析时都兼容：
    /// `nwcore_app_id` / `nwcore_bundleid` / `nwcore_name` / `nwcore_desc` /
    /// `nwcore_strVersion` / `nwcore_url` / `nwcore_ipaURL` / `nwcore_strAppSize` /
    /// `nwcore_strAppIconName`，以及 `trackName` / `artworkUrl512` /
    /// `currentVersionReleaseDate` / `iconURL` / `downloadURL`。
    struct NiuwaApp: Identifiable, Hashable {
        /// 牛蛙侧 app id（`nwcore_app_id`）
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
        /// 200 但信封里没有 `nwcore_apps` —— 把 `nwcore_code` / `nwcore_messages` 带上
        case server(code: String, message: String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "接口地址无效"
            case .http(let c): return "请求失败（HTTP \(c)）"
            case .decode: return "返回数据解析失败"
            case .server(let code, let message):
                return message.isEmpty ? "服务端返回错误码 \(code)" : "\(message)（\(code)）"
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

    /// 本 App 的 build 号（`CFBundleVersion`）—— 牛蛙的 `pub_version` 量级与之相符
    private static var pubVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// 公共参数五项（`pub_*`）—— 这就是牛蛙的"免登录"身份，没有 token / Authorization / uid
    private static func pubParams(iPad: Bool) -> [String: String] {
        [
            "pub_version": pubVersion,
            "pub_udid": pubUDID,
            "pub_lang": DeviceInfoService.userLocaleIdentifier() ?? "zh-Hans-CN",
            "pub_platform": iPad ? "iPadOS" : "iOS",
            "pub_system_version": pubSystemVersion,
        ]
    }

    private static func postJSON(_ path: String, body: [String: String]) async throws -> Data {
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
        var body = pubParams(iPad: iPad)
        body["keyword"] = kw
        body["region"] = region.rawValue
        return try await perform(path: searchPath, body: body, region: region)
    }

    // MARK: - 下载（只取直链，不下载文件）

    /// 按 bundleId 取安装包直链；服务端没给直链时返回 `nil`。
    static func download(bundleId: String, region: NiuwaRegion, iPad: Bool = true) async throws -> NiuwaApp? {
        let bid = bundleId.trimmingCharacters(in: .whitespaces)
        guard !bid.isEmpty else { return nil }
        var body = pubParams(iPad: iPad)
        body["bundleid"] = bid
        body["region"] = region.rawValue
        return try await perform(path: downloadPath, body: body, region: region).first
    }

    // MARK: - 请求 + 全量诊断日志

    /// 发一次请求，**把请求体（UDID 打码）/ HTTP 状态码 / 响应体原文全打进 `LoginLogger`**。
    ///
    /// 失败三分：
    /// - `network`：URLSession 直接抛（没有 HTTP 响应）
    /// - `http(N)`：有响应但非 2xx
    /// - `server(code:message:)`：200 但信封里没有 `nwcore_apps`（把 `nwcore_code` /
    ///   `nwcore_messages` 原文带上）
    private static func perform(path: String, body: [String: String],
                                region: NiuwaRegion) async throws -> [NiuwaApp] {
        let log = LoginLogger.shared
        log.log("\(logTag) → POST \(host)\(path) region=\(region.rawValue)", category: .appStore)
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
        log.log("\(logTag) ← 200 响应体 \(truncate(raw))", category: .appStore)

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log.log("\(logTag) ✗ 响应不是 JSON 对象", category: .appStore)
            throw StoreError.decode
        }

        let code = string(obj["nwcore_code"]) ?? "-"
        let message = string(obj["nwcore_messages"])
            ?? (obj["nwcore_messages"] as? [Any])?.map { string($0) ?? "" }.joined(separator: "；")
            ?? ""
        let rawApps = obj["nwcore_apps"] as? [[String: Any]]
        guard let rawApps else {
            log.log("\(logTag) ✗ 信封无 nwcore_apps（nwcore_code=\(code) messages=\(message.isEmpty ? "-" : message)）",
                    category: .appStore)
            throw StoreError.server(code: code, message: message)
        }

        let apps = rawApps.compactMap(parse)
        log.log("\(logTag) ✓ nwcore_code=\(code) 解析出 \(apps.count)/\(rawApps.count) 条（region=\(region.rawValue)）",
                category: .appStore)
        return apps
    }

    /// 请求体转日志文本：`pub_udid` 只留前后 4 位
    private static func describeBody(_ body: [String: String]) -> String {
        let sorted = body.keys.sorted().map { key -> String in
            let value = key == "pub_udid" ? maskUDID(body[key] ?? "") : (body[key] ?? "")
            return "\(key)=\(value)"
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

    private static func parse(_ d: [String: Any]) -> NiuwaApp? {
        guard let bundleId = string(d["nwcore_bundleid"]) ?? string(d["bundleId"]),
              !bundleId.isEmpty else { return nil }
        let name = string(d["nwcore_name"]) ?? string(d["trackName"]) ?? bundleId
        var app = NiuwaApp(bundleId: bundleId, name: name)
        app.appId = string(d["nwcore_app_id"]) ?? string(d["appId"])
        app.desc = string(d["nwcore_desc"]) ?? string(d["desc"])
        app.version = string(d["nwcore_strVersion"]) ?? string(d["version"])
        app.sizeText = string(d["nwcore_strAppSize"]) ?? string(d["sizeText"])
        app.iconURL = normalizeAsset(string(d["nwcore_strAppIconName"])
            ?? string(d["artworkUrl512"])
            ?? string(d["iconURL"]))
        app.downloadURL = normalizeAsset(string(d["nwcore_ipaURL"])
            ?? string(d["nwcore_url"])
            ?? string(d["downloadURL"]))
        app.releaseDate = string(d["currentVersionReleaseDate"])
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
