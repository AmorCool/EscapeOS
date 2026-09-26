import Foundation
import UIKit

/// 把容器目录的 UUID 解析成可读的标识（bundle id）.
///
/// 浏览 `/var/mobile/Containers/Data/Application` 时，看到的只是一串 UUID 目录，
/// 完全无法辨认.这里读容器根的 containermanager 元数据，拿 `MCMMetadataIdentifier`
/// （bundle id）作为显示名——**与 Erosion 原版 `folderLabel` 完全一致**.
///
/// ⚠️ 为什么不做 bundle id → App 显示名（LSApplicationWorkspace）的二级解析：
/// v0.2.98 在后台线程批量调用私有 LaunchServices API → 打开容器根直接闪退；
/// v0.2.99 挪到主线程后仍延迟闪退（该环境批量查询不稳定）.Erosion 原版只显示
/// bundle id，从不上 LS 查询.对齐原版，容器行显示 bundle id（仍比 UUID 好认）.
///
/// 结果按容器路径缓存，避免每次刷新目录都重读 plist.
final class ContainerNameResolver {

    /// 单个容器解析失败的原因.
    ///
    /// 为什么要分类：搜索只能匹配「已解析」出的名字，解析失败的容器**永远搜不到**.
    /// 以前失败静默 `continue`，用户只会以为「没有这个容器」——把原因带出来，
    /// 用户才能知道为什么某个 UUID 只能用 UUID 搜.
    ///
    /// `Error` 不是为了满足 `Result` 才加的：它本来就是「解析失败」这件事的类型化
    /// 描述，实现 `LocalizedError` 让调用方可以直接把 `errorDescription` 放进提示里，
    /// 不必再为每种 `Reason` 手写一遍文案.
    struct ResolveFailure: Error, Sendable, LocalizedError {
        enum Reason: Sendable {
            /// `consume` 抛错（附 SandboxEscape 的错误文本）.
            case consumeFailed
            /// 命中了 LiveContainer 容器扩展的哨兵分支（未真取扩展），且读 plist 失败.
            case sentinelHandle
            /// 拿到了句柄，但元数据 plist 读不出来（文件不存在 / 读不动）.
            case metadataUnreadable
            /// plist 读到了，但没有 `MCMMetadataIdentifier` 键（或值不是 String）.
            case missingIdentifier
        }

        /// 容器目录路径（UUID）.
        let path: String
        let reason: Reason
        /// 补充信息：失败时的具体错误文本或文件路径，供明细展示.
        let detail: String?

        var errorDescription: String? {
            let base: String
            switch reason {
            case .consumeFailed:
                base = "无法获取沙盒扩展."
            case .sentinelHandle:
                base = "被 LiveContainer 容器扩展覆盖，但读取仍失败."
            case .metadataUnreadable:
                base = "读不出容器元数据."
            case .missingIdentifier:
                base = "容器元数据里没有标识键."
            }
            if let detail, !detail.isEmpty {
                return "\(base)（\(detail)）"
            }
            return base
        }
    }

    /// Swift 6 并发检查：本类型非 Sendable，但唯一的可变状态 `cache` 的**全部**读写
    /// 都在 `lock`（NSLock）内（见 `resolveAll` / `displayName`），实例本身线程安全
    /// —— `resolveAll` 的文档也声明「任意线程可调」。
    nonisolated(unsafe) static let shared = ContainerNameResolver()

    private let escape = SandboxEscape()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"
    private static let fallbackMetadataFileName = "com.apple.mobile_container_manager.metadata.plist"

    private init() {}

    /// 批量解析容器显示名（bundle id）.任意线程可调：
    /// 内部只有 bad_query consume + plist 读取，无任何私有 UI/LaunchServices API.
    /// 返回 [容器路径: bundleId]，读取失败的容器不出现（调用方回退显示 UUID）.
    func resolveAll(containerPaths: [String]) -> [String: String] {
        resolveAllReportingFailures(containerPaths: containerPaths).names
    }

    /// 同 `resolveAll`，但把每个失败容器的原因一并返回 —— UI 据此说明「为什么搜不到」.
    /// 读失败**不写缓存**，所以换个时机（补解析）可以重试.
    func resolveAllReportingFailures(
        containerPaths: [String]
    ) -> (names: [String: String], failures: [ResolveFailure]) {
        var names: [String: String] = [:]
        var failures: [ResolveFailure] = []
        for path in containerPaths {
            lock.lock()
            let cached = cache[path]
            lock.unlock()
            if let cached {
                names[path] = cached
                continue
            }
            switch resolveOne(containerPath: path) {
            case .success(let bundleId):
                lock.lock()
                cache[path] = bundleId
                lock.unlock()
                names[path] = bundleId
            case .failure(let failure):
                failures.append(failure)
            }
        }
        return (names, failures)
    }

    /// 单点解析（缓存优先）.任意线程可调.
    func resolve(containerPath: String) -> String? {
        lock.lock()
        let cached = cache[containerPath]
        lock.unlock()
        if let cached { return cached }

        guard case .success(let bundleId) = resolveOne(containerPath: containerPath) else { return nil }
        lock.lock()
        cache[containerPath] = bundleId
        lock.unlock()
        return bundleId
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - 内部

    /// 先试带点前缀的主文件名，再试无点前缀的回退名；两个都失败时回报**主文件**的原因
    /// （主文件才是 containermanager 的规范位置，回退名多半压根不存在，原因没参考价值）.
    private func resolveOne(containerPath: String) -> Result<String, ResolveFailure> {
        let candidates = [
            (containerPath as NSString).appendingPathComponent(Self.metadataFileName),
            (containerPath as NSString).appendingPathComponent(Self.fallbackMetadataFileName)
        ]
        var primaryFailure: ResolveFailure?
        for (index, path) in candidates.enumerated() {
            switch readMetadataIdentifier(at: path, containerPath: containerPath) {
            case .resolved(let identifier):
                return .success(identifier)
            case .failed(let failure):
                if index == 0 { primaryFailure = failure }
            }
        }
        return .failure(primaryFailure ?? ResolveFailure(
            path: containerPath,
            reason: .metadataUnreadable,
            detail: nil
        ))
    }

    private enum MetadataOutcome {
        case resolved(String)
        case failed(ResolveFailure)
    }

    private func readMetadataIdentifier(at path: String, containerPath: String) -> MetadataOutcome {
        let handle: SandboxEscape.Handle
        do {
            handle = try escape.consume(path: path, create: true)
        } catch {
            return .failed(ResolveFailure(
                path: containerPath,
                reason: .consumeFailed,
                detail: error.localizedDescription
            ))
        }
        defer { escape.release(handle) }

        if handle.raw < 0 {
            // 哨兵句柄：本次没真取扩展，靠的是「进程本身已有访问权」的假设.
            // 该假设由 `SandboxEscape.isCoveredByLCContainerExtensions` 的前缀判定 +
            // **全局** token 计数推出，并不保证这条路径真有访问权（例如 App Group token
            // 没发出来、只有 home token 生效时，全局判定仍为 true）.所以这里先按环境权限
            // 读一次，读不到就强制真取一次扩展再试 —— 强制失败会 throw，只影响本次解析.
            let ambient = identifierOutcome(at: path, containerPath: containerPath)
            if case .resolved = ambient { return ambient }
            if let forced = try? escape.consume(path: path, create: true, forceRealExtension: true) {
                defer { escape.release(forced) }
                let forcedOutcome = identifierOutcome(at: path, containerPath: containerPath)
                if case .resolved = forcedOutcome { return forcedOutcome }
            }
            // 两种都读不到：明确标成「哨兵分支 + 读失败」，与普通读失败区分开.
            return .failed(ResolveFailure(
                path: containerPath,
                reason: .sentinelHandle,
                detail: "被 LiveContainer 容器扩展覆盖（哨兵句柄），未真取扩展且读取失败"
            ))
        }

        return identifierOutcome(at: path, containerPath: containerPath)
    }

    /// 读 plist 并取 `MCMMetadataIdentifier`；读不到 / 缺键都映射成对应失败原因.
    private func identifierOutcome(at path: String, containerPath: String) -> MetadataOutcome {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return .failed(ResolveFailure(
                path: containerPath,
                reason: .metadataUnreadable,
                detail: path
            ))
        }
        guard let identifier = dict["MCMMetadataIdentifier"] as? String else {
            return .failed(ResolveFailure(
                path: containerPath,
                reason: .missingIdentifier,
                detail: path
            ))
        }
        return .resolved(identifier)
    }
}
