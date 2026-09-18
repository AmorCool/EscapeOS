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

        // v0.3.412：**不再直接调 `bad_query`** —— 交给漏洞利用注册表。
        //
        // 这是"把 bad_query 真正独立出来"的关键一步：以前取消勾选只影响「列目录」
        // （`BadQueryExploit.paths`），而**取沙盒扩展**这条能力仍写死在这里，
        // 于是勾不勾选都不影响实际行为 —— 用户实测指出过这一点。
        // 现在两条能力都归 `BadQueryExploit`，勾选才真正控制全部。
        //
        // 取第一个非 nil 的结果：`nil` = 该漏洞利用没执行（被关掉），继续试下一个；
        // 负数 = 执行了但被内核拒绝（iOS 26 常见 -4），同样继续试下一个漏洞利用。
        let raw = ExploitRegistry.enabled()
            .shuffled()
            .compactMap { $0.consumeExtension(path: path,
                                              groupIdentifier: groupIdentifier,
                                              isGroup: isGroup,
                                              create: create) }
            .first(where: { $0 >= 0 })

        guard let raw else {
            // 没有任何已启用的漏洞利用能给出句柄（用户全关 / 全被内核拒绝）。
            throw SandboxEscapeError.kernelRejected
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
        // v0.3.412：同样经注册表释放。用 `all`（不是 `enabled()`）——
        // 释放是清理动作，不该因为用户中途取消勾选而泄漏句柄。
        ExploitRegistry.all.first?.releaseExtension(handle.raw)
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
    //
    // 线程安全论证（下面 8 个 `nonisolated(unsafe)` 静态属性的共同依据）：
    // · **写者唯一**：只有 `bootstrapLiveContainerExtensions()` 一处写入，而它必须在本 App
    //   启动时（`EscapeSpaceApp.init`，主线程）调用一次——源码注释已写明「Must run at app
    //   launch so the extensions are live before any discovery/scan」。该函数把全部字段写完后
    //   才返回，此后**再无任何写入点**，故不存在写-写竞争。
    // · **读**：① 主线程/SwiftUI（`LiveCleanTabView` 诊断区）；② 后台队列
    //   （`BackupsListView.loadTargets` 的 `DispatchQueue.global().async` →
    //   `LiveContainerDiscovery.discover`）。两处读取都发生在启动之后，启动时的写入对它们
    //   有 happens-before（全局变量惰性初始化 + 队列提交）；此后数据不再变化，并发只读安全。
    // · 结论：语义上等价于「启动时一次性初始化的只读全局量」，`nonisolated(unsafe)` 只是把
    //   这一既有事实告知编译器；**不引入任何行为变化**。

    /// Set when the LiveContainer host handed us container sandbox tokens via
    /// `ESC_LC_CONTAINER_TOKENS`. While active, `LiveContainerDiscovery` skips the
    /// (iOS-26-blocked) `bad_query` path and reads guest containers directly, since
    /// the consumed extensions grant access to the LC data + App Group roots.
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcContainerExtensionsActive = false

    /// LC data container root, forwarded by the host as `ESC_LC_HOME`
    /// (private guest containers live under `<this>/Documents/Data/Application`).
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcHomePath: String?

    /// LC's real App Group container, forwarded by the host as `ESC_LC_APPGROUP_PATH`
    /// (shared/"converted" guest containers live under `<this>/LiveContainer/Data/Application`).
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcAppGroupPath: String?

    /// Host-reported grant outcome (forwarded via `ESC_LC_GRANT_STATUS`).
    /// Possible values: "issued:N", "failed:issue_null",
    /// "skipped:no_symbol", "skipped:not_target", optionally suffixed
    /// with ",no_appgroup". NULL when the host never forwarded it.
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcContainerGrantStatus: String?

    /// Number of tokens the host handed us (and we attempted to consume).
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcContainerTokenCount = 0

    /// Number of tokens successfully consumed in this process.
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcContainerConsumedCount = 0

    /// Per-token consume result strings (for on-device diagnosis).
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcContainerConsumeResults: [String] = []

    /// How the LiveContainer host launched us: "appex" (multitask) or "classic"
    /// (same-process). Forwarded as `ESC_LC_LAUNCH_MODE` for diagnostics.
    /// nonisolated(unsafe)：写者唯一（启动 bootstrap），论证见上方 MARK 注释块.
    nonisolated(unsafe) static var lcContainerLaunchMode: String?

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
