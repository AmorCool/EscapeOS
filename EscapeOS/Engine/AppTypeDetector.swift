import Foundation

/// v0.3.181：第三方应用类型识别（应用板块 · 胶囊标签）。
/// 仅基于设备运行时已可获取的来源：
///   1) misagent 拉的 provisioning profile entitlements（来自 ProvisioningProfileStore.fetchSideloadedApps）
///   2) LSApplicationProxy 私有属性 signerIdentity / signatureSigner（KVC）
/// 不读取跨 app bundle 文件（沙盒限制）。启发式判定：
///   - 无 entitlements 来自 misagent → App Store（系统签发，无第三方 profile）
///   - entitlements.get-task-allow == true → Development（Xcode Debug / 个人开发证书）
///   - entitlements 包含 com.apple.developer.enterprise.* 系列 → Enterprise（企业/内部分发）
///   - 其他有 entitlements（团队/个人 Ad-hoc/分发）→ Ad-Hoc
enum AppType: String, Hashable {
    case appStore      = "App Store"
    case development   = "开发"
    case enterprise    = "企业签名"
    case adHoc         = "Ad-Hoc"
    case unknown       = "未知"

    var subtitle: String {
        switch self {
        case .appStore:    return "App Store 官方签发"
        case .development: return "开发者调试或上架前签名"
        case .enterprise:  return "企业内部/批量签发（不限设备）"
        case .adHoc:       return "团队或个人证书分发"
        case .unknown:     return "签名来源未知"
        }
    }
}

/// 应用类型检测器：纯 entitlements 启发式 + KVC 探测（不依赖 pymobiledevice3）。
enum AppTypeDetector {
    /// 通过 entitlements 判定。
    /// `entitlements`: ProvisioningProfileStore.fetchSideloadedApps() 里的 entitlements dict
    ///                 （若该 app 不在 misagent 列表里，传入空字典，判定为 .appStore）
    static func detect(entitlements: [String: Any]) -> AppType {
        if entitlements.isEmpty {
            return .appStore
        }
        // get-task-allow=true（Xcode Debug/个人开发者）→ Development
        if let gta = entitlements["get-task-allow"], (gta as? Bool) == true {
            return .development
        }
        // 任意 enterprise 专属 entitlement 命中 → 企业签名
        for key in entitlements.keys {
            if key.hasPrefix("com.apple.developer.enterprise") {
                return .enterprise
            }
        }
        // 其它有 entitlements 但无 enterprise 标识 → 团队/Ad-hoc 签名
        return .adHoc
    }
}