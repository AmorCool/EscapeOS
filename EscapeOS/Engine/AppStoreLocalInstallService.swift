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
        //                 ChatGPT 这类应用只有带旧版本 ID 才出包；v0.3.366 候选来源为
        //                 「三方目录 → 爱思 appinfo historyversion」两条，见 candidateVersionIDs）
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
        /// v0.3.362：版本号 → `externalVersionId`，用于把「命中那一版」记进缓存
        var versionByNumber: [String: String] = [:]
        var attempt = 0
        while true {
            attempt += 1
            guard attempt <= 6 else { throw ApplePackageError.emptyPackage }
            try Task.checkCancellation()
            do {
                onLog?("[AppleID] 请求下载信息…")
                // v0.3.365（请求放大审计）：候选**只吃一轮** —— 原来 versionCandidates 常驻，
                // attempt 每轮都会重新进候选循环，同一批 6 个候选被重打 2 次（一次动作纯重复 12 次请求），
                // 而连发会撞 429、正好把本轮的修复打坏。这里在调用前就清空（成败都不再重复）。
                let pendingCandidates = versionCandidates
                versionCandidates = []
                let output = try await Download.download(account: &account, app: software,
                                                         externalVersionID: externalVersionID,
                                                         versionCandidates: pendingCandidates)
                if let newest = newestCatalogVersion, output.bundleShortVersionString != newest {
                    onLog?("[AppleID] Apple 拒绝了最新版，已改用该账号可下的版本 \(output.bundleShortVersionString)")
                    // 记住这一版，下次直接先试它（否则窗口滑走后又变回空包）
                    rememberVersionID(versionByNumber[output.bundleShortVersionString],
                                      dsid: account.directoryServicesIdentifier,
                                      bundleId: software.bundleID)
                }
                return output
            } catch ApplePackageError.emptyPackage where !triedVersionCandidates {
                // 第一优先：用历史版本候选重打 volumeStore（真机实测这才是能出包的那一档，
                // 不需要刷新会话也不需要购买）。候选为空会自动落到下面「刷新会话」那条分支。
                triedVersionCandidates = true
                onLog?("[AppleID] Apple 未返回可下载内容 → 换该账号可下的历史版本重试")
                let candidates = await candidateVersionIDs(
                    software: software, dsid: account.directoryServicesIdentifier, onLog: onLog)
                versionCandidates = candidates.ids
                newestCatalogVersion = candidates.newestVersion
                versionByNumber = candidates.byVersion
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

    /// v0.3.361 / v0.3.362 / v0.3.366：取该应用的 `externalVersionId` 候选（**有序、有界**）。
    ///
    /// 依据（真机实测）：ChatGPT 的 `volumeStoreDownloadProduct` 只在 body 带 `externalVersionId`
    /// 时才出包，且**最新的两个 ID 会被 Apple 拒**、更旧的可以下 —— 所以拿最新的若干个去试。
    ///
    /// **来源链（v0.3.366 加入第二来源）**：
    /// 1. **三方版本目录** `AppStoreService.versionHistoryFromCatalog(appId:)` —— 它有最新版，优先；
    /// 2. 目录**抛错或返回空** → **爱思** `POST app4.i4.cn/appinfo.xhtml` 的 `historyversion[]`
    ///    取 `versionid`（`versionid` 与 Apple `externalVersionId` 同口径，已鉴定：4/4 数值精确相等，
    ///    且跨应用按日期交错，只能是 Apple 的全局版本计数器）。
    /// 两条都拿不到 → 返回空数组，调用方继续走原来的刷新/购买流程（**不新增硬失败**）。
    ///
    /// **排序**：两条来源统一按 `versionid`（= `externalVersionId`）数值**降序** —— 它是 Apple 的
    /// 全局计数器，数值越大越新；爱思的 `releasetime` 只是缓存快照日期，不能用作排序依据。
    ///
    /// **请求上界（候选阶段）**：目录 ≤ 1 次调用；只有目录抛错/为空时才进爱思档
    /// = 1 次搜索（trackId → 爱思 appid 映射）+ 1 次详情，**最坏共 3 次**（新增最多 2 次）。
    ///
    /// v0.3.362：只取「最新 6 个」有**静默失效**风险 —— 前两槽固定被拒，而 ChatGPT 约每周一版，
    /// 4~6 周后可用项就会被挤出窗口，表现为「突然又下不了」。所以：
    /// **把上次成功的 `externalVersionId` 缓存在候选第 1 位**（命中即停），窗口退化为兜底。
    /// 缓存只影响「先试哪个」，丢了最多多撞一轮，所以放 UserDefaults 足够（Documents 留给凭据）。
    private static func candidateVersionIDs(software: Software, dsid: String,
                                            onLog: ((String) -> Void)?)
        async -> (ids: [String], newestVersion: String?, byVersion: [String: String]) {
        // 两条来源归一成同一种形状：(externalVersionId, 版本号)，随后的排序/裁剪只写一处。
        var pairs: [(id: String, version: String)] = []
        var source = "目录"

        do {
            let history = try await AppStoreService.versionHistoryFromCatalog(appId: String(software.id))
            for v in history {
                if let ext = v.externalVersionID, !ext.isEmpty {
                    pairs.append((id: ext, version: v.version))
                }
            }
            if pairs.isEmpty { onLog?("[AppleID] 版本目录没有候选") }
        } catch {
            onLog?("[AppleID] 版本目录不可用：\(error.localizedDescription)")
        }

        if pairs.isEmpty {
            source = "爱思"
            do {
                let versions = try await I4PCStoreClient.historyVersions(
                    trackId: String(software.id), name: software.name)
                for v in versions where !v.id.isEmpty { pairs.append((id: v.id, version: v.version)) }
                if pairs.isEmpty { onLog?("[AppleID] 爱思没有历史版本") }
            } catch {
                onLog?("[AppleID] 爱思源不可用：\(error.localizedDescription)")
            }
        }

        guard !pairs.isEmpty else {
            onLog?("[AppleID] 历史版本候选 0 个")
            return ([], nil, [:])
        }

        // 统一按 versionid 数值降序（等价于「最新在前」）；非数值 id 排到最后。
        pairs.sort { (Int64($0.id) ?? 0) > (Int64($1.id) ?? 0) }

        let byVersion = Dictionary(pairs.map { ($0.version, $0.id) },
                                   uniquingKeysWith: { first, _ in first })
        var ids = pairs.map { $0.id }
        if let cached = cachedVersionID(dsid: dsid, bundleId: software.bundleID),
           let index = ids.firstIndex(of: cached) {
            ids.remove(at: index)
            ids.insert(cached, at: 0)
        }
        let window = Array(ids.prefix(6))
        // 日志要一眼看出候选来自哪条来源（目录 / 爱思）、几个、最新是哪版。
        onLog?("[AppleID] 历史版本候选 \(window.count) 个（\(source) · 最新 \(pairs.first?.version ?? "?")）")
        return (window, pairs.first?.version, byVersion)
    }

    /// 上次成功下到包用的 `externalVersionId`（按 dsid + bundleId）。
    private static func cachedVersionID(dsid: String, bundleId: String) -> String? {
        guard !dsid.isEmpty, !bundleId.isEmpty else { return nil }
        let key = "AppStore.LastGoodVersion.\(dsid).\(bundleId)"
        let value = UserDefaults.standard.string(forKey: key)
        return (value?.isEmpty == false) ? value : nil
    }

    private static func rememberVersionID(_ id: String?, dsid: String, bundleId: String) {
        guard let id, !id.isEmpty, !dsid.isEmpty, !bundleId.isEmpty else { return }
        UserDefaults.standard.set(id, forKey: "AppStore.LastGoodVersion.\(dsid).\(bundleId)")
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
