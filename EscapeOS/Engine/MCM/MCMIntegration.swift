//
//  MCMIntegration.swift
//  EscapeOS (MHA branch)
//
//  Swift wrapper over the MCM bridge (BQMCMIntegration). Provides a
//  type-safe entry point for the App/container browsers to request MHA
//  container access. On non-MHA builds BQMCMIsMobileHouseArrest() is false
//  and every call returns nil with a descriptive error, so the rest of the
//  app can degrade gracefully (it already does via the bad_query route).
//

import Foundation

enum MCMError: Error, LocalizedError {
    case notMHA
    case bridgeUnavailable
    case invalidIdentifier
    case activationFailed(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .notMHA:
            return "本进程未以 MobileHouseArrest 身份运行（MHA 分支未生效）。"
        case .bridgeUnavailable:
            return "Containermanager 符号解析失败，当前 iOS 版本不支持。"
        case .invalidIdentifier:
            return "容器标识符非法（含不允许的字符）。"
        case .activationFailed(let detail):
            return "容器激活失败：\(detail)"
        case .unknown:
            return "未知的 MCM 错误。"
        }
    }
}

/// Container class table (subset of MCM classes used by EscapeOS).
enum MCMContainerClass: UInt64 {
    case appData       = 2   // 三方/系统 App 数据容器
    case extensionData = 4   // App Extension 数据
    case appGroup      = 7   // App Group 共享容器
    case serviceData   = 10  // 系统服务（如 com.apple.lsd）
    case systemData    = 12  // 系统数据
    case systemGroup   = 13  // systemgroup（MobileGestalt 缓存等）
    case protectedData = 15  // 受保护数据
}

struct MCMIntegration {

    /// True iff the running process presents the MHA signed-code identifier.
    /// containermanagerd checks SecTaskCopySigningIdentifier, NOT the bundle id.
    static var isMobileHouseArrest: Bool {
        BQMCMIsMobileHouseArrest()
    }

    /// The actual signed-code identifier of the running process, as reported by
    /// SecTaskCopySigningIdentifier. Use this to confirm on-device whether the
    /// MHA identity survived LiveContainer's re-signing.
    static var signedCodeIdentifier: String {
        BQMCMSignedCodeIdentifierString()
    }

    /// True iff the low-level containermanager symbols were resolved.
    static var bridgeAvailable: Bool {
        BQMCMBridgeAvailable()
    }

    /// Configure the iOS 26 App Group "sacrifice" route. Must be called once
    /// at launch with the App Group registered to EscapeOS's signing identity.
    static func configure(appGroup: String) {
        BQMCMSetAppGroupIdentifier(appGroup)
    }

    /// Auto-detect the host process's App Group(s) from its entitlements and
    /// use the first for the iOS 26 sacrifice route. Inside LiveContainer this
    /// borrows the host's App Group (the contained app runs as the LC process).
    static func detectHostAppGroup() {
        BQMCMDetectHostAppGroup()
    }

    /// Activate (and cache) the container root for a bundle/group identifier.
    /// - Returns: the absolute container root path, or nil on failure.
    static func activate(_ identifier: String,
                         class containerClass: MCMContainerClass,
                         group: Bool = false) throws -> String {
        guard Self.isMobileHouseArrest else { throw MCMError.notMHA }
        guard Self.bridgeAvailable else { throw MCMError.bridgeUnavailable }
        guard BQMCMSafeIdentifier(identifier) else { throw MCMError.invalidIdentifier }

        var error: NSString?
        let path = BQMCMActivate(containerClass.rawValue,
                                identifier,
                                group,
                                &error)
        if let path = path as String? {
            return path
        }
        throw MCMError.activationFailed((error as? String) ?? "无详情")
    }

    /// Scoped variant for part-domain traversal (e.g. class 13 part 3).
    /// Use this when you need a sandbox extension for a specific subpath inside
    /// a container rather than the whole container root.
    static func activateScoped(_ identifier: String,
                               class containerClass: MCMContainerClass,
                               group: Bool = false,
                               part: UInt64 = 0,
                               partDomain: String? = nil,
                               flags: UInt64 = BQMCMFlags) throws -> String {
        guard Self.isMobileHouseArrest else { throw MCMError.notMHA }
        guard Self.bridgeAvailable else { throw MCMError.bridgeUnavailable }
        guard BQMCMSafeIdentifier(identifier) else { throw MCMError.invalidIdentifier }

        var error: NSString?
        let path = BQMCMActivateScoped(containerClass.rawValue,
                                       identifier,
                                       group,
                                       part,
                                       partDomain,
                                       flags,
                                       &error)
        if let path = path as String? {
            return path
        }
        throw MCMError.activationFailed((error as? String) ?? "无详情")
    }

    /// True iff `path` is inside a currently-active lease root.
    static func pathHasActiveLease(_ path: String) -> Bool {
        BQMCMPathHasActiveLease(path)
    }

    /// Query-only: return the class-2 container root path WITHOUT activating
    /// the sandbox token (used for app discovery on iOS 26).
    static func queryDataContainerPath(_ identifier: String) throws -> String {
        guard Self.isMobileHouseArrest else { throw MCMError.notMHA }
        guard Self.bridgeAvailable else { throw MCMError.bridgeUnavailable }
        guard BQMCMSafeIdentifier(identifier) else { throw MCMError.invalidIdentifier }

        var error: NSString?
        let path = BQMCMDataContainerPathQuery(identifier, &error)
        if let path = path as String? { return path }
        throw MCMError.activationFailed((error as? String) ?? "无详情")
    }

    /// Enumerate registered identifiers under a container class (iOS 26 often
    /// near-empty — combine with csstore/LS discovery in the caller).
    static func enumerate(_ containerClass: MCMContainerClass, limit: Int = 4096) -> [String] {
        guard Self.isMobileHouseArrest, Self.bridgeAvailable else { return [] }
        return BQMCMEnumerateIdentifiersForClass(containerClass.rawValue,
                                                 numericCast(limit), nil) ?? []
    }

    /// iOS 26 app-discovery fallback: parse com.apple.lsd's csstore for
    /// candidate bundle IDs.
    static func launchServicesStoreIdentifiers() -> [String] {
        guard Self.isMobileHouseArrest else { return [] }
        return BQMCMLaunchServicesStoreIdentifiers() ?? []
    }

    /// Release every cached lease.
    static func releaseAllLeases() {
        BQMCMReleaseAllLeases()
    }
}
