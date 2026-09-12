import Foundation

struct OwnedApp: Identifiable, Hashable {
    var id: Int64
    var bundleId: String
    var name: String
    var version: String
    var purchaseDate: Date?
    var idText: String { "\(id)" }

    func matches(_ keyword: String) -> Bool {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty || name.lowercased().contains(key)
            || bundleId.lowercased().contains(key) || idText.contains(key)
    }
}

enum PurchaseHistoryError: Error, LocalizedError {
    case noAccount
    case signerUnavailable
    case badResponse(String)
    case rejected(String)
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .noAccount: return "没有可用的 Apple ID 账号"
        case .signerUnavailable: return "SAP 资产不可用，无法签名"
        case let .badResponse(what): return "已购列表响应异常（\(what)）"
        case let .rejected(message): return message
        case .tokenExpired: return "已购列表认证未通过，请在账号管理中检查登录状态。"
        }
    }
}

/// Configurator purchase DAAP: login -> update(musr) -> databases/{musr}/items.
/// musr is kept exactly as returned by Apple, matching ipatool's implementation.
enum PurchaseHistoryService {
    private static let base = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
    private static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    static let query = "('com.apple.itunes.extended\\-media\\-kind:131072')"

    static func ownedApps(email: String) async throws -> [OwnedApp] {
        try await StoreAccountSession.withAccount(email: email) { account in
            do {
                // A valid empty DAAP table is a result, not proof of an expired token.
                return try await list(account: &account)
            } catch PurchaseHistoryError.tokenExpired {
                LoginLogger.shared.log("[已购] 认证被拒 → 刷新一次会话后重试", category: .appStore)
                account = try await AppleIDSignInService.rotate(email: email, failedAccount: account)
                return try await list(account: &account)
            }
        }
    }

    private static func list(account: inout AppStoreAccount) async throws -> [OwnedApp] {
        let session = PurchaseHistorySession(account: account)
        defer { account = session.account; session.close() }
        try await session.prepare()
        let id = try await session.login()
        let revision = try await session.update(sessionID: id)
        return try await session.items(sessionID: id, revision: revision)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // Never forward X-Token/DSID to an unvalidated Location or lose a signed POST body.
            completionHandler(nil)
        }
    }

    private final class PurchaseHistorySession {
        var account: AppStoreAccount
        private let session: URLSession
        private let guid: String
        private var signer: SAPContext?

        init(account: AppStoreAccount) {
            self.account = account
            guid = AppleIDSignInService.sapGUID()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        }

        func close() { session.invalidateAndCancel() }

        func login() async throws -> UInt32 {
            let data = try await send(path: "/login")
            try PurchaseHistoryService.checkStatus(data, label: "login")
            guard let id = try firstUInt(data, tag: "mlid"), id > 0, id <= UInt32.max else {
                throw PurchaseHistoryError.badResponse("login 缺少有效 mlid")
            }
            return UInt32(id)
        }

        func update(sessionID: UInt32) async throws -> UInt32 {
            let body = Data("session-id=\(sessionID)&revision-number=(null)&query=\(query)".utf8)
            let data = try await send(path: "/update", body: body,
                                      contentType: "application/x-www-form-urlencoded", signed: true)
            try PurchaseHistoryService.checkStatus(data, label: "update")
            guard let revision = try firstUInt(data, tag: "musr"), revision <= UInt32.max else {
                throw PurchaseHistoryError.badResponse("update 缺少 musr")
            }
            return UInt32(revision)
        }

        func items(sessionID: UInt32, revision: UInt32) async throws -> [OwnedApp] {
            let data = try await send(path: "/databases/\(revision)/items",
                body: PurchaseHistoryService.itemsBody(sessionID: sessionID, revision: revision),
                contentType: "application/x-dmap-tagged", signed: true)
            let apps = try PurchaseHistoryService.parseItems(data)
            let total = (try firstUInt(data, tag: "mtco")).map { String($0) } ?? "missing"
            let returned = (try firstUInt(data, tag: "mrco")).map { String($0) } ?? "missing"
            LoginLogger.shared.log("[已购] total=\(total) returned=\(returned) apps=\(apps.count)", category: .appStore)
            return apps
        }

        private func send(path: String, body: Data? = nil, contentType: String? = nil,
                          signed: Bool = false) async throws -> Data {
            try Task.checkCancellation()
            guard let url = URL(string: base + path), !account.requestStoreFront.isEmpty else {
                throw PurchaseHistoryError.badResponse("无有效的账号 storefront")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            for (name, value) in headers() { request.setValue(value, forHTTPHeaderField: name) }
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            if signed {
                guard let signer, signer.complete else { throw PurchaseHistoryError.signerUnavailable }
                request.setValue(try signer.sign(body ?? Data()).base64EncodedString(),
                                 forHTTPHeaderField: "X-Apple-ActionSignature")
            }
            let (data, response) = try await perform(request)
            LoginLogger.shared.log("[已购] \(path) → HTTP \(response.statusCode)，\(data.count) 字节", category: .appStore)
            if response.statusCode == 401 || response.statusCode == 403 { throw PurchaseHistoryError.tokenExpired }
            guard response.statusCode == 200 else {
                throw PurchaseHistoryError.badResponse("\(path) HTTP \(response.statusCode)")
            }
            return data
        }

        private func headers() -> [(String, String)] {
            let now = Date()
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return [
                ("Accept", "*/*"), ("Accept-Language", "en-us"),
                ("Client-Cloud-DAAP-Request-Reason", "5"),
                ("Client-Cloud-Purchase-Daap-Version", "1.1/Configurator-2.0"),
                ("Client-DAAP-Version", "3.12"), ("Date", date.string(from: now)),
                ("iCloud-DSID", account.directoryServicesIdentifier),
                ("X-Apple-I-Client-Time", ISO8601DateFormatter().string(from: now)),
                ("X-Apple-I-Locale", "en_US"), ("X-Apple-I-TimeZone", TimeZone.current.identifier),
                ("X-Apple-Store-Front", account.requestStoreFront),
                ("X-Apple-TZ", "\(TimeZone.current.secondsFromGMT(for: now) / 60)"),
                ("X-Dsid", account.directoryServicesIdentifier), ("X-Guid", guid),
                ("X-Token", account.passwordToken), ("User-Agent", userAgent),
            ]
        }

        func prepare() async throws {
            guard let assets = SAPAssetsLocator.url, guid.count == 12 else {
                throw PurchaseHistoryError.signerUnavailable
            }
            let bytes = stride(from: 0, to: 12, by: 2).compactMap { offset -> UInt8? in
                let index = guid.index(guid.startIndex, offsetBy: offset)
                return UInt8(guid[index ..< guid.index(index, offsetBy: 2)], radix: 16)
            }
            guard bytes.count == 6 else { throw PurchaseHistoryError.signerUnavailable }
            let signer = try SAPContext(assetsURL: assets, hardwareID: Data(bytes))
            let bagURL = URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(guid)")!
            let (bagData, bagResponse) = try await perform(URLRequest(url: bagURL))
            guard bagResponse.statusCode == 200, let bag = StoreAuthenticationProtocol.plist(bagData) else {
                throw PurchaseHistoryError.badResponse("SAP bag HTTP \(bagResponse.statusCode)")
            }
            let nested = bag["urlBag"] as? [String: Any] ?? [:]
            func value(_ key: String) -> Any? { bag[key] ?? nested[key] }
            guard StoreAuthenticationProtocol.string(value("sign-sap-version")) == "200",
                  let certificateURL = publicURL(value("sign-sap-setup-cert"), host: "s.mzstatic.com"),
                  let setupURL = publicURL(value("sign-sap-setup"), host: "fpinit.itunes.apple.com") else {
                throw PurchaseHistoryError.signerUnavailable
            }
            let (certData, certResponse) = try await perform(URLRequest(url: certificateURL))
            guard certResponse.statusCode == 200,
                  let cert = StoreAuthenticationProtocol.plist(certData)?["sign-sap-setup-cert"] as? Data else {
                throw PurchaseHistoryError.badResponse("SAP certificate HTTP \(certResponse.statusCode)")
            }
            let exchange = try signer.exchangeData(cert, version: 200)
            var setup = URLRequest(url: setupURL)
            setup.httpMethod = "POST"
            setup.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            setup.httpBody = try PropertyListSerialization.data(
                fromPropertyList: ["sign-sap-setup-buffer": exchange], format: .xml, options: 0)
            let (replyData, replyResponse) = try await perform(setup)
            guard replyResponse.statusCode == 200,
                  let reply = StoreAuthenticationProtocol.plist(replyData)?["sign-sap-setup-buffer"] as? Data else {
                throw PurchaseHistoryError.badResponse("SAP setup HTTP \(replyResponse.statusCode)")
            }
            _ = try signer.exchangeData(reply, version: 200)
            guard signer.complete else { throw PurchaseHistoryError.signerUnavailable }
            self.signer = signer
        }

        private func perform(_ original: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try Task.checkCancellation()
            var request = original
            request.httpShouldHandleCookies = false
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let url = request.url {
                for (name, value) in account.cookie.buildCookieHeader(url) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, let url = http.url else {
                throw PurchaseHistoryError.badResponse("no response")
            }
            account.cookie.mergeCookies(HTTPClientCookie.parseResponse(http.allHeaderFields, for: url))
            return (data, http)
        }

        private func publicURL(_ value: Any?, host: String) -> URL? {
            guard let text = value as? String, let url = URL(string: text),
                  url.scheme == "https", url.host?.lowercased() == host,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.port == nil || url.port == 443 else { return nil }
            return url
        }
    }

    // Pure DAAP codecs: use the same parser in production and offline regression tests.
    static func itemsBody(sessionID: UInt32, revision: UInt32) -> Data {
        let payload = tag("mstc", uint32(UInt32(Date().timeIntervalSince1970)))
            + tag("mlid", uint32(sessionID)) + tag("mikd", Data([2]))
            + tag("musr", uint32(revision)) + tag("mder", uint32(0))
            + tag("mque", Data(query.utf8)) + tag("aetl", Data())
        return tag("adsr", payload)
    }

    static func tag(_ name: String, _ payload: Data) -> Data {
        Data(name.utf8) + uint32(UInt32(payload.count)) + payload
    }

    static func uint32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    static func checkStatus(_ data: Data, label: String) throws {
        guard let status = try firstUInt(data, tag: "mstt") else {
            throw PurchaseHistoryError.badResponse("\(label) 缺少 DAAP mstt")
        }
        if status == 401 || status == 403 { throw PurchaseHistoryError.tokenExpired }
        guard status == 200 else { throw PurchaseHistoryError.rejected("\(label) 被拒绝（DAAP \(status)）") }
    }

    static func firstUInt(_ data: Data, tag target: String) throws -> UInt64? {
        var result: UInt64?
        try walk(data) { name, value in
            guard result == nil, name == target else { return }
            if value.count == 4 { result = UInt64(value.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }) }
            if value.count == 8 { result = value.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian } }
        }
        return result
    }

    private static let containers: Set<String> = [
        "adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd",
    ]

    static func walk(_ data: Data, depth: Int = 0, visit: (String, Data) throws -> Void) throws {
        guard depth <= 16 else { throw PurchaseHistoryError.badResponse("DMAP 嵌套过深") }
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 8 else { throw PurchaseHistoryError.badResponse("DMAP 头被截断") }
            let name = String(decoding: data.subdata(in: offset ..< offset + 4), as: UTF8.self)
            let length = Int(data.subdata(in: offset + 4 ..< offset + 8)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard length <= data.count - offset - 8 else { throw PurchaseHistoryError.badResponse("DMAP 内容被截断") }
            let value = data.subdata(in: offset + 8 ..< offset + 8 + length)
            try visit(name, value)
            if containers.contains(name) { try walk(value, depth: depth + 1, visit: visit) }
            offset += 8 + length
        }
    }

    static func parseItems(_ data: Data) throws -> [OwnedApp] {
        guard String(decoding: data.prefix(4), as: UTF8.self) == "adbs" else {
            throw PurchaseHistoryError.badResponse("items 缺少 adbs")
        }
        try checkStatus(data, label: "items")
        var apps: [OwnedApp] = []
        var seen = Set<Int64>()
        var recordCount = 0
        try walk(data) { name, payload in
            guard name == "mlit" else { return }
            recordCount += 1
            var app = OwnedApp(id: 0, bundleId: "", name: "", version: "", purchaseDate: nil)
            try walk(payload) { field, value in
                switch field {
                case "aeSI":
                    if value.count == 4 { app.id = Int64(value.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }) }
                    if value.count == 8 { app.id = Int64(bitPattern: value.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }) }
                case "aeBI": app.bundleId = String(decoding: value, as: UTF8.self)
                case "aeLN": app.name = String(decoding: value, as: UTF8.self)
                case "minm": if app.name.isEmpty { app.name = String(decoding: value, as: UTF8.self) }
                case "aePd": app.version = String(decoding: value, as: UTF8.self)
                case "asdp":
                    if value.count == 4 {
                        let seconds = value.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                        app.purchaseDate = Date(timeIntervalSince1970: TimeInterval(seconds))
                    }
                default: break
                }
            }
            guard app.id > 0 else { throw PurchaseHistoryError.badResponse("已购条目缺少有效 aeSI") }
            if seen.insert(app.id).inserted { apps.append(app) }
        }
        guard let returned = try firstUInt(data, tag: "mrco"), let total = try firstUInt(data, tag: "mtco") else {
            throw PurchaseHistoryError.badResponse("items 缺少记录计数")
        }
        guard returned == UInt64(recordCount), total >= returned else {
            throw PurchaseHistoryError.badResponse("条目数与 DAAP 计数不一致")
        }
        guard total == returned else {
            throw PurchaseHistoryError.badResponse("Apple 只返回部分记录（\(returned)/\(total)），不能当作完整已购列表")
        }
        return apps.sorted { ($0.purchaseDate ?? .distantPast) > ($1.purchaseDate ?? .distantPast) }
    }
}
