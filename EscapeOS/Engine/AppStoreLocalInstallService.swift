import Foundation

/// Download an account-authorized App Store package and install it locally.
enum AppStoreLocalInstallService {
    enum LocalError: Error, LocalizedError {
        case noAccount
        case badItemId
        case accountIncomplete(String)
        case reloginNeedsCode

        var errorDescription: String? {
            switch self {
            case .noAccount: return "没有可用的 Apple ID 账号，请先在 AppStore 商店里登录"
            case .badItemId: return "应用 ID 无效（需要数字形式的 trackId）"
            case let .accountIncomplete(what): return "账号信息不完整（缺少 \(what)），请重新登录 Apple ID。"
            case .reloginNeedsCode: return "登录已过期且 Apple 要求验证码，请到商店账号管理中重新登录。"
            }
        }
    }

    @discardableResult
    static func downloadAndInstall(item: AppStoreItem, email: String,
                                   externalVersionID: String? = nil,
                                   downloadProgress: ((Double) -> Void)? = nil,
                                   installProgress: ((Double) -> Void)? = nil,
                                   onLog: ((String) -> Void)? = nil) async throws -> URL {
        let software = try makeSoftware(item)
        let output = try await StoreAccountSession.withAccount(email: email) { account in
            if account.directoryServicesIdentifier.isEmpty { throw LocalError.accountIncomplete("dsPersonId") }
            if account.passwordToken.isEmpty { throw LocalError.accountIncomplete("passwordToken") }
            let identity = LocalDeviceIdentity.apply()
            if !identity.isUsable { onLog?("[本机] 未取到序列号，安装授权可能不可用") }
            return try await downloadInformation(software: software, account: &account,
                email: email, externalVersionID: externalVersionID, onLog: onLog)
        }
        // Release account lease and persist cookies before the lengthy IPA transfer/installation.
        try Task.checkCancellation()
        onLog?("[AppleID] 版本 \(output.bundleShortVersionString)(\(output.bundleVersion))，sinf \(output.sinfs.count) 个")
        onLog?("[下载] \(URL(string: output.downloadURL)?.host ?? "?")")
        let name = "\(software.bundleID)-\(output.bundleShortVersionString).ipa"
        let dest = try await AppStoreInstallService.downloadIPA(urlString: output.downloadURL,
            suggestedName: name, progress: downloadProgress, onLog: onLog)
        try Task.checkCancellation()
        onLog?("[注入] 写入 SC_Info…")
        try await SignatureInjector.inject(sinfs: output.sinfs, into: dest.path)
        try await AppStoreInstallService.installLocalIPA(dest.path, progress: installProgress, onLog: onLog)
        return dest
    }

    private static func downloadInformation(software: Software, account: inout AppStoreAccount,
                                            email: String, externalVersionID: String?,
                                            onLog: ((String) -> Void)?) async throws -> DownloadOutput {
        var needsLicense = false
        var purchased = false
        var refreshed = false
        while true {
            try Task.checkCancellation()
            do {
                if needsLicense {
                    // A license/empty package is not an expired ticket. Use the existing session first.
                    onLog?("[AppleID] 使用现有会话获取授权…")
                    let outcome = try await Purchase.purchase(account: &account, app: software)
                    _ = describe(outcome, onLog: onLog)
                    purchased = true
                    needsLicense = false
                    try await Task.sleep(for: .milliseconds(2500))
                }
                onLog?("[AppleID] 请求下载信息…")
                return try await Download.download(account: &account, app: software,
                                                    externalVersionID: externalVersionID)
            } catch ApplePackageError.licenseRequired where !purchased && !needsLicense {
                needsLicense = true
                onLog?("[AppleID] 缺少此应用的许可（9610）→ 获取一次授权")
            } catch ApplePackageError.emptyPackage where !purchased && !needsLicense {
                needsLicense = true
                onLog?("[AppleID] Apple 返回空包 → 使用现有会话尝试获取一次许可")
            } catch ApplePackageError.passwordTokenExpired where !refreshed {
                refreshed = true
                try await refreshAccount(email: email, account: &account, onLog: onLog)
            }
        }
    }

    @discardableResult
    static func acquireLicense(item: AppStoreItem, email: String,
                               onLog: ((String) -> Void)? = nil) async throws -> String {
        let software = try makeSoftware(item)
        return try await StoreAccountSession.withAccount(email: email) { account in
            do {
                return describe(try await Purchase.purchase(account: &account, app: software), onLog: onLog)
            } catch ApplePackageError.passwordTokenExpired {
                try await refreshAccount(email: email, account: &account, onLog: onLog)
                return describe(try await Purchase.purchase(account: &account, app: software), onLog: onLog)
            }
        }
    }

    private static func describe(_ outcome: Purchase.Outcome, onLog: ((String) -> Void)?) -> String {
        let text = outcome == .purchased ? "已获取许可证" : "该账号已拥有此应用"
        onLog?("[AppleID] \(text)")
        return text
    }

    private static func refreshAccount(email: String, account: inout AppStoreAccount,
                                       onLog: ((String) -> Void)?) async throws {
        do {
            onLog?("[AppleID] 票据失效 → 刷新一次会话")
            account = try await AppleIDSignInService.rotate(email: email, failedAccount: account)
            onLog?("[AppleID] 会话刷新成功")
        } catch let error as StoreAuthenticationError where error.needsCode {
            throw LocalError.reloginNeedsCode
        } catch {
            onLog?("[AppleID] 会话刷新未完成：\(error.localizedDescription)")
            throw error
        }
    }

    static func makeSoftware(_ item: AppStoreItem) throws -> Software {
        guard let id = Int64(item.id) else { throw LocalError.badItemId }
        return Software(id: id, bundleID: item.bundleId ?? "", name: item.name,
            version: item.version ?? "", price: item.price, artistName: item.seller ?? "",
            sellerName: item.seller ?? "", description: item.summary ?? "",
            averageUserRating: item.rating ?? 0, userRatingCount: item.ratingCount ?? 0,
            artworkUrl: item.iconURL ?? "", screenshotUrls: item.screenshots,
            minimumOsVersion: item.minimumOS ?? "", fileSizeBytes: item.fileSizeBytes.map { String($0) },
            releaseDate: item.updatedDate ?? "", formattedPrice: item.priceText,
            primaryGenreName: item.primaryGenre ?? "")
    }
}
