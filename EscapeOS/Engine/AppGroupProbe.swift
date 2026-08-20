import Foundation

/// On-device feasibility probe for reading LiveContainer's *shared* (App Group)
/// app containers without jailbreak.
///
/// The App Group container directory is named by a UUID chosen by
/// `containermanagerd` and is unknown at build time. This probe therefore
/// attempts two strategies and reports each outcome, so a single tap yields
/// real device evidence on iOS 26:
///
/// 1. **Direct hypotheses** — a few plausible absolute paths (e.g. the group
///    container named by the group-id string, which some sideload layouts use).
/// 2. **Discovery sweep** — if the sandbox extension permits it, enumerate the
///    `AppGroup` parent directory to learn the real group UUID dirs, then try
///    the LiveContainer shared-app path inside *each* one.
///
/// Success criterion for "shared-app management is feasible": at least one
/// path where **both** the sandbox extension is granted **and** the directory
/// is listed.
struct AppGroupProbe {

    static let groupIdentifier = "group.com.kdt.livecontainer"
    static let appGroupRoot = "/private/var/mobile/Containers/Shared/AppGroup"

    /// Runs the full probe and returns a plain-text report suitable for display
    /// in the Settings diagnostic section. Synchronous; call off the main thread
    /// for a responsive UI.
    static func run() -> String {
        let escape = SandboxEscape()
        let files = FileService()
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString

        var out: [String] = []
        out.append("AppGroup 共享 App 探测")
        out.append("iOS \(osVer)")
        out.append("目标 App Group：\(groupIdentifier)")
        out.append("路由：bad_query class 7 + is_group + create=true")
        out.append(String(repeating: "─", count: 46))

        // --- Strategy 1: direct path hypotheses ---
        let direct: [(String, String)] = [
            ("A. group-id 命名的根目录",
             "\(appGroupRoot)/group.com.kdt.livecontainer"),
            ("B. group-id 命名的深层共享目录",
             "\(appGroupRoot)/group.com.kdt.livecontainer/AppGroup/LiveContainer/Shared/Data/Application"),
            ("C. 无 group. 前缀的深层共享目录",
             "\(appGroupRoot)/com.kdt.livecontainer/AppGroup/LiveContainer/Shared/Data/Application"),
        ]
        for (label, path) in direct {
            out.append(contentsOf: probeOne(escape: escape, files: files, label: label, path: path))
            out.append("")
        }

        // --- Strategy 2: discovery sweep over the AppGroup parent ---
        out.append("D. 枚举 AppGroup 父目录并尝试每个 group 子目录")
        if let names = tryList(escape: escape, files: files, path: appGroupRoot) {
            out.append("  父目录列举：✅ \(names.count) 个 group 目录")
            let maxProbe = min(names.count, 40)
            var found = false
            for name in names.prefix(maxProbe) {
                let sub = "\(appGroupRoot)/\(name)/AppGroup/LiveContainer/Shared/Data/Application"
                let lines = probeOne(
                    escape: escape,
                    files: files,
                    label: "    group:\(name)",
                    path: sub,
                    indent: "    "
                )
                if lines.contains(where: { $0.contains("目录列举：✅") }) {
                    found = true
                }
                out.append(contentsOf: lines)
            }
            if !found {
                out.append("  未发现任一 group 目录下存在 LiveContainer 共享 App 路径。")
            }
        } else {
            out.append("  父目录列举：❌ 无法访问（该路由可能仅授权到具体 group 容器，而非父目录）")
        }

        out.append(String(repeating: "─", count: 46))
        out.append("结论：任一路径「沙盒扩展✅ + 目录列举✅」同时成立 → 共享 App 管理可行。")
        out.append("把本结果截图回传即可定位。")
        return out.joined(separator: "\n")
    }

    // MARK: - helpers

    /// Try consume + list for one path. Returns report lines (no trailing blank).
    private static func probeOne(
        escape: SandboxEscape,
        files: FileService,
        label: String,
        path: String,
        indent: String = "  "
    ) -> [String] {
        var lines: [String] = []
        lines.append("\(indent)\(label)")
        lines.append("\(indent)  路径：\(path)")
        do {
            let handle = try escape.consume(
                path: path,
                groupIdentifier: groupIdentifier,
                isGroup: true,
                create: true
            )
            lines.append("\(indent)  沙盒扩展：✅ handle=\(handle.raw)")
            do {
                let items = try files.list(directory: path)
                lines.append("\(indent)  目录列举：✅ \(items.count) 项")
                for it in items.prefix(8) {
                    lines.append("\(indent)    • \(it.name)\(it.isDirectory ? "/" : "")")
                }
                if items.count > 8 {
                    lines.append("\(indent)    … 其余 \(items.count - 8) 项")
                }
            } catch {
                lines.append("\(indent)  目录列举：❌ \(error.localizedDescription)")
            }
            escape.release(handle)
        } catch {
            lines.append("\(indent)  沙盒扩展：❌ \(error.localizedDescription)")
        }
        return lines
    }

    /// Try consume + list a directory. Returns entry names if both succeed,
    /// otherwise `nil`.
    private static func tryList(
        escape: SandboxEscape,
        files: FileService,
        path: String
    ) -> [String]? {
        do {
            let handle = try escape.consume(
                path: path,
                groupIdentifier: groupIdentifier,
                isGroup: true,
                create: true
            )
            defer { escape.release(handle) }
            return try files.list(directory: path).map { $0.name }
        } catch {
            return nil
        }
    }
}
