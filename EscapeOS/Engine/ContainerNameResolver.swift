import Foundation
import UIKit

/// 把容器目录的 UUID 解析成可读的 App 名。
///
/// 浏览 `/var/mobile/Containers/Data/Application` 时，看到的只是一串 UUID 目录，
/// 完全无法辨认。这里做两级解析：
/// 1. 读容器根的 containermanager 元数据，拿 `MCMMetadataIdentifier`（bundle id）——
///    该路径在别的 App 沙盒内，必须经 `SandboxEscape` 签发扩展才能读。
/// 2. bundle id → App 显示名，走私有 `LSApplicationWorkspace`，取不到就退回
///    bundle id（仍比 UUID 好认）。
///
/// ⚠️ 线程约束（v0.2.99 修复闪退）：
/// - `readBundleId` 系（bad_query + NSDictionary）可以在任意后台线程跑；
/// - **`LSApplicationWorkspace` 私有 API 只能在主线程调用**——v0.2.98 在
///   `Task.detached(utility)` 后台线程对几百个容器批量 perform，直接导致
///   打开容器根目录时进程闪退。Erosion 原版只显示 bundle id，不查 LaunchServices。
///   这里保留 App 名显示，但把查询拆到主线程。
///
/// 结果按容器路径缓存，避免每次刷新目录都重读 plist。
final class ContainerNameResolver {

    static let shared = ContainerNameResolver()

    private let escape = SandboxEscape()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"

    private init() {}

    /// 后台线程批量读取 bundle id（只做 bad_query + plist 读取，线程安全）。
    /// 返回 [容器路径: bundleId]，读取失败的容器不出现。
    func resolveAllBundleIds(containerPaths: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for path in containerPaths {
            if let bundleId = readBundleId(containerPath: path) {
                result[path] = bundleId
            }
        }
        return result
    }

    /// 主线程调用：把 [容器路径: bundleId] 本地化成 [容器路径: App 名]。
    /// 内部走私有 `LSApplicationWorkspace`，**严禁在后台线程调用**。
    func localizeNames(bundleIds: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (path, bundleId) in bundleIds {
            let name = localizedName(forBundleId: bundleId) ?? bundleId
            result[path] = name
            lock.lock()
            cache[path] = name
            lock.unlock()
        }
        return result
    }

    /// 兼容单点解析（仅主线程调用安全的场景）：先查缓存，再后台读 bundle id，
    /// 最后在主线程查名。若调用方无法保证主线程，请改用上面两个方法。
    @MainActor
    func resolve(containerPath: String) -> String? {
        lock.lock()
        let cached = cache[containerPath]
        lock.unlock()
        if let cached { return cached }

        guard let bundleId = readBundleId(containerPath: containerPath) else { return nil }
        let name = localizedName(forBundleId: bundleId) ?? bundleId

        lock.lock()
        cache[containerPath] = name
        lock.unlock()
        return name
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - 内部

    /// 读容器元数据里的 `MCMMetadataIdentifier`。后台线程安全。
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

    /// 用私有 LSApplicationWorkspace 查应用的本地化名称。**仅主线程调用。**
    private func localizedName(forBundleId bundleId: String) -> String? {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue()
        else { return nil }

        guard let proxy = workspace
            .perform(NSSelectorFromString("applicationProxyForIdentifier:"), with: bundleId)?
            .takeUnretainedValue()
        else { return nil }

        guard let name = proxy.perform(NSSelectorFromString("localizedName"))?.takeUnretainedValue() as? String,
              !name.isEmpty
        else { return nil }
        return name
    }
}
