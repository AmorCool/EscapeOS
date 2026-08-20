import Foundation

/// Uninstalls user-installed apps by routing the request through the
/// pairing-file + LocalDevVPN tunnel — the **same authenticated channel the
/// app list uses** — instead of calling `MobileInstallationUninstall` in
/// process.
///
/// Why not `libmis` / `MobileInstallationUninstall`?
/// That call is rejected on iOS 18/26 because `installd` (which it routes
/// through over XPC) checks the caller's entitlement. EscapeOS only carries
/// `get-task-allow` — NOT
/// `com.apple.private.mobileinstallation.allow-uninstall` — so the in-process
/// call returns -1 ("权限被拒绝"). On iOS 26.5 the operation must instead be
/// authenticated via the trusted pairing file over the LocalDevVPN tunnel.
///
/// The fix below delegates to `TunnelContext.uninstallAppWithBundleId:` which
/// opens an `InstallationProxyClient` over the RPPairing (iOS 26.4+) or
/// lockdown (iOS 18) tunnel and calls `installation_proxy_uninstall`. The
/// pairing-file trust makes `installd` accept it without the in-process
/// entitlement. iOS may still surface a system "Delete App" confirmation
/// alert — that's intentional and treated as success.
///
/// We only ever target `ApplicationType == "User"` apps; the caller
/// (`AppListViewModel`) rejects anything else before invoking `uninstall`.
enum UninstallServiceError: LocalizedError {
    case notConfigured
    case tunnelFailed(String)
    case callFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未导入配对文件。请先在「设置」导入配对文件并开启 LocalDevVPN，再卸载应用。"
        case .tunnelFailed(let m):
            return "连接本地隧道失败：\(m)"
        case .callFailed(let m):
            return "卸载失败：\(m)"
        }
    }
}

final class UninstallService {
    static let shared = UninstallService()

    /// The pairing-file + LocalDevVPN tunnel that authenticates the uninstall.
    private let tunnel = TunnelContext.shared

    private init() {}

    /// Uninstall a User-installed app by bundle id, routed through the tunnel.
    /// - Throws: `UninstallServiceError` when no pairing file is present or
    ///   `installd` reports a failure (surfaced as `callFailed`).
    func uninstall(bundleId: String) throws {
        guard tunnel.hasPairingFile else {
            throw UninstallServiceError.notConfigured
        }
        var err: NSError?
        let ok = tunnel.uninstallApp(withBundleId: bundleId, error: &err)
        if !ok {
            if let e = err {
                throw UninstallServiceError.callFailed(e.localizedDescription)
            }
            throw UninstallServiceError.callFailed("未知错误（隧道未返回详细信息）。")
        }
    }
}
