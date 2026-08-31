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
        pod: String? = nil
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
        pod: String? = nil
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
    }
}
