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
        // 每次调用都取全新 Anisette（新 OTP），避免一次性 OTP 失效
        let anisette = try await AnisetteProvider.shared.getAnisetteData()
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

    // MARK: - Helpers

    private static func post(url: URL, headers: [String: String], plistBody: [String: Any], method: String = "POST") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: plistBody, format: .xml, options: 0)
        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(http) else {
            let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw AppleAPIError.customError(code: http, message: "Apple API 请求失败（HTTP \(http)）: \(preview)")
        }
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
