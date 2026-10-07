import Foundation

// MARK: - 软件源错误枚举
//
// 文案见规格 §2.4（对齐牛蛙原文案，去掉「牛蛙助手」字样）。

enum SignSourceError: LocalizedError, Equatable {
    /// 源地址不是合法 URL / scheme 非 http(s)
    case invalidURL(String)
    /// URLSession 抛（含超时）
    case network(String)
    /// 有响应但非 2xx
    case http(Int)
    /// 200 但不是 JSON（可能是 HTML 错误页 / 门户页）
    case notJSON
    /// RSA 层失败（私钥不可用 / 解密失败 / 整源两轮试解后仍非 JSON）
    case rsa(String)
    /// **信封存在但非 RSA**（非 256 对齐 ⇒ 流密码；或全能签 V2 的 Base62）⇒ 优雅降级，不崩不误判
    case unsupportedCipher(String)
    /// 缺 sourceURL/name/identifier，或 apps 为空
    case missingFields(String)
    /// E2 非 JSON / 网络失败
    case unlockFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效源地址"
        case .network(let m):
            return "网络错误：\(m)"
        case .http(let code):
            return "源返回 HTTP \(code)"
        case .notJSON:
            return "此源不受支持（响应不是 JSON）"
        case .rsa:
            return "源内容解密失败（加密源，密钥不匹配）"
        case .unsupportedCipher:
            return "此源使用了暂不支持的加密方式"
        case .missingFields:
            return "此源不受支持"
        case .unlockFailed(let m):
            return "解锁失败：\(m)"
        }
    }
}

// MARK: - 软件源网络层

/// 软件源（用户自定义第三方源）的**网络层**。
///
/// 与 `NiuwaStoreClient`（牛蛙内置商店）**零关系**：
/// · 本类 = 明文 GET + 用户输入的任意域名 + 可选 RSA 解密；
/// · 彼类 = AES-256-GCM 加密 POST + 硬编码 api.ios222.com。
/// ⚠️ 严禁把本类任何请求套进 `NiuwaStoreClient.postJSON` / `NiuwaCrypto`。
///
/// 端点（规格 §0 / §2 / §5）：
/// · E1 拉源 `GET {sourceURL}?udid={UDID}`
/// · E2 解锁 `GET {unlockURL}?udid={UDID}&code={code}`
/// · E3 取解锁码走系统 `openURL(payURL)`（属视图层，不在本层）
///
/// 筛选与搜索是**本地**做的（不是服务端参数）——本层不处理。
enum SignSourceClient {

    /// 日志前缀（真机 grep 用）
    static let logTag = "[软件源]"

    // MARK: - 对外接口

    /// E1 拉源：`GET {sourceURL}?udid={UDID}`。
    ///
    /// - 源 URL **约定不带 query**（模板是 `%@?udid=%@`）；若已带 query（用户粘贴了带参数的 URL），
    ///   保留原 query 再 append `udid`。
    /// - `udid` 取缓存；取不到时**仍发请求但省略该参数**（服务端行为未定，规格 §9 R3）。
    static func fetch(sourceURL: String) async throws -> SignSource {
        let udid = currentUDID()
        var extra: [URLQueryItem] = []
        if let udid { extra.append(URLQueryItem(name: "udid", value: udid)) }
        guard let url = makeURL(sourceURL, extraQuery: extra) else {
            throw SignSourceError.invalidURL(sourceURL)
        }
        LoginLogger.shared.log("\(logTag) → GET \(url.absoluteString)（udid=\(udid ?? "省略")）",
                               category: .appStore)
        let data = try await getJSON(url)
        return try parse(data, origin: sourceURL)
    }

    /// E2 解锁校验：`GET {unlockURL}?udid={UDID}&code={code}`。
    ///
    /// - `code` **原样拼接、不做 URL 编码**（复刻牛蛙行为，规格 §5.1 / §9 R5）。
    /// - 成功判据 = 响应体可解析为 JSON（不消费任何字段）。
    /// - 成功后调用方负责**重拉 E1**（本函数不做刷新，规格 §5.3）。
    /// - 两级 `unlockURL` 都为空 ⇒ 直接抛 `.unlockFailed`，不发请求（规格 §5.1）。
    static func unlock(unlockURL: String, code: String) async throws {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SignSourceError.unlockFailed("解锁码不能为空")
        }
        let base = unlockURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw SignSourceError.unlockFailed("该源未提供解锁接口")
        }
        // code 原样拼接、不做 URL 编码（复刻牛蛙 stringWithFormat:@"%@?udid=%@&code=%@"）
        let sep = base.contains("?") ? "&" : "?"
        var urlString = base + sep
        if let udid = currentUDID() { urlString += "udid=\(udid)&" }
        urlString += "code=\(code)"
        guard let url = URL(string: urlString) else {
            throw SignSourceError.unlockFailed("解锁地址无效")
        }
        LoginLogger.shared.log("\(logTag) → GET（解锁）\(url.absoluteString)", category: .appStore)
        let data: Data
        do {
            data = try await getJSON(url)
        } catch {
            throw SignSourceError.unlockFailed(error.localizedDescription)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw SignSourceError.unlockFailed("数据错误")
        }
        // 成功：什么都不做（真正的状态在服务端，规格 §5.2）
    }

    /// 响应体 → `SignSource`（明文直用 / RSA 信封自动识别）。抽出来便于单测与抓包期调试。
    ///
    /// 主流程见规格 §2.3：
    /// ① data → `[String: Any]`（失败 `.notJSON`）
    /// ② 含信封键 ⇒ `SignSourceRSA.decryptEnvelopeIfPresent`（明文封装 / RSA / 优雅降级），
    ///    解出的明文重新解析；无信封键 ⇒ 明文透传
    /// ③ 校验 sourceURL / name / identifier 非空 且 apps 是非空数组（失败 `.missingFields`）
    /// ④ apps[] → `[SignSourceApp]`（lossy：逐条解码失败的跳过并打日志）
    /// ⑤ 归一化：空串 → nil（已在模型解码层做）、http→https、回填、继承
    /// ⑥ 解码后 apps 为空 ⇒ `.missingFields`
    ///
    /// - Parameter origin: 用户输入的原始 sourceURL，用于源 JSON 缺 `sourceURL` 时回填。
    static func parse(_ data: Data, origin: String) throws -> SignSource {
        // ① 顶层 JSON 对象
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SignSourceError.notJSON
        }

        // ② 信封键 → RSA / 明文封装 / 优雅降级；无信封键 → 明文透传
        let effective: [String: Any]
        if let plain = try SignSourceRSA.decryptEnvelopeIfPresent(root, body: data) {
            guard let r2 = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
                throw SignSourceError.rsa("解密结果不是 JSON 对象")
            }
            effective = r2
        } else {
            effective = root
        }

        // ③ 必填字段校验（让 Codable 只管映射，报错在这里显式做）
        guard let identifier = string(effective["identifier"]) else {
            throw SignSourceError.missingFields("缺少 identifier")
        }
        guard let name = string(effective["name"]) else {
            throw SignSourceError.missingFields("缺少 name")
        }
        guard let sourceURL = string(effective["sourceURL"]) ?? string(origin) else {
            throw SignSourceError.missingFields("缺少 sourceURL")
        }
        guard let rawApps = effective["apps"] as? [[String: Any]], !rawApps.isEmpty else {
            throw SignSourceError.missingFields("apps 为空或非数组")
        }

        // ④ apps 逐条 lossy 解码（坏记录跳过并打日志，不整批失败）
        var apps: [SignSourceApp] = []
        let decoder = JSONDecoder()
        for (i, obj) in rawApps.enumerated() {
            guard let d = try? JSONSerialization.data(withJSONObject: obj),
                  let app = try? decoder.decode(SignSourceApp.self, from: d) else {
                LoginLogger.shared.log("\(logTag) apps[\(i)] 解析失败：键=[\(obj.keys.sorted().joined(separator: ","))]",
                                       category: .appStore)
                continue
            }
            apps.append(app)
        }

        // ⑤ 归一化 + 回填 + 继承
        var source = SignSource(
            identifier: identifier,
            name: name,
            sourceURL: normalizeAsset(sourceURL) ?? sourceURL,
            sourceIcon: normalizeAsset(string(effective["sourceicon"])),
            message: string(effective["message"]),
            payURL: normalizeAsset(string(effective["payURL"])),
            unlockURL: normalizeAsset(string(effective["unlockURL"])),
            apps: apps
        )
        // App 级 URL 归一化（http → https，ATS）
        for i in source.apps.indices {
            source.apps[i].downloadURL = normalizeAsset(source.apps[i].downloadURL)
            source.apps[i].iconURL = normalizeAsset(source.apps[i].iconURL)
            source.apps[i].payURL = normalizeAsset(source.apps[i].payURL)
            source.apps[i].unlockURL = normalizeAsset(source.apps[i].unlockURL)
        }
        // 回填 sourceURL / sourceName + App 级 payURL / unlockURL 继承源级
        source.applyInheritance()

        // ⑥ 全部 App 在 ④ 被跳过 ⇒ 与「apps 为空」同款处理
        guard !source.apps.isEmpty else {
            throw SignSourceError.missingFields("apps 全部解析失败")
        }
        LoginLogger.shared.log("\(logTag) 解析完成：\(source.name)（\(source.apps.count) 个 App）",
                               category: .appStore)
        return source
    }

    // MARK: - 请求

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15          // 源是第三方服务器，比内置商店给宽一点
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData   // 源内容会变，别吃缓存
        // 不设自定义 UA / 额外 header（牛蛙原版 sharedSession 无额外 header）
        return URLSession(configuration: cfg)
    }()

    /// GET 取原始响应体。非 2xx → `.http`；超时 → `.network("请求超时")`。
    private static func getJSON(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SignSourceError.http(http.statusCode)
            }
            return data
        } catch let e as SignSourceError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw SignSourceError.network("请求超时")
        } catch {
            throw SignSourceError.network(error.localizedDescription)
        }
    }

    // MARK: - UDID

    /// 取本机 UDID（**只吃缓存、绝不建隧道**，规格 §6）。
    /// 冷缓存 → 后台预热，本次请求省略 `udid` 参数（更诚实，不伪造设备标识）。
    private static func currentUDID() -> String? {
        if let snap = LocalDeviceIdentity.cachedSnapshot(),
           let udid = snap.udid?.trimmingCharacters(in: .whitespaces), !udid.isEmpty {
            return udid
        }
        LocalDeviceIdentity.warmUpInBackground()
        return nil
    }

    // MARK: - 工具

    /// 组 URL：校验 scheme 为 http(s)，保留原 query 再 append 额外参数。
    private static func makeURL(_ base: String, extraQuery: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        var items = comps.queryItems ?? []
        items.append(contentsOf: extraQuery)
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    /// ATS：明文 http 一律升 https（照 `NiuwaStoreClient.normalizeAsset`，规格 §1.2）。
    private static func normalizeAsset(_ raw: String?) -> String? {
        guard var v = raw?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if v.hasPrefix("http://") {
            v = "https://" + String(v.dropFirst("http://".count))
        }
        return v
    }

    /// 取值兜底：`String` / `NSNumber` → 非空 `String?`（照 `NiuwaStoreClient.string`）。
    private static func string(_ v: Any?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}
