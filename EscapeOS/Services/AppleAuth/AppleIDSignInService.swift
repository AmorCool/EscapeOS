//
//  AppleIDSignInService.swift
//  EscapeOS 侧的胶水层：把本地 SAP 登录接回账号库与下载中心。
//
//  流程：UI（邮箱/密码/验证码）→ SignedStoreAuthenticator（本地 SAP 签名）
//        → AppStoreDownloadStore.add(account)（成为当前下载账号）
//        → IPADownloadCenter.startWithAppleID(item:email:) 真正下载安装。
//
import Foundation

enum AppleIDSignInService {

    /// 12 位十六进制设备标识 —— **登录与下载必须用同一个**（Apple 用它关联设备/SAP 硬件 ID）。
    ///
    /// `AppStoreDownloadStore` 里已有的 `Configuration.deviceIdentifier` 是持久化的随机标识，
    /// 这里把它规整成 12 位 hex（SAP 需要 6 字节硬件 ID）。
    static func sapGUID() -> String {
        let raw = Configuration.deviceIdentifier.lowercased()
        let hex = raw.filter { $0.isHexDigit }
        if hex.count >= 12 { return String(hex.prefix(12)) }
        // 不足 12 位则补足（并写回，保证持久一致）
        var padded = hex
        while padded.count < 12 { padded.append("0") }
        return String(padded.prefix(12))
    }

    /// 登录并保存账号。抛错时若 `StoreAuthenticationError.needsCode` 为真，UI 应提示输入验证码。
    @discardableResult
    static func signIn(email: String,
                       password: String,
                       code: String = "",
                       log: ((String) -> Void)? = nil) async throws -> AppStoreAccount {
        let guid = sapGUID()
        log?("开始登录（guid \(guid.prefix(4))…）")
        let account = try await SignedStoreAuthenticator().authenticate(
            email: email, password: password, code: code, guid: guid, cookies: [])
        await MainActor.run {
            AppStoreDownloadStore.shared.add(account)
        }
        logRegion(account, log: log)
        log?("登录成功并已设为当前下载账号")
        return account
    }

    /// 账号轮换：用已存账号的 cookie 重新认证，延长令牌寿命（免验证码）
    /// - Parameter code: 双重认证验证码（Apple 要求时传入；首次可留空）
    @discardableResult
    static func rotate(email: String, code: String = "") async throws -> AppStoreAccount {
        guard let stored = AppStoreDownloadStore.shared.account(for: email) else {
            throw StoreAuthenticationError.invalidConfiguration
        }
        let account = try await SignedStoreAuthenticator().authenticate(
            email: stored.email, password: stored.password, code: code,
            guid: sapGUID(), cookies: stored.cookie)
        await MainActor.run {
            AppStoreDownloadStore.shared.add(account)
        }
        logRegion(account, log: nil)
        return account
    }

    /// 登录后把商店区域对齐到账号所在区（浏览到的商品才会是账号真能下的）
    private static func logRegion(_ account: AppStoreAccount, log: ((String) -> Void)?) {
        if let region = AppStoreService.adoptAccountRegion(storefront: account.store, email: account.email) {
            log?("账号区域 \(region.uppercased())（storefront \(account.store)），商店已跟随")
            LoginLogger.shared.log("[SAP] 账号区域 \(region.uppercased())（storefront \(account.store)）",
                                   category: .appStore)
        } else {
            log?("账号 storefront \(account.store) 未能反查区域，商店保持 \(AppStoreService.countryCode.uppercased())")
        }
    }

    /// SAP 资产是否就位（缺失时登录必然失败，UI 应给出明确提示）
    static var assetsReady: Bool {
        guard let url = SAPAssetsLocator.url else { return false }
        let names = ["CommerceKit", "CommerceCore", "CoreFP", "CoreFP.icxs"]
        return names.allSatisfy {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }
}
