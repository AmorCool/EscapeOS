//
//  Account.swift
//  ApplePackage
//
//  Created by qaq on 9/14/25.
//

import Foundation

public struct Account: Codable, Hashable, Equatable, Sendable {
    public var email: String
    public var password: String

    public var appleId: String // /accountInfo/appleId
    public var store: String
    public var firstName: String // /accountInfo/address/firstName
    public var lastName: String // /accountInfo/address/lastName
    public var passwordToken: String // /passwordToken
    public var directoryServicesIdentifier: String // /dsPersonId
    public var cookie: [Cookie]

    public init(
        email: String,
        password: String,
        appleId: String,
        store: String,
        firstName: String,
        lastName: String,
        passwordToken: String,
        directoryServicesIdentifier: String,
        cookie: [Cookie]
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
    }
}

public extension Account {
    init(
        email: String,
        password: String,
        appleId: String?,
        store: String,
        firstName: String?,
        lastName: String?,
        passwordToken: String?,
        directoryServicesIdentifier: String?,
        cookie: [Cookie]
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
    }
}
