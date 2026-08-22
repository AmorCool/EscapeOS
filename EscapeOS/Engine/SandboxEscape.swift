import Foundation

/// Errors that can occur while consuming or releasing a sandbox extension
/// for a container path via the bad_query primitive.
enum SandboxEscapeError: Error, LocalizedError {
    case notAbsolutePath
    case targetMissing
    case resolveFailed
    case queryCreateFailed
    case outsideSandbox
    case kernelRejected
    case asprintfFailed
    case unknown(code: Int64)
    case invalidHandle

    var errorDescription: String? {
        switch self {
        case .notAbsolutePath:
            return "The provided path is not an absolute path."
        case .targetMissing:
            return "The target path does not exist on this device."
        case .resolveFailed:
            return "Failed to resolve containermanager symbols."
        case .queryCreateFailed:
            return "Failed to create the container query."
        case .outsideSandbox:
            return "The path lies outside containermanager's sandbox."
        case .kernelRejected:
            return "The kernel refused to issue a sandbox extension."
        case .asprintfFailed:
            return "Failed to build the query part string."
        case .unknown(let code):
            return "Unknown sandbox error (code \(code))."
        case .invalidHandle:
            return "Attempted to use an invalid sandbox handle."
        }
    }
}

/// Thin, type-safe wrapper around the `bad_query` C primitive. All access to
/// another app's container must go through this type so that handles are
/// tracked and released deterministically.
final class SandboxEscape {

    /// An opaque, positive handle representing a live sandbox extension.
    struct Handle: Hashable {
        let raw: Int64
    }

    private var liveHandles: Set<Int64> = []
    private let lock = NSLock()

    /// Consume a sandbox extension for `path`.
    /// - Parameters:
    ///   - path: Absolute path inside another app's container.
    ///   - groupIdentifier: Optional app-group identifier (iOS 26 App Group route).
    ///   - isGroup: Whether the target is an App Group container.
    ///   - create: When `true`, skip the existence (`lstat`) pre-check. Used by
    ///     diagnostics that probe paths whose UUID is not yet known.
    /// - Returns: A `Handle` that must later be passed to `release(_:)`.
    /// - Throws: `SandboxEscapeError` on failure.
    func consume(path: String, groupIdentifier: String? = nil, isGroup: Bool = false, create: Bool = false) throws -> Handle {
        // When LiveContainer has already granted us a sandbox extension for the
        // LC data/AppGroup roots, any subpath inside those roots is reachable
        // without calling bad_query — which on iOS 26 returns -4 (kernelRejected)
        // for arbitrary containers. Return a sentinel handle so callers can keep
        // using withHandle() transparently.
        if Self.isCoveredByLCContainerExtensions(path: path) {
            return Handle(raw: -1)
        }

        var cPath = Array(path.utf8CString)
        var cGroup = groupIdentifier.map { Array($0.utf8CString) }

        let raw: Int64 = cPath.withUnsafeMutableBufferPointer { pathPtr in
            if cGroup != nil {
                return cGroup!.withUnsafeMutableBufferPointer { groupPtr in
                    bad_query(pathPtr.baseAddress, create, groupPtr.baseAddress, isGroup)
                }
            }
            return bad_query(pathPtr.baseAddress, create, nil, isGroup)
        }

        guard raw >= 0 else {
            throw Self.error(from: raw)
        }

        lock.lock()
        liveHandles.insert(raw)
        lock.unlock()
        return Handle(raw: raw)
    }

    /// Release a previously consumed handle. Safe to call multiple times.
    func release(_ handle: Handle) {
        // Sentinel handle: the access came from the globally-active LC container
        // extension, not from a per-call bad_query handle. Nothing to release.
        guard handle.raw >= 0 else { return }
        lock.lock()
        let removed = liveHandles.remove(handle.raw)
        lock.unlock()
        guard removed != nil else { return }
        bad_query_release(handle.raw)
    }

    /// True when `path` lies under a LiveContainer container root for which the
    /// host already issued and we consumed a sandbox extension.
    private static func isCoveredByLCContainerExtensions(path: String) -> Bool {
        guard lcContainerExtensionsActive else { return false }
        let standardized = (path as NSString).standardizingPath
        if let home = lcHomePath, !home.isEmpty,
           standardized.hasPrefix((home as NSString).standardizingPath) {
            return true
        }
        if let ag = lcAppGroupPath, !ag.isEmpty,
           standardized.hasPrefix((ag as NSString).standardizingPath) {
            return true
        }
        return false
    }

    /// Number of currently live (consumed, not yet released) handles.
    var liveHandleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveHandles.count
    }

    // MARK: - LiveContainer container-management extensions

    /// Set when the LiveContainer host handed us container sandbox tokens via
    /// `ESC_LC_CONTAINER_TOKENS`. While active, `LiveContainerDiscovery` skips the
    /// (iOS-26-blocked) `bad_query` path and reads guest containers directly, since
    /// the consumed extensions grant access to the LC data + App Group roots.
    static var lcContainerExtensionsActive = false

    /// LC data container root, forwarded by the host as `ESC_LC_HOME`
    /// (private guest containers live under `<this>/Documents/Data/Application`).
    static var lcHomePath: String?

    /// LC's real App Group container, forwarded by the host as `ESC_LC_APPGROUP_PATH`
    /// (shared/"converted" guest containers live under `<this>/LiveContainer/Data/Application`).
    static var lcAppGroupPath: String?

    /// Host-reported grant outcome (forwarded via `ESC_LC_GRANT_STATUS`).
    /// Possible values: "issued:N", "failed:issue_null",
    /// "skipped:no_symbol", "skipped:not_target", optionally suffixed
    /// with ",no_appgroup". NULL when the host never forwarded it.
    static var lcContainerGrantStatus: String?

    /// Number of tokens the host handed us (and we attempted to consume).
    static var lcContainerTokenCount = 0

    /// Number of tokens successfully consumed in this process.
    static var lcContainerConsumedCount = 0

    /// Per-token consume result strings (for on-device diagnosis).
    static var lcContainerConsumeResults: [String] = []

    /// How the LiveContainer host launched us: "appex" (multitask) or "classic"
    /// (same-process). Forwarded as `ESC_LC_LAUNCH_MODE` for diagnostics.
    static var lcContainerLaunchMode: String?

    /// Consume the container sandbox tokens issued by the LiveContainer host.
    /// Tokens are newline-separated in `ESC_LC_CONTAINER_TOKENS`; each is consumed
    /// in THIS process (extensions are not inherited across the spawn boundary on
    /// iOS 26). Also records the forwarded container root paths. Must run at app
    /// launch so the extensions are live before any discovery/scan.
    static func bootstrapLiveContainerExtensions() {
        // Read the live environment via getenv — NOT ProcessInfo.processInfo.environment,
        // which Darwin caches lazily on first access. LiveContainer's own bootstrap
        // (LCBootstrap) runs before EscapeOS's init and may touch it, leaving us with
        // a stale, extension-less copy that never sees the ESC_LC_* vars set by
        // LiveProcess. getenv always reflects the current environ.
        let readEnv: (String) -> String? = { key in
            guard let c = getenv(key) else { return nil }
            let s = String(cString: c)
            return s.isEmpty ? nil : s
        }

        lcHomePath = readEnv("ESC_LC_HOME")
        lcAppGroupPath = readEnv("ESC_LC_APPGROUP_PATH")
        lcContainerGrantStatus = readEnv("ESC_LC_GRANT_STATUS")
        lcContainerLaunchMode = readEnv("ESC_LC_LAUNCH_MODE")

        guard let raw = readEnv("ESC_LC_CONTAINER_TOKENS") else {
            NSLog("[SandboxEscape] no LiveContainer container tokens in environment")
            return
        }
        let tokens = raw.split(separator: "\n").filter { !$0.isEmpty }
        lcContainerTokenCount = tokens.count
        var consumed = 0
        var results: [String] = []
        for (i, token) in tokens.enumerated() {
            let handle = String(token).withCString { mg_consume_token($0) }
            if handle >= 0 {
                consumed += 1
                let msg = "token[\(i)] ok handle=\(handle)"
                results.append(msg)
                NSLog("[SandboxEscape] consumed container extension \(msg)")
            } else {
                let msg = "token[\(i)] FAILED code=\(handle)"
                results.append(msg)
                NSLog("[SandboxEscape] container extension \(msg)")
            }
        }
        lcContainerConsumedCount = consumed
        lcContainerConsumeResults = results
        lcContainerExtensionsActive = consumed > 0
        NSLog("[SandboxEscape] LiveContainer container extensions active=\(lcContainerExtensionsActive) (consumed \(consumed)/\(tokens.count))")
    }

    /// Convenience scoped accessor: consumes a handle, runs `body`, always releases.
    @discardableResult
    func withHandle<T>(
        for path: String,
        groupIdentifier: String? = nil,
        isGroup: Bool = false,
        _ body: (Handle) throws -> T
    ) throws -> T {
        let handle = try consume(path: path, groupIdentifier: groupIdentifier, isGroup: isGroup)
        defer { release(handle) }
        return try body(handle)
    }

    private static func error(from code: Int64) -> SandboxEscapeError {
        switch code {
        case -255: return .notAbsolutePath
        case -254: return .targetMissing
        case -1:   return .resolveFailed
        case -2:   return .queryCreateFailed
        case -3:   return .outsideSandbox
        case -4:   return .kernelRejected
        case -5:   return .asprintfFailed
        default:   return .unknown(code: code)
        }
    }
}
