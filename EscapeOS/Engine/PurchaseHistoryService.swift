//
//  PurchaseHistoryService.swift
//  EscapeOS
//
//  Apple「已购列表」—— 走 DMAP（MZPurchaseDaap），与 ipatool 的 `list-purchases` 同源。
//
//  三个动作，全是只读（不会改动账号状态）：
//    ① POST {base}/login                     —— 只用请求头，返回会话号 mlid
//    ② POST {base}/update                    —— 需要 SAP 签名（X-Apple-ActionSignature），返回 revision musr
//    ③ POST {base}/databases/{musr}/items    —— x-dmap-tagged 体 + SAP 签名，返回 mlit 条目
//
//  签名必须用本机 SAP 资产（Unicorn 跑 Apple CommerceKit），不签名 ② 会直接 500。
//

import Foundation

/// 一条已购记录（DMAP mlit）
struct OwnedApp: Identifiable, Hashable {
    var id: Int64            // aeSI
    var bundleId: String     // aeBI
    var name: String         // aeLN / minm
    var version: String      // aePd
    var purchaseDate: Date?  // asdp

    var idText: String { "\(id)" }

    /// 搜索匹配：名称 / bundleId / appId（大小写不敏感）
    func matches(_ keyword: String) -> Bool {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return true }
        return name.lowercased().contains(k)
            || bundleId.lowercased().contains(k)
            || idText.contains(k)
    }
}

enum PurchaseHistoryError: Error, LocalizedError {
    case noAccount
    case signerUnavailable
    case badResponse(String)
    case rejected(String)
    /// HTTP 401/403：会话票据（passwordToken / cookie）过期 —— ipatool 同样把这两档
    /// 直接当 passwordTokenExpired。调用方应用已存凭据 rotate 一次再重试。
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .noAccount: return "没有可用的 Apple ID 账号"
        case .signerUnavailable: return "SAP 资产不可用，无法签名"
        case .badResponse(let what): return "已购列表响应异常（\(what)）"
        case .rejected(let message): return message
        case .tokenExpired: return "登录票据已过期，请重试"
        }
    }
}

enum PurchaseHistoryService {

    private static let base = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
    private static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    /// extended-media-kind: 131072 = 应用（ipatool ownedAppsMediaKind 同值）
    private static let query = "('com.apple.itunes.extended\\-media\\-kind:131072')"

    // MARK: - 对外入口

    /// 拉取该账号的已购应用（按购买时间从新到旧）。
    /// 会先做一次 SAP setup 交换（bag + 证书），因为 ②/③ 必须带签名。
    static func ownedApps(email: String) async throws -> [OwnedApp] {
        guard let account = AppStoreDownloadStore.shared.account(for: email) else {
            throw PurchaseHistoryError.noAccount
        }
        do {
            let owned = try await list(account: account)
            if !owned.isEmpty { return owned }
            // 所有口径都回空时，还有一个强嫌疑：**X-Token 用的是过期票据**。
            // DMAP 对过期票据可能回 200 + 空表（而不是 401），这时换一次令牌再打一遍即可。
            // AssppPro 就是先 rotatePasswordToken 再去列已购的。
            LoginLogger.shared.log("[已购] 全口径空结果 → 换一次令牌后重试", category: .appStore)
            let refreshed = try await AppleIDSignInService.rotate(email: email)
            return try await list(account: refreshed)
        } catch PurchaseHistoryError.tokenExpired {
            // 票据过期 → 用已存凭据 rotate 一次（带 cookie，通常免验证码）再重试一次
            LoginLogger.shared.log("[已购] 票据过期 → 重新登录后重试", category: .appStore)
            let refreshed = try await AppleIDSignInService.rotate(email: email)
            return try await list(account: refreshed)
        }
    }

    private static func list(account: AppStoreAccount) async throws -> [OwnedApp] {
        let session = PurchaseHistorySession(account: account)
        try await session.prepare()
        let sessionID = try await session.login()
        let revision = try await session.update(sessionID: sessionID)
        return try await session.items(sessionID: sessionID, revision: revision)
    }

    // MARK: - 会话

    private final class PurchaseHistorySession {
        private let account: AppStoreAccount
        private let session: URLSession
        private let signer: SAPContext?
        private var signerReady = false

        init(account: AppStoreAccount) {
            self.account = account
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            session = URLSession(configuration: configuration)
            signer = try? Self.makeSigner()
        }

        // ① 会话登录
        func login() async throws -> UInt32 {
            let (data, response) = try await send(path: "/login")
            guard response.statusCode == 200 else {
                throw PurchaseHistoryError.badResponse("login HTTP \(response.statusCode)")
            }
            try Self.checkDMAPStatus(data, label: "login")
            guard let sessionID = Self.firstUInt(data, tag: "mlid"), sessionID <= UInt32.max else {
                throw PurchaseHistoryError.badResponse("login 缺少 mlid")
            }
            return UInt32(sessionID)
        }

        // ② 更新购买历史（需要签名）
        func update(sessionID: UInt32) async throws -> UInt32 {
            let body = Data("session-id=\(sessionID)&revision-number=(null)&query=\(query)".utf8)
            let (data, response) = try await send(
                path: "/update",
                body: body,
                contentType: "application/x-www-form-urlencoded",
                signed: true
            )
            guard response.statusCode == 200 else {
                throw PurchaseHistoryError.badResponse("update HTTP \(response.statusCode)")
            }
            try Self.checkDMAPStatus(data, label: "update")
            guard let revision = Self.firstUInt(data, tag: "musr"), revision <= UInt32.max else {
                throw PurchaseHistoryError.badResponse("update 缺少 musr")
            }
            return UInt32(revision)
        }

        // ③ 取条目（x-dmap-tagged + 签名）——按口径逐个试，取第一个非空
        func items(sessionID: UInt32, revision: UInt32) async throws -> [OwnedApp] {
            var lastStatus = 0
            for variant in Self.variants(store: account.store) {
                let usedRevision = variant.revision ?? revision
                let body = Self.itemsBody(sessionID: sessionID, revision: usedRevision,
                                          query: variant.query)
                let (data, response) = try await send(
                    path: "/databases/\(usedRevision)/items",
                    body: body,
                    contentType: "application/x-dmap-tagged",
                    signed: true,
                    storeFront: variant.storeFront
                )
                lastStatus = response.statusCode
                guard response.statusCode == 200 else {
                    LoginLogger.shared.log("[已购] \(variant.name) → HTTP \(response.statusCode)",
                                           category: .appStore)
                    continue
                }
                let apps = Self.parseOwnedApps(data)
                LoginLogger.shared.log("[已购] \(variant.name) → \(apps.count) 条（\(data.count) 字节）",
                                       category: .appStore)
                if !apps.isEmpty { return apps }
                LoginLogger.shared.log("[已购] \(variant.name) 空结果原始字节 \(Self.rawDump(data))",
                                       category: .appStore)
            }
            if lastStatus != 0, lastStatus != 200 {
                throw PurchaseHistoryError.badResponse("items HTTP \(lastStatus)")
            }
            return []
        }

        // MARK: 请求

        private func send(path: String,
                          body: Data? = nil,
                          contentType: String? = nil,
                          signed: Bool = false,
                          storeFront: String? = nil) async throws -> (Data, HTTPURLResponse) {
            guard let url = URL(string: base + path) else {
                throw PurchaseHistoryError.badResponse("bad url")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            for (name, value) in Self.headers(account: account) {
                if name == "X-Apple-Store-Front", storeFront != nil { continue }
                request.setValue(value, forHTTPHeaderField: name)
            }
            if let storeFront {
                request.setValue(storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
            }
            // **必须有 Cookie**：DMAP 的鉴权靠会话 cookie，缺它 /items 直接 401。
            // ipatool 的 HTTP 客户端自带 cookie jar，我们是 ephemeral session，
            // 所以得手动把账号里存的 cookie 拼上（与 volumeStore / buyProduct 同款做法）。
            for (name, value) in account.cookie.buildCookieHeader(url) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            if signed {
                guard let signer, signerReady else { throw PurchaseHistoryError.signerUnavailable }
                // 与登录链路一致：对**最终发出的请求体**签名，放 X-Apple-ActionSignature
                request.setValue(try signer.sign(body ?? Data()).base64EncodedString(),
                                 forHTTPHeaderField: "X-Apple-ActionSignature")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PurchaseHistoryError.badResponse("no response")
            }
            LoginLogger.shared.log("[已购] \(path) → HTTP \(http.statusCode)，\(data.count) 字节",
                                   category: .appStore)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw PurchaseHistoryError.tokenExpired
            }
            return (data, http)
        }

        /// ipatool `ownedAppsHeaders` 同款
        private static func headers(account: AppStoreAccount) -> [(String, String)] {
            let now = Date()
            let offsetMinutes = TimeZone.current.secondsFromGMT(for: now) / 60
            return [
                ("Accept", "*/*"),
                ("Accept-Language", "en-us"),
                ("Client-Cloud-DAAP-Request-Reason", "5"),
                ("Client-Cloud-Purchase-Daap-Version", "1.1/Configurator-2.0"),
                ("Client-DAAP-Version", "3.12"),
                ("Date", Self.rfc1123(now)),
                ("iCloud-DSID", account.directoryServicesIdentifier),
                ("X-Apple-I-Client-Time", Self.iso8601.string(from: now)),
                ("X-Apple-I-Locale", "en_US"),
                ("X-Apple-I-TimeZone", TimeZone.current.identifier),
                ("X-Apple-Store-Front", account.store.isEmpty ? "143441" : "\(account.store)-1"),
                ("X-Apple-TZ", "\(offsetMinutes)"),
                ("X-Dsid", account.directoryServicesIdentifier),
                ("X-Guid", AppleIDSignInService.sapGUID()),
                ("X-Token", account.passwordToken),
                ("User-Agent", userAgent),
            ]
        }

        private static let rfc1123Formatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return f
        }()

        private static let iso8601: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            return f
        }()

        private static func rfc1123(_ date: Date) -> String {
            rfc1123Formatter.string(from: date)
        }

        // MARK: SAP 签名器（setup 交换与登录链路同一套流程）

        private static func makeSigner() throws -> SAPContext {
            guard let assets = SAPAssetsLocator.url else { throw PurchaseHistoryError.signerUnavailable }
            let guid = AppleIDSignInService.sapGUID()
            let hardware = stride(from: 0, to: 12, by: 2).compactMap { offset -> UInt8? in
                let start = guid.index(guid.startIndex, offsetBy: offset)
                return UInt8(guid[start ..< guid.index(start, offsetBy: 2)], radix: 16)
            }
            guard hardware.count == 6 else { throw PurchaseHistoryError.signerUnavailable }
            return try SAPContext(assetsURL: assets, hardwareID: Data(hardware))
        }

        /// 与 `SignedStoreAuthenticator` 相同的两步 setup 交换（bag → 证书 → fpinit）
        func prepare() async throws {
            guard let signer else { throw PurchaseHistoryError.signerUnavailable }
            let guid = AppleIDSignInService.sapGUID()
            let bagURL = URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(guid)")!
            let (bagData, bagResponse) = try await plain(bagURL)
            guard bagResponse.statusCode == 200,
                  let bag = StoreAuthenticationProtocol.plist(bagData)
            else { throw PurchaseHistoryError.signerUnavailable }
            let nested = bag["urlBag"] as? [String: Any] ?? [:]
            func value(_ key: String) -> Any? { bag[key] ?? nested[key] }
            guard StoreAuthenticationProtocol.string(value("sign-sap-version")) == "200",
                  let certificateURL = Self.publicURL(value("sign-sap-setup-cert"), host: "s.mzstatic.com"),
                  let setupURL = Self.publicURL(value("sign-sap-setup"), host: "fpinit.itunes.apple.com")
            else { throw PurchaseHistoryError.signerUnavailable }

            let (certificateData, certificateResponse) = try await plain(certificateURL)
            guard certificateResponse.statusCode == 200,
                  let certificate = StoreAuthenticationProtocol.plist(certificateData)?["sign-sap-setup-cert"] as? Data
            else { throw PurchaseHistoryError.signerUnavailable }
            let exchange = try signer.exchangeData(certificate, version: 200)

            var setup = URLRequest(url: setupURL)
            setup.httpMethod = "POST"
            setup.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
            setup.httpBody = try PropertyListSerialization.data(
                fromPropertyList: ["sign-sap-setup-buffer": exchange], format: .xml, options: 0)
            let (setupData, setupResponse) = try await plain(setup)
            guard setupResponse.statusCode == 200,
                  let reply = StoreAuthenticationProtocol.plist(setupData)?["sign-sap-setup-buffer"] as? Data
            else { throw PurchaseHistoryError.signerUnavailable }
            _ = try signer.exchangeData(reply, version: 200)
            guard signer.complete else { throw PurchaseHistoryError.signerUnavailable }
            signerReady = true
        }

        private func plain(_ url: URL) async throws -> (Data, HTTPURLResponse) {
            try await plain(URLRequest(url: url))
        }

        private func plain(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            var request = request
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PurchaseHistoryError.badResponse("no response")
            }
            return (data, http)
        }

        private static func publicURL(_ value: Any?, host: String) -> URL? {
            guard let text = value as? String, let url = URL(string: text),
                  url.scheme == "https", url.host?.lowercased() == host,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.port == nil || url.port == 443 else { return nil }
            return url
        }

        // MARK: DMAP 编码

        /// ipatool `ownedAppsItemsBody` 同款（query 为 nil 时不带 mque 过滤）
        private static func itemsBody(sessionID: UInt32, revision: UInt32, query: String?) -> Data {
            var payload = Data()
            payload.append(tag("mstc", uint32(UInt32(Date().timeIntervalSince1970))))
            payload.append(tag("mlid", uint32(sessionID)))
            payload.append(tag("mikd", Data([2])))
            payload.append(tag("musr", uint32(revision)))
            payload.append(tag("mder", uint32(0)))
            if let query { payload.append(tag("mque", Data(query.utf8))) }
            payload.append(tag("aetl", Data()))
            return tag("adsr", payload)
        }

        /// 「已购」在同一个账号上可能因 storefront 写法 / 是否带 media-kind 过滤而给出不同结果。
        /// 先按 ipatool 原样打，空了再试其它组合 —— 谁先返回条目就用谁。
        struct ItemsVariant {
            let name: String
            let storeFront: String
            let query: String?
            /// nil = 用 /update 返回的 revision；1 = DAAP 的「初始版本，取全部」
            let revision: UInt32?
        }

        static func variants(store: String) -> [ItemsVariant] {
            let base = store.isEmpty ? "143441" : store
            let kind = "('com.apple.itunes.extended\\-media\\-kind:131072')"
            return [
                ItemsVariant(name: "A 默认（\(base)-1 + 应用过滤）", storeFront: "\(base)-1", query: kind, revision: nil),
                ItemsVariant(name: "B 裸 storefront（\(base)）", storeFront: base, query: kind, revision: nil),
                // Apple 回的是 adbs{mstt=200, muty, mtco=0, mrco=0, musr}（total/returned count 都是 0）。
                // 除了口径，还有一种可能：`/items` 要的 revision 应该是 DAAP 的「初始版本 1」，
                // 而我们一直用 /update 回的那个 revision（那是「增量」口径，自然是空的）。
                ItemsVariant(name: "E revision=1 + 默认 storefront + 应用过滤", storeFront: "\(base)-1", query: kind, revision: 1),
                ItemsVariant(name: "F revision=1 + 裸 storefront + 应用过滤", storeFront: base, query: kind, revision: 1),
                ItemsVariant(name: "G revision=1 + 默认 storefront、不带过滤", storeFront: "\(base)-1", query: nil, revision: 1),
                ItemsVariant(name: "C 默认 storefront、不带过滤", storeFront: "\(base)-1", query: nil, revision: nil),
                ItemsVariant(name: "D 裸 storefront、不带过滤", storeFront: base, query: nil, revision: nil),
            ]
        }

        /// 原始字节（前 160 字节的 hex + 可读文本），空结果时用来定性
        static func rawDump(_ data: Data) -> String {
            let head = data.prefix(160)
            let hex = head.map { String(format: "%02x", $0) }.joined()
            var text = ""
            for byte in head {
                let scalar = UnicodeScalar(byte)
                text.append(byte >= 0x20 && byte < 0x7f ? Character(scalar) : ".")
            }
            return "hex=\(hex) text=\(text)"
        }

        private static func tag(_ name: String, _ payload: Data) -> Data {
            var out = Data(name.utf8.prefix(4))
            while out.count < 4 { out.append(0) }
            var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(payload)
            return out
        }

        private static func uint32(_ value: UInt32) -> Data {
            var big = value.bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }

        // MARK: DMAP 解析

        private static func checkDMAPStatus(_ data: Data, label: String) throws {
            guard let status = firstUInt(data, tag: "mstt") else { return }
            guard status == 200 else {
                throw PurchaseHistoryError.rejected("\(label) 被拒绝（DAAP \(status)）")
            }
        }

        private static func firstUInt(_ data: Data, tag target: String) -> UInt64? {
            var found: UInt64?
            walk(data) { name, payload in
                guard found == nil, name == target else { return }
                switch payload.count {
                case 4: found = UInt64(payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
                case 8: found = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
                default: break
                }
            }
            return found
        }

        private static let containers: Set<String> = [
            "adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty",
            "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd",
        ]

        private static func walk(_ data: Data, depth: Int = 0, visit: (String, Data) -> Void) {
            guard depth <= 16, data.count >= 8 else { return }
            var offset = 0
            while offset + 8 <= data.count {
                let nameData = data.subdata(in: offset ..< offset + 4)
                guard let name = String(data: nameData, encoding: .isoLatin1) else { return }
                let length = Int(data.subdata(in: offset + 4 ..< offset + 8)
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
                guard length >= 0, offset + 8 + length <= data.count else { return }
                let payload = data.subdata(in: offset + 8 ..< offset + 8 + length)
                visit(name, payload)
                if containers.contains(name) {
                    walk(payload, depth: depth + 1, visit: visit)
                }
                offset += 8 + length
            }
        }

        private static func parseOwnedApps(_ data: Data) -> [OwnedApp] {
            var apps: [OwnedApp] = []
            var seen = Set<Int64>()
            walk(data) { name, payload in
                guard name == "mlit" else { return }
                var app = OwnedApp(id: 0, bundleId: "", name: "", version: "", purchaseDate: nil)
                walk(payload) { field, value in
                    switch field {
                    case "aeSI":
                        if value.count == 4 {
                            app.id = Int64(value.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
                        } else if value.count == 8 {
                            app.id = Int64(bitPattern: value.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian })
                        }
                    case "aeBI": app.bundleId = String(decoding: value, as: UTF8.self)
                    case "aeLN": app.name = String(decoding: value, as: UTF8.self)
                    case "minm":
                        if app.name.isEmpty { app.name = String(decoding: value, as: UTF8.self) }
                    case "aePd": app.version = String(decoding: value, as: UTF8.self)
                    case "asdp":
                        if value.count == 4 {
                            let seconds = value.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                            app.purchaseDate = Date(timeIntervalSince1970: TimeInterval(seconds))
                        }
                    default: break
                    }
                }
                guard app.id != 0, !seen.contains(app.id) else { return }
                seen.insert(app.id)
                apps.append(app)
            }
            return apps.sorted { ($0.purchaseDate ?? .distantPast) > ($1.purchaseDate ?? .distantPast) }
        }
    }
}

