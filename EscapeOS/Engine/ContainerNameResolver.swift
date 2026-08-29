import Foundation
import UIKit

/// 把容器目录的 UUID 解析成可读的 App 名。
///
/// 浏览 `/var/mobile/Containers/Data/Application` 时，看到的只是一串 UUID 目录，
/// 完全无法辨认。这里做两级解析：
/// 1. 读容器根的 containermanager 元数据，拿 `MCMMetadataIdentifier`（bundle id）——
///    该路径在别的 App 沙盒内，必须经 `SandboxEscape` 签发扩展才能读。
/// 2. bundle id → App 显示名，优先走私有 `LSApplicationWorkspace`（与壁纸页打开
///    PosterBoard 同样的手法），取不到就退回 bundle id（仍比 UUID 好认）。
///
/// 结果按容器路径缓存，避免每次刷新目录都重读 plist。
final class ContainerNameResolver {

    static let shared = ContainerNameResolver()

    private let escape = SandboxEscape()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"

    private init() {}

    /// 解析容器显示名；解析不了返回 `nil`，调用方应回退显示原始目录名。
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

    /// 预解析一批容器（后台批量调用，避免逐个上主线程）。
    func resolveAll(containerPaths: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for path in containerPaths {
            if let name = resolve(containerPath: path) {
                result[path] = name
            }
        }
        return result
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

    /// 用私有 LSApplicationWorkspace 查应用的本地化名称。
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
