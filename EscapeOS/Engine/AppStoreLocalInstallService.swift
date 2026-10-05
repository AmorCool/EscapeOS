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
                                   // Swift 6：本闭包会传进 AppStoreInstallService.installLocalIPA
                                   // 的 @Sendable 参数，这里也要对齐标 @Sendable（CI 实测 :84）。
                                   installProgress: (@Sendable (Double) -> Void)? = nil,
                                   onResolvedURL: ((String) -> Void)? = nil,
                                   onLog: ((String) -> Void)? = nil) async throws -> URL {
        let t0 = Date()
        let software = try makeSoftware(item)

        // v0.3.402：**把设备身份读取从下载启动的关键路径上摘下来**。
        //
        // 这里原来是一句同步的 `LocalDeviceIdentity.apply()` —— 它会连建 2 次 RSD 隧道
        // （`lockdownFullDict` 一次 + `com.apple.mobile.iTunes` 域一次，后者只为两个 FairPlay
        // 字段），真机实测秒级。用户看到的现象就是「点了下载要等好几秒才动」。
        //
        // 而现在这几个字段在**本链路上没有任何消费者**：
        //   · `serialNumber` 不进请求 —— 请求体写死了 `"0"`
        //     （`StoreDownloadEndpoint+Fetch.swift:290`，v0.3.334 真机验证过的决定），
        //     它只喂 `Download.swift:123` 的一行日志；
        //   · `fairPlayCertificate` / `fairPlayDeviceType` 全工程只写不读（v0.3.402 已删）。
        //
        // 所以改成「后台预热 + 只吃缓存」：**启动路径上一个设备 IO 都不等**。
        // 首次下载因此不再付隧道时间；缓存热了之后，下面 `applyIfCached()` 顺手把
        // `Configuration.deviceSerialNumber` 补上（写与它后面的读在**同一任务**里，无跨线程竞争）。
        // 预热跑在「等账号租约」这段时间里 —— 那本来就是要等的，正好重叠掉。
        LocalDeviceIdentity.warmUpInBackground()
        onLog?("[计时] 下载链路启动（点击→此处 \(ms(since: t0))ms：任务调度 + makeSoftware）")

        // 计时锚点：这一时刻之前的时间 = 账号租约门的排队等待（不是隧道）。
        let leaseWaitStarted = Date()
        let output = try await StoreAccountSession.withAccount(email: email) { account in
            // 本闭包的第一句 —— 它跑起来就说明租约已经拿到。
            // 于是「上面的锚点 → 这里」正好等于**门等待**，与后面的设备身份步骤彻底分开。
            onLog?("[计时] 账号租约已获得（门等待 \(ms(since: leaseWaitStarted))ms）")

            if account.directoryServicesIdentifier.isEmpty { throw LocalError.accountIncomplete("dsPersonId") }
            if account.passwordToken.isEmpty { throw LocalError.accountIncomplete("passwordToken") }

            let identityStarted = Date()
            LocalDeviceIdentity.applyIfCached()
            onLog?("[计时] 设备身份步骤 \(ms(since: identityStarted))ms"
                + "（只吃缓存；冷缓存时由后台预热补，不阻塞）")
            return try await downloadInformation(software: software, account: &account,
                email: email, externalVersionID: externalVersionID, onLog: onLog)
        }
        // Release account lease and persist cookies before the lengthy IPA transfer/installation.
        try Task.checkCancellation()
        onLog?("[计时] 已拿到下载信息（含账号租约内全部网络往返 合计 \(ms(since: leaseWaitStarted))ms）")
        onLog?("[AppleID] 版本 \(output.bundleShortVersionString)(\(output.bundleVersion))，sinf \(output.sinfs.count) 个")
        onLog?("[下载] \(URL(string: output.downloadURL)?.host ?? "?")")
        // v0.3.391：把 Apple 这次签发的下载地址**回传给调用方**，由它写进下载台账。
        //
        // 用户要的是「**记住我这一次下载用的链接**」—— 他自己也说了「尽管是有有效期会失效的」。
        // 之前我们以「AppleID 通道的地址必须带授权头才有效」为理由**什么都不给**，
        // 那是把「这个链接单独能用吗」和「这个链接有没有留档」混为一谈了 —— 用户要的是后者。
        onResolvedURL?(output.downloadURL)
        let name = "\(software.bundleID)-\(output.bundleShortVersionString).ipa"
        // v0.3.571：下载源必须是 Apple 自有域（初始 URL + 每次重定向都查）。
        // 这条是 `SignatureInjector`「输入来自 Apple 正版包」这一前提的**强制点**：
        // 商店 API 响应里的 `downloadURL` 逐字进入下载，若被引到第三方域，包内的
        // `SC_Info/Manifest.plist` 就不可信（vendor 侧有意不做路径校验，正是以此为前提）。
        let dest = try await AppStoreInstallService.downloadIPA(urlString: output.downloadURL,
            suggestedName: name, progress: downloadProgress,
            hostPolicy: StoreAuthenticationProtocol.isAppleHost, onLog: onLog)
        try Task.checkCancellation()
        onLog?("[注入] 写入 SC_Info…")
        try await SignatureInjector.inject(sinfs: output.sinfs, into: dest.path)
        try await AppStoreInstallService.installLocalIPA(dest.path, progress: installProgress, onLog: onLog)
        return dest
    }

    private static func downloadInformation(software: Software, account: inout AppStoreAccount,
                                            email: String, externalVersionID: String?,
                                            onLog: ((String) -> Void)?) async throws -> DownloadOutput {
        // 有界状态机（v0.3.352 重写，v0.3.361 加入历史版本候选，v0.3.539 收紧）：
        //   下载 → 票据失效（2002/2034/2042）→ 刷新会话一次 → 继续
        //        → 空包 → **改用候选列表里最可能可下的那一个版本号**（v0.3.539：只挑一个，
        //                 不再把 6 个候选交给下层循环重打）→ 仍为空 → 刷新会话一次
        //                → 仍为空 → 获取许可一次 → 再下载
        //        → 9610 → 获取许可一次 → 再下载
        //        → **传输层失败（502/带 body 的 5xx/网络错误）→ 直接上抛，不补救**
        // Apple 的两种「没有下载权」表达方式（`failureType 9610` 与 HTTP 200 + 空 songList）
        // 都必须触发同一段补救逻辑。而 5xx 是**基础设施状态**，与许可无关，不参与补救。
        var refreshed = false
        var licensed = false
        var emptyRetried = false
        /// v0.3.361：空包时改用的历史版本 ID。
        /// v0.3.539：语义改为「**本轮实际要用的版本号**」—— 一旦选定就直接驱动
        /// `externalVersionID` 下发，不再让 ApplePackage 内部做候选循环。
        var selectedVersionID: String?
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
                // v0.3.539：选定版本（若有）直接作为主体版本下发 —— 这就是「用候选」的实现，
                // 只是把循环从 ApplePackage 内部挪回了调用方（上游 download 没有候选参数）。
                let effectiveVersion = selectedVersionID ?? externalVersionID
                let output = try await Download.download(account: &account, app: software,
                                                         externalVersionID: effectiveVersion)
                if let newest = newestCatalogVersion, output.bundleShortVersionString != newest {
                    onLog?("[AppleID] Apple 拒绝了最新版，已改用该账号可下的版本 \(output.bundleShortVersionString)")
                    // 记住这一版，下次直接先试它（否则窗口滑走后又变回空包）
                    rememberVersionID(versionByNumber[output.bundleShortVersionString],
                                      dsid: account.directoryServicesIdentifier,
                                      bundleId: software.bundleID)
                }
                return output
            } catch ApplePackageError.transportFailure {
                // v0.3.539：**传输层失败绝不补救，直接上抛。**
                //
                // 502 / 带 body 的 5xx / 网络错误都不是「Apple 没给你包」，而是基础设施状态。
                // 原来这类会被归一成 emptyPackage，于是走进下面「刷新会话 → 获取许可 → 重试」，
                // 每次都再撞一次 10 秒网关超时 —— 真机日志实测一次点击放大成
                // 4 次 5xx + 10 次 volumeStore 请求。现在如实报错，让用户稍后重试。
                onLog?("[AppleID] Apple 下载服务不可用（非许可问题），不再重试")
                throw ApplePackageError.transportFailure(status: -1)
            } catch ApplePackageError.emptyPackage where !triedVersionCandidates {
                // 第一优先：改用历史版本（真机实测这才是能出包的那一档，
                // 不需要刷新会话也不需要购买）。候选为空会自动落到下面「刷新会话」那条分支。
                triedVersionCandidates = true
                onLog?("[AppleID] Apple 未返回可下载内容 → 换该账号可下的历史版本重试")
                let candidates = await candidateVersionIDs(
                    software: software, dsid: account.directoryServicesIdentifier, onLog: onLog)
                // v0.3.539：候选改为**在调用方选一个**，作为下一轮的主体版本下发。
                //
                // 原来是把 6 个候选塞进 `versionCandidates` 让 ApplePackage 内部逐个重打 ——
                // 「一层循环套在另一层循环」，真机日志显示 6 个候选全被拒后还要退回
                // redownload 撞 10 秒网关超时，一次点击放大成 14 次请求。
                // 现在 `candidateVersionIDs` 回来的列表已经把「缓存命中」排在第 1 位，
                // 所以取 `.first` 就是「最可能可下的那一个」。
                selectedVersionID = candidates.ids.first
                if let picked = selectedVersionID {
                    onLog?("[AppleID] 历史版本候选 \(candidates.ids.count) 个，本轮先用 \(picked)")
                } else {
                    onLog?("[AppleID] 没有可用的历史版本候选")
                }
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

    /// v0.3.402：`[计时]` 日志用 —— 与锚点的毫秒差。
    ///
    /// 只是让差值一眼可见（`LoginLogger` 自己已经带 `HH:mm:ss.SSS` 绝对时间戳）。
    /// 不叫 `ms` 属性、也不与任何局部常量同名，避免「局部变量遮蔽方法名」那类编译坑。
    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
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
