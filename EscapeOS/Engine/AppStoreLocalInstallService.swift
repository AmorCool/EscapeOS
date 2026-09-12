import Foundation

/// v0.3.301：用**本机 Apple ID** 从 App Store 官方源下载并安装。
///
/// 链路（Apple 官方通道，与第三方分发源并列）：
/// ```
/// LocalDeviceIdentity.apply()          身份就位（guid + serialNumber）
///   → Purchase.purchase                免费应用入库（拿授权）
///   → Download.download                取下载直链 + **sinfs**
///   → 下载 IPA
///   → SignatureInjector.inject         把 sinfs 写回包内 SC_Info/<exe>.sinf
///   → AppStoreInstallService.installLocalIPA
///        └─ 加密包 → PackageType:"Customer" + ApplicationSINF（installd 换取解密密钥）
/// ```
/// 与第三方分发源的本质差别：sinf 由 Apple 按**本机身份**生成，
/// 所以 installd 解得到 FairPlay 密文段 —— **不需要解密、不需要重签**。
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
            case .accountIncomplete(let what):
                return "账号信息不完整（缺少 \(what)），Apple 会把下载当成未登录（MZFinance.NoAccount_message）。"
                     + "请重新登录一次这个 Apple ID。"
            case .reloginNeedsCode:
                return "登录状态已过期，自动重登时 Apple 要求验证码 —— 请到 AppStore 商店的账号管理里重新登录一次。"
            }
        }
    }

    /// 下载并安装。`downloadProgress` / `installProgress` 在任意线程回调（0~1）。
    ///
    /// `externalVersionID` 非空时下载**指定历史版本**（版本历史页用）。
    @discardableResult
    static func downloadAndInstall(item: AppStoreItem,
                                   email: String,
                                   externalVersionID: String? = nil,
                                   downloadProgress: ((Double) -> Void)? = nil,
                                   installProgress: ((Double) -> Void)? = nil,
                                   onLog: ((String) -> Void)? = nil) async throws -> URL {
        guard let stored = AppStoreDownloadStore.shared.account(for: email) else {
            throw LocalError.noAccount
        }
        var account = stored
        // v0.3.335：**无论如何都把账号写回**。购买/下载过程中 Apple 会通过
        // Set-Cookie 轮换会话票据（`mergeCookies`），不回写就等于每次都在拿旧票据
        // 换新票据 —— 表现为「动不动就要重登」。Asspp 的 `withAccount` 同样会回写。
        defer { AppStoreDownloadStore.shared.updateFromAnyThread(account) }
        let software = try makeSoftware(item)

        // v0.3.307：先体检账号。dsid / passwordToken 为空时 Apple 必回
        // `MZFinance.NoAccount_message`（能登录≠账号可用），提前给明确原因，别让用户猜.
        if account.directoryServicesIdentifier.isEmpty {
            onLog?("[账号] dsid 为空 —— Apple 无法识别会话，重新登录该 Apple ID")
            throw LocalError.accountIncomplete("dsPersonId/dsid")
        }
        if account.passwordToken.isEmpty {
            onLog?("[账号] passwordToken 为空 —— 需要重新登录该 Apple ID")
            throw LocalError.accountIncomplete("passwordToken")
        }

        // 0) 身份就位：Apple 用 guid + serialNumber 关联本机 FairPlay 证书.
        //    guid 必须与登录时一致（apply 只写序列号，见 LocalDeviceIdentity 注释）.
        let identity = LocalDeviceIdentity.apply()
        onLog?("[本机] \(identity.summary)")
        onLog?("[账号] \(account.email) · dsid=\(account.directoryServicesIdentifier) · "
               + "cookie \(account.cookie.count) 条 · pod=\(account.pod ?? "-") · "
               + "guid=\(LocalDeviceIdentity.downloadGUID.prefix(12))…")
        if !identity.isUsable {
            onLog?("[本机] 警告：未取到序列号，Apple 可能按匿名设备发 sinf（装不上）")
        }

        // 1) 取下载直链 + sinf；2) 只有 Apple 说「缺许可」时才去购买
        //
        // v0.3.333：对齐 Asspp（Interface/Search/ProductView.swift）——
        //   · 主流程**只请求下载**，不无条件购买；
        //   · 下载回 `failureType 9610`（licenseRequired）时才走「获取许可」，
        //     而那一步**必定先 rotate 刷新 passwordToken 再 purchase**。
        // 我们此前无条件先 purchase，于是令牌一过期整条链路直接死在购买上。
        // 令牌失效（2034）时按 ipatool 的做法自动重登再重试。
        var output: DownloadOutput?
        var needLicense = false
        var refreshedForLicense = false
        /// v0.3.337：空包只给**一次**「刷新登录 + 获取许可」的机会。
        var triedLicenseForEmpty = false
        var retries = 0
        while true {
            do {
                if needLicense {
                    // Asspp 同款：购买前必先刷新令牌（just refreshed 时不重复打登录接口）
                    if !refreshedForLicense {
                        onLog?("[AppleID] 获取授权（先刷新登录）…")
                        try await refreshAccount(email: email, account: &account, onLog: onLog)
                        refreshedForLicense = true
                    } else {
                        onLog?("[AppleID] 获取授权…")
                    }
                    let outcome = try await Purchase.purchase(account: &account, app: software,
                                                              endpoint: .finance)
                    onLog?("[AppleID] 授权结果：\(outcome == .purchased ? "下单成功" : "该账号已拥有")")
                    if outcome == .alreadyOwned {
                        // v0.3.340：账号已有授权却仍然拿不到下载内容时，再用 Apple bag 里
                        // 那个真正的官方购买端点（MZBuy）试一次，结果写进日志 —— 两条端点
                        // 对同一请求的应答不同，这一步能把「到底哪条能建立下载权」测明。
                        do {
                            _ = try await Purchase.purchase(account: &account, app: software,
                                                            endpoint: .official)
                            onLog?("[AppleID] MZBuy 端点授权成功")
                        } catch {
                            onLog?("[AppleID] MZBuy 端点授权失败：\(error.localizedDescription)")
                        }
                    }
                    needLicense = false
                }
                onLog?("[AppleID] 请求下载信息…")
                output = try await Download.download(account: &account, app: software,
                                                     externalVersionID: externalVersionID)
                break
            } catch ApplePackageError.licenseRequired where !needLicense && retries < 2 {
                needLicense = true
                retries += 1
                onLog?("[AppleID] 该账号还没有此应用的许可（9610）→ 获取授权")
            } catch ApplePackageError.emptyPackage where !triedLicenseForEmpty {
                // v0.3.337：**空包也要走一次「获取许可」**。
                // 此前空包只回退端点、从不购买 → 这一档永远卡死（真机日志里
                // 「请求下载信息 → volumeStore 空包 → redownload 500」就是这条路）。
                // Apple 对「没建立过下载权」的应用回静默空包，而 `buyProduct` 才是
                // 建立它的正规途径（9610 能触发购买，空包却从不触发 = 逻辑漏洞）。
                triedLicenseForEmpty = true
                needLicense = true
                onLog?("[AppleID] Apple 未返回可下载内容（空包）→ 先刷新登录并获取许可，再重试")
            } catch ApplePackageError.passwordTokenExpired where retries < 2 {
                retries += 1
                onLog?("[AppleID] 登录已失效（2034 / Sign In to the iTunes Store）→ 自动重新登录…")
                try await refreshAccount(email: email, account: &account, onLog: onLog)
                refreshedForLicense = true
            }
        }
        guard let output else { throw ApplePackageError.passwordTokenExpired }
        onLog?("[AppleID] 版本 \(output.bundleShortVersionString)(\(output.bundleVersion))，"
               + "sinf \(output.sinfs.count) 个")

        // 3) 下载 IPA（带字节级进度）
        onLog?("[下载] \(URL(string: output.downloadURL)?.host ?? "?")")
        let name = "\(software.bundleID)-\(output.bundleShortVersionString).ipa"
        let dest = try await AppStoreInstallService.downloadIPA(
            urlString: output.downloadURL,
            suggestedName: name,
            progress: downloadProgress,
            onLog: onLog)

        // 4) 注入 sinf —— 缺它 installd 拿不到解密授权
        onLog?("[注入] 写入 SC_Info…")
        try await SignatureInjector.inject(sinfs: output.sinfs, into: dest.path)

        // 5) 安装（加密包自动走 ApplicationSINF 通道）
        try await AppStoreInstallService.installLocalIPA(dest.path,
                                                         progress: installProgress,
                                                         onLog: onLog)
        return dest
    }

    /// 用已保存的密码 + cookie 走一次 SAP 重登（`AppleIDSignInService.rotate`），
    /// 拿到新的 passwordToken / dsid / cookie，并写回账号库。
    /// Apple 要验证码时转成明确提示（`LocalError.reloginNeedsCode`）。
    /// 「获取许可证」—— 单独把该账号对该应用的授权买下来（免费应用）。
    ///
    /// 与下载链路里 9610 分支是同一件事：走 `buyProduct` 把授权买下来。
    /// **先用已存票据直接买，Apple 说票据过期（2034/2042）才 rotate 重登一次** —— 见下面注释。
    /// 返回一句可直接展示的结果。
    @discardableResult
    static func acquireLicense(item: AppStoreItem,
                               email: String,
                               onLog: ((String) -> Void)? = nil) async throws -> String {
        guard var account = AppStoreDownloadStore.shared.account(for: email) else {
            throw LocalError.noAccount
        }
        let software = try makeSoftware(item)
        onLog?("[AppleID] 获取许可证：\(item.bundleId ?? item.name)")
        // 先直接用已存票据购买；**只有** Apple 说票据过期（2034/2042）才重新登录。
        // 原来无条件 rotate：票据还有效时也白打一次登录，而登录端点被反复打会回
        // HTTP 204/301 空响应（按出口 IP 的限流），反而把整条链路打死。
        do {
            let outcome = try await Purchase.purchase(account: &account, app: software,
                                                      endpoint: .finance)
            AppStoreDownloadStore.shared.updateFromAnyThread(account)
            return describe(outcome, onLog: onLog)
        } catch ApplePackageError.passwordTokenExpired {
            onLog?("[AppleID] 票据过期 → 重新登录后重试")
            try await refreshAccount(email: email, account: &account, onLog: onLog)
            let outcome = try await Purchase.purchase(account: &account, app: software,
                                                      endpoint: .finance)
            AppStoreDownloadStore.shared.updateFromAnyThread(account)
            return describe(outcome, onLog: onLog)
        }
    }

    private static func describe(_ outcome: Purchase.Outcome,
                                 onLog: ((String) -> Void)?) -> String {
        switch outcome {
        case .purchased:
            onLog?("[AppleID] 授权结果：下单成功")
            return "已获取许可证"
        case .alreadyOwned:
            onLog?("[AppleID] 授权结果：该账号已拥有")
            return "该账号已拥有此应用"
        }
    }

    private static func refreshAccount(email: String,
                                       account: inout AppStoreAccount,
                                       onLog: ((String) -> Void)?) async throws {
        do {
            let refreshed = try await AppleIDSignInService.rotate(email: email)
            account = refreshed
            onLog?("[AppleID] 自动重登成功（dsid=\(refreshed.directoryServicesIdentifier)）")
        } catch let error as StoreAuthenticationError where error.needsCode {
            onLog?("[AppleID] 自动重登需要验证码")
            throw LocalError.reloginNeedsCode
        } catch {
            // v0.3.331：重登失败必须落日志 —— 否则日志会停在第 3 行，看不出为什么没续上
            onLog?("[AppleID] 自动重登失败：\(error.localizedDescription)")
            throw error
        }
    }

    /// AppStoreItem → ApplePackage Software
    static func makeSoftware(_ item: AppStoreItem) throws -> Software {
        guard let id = Int64(item.id) else { throw LocalError.badItemId }
        return Software(
            id: id,
            bundleID: item.bundleId ?? "",
            name: item.name,
            version: item.version ?? "",
            price: item.price,
            artistName: item.seller ?? "",
            sellerName: item.seller ?? "",
            description: item.summary ?? "",
            averageUserRating: item.rating ?? 0,
            userRatingCount: item.ratingCount ?? 0,
            artworkUrl: item.iconURL ?? "",
            screenshotUrls: item.screenshots,
            minimumOsVersion: item.minimumOS ?? "",
            fileSizeBytes: item.fileSizeBytes.map { String($0) },
            releaseDate: item.updatedDate ?? "",
            formattedPrice: item.priceText,
            primaryGenreName: item.primaryGenre ?? ""
        )
    }
}
