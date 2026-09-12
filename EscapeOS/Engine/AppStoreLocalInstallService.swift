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
    @discardableResult
    static func downloadAndInstall(item: AppStoreItem,
                                   email: String,
                                   downloadProgress: ((Double) -> Void)? = nil,
                                   installProgress: ((Double) -> Void)? = nil,
                                   onLog: ((String) -> Void)? = nil) async throws -> URL {
        guard let stored = AppStoreDownloadStore.shared.account(for: email) else {
            throw LocalError.noAccount
        }
        var account = stored
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

        // 1) 入库（免费应用）+ 2) 取下载直链 + sinf
        //
        // v0.3.330：Apple 的 `passwordToken` 有有效期，过期时购买/下载回
        // `failureType 2034`（Sign In to the iTunes Store）。按 ipatool 的做法
        // （cmd/purchase.go：Attempts(2) + RetryIf(ErrPasswordTokenExpired)）
        // **自动用已保存的凭据重登一次再重试** —— 带 cookie 轮换，通常不用再收验证码。
        var output: DownloadOutput?
        for attempt in 1 ... 2 {
            if attempt == 2 {
                onLog?("[AppleID] 登录已过期 → 用已保存的凭据自动重新登录…")
                try await refreshAccount(email: email, account: &account, onLog: onLog)
            }
            do {
                onLog?("[AppleID] 获取授权…")
                try await Purchase.purchase(account: &account, app: software)

                onLog?("[AppleID] 请求下载信息…")
                output = try await Download.download(account: &account, app: software)
                break
            } catch ApplePackageError.passwordTokenExpired {
                onLog?("[AppleID] Apple 判定登录已失效（2034 / Sign In to the iTunes Store）")
                if attempt == 2 { throw ApplePackageError.passwordTokenExpired }
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
    private static func makeSoftware(_ item: AppStoreItem) throws -> Software {
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
