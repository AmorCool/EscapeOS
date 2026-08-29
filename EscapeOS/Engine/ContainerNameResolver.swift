import Foundation
import UIKit

/// 把容器目录的 UUID 解析成可读的标识（bundle id）。
///
/// 浏览 `/var/mobile/Containers/Data/Application` 时，看到的只是一串 UUID 目录，
/// 完全无法辨认。这里读容器根的 containermanager 元数据，拿 `MCMMetadataIdentifier`
/// （bundle id）作为显示名——**与 Erosion 原版 `folderLabel` 完全一致**。
///
/// ⚠️ 为什么不做 bundle id → App 显示名（LSApplicationWorkspace）的二级解析：
/// v0.2.98 在后台线程批量调用私有 LaunchServices API → 打开容器根直接闪退；
/// v0.2.99 挪到主线程后仍延迟闪退（该环境批量查询不稳定）。Erosion 原版只显示
/// bundle id，从不上 LS 查询。对齐原版，容器行显示 bundle id（仍比 UUID 好认）。
///
/// 结果按容器路径缓存，避免每次刷新目录都重读 plist。
final class ContainerNameResolver {

    static let shared = ContainerNameResolver()

    private let escape = SandboxEscape()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"

    private init() {}

    /// 批量解析容器显示名（bundle id）。任意线程可调：
    /// 内部只有 bad_query consume + plist 读取，无任何私有 UI/LaunchServices API。
    /// 返回 [容器路径: bundleId]，读取失败的容器不出现（调用方回退显示 UUID）。
    func resolveAll(containerPaths: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for path in containerPaths {
            lock.lock()
            let cached = cache[path]
            lock.unlock()
            if let cached {
                result[path] = cached
                continue
            }
            guard let bundleId = readBundleId(containerPath: path) else { continue }
            lock.lock()
            cache[path] = bundleId
            lock.unlock()
            result[path] = bundleId
        }
        return result
    }

    /// 单点解析（缓存优先）。任意线程可调。
    func resolve(containerPath: String) -> String? {
        lock.lock()
        let cached = cache[containerPath]
        lock.unlock()
        if let cached { return cached }

        guard let bundleId = readBundleId(containerPath: containerPath) else { return nil }
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

    /// 读容器元数据里的 `MCMMetadataIdentifier`。
    private func readBundleId(containerPath: String) -> String? {
        let primary = (containerPath as NSString).appendingPathComponent(Self.metadataFileName)
        if let id = readMetadataIdentifier(at: primary) { return id }
        let alt = (containerPath as NSString).appendingPathComponent("com.apple.mobile_container_manager.metadata.plist")
        return readMetadataIdentifier(at: alt)
    }

    private func readMetadataIdentifier(at path: String) -> String? {
        guard let handle = try? escape.consume(path: path, create: true) else { return nil }
        defer { escape.release(handle) }
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        return dict["MCMMetadataIdentifier"] as? String
    }
}
