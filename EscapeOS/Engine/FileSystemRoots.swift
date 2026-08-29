import Foundation

/// 文件浏览器可进入的根路径清单。
///
/// 移植自 Erosion 的 `FSPaths` / `FSURL`，并按 EscapeOS 的情况做了调整：
/// - Erosion 把「App Groups / System App Data / SystemGroup 容器」归到
///   `raveSupported()` 后面（仅 iOS 27.0 的 4 个特定 build 才显示）。EscapeOS
///   不做版本门控，这些入口一律列出 —— bad_query 签发失败时页面会原样报出错误，
///   比「干脆不显示」更容易定位。
enum FileSystemRoots {

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        /// true 表示其下的第一级目录是「容器」，可解析出 App 名。
        let resolvesContainerNames: Bool
    }

    static let entries: [Entry] = [
        Entry(
            id: "/var/mobile/Containers/Data/Application",
            title: "应用数据容器",
            subtitle: "各 App 的 Documents / Library / tmp",
            systemImage: "folder.fill",
            resolvesContainerNames: true
        ),
        Entry(
            id: "/var/mobile/Containers/Data/InternalDaemon",
            title: "系统守护进程容器",
            subtitle: "系统服务的数据目录",
            systemImage: "gearshape.fill",
            resolvesContainerNames: true
        ),
        Entry(
            id: "/var/mobile/Containers/Data/PluginKitPlugin",
            title: "App 插件容器",
            subtitle: "扩展与插件的数据目录",
            systemImage: "puzzlepiece.fill",
            resolvesContainerNames: true
        ),
        Entry(
            id: "/var/containers/Bundle/Application",
            title: "应用安装目录",
            subtitle: "各 App 的 .app 包（图标、Info.plist、资源）",
            systemImage: "app.badge.checkmark",
            resolvesContainerNames: false
        ),
        Entry(
            id: "/var/mobile/Containers/Shared/AppGroup",
            title: "App Group",
            subtitle: "同一开发者下多个 App 共享的数据",
            systemImage: "person.2.fill",
            resolvesContainerNames: true
        ),
        Entry(
            id: "/var/containers/Shared/SystemGroup",
            title: "SystemGroup 容器",
            subtitle: "系统级共享数据（含配置描述文件）",
            systemImage: "lock.fill",
            resolvesContainerNames: false
        )
    ]

    /// 需要把 UUID 目录解析成 App 名的路径集合。
    static let containerNameRoots: Set<String> = Set(
        entries.filter(\.resolvesContainerNames).map(\.id)
    )

    /// 本应用自己的 Documents（备份、配对文件、导出物都在里面）。
    static var appDocuments: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }
}
