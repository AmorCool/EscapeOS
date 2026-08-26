import Foundation
import CryptoKit

/// Apple GrandSlam 认证引擎（对应 StosSign 的 `Authentication`）。
/// 使用本项目自带的 `GSAAuth`（SRP-6a）完成 init → complete 握手，支持两步验证（受信任设备 / 短信），
/// 成功后返回 `Account` 与 `AppleAPISession`。全程只依赖原生框架。
enum AppleAuthenticator {
    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    static let gsaURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
    static let qhURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/")!

    /// 与 Apple 完成 SRP-6a 握手并登录。
    /// `verificationHandler` 在需要两步验证时被调用，参数为一个「提交验证码」的回调：
    /// 调用方应弹出输入界面，待用户填好验证码后调用 `reply(code)`（传 nil 表示取消）。
    /// `refreshAnisette`：两步验证提交后、重新握手前调用，获取全新的 Anisette 数据——
    /// Apple 的 anisette OTP 在一次握手成功后即失效（防止重放），复用旧数据会导致 -22421。
    static func authenticate(
        appleID unsanitizedAppleID: String,
        password: String,
        anisetteData: AnisetteData,
        verificationHandler: ((@escaping (String?) -> Void) async -> Void)? = nil,
        refreshAnisette: (() async throws -> AnisetteData)? = nil
    ) async throws -> (Account, AppleAPISession) {
        let sanitizedAppleID = unsanitizedAppleID.lowercased()
        LoginLogger.shared.log("▶ authenticate 开始: \(sanitizedAppleID)")
        defer { LoginLogger.shared.log("◀ authenticate 结束") }

        let clientDictionary: [String: Any] = [
            "bootstrap": true,
            "icscrec": true,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud",
            "loc": Locale.current.identifier,
            "X-Apple-Locale": Locale.current.identifier,
            "X-Apple-I-MD": anisetteData.oneTimePassword,
            "X-Apple-I-MD-M": anisetteData.machineID,
            "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
            "X-Apple-I-MD-LU": anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": anisetteData.routingInfo,
            "X-Apple-I-SRL-NO": anisetteData.deviceSerialNumber,
            "X-Apple-I-Client-Time": dateFormatter.string(from: anisetteData.date),
            "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "PST"
        ]

        let context = GSAAuth(username: sanitizedAppleID, password: password)
        guard let publicKey = context.start() else {
            throw AppleAPIError.authenticationHandshakeFailed
        }

        let initialParameters: [String: Any] = [
            "A2k": publicKey,
            "cpd": clientDictionary,
            "ps": ["s2k", "s2k_fo"],
            "o": "init",
            "u": sanitizedAppleID
        ]

        let responseDictionary = try await sendAuthenticationRequest(parameters: initialParameters, anisetteData: anisetteData)

        guard let c = responseDictionary["c"] as? String,
              let salt = responseDictionary["s"] as? Data,
              let iterations = responseDictionary["i"] as? Int,
              let serverPublicKey = responseDictionary["B"] as? Data else {
            throw URLError(.badServerResponse)
        }

        context.salt = salt
        context.serverPublicKey = serverPublicKey

        let sp = responseDictionary["sp"] as? String
        let isHexadecimal = (sp == "s2k_fo")

        guard let verificationMessage = context.makeVerificationMessage(iterations: iterations, isHexadecimal: isHexadecimal) else {
            throw AppleAPIError.authenticationHandshakeFailed
        }

        let verificationParameters: [String: Any] = [
            "c": c,
            "cpd": clientDictionary,
            "M1": verificationMessage,
            "o": "complete",
            "u": sanitizedAppleID
        ]

        let verificationResponse = try await sendAuthenticationRequest(parameters: verificationParameters, anisetteData: anisetteData)

        guard let serverVerificationMessage = verificationResponse["M2"] as? Data,
              let serverDictionary = verificationResponse["spd"] as? Data,
              let statusDictionary = verificationResponse["Status"] as? [String: Any] else {
            throw URLError(.badServerResponse)
        }

        guard context.verifyServerVerificationMessage(serverVerificationMessage) else {
            throw AppleAPIError.authenticationHandshakeFailed
        }

        guard let decryptedData = context.decryptedCBC(serverDictionary) else {
            throw AppleAPIError.authenticationHandshakeFailed
        }

        guard let decryptedDictionary = try PropertyListSerialization.propertyList(from: decryptedData, format: nil) as? [String: Any],
              let dsid = decryptedDictionary["adsid"] as? String,
              let idmsToken = decryptedDictionary["GsIdmsToken"] as? String else {
            throw URLError(.badServerResponse)
        }

        context.dsid = dsid

        let authType = statusDictionary["au"] as? String
        LoginLogger.shared.log("✓ complete 握手成功，au=\(authType ?? "nil") dsid=\(dsid.prefix(8))…")
        switch authType {
        case "trustedDeviceSecondaryAuth":
            guard let verificationHandler else { throw AppleAPIError.requiresTwoFactorAuthentication }
            try await requestTrustedDeviceTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler)
            // 验证码通过后重新获取 Anisette（OTP 已被首次握手消费），再走完整握手
            let freshAnisette = try await (refreshAnisette?() ?? anisetteData)
            if freshAnisette.oneTimePassword != anisetteData.oneTimePassword {
                LoginLogger.shared.log("… 2FA 通过，刷新 Anisette OTP 后重新握手")
            }
            return try await authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: freshAnisette, verificationHandler: verificationHandler, refreshAnisette: refreshAnisette)

        case "secondaryAuth":
            guard let verificationHandler else { throw AppleAPIError.requiresTwoFactorAuthentication }
            try await requestSMSTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler)
            let freshAnisette = try await (refreshAnisette?() ?? anisetteData)
            if freshAnisette.oneTimePassword != anisetteData.oneTimePassword {
                LoginLogger.shared.log("… 短信验证通过，刷新 Anisette OTP 后重新握手")
            }
            return try await authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: freshAnisette, verificationHandler: verificationHandler, refreshAnisette: refreshAnisette)

        default:
            guard let sessionKey = decryptedDictionary["sk"] as? Data,
                  let cData = decryptedDictionary["c"] as? Data else {
                throw URLError(.badServerResponse)
            }
            context.sessionKey = sessionKey

            let app = "com.apple.gs.xcode.auth"
            guard let checksum = context.makeChecksum(appName: app) else {
                throw AppleAPIError.authenticationHandshakeFailed
            }

            let tokenParameters: [String: Any] = [
                "app": [app],
                "c": cData,
                "checksum": checksum,
                "cpd": clientDictionary,
                "o": "apptokens",
                "t": idmsToken,
                "u": dsid
            ]

            let token = try await fetchAuthToken(app: app, parameters: tokenParameters, context: context, anisetteData: anisetteData)

            let session = AppleAPISession(dsid: dsid, authToken: token, anisetteData: anisetteData)
            LoginLogger.shared.log("✓ apptokens 获取成功，token=\(token.prefix(12))…")
            let account: Account
            do {
                account = try await fetchAccount(session: session)
            } catch {
                account = Account(email: sanitizedAppleID, firstName: "", lastName: "")
            }
            return (account, session)
        }
    }

    // MARK: - GrandSlam 请求

    static func sendAuthenticationRequest(parameters requestParameters: [String: Any], anisetteData: AnisetteData) async throws -> [String: Any] {
        let requestBody: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": requestParameters
        ]

        var httpHeaders = [
            "Content-Type": "text/x-xml-plist",
            "X-MMe-Client-Info": anisetteData.deviceDescription,
            "Accept": "*/*",
            "User-Agent": "akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0"
        ]

        if requestParameters["o"] as? String == "complete" {
            httpHeaders["Connection"] = "close"
        }

        let bodyData = try PropertyListSerialization.data(fromPropertyList: requestBody, format: .xml, options: 0)

        var request = URLRequest(url: gsaURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard let responseDictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let dictionary = responseDictionary["Response"] as? [String: Any],
              let status = dictionary["Status"] as? [String: Any] else {
            LoginLogger.shared.log("❌ GrandSlam HTTP \(http) 响应解析失败: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            throw URLError(.badServerResponse)
        }

        let errorCode = status["ec"] as? Int ?? 0
        let errorMessage = status["em"] as? String ?? ""
        if errorCode != 0 {
            LoginLogger.shared.log("❌ GrandSlam 错误 ec=\(errorCode) em=\(errorMessage)")
        }
        guard errorCode == 0 else {
            switch errorCode {
            case -20101, -22406: throw AppleAPIError.incorrectCredentials
            case -22421:
                LoginLogger.shared.log("❌ Apple 拒绝 Anisette(-22421): \(errorMessage)")
                throw AppleAPIError.customError(code: -22421, message: "Anisette 被 Apple 拒绝: \(errorMessage)")
            case -20209: throw AppleAPIError.accountLocked
            default:
                guard !errorMessage.isEmpty else { throw AppleAPIError.unknown }
                throw AppleAPIError.customError(code: errorCode, message: errorMessage)
            }
        }

        return dictionary
    }

    static func makeTwoFactorCodeRequest(url: URL, dsid: String, idmsToken: String, anisetteData: AnisetteData) -> URLRequest {
        let identityToken = "\(dsid):\(idmsToken)"
        let encodedIdentityToken = identityToken.data(using: .utf8)?.base64EncodedString() ?? ""

        let httpHeaders = [
            "Accept": "application/x-buddyml",
            "Accept-Language": "en-us",
            "Content-Type": "application/x-plist",
            "User-Agent": "Xcode",
            "X-Apple-App-Info": "com.apple.gs.xcode.auth",
            "X-Xcode-Version": "11.2 (11B41)",
            "X-Apple-Identity-Token": encodedIdentityToken,
            "X-Apple-I-MD-M": anisetteData.machineID,
            "X-Apple-I-MD": anisetteData.oneTimePassword,
            "X-Apple-I-MD-LU": anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": "\(anisetteData.routingInfo)",
            "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
            "X-MMe-Client-Info": anisetteData.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from: anisetteData.date),
            "X-Apple-Locale": anisetteData.locale.identifier,
            "X-Apple-I-TimeZone": anisetteData.timeZone.abbreviation() ?? "PST"
        ]

        var request = URLRequest(url: url)
        httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    static func fetchAuthToken(app: String, parameters: [String: Any], context: GSAAuth, anisetteData: AnisetteData) async throws -> String {
        let responseDictionary = try await sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData)

        guard let encryptedToken = responseDictionary["et"] as? Data else {
            throw URLError(.badServerResponse)
        }
        guard let token = context.decryptedGCM(encryptedToken) else {
            throw AppleAPIError.authenticationHandshakeFailed
        }
        guard let tokensDictionary = try PropertyListSerialization.propertyList(from: token, format: nil) as? [String: Any],
              let appTokens = tokensDictionary["t"] as? [String: Any],
              let tokens = appTokens[app] as? [String: Any],
              let authToken = tokens["token"] as? String else {
            throw URLError(.badServerResponse)
        }
        return authToken
    }

    // MARK: - 两步验证

    static func requestTrustedDeviceTwoFactorCode(dsid: String, idmsToken: String, anisetteData: AnisetteData,
                                                   verificationHandler: @escaping (@escaping (String?) -> Void) async -> Void) async throws {
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
        let verifyURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!

        let request = makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        _ = try await URLSession.shared.data(for: request)

        let verificationCode = try await withCheckedThrowingContinuation { continuation in
            Task {
                await verificationHandler { code in
                    continuation.resume(returning: code)
                }
            }
        }

        guard let code = verificationCode else { throw AppleAPIError.requiresTwoFactorAuthentication }

        var verifyRequest = makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        verifyRequest.allHTTPHeaderFields?["security-code"] = code

        let (data, _) = try await URLSession.shared.data(for: verifyRequest)
        guard let responseDictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        let errorCode = responseDictionary["ec"] as? Int ?? 0
        guard errorCode == 0 else {
            switch errorCode {
            case -21669: throw AppleAPIError.incorrectVerificationCode
            default:
                guard let errorDescription = responseDictionary["em"] as? String else { throw AppleAPIError.unknown }
                throw AppleAPIError.customError(code: errorCode, message: errorDescription)
            }
        }
    }

    static func requestSMSTwoFactorCode(dsid: String, idmsToken: String, anisetteData: AnisetteData,
                                        verificationHandler: @escaping (@escaping (String?) -> Void) async -> Void) async throws {
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/phone/put?mode=sms")!
        let verifyURL = URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode?referrer=/auth/verify/phone/put")!

        var request = makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        request.httpMethod = "POST"
        let bodyXML = ["serverInfo": ["phoneNumber.id": "1"]] as [String: Any]
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: bodyXML, format: .xml, options: 0)
        _ = try await URLSession.shared.data(for: request)

        let verificationCode = try await withCheckedThrowingContinuation { continuation in
            Task {
                await verificationHandler { code in
                    continuation.resume(returning: code)
                }
            }
        }

        guard let code = verificationCode else { throw AppleAPIError.requiresTwoFactorAuthentication }

        var verifyRequest = makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        verifyRequest.httpMethod = "POST"
        let verifyBodyXML = [
            "securityCode.code": code,
            "serverInfo": ["mode": "sms", "phoneNumber.id": "1"]
        ] as [String: Any]
        verifyRequest.httpBody = try PropertyListSerialization.data(fromPropertyList: verifyBodyXML, format: .xml, options: 0)

        let (_, response) = try await URLSession.shared.data(for: verifyRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              httpResponse.allHeaderFields.keys.contains("X-Apple-PE-Token") else {
            throw AppleAPIError.incorrectVerificationCode
        }
    }

    // MARK: - 账户信息

    static func fetchAccount(session: AppleAPISession) async throws -> Account {
        let url = qhURL.appendingPathComponent("viewDeveloper.action")
        let parameters: [String: String] = [
            "clientId": "XABBG36SBA",
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased()
        ]
        let body = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue(session.dsid, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        request.setValue(session.authToken, forHTTPHeaderField: "X-Apple-GS-Token")
        request.setValue(session.anisetteData.machineID, forHTTPHeaderField: "X-Apple-I-MD-M")
        request.setValue(session.anisetteData.oneTimePassword, forHTTPHeaderField: "X-Apple-I-MD")
        request.setValue(session.anisetteData.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(String(session.anisetteData.routingInfo), forHTTPHeaderField: "X-Apple-I-MD-RINFO")
        request.setValue(session.anisetteData.deviceUniqueIdentifier, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(session.anisetteData.deviceDescription, forHTTPHeaderField: "X-MMe-Client-Info")
        request.setValue(dateFormatter.string(from: session.anisetteData.date), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(session.anisetteData.locale.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(session.anisetteData.timeZone.abbreviation() ?? "GMT", forHTTPHeaderField: "X-Apple-I-TimeZone")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let resp = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let developer = resp["developer"] as? [String: Any] else {
            throw AppleAPIError.badServerResponse
        }
        let jsonData = try JSONSerialization.data(withJSONObject: developer)
        return try JSONDecoder().decode(Account.self, from: jsonData)
    }
}
