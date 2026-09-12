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

    static func authenticationURL(_ value: String) throws -> URL {
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

    static func retryable(status: Int, data: Data) -> Bool {
        // Never replay empty/ambiguous login refusals, 429, or structured credential/2FA errors.
        !data.isEmpty && plist(data) == nil && [502, 503, 504].contains(status)
    }

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
