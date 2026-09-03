import Foundation

// MARK: - 模型

/// Apple Developer 团队信息（listTeams.action）。
struct DeveloperTeam: Identifiable, Hashable {
    let name: String
    let identifier: String
    var id: String { identifier }
}

/// Apple Developer App ID（ios/listAppIds.action）。
struct DeveloperAppID: Identifiable, Hashable {
    let identifier: String       // appIdId（PATCH /v1/bundleIds/<id> 用）
    let name: String
    let bundleIdentifier: String // identifier 字段（bundle id）
    let enabledFeatures: [String]

    var id: String { identifier }
    var hasIncreasedMemory: Bool { enabledFeatures.contains("INCREASED_MEMORY_LIMIT") }
}

/// Apple Developer 开发证书（ios/listAllDevelopmentCerts.action），
/// 移植自 SideInstaller 的 DevCert / isideload 的 DevelopmentCertificate。
struct DeveloperCertificate: Identifiable, Hashable {
    let name: String
    let serialNumber: String
    let machineName: String
    let certificateId: String
    let platform: String
    let status: String
    /// 过期时间（RFC3339 / plist date），Apple 可能不返回。
    let expiration: Date?

    /// 稳定标识：吊销以序列号为准，缺失时退回证书 id。
    var id: String { serialNumber.isEmpty ? certificateId : serialNumber }

    var displayName: String { name.isEmpty ? "未命名证书" : name }

    /// 证书关联的机器（Apple 标记的），无则 nil。
    var machineLabel: String? { machineName.isEmpty ? nil : machineName }

    /// 是否已过期。
    var isExpired: Bool {
        guard let expiration else { return false }
        return expiration < Date()
    }
}

// MARK: - Apple Developer API

/// Apple Developer 后端 API（developerservices2.apple.com），移植自 GetMoreRam / StosSign，
/// 纯原生 URLSession 实现。所有请求携带 dsid/authToken，Anisette OTP 每次取全新值
/// （Apple 的 OTP 为一次性，复用会 -22421）。
enum AppleDeveloperAPI {
    static let clientID = "XABBG36SBA"
    static let qhURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/")!
    static let v1URL = URL(string: "https://developerservices2.apple.com/services/v1/")!

    // MARK: - 请求头

    private static func makeHeaders(session: AppleAPISession) async throws -> [String: String] {
        // 每次调用都取全新 Anisette（新 OTP），避免一次性 OTP 失效。
        // v0.2.115：改用带重试 + 服务器轮换的入口——Anisette 服务器侧故障
        // （-45025 / -45003 / WebSocket 断开）在此自动换服务器，不再让页面
        // 直接报错或卡住。
        let anisette = try await AnisetteProvider.shared.getAnisetteDataWithFallback()
        let fmt = ISO8601DateFormatter()
        return [
            "User-Agent": "Xcode",
            "Accept": "text/x-xml-plist",
            "Accept-Language": "en-us",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "11.2 (11B41)",
            "X-Apple-I-Identity-Id": session.dsid,
            "X-Apple-GS-Token": session.authToken,
            "X-Apple-I-MD-M": anisette.machineID,
            "X-Apple-I-MD": anisette.oneTimePassword,
            "X-Apple-I-MD-LU": anisette.localUserID,
            "X-Apple-I-MD-RINFO": "\(anisette.routingInfo)",
            "X-Mme-Device-Id": anisette.deviceUniqueIdentifier,
            "X-MMe-Client-Info": anisette.deviceDescription,
            "X-Apple-I-Client-Time": fmt.string(from: anisette.date),
            "X-Apple-Locale": anisette.locale.identifier,
            "X-Apple-I-TimeZone": anisette.timeZone.abbreviation() ?? "PST"
        ]
    }

    // MARK: - Teams

    /// 获取账号下的开发者团队列表。
    static func fetchTeams(session: AppleAPISession) async throws -> [DeveloperTeam] {
        LoginLogger.shared.log("▶ 获取团队列表")
        var headers = try await makeHeaders(session: session)
        headers["Content-Type"] = "text/x-xml-plist"
        let body: [String: String] = [
            "clientId": clientID,
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased()
        ]
        let url = qhURL.appendingPathComponent("listTeams.action").appendingQueryItem("clientId", clientID)
        let data = try await post(url: url, headers: headers, plistBody: body, method: "POST")

        guard let dict = plist(data),
              let teamsArray = dict["teams"] as? [[String: Any]] else {
            try throwIfSessionExpired(data)
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            LoginLogger.shared.log("❌ 团队列表解析失败: \(preview)")
            throw AppleAPIError.customError(code: -1, message: "团队列表解析失败: \(preview)")
        }
        var teams: [DeveloperTeam] = []
        for t in teamsArray {
            if let name = t["name"] as? String, let id = t["teamId"] as? String {
                teams.append(DeveloperTeam(name: name, identifier: id))
            }
        }
        guard !teams.isEmpty else {
            throw AppleAPIError.customError(code: -1, message: "账号下没有可用团队")
        }
        LoginLogger.shared.log("✓ 团队 \(teams.count) 个")
        return teams
    }

    // MARK: - App IDs

    /// 获取团队下的 App ID 列表。
    static func fetchAppIDs(team: DeveloperTeam, session: AppleAPISession) async throws -> [DeveloperAppID] {
        LoginLogger.shared.log("▶ 获取 App ID 列表（team=\(team.identifier)）")
        var headers = try await makeHeaders(session: session)
        headers["Content-Type"] = "text/x-xml-plist"
        var body: [String: String] = [
            "clientId": clientID,
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased(),
            "teamId": team.identifier
        ]
        let url = qhURL.appendingPathComponent("ios/listAppIds.action").appendingQueryItem("clientId", clientID)
        let data = try await post(url: url, headers: headers, plistBody: body, method: "POST")

        guard let dict = plist(data),
              let appIdsArray = dict["appIds"] as? [[String: Any]] else {
            try throwIfSessionExpired(data)
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            LoginLogger.shared.log("❌ App ID 列表解析失败: \(preview)")
            throw AppleAPIError.customError(code: -1, message: "App ID 列表解析失败: \(preview)")
        }
        let apps = appIdsArray.compactMap { d -> DeveloperAppID? in
            guard let id = d["appIdId"] as? String,
                  let name = d["name"] as? String,
                  let bundleId = d["identifier"] as? String else { return nil }
            let features = d["enabledFeatures"] as? [String] ?? []
            return DeveloperAppID(identifier: id, name: name, bundleIdentifier: bundleId, enabledFeatures: features)
        }
        LoginLogger.shared.log("✓ App ID \(apps.count) 个")
        return apps
    }

    // MARK: - 开启增加内存限制

    /// PATCH /v1/bundleIds/<appIdId>，为 App ID 开启 INCREASED_MEMORY_LIMIT 能力。
    /// 返回服务器响应原文（成功时包含更新后的 data）。
    static func enableIncreasedMemory(appID: DeveloperAppID, team: DeveloperTeam, session: AppleAPISession) async throws -> String {
        LoginLogger.shared.log("▶ 开启 INCREASED_MEMORY_LIMIT: \(appID.bundleIdentifier)")
        var headers = try await makeHeaders(session: session)
        headers["Content-Type"] = "application/vnd.api+json"
        headers["Accept"] = "application/vnd.api+json"

        let payload: [String: Any] = [
            "data": [
                "type": "bundleIds",
                "id": appID.identifier,
                "attributes": [
                    "identifier": appID.bundleIdentifier,
                    "teamId": team.identifier,
                    "seedId": team.identifier,
                    "bundleType": "bundle",
                    "name": appID.name,
                    "hasExclusiveManagedCapabilities": false
                ],
                "relationships": [
                    "bundleIdCapabilities": [
                        "data": [
                            [
                                "type": "bundleIdCapabilities",
                                "attributes": ["enabled": true, "settings": []],
                                "relationships": [
                                    "capability": [
                                        "data": ["type": "capabilities", "id": "INCREASED_MEMORY_LIMIT"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let url = v1URL.appendingPathComponent("bundleIds").appendingPathComponent(appID.identifier)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseString = String(data: data, encoding: .utf8) ?? ""
        LoginLogger.shared.log("← PATCH HTTP \(http): \(responseString.prefix(300))")

        guard (200..<300).contains(http) else {
            throw AppleAPIError.customError(code: http, message: "Apple API 请求失败（HTTP \(http)）: \(responseString.prefix(300))")
        }
        return responseString
    }

    // MARK: - 开发证书（移植自 SideInstaller 证书板块）

    /// 获取团队下的 iOS 开发证书列表。
    /// 端点与请求格式对齐 isideload 的 CertificatesApi：
    /// POST .../ios/listAllDevelopmentCerts.action，body 含 teamId。
    static func fetchCertificates(team: DeveloperTeam, session: AppleAPISession) async throws -> [DeveloperCertificate] {
        LoginLogger.shared.log("▶ 获取证书列表（team=\(team.identifier)）")
        var headers = try await makeHeaders(session: session)
        headers["Content-Type"] = "text/x-xml-plist"
        var body: [String: Any] = [
            "clientId": clientID,
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased(),
            "teamId": team.identifier
        ]
        let url = qhURL.appendingPathComponent("ios/listAllDevelopmentCerts.action").appendingQueryItem("clientId", clientID)
        let data = try await post(url: url, headers: headers, plistBody: body, method: "POST")

        guard let dict = plist(data),
              let certsArray = dict["certificates"] as? [[String: Any]] else {
            try throwIfSessionExpired(data)
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            LoginLogger.shared.log("❌ 证书列表解析失败: \(preview)")
            throw AppleAPIError.customError(code: -1, message: "证书列表解析失败: \(preview)")
        }
        let certs = certsArray.compactMap { d -> DeveloperCertificate? in
            let s = { (key: String) in (d[key] as? String) ?? "" }
            let expiration: Date?
            if let date = d["expirationDate"] as? Date {
                expiration = date
            } else if let iso = d["expirationDate"] as? String, !iso.isEmpty {
                expiration = ISO8601DateFormatter().date(from: iso)
            } else {
                expiration = nil
            }
            return DeveloperCertificate(
                name: s("name"),
                serialNumber: s("serialNumber"),
                machineName: s("machineName"),
                certificateId: s("certificateId"),
                platform: s("certificatePlatform"),
                status: s("status"),
                expiration: expiration
            )
        }
        LoginLogger.shared.log("✓ 证书 \(certs.count) 个")
        return certs
    }

    /// 提交 CSR 创建开发证书（免费 Apple ID 通用）。
    /// 端点/键名对齐 SideStore/AltSign addCertificate：
    /// POST .../ios/submitDevelopmentCSR.action，plist body 携带
    /// csrContent（**完整 PEM 字符串**）+ machineId（随机大写 UUID）+ machineName。
    /// 响应 certRequest.certContent（base64 DER）。
    /// 特殊错误码：3250=CSR 无效，7460=证书数量达上限。
    static func submitSigningCertificate(team: DeveloperTeam,
                                         csrPEM: String,
                                         machineName: String,
                                         session: AppleAPISession) async throws -> Data {
        LoginLogger.shared.log("▶ 提交 CSR 创建开发证书（team=\(team.identifier)）")
        var headers = try await makeHeaders(session: session)
        headers["Content-Type"] = "text/x-xml-plist"
        let body: [String: Any] = [
            "clientId": clientID,
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased(),
            "teamId": team.identifier,
            "csrContent": csrPEM,
            "machineId": UUID().uuidString.uppercased(),
            "machineName": machineName
        ]
        let url = qhURL.appendingPathComponent("ios/submitDevelopmentCSR.action")
            .appendingQueryItem("clientId", clientID)
        let data = try await post(url: url, headers: headers, plistBody: body, method: "POST")
        guard let dict = plist(data),
              let certRequest = dict["certRequest"] as? [String: Any] else {
            try throwIfSessionExpired(data)
            // 特殊错误码提示（plist 顶层 resultCode）
            if let resultCode = plist(data)?["resultCode"] as? Int {
                if resultCode == 3250 {
                    LoginLogger.shared.log("❌ Apple 拒绝 CSR（3250）")
                    throw AppleAPIError.customError(code: 3250, message: "Apple 拒绝了证书请求（3250：CSR 无效）")
                }
                if resultCode == 7460 {
                    LoginLogger.shared.log("❌ 证书数量达上限（7460）")
                    throw AppleAPIError.customError(code: 7460, message: "开发证书数量已达上限（7460）。请到「更多 → 证书管理」吊销一张过期/旧证书（别吊销 SideStore 正在用的那张），再回来重新创建")
                }
            }
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            LoginLogger.shared.log("❌ 证书创建响应解析失败: \(preview)")
            throw AppleAPIError.customError(code: -1, message: "证书创建响应解析失败: \(preview)")
        }
        guard let b64 = certRequest["certContent"] as? String,
              let certDER = Data(base64Encoded: b64) else {
            LoginLogger.shared.log("❌ 响应缺少 certRequest.certContent")
            throw AppleAPIError.customError(code: -1, message: "响应缺少 certRequest.certContent")
        }
        LoginLogger.shared.log("✓ 开发证书创建成功（\(certDER.count) 字节）")
        return certDER
    }

    /// 吊销指定序列号的开发证书。
    /// 端点对齐 isideload：POST .../ios/revokeDevelopmentCert.action，
    /// body 含 teamId + serialNumber。
    static func revokeCertificate(team: DeveloperTeam, serialNumber: String, session: AppleAPISession) async throws {
        LoginLogger.shared.log("▶ 吊销证书（team=\(team.identifier), serial=\(serialNumber)）")
        var headers = try await makeHeaders(session: session)
        headers["Content-Type"] = "text/x-xml-plist"
        let body: [String: Any] = [
            "clientId": clientID,
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased(),
            "teamId": team.identifier,
            "serialNumber": serialNumber
        ]
        let url = qhURL.appendingPathComponent("ios/revokeDevelopmentCert.action").appendingQueryItem("clientId", clientID)
        _ = try await post(url: url, headers: headers, plistBody: body, method: "POST")
        LoginLogger.shared.log("✓ 吊销请求已接受")
    }

    // MARK: - Helpers

    /// v0.2.112：Apple 在 HTTP 200 的 plist 体里用 `resultCode` 表达业务错误。
    /// 1100 = "Your session has expired. Please log in." —— 常见于 dsid/authToken
    /// 与当前 Anisette 机器标识不匹配（例如被另一套认证实现的登录覆盖）。
    /// 统一识别成 `.sessionExpired`，好让 UI 给出「重新登录」的可操作提示，
    /// 而不是让用户对着一段 XML 原文发懵。
    private static func throwIfSessionExpired(_ data: Data) throws {
        guard let dict = plist(data) else { return }
        let code: Int? = (dict["resultCode"] as? NSNumber)?.intValue
            ?? (dict["resultCode"] as? String).flatMap { Int($0) }
        guard code == 1100 else { return }
        let reason = (dict["userString"] as? String) ?? "Your session has expired. Please log in."
        LoginLogger.shared.log("❌ 会话已过期（resultCode 1100）: \(reason)")
        throw AppleAPIError.sessionExpired
    }

    private static func post(url: URL, headers: [String: String], plistBody: [String: Any], method: String = "POST") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: plistBody, format: .xml, options: 0)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(http) else {
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw AppleAPIError.customError(code: http, message: "Apple API 请求失败（HTTP \(http)）: \(preview)")
        }
        try throwIfSessionExpired(data)
        return data
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

// MARK: - URL helper

private extension URL {
    func appendingQueryItem(_ name: String, _ value: String) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? self
    }
}
