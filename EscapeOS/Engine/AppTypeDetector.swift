import Foundation

/// v0.3.184：第三方应用类型识别（应用板块 · 胶囊标签），细分到「正版 vs 共享」。
///
/// 数据来源（仅运行时可获取，不读跨 app bundle）：
///  1) misagent 拉的 provisioning profile entitlements
///     （来自 ProvisioningProfileStore.fetchSideloadedApps）——企业/开发判定
///  2) installation_proxy 返回的 ApplicationType 字段 —— User / System / HiddenSystemApp
///  3) installation_proxy 返回的 iTunesMetadata.apple-id 字段（App Store 下载的 App）
///  4) 当前 Apple ID（来自 MemoryLimitSettings.appleID，由用户在 AppStore 登录态提供）
///
/// 判定优先级：
///   - HiddenSystemApp → .hidden（隐藏应用，App Store 不可见）
///   - User + entitlements.com.apple.developer.enterprise.* → .enterprise
///   - User + entitlements.get-task-allow == true → .development
///   - User + 有 entitlements（非企业非开发）→ .development（团队/Ad-Hoc 个人签）
///   - User + 无 entitlements + iTunesAppleID == currentAppleID → .appStorePersonal
///   - User + 无 entitlements + iTunesAppleID != currentAppleID → .appStoreShared
///   - User + 无 entitlements + 无 iTunesMetadata → .appStore（无法判定，统称 AppStore）
enum AppType: String, Hashable {
    case appStorePersonal   = "正版"
    case appStoreShared     = "共享"
    case appStore           = "AppStore"
    case development        = "开发"
    case enterprise         = "企业签名"
    case hidden             = "隐藏"
    case unknown            = "未知"

    var subtitle: String {
        switch self {
        case .appStorePersonal: return "App Store 本人购买/下载"
        case .appStoreShared:   return "App Store 家人共享（购买者非本人 Apple ID）"
        case .appStore:         return "App Store（无法判别正版/共享）"
        case .development:      return "Xcode 调试或证书直装"
        case .enterprise:       return "企业内部/批量签发（不限设备）"
        case .hidden:           return "系统隐藏应用"
        case .unknown:          return "签名来源未知"
        }
    }
}

/// 应用类型检测器：纯运行时启发式（不依赖 pymobiledevice3）。
///
/// `entitlements` 来自 misagent ProfileInfo；`applicationType` 来自 installation_proxy；
/// `iTunesAppleID` 来自 iTunesMetadata.apple-id（installation_proxy 返回）；`currentAppleID`
/// 来自 MemoryLimitSettings.appleID。
enum AppTypeDetector {
    /// 综合判定应用类型。
    /// 任意输入为 nil 时降级到下一档，最后兜底 .unknown（仅 system 类应用可能落到这）。
    static func detect(
        entitlements: [String: Any],
        applicationType: String?,
        iTunesAppleID: String?,
        currentAppleID: String?
    ) -> AppType {
        // 1. 隐藏应用优先（基于 installation_proxy 的 ApplicationType）
        if applicationType == "HiddenSystemApp" { return .hidden }

        // 2. 非 User 类型兜底为 .unknown
        guard applicationType == "User" else { return .unknown }

        // 3. 有 entitlements：企业 / 开发 / Ad-Hoc 优先
        if !entitlements.isEmpty {
            // 任意 enterprise 专属 entitlement 命中 → 企业签名
            for key in entitlements.keys where key.hasPrefix("com.apple.developer.enterprise") {
                return .enterprise
            }
            // get-task-allow=true（Xcode Debug/个人开发者）→ Development
            if let gta = entitlements["get-task-allow"], (gta as? Bool) == true {
                return .development
            }
            // 其它有 entitlements 但无 enterprise / get-task-allow 标识
            // → 团队/Ad-hoc 个人签。归为 development（语义上同属「非 AppStore 签发」）.
            return .development
        }

        // 4. 无 entitlements → AppStore 系（system-signed）
        // 用 iTunesMetadata.apple-id 区分正版 vs 共享
        if let iTunesId = iTunesAppleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !iTunesId.isEmpty,
           let currentId = currentAppleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !currentId.isEmpty {
            return iTunesId.lowercased() == currentId ? .appStorePersonal : .appStoreShared
        }

        // 5. 拿不到 iTunesMetadata 或当前 Apple ID → 统称 AppStore
        return .appStore
    }
}
