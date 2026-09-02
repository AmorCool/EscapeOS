//
//  ModuleService.swift
//  EscapeSpace
//
//  EscapeSpace 模块系统（v0.3.48）。
//  参考 KernelSU 的模块管理形态（module.prop + 声明式动作），升级为 JSON 规范：
//
//    escape.module.v1 规范
//    ├── module.json      模块清单（spec/id/name/icon/version/author/description/actions）
//    └── actions[]        声明式动作，由宿主（EscapeSpace）通过 Rust FFI 管道执行
//
//  动作类型（v1 支持 signal；后续版本扩展）：
//    - signal          按进程名查找 PID 并下发信号（listProcesses + send_signal，Rust FFI）
//    - kill_top_memory （预留）按内存占用排序结束高占用后台应用
//    - notify          （预留）本地通知
//    - script          （预留）设备侧脚本执行
//
//  模块以 .zip 分发（根目录必须含 module.json），安装到
//  Documents/Modules/<id>/。宿主内置两个官方模块（首次启动自动安装）。
//

import Foundation

// MARK: - 模块模型

/// 热补丁声明（hotfix.patches[]）
struct HotfixPatch: Codable {
    let type: String       // "feature_flag" | "text"
    let key: String
    var valueBool: Bool?
    var valueText: String?

    enum CodingKeys: String, CodingKey {
        case type, key, value
    }

    init(type: String, key: String, valueBool: Bool? = nil, valueText: String? = nil) {
        self.type = type
        self.key = key
        self.valueBool = valueBool
        self.valueText = valueText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        key = try c.decode(String.self, forKey: .key)
        valueBool = try? c.decode(Bool.self, forKey: .value)
        valueText = try? c.decode(String.self, forKey: .value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(key, forKey: .key)
        if let b = valueBool { try c.encode(b, forKey: .value) }
        else if let t = valueText { try c.encode(t, forKey: .value) }
    }
}

/// 热补丁配置（module.json "hotfix" 键）
struct HotfixConfig: Codable {
    var patches: [HotfixPatch]?
    /// JS 补丁文件名（默认 hotfix.js）
    var script: String?

    var hasScript: Bool { true }  // script 字段存在即尝试加载 hotfix.js
    var scriptName: String { script ?? "hotfix.js" }
}

/// 二进制模块配置（module.json "binary" 键）
struct BinaryConfig: Codable {
    /// 相对模块目录的可执行文件路径（bin/alist）
    var executable: String
    /// 启动参数（相对路径会在启动时自动拼接模块目录）
    var args: [String]?
    /// WebUI 端口
    var port: Int?
    /// WebUI 路径（默认 /）
    var webPath: String?
    /// 是否随宿主自启动
    var autoStart: Bool?
}

struct EscapeModuleAction: Identifiable, Codable {
    let id: String
    let label: String
    var icon: String?
    let type: String            // v1: "signal"
    /// signal: 进程名（对 displayName / executablePath 做大小写不敏感包含匹配）
    var process: String?
    /// signal: "SIGKILL" | "SIGTERM" | "SIGSTOP" | "SIGCONT"
    var signal: String?
    /// 执行前确认文案；为空则直接执行
    var confirm: String?
    /// 超时秒数（预留）
    var timeoutSec: Int?
}

struct EscapeModule: Identifiable, Codable {
    /// 规范版本，固定 "escape.module.v1"
    let spec: String
    /// 模块唯一标识（反向域名）
    let id: String
    let name: String
    var icon: String?
    var accent: String?
    let version: String
    var versionCode: Int?
    var author: String?
    var description: String
    var notes: String?
    var category: String?
    var minHostVersion: String?
    /// v1.1：可选。zip 内相对目录名（须含 index.html）——
    /// 模块自带 WebView 界面（对齐 KernelSU 的 webroot 机制），
    /// 有此字段时模块卡片显示「打开」按钮，用内嵌 WKWebView 加载本地页。
    var webroot: String?
    /// v1.1：可选。热补丁配置——存在即要求官方签名（signature.sig）
    var hotfix: HotfixConfig?
    /// v1.1：可选。二进制模块——随宿主自启动的后台服务（如 alist）
    var binary: BinaryConfig?
    /// 二进制模块是否随宿主自启动（默认读 binary.autoStart）
    var autoStart: Bool?
    let actions: [EscapeModuleAction]

    /// 是否热补丁模块（导入时强制验签）
    var isHotfixModule: Bool { hotfix != nil }
    /// 是否二进制模块
    var isBinaryModule: Bool { binary != nil }

    /// 安装目录（内置原地模块指向 bundle）
    var installURL: URL {
        ModuleService.shared.installURL(for: id)
    }

    var accentColorName: String { accent ?? "blue" }
}

// MARK: - 服务

final class ModuleService {
    static let shared = ModuleService()

    /// 模块安装根目录：Documents/Modules
    let modulesRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/Modules", isDirectory: true)

    private init() {
        try? FileManager.default.createDirectory(at: modulesRoot, withIntermediateDirectories: true)
        bootstrapBundledModules()
    }

    // MARK: 内置模块首次安装

    /// 用户主动卸载过的模块 id（防止内置模块重启后自动回归）
    private static let uninstalledKey = "Module.uninstalled.ids"
    /// 覆盖安装检测锚点：主可执行文件的修改时间
    /// （每次安装/覆盖安装都会刷新，同版本覆盖安装也能检测到）
    private static let hostInstallDateKey = "Module.uninstalled.hostInstallDate"

    private var uninstalledIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.uninstalledKey) ?? [])
    }

    /// 首次启动时把 bundle 内置模块安装到 Documents/Modules。
    /// 幂等：目录已存在 或 用户曾主动卸载过 → 跳过。
    /// 覆盖安装新 IPA 后是否恢复内置模块（用户可关）
    private static let restoreOnUpgradeKey = "Module.restoreOnUpgrade"
    static var restoreOnUpgrade: Bool {
        get { UserDefaults.standard.object(forKey: restoreOnUpgradeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: restoreOnUpgradeKey) }
    }

    /// 内置且不落盘（bundle 原地加载）的二进制模块：id → bundle 内模块目录
    private var inPlaceBundled: [String: URL] = [:]

    /// 内置原地模块不可卸载
    func isInPlaceBundled(_ id: String) -> Bool { inPlaceBundled[id] != nil }

    /// 模块安装根：内置原地模块指向 bundle，其余在 Documents/Modules
    func installURL(for id: String) -> URL {
        if let url = inPlaceBundled[id] { return url }
        return modulesRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// 模块数据目录（始终可写，与二进制分离）：<modulesRoot>/<id>/data
    func dataURL(for id: String) -> URL {
        modulesRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("data", isDirectory: true)
    }

    private func bootstrapBundledModules() {        // 覆盖安装不清沙盒数据（UserDefaults 保留），卸载标记跨安装残留。
        // 检测锚点（双取最大）：bundle 目录 mtime + 可执行文件 mtime。
        // 注意 LC 场景：可执行文件 mtime 可能保留 IPA 内构建时间（同 IPA 覆盖不变），
        // 而 bundle 目录在安装搬运时 mtime 必然刷新——两者取 max 更稳。
        // 若两锚点都不变（同 IPA 且搬运未触目录），用户可在模块设置里点"恢复内置模块"手动回归。
        func modTime(_ url: URL) -> TimeInterval {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        let bundleMod = modTime(Bundle.main.bundleURL)
        // executableURL 是可选（URL?）——flatMap 解包后计算
        let execMod = Bundle.main.executableURL.flatMap { modTime($0) } ?? 0
        let installAnchor = max(bundleMod, execMod)
        let recordedDate = UserDefaults.standard.double(forKey: Self.hostInstallDateKey)
        if recordedDate == 0 {
            UserDefaults.standard.set(installAnchor, forKey: Self.hostInstallDateKey)
        } else if abs(recordedDate - installAnchor) > 1 {
            if Self.restoreOnUpgrade {
                UserDefaults.standard.removeObject(forKey: Self.uninstalledKey)
                print("[Module] 检测到覆盖安装（安装锚点变化），恢复内置模块")
            }
            UserDefaults.standard.set(installAnchor, forKey: Self.hostInstallDateKey)
        }

        guard let bundledURL = Bundle.main.url(forResource: "BundledModules", withExtension: nil) else { return }
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: bundledURL.path) else { return }
        let uninstalled = uninstalledIds
        for id in ids where !id.hasPrefix(".") {
            guard !uninstalled.contains(id) else { continue }
            let src = bundledURL.appendingPathComponent(id, isDirectory: true)
            let dest = modulesRoot.appendingPathComponent(id, isDirectory: true)
            // 二进制模块（binary 键）不落盘：直接从 bundle 原地加载（137MB 级 dylib
            // 拷贝进 Documents 白白吃磁盘写入配额）。数据目录仍在 modulesRoot/<id>/data。
            if let data = try? Data(contentsOf: src.appendingPathComponent("module.json")),
               let m = try? JSONDecoder().decode(EscapeModule.self, from: data),
               m.isBinaryModule {
                let dataRoot = modulesRoot.appendingPathComponent(id, isDirectory: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    // v0.3.70 时代的落盘副本：迁移 data/ 后删除副本（省 137MB）
                    do {
                        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
                        let oldData = dest.appendingPathComponent("data")
                        let newData = dataRoot.appendingPathComponent("data")
                        if FileManager.default.fileExists(atPath: oldData.path) &&
                            !FileManager.default.fileExists(atPath: newData.path) {
                            try FileManager.default.moveItem(at: oldData, to: newData)
                        }
                        try FileManager.default.removeItem(at: dest)
                        print("[Module] \(id) 已迁移为 bundle 原地加载（数据保留在 \(newData.path)）")
                    } catch {
                        print("[Module] \(id) 原地加载迁移失败（保留落盘副本）: \(error)")
                        continue
                    }
                } else {
                    try? FileManager.default.createDirectory(
                        at: dataRoot.appendingPathComponent("data"), withIntermediateDirectories: true)
                }
                inPlaceBundled[id] = src
                continue
            }
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: dest)
            print("[Module] 内置模块安装: \(id)")
        }

        // 启动钩子：热补丁聚合 + 二进制自启动（延迟 2s 避开启动高峰）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            HotfixService.shared.reload()
            BinaryModuleRunner.shared.autoStartAll()
        }
    }

    // MARK: 列举

    func listModules() -> [EscapeModule] {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: modulesRoot.path) else { return [] }
        var modules: [EscapeModule] = []
        var seen = Set<String>()
        for id in ids.sorted() where !id.hasPrefix(".") {
            let manifest = modulesRoot.appendingPathComponent(id).appendingPathComponent("module.json")
            guard let data = try? Data(contentsOf: manifest),
                  let m = try? JSONDecoder().decode(EscapeModule.self, from: data) else { continue }
            modules.append(m)
            seen.insert(id)
        }
        // 内置原地二进制模块（bundle 内，不落盘）
        for (id, url) in inPlaceBundled.sorted(by: { $0.key < $1.key }) where !seen.contains(id) {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("module.json")),
                  let m = try? JSONDecoder().decode(EscapeModule.self, from: data) else { continue }
            modules.append(m)
        }
        return modules
    }

    func module(id: String) -> EscapeModule? {
        listModules().first { $0.id == id }
    }

    // MARK: 导入 .zip

    /// 导入 .zip 模块。zip 内任意层级（含 modules/<id>/ 前缀、GitHub 源码 zip 的多层嵌套）均可识别
    /// module.json，并安装其所在目录的内容。spec = escape.module.v1。
    /// log：安装详情日志回调（KernelSU 风格安装界面逐行输出）。
    /// 返回解析后的模块；spec 不符 / 清单缺失会抛错。
    func importZip(at url: URL, log: ((String) -> Void)? = nil) throws -> EscapeModule {
        log?("- 导入模块：\(url.lastPathComponent)")
        let data = try Data(contentsOf: url)
        log?("- 读取 zip（\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))）")
        let entries: [ZipEntry]
        do {
            entries = try ZipContainer.open(container: data)
        } catch {
            throw ModuleError.badArchive("ZIP 解析失败：\(error.localizedDescription)")
        }
        log?("- 解析出 \(entries.count) 个条目")

        // 解压到临时目录
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("module-import-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var manifestData: Data?
        var manifestName: String?      // module.json 在 zip 内的完整路径（推导同目录 signature.sig / 安装根）
        var extractedFiles: [String: Data] = [:]   // 全部 regular 文件字节（签名校验用）
        for entry in entries {
            let name = entry.info.name
            // 跳过 macOS 垃圾与目录项
            if name.contains("__MACOSX") || name.hasPrefix(".") || name.contains("/.") { continue }
            switch entry.info.type {
            case .directory:
                try FileManager.default.createDirectory(
                    at: tmp.appendingPathComponent(name),
                    withIntermediateDirectories: true)
            case .regular:
                guard let d = entry.data else { continue }
                let dest = tmp.appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try d.write(to: dest)
                if name == "module.json" || name.hasSuffix("/module.json") {
                    manifestData = d
                    manifestName = name
                }
                extractedFiles[name] = d
            default:
                break
            }
        }

        // 校验清单
        guard let mData = manifestData,
              let module = try? JSONDecoder().decode(EscapeModule.self, from: mData) else {
            throw ModuleError.missingManifest("zip 内缺少合法的 module.json")
        }
        log?("- 清单：\(module.id) v\(module.version)（\(module.name)）")
        guard module.spec == "escape.module.v1" else {
            throw ModuleError.badSpec("规范版本不支持：\(module.spec)")
        }
        log?("- 规范 \(module.spec) ✓")

        // module.json 所在目录（"" 表示 zip 根）——signature.sig 必须与 module.json 同目录
        // 用纯字符串切分（NSString.deletingLastPathComponent 返回值斜杠语义不可靠，
        // 之前 dropLast() 掐掉真实字符导致 extractedRoot/签名 key 双双找错——v0.3.68 修复）
        let manifestDir: String
        if let mn = manifestName, let idx = mn.lastIndex(of: "/") {
            manifestDir = String(mn[...idx])          // 保留末尾 "/"，如 "modules/<id>/"
        } else {
            manifestDir = ""                          // zip 根
        }
        // 安装根 = module.json 所在目录（支持任意嵌套：modules/<id>/、module-esc-main/modules/<id>/ 均可）
        let extractedRoot = tmp.appendingPathComponent(
            manifestDir.isEmpty ? "." : String(manifestDir.dropLast()), isDirectory: true)

        // 热补丁 / 二进制模块必须携带官方签名（signature.sig = 对 module.json 的 ed25519 签名 base64 文本）
        if module.isHotfixModule || module.isBinaryModule {
            log?("- 热补丁/二进制模块：验证官方签名…")
            let sigB64 = extractedFiles[manifestDir + "signature.sig"]
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sigB64.isEmpty else {
                log?("- 签名文件查找 key：\(manifestDir)signature.sig")
                log?("- zip 内已知文件：\(extractedFiles.keys.sorted().joined(separator: ", "))")
                log!("! 签名缺失")
                throw ModuleError.badSpec("热补丁/二进制模块签名缺失——zip 内未找到 \(manifestDir)signature.sig")
            }
            guard HotfixService.verifySignature(manifestData: mData, signatureB64: sigB64) else {
                log!("! 签名校验失败（签名文件存在但与官方公钥不匹配）")
                throw ModuleError.badSpec("热补丁/二进制模块签名校验失败——仅接受 EscapeSpace 官方签名")
            }
            log?("- 签名验证 ✓")
        }

        guard !module.actions.isEmpty || module.isBinaryModule else {
            throw ModuleError.badSpec("模块未声明任何 action")
        }
        // 校验动作类型（v1 只支持 signal；未知类型拒绝导入，保证向前兼容的严格性）
        for action in module.actions where action.type != "signal" {
            throw ModuleError.badSpec("不支持的 action 类型：\(action.type)（本宿主仅支持 signal）")
        }

        // 安装：Modules/<id>/（同 id 覆盖升级）
        let dest = modulesRoot.appendingPathComponent(module.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
            log?("- 检测到旧版本，覆盖升级")
        }
        guard FileManager.default.fileExists(atPath: extractedRoot.appendingPathComponent("module.json").path) else {
            throw ModuleError.missingManifest("zip 内缺少合法的 module.json")
        }
        try FileManager.default.copyItem(at: extractedRoot, to: dest)
        log?("- 安装到 Documents/Modules/\(module.id) ✓")
        print("[Module] 导入成功: \(module.id) v\(module.version)")

        // 导入后钩子：热补丁聚合刷新 + 二进制模块自启动
        DispatchQueue.main.async {
            HotfixService.shared.reload()
            if module.isBinaryModule, module.autoStart == true || module.binary?.autoStart == true {
                BinaryModuleRunner.shared.start(module: module)
            }
        }
        return module
    }

    // MARK: 删除

    func delete(id: String) {
        guard inPlaceBundled[id] == nil else {
            print("[Module] \(id) 为内置原地模块，不可卸载")
            return
        }
        let dir = modulesRoot.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        // 若是内置模块，记录用户卸载意愿——重启后不再自动回归
        if Bundle.main.url(forResource: "BundledModules/\(id)/module.json", withExtension: nil) != nil {
            var ids = uninstalledIds
            ids.insert(id)
            UserDefaults.standard.set(Array(ids), forKey: Self.uninstalledKey)
        }
    }

    // MARK: 启用 / 禁用（.disabled 标记文件，不污染 manifest）

    func isEnabled(id: String) -> Bool {
        let marker = modulesRoot.appendingPathComponent(id).appendingPathComponent(".disabled")
        return !FileManager.default.fileExists(atPath: marker.path)
    }

    func setEnabled(id: String, _ enabled: Bool) {
        let marker = modulesRoot.appendingPathComponent(id).appendingPathComponent(".disabled")
        if enabled {
            try? FileManager.default.removeItem(at: marker)
        } else {
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        }
    }

    /// 手动恢复全部内置模块（清空卸载记录 + 重新安装缺失的）——双锚点都不变时的兜底
    func restoreBundledModules() {
        UserDefaults.standard.removeObject(forKey: Self.uninstalledKey)
        bootstrapBundledModules()
    }

    // MARK: WebView 支持（对齐 KernelSU webroot 机制）

    /// 模块 webroot 目录（须含 index.html）；未声明或目录缺失返回 nil。
    func webrootURL(for module: EscapeModule) -> URL? {
        guard let wr = module.webroot, !wr.isEmpty else { return nil }
        let dir = module.installURL.appendingPathComponent(wr, isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("index.html").path) else { return nil }
        return dir
    }

    // MARK: 执行动作（Rust FFI 管道）

    /// 执行 signal 动作：按进程名在设备进程列表中查找 PID，逐个下发信号。
    /// 返回人类可读的执行结果摘要。
    func run(action: EscapeModuleAction) throws -> String {
        guard action.type == "signal", let procName = action.process, !procName.isEmpty else {
            throw ModuleError.badAction("signal 动作缺少 process 字段")
        }
        let sig = parseSignal(action.signal)

        let entries = try ProcessManagerService.shared.listProcesses()
        let matched = entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(procName) ||
            $0.executablePath.localizedCaseInsensitiveContains(procName)
        }

        guard !matched.isEmpty else {
            throw ModuleError.processNotFound(
                "设备进程列表中未找到「\(procName)」（系统守护进程可能对宿主不可见）")
        }

        var killed: [String] = []
        var failed: [String] = []
        for entry in matched {
            do {
                try ProcessManagerService.shared.sendSignal(sig, toPID: Int(entry.pid))
                killed.append("\(entry.displayName)(\(entry.pid))")
            } catch {
                failed.append("\(entry.displayName): \(error.localizedDescription)")
            }
        }

        var summary = "已下发 \(sigName(sig)) → \(killed.count) 个进程"
        if !killed.isEmpty { summary += "：\(killed.joined(separator: "、"))" }
        if !failed.isEmpty { summary += "；失败 \(failed.count)：\(failed.joined(separator: "、"))" }
        return summary
    }

    private func parseSignal(_ s: String?) -> ProcessControlAction {
        // 宿主 sendSignal 支持三种信号；SIGTERM 按 terminate 语义映射到 SIGKILL
        switch (s ?? "SIGKILL").uppercased() {
        case "SIGSTOP": return .pause
        case "SIGCONT": return .resume
        case "SIGTERM", "SIGKILL": return .kill
        default: return .kill
        }
    }

    private func sigName(_ a: ProcessControlAction) -> String {
        switch a {
        case .kill: return "SIGKILL"
        case .pause: return "SIGSTOP"
        case .resume: return "SIGCONT"
        }
    }
}

// MARK: - 错误

enum ModuleError: LocalizedError {
    case badArchive(String)
    case missingManifest(String)
    case badSpec(String)
    case badAction(String)
    case processNotFound(String)

    var errorDescription: String? {
        switch self {
        case .badArchive(let m): return m
        case .missingManifest(let m): return m
        case .badSpec(let m): return m
        case .badAction(let m): return m
        case .processNotFound(let m): return m
        }
    }
}
