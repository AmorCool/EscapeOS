import Foundation
import UIKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 文件浏览器可进入的根路径清单。
///
/// 移植自 Erosion 的 `FSPaths` / `FSURL`，并按 EscapeOS 的实际情况做了调整：
/// - iOS 26 上只显示「应用数据 / 守护进程 / App 插件」三个容器根；
///   它们通过 `bad_query_list`（inode 扫描）枚举，不需要为根路径本身
///   签发沙盒扩展 —— 这正是 Erosion 原版的做法。
/// - 「App Group / SystemGroup / System App Data」需要 iOS 27.0 特定预览版
///   的 bad_query 路径才能访问，因此按 `raveSupported()` 门控显示，与原版一致。
/// - 额外保留「应用安装目录」（.app 包），同样走 `bad_query_list`。
enum FileSystemRoots {

    /// 容器根的列表策略。
    /// - `badQueryList`: 用 `bad_query_list` 直接枚举，不消费沙盒扩展。
    /// - `sandboxExtension`: 进入前先尝试 `SandboxEscape.consume`，与 Erosion
    ///   的 `shouldGrant: true` 行为一致。
    enum ListingMode {
        case badQueryList
        case sandboxExtension
    }

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        /// true 表示其下的第一级目录是「容器」，可解析出 App 名。
        let resolvesContainerNames: Bool
        /// 该根应如何枚举一级条目。
        let listingMode: ListingMode
        /// true 表示仅在 iOS 27.0 特定预览版上显示（raveSupported）。
        let requiresRave: Bool
    }

    static let entries: [Entry] = {
        var list: [Entry] = [
            Entry(
                id: "/var/mobile/Containers/Data/Application",
                title: "应用数据容器",
                subtitle: "各 App 的 Documents / Library / tmp",
                systemImage: "folder.fill",
                resolvesContainerNames: true,
                listingMode: .badQueryList,
                requiresRave: false
            ),
            Entry(
                id: "/var/mobile/Containers/Data/InternalDaemon",
                title: "系统守护进程容器",
                subtitle: "系统服务的数据目录",
                systemImage: "gearshape.fill",
                resolvesContainerNames: true,
                listingMode: .badQueryList,
                requiresRave: false
            ),
            Entry(
                id: "/var/mobile/Containers/Data/PluginKitPlugin",
                title: "App 插件容器",
                subtitle: "扩展与插件的数据目录",
                systemImage: "puzzlepiece.fill",
                resolvesContainerNames: true,
                listingMode: .badQueryList,
                requiresRave: false
            ),
            Entry(
                id: "/var/containers/Bundle/Application",
                title: "应用安装目录",
                subtitle: "各 App 的 .app 包（图标、Info.plist、资源）",
                systemImage: "app.badge.checkmark",
                resolvesContainerNames: false,
                listingMode: .badQueryList,
                requiresRave: false
            )
        ]

        if isRaveSupported {
            list.append(contentsOf: [
                Entry(
                    id: "/var/mobile/Containers/Shared/AppGroup",
                    title: "App Group",
                    subtitle: "同一开发者下多个 App 共享的数据",
                    systemImage: "person.2.fill",
                    resolvesContainerNames: true,
                    listingMode: .sandboxExtension,
                    requiresRave: true
                ),
                Entry(
                    id: "/var/containers/Data/System",
                    title: "System App Data",
                    subtitle: "系统应用数据容器",
                    systemImage: "internaldrive.fill",
                    resolvesContainerNames: true,
                    listingMode: .sandboxExtension,
                    requiresRave: true
                ),
                Entry(
                    id: "/var/containers/Shared/SystemGroup",
                    title: "SystemGroup 容器",
                    subtitle: "系统级共享数据（含配置描述文件）",
                    systemImage: "lock.fill",
                    resolvesContainerNames: true,
                    listingMode: .badQueryList,
                    requiresRave: true
                )
            ])
        }

        return list
    }()

    static func entry(for path: String) -> Entry? {
        entries.first { $0.id == path }
    }

    /// 需要把 UUID 目录解析成 App 名的路径集合。
    static let containerNameRoots: Set<String> = Set(
        entries.filter(\.resolvesContainerNames).map(\.id)
    )

    /// 使用 `bad_query_list` 枚举的根路径集合。
    static let badQueryListRoots: Set<String> = Set(
        entries.filter { $0.listingMode == .badQueryList }.map(\.id)
    )

    /// 本应用自己的 Documents（备份、配对文件、导出物都在里面）。
    static var appDocuments: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    // MARK: - 版本门控（对齐 Erosion 的 raveSupported）

    /// iOS 27.0 预览版中 bad_query 路径遍历恢复可用的 4 个特定 build。
    static var isRaveSupported: Bool {
        let version = doubleSystemVersion()
        let build = buildNumber()
        return version == 27.0 && ["24A5355q", "24A5370h", "24A5380h", "24A5390f"].contains(build)
    }

    private static func doubleSystemVersion() -> Double {
        Double(UIDevice.current.systemVersion) ?? 0
    }

    private static func buildNumber() -> String {
        var versionString = [CChar](repeating: 0, count: 32)
        var versionStringLen = size_t(versionString.count - 1)
        let res = sysctlbyname("kern.osversion", &versionString, &versionStringLen, nil, 0)
        guard res == 0, let build = String(validatingUTF8: versionString) else {
            return "Unknown"
        }
        return build
    }
}
