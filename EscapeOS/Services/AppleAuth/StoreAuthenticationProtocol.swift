import Foundation

enum StoreAuthenticationError: LocalizedError {
    case codeRequired
    case invalidCode
    case invalidConfiguration
    case invalidRedirect
    case serviceResponse(Int)
    case rejected(String)
    case tooManyAttempts

    var needsCode: Bool {
        switch self {
        case .codeRequired, .invalidCode: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .codeRequired:
            return "请输入 Apple 发送的验证码后重试"
        case .invalidCode:
            return "验证码被拒绝，请重新获取后重试"
        case .invalidConfiguration:
            return "Apple 返回的登录配置不受支持（SAP 资产缺失或版本变化）"
        case .invalidRedirect:
            return "Apple 返回了非法的登录跳转，凭据未被转发"
        case let .serviceResponse(status):
            return "登录服务返回异常（HTTP \(status)）——不是密码错或验证码问题，请稍后重试"
        case let .rejected(message):
            return message
        case .tooManyAttempts:
            return "重试次数过多，请稍后再试"
        }
    }
}

/// Pure protocol rules, shared by production requests and regression checks.
enum StoreAuthenticationProtocol {
    static let authenticationPath = "/WebObjects/MZFinance.woa/wa/authenticate"

    static func authenticationURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              host == "buy.itunes.apple.com" || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil,
              url.path == authenticationPath
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
        // Only retry unstructured transient responses, never a credential/2FA rejection.
        guard plist(data) == nil else { return false }
        return status == 204 || status == 404 || (500 ... 599).contains(status)
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

    /// Foundation preserves a leading dot on domain cookies; ApplePackage 1.2.7
    /// expects a bare domain when deciding which cookies to send to store pods.
    static func storeCookieDomain(_ domain: String?) -> String? {
        domain.map { String($0.drop(while: { $0 == "." })).lowercased() }
    }

    /// Restore ApplePackage's domain/subdomain semantics in Foundation's jar.
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
