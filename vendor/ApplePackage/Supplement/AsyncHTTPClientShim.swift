import Foundation

// MARK: - AsyncHTTPClient 兼容层（EscapeSpace / Theos 适配）
//
// ApplePackage 原本依赖 `async-http-client`（SwiftPM），而它又拖着 swift-nio
// 全家桶（几十个包）。EscapeSpace 用 Theos 构建，**不支持 SwiftPM**，无法引入。
//
// 与其改动 23 个文件里的每一处网络调用，这里提供一个**签名兼容的 shim**：
// 底层用 `URLSession` 实现，调用点代码一行都不用改。
//
// 覆盖到的原 API：
// - `HTTPClient(eventLoopGroupProvider:configuration:)` / `shutdown()`
// - `HTTPClient.Configuration`（tlsConfiguration / redirectConfiguration / timeout）+ `.then {}`
// - `HTTPClient.Request(url:method:headers:body:)`、`.GET` / `.POST`
// - `client.execute(request:).get()`（用 async 替代 EventLoopFuture）
// - `HTTPClient.Response.status(.ok/.found/...)`、`.body`（ByteBuffer）、`.headers`
// - `HTTPClient.Cookie`（仅 Cookie.swift 用于读取 name/value/domain/path/expires）

// MARK: - ByteBuffer

/// 只实现 ApplePackage 用到的部分：`readData(length:)` / `readableBytes`。
public struct ByteBuffer {
    private var storage: Data
    private var readerIndex: Int = 0

    public init(data: Data) { self.storage = data }
    public init(bytes: [UInt8]) { self.storage = Data(bytes) }
    public init(_ data: Data) { self.storage = data }

    public var readableBytes: Int { storage.count - readerIndex }

    public mutating func readData(length: Int) -> Data? {
        guard length >= 0, readableBytes >= length else { return nil }
        let start = storage.startIndex + readerIndex
        let data = storage[start ..< (start + length)]
        readerIndex += length
        return data
    }

    public var data: Data { storage }
}

// MARK: - HTTP 方法 / 状态

public enum HTTPMethodShim: String {
    case GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS
}

/// 兼容调用点的 `body: .data(x)` / `body: .none` / `body: .byteBuffer(b)`。
public enum HTTPBodyShim {
    case none
    case data(Data)
    case byteBuffer(ByteBuffer)

    var bytes: Data? {
        switch self {
        case .none: return nil
        case .data(let d): return d
        case .byteBuffer(let b): return b.data
        }
    }
}

public struct HTTPResponseStatus: Equatable {
    public let code: UInt
    public init(code: UInt) { self.code = code }

    public static let ok = HTTPResponseStatus(code: 200)
    public static let found = HTTPResponseStatus(code: 302)
    public static let movedPermanently = HTTPResponseStatus(code: 301)
    public static let seeOther = HTTPResponseStatus(code: 303)
    public static let temporaryRedirect = HTTPResponseStatus(code: 307)
    public static let permanentRedirect = HTTPResponseStatus(code: 308)
    public static let badRequest = HTTPResponseStatus(code: 400)
    public static let unauthorized = HTTPResponseStatus(code: 401)
    public static let forbidden = HTTPResponseStatus(code: 403)
    public static let notFound = HTTPResponseStatus(code: 404)

    public static func == (lhs: HTTPResponseStatus, rhs: HTTPResponseStatus) -> Bool {
        lhs.code == rhs.code
    }
}

// MARK: - Headers

public struct HTTPHeaders {
    private var items: [(name: String, value: String)] = []

    public init() {}
    public init(_ pairs: [(String, String)]) {
        items = pairs.map { (name: $0.0, value: $0.1) }
    }

    public mutating func add(name: String, value: String) {
        items.append((name: name, value: value))
    }

    public func first(name: String) -> String? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var all: [(name: String, value: String)] { items }

    /// 兼容 `response.headers["x-set-apple-store-front"]` 这类下标访问：
    /// HTTP 头可以重复（Set-Cookie 尤其如此），所以返回**所有**同名值。
    public subscript(name: String) -> [String] {
        items.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map { $0.value }
    }
}


// MARK: - 构造参数占位类型（兼容调用点，实际行为由 URLSession 决定）

/// 原版是 NIOSSL 的 TLSConfiguration；Theos 下用不到自定义 TLS
/// （release 本就是标准验证），这里只保留调用点需要的接口形状。
public struct TLSConfiguration {
    public enum CertificateVerification { case none, fullVerification, noHostnameVerification }
    public var certificateVerification: CertificateVerification = .fullVerification
    public init() {}
    public static func makeClientConfiguration() -> TLSConfiguration { TLSConfiguration() }
}

/// 兼容 `$0.httpVersion = .http1Only`（URLSession 自动协商，这里仅占位）。
public enum HTTPVersionShim { case http1Only, http2 }

public struct RedirectConfiguration {
    public let max: Int
    public init(max: Int = 8) { self.max = max }
    /// 兼容 `.follow(max:allowCycles:)`。
    public static func follow(max: Int, allowCycles: Bool) -> RedirectConfiguration {
        RedirectConfiguration(max: max)
    }
    /// 不跟随重定向 —— 登录 / 购买 / 下载等接口要自己读 `Location` 头，
    /// 由调用方决定下一步（Authenticate / Purchase / Download / Version* 都在用）。
    public static let disallow = RedirectConfiguration(max: 0)
}

public struct TimeoutShim {
    public let connect: TimeInterval
    public let read: TimeInterval

    /// 兼容调用点 `.init(connect: .seconds(x), read: .seconds(y))`。
    public init(connect: TimeAmountShim, read: TimeAmountShim) {
        self.connect = TimeInterval(connect.seconds)
        self.read = TimeInterval(read.seconds)
    }

    public init(connect: TimeInterval, read: TimeInterval) {
        self.connect = connect
        self.read = read
    }
}

/// 兼容 `.seconds(Int64)` 写法。
public struct TimeAmountShim {
    public let seconds: Int64
    public init(seconds: Int64) { self.seconds = seconds }
    public static func seconds(_ value: Int64) -> TimeAmountShim { TimeAmountShim(seconds: value) }
}

/// Cookie.swift 只读取这些字段做转换。
public struct HTTPClientCookie {
    public let name: String
    public let value: String
    public let path: String
    public let domain: String
    public let maxAge: Int?
    public let httpOnly: Bool
    public let secure: Bool

    public init(name: String, value: String, path: String = "/", domain: String = "",
                maxAge: Int? = nil, httpOnly: Bool = false, secure: Bool = false) {
        self.name = name
        self.value = value
        self.path = path
        self.domain = domain
        self.maxAge = maxAge
        self.httpOnly = httpOnly
        self.secure = secure
    }

    /// 解析一条 `Set-Cookie` 响应头。
    ///
    /// 原版由 AsyncHTTPClient 代劳；shim 用 URLSession，需要自己解析。
    /// Cookie 的发送则由 `[Cookie].buildCookieHeader()` 手动完成，
    /// 所以请求里必须关掉 `httpShouldHandleCookies`，否则两边会重复处理。
    public static func parse(_ header: String) -> HTTPClientCookie? {
        let parts = header
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return nil }
        let pair = first.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2, !pair[0].isEmpty else { return nil }

        var path = "/"
        var domain = ""
        var maxAge: Int?
        var httpOnly = false
        var secure = false

        for attribute in parts.dropFirst() {
            let item = attribute.split(separator: "=", maxSplits: 1).map(String.init)
            let key = (item.first ?? "").lowercased()
            let value = item.count > 1 ? item[1] : ""
            switch key {
            case "path": path = value.isEmpty ? "/" : value
            case "domain": domain = value
            case "max-age": maxAge = Int(value)
            case "httponly": httpOnly = true
            case "secure": secure = true
            default: break
            }
        }

        return HTTPClientCookie(name: pair[0], value: pair[1], path: path, domain: domain,
                                maxAge: maxAge, httpOnly: httpOnly, secure: secure)
    }
}

// MARK: - Client

public final class HTTPClient {

    public struct Configuration {
        public var timeoutConnect: TimeInterval = 10
        public var timeoutRead: TimeInterval = 30
        /// 保留字段：原版用于 TLS 配置；release 下是标准验证，URLSession 默认即符合。
        public var tlsConfiguration: TLSConfiguration = .makeClientConfiguration()
        public var redirectConfiguration: RedirectConfiguration = .follow(max: 8, allowCycles: false)
        public var httpVersion: HTTPVersionShim = .http1Only
        public var httpVersionIs1Only = true

        public init() {}

        /// 兼容 `.init(tlsConfiguration:redirectConfiguration:timeout:)`。
        public init(tlsConfiguration: TLSConfiguration,
                    redirectConfiguration: RedirectConfiguration,
                    timeout: TimeoutShim) {
            self.tlsConfiguration = tlsConfiguration
            self.redirectConfiguration = redirectConfiguration
            self.timeoutConnect = timeout.connect
            self.timeoutRead = timeout.read
        }

        /// 兼容 `.then { $0.httpVersion = .http1Only }`（链式配置）。
        public func then(_ body: (inout Configuration) -> Void) -> Configuration {
            var copy = self
            body(&copy)
            return copy
        }
    }

    public let configuration: Configuration

    /// 每个 client 持有独立的 URLSession：重定向策略（是否跟随）由
    /// `configuration.redirectConfiguration` 决定，需要自定义 `URLSessionTaskDelegate`
    /// 来精确控制（见 `ApplePackageRedirectDelegate`）。
    private let session: URLSession
    private let redirectDelegate: ApplePackageRedirectDelegate

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.redirectDelegate = ApplePackageRedirectDelegate(
            redirectConfiguration: configuration.redirectConfiguration
        )
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = configuration.timeoutRead
        cfg.timeoutIntervalForResource = max(configuration.timeoutRead, 60)
        // v0.3.21：URLSession cookie 处理已开启（httpShouldHandleCookies = true），
        // ephemeral 配置自带独立 HTTPCookieStorage，同一 session 内自动捕获+回传。
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg,
                                  delegate: redirectDelegate,
                                  delegateQueue: nil)
    }

    /// 兼容原版构造签名。参数仅用于对齐调用点，实际按 URLSession 语义处理。
    ///
    /// 不能写成 `Any?`：调用点是 `eventLoopGroupProvider: .singleton`，
    /// `Any?` 无法推断成员（`type 'Any?' has no member 'singleton'`，CI 实证）。
    public convenience init(eventLoopGroupProvider: EventLoopGroupProvider = .createNew,
                            configuration: Configuration = Configuration()) {
        self.init(configuration: configuration)
    }

    deinit {
        // URLSession 强引用 delegate，必须 invalidate 才能释放，否则会泄漏。
        session.invalidateAndCancel()
    }

    public func shutdown() -> String {
        // 释放 session 及其强引用的 delegate（保留方法以兼容
        // `defer { _ = client.shutdown() }`）。
        session.invalidateAndCancel()
        return "ok"
    }

    /// 兼容 `HTTPClient.Cookie`（Cookie.swift 用它做类型转换）。
    public typealias Cookie = HTTPClientCookie

    // MARK: Request / Response

    public struct Request {
        public var url: String
        public var method: HTTPMethodShim
        public var headers: HTTPHeaders
        public var body: HTTPBodyShim

        public init(url: String, method: HTTPMethodShim = .GET) {
            self.url = url
            self.method = method
            self.headers = HTTPHeaders()
            self.body = .none
        }

        /// 兼容 `HTTPClient.Request(url:method:headers:body:)`。
        public init(url: String, method: HTTPMethodShim, headers: HTTPHeaders, body: HTTPBodyShim) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
        }

        /// 兼容原版 `Request(url: URL, ...)`：asspp 的 VersionFinder / VersionLookup
        /// 内部用 `URL` 构造请求（CI 实证 `cannot convert value of type 'URL' to
        /// expected argument type 'String'`），这里重载接受 `URL`，内部转成
        /// `absoluteString`，调用点一行都不用改。
        public init(url: URL, method: HTTPMethodShim = .GET) {
            self.url = url.absoluteString
            self.method = method
            self.headers = HTTPHeaders()
            self.body = .none
        }

        public init(url: URL, method: HTTPMethodShim, headers: HTTPHeaders, body: HTTPBodyShim) {
            self.url = url.absoluteString
            self.method = method
            self.headers = headers
            self.body = body
        }
    }

    public struct Response {
        public var status: HTTPResponseStatus
        public var headers: HTTPHeaders
        public var body: ByteBuffer?

        public init(status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders(), body: ByteBuffer?) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    /// 执行一次请求，返回「可 await 的结果」。
    /// 调用点写作 `try await client.execute(request: request).get()`。
    public func execute(request: Request) -> HTTPResult {
        HTTPResult {
            guard let url = URL(string: request.url) else {
                throw ApplePackageHTTPError.invalidURL(request.url)
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = request.method.rawValue
            urlRequest.timeoutInterval = self.configuration.timeoutRead
            // v0.3.21：开启 URLSession cookie 处理——SAP 认证流程中 Apple 服务器
            // 使用 Set-Cookie 跟踪认证会话状态。之前关闭导致 204 循环（服务器
            // 无法将 SAP 会话与 HTTP 会话关联）。TCI 路线已证此为关键缺失。
            // 手动 cookie 传递（buildCookieHeader）仍在，两层不冲突。
            urlRequest.httpShouldHandleCookies = true
            for item in request.headers.all {
                urlRequest.setValue(item.value, forHTTPHeaderField: item.name)
            }
            if let body = request.body.bytes {
                urlRequest.httpBody = body
            }

            let (data, response) = try await self.session.data(for: urlRequest)
            let http = response as? HTTPURLResponse
            let code = UInt(http?.statusCode ?? 0)

            var headers = HTTPHeaders()
            for (name, value) in http?.allHeaderFields ?? [:] {
                headers.add(name: String(describing: name), value: String(describing: value))
            }
            return Response(status: HTTPResponseStatus(code: code), headers: headers, body: ByteBuffer(data))
        }
    }
}

public extension HTTPClient.Response {
    /// 从 `Set-Cookie` 响应头解析出的 cookie 列表。
    ///
    /// 原版 AsyncHTTPClient 会自动填充这个属性；shim 需要手动解析。
    /// 登录 / 购买 / 下载流程全靠它把会话延续下去。
    var cookies: [HTTPClientCookie] {
        headers["Set-Cookie"].compactMap { HTTPClientCookie.parse($0) }
    }
}

/// `EventLoopFuture<Response>.get()` 的 async 替身。
public struct HTTPResult {
    private let body: () async throws -> HTTPClient.Response

    public init(_ body: @escaping () async throws -> HTTPClient.Response) {
        self.body = body
    }

    public func get() async throws -> HTTPClient.Response {
        try await body()
    }
}

/// 兼容 AsyncHTTPClient 的 `EventLoopGroupProvider`。
///
/// shim 用 URLSession，没有事件循环组的概念；这里只保留调用点会用到的
/// `.singleton`，让 `HTTPClient(eventLoopGroupProvider: .singleton, ...)`
/// 能正常做类型推断。
public enum EventLoopGroupProvider {
    case singleton
    case createNew
}

// MARK: - 重定向控制

/// 控制 URLSession 是否跟随重定向。
///
/// ApplePackage 的调用方（Authenticate / Purchase / Download / Version* 等）普遍使用
/// `redirectConfiguration: .disallow`，期望**自己**读取 302 响应的 `Location` 头并手动
/// 构造下一步请求（要在重定向之间携带 cookie / 重发 plist body）。
///
/// 但 `URLSession.shared.data(for:)` 默认会**自动跟随** 302，且自动合成的后续请求不会
/// 带上调用方手动拼的 cookie / body，导致 iTunes 认证握手失败，最终服务端返回一个没有
/// `Location` 的 302 → 报 `failed to retrieve redirect location`。
///
/// 这里实现 `URLSessionTaskDelegate` 的 `willPerformHTTPRedirection`
/// （`completionHandler: (URLRequest?) -> Void` 变体，iOS 7+ 通用；CI 所用 SDK 的
/// 协议要求即为此签名，不存在 `URLSession.RedirectPolicy`）。当配置为 `.disallow`
/// （`max == 0`）时调 `completionHandler(nil)` 取消自动跟随、把原始 302 响应交还给
/// 调用方处理 —— 与原版 AsyncHTTPClient 行为一致；`.follow` 则调
/// `completionHandler(request)` 保持跟随（与原 `URLSession.shared` 行为一致，
/// 不影响 Lookup / Search）。
private final class ApplePackageRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let redirectConfiguration: RedirectConfiguration

    init(redirectConfiguration: RedirectConfiguration) {
        self.redirectConfiguration = redirectConfiguration
        super.init()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if redirectConfiguration.max == 0 {
            // .disallow：不跟随，把 302 交还给调用方自行处理。
            completionHandler(nil)
        } else {
            // .follow：按 URLSession 默认行为跟随。
            completionHandler(request)
        }
    }
}

public enum ApplePackageHTTPError: Error, LocalizedError {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的 URL：\(url)"
        }
    }
}
