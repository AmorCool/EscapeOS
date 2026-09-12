import Foundation

enum StoreAuthenticationError: LocalizedError, Sendable {
    case codeRequired
    case invalidCode
    case invalidConfiguration
    case invalidRedirect
    case serviceResponse(Int)
    case missingRedirect(Int)
    case unstructuredResponse(Int, empty: Bool)
    case rateLimited(retryAfter: TimeInterval?)
    case cooldown(Int)
    case accountChanged
    case credentialsRequired
    case rejected(String)
    case tooManyAttempts

    var needsCode: Bool {
        switch self {
        case .codeRequired, .invalidCode: return true
        default: return false
        }
    }

    /// Local backoff, not a claim about Apple's IP/account restriction duration.
    var backoffInterval: TimeInterval? {
        switch self {
        case let .rateLimited(delay): return max(60, delay ?? 60)
        case .missingRedirect, .unstructuredResponse: return 60
        case let .serviceResponse(status) where status >= 500: return 60
        default: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .codeRequired:
            return "请输入 Apple 发送的验证码后重试"
        case .invalidCode:
            return "验证码被拒绝，请重新获取后重试"
        case .invalidConfiguration:
            return "Apple 返回的登录配置不受支持（请检查 SAP 资产与设备标识）"
        case .invalidRedirect:
            return "Apple 返回了不受信任的商店跳转，凭据未被转发"
        case let .serviceResponse(status):
            return "登录服务响应异常（HTTP \(status)）。仅凭此响应无法判断账号、网络或服务端原因，请查看商店日志。"
        case let .missingRedirect(status):
            return "Apple 登录返回 HTTP \(status)，但缺少有效的 Location 跳转地址。已停止自动重试并保留现有账号；这不能单独证明是 IP 限流或密码错误。"
        case let .unstructuredResponse(status, empty):
            return "Apple 登录返回 HTTP \(status)（\(empty ? "空响应" : "非预期响应")），没有提供可识别的认证结果。已保留现有账号，请稍后重试并查看商店日志。"
        case let .rateLimited(delay):
            if let delay { return "Apple 登录请求受限（HTTP 429），请至少等待 \(Int(ceil(delay))) 秒后再试。" }
            return "Apple 登录请求受限（HTTP 429），请稍后再试。"
        case let .cooldown(seconds):
            return "上次登录响应异常，为避免重复发送密码，本应用暂缓自动登录；请约 \(seconds) 秒后重试。现有账号未被删除。"
        case .accountChanged:
            return "操作期间账号已退出或更换，请重新选择账号。"
        case .credentialsRequired:
            return "保存的凭据不完整，请到账号管理重新登录 Apple ID。"
        case let .rejected(message):
            return message
        case .tooManyAttempts:
            return "登录跳转或协议重试次数过多，已停止请求，请稍后再试。"
        }
    }
}

/// Pure protocol rules, shared by production requests and regression checks.
enum StoreAuthenticationProtocol {
    static let authenticationPath = "/WebObjects/MZFinance.woa/wa/authenticate"

    /// v0.3.355：Apple 的**前置边缘按 `Content-Type` 路由请求体**（PC 复现，2026-09-12：
    /// 同一份 XML plist body，`x-www-form-urlencoded` → 404 + 146 字节 HTML 错误页，
    /// `x-apple-plist` → 204 空响应）。两者都不是认证结论，说明请求没进到认证应用。
    /// 真机日志里反复出现的「HTTP 204 空响应」「HTTP 403/404 + 146 字节」就是这个形状。
    /// 所以先按上游 ipatool 的写法发一次，被边缘拒了再换 Apple 自家商店客户端的写法发一次。
    static let primaryContentType = "application/x-www-form-urlencoded"
    static let alternateContentType = "application/x-apple-plist"

    /// v0.3.356：**二改版 AssppPro 4.2.5 的登录请求是这么发的**（从它的二进制字面量直接挖出来，
    /// strings @0x46414-0x46419，紧挨着 `MZFinance.woa/wa/authenticate/`）：
    ///   · `Accept: application/xml, application/x-apple-plist, text/xml`
    ///   · 端点默认值 **带尾斜杠** `…/authenticate/`
    /// 我们此前两样都没有。PC 复现显示，同一个 URL 加不加 `Accept`、带不带尾斜杠，
    /// Apple 前置回的状态码都不一样（301/204/403/404 混着来）—— 说明这两项影响**前置路由**。
    /// 所以按参考客户端对齐：一律带 `Accept`，被前置拒了再试一次尾斜杠变体。
    static let storeClientAccept = "application/xml, application/x-apple-plist, text/xml"

    /// v0.3.357：**现代认证端点** `auth.itunes.apple.com/auth/v1/native/fast/`。
    ///
    /// 依据：dompling/Jsbox-Ipa（JAsspp 0.2.1，`config.js:52-53` + `auth.js:187-202`）把
    /// native 端点列为**第一候选**，bag 给的 auth.itunes.apple.com 端点还会补 `/fast`；
    /// 候选顺序是 native → bag → legacy。对照我们的现实：bag 给的是 legacy
    /// `buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate`，而 Apple 前置对它
    /// 只回 204 空响应 / 301 / 403 / 404（真机日志 + PC 复现），**从来没进到认证应用**。
    /// 所以把 native 端点作为兜底候选加进登录梯子。
    static let nativeFastHost = "auth.itunes.apple.com"
    static let nativeFastPath = "/auth/v1/native/fast"

    /// 规范化 native 端点：**bag 给出的 native 地址通常缺少 `/fast` 子路径**。
    ///
    /// 依据：Jsbox-Ipa `bag.js:33-53` 的 `normalizeAuthURL` —— host 是
    /// `auth.itunes.apple.com` 时一律把路径补成 `…/native/fast/`（去掉多余尾斜杠、
    /// 缺 `/fast` 就补上、再补回一个尾斜杠），并保留原有查询串；legacy 端点原样返回。
    /// 它的注释原话：「bag 中的 native 认证端点缺少 /fast/ 子路径，直接访问会 301 到 HTML」。
    ///
    /// 我们此前只按**精确路径**放行 native，bag 一旦返回 native 就 `invalidRedirect` ——
    /// 这正是「bag 拿到了却登不上」的那一半。所以按同一规则规范化。
    static func nativeFastURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, isNativeFastHost(host),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443
        else { return nil }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // 只接受 native 家族的路径；避免把 host 上的意外路径拼成 /fast/ 这种畸形端点。
        guard path.lowercased().contains("/native") else { return nil }
        if !path.hasSuffix("/fast") { path += "/fast" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = path + "/"
        return components?.url
    }

    static func nativeFastAuthenticationURL(guid: String) -> URL? {
        nativeFastURL("https://\(nativeFastHost)\(nativeFastPath)/?guid=\(guid)")
    }

    static func isNativeFastHost(_ host: String) -> Bool {
        host.lowercased() == nativeFastHost
    }

    /// 设备标识：Jsbox-Ipa 两处放宽口径一致 —— `device.js:11` 用
    /// `/^[0-9a-f]{12,32}$/i`，`sap.js:884` 用 `/^(?:[0-9A-F]{2}){1,20}$/`
    /// （偶数长度十六进制、大小写不敏感）。
    ///
    /// 我们只认**恰好 12 位**，真机 `invalidConfiguration` 的来源之一：本地
    /// `device_guid.txt` 是从旧版本 `UserDefaults` 迁移过来的**任意非空串**
    /// （`AppStoreDownloadStore.bootstrapDeviceIdentifier` 不校验格式），长度一旦不是 12
    /// 就直接放弃登录。这里放宽到与参考实现一致，硬件 ID 仍取**前 12 位**（6 字节）。
    static func isDeviceGUID(_ value: String) -> Bool {
        guard (12 ... 32).contains(value.count), value.count.isMultiple(of: 2) else { return false }
        return value.allSatisfy(\.isHexDigit)
    }

    /// v0.3.357：SAP 端点的**硬编码兜底**（Jsbox-Ipa `sap.js:24-25` 同款）。
    /// bag 拿不到/不合规时不该让整次登录直接 `invalidConfiguration`。
    static let fallbackSAPCertURL = "https://s.mzstatic.com/sap/setupCert.plist"
    static let fallbackSAPSetupURL = "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy"

    /// 尾斜杠变体：`…/authenticate` → `…/authenticate/`（Apple 的 nginx 会用 301 提示规范的路径形态）
    static func trailingSlashVariant(_ url: URL) -> URL? {
        guard !url.path.hasSuffix("/") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = url.path + "/"
        return components?.url
    }

    static func authenticationURL(_ value: String) throws -> URL {
        // native/fast 是独立 host，先按参考客户端规则**规范化路径**再放行
        // （bag 返回的 native 地址常缺 `/fast`；其它一切仍走 storeURL 白名单）。
        if let url = URL(string: value), let host = url.host, isNativeFastHost(host) {
            guard let normalized = nativeFastURL(value) else {
                throw StoreAuthenticationError.invalidRedirect
            }
            return normalized
        }
        let url = try storeURL(value, paths: [authenticationPath])
        guard isBuyHost(url.host ?? "") else { throw StoreAuthenticationError.invalidRedirect }
        return url
    }

    static func isBuyHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "buy.itunes.apple.com"
            || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
    }

    static func storeURL(_ value: String, paths: Set<String>) throws -> URL {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              paths.contains(url.path),
              isBuyHost(host) || (host == "downloaddispatch.itunes.apple.com" && url.path == "/r/redownload")
        else { throw StoreAuthenticationError.invalidRedirect }
        return url
    }

    static func plist(_ data: Data) -> [String: Any]? {
        var payload = data
        // bag.xml wraps a plist in Document/Protocol; login replies are ordinary plists.
        if let xml = String(data: data, encoding: .utf8),
           let start = xml.range(of: "<plist"), let end = xml.range(of: "</plist>"),
           start.lowerBound < end.upperBound {
            payload = Data(xml[start.lowerBound ..< end.upperBound].utf8)
        }
        return (try? PropertyListSerialization.propertyList(from: payload, format: nil)) as? [String: Any]
    }

    static func body(email: String, password: String, code: String, guid: String, attempt: Int) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "appleId": email,
            "password": password + code.filter { !$0.isWhitespace },
            "guid": guid,
            "attempt": String(attempt),
            "rmp": "0",
            "why": "signIn",
        ], format: .xml, options: 0)
    }

    /// 认证请求是否值得**原样重发**（同一份 body + 新签名）。
    ///
    /// v0.3.353：对齐上游 ipatool `retryableAuthenticationError` —— 它重试的是
    /// **204 No Content / 404 / 5xx**（最多 3 次，延迟 250ms × 第几次）。
    /// Apple 边缘在瞬时拒绝时回的就是这几个码（真机日志里 204 / 404 / 500 / 503 都出现过），
    /// 老实现只认 502/503/504 且额外要求「body 非空且不是 plist」→ **204（空 body）与
    /// 404（HTML）直接被判死**，还会顺带触发 60 秒本地冷却，表现就是「每次登录都不成」。
    ///
    /// 另外把「3xx **但没有 Location**」也纳入重试：那是 Apple 边缘的畸形应答，
    /// 没有可跟随的跳转地址，直接判死等于把一次瞬时抖动升级成一次登录失败。
    static func retryable(status: Int, hasRedirect: Bool) -> Bool {
        if status == 204 || status == 404 || (500 ... 599).contains(status) { return true }
        return (300 ... 399).contains(status) && !hasRedirect
    }

    /// 与 ipatool `authenticationRetryDelay` 同款：250ms × 第几次。
    static func retryDelay(attempt: Int) -> Duration { .milliseconds(250 * attempt) }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(text), seconds.isFinite, seconds >= 0 { return min(seconds, 604800) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: text).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func rejection(_ plist: [String: Any], code: String) -> StoreAuthenticationError? {
        let failure = string(plist["failureType"])
        let message = string(plist["customerMessage"])
        if failure.isEmpty, code.isEmpty, message == "MZFinance.BadLogin.Configurator_message" {
            return .codeRequired
        }
        if failure == "5005" { return .invalidCode }
        if !failure.isEmpty { return .rejected(message.isEmpty ? "Apple rejected the login (\(failure))." : message) }
        if message == "Your account is disabled." || message == "MZFinance.AccountDisabled_message" { return .rejected(message) }
        return nil
    }

    static func storeCookieDomain(_ domain: String?) -> String? {
        domain.map { String($0.drop(while: { $0 == "." })).lowercased() }
    }

    static func foundationCookieDomain(_ domain: String?) -> String? {
        guard let domain = storeCookieDomain(domain),
              domain == "itunes.apple.com" || domain.hasSuffix(".itunes.apple.com")
        else { return nil }
        return "." + domain
    }

    static func storeIdentifier(_ header: String) -> String {
        String(header.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? "")
    }

    static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
