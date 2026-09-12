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
        // 有界状态机（v0.3.352 重写，v0.3.361 加入历史版本候选）：
        //   下载 → 票据失效（2002/2034/2042）→ 刷新会话一次 → 继续
        //        → 空包 → **先用候选 externalVersionId 重打一次 volumeStore**（v0.3.361：
        //                 ChatGPT 这类应用只有带旧版本 ID 才出包）
        //                → 仍为空 → 先刷新会话确认一次（Apple 用「合法空包」表达票据不被认可）
        //                → 仍为空 → 获取许可一次 → 再下载
        //        → 9610 → 获取许可一次 → 再下载
        // Apple 的两种「没有下载权」表达方式（`failureType 9610` 与 HTTP 200 + 空 songList，
        // 后者会被 redownload 的 5xx 包住）都必须触发同一段补救逻辑 —— 老实现只认 9610，
        // 且 351 把 redownload 失败还原成裸错误，导致空包这一档永远走不到购买。
        var refreshed = false
        var licensed = false
        var emptyRetried = false
        /// v0.3.361：空包时改用的历史版本候选（`externalVersionId`）
        var versionCandidates: [String] = []
        var triedVersionCandidates = false
        /// v0.3.361：候选里「最新版」的版本号 —— 仅用于最终日志说明
        /// （拿到包后版本号 != 它，才说明真的改用了旧版）。
        var newestCatalogVersion: String?
        var attempt = 0
        while true {
            attempt += 1
            guard attempt <= 8 else { throw ApplePackageError.emptyPackage }
            try Task.checkCancellation()
            do {
                onLog?("[AppleID] 请求下载信息…")
                let output = try await Download.download(account: &account, app: software,
                                                         externalVersionID: externalVersionID,
                                                         versionCandidates: versionCandidates)
                if let newest = newestCatalogVersion, output.bundleShortVersionString != newest {
                    onLog?("[AppleID] Apple 拒绝了最新版，已改用该账号可下的版本 \(output.bundleShortVersionString)")
                }
                return output
            } catch ApplePackageError.emptyPackage where !triedVersionCandidates {
                // 第一优先：用历史版本候选重打 volumeStore（真机实测这才是能出包的那一档，
                // 不需要刷新会话也不需要购买）。候选为空会自动落到下面「刷新会话」那条分支。
                triedVersionCandidates = true
                onLog?("[AppleID] Apple 未返回可下载内容 → 换该账号可下的历史版本重试")
                let candidates = await candidateVersionIDs(software: software, onLog: onLog)
                versionCandidates = candidates.ids
                newestCatalogVersion = candidates.newestVersion
            } catch ApplePackageError.passwordTokenExpired where !refreshed {
                refreshed = true
                try await refreshAccount(email: email, account: &account, onLog: onLog)
            } catch ApplePackageError.licenseRequired where !licensed {
                licensed = true
                onLog?("[AppleID] 该账号还没有此应用的许可（9610）→ 获取一次授权")
                try await acquireLicense(software: software, account: &account,
                                         email: email, onLog: onLog)
            } catch ApplePackageError.emptyPackage where !licensed {
                if !emptyRetried, !refreshed {
                    // 先确认这空包不是「会话票据不被认可」造成的（Apple 那种情况下同样回
                    // HTTP 200 + 空 songList，而不是 401）。直接去购买会白撞 2002。
                    emptyRetried = true
                    refreshed = true
                    onLog?("[AppleID] Apple 未返回可下载内容 → 刷新会话后重试")
                    try await refreshAccount(email: email, account: &account, onLog: onLog)
                } else {
                    licensed = true
                    onLog?("[AppleID] Apple 未返回可下载内容 → 获取一次授权后重试")
                    try await acquireLicense(software: software, account: &account,
                                             email: email, onLog: onLog)
                }
            }
        }
    }

    /// v0.3.361：从免登录版本目录取该应用的 `externalVersionId` 候选（目录是「最新在前」）。
    ///
    /// 依据（真机实测）：ChatGPT 的 `volumeStoreDownloadProduct` 只在 body 带 `externalVersionId`
    /// 时才出包，且**最新的两个 ID 会被 Apple 拒**、更旧的可以下 —— 所以取最新的 6 个拿去试
    /// （`versionCandidates`：890707559 / 890363403 被拒，890134149 可下，共 6 个必覆盖可用项）。
    /// 目录通道失败不算错：返回空数组即可，调用方会继续走原有的刷新会话 / 获取许可流程。
    private static func candidateVersionIDs(software: Software,
                                            onLog: ((String) -> Void)?) async -> (ids: [String], newestVersion: String?) {
        do {
            let history = try await AppStoreService.versionHistoryFromCatalog(appId: String(software.id))
            let ids = history.compactMap { $0.externalVersionID }.filter { !$0.isEmpty }
            let newestSix = Array(ids.prefix(6))
            onLog?("[AppleID] 历史版本候选 \(newestSix.count) 个（最新 \(history.first?.version ?? "?")）")
            // history 是「最新在前」，所以 first 就是商店最新版（= 被 Apple 拒的那个）。
            return (newestSix, history.first?.version)
        } catch {
            onLog?("[AppleID] 版本目录不可用：\(error.localizedDescription)")
            return ([], nil)
        }
    }

    /// 获取一次许可；票据失效时**先用已保存凭据刷新会话再买一次**。
    ///
    /// Apple 在会话票据不被认时对 buyProduct 回 `failureType 2002 / "Your password has
    /// changed."`（离线回放实测），而日志/下载链路当时都还好用 —— 这条必须按「票据失效」处理，
    /// 否则「已经买过的免费应用」永远拿不到授权，下载永远停在空包。
    private static func acquireLicense(software: Software, account: inout AppStoreAccount,
                                       email: String, onLog: ((String) -> Void)?) async throws {
        onLog?("[AppleID] 获取授权…")
        do {
            _ = describe(try await Purchase.purchase(account: &account, app: software), onLog: onLog)
        } catch ApplePackageError.passwordTokenExpired {
            try await refreshAccount(email: email, account: &account, onLog: onLog)
            onLog?("[AppleID] 获取授权（已刷新会话）…")
            _ = describe(try await Purchase.purchase(account: &account, app: software), onLog: onLog)
        }
        // 刚建立的许可在 Apple 侧生效有延迟，立刻重试会白打一次（IPARanger 同款等待）。
        try await Task.sleep(for: .milliseconds(2500))
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
