import Foundation

/// 定位 bundle 内的 `SAPAssets/`（Asspp 本地 SAP 登录所需的 4 个 Apple 资产）。
///
/// **为什么不能只写 `Bundle.main.resourceURL`**：本 App 常被侧载在
/// **LiveContainer** 里运行（进程名是 `LiveProcess`），此时 `Bundle.main` 未必指向
/// 我们自己的 .app —— 真机表现为日志里
/// `[SAP] 失败：Missing or truncated SAP assets. Rebuild the app.`，
/// 而 IPA 里的资产其实是完整的（已核对：CoreFP 29,014,912 / CoreFP.icxs 5,288,352 /
/// CommerceKit 3,271,840 / CommerceCore 207,744 字节，全部与 SAPContext.mm 的校验值一致）。
///
/// 所以按「最可能正确 → 兜底」的顺序逐个试，取第一个真的存在 `CoreFP` 的目录。
enum SAPAssetsLocator {

    /// 资产文件名（用它做存在性判定，它是最大的那个）
    static let probeFile = "CoreFP"

    /// 逐个候选目录（去重、保序）
    private static func candidates() -> [URL] {
        var bases: [URL] = []
        // ① 包含 SAPContext 类的那 **image** 所在的 bundle —— 最可靠：
        //    class_getImageName 拿的是编译进这个类的 Mach-O，也就是我们的 .app，
        //    与进程的 main bundle 是谁无关。
        if let cls = NSClassFromString("SAPContext") {
            let bundle = Bundle(for: cls)
            if let url = bundle.resourceURL { bases.append(url) }
            bases.append(bundle.bundleURL)
        }
        // ② 常规路径
        if let url = Bundle.main.resourceURL { bases.append(url) }
        bases.append(Bundle.main.bundleURL)
        // ③ 可执行文件同级（有些容器/注入场景 main bundle 不对，但 exe 是对的）
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            bases.append(exe.deletingLastPathComponent())
        }

        var seen = Set<String>()
        var out: [URL] = []
        for base in bases {
            let dir = base.appendingPathComponent("SAPAssets")
            let key = dir.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(dir) }
        }
        return out
    }

    /// 可用的资产目录；nil = 四处都没找到
    static var url: URL? {
        candidates().first { dir in
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(probeFile).path)
        }
    }

    /// 走一遍全部候选并逐条记录结果（登录失败时用来定位"资产到底在不在"）
    static func describe() -> String {
        let fm = FileManager.default
        var lines: [String] = []
        for dir in candidates() {
            let exists = fm.fileExists(atPath: dir.path)
            if exists {
                let size = (try? fm.attributesOfItem(
                    atPath: dir.appendingPathComponent(probeFile).path)[.size] as? Int) ?? nil
                lines.append("\(dir.path) → 存在，CoreFP=\(size.map(String.init) ?? "缺失")")
            } else {
                lines.append("\(dir.path) → 不存在")
            }
        }
        return lines.joined(separator: "；")
    }
}
