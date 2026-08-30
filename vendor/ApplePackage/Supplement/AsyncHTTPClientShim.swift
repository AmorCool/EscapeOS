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

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 兼容原版构造签名（参数仅用于对齐调用点，实际按 URLSession 语义处理）。
    public convenience init(eventLoopGroupProvider: Any? = nil, configuration: Configuration = Configuration()) {
        self.init(configuration: configuration)
    }

    public func shutdown() -> String {
        // URLSession 无需显式关闭；保留方法以兼容 `defer { _ = client.shutdown() }`。
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
            for item in request.headers.all {
                urlRequest.setValue(item.value, forHTTPHeaderField: item.name)
            }
            if let body = request.body.bytes {
                urlRequest.httpBody = body
            }

            let (data, response) = try await URLSession.shared.data(for: urlRequest)
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

public enum ApplePackageHTTPError: Error, LocalizedError {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的 URL：\(url)"
        }
    }
}
