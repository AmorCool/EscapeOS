//
//  AppStoreAccount.swift
//  ApplePackage
//
//  Created by qaq on 9/14/25.
//

import Foundation

public struct AppStoreAccount: Codable, Hashable, Equatable, Sendable {
    public var email: String
    public var password: String

    public var appleId: String // /accountInfo/appleId
    public var store: String
    public var firstName: String // /accountInfo/address/firstName
    public var lastName: String // /accountInfo/address/lastName
    public var passwordToken: String // /passwordToken
    public var directoryServicesIdentifier: String // /dsPersonId
    public var cookie: [Cookie]
    /// Apple 认证分配的 store pod（pXX 编号）；从认证响应的 `pod` 响应头提取，
    /// 用于下游 download 调用路由到正确 store。ApplePackage 1.2.7 主线字段，
    /// 老持久化的 JSON 没有此字段时 Swift Codable 会自动解码为 nil（向后兼容）。
    public var pod: String?
    /// Preserve Apple's complete storefront header; old account JSON remains compatible.
    public var fullStoreFront: String?
    /// Changes only after an explicit login/refresh. Stale requests cannot replace a newer session.
    public var sessionRevision: UUID?
    /// v0.3.354：这份会话是**在哪台机器身份（guid）下签发**的。
    ///
    /// Apple 的 store 会话（passwordToken / Cookie）与「机器身份」绑定：guid 变了以后，
    /// 旧票据在 Apple 眼里属于另一台设备。继续把它当 Cookie 发出去，Auth 边缘会回
    /// 畸形应答（真机实测 204 空响应 / 302 无 Location），而不是一句清楚的
    /// "Sign In to the iTunes Store"。所以换身份后**不能再带旧 Cookie 去登录**。
    public var deviceGuid: String?

    public var requestStoreFront: String {
        if let fullStoreFront, !fullStoreFront.isEmpty { return fullStoreFront }
        return store.isEmpty ? "" : "\(store)-1"
    }

    private enum CodingKeys: String, CodingKey {
        case email, password, appleId, store, firstName, lastName, passwordToken
        case directoryServicesIdentifier, cookie, pod, fullStoreFront, sessionRevision, deviceGuid
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        email = try values.decode(String.self, forKey: .email)
        password = try values.decode(String.self, forKey: .password)
        appleId = try values.decode(String.self, forKey: .appleId)
        store = try values.decode(String.self, forKey: .store)
        firstName = try values.decode(String.self, forKey: .firstName)
        lastName = try values.decode(String.self, forKey: .lastName)
        passwordToken = try values.decode(String.self, forKey: .passwordToken)
        directoryServicesIdentifier = try values.decode(String.self, forKey: .directoryServicesIdentifier)
        cookie = try values.decode([Cookie].self, forKey: .cookie)
        pod = try values.decodeIfPresent(String.self, forKey: .pod)
        fullStoreFront = try values.decodeIfPresent(String.self, forKey: .fullStoreFront)
        sessionRevision = try values.decodeIfPresent(UUID.self, forKey: .sessionRevision)
        deviceGuid = try values.decodeIfPresent(String.self, forKey: .deviceGuid)
    }

    public init(
        email: String,
        password: String,
        appleId: String,
        store: String,
        firstName: String,
        lastName: String,
        passwordToken: String,
        directoryServicesIdentifier: String,
        cookie: [Cookie],
        pod: String? = nil,
        fullStoreFront: String? = nil,
        sessionRevision: UUID? = nil,
        deviceGuid: String? = nil
    ) {
        self.email = email
        self.password = password
        self.appleId = appleId
        self.store = store
        self.firstName = firstName
        self.lastName = lastName
        self.passwordToken = passwordToken
        self.directoryServicesIdentifier = directoryServicesIdentifier
        self.cookie = cookie
        self.pod = pod
        self.fullStoreFront = fullStoreFront
        self.sessionRevision = sessionRevision
        self.deviceGuid = deviceGuid
    }
}

public extension AppStoreAccount {
    init(
        email: String,
        password: String,
        appleId: String?,
        store: String,
        firstName: String?,
        lastName: String?,
        passwordToken: String?,
        directoryServicesIdentifier: String?,
        cookie: [Cookie],
        pod: String? = nil,
        fullStoreFront: String? = nil,
        sessionRevision: UUID? = nil,
        deviceGuid: String? = nil
    ) throws {
        try ensure(!email.isEmpty, "empty email")
        try ensure(!password.isEmpty, "empty password")
        self.email = email
        self.password = password
        self.appleId = try appleId.get("unable to read appleId")
        try ensure(!store.isEmpty, "unknown store identifier")
        try ensure(Configuration.countryCode(for: store) != nil, "unsupported store identifier: \(store)")
        self.store = store
        self.firstName = try firstName.get("unable to read firstName")
        self.lastName = try lastName.get("unable to read lastName")
        self.passwordToken = try passwordToken.get("unable to read passwordToken")
        self.directoryServicesIdentifier = try directoryServicesIdentifier.get("unable to read dsPersonId")
        self.cookie = cookie
        self.pod = pod
        self.fullStoreFront = fullStoreFront
        self.sessionRevision = sessionRevision
        self.deviceGuid = deviceGuid
    }
}
