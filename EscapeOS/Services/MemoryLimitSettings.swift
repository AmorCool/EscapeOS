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

    /// Anisette 服务器列表：原有 4 个 + 合并 SideInstaller 社区列表
    /// （servers.sidestore.io）中我们没有的 11 个。
    static let anisetteServers = [
        // 原有
        "https://ani.sidestore.io",
        "https://ani.stikstore.app",
        "https://ani.sidestore.app",
        "https://ani.846969.xyz",
        // 合并自 SideInstaller（社区列表）
        "https://ani.sidestore.zip",
        "https://ani.npeg.us",
        "http://5.249.163.88:6969",
        "https://anisette.wedotstud.io",
        "https://ani.xu30.top",
        "https://ani.owoellen.rocks",
        "https://ani.idevicehacked.com",
        "https://ani.neoarz.com",
        "https://ani3server.fly.dev",
        "https://ani.jaydenha.uk",
        "https://anisette.crystall1ne.dev"
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
        migrateLegacySideloadSession()
        refresh()
    }

    // MARK: - 会话归属（v0.2.112：两套实现必须分开存）

    /// 当前 `dsid` / `authToken` 归属哪套 Apple 认证实现。
    ///
    /// **铁律**：`AppleAuthenticator`（Swift，自带 Anisette identifier/adiPb）与
    /// isideload（Rust，另一套 Anisette identifier/adiPb）产出的 dsid/authToken
    /// **互不通用**。v0.2.111 让两者共用 `dsid`/`authToken` 一对键，isideload 登录
    /// 会覆盖 Swift 侧会话，导致「证书管理」「增加内存限制」请求
    /// developerservices2 时返回 resultCode 1100（Your session has expired）。
    /// 现在：Swift 侧写 `dsid`/`authToken`，isideload 侧写
    /// `sideloadDSID`/`sideloadAuthToken`，永不互相覆盖。
    private enum SessionOwner: String {
        case swift = "swift"
        case sideload = "sideload"
    }

    private func currentOwner() -> SessionOwner? {
        guard let raw = keychain.string(for: "sessionOwner") else { return nil }
        return SessionOwner(rawValue: raw)
    }

    /// 自愈迁移：v0.2.111（及更早）把 isideload 的 dsid/authToken 写进了
    /// `dsid`/`authToken` 主键。升级到 v0.2.112 后，若主键当前归属 isideload，
    /// 就把它搬到 sideload 专用键并清掉主键，让 Swift 侧（证书管理 /
    /// 增加内存限制）回到「未登录」状态而不是拿着异种 token 反复 1100。
    private func migrateLegacySideloadSession() {
        guard currentOwner() == .sideload else { return }
        guard keychain.string(for: "sideloadDSID") == nil else {
            // 已迁移过：确保主键干净即可
            keychain.delete("dsid")
            keychain.delete("authToken")
            return
        }
        let legacyDSID = keychain.string(for: "dsid") ?? ""
        let legacyToken = keychain.string(for: "authToken") ?? ""
        if !legacyDSID.isEmpty { keychain.set(legacyDSID, for: "sideloadDSID") }
        if !legacyToken.isEmpty { keychain.set(legacyToken, for: "sideloadAuthToken") }
        keychain.delete("dsid")
        keychain.delete("authToken")
    }

    func refresh() {
        isLoggedIn = keychain.bool(for: "isLoggedIn") ?? false
        appleID = keychain.string(for: "appleID") ?? ""
    }

    /// Privacy-safe display form: keeps the first two characters of the local part
    /// and masks the rest with bullets, preserving the domain. e.g.
    /// `john.appleseed@icloud.com` → `jo••••••••@icloud.com`.
    func maskedAppleID() -> String {
        let email = appleID
        guard !email.isEmpty else { return "" }
        guard let at = email.firstIndex(of: "@") else {
            let n = min(email.count, 6)
            return String(repeating: "•", count: n)
        }
        let local = String(email[..<at])
        let domain = String(email[at...])
        let visibleCount = min(local.count, 2)
        let visible = local.prefix(visibleCount)
        let masked = String(repeating: "•", count: max(local.count - visibleCount, 1))
        return "\(visible)\(masked)\(domain)"
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
        keychain.delete("dsid")
        keychain.delete("authToken")
        keychain.delete("sideloadDSID")
        keychain.delete("sideloadAuthToken")
        keychain.delete("sessionOwner")
        keychain.delete("accountName")
        keychain.delete("isLoggedIn")
        refresh()
    }

    // MARK: - 登录完成（由 Apple 认证引擎调用）

    func completeSignIn(email: String, password: String, account: Account, session: AppleAPISession) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(email, for: "appleID")
        keychain.set(password, for: "applePassword")
        keychain.set(session.dsid, for: "dsid")
        keychain.set(session.authToken, for: "authToken")
        keychain.set(account.name, for: "accountName")
        keychain.set(account.firstName, for: "firstName")
        keychain.set(account.lastName, for: "lastName")
        keychain.set(true, for: "isLoggedIn")
        keychain.set(SessionOwner.swift.rawValue, for: "sessionOwner")
        // 记住该账户（供登录历史一键登录）
        keychain.set(password, for: "pw:" + email)
        addLoginHistory(email)
        refresh()
    }

    /// 保存 isideload（IPA 侧载）完整登录拿到的 dsid + `com.apple.gs.xcode.auth`
    /// token。
    ///
    /// **v0.2.112 关键修复**：这些凭据由 Rust 侧的 isideload 用自己的 Anisette
    /// identifier/adiPb 生成，**只能**用于 `si_signin_with_session`，**不能**给
    /// Swift 的 `AppleDeveloperAPI` 用。因此单独存
    /// `sideloadDSID`/`sideloadAuthToken`，绝不覆盖 `dsid`/`authToken`
    /// —— 否则「证书管理」「增加内存限制」会拿到异种 token，Apple 一律回
    /// resultCode 1100（Your session has expired）。
    func saveSessionCredentials(email: String, password: String, dsid: String, authToken: String) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(email, for: "appleID")
        keychain.set(password, for: "applePassword")
        keychain.set(password, for: "pw:" + email)
        if !dsid.isEmpty { keychain.set(dsid, for: "sideloadDSID") }
        if !authToken.isEmpty { keychain.set(authToken, for: "sideloadAuthToken") }
        keychain.set(true, for: "isLoggedIn")
        keychain.set(SessionOwner.sideload.rawValue, for: "sessionOwner")
        addLoginHistory(email)
        refresh()
    }

    // MARK: - 读取会话凭据

    /// Swift 认证引擎（`AppleAuthenticator`）的会话，供证书管理 / 增加内存限制用。
    var dsid: String? { keychain.string(for: "dsid") }
    var authToken: String? { keychain.string(for: "authToken") }

    /// isideload（Rust）的签名会话，供 IPA 侧载免登录恢复用。
    var sideloadDSID: String? { keychain.string(for: "sideloadDSID") }
    var sideloadAuthToken: String? { keychain.string(for: "sideloadAuthToken") }
    var accountName: String { keychain.string(for: "accountName") ?? "" }
    var firstName: String { keychain.string(for: "firstName") ?? "" }
    var lastName: String { keychain.string(for: "lastName") ?? "" }

    // MARK: - 登录历史（记住账户）

    private static let historyKey = "LoginHistory"

    /// 最近登录的邮箱列表（最近在前，最多 10 条）。
    var loginHistory: [String] {
        UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    func addLoginHistory(_ email: String) {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !e.isEmpty else { return }
        var list = loginHistory.filter { $0.lowercased() != e }
        list.insert(e, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: Self.historyKey)
    }

    func removeLoginHistory(_ email: String) {
        var list = loginHistory.filter { $0.lowercased() != email.lowercased() }
        UserDefaults.standard.set(list, forKey: Self.historyKey)
        keychain.delete("pw:" + email)
    }

    /// 历史账户的一键登录密码（keychain 中按邮箱单独保存；当前登录账户回退到 applePassword）。
    func password(forHistory email: String) -> String? {
        if let pw = keychain.string(for: "pw:" + email), !pw.isEmpty { return pw }
        if email.lowercased() == appleID.lowercased() {
            return keychain.string(for: "applePassword")
        }
        return nil
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
