import Foundation

/// v0.3.364：第三方应用类型识别（应用板块 · 胶囊标签）——**对齐爱思 9.0 口径**.
///
/// **逆向依据**（v0.3.364 只读逆向，见 i4-class 报告）：
///   - 爱思 PC 9.0（`C:\Program Files\i4Tools9\i4Tools.exe`）的标签集只有 6 类：
///     **苹果正版 / 共享正版 / 个人签名 / 企业签名 / 越狱版 / 其他版本**
///     （字面量在 RVA 0x1451660、0x140dc88、0x1465e40）。它**没有**「AppStore」
///     这一类，也没有「系统」这一类。
///   - 企业签名 = `.mobileprovision` 文本命中 `ProvisionsAllDevices</key>*<true/>`
///     （字面量 0x1512890，分类函数引用点 RVA 0xfa7357 / 0xfa8a36）。
///   - 个人签名 = 有 profile 且命中 `TeamName</key>*<string>` / `DeveloperCertificates`
///     （0x1512ab8 / 0x1512ae8）。
///   - 越狱版 = 无 profile、无 `iTunesMetadata.plist`、无 FairPlay 加密
///     （`.app/SC_Info/`、`.sinf`、`.supp`，0x1512900~0x1512920）。
///   - **正版 vs 共享 = App 自身 `iTunesMetadata` 的购买邮箱是否属于爱思的共享账号
///     白名单**（`share_appleid@163.com`、`share_appleid001~006@163.com`）。
///   - **爱思不比当前登录 Apple ID，也不看 `ApplicationDSID`**：`idm_app.dll`
///     0x17a00 的 ReturnAttributes 里只有 `ApplicationType` / `SignerIdentity` /
///     `UIFileSharingEnabled` / `StaticDiskUsage` / `DynamicDiskUsage` /
///     `IsHiddenSystemApp` 等，没有这两项。
///
/// **旧口径（v0.3.187~363，已废弃）**：拿 `iTunesMetadata.apple-id` 与**本机当前
/// Apple ID**比较，不同即「共享」。本机 ID 取自我们自己的 keychain 登录态
/// （`MemoryLimitSettings.currentAppleIDDirect()`），未登录 / 换号 / 家人共享时
/// 必然判错 —— 这正是用户反馈「共享正版、正版应用分不清」的根因。
///
/// **判定优先级（v0.3.364）**：
///   1. `HiddenSystemApp` → .hidden（界面归入「系统」）
///   2. 非 `User` → .unknown（界面归入「系统」）
///   3. `ProvisionsAllDevices == true` → .enterprise（企业唯一权威字段，Apple TN3125）
///   4. 有 entitlements（即侧载 profile，且非企业）→ .development
///      （个人 Apple ID 自签 / Xcode 调试 / Ad-Hoc / 团队 Distribution）
///   5. 有 `iTunesMetadata`（含只拿到购买邮箱的情况）→ 邮箱 ∈ 共享白名单则
///      .appStoreShared，否则 .appStorePersonal
///   6. 无 `iTunesMetadata` 且无 FairPlay 加密 → .jailbroken（爱思的「越狱版」）
///
/// `.appStore` 只剩「兜底」语义（加密包但拿不到元数据），界面文案与
/// .appStorePersonal 相同（「苹果正版」）——**界面上不再出现「AppStore」**。
enum AppType: String, Hashable {
    case appStorePersonal   = "正版"
    case appStoreShared     = "共享"
    case appStore           = "AppStore"
    case development        = "个人签名"
    case enterprise         = "企业签名"
    case jailbroken         = "越狱版"
    case hidden             = "隐藏"
    case unknown            = "未知"

    /// 界面文案（v0.3.364：`rawValue` 保持历史值不动，只在显示层对齐爱思 ——
    /// `.appStore` 兜底不再显示「AppStore」，改为与苹果正版同文案）.
    var displayName: String {
        switch self {
        case .appStorePersonal: return "苹果正版"
        case .appStoreShared:   return "共享正版"
        case .appStore:         return "苹果正版"
        case .development:      return "个人签名"
        case .enterprise:       return "企业签名"
        case .jailbroken:       return "越狱版"
        case .hidden:           return "隐藏"
        case .unknown:          return "未识别"
        }
    }

    /// 一行补充说明（界面文案精简，不写解释性长句）.
    var subtitle: String {
        switch self {
        case .appStorePersonal: return "本人 Apple ID 下载"
        case .appStoreShared:   return "共享账号下载"
        case .appStore:         return "App Store 下载"
        case .development:      return "自签 / 调试 / Ad-Hoc"
        case .enterprise:       return "企业签名（不限设备）"
        case .jailbroken:       return "破解 / 越狱包"
        case .hidden:           return "系统隐藏应用"
        case .unknown:          return "来源未识别"
        }
    }
}

/// 应用类型检测器.
enum AppTypeDetector {
    /// 爱思「共享正版」共享账号白名单（比对时大小写不敏感）.
    ///
    /// **来源**（只读逆向，勿凭空改）：
    ///   - `C:\Program Files\i4Tools9\i4Tools.exe` .rdata 0x15127b8~0x1512878，
    ///     7 个邮箱字面量连续存放，与 `embedded.mobileprovision` /
    ///     `iTunesMetadata.plist` / `/SC_Info/` / `.sinf` 等一起被同一个
    ///     「包分类」函数引用；
    ///   - 爱思自带包 `files\ipa\photo.ipa` 的 `iTunesMetadata.plist`：
    ///     `appleId` 与 `com.apple.iTunesStore.downloadInfo.accountInfo.AppleID`
    ///     同为 `share_appleid003@163.com`（与用户截图里的邮箱一致）。
    ///
    /// 维护：爱思更换共享账号时同步本表.
    static let sharedAccountWhitelist: Set<String> = [
        "share_appleid@163.com",
        "share_appleid001@163.com",
        "share_appleid002@163.com",
        "share_appleid003@163.com",
        "share_appleid004@163.com",
        "share_appleid005@163.com",
        "share_appleid006@163.com",
    ]

    /// 购买邮箱是否属于爱思共享账号白名单（大小写不敏感）.
    static func isSharedAccount(_ appleId: String) -> Bool {
        let normalized = appleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return sharedAccountWhitelist.contains(normalized)
    }

    /// 综合判定应用类型.
    ///
    /// - `provisionsAllDevices`：misagent 拉的 .mobileprovision 顶层字段
    ///   （企业判定唯一权威，Apple TN3125）.
    /// - `hasITunesMetadata`：instproxy 是否真的返回了 `iTunesMetadata`
    ///   （**存在性**判断；iOS 27 上它是 bplist 字节，解析失败也仍算「有」）.
    /// - `isFairPlayEncrypted`：包内是否有 FairPlay 加密（`SC_Info/*.sinf`）。
    ///   `nil` = 未知（已装应用读不到包内文件，iOS 侧 AFC 只到媒体域；
    ///   只有本地 IPA 场景能由 `IPAPackageInspector` 给出确定值）。
    /// - `currentAppleID`：**仅保留形参做兼容，不再参与判定**
    ///   （爱思口径不看本机登录账号，见文件头）.
    static func detect(
        entitlements: [String: Any],
        applicationType: String?,
        iTunesAppleID: String?,
        currentAppleID: String? = nil,
        provisionsAllDevices: Bool = false,
        hasITunesMetadata: Bool = false,
        isFairPlayEncrypted: Bool? = nil
    ) -> AppType {
        // 1. 隐藏应用（基于 installation_proxy 的 ApplicationType）
        if applicationType == "HiddenSystemApp" { return .hidden }
        guard applicationType == "User" else { return .unknown }

        // 2. **企业权威判定**：.mobileprovision 顶层 ProvisionsAllDevices == true
        if provisionsAllDevices {
            return .enterprise
        }

        // 3. 有 entitlements（即有 profile 但非企业）→ 自签 / 调试 / Ad-Hoc / 团队签
        if !entitlements.isEmpty {
            return .development
        }

        // 4. App Store 系：只看 **App 自身购买邮箱** 是否在爱思共享账号白名单里
        let boughtBy = iTunesAppleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasITunesMetadata || !(boughtBy ?? "").isEmpty {
            if let boughtBy, isSharedAccount(boughtBy) { return .appStoreShared }
            return .appStorePersonal
        }

        // 5. 无 profile、无 iTunesMetadata → 不是 App Store 下发的包。
        //    仍带 FairPlay 加密时按 App Store 加密包兜底；否则是破解 / 越狱包。
        if isFairPlayEncrypted == true { return .appStore }
        return .jailbroken
    }
}
