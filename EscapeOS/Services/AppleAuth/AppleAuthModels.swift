import Foundation
import CryptoKit

// MARK: - AnisetteData

/// Apple 设备认证数据（Anisette Data）。
/// 字段与 StosSign / AltStore 的 AnisetteData 兼容，仅用于从 JSON 字典解码。
struct AnisetteData: Decodable {
    let machineID: String
    let oneTimePassword: String
    let localUserID: String
    let routingInfo: UInt64
    let deviceUniqueIdentifier: String
    let deviceSerialNumber: String
    let deviceDescription: String
    let date: Date
    let locale: Locale
    let timeZone: TimeZone

    /// 显式成员构造器（定义了 init(from:) 后 memberwise init 不再自动生成）。
    init(machineID: String, oneTimePassword: String, localUserID: String,
         routingInfo: UInt64, deviceUniqueIdentifier: String, deviceSerialNumber: String,
         deviceDescription: String, date: Date, locale: Locale, timeZone: TimeZone) {
        self.machineID = machineID
        self.oneTimePassword = oneTimePassword
        self.localUserID = localUserID
        self.routingInfo = routingInfo
        self.deviceUniqueIdentifier = deviceUniqueIdentifier
        self.deviceSerialNumber = deviceSerialNumber
        self.deviceDescription = deviceDescription
        self.date = date
        self.locale = locale
        self.timeZone = timeZone
    }

    private enum CodingKeys: String, CodingKey {
        case machineID, oneTimePassword, localUserID, routingInfo, deviceUniqueIdentifier, deviceSerialNumber, deviceDescription, date, locale, timeZone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try c.decode(String.self, forKey: .machineID)
        oneTimePassword = try c.decode(String.self, forKey: .oneTimePassword)
        localUserID = try c.decode(String.self, forKey: .localUserID)

        let routingInfoString = try c.decode(String.self, forKey: .routingInfo)
        guard let ri = UInt64(routingInfoString) else {
            throw DecodingError.dataCorruptedError(forKey: .routingInfo, in: c, debugDescription: "Invalid routingInfo")
        }
        routingInfo = ri

        deviceUniqueIdentifier = try c.decode(String.self, forKey: .deviceUniqueIdentifier)
        deviceSerialNumber = try c.decode(String.self, forKey: .deviceSerialNumber)
        deviceDescription = try c.decode(String.self, forKey: .deviceDescription)

        let dateString = try c.decode(String.self, forKey: .date)
        guard let d = AppleAuthenticator.dateFormatter.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "Invalid date")
        }
        date = d

        let localeIdentifier = try c.decode(String.self, forKey: .locale)
        locale = Locale(identifier: localeIdentifier)
        let timeZoneIdentifier = try c.decode(String.self, forKey: .timeZone)
        timeZone = TimeZone(abbreviation: timeZoneIdentifier) ?? TimeZone.current
    }
}

// MARK: - Account

/// Apple ID 账户信息，从开发者服务的 `developer` 字典解码。
struct Account: Decodable {
    let appleID: String
    let identifier: Int
    let firstName: String
    let lastName: String

    var name: String { firstName + " " + lastName }

    init(email: String, firstName: String, lastName: String) {
        self.appleID = email
        self.identifier = 0
        self.firstName = firstName
        self.lastName = lastName
    }

    private enum CodingKeys: String, CodingKey {
        case appleID = "email"
        case identifier = "personId"
        case firstName = "dsFirstName"
        case lastName = "dsLastName"
        case fallbackFirstName = "firstName"
        case fallbackLastName = "lastName"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appleID = try c.decode(String.self, forKey: .appleID)
        identifier = try c.decode(Int.self, forKey: .identifier)
        if let f = try c.decodeIfPresent(String.self, forKey: .firstName) {
            firstName = f
        } else if let f = try c.decodeIfPresent(String.self, forKey: .fallbackFirstName) {
            firstName = f
        } else { firstName = "Unknown" }
        if let l = try c.decodeIfPresent(String.self, forKey: .lastName) {
            lastName = l
        } else if let l = try c.decodeIfPresent(String.self, forKey: .fallbackLastName) {
            lastName = l
        } else { lastName = "Unknown" }
    }
}

// MARK: - AppleAPISession

/// 认证成功后拿到的会话（用于后续调用 Apple 开发者服务）。
struct AppleAPISession {
    let dsid: String
    let authToken: String
    let anisetteData: AnisetteData
}

// MARK: - AppleAPIError

enum AppleAPIError: Error {
    case unknown
    case invalidParameters
    case badServerResponse
    case incorrectCredentials
    case requiresTwoFactorAuthentication
    case incorrectVerificationCode
    case authenticationHandshakeFailed
    case invalidAnisetteData
    case accountLocked
    case customError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unknown: return "未知错误"
        case .invalidParameters: return "参数无效"
        case .badServerResponse: return "Apple 服务器返回了意外的响应"
        case .incorrectCredentials: return "Apple ID 或密码错误"
        case .requiresTwoFactorAuthentication: return "需要两步验证"
        case .incorrectVerificationCode: return "验证码错误或已过期"
        case .authenticationHandshakeFailed: return "与 Apple 服务器的认证握手失败"
        case .invalidAnisetteData: return "Anisette 数据无效或已过期"
        case .accountLocked: return "Apple ID 已被锁定"
        case .customError(let code, let message): return "错误 \(code)：\(message)"
        }
    }
}
