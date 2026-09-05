import Foundation
import UIKit

/// A single installed application discoverable on-device. Covers both
/// user-installed (App Store / sideloaded) apps and system apps.
struct InstalledApp: Identifiable, Hashable {
    let id = UUID()
    let bundleIdentifier: String
    let name: String
    let containerPath: String
    let version: String?
    /// `ApplicationType` from installation_proxy: "User", "System",
    /// "HiddenSystemApp", or nil. Used by the app list to split 全部 / 系统 / 三方.
    let applicationType: String?
    /// v0.3.184：iTunesMetadata.apple-id（installation_proxy 返回的子字典）。
    /// 仅 App Store 下载的 App 存在此字段；用于区分「本人购买」与「家人共享」.
    /// nil 表示该 app 没有 iTunesMetadata（侧载/重签/系统应用）.
    /// 带默认值 nil：避免破坏其它 Memberwise init 调用点（LiveContainerDiscovery/
    /// SupervisedHelpers/RestoreService 等不关注此字段）.
    var iTunesAppleID: String? = nil
    /// v0.3.194：iTunesMetadata 内 com.apple.iTunesStore.downloadInfo.accountInfo 关键字段
    /// （从 Browse+ReturnAttributes 全量元数据解析，仅 User+AppStore 应用有值）。
    /// 用于「正版 vs 家人共享」判定（见 AppTypeDetector）.
    var purchaserDSID: String? = nil   // accountInfo.PurchaserID（真实购买者）
    var downloaderDSID: String? = nil  // accountInfo.DSPersonID（下载者）
    var familyID: String? = nil        // accountInfo.FamilyID（家庭 ID，>0 表示经家人共享下载）
    var accountAppleID: String? = nil  // accountInfo.AppleID（购买者邮箱，方便展示）

    /// Whether this is a system/firmware app rather than a user-installed one.
    var isSystem: Bool {
        guard let t = applicationType else { return false }
        return t == "System" || t == "HiddenSystemApp"
    }
}

/// Errors surfaced by tunnel-based app discovery.
enum AppDiscoveryError: LocalizedError {
    case noPairingFile
    case heartbeatFailed(String)
    case enumerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPairingFile:
            return "尚未导入配对文件。需要配对文件才能列出设备上的应用。"
        case .heartbeatFailed(let m):
            return "无法连接本地隧道：\(m)。请将 LocalDevVPN 的设备 IP / 隧道 IP 保持默认（10.7.0.1），保持 Wi-Fi 连接，并使用 iPASide 生成的配对文件。"
        case .enumerationFailed(let m):
            return "枚举应用失败：\(m)"
        }
    }
}

/// Discovers installed apps on-device via LocalDevVPN + a pairing file.
/// iOS 26.4+ uses RPPairing/RSD; iOS 18 falls back to lockdown over the same VPN.
final class AppDiscovery {

    private let tunnel = TunnelContext.shared

    /// Whether a pairing file has been imported.
    var hasPairingFile: Bool { tunnel.hasPairingFile }

    /// Establish the tunnel and enumerate installed apps.
    /// - Throws: `AppDiscoveryError` when pairing/heartbeat/enumeration fails.
    func fetchInstalledApps() throws -> [InstalledApp] {
        guard tunnel.hasPairingFile else {
            throw AppDiscoveryError.noPairingFile
        }

        do {
            try tunnel.ensureHeartbeat()
        } catch {
            throw AppDiscoveryError.heartbeatFailed(error.localizedDescription)
        }

        let all: [String: [AnyHashable: Any]]
        do {
            // v0.3.194：优先走 Browse + ReturnAttributes 全量元数据（含 iTunesMetadata/
            // ApplicationDSID，UFADE 路线）。失败则回退普通 Lookup（老逻辑）——
            // 绝不能因元数据通道失败导致应用列表整体不可用.
            if let metaApps = try? tunnel.getAllAppsInfoWithMetadata() {
                all = metaApps
            } else {
                all = try tunnel.getAllAppsInfo()
            }
        } catch {
            throw AppDiscoveryError.enumerationFailed(error.localizedDescription)
        }

        var apps: [InstalledApp] = []
        for (bundleId, infoRaw) in all {
            let info = infoRaw.reduce(into: [String: Any]()) { $0[$1.key.base as? String ?? ""] = $1.value }
            // Return every application type. The underlying instproxy query uses
            // `application_type = NULL` ("Any"), so system apps are already in
            // the payload — the app list UI splits them into 全部 / 系统 / 三方
            // tabs instead of dropping them here.
            let appType = info["ApplicationType"] as? String
            // Resolve display name.
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bundleId
            // Container path (Data container). System apps may not expose one;
            // we keep them in the list (read-only) instead of dropping them.
            let container = (info["Container"] as? String) ?? ""
            let version = info["CFBundleShortVersionString"] as? String
            // v0.3.184：iTunesMetadata 子字典（仅 App Store 下载的应用有）.
            // 用于在 AppTypeDetector 区分「本人购买」与「家人共享」.
            let (iTunesAppleID, purchaserDSID, downloaderDSID, familyID, accountAppleID) = Self.parseITunesMetadata(info)
            apps.append(InstalledApp(
                bundleIdentifier: bundleId,
                name: name,
                containerPath: container,
                version: version,
                applicationType: appType,
                iTunesAppleID: iTunesAppleID,
                purchaserDSID: purchaserDSID,
                downloaderDSID: downloaderDSID,
                familyID: familyID,
                accountAppleID: accountAppleID
            ))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// v0.3.194：从 app info dict 解析 iTunesMetadata 的购买者/下载者字段。
    /// iTunesMetadata 可能以 [String:Any] 子字典出现（plist 转换后），
    /// 也可能以 Data（二进制 plist）出现——两种都处理。
    /// 字段层级：iTunesMetadata.com.apple.iTunesStore.downloadInfo.accountInfo
    ///   .PurchaserID / .DSPersonID / .FamilyID / .AppleID
    private static func parseITunesMetadata(_ info: [String: Any])
        -> (iTunesAppleID: String?, purchaser: String?, downloader: String?, family: String?, account: String?) {
        guard let metaRaw = info["iTunesMetadata"] else { return (nil, nil, nil, nil, nil) }
        let meta: [String: Any]
        if let dict = metaRaw as? [String: Any] {
            meta = dict
        } else if let data = metaRaw as? Data,
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any] {
            meta = dict
        } else {
            return (nil, nil, nil, nil, nil)
        }
        // 顶层 apple-id（下载票据账号，兜底）
        let topAppleID = meta["apple-id"] as? String
        // downloadInfo.accountInfo
        let accountInfo = (meta["com.apple.iTunesStore.downloadInfo"] as? [String: Any])?["accountInfo"] as? [String: Any]
        let purchaser = accountInfo?["PurchaserID"] as? String
        let downloader = accountInfo?["DSPersonID"] as? String
        let family = accountInfo?["FamilyID"] as? String
        let account = accountInfo?["AppleID"] as? String
        return (topAppleID, purchaser, downloader, family, account)
    }

    /// Fetch the SpringBoard icon for an app, if the tunnel is up.
    func appIcon(for bundleId: String) -> UIImage? {
        try? tunnel.getAppIcon(withBundleId: bundleId)
    }

    /// Import a pairing file (contents of a .mobiledevicepairing plist).
    func importPairingFile(_ contents: String) throws {
        try tunnel.savePairingFile(contents)
    }

    /// Remove the stored pairing file.
    func resetPairing() {
        tunnel.resetPairingFile()
    }

    /// Whether the user has granted single-app install permissions via the
    /// pairing file. MobileInstallation refuses install/uninstall calls when
    /// this isn't in effect — even iOS-style "Delete App" dialogs go through
    /// it. Used by the multi-select uninstall UI.
    func canUninstallApps() -> Bool {
        return tunnel.hasPairingFile
    }
}

/// Marker extension so `AppListViewModel` can add app-removal operations
/// without bloating `AppDiscovery` further.
extension InstalledApp {
    /// Whether this is a user / sideloaded app (rather than a system framework).
    var isUserApp: Bool { !isSystem }
}
