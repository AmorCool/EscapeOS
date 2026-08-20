import Foundation

/// Uninstalls user-installed apps via the private `MobileInstallation`
/// framework. Function pointers are resolved through `dlopen` / `dlsym`
/// at runtime so we don't need a private SDK to compile.
///
/// `MobileInstallationUninstall` is a privileged call — it goes through
/// `installd` over XPC. EscapeOS writes the imported pairing file to
/// `misagent`'s trust cache on import, so `installd` accepts these calls
/// without re-prompting. iOS may still surface a system "Delete App"
/// confirmation alert — that's intentional, and we treat it as success.
///
/// We deliberately do *not* allow uninstalling system apps — only
/// `ApplicationType == "User"`. The caller (`AppListViewModel`) rejects
/// anything else before invoking `uninstall`.
enum UninstallServiceError: LocalizedError {
    case dylibMissing(String)
    case symbolMissing(String)
    case callFailed(String)

    var errorDescription: String? {
        switch self {
        case .dylibMissing(let p):
            return "无法加载 MobileInstallation：\(p)"
        case .symbolMissing(let s):
            return "MobileInstallation 符号缺失：\(s)"
        case .callFailed(let m):
            return "卸载失败：\(m)"
        }
    }
}

final class UninstallService {
    static let shared = UninstallService()

    /// Resolved function pointer for `MobileInstallationUninstall`:
    /// `int MobileInstallationUninstall(const char *bundleIdentifier)`.
    private typealias MIUninstallFn = @convention(c) (UnsafePointer<CChar>) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var uninstall: MIUninstallFn?
    private let lock = NSLock()

    private init() {}

    private func bootstrap() throws {
        lock.lock()
        defer { lock.unlock() }
        if uninstall != nil { return }
        guard let lib = dlopen("/usr/lib/libmis.dylib", RTLD_NOW | RTLD_LOCAL) else {
            let err = dlerror().map { String(cString: $0) } ?? "未知错误"
            throw UninstallServiceError.dylibMissing(err)
        }
        handle = lib
        guard let sym = dlsym(lib, "MobileInstallationUninstall") else {
            throw UninstallServiceError.symbolMissing("MobileInstallationUninstall")
        }
        uninstall = unsafeBitCast(sym, to: MIUninstallFn.self)
    }

    /// Uninstall a User-installed app by bundle id.
    /// Throws `UninstallServiceError.callFailed` if `installd` returns
    /// a non-zero status — the error description already localises the
    /// common cases (-1 permission, -100 not found, -103 locked).
    func uninstall(bundleId: String) throws {
        try bootstrap()
        let tag = NSString(string: "EscapeOS-uninstall-\(UUID().uuidString)")
        defer { _ = tag }
        let status = uninstall!(tag.utf8String!)
        try check(status)
    }

    /// Translate a `MobileInstallation` status code to an error.
    private func check(_ status: Int32) throws {
        switch status {
        case 0: return
        case -1:
            throw UninstallServiceError.callFailed("权限被拒绝或签名无效。请确认配对文件仍受信任后重试。")
        case -100:
            throw UninstallServiceError.callFailed("找不到指定的应用（bundle id 可能错误，或此版本 iOS 禁止删除此应用）。")
        case -103:
            throw UninstallServiceError.callFailed("iOS 不接受此命令。请先解锁设备，然后重新导入配对文件。")
        default:
            throw UninstallServiceError.callFailed("未知错误（MobileInstallationUninstall 返回 \(status)）")
        }
    }
}
