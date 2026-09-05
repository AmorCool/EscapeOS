import Foundation

/// v0.3.187：第三方应用类型识别（应用板块 · 胶囊标签），细分到「正版 vs 共享 vs 企业」。
///
/// **权威字段来源**（Apple TN3125 + libimobiledevice 协议）：
///   1) misagent 拉的 .mobileprovision 顶层 `ProvisionsAllDevices`
///      —— true 即企业 / In-House profile（**唯一可靠的企业判定**）
///   2) installation_proxy 返回的 `ApplicationType` 字段
///      —— User / System / HiddenSystemApp
///   3) installation_proxy 返回的 `iTunesMetadata.apple-id`（App Store 下载的 App）
///   4) 当前 Apple ID（来自 MemoryLimitSettings.appleID / keychain）
///
/// **v0.3.187 之前的两个错误启发式**（已废弃）：
///   - `entitlements.com.apple.developer.enterprise.*` 前缀 → Apple 文档（TN3125）
///     明确**没有这种标准 entitlement**；企业标志只在 mobileprovision 顶层
///     `ProvisionsAllDevices=true`。v0.3.184~186 用此启发式 → iOS 14+ 几乎不命中，
///     所有企业应用被合并到「开发」（被吐槽"全改成开发"的根因）。
///   - `entitlements.get-task-allow == true` → development → **错**。get-task-allow
///     也出现在企业 profile（企业 App 同样允许调试器 attach）和个人 Apple ID 自签
///     （free provisioning 也带）。不能作为类型判定依据。
///
/// **判定优先级**（v0.3.187 起）：
///   - HiddenSystemApp → .hidden
///   - 非 User → .unknown
///   - ProvisionsAllDevices == true → .enterprise（**唯一权威**）
///   - 有 entitlements（即有 profile 但非企业）→ .development
///     （开发调试 / 个人 Apple ID 自签 / Ad-Hoc / 团队 Distribution 合并）
///   - 无 entitlements + iTunesAppleID == currentAppleID → .appStorePersonal
///   - 无 entitlements + iTunesAppleID != currentAppleID → .appStoreShared
///   - 无 entitlements + 无 iTunesMetadata → .appStore（兜底）
enum AppType: String, Hashable {
    case appStorePersonal   = "正版"
    case appStoreShared     = "共享"
    case appStore           = "AppStore"
    case development        = "个人签名"
    case enterprise         = "企业签名"
    case hidden             = "隐藏"
    case unknown            = "未知"

    var subtitle: String {
        switch self {
        case .appStorePersonal: return "App Store 本人购买/下载"
        case .appStoreShared:   return "App Store 家人共享（购买者非本人 Apple ID）"
        case .appStore:         return "App Store（无法判别正版/共享）"
        case .development:      return "个人 Apple ID 自签 / Xcode 调试 / Ad-Hoc / 团队签"
        case .enterprise:       return "企业内部/批量签发（不限设备）"
        case .hidden:           return "系统隐藏应用"
        case .unknown:          return "签名来源未知"
        }
    }
}

/// 应用类型检测器。
enum AppTypeDetector {
    /// 综合判定应用类型。
    ///
    /// `provisionsAllDevices` 来自 misagent 拉的 .mobileprovision 顶层字段
    /// （**企业判定唯一权威字段**，Apple TN3125）.
    static func detect(
        entitlements: [String: Any],
        applicationType: String?,
        iTunesAppleID: String?,
        currentAppleID: String?,
        provisionsAllDevices: Bool = false
    ) -> AppType {
        // 1. 隐藏应用（基于 installation_proxy 的 ApplicationType）
        if applicationType == "HiddenSystemApp" { return .hidden }
        guard applicationType == "User" else { return .unknown }

        // 2. **企业权威判定**：.mobileprovision 顶层 ProvisionsAllDevices == true
        //    （这是 Apple 文档（TN3125）明确的企业标志；entitlements 内无对应键）
        if provisionsAllDevices {
            return .enterprise
        }

        // 3. 有 entitlements（即有 profile 但非企业）→ 开发/自签大类.
        //    不再用 get-task-allow 区分（企业 profile 也带 get-task-allow；
        //    个人 Apple ID 自签也带）。按用户规则把"开发 / 自签 / Ad-Hoc /
        //    团队 Distribution"合并入 .development.
        if !entitlements.isEmpty {
            return .development
        }

        // 4. 无 entitlements → AppStore 系（系统签发）.
        //    用 iTunesMetadata.apple-id 区分正版 vs 共享.
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