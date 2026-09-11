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

        var errorDescription: String? {
            switch self {
            case .noAccount: return "没有可用的 Apple ID 账号，请先在 AppStore 商店里登录"
            case .badItemId: return "应用 ID 无效（需要数字形式的 trackId）"
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

        // 0) 身份就位：Apple 用 guid + serialNumber 关联本机 FairPlay 证书
        let identity = LocalDeviceIdentity.apply()
        onLog?("[本机] \(identity.summary)")
        if !identity.isUsable {
            onLog?("[本机] 警告：未取到序列号，Apple 可能按匿名设备发 sinf（装不上）")
        }

        // 1) 入库（免费应用）
        onLog?("[AppleID] 获取授权…")
        try await Purchase.purchase(account: &account, app: software)

        // 2) 取下载直链 + sinf
        onLog?("[AppleID] 请求下载信息…")
        let output = try await Download.download(account: &account, app: software)
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
