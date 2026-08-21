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
            all = try tunnel.getAllAppsInfo()
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
            apps.append(InstalledApp(
                bundleIdentifier: bundleId,
                name: name,
                containerPath: container,
                version: version,
                applicationType: appType
            ))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
