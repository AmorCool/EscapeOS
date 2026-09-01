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
    let actions: [EscapeModuleAction]

    /// 安装目录
    var installURL: URL {
        ModuleService.shared.modulesRoot.appendingPathComponent(id, isDirectory: true)
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

    private func bootstrapBundledModules() {
        // 覆盖安装不清沙盒数据（UserDefaults 保留），卸载标记跨安装残留。
        // 检测锚点：主可执行文件 contentModificationDate——每次安装（含同版本覆盖）必变。
        // 策略：检测到新安装且开关开 → 清空卸载记录，内置模块回归；开关关 → 维持卸载。
        let execMod = (Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey])
        })?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let recordedDate = UserDefaults.standard.double(forKey: Self.hostInstallDateKey)
        if recordedDate == 0 {
            UserDefaults.standard.set(execMod, forKey: Self.hostInstallDateKey)
        } else if abs(recordedDate - execMod) > 1 {
            if Self.restoreOnUpgrade {
                UserDefaults.standard.removeObject(forKey: Self.uninstalledKey)
                print("[Module] 检测到覆盖安装（可执行文件时间变化），恢复内置模块")
            }
            UserDefaults.standard.set(execMod, forKey: Self.hostInstallDateKey)
        }

        guard let bundledURL = Bundle.main.url(forResource: "BundledModules", withExtension: nil) else { return }
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: bundledURL.path) else { return }
        let uninstalled = uninstalledIds
        for id in ids where !id.hasPrefix(".") {
            guard !uninstalled.contains(id) else { continue }
            let dest = modulesRoot.appendingPathComponent(id, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            let src = bundledURL.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.copyItem(at: src, to: dest)
            print("[Module] 内置模块安装: \(id)")
        }
    }

    // MARK: 列举

    func listModules() -> [EscapeModule] {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: modulesRoot.path) else { return [] }
        var modules: [EscapeModule] = []
        for id in ids.sorted() where !id.hasPrefix(".") {
            let manifest = modulesRoot.appendingPathComponent(id).appendingPathComponent("module.json")
            guard let data = try? Data(contentsOf: manifest) else { continue }
            if let m = try? JSONDecoder().decode(EscapeModule.self, from: data) {
                modules.append(m)
            }
        }
        return modules
    }

    func module(id: String) -> EscapeModule? {
        listModules().first { $0.id == id }
    }

    // MARK: 导入 .zip

    /// 导入 .zip 模块。zip 根目录必须包含 module.json（spec = escape.module.v1）。
    /// 返回解析后的模块；spec 不符 / 清单缺失会抛错。
    func importZip(at url: URL) throws -> EscapeModule {
        let data = try Data(contentsOf: url)
        let entries: [ZipEntry]
        do {
            entries = try ZipContainer.open(container: data)
        } catch {
            throw ModuleError.badArchive("ZIP 解析失败：\(error.localizedDescription)")
        }

        // 解压到临时目录
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("module-import-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var manifestData: Data?
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
                }
            default:
                break
            }
        }

        // 校验清单
        guard let mData = manifestData,
              let module = try? JSONDecoder().decode(EscapeModule.self, from: mData) else {
            throw ModuleError.missingManifest("zip 根目录缺少合法的 module.json")
        }
        guard module.spec == "escape.module.v1" else {
            throw ModuleError.badSpec("规范版本不支持：\(module.spec)")
        }
        guard !module.actions.isEmpty else {
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
        }
        // 如果 zip 内容在子目录里（module.json 在 <root>/<something>/module.json），
        // 找到包含 module.json 的层级整体拷贝
        let contentRoot: URL
        if FileManager.default.fileExists(atPath: tmp.appendingPathComponent("module.json").path) {
            contentRoot = tmp
        } else if let sub = try? FileManager.default.contentsOfDirectory(atPath: tmp.path).first(where: {
            FileManager.default.fileExists(atPath: tmp.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("module.json").path)
        }) {
            contentRoot = tmp.appendingPathComponent(sub, isDirectory: true)
        } else {
            throw ModuleError.missingManifest("zip 根目录缺少合法的 module.json")
        }
        try FileManager.default.copyItem(at: contentRoot, to: dest)
        print("[Module] 导入成功: \(module.id) v\(module.version)")
        return module
    }

    // MARK: 删除

    func delete(id: String) {
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
