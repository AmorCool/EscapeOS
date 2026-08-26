import SwiftUI
import Security

// MARK: - Keychain wrapper

/// A minimal keychain helper scoped to the given service.
/// Only supports string/bool/data for the small set of memory-limit credentials.
struct EscapeKeychain {
    let service: String

    func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func bool(for key: String) -> Bool? {
        guard let string = string(for: key) else { return nil }
        return string == "1"
    }

    func data(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ string: String?, for key: String) {
        set(string?.data(using: .utf8), for: key)
    }

    func set(_ bool: Bool, for key: String) {
        set(bool ? "1" : "0", for: key)
    }

    func set(_ data: Data?, for key: String) {
        delete(key)
        guard let data = data else { return }

        var attributes = baseQuery(for: key)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ key: String) {
        var query = baseQuery(for: key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }
}

// MARK: - SideStore account import

struct SideStoreAccount: Decodable {
    let email: String
    let password: String
    let adiPB: String
    let localUser: String

    enum CodingKeys: String, CodingKey {
        case email
        case password
        case adiPB
        case adiPb
        case adipb
        case localUser = "local_user"
        case localuser
        case localUserCamel = "localUser"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        adiPB = try container.decodeIfPresent(String.self, forKey: .adiPB)
            ?? container.decodeIfPresent(String.self, forKey: .adiPb)
            ?? container.decodeIfPresent(String.self, forKey: .adipb)
            ?? ""
        localUser = try container.decodeIfPresent(String.self, forKey: .localUser)
            ?? container.decodeIfPresent(String.self, forKey: .localuser)
            ?? container.decodeIfPresent(String.self, forKey: .localUserCamel)
            ?? ""
    }
}

enum MemoryLimitError: LocalizedError {
    case missingField
    case invalidLocalUser

    var errorDescription: String? {
        switch self {
        case .missingField:
            return "账户文件缺少必要字段（email / password / adiPB / local_user）。"
        case .invalidLocalUser:
            return "local_user 必须是 Base64 编码的 16 字节标识符。"
        }
    }
}

// MARK: - Settings model

/// Stores the credentials and Anisette server used by the "增加内存限制" flow.
/// The actual Apple Developer API calls (authenticate / fetch App IDs / patch capability)
/// will be wired to StosSign in a follow-up; this class handles the settings surface.
@MainActor
final class MemoryLimitSettings: ObservableObject {
    static let shared = MemoryLimitSettings()

    static let anisetteServers = [
        "https://ani.sidestore.io",
        "https://ani.stikstore.app",
        "https://ani.sidestore.app",
        "https://ani.846969.xyz"
    ]

    /// Strips the scheme (http/https) from an Anisette server URL for display.
    static func host(from server: String) -> String {
        server
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    @AppStorage("AnisetteServer") var anisetteServer: String = "https://ani.sidestore.io"

    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var appleID: String = ""

    private let keychain = EscapeKeychain(service: "com.ipaside.escapeos.memorylimit")

    private init() {
        refresh()
    }

    func refresh() {
        isLoggedIn = keychain.bool(for: "isLoggedIn") ?? false
        appleID = keychain.string(for: "appleID") ?? ""
    }

    // MARK: - Sign in / out

    func signIn(email: String, password: String) {
        keychain.set(email.trimmingCharacters(in: .whitespacesAndNewlines), for: "appleID")
        keychain.set(password, for: "applePassword")
        keychain.set(true, for: "isLoggedIn")
        refresh()
    }

    func signOut() {
        keychain.delete("appleID")
        keychain.delete("applePassword")
        keychain.delete("adiPb")
        keychain.delete("identifier")
        keychain.delete("isLoggedIn")
        refresh()
    }

    // MARK: - SideStore import

    func importSideStoreAccount(_ account: SideStoreAccount) throws {
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = account.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let adiPB = account.adiPB.trimmingCharacters(in: .whitespacesAndNewlines)
        let localUser = account.localUser.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !email.isEmpty else { throw MemoryLimitError.missingField }
        guard !password.isEmpty else { throw MemoryLimitError.missingField }
        guard !adiPB.isEmpty else { throw MemoryLimitError.missingField }
        guard !localUser.isEmpty else { throw MemoryLimitError.missingField }
        guard let decoded = Data(base64Encoded: localUser), decoded.count == 16 else {
            throw MemoryLimitError.invalidLocalUser
        }

        keychain.set(email, for: "appleID")
        keychain.set(password, for: "applePassword")
        keychain.set(adiPB, for: "adiPb")
        keychain.set(localUser, for: "identifier")
        keychain.set(true, for: "isLoggedIn")
        refresh()
    }
}
