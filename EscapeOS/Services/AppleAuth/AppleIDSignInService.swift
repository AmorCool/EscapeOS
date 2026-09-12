import Foundation

/// The App Store SAP flow is separate from AltStore/GrandSlam developer authentication.
enum AppleIDSignInService {
    /// Initialize the persisted identity first, then use the exact same GUID as purchase/download.
    static func sapGUID() -> String {
        _ = AppStoreDownloadStore.shared
        return Configuration.deviceIdentifier
    }

    @discardableResult
    static func signIn(email: String, password: String, code: String = "",
                       log: ((String) -> Void)? = nil) async throws -> AppStoreAccount {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { throw StoreAuthenticationError.credentialsRequired }
        try await StoreLoginBackoff.shared.check(email)
        log?("开始登录（本地 SAP 签名）")
        do {
            let authenticated = try await SignedStoreAuthenticator().authenticate(
                email: email, password: password, code: code, guid: sapGUID(), cookies: [])
            try Task.checkCancellation()
            let account = await MainActor.run {
                AppStoreDownloadStore.shared.add(authenticated)
                return AppStoreDownloadStore.shared.account(for: email) ?? authenticated
            }
            await StoreLoginBackoff.shared.clear(email)
            logRegion(account, log: log)
            log?("登录成功并已设为当前下载账号")
            return account
        } catch {
            if let authError = error as? StoreAuthenticationError {
                await StoreLoginBackoff.shared.record(authError, email: email)
            }
            throw error
        }
    }

    /// Refresh only on an explicit expired-ticket response. Passing the failed snapshot avoids
    /// a second login if another operation has already refreshed it. It does not select an account.
    @discardableResult
    static func rotate(email: String, code: String = "",
                       failedAccount: AppStoreAccount? = nil) async throws -> AppStoreAccount {
        return try await StoreRefreshCoordinator.shared.refresh(email: email, code: code, failedAccount: failedAccount)
    }

    private static func logRegion(_ account: AppStoreAccount, log: ((String) -> Void)?) {
        if let region = AppStoreService.adoptAccountRegion(storefront: account.store, email: account.email) {
            log?("账号区域 \(region.uppercased())（storefront \(account.store)），商店已跟随")
            LoginLogger.shared.log("[SAP] 账号区域 \(region.uppercased())（storefront \(account.store)）", category: .appStore)
        }
    }

    static var assetsReady: Bool {
        guard let url = SAPAssetsLocator.url else { return false }
        return ["CommerceKit", "CommerceCore", "CoreFP", "CoreFP.icxs"].allSatisfy {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }
}
