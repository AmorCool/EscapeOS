import Foundation

public struct Cookie: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var value: String
    public var path: String
    public var domain: String?
    public var expiresAt: TimeInterval?
    public var httpOnly: Bool
    public var secure: Bool
    /// nil preserves legacy domain-cookie semantics; new host-only cookies are explicitly true.
    public var hostOnly: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, value, path, domain, expiresAt, httpOnly, secure, hostOnly
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        value = try values.decode(String.self, forKey: .value)
        path = try values.decode(String.self, forKey: .path)
        domain = try values.decodeIfPresent(String.self, forKey: .domain)
        expiresAt = try values.decodeIfPresent(TimeInterval.self, forKey: .expiresAt)
        httpOnly = try values.decode(Bool.self, forKey: .httpOnly)
        secure = try values.decode(Bool.self, forKey: .secure)
        hostOnly = try values.decodeIfPresent(Bool.self, forKey: .hostOnly)
    }

    public init(name: String, value: String, path: String, domain: String? = nil,
                expiresAt: TimeInterval? = nil, httpOnly: Bool, secure: Bool,
                hostOnly: Bool? = nil) {
        self.name = name
        self.value = value
        self.path = path
        self.domain = domain
        self.expiresAt = expiresAt
        self.httpOnly = httpOnly
        self.secure = secure
        self.hostOnly = hostOnly
    }

    var normalizedDomain: String {
        String((domain ?? "").drop(while: { $0 == "." })).lowercased()
    }

    var storageKey: String { "\(name)\u{0}\(normalizedDomain)\u{0}\(path)" }
}

public extension Cookie {
    init(copyFrom cookie: HTTPClient.Cookie) {
        let expires = cookie.maxAge.map { Date().addingTimeInterval(TimeInterval($0)).timeIntervalSince1970 }
            ?? cookie.expiresAt
        self.init(name: cookie.name, value: cookie.value, path: cookie.path,
                  domain: cookie.domain, expiresAt: expires,
                  httpOnly: cookie.httpOnly, secure: cookie.secure, hostOnly: cookie.hostOnly)
    }
}

public extension [Cookie] {
    mutating func mergeCookies(_ cookies: [HTTPClient.Cookie]) {
        // RFC 6265 identity is (name, domain, path), not name alone.
        var merged: [String: Cookie] = [:]
        for var cookie in self {
            cookie.domain = cookie.normalizedDomain
            if cookie.expiresAt.map({ $0 > Date().timeIntervalSince1970 }) ?? true {
                merged[cookie.storageKey] = cookie
            }
        }
        for incoming in cookies {
            var cookie = Cookie(copyFrom: incoming)
            cookie.domain = cookie.normalizedDomain
            if let expiry = cookie.expiresAt, expiry <= Date().timeIntervalSince1970 {
                merged[cookie.storageKey] = nil
            } else {
                merged[cookie.storageKey] = cookie
            }
        }
        self = merged.values.sorted { $0.storageKey < $1.storageKey }
    }

    func buildCookieHeader(_ endpoint: URL) -> [(String, String)] {
        guard let host = endpoint.host?.lowercased() else { return [] }
        let path = endpoint.path.isEmpty ? "/" : endpoint.path
        let now = Date().timeIntervalSince1970
        let valid = filter { cookie in
            let domain = cookie.normalizedDomain
            guard !cookie.name.isEmpty, !domain.isEmpty,
                  !cookie.name.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "=" }),
                  !cookie.value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ";" }) else { return false }
            guard host == domain || (cookie.hostOnly != true && host.hasSuffix("." + domain)) else { return false }
            if cookie.secure && endpoint.scheme?.lowercased() != "https" { return false }
            if let expiry = cookie.expiresAt, expiry <= now { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return path == cookiePath || (path.hasPrefix(cookiePath)
                && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).first == "/"))
        }.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
            return lhs.storageKey < rhs.storageKey
        }
        guard !valid.isEmpty else { return [] }
        return [("Cookie", valid.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))]
    }
}
