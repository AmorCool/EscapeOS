//
//  HostCapabilityService.swift
//  EscapeSpace
//
//  v0.3.481：宿主能力接口（escape.host.v1）—— 模块**反向调用宿主**的唯一通道.
//
//  ## 为什么需要它
//  在此之前模块只能「被宿主调用」（signal / bridge），不能反向调用宿主能力。
//  后果是任何需要「沙盒外读写 / 改系统设置 / 枚举进程」的模块，都得自己把整套
//  漏洞利用重写一遍 —— 既是重复劳动，也是模块之间耦合的根源。
//
//  有了这层接口，模块只说「我要 fs.read」，由宿主决定底层怎么实现；
//  将来底层换了，模块**零改动**. 加新能力也只需要改这一个文件.
//
//  ## 两条调用路径（都汇到本文件的 `call`）
//  · **外部 dylib 模块**（C/Go）：宿主加载时把 `EscapeHostAPI` 函数表指针交给模块的
//    `escape_module_init`（见 `BinaryModuleRunner.startBinaryModule`），模块拿到
//    `call` 函数指针后调用. 这条路径**刻意不用 dlsym 宿主符号** —— 主可执行文件的
//    符号不保证对 `dlsym(RTLD_DEFAULT)` 可见（本仓库自己就是因为这个才写了
//    `uloader_symbols_with_suffix` 去读符号表）.
//  · **原生 SwiftUI 模块界面**：视图是**编译进宿主的 Swift 代码**，直接调
//    `HostCapabilityService.call(...)`，根本不需要 C ABI.
//
//  ## 调用线程
//  `call` 是**同步**的，有些能力会真的连设备（一次可能十几秒）.
//  **调用方必须在后台线程调用**，主线程调用会卡住界面.
//

import Foundation
import UserNotifications

// MARK: - 交给模块的 C 函数表

/// 宿主交给模块的 C 函数表.
///
/// ## 布局约定（模块侧要声明一份**完全一致**的 struct）
/// 全部字段按声明顺序紧凑排列，指针/整数都是 8 字节或 4 字节，总大小 48 字节：
///
/// | 偏移 | 字段            | 大小 |
/// |------|-----------------|------|
/// | 0    | `abiVersion`    | 4    |
/// | 4    | `structSize`    | 4    |
/// | 8    | `call`          | 8    |
/// | 16   | `freeString`    | 8    |
/// | 24   | `hostSymbol`    | 8    |
/// | 32   | `moduleDataDir` | 8    |
/// | 40   | `moduleDir`     | 8    |
///
/// 模块应先读 `abiVersion` / `structSize` 再决定是否使用 —— 宿主将来加字段时
/// 老模块仍能按老偏移安全读取.
///
/// ## 这里为什么不写 `@frozen`
/// `@frozen` 对非 public 类型是多余的（本类型只在 app 内部使用，模块侧是自己
/// 声明同布局的 struct，不走 Swift ABI），且会在部分 Swift 版本上产生
/// 「attribute only applies to public types」警告. 布局靠上面的约定 + 字段
/// 声明顺序保证（Swift 对 stored property 保证声明顺序）.
struct EscapeHostAPI {
    /// 接口版本（当前 1）
    var abiVersion: UInt32
    /// 本 struct 的字节大小（模块用它做版本兼容判断）
    var structSize: UInt32
    /// 核心分发器：capability + jsonArgs → outJson（调用方负责 free）
    var call: @convention(c) (UnsafePointer<CChar>?,
                              UnsafePointer<CChar>?,
                              UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    /// 释放宿主返回的字符串
    var freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    /// 拿宿主任意符号（逃生口；返回 dlopen 句柄，调用方自行 cast）
    var hostSymbol: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    /// 当前模块的数据目录（strdup，调用方负责 free）
    var moduleDataDir: @convention(c) () -> UnsafeMutablePointer<CChar>?
    /// 当前模块的安装目录（strdup，调用方负责 free）
    var moduleDir: @convention(c) () -> UnsafeMutablePointer<CChar>?
}

/// 便利入口：模块愿意 `dlsym(RTLD_DEFAULT, "escape_host_call")` 时用这个.
///
/// 注意这条路径**不保证可用**（主可执行文件符号不一定导出），主路径是
/// `escape_module_init` 拿函数表. 这里只是顺手提供一个，能用就用.
///
/// - Parameters:
///   - capability: 能力名（如 `fs.read`）
///   - jsonArgs: JSON 对象字符串；不需要参数时传 `{}` 或 nil
///   - outJson: 输出 JSON 字符串（`strdup` 分配，调用方用 `escape_host_free` 释放）
/// - Returns: 0 成功；非 0 失败（失败时 `outJson` 里也有 `{"ok":false,"error":...}`）
@_cdecl("escape_host_call")
func escape_host_call(_ capability: UnsafePointer<CChar>?,
                      _ jsonArgs: UnsafePointer<CChar>?,
                      _ outJson: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let cap = capability.map { String(cString: $0) } ?? ""
    let args = jsonArgs.map { String(cString: $0) } ?? "{}"
    let (rc, json) = HostCapabilityService.call(capability: cap, jsonArgs: args)
    if let outJson { outJson.pointee = strdup(json) }
    return rc
}

/// 释放宿主返回的字符串（C 侧便利入口）
@_cdecl("escape_host_free")
func escape_host_free(_ p: UnsafeMutablePointer<CChar>?) {
    if let p { free(p) }
}

// MARK: - 服务

/// 宿主能力服务（纯静态，无实例）.
///
/// **不做 MainActor 隔离**：模块在**非主线程**调用它（有些能力一次要十几秒，主线程
/// 调用会卡界面）. 内部若需要主线程资源，用 `runOnMain` 显式跳一次.
enum HostCapabilityService {

    /// 接口版本
    static let abiVersion: UInt32 = 1

    /// 本机支持的宿主能力清单.
    ///
    /// ⚠️ `EscapeModule.missingCapabilities` 依赖这个符号（`static let` / `[String]`
    /// 的签名不能改）；模块仓库的 `validate.py` 里 `KNOWN_CAPABILITIES` 也对应这一份，
    /// **两边必须同步改**.
    static let capabilityList: [String] = [
        "host.version",
        "host.capabilities",
        "fs.read",
        "fs.write",
        "fs.delete",
        "fs.exists",
        "fs.list",
        "apps.lookup",
        "afc.list",
        "afc.stat",
        "afc.read",
        "afc.write",
        "afc.delete",
        "afc.mkdir",
        "proc.list",
        "proc.signal",
        "notify.post",
    ]

    // MARK: 当前模块上下文（供 @convention(c) 闭包读取）

    /// 当前正在加载的模块上下文.
    ///
    /// 为什么需要：`@convention(c)` 闭包**不能捕获上下文**，所以 `moduleDataDir` /
    /// `moduleDir` 两个闭包只能从全局槽位读. 同一时刻只加载一个模块，单槽位够用.
    private final class ModuleContext: @unchecked Sendable {
        let dataDir: String
        let moduleDir: String
        init(dataDir: String, moduleDir: String) {
            self.dataDir = dataDir
            self.moduleDir = moduleDir
        }
    }

    /// nonisolated(unsafe)：访问全部经 `contextLock` 保护，实际无竞争
    nonisolated(unsafe) private static var context: ModuleContext?
    private static let contextLock = NSLock()

    private static func setContext(_ ctx: ModuleContext) {
        contextLock.lock()
        context = ctx
        contextLock.unlock()
    }

    private static func currentDataDirCString() -> UnsafeMutablePointer<CChar>? {
        contextLock.lock()
        let dir = context?.dataDir
        contextLock.unlock()
        guard let dir else { return nil }
        return strdup(dir)
    }

    private static func currentModuleDirCString() -> UnsafeMutablePointer<CChar>? {
        contextLock.lock()
        let dir = context?.moduleDir
        contextLock.unlock()
        guard let dir else { return nil }
        return strdup(dir)
    }

    // MARK: 构造函数表

    /// 构造交给模块的函数表（同时把模块上下文记进全局槽位）.
    static func makeAPI(moduleDataDir: String, moduleDir: String) -> EscapeHostAPI {
        setContext(ModuleContext(dataDir: moduleDataDir, moduleDir: moduleDir))
        return EscapeHostAPI(
            abiVersion: abiVersion,
            structSize: UInt32(MemoryLayout<EscapeHostAPI>.size),
            call: { cap, args, out in
                let capability = cap.map { String(cString: $0) } ?? ""
                let jsonArgs = args.map { String(cString: $0) } ?? "{}"
                let (rc, json) = HostCapabilityService.call(capability: capability,
                                                           jsonArgs: jsonArgs)
                if let out { out.pointee = strdup(json) }
                return rc
            },
            freeString: { p in if let p { free(p) } },
            hostSymbol: { name in
                guard let name else { return nil }
                // RTLD_DEFAULT = -2（与仓库其它处一致）
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), String(cString: name))
            },
            moduleDataDir: { HostCapabilityService.currentDataDirCString() },
            moduleDir: { HostCapabilityService.currentModuleDirCString() }
        )
    }

    /// 释放字符串（Swift 侧便利入口）
    static func freeString(_ p: UnsafeMutablePointer<CChar>?) {
        if let p { free(p) }
    }

    // MARK: - 分发器

    /// 核心分发：能力名 + JSON 入参 → (rc, JSON 结果).
    ///
    /// - Returns: `(0, json)` 成功；`(非 0, json)` 失败，且 json 里必有 `error` 字段.
    ///
    /// **所有失败都如实返回 `error`，不吞、不粉饰成成功** —— 上层 UI 与模块
    /// 都要能看见「哪一步断的」.
    static func call(capability: String, jsonArgs: String) -> (Int32, String) {
        // 记一笔调用日志（落盘，SSH `caplog` 可读）—— 见 appendCallLog 的注释说明
        // 为什么在宿主侧统一记、而不是让每个模块自己记.
        let started = Date()
        let result = dispatch(capability: capability, jsonArgs: jsonArgs)
        appendCallLog(capability: capability,
                      jsonArgs: jsonArgs,
                      result: result.1,
                      ok: result.0 == 0,
                      elapsedMS: Int(Date().timeIntervalSince(started) * 1000))
        return result
    }

    /// 能力分发（真正的 switch）.
    ///
    /// 与 `call` 分开是因为 `call` 要包一层日志 —— 直接调 `dispatch` 可以跳过日志，
    /// 但**不要在别处调它**，否则排障时会出现「日志缺一笔」这种最难查的情况.
    private static func dispatch(capability: String, jsonArgs: String) -> (Int32, String) {
        let args = parseArgs(jsonArgs)
        switch capability {
        case "host.version":          return hostVersion()
        case "host.capabilities":     return hostCapabilities()
        case "fs.read":               return fsRead(args)
        case "fs.write":              return fsWrite(args)
        case "fs.delete":             return fsDelete(args)
        case "fs.exists":             return fsExists(args)
        case "fs.list":               return fsList(args)
        case "apps.lookup":           return appsLookup(args)
        case "afc.list":              return afcList(args)
        case "afc.stat":              return afcStat(args)
        case "afc.read":              return afcRead(args)
        case "afc.write":             return afcWrite(args)
        case "afc.delete":            return afcDelete(args)
        case "afc.mkdir":             return afcMkdir(args)
        case "proc.list":             return procList()
        case "proc.signal":           return procSignal(args)
        case "notify.post":           return notifyPost(args)
        default:
            return fail("未知能力「\(capability)」",
                        extra: ["supported": capabilityList])
        }
    }

    // MARK: - host.*

    private static func hostVersion() -> (Int32, String) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return ok(["version": version, "build": build])
    }

    private static func hostCapabilities() -> (Int32, String) {
        ok(["abi": Int(abiVersion), "list": capabilityList])
    }

    // MARK: - fs.*

    /// 路径是否在 App 沙盒内（沙盒内直接用 FileManager，不需要漏洞利用）
    private static func isInSandbox(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/")
    }

    /// 按 `encoding` 把字节编码成 JSON 可放的字符串（默认 base64）
    private static func encode(_ data: Data, encoding: String) -> String? {
        if encoding == "utf8" { return String(data: data, encoding: .utf8) }
        return data.base64EncodedString()
    }

    /// 把 JSON 里的 data 字段解回字节
    private static func decode(_ text: String, encoding: String) -> Data? {
        if encoding == "utf8" { return text.data(using: .utf8) }
        return Data(base64Encoded: text)
    }

    private static func fsRead(_ args: [String: Any]) -> (Int32, String) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("fs.read 缺少 path")
        }
        let encoding = (args["encoding"] as? String) ?? "base64"
        guard encoding == "base64" || encoding == "utf8" else {
            return fail("fs.read 的 encoding 只支持 base64 / utf8")
        }

        if isInSandbox(path) {
            guard let data = FileManager.default.contents(atPath: path) else {
                return fail("读失败（沙盒内路径不存在或不可读）：\(path)", extra: ["via": "direct"])
            }
            guard let text = encode(data, encoding: encoding) else {
                return fail("读到了 \(data.count) 字节但按 \(encoding) 编码失败（可能是二进制）",
                            extra: ["via": "direct", "size": data.count])
            }
            return ok(["data": text, "size": data.count, "via": "direct"])
        }

        // 沙盒外**没有**可用原语了：宿主唯一能碰沙盒外的机制是 airlift 漏洞利用，
        // 而它已整体移除（用户 2026-09-25 决定不再使用）。如实报错，不假装知道.
        return fail(
            "fs.read 只支持 App 沙盒内路径：沙盒外的读取原语（airlift）已从宿主移除。",
            extra: ["via": "none"])
    }

    private static func fsWrite(_ args: [String: Any]) -> (Int32, String) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("fs.write 缺少 path")
        }
        guard let text = args["data"] as? String else {
            return fail("fs.write 缺少 data")
        }
        let encoding = (args["encoding"] as? String) ?? "base64"
        guard encoding == "base64" || encoding == "utf8" else {
            return fail("fs.write 的 encoding 只支持 base64 / utf8")
        }
        guard let data = decode(text, encoding: encoding) else {
            return fail("data 按 \(encoding) 解码失败")
        }

        // 可选：写前把原内容备份到 App 沙盒（沙盒外覆盖前留一条后路）
        var backupPath: String?
        if (args["backup"] as? Bool) == true {
            if let old = FileManager.default.contents(atPath: path) {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("CapBackup", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let url = dir.appendingPathComponent("\(path.replacingOccurrences(of: "/", with: "_"))-\(stamp).bak")
                if (try? old.write(to: url)) != nil { backupPath = url.path }
            }
        }

        if isInSandbox(path) {
            do {
                try data.write(to: URL(fileURLWithPath: path))
                var extra: [String: Any] = ["size": data.count, "via": "direct"]
                if let backupPath { extra["backup"] = backupPath }
                return ok(extra)
            } catch {
                return fail("写失败（沙盒内）：\(error.localizedDescription)",
                            extra: ["via": "direct"])
            }
        }

        // 沙盒外**没有**可用原语了（见 `fsRead`）.
        return fail(
            "fs.write 只支持 App 沙盒内路径：沙盒外的写入原语（airlift）已从宿主移除。",
            extra: ["via": "none"])
    }

    private static func fsDelete(_ args: [String: Any]) -> (Int32, String) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("fs.delete 缺少 path")
        }
        if isInSandbox(path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                return ok(["via": "direct"])
            } catch {
                return fail("删除失败（沙盒内）：\(error.localizedDescription)", extra: ["via": "direct"])
            }
        }
        // 沙盒外**没有**可用原语了（见 `fsRead`）.
        return fail(
            "fs.delete 只支持 App 沙盒内路径：沙盒外的删除原语（airlift）已从宿主移除。",
            extra: ["via": "none"])
    }

    private static func fsExists(_ args: [String: Any]) -> (Int32, String) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("fs.exists 缺少 path")
        }
        if isInSandbox(path) {
            return ok(["exists": FileManager.default.fileExists(atPath: path), "via": "direct"])
        }
        // 宿主没有沙盒外「只 stat 不搬动」的原语（airlift 已移除），如实报错.
        return fail(
            "fs.exists 只支持 App 沙盒内路径：沙盒外的查询原语已从宿主移除。",
            extra: ["via": "none"])
    }

    private static func fsList(_ args: [String: Any]) -> (Int32, String) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("fs.list 缺少 path")
        }
        guard isInSandbox(path) else {
            // 宿主没有沙盒外目录枚举原语，如实报错.
            return fail(
                "fs.list 只支持 App 沙盒内路径：沙盒外的枚举原语已从宿主移除。",
                extra: ["via": "none"])
        }
        let url = URL(fileURLWithPath: path)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []) else {
            return fail("列目录失败（不存在或不可读）：\(path)", extra: ["via": "direct"])
        }
        let entries: [[String: Any]] = items.map { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            var entry: [String: Any] = [
                "name": item.lastPathComponent,
                "isDir": values?.isDirectory ?? false,
            ]
            if let size = values?.fileSize { entry["size"] = size }
            if let mtime = values?.contentModificationDate {
                entry["mtime"] = ISO8601DateFormatter().string(from: mtime)
            }
            return entry
        }
        return ok(["entries": entries, "count": entries.count, "via": "direct"])
    }

    /// 解析 plist（binary 与 XML 都能解）.

    // MARK: - apps.lookup（按 bundle id 查 App 容器路径）

    /// `apps.lookup` —— 列已安装应用，**带 App 数据容器路径**（v0.3.497 新增）.
    ///
    /// ## 为什么需要它
    /// App 容器的路径里带一串随机 UUID
    /// （`/var/containers/Bundle/Application/<UUID>/`）—— 靠人猜不出来。
    /// 这个能力走 `installation_proxy`（**不是漏洞**），
    /// 直接把 `Container`（数据容器）/ 包路径给出来，用于定位 App 容器。
    ///
    /// ## 参数
    /// - `bundleId`：可选；给了就只返回那一个 App（不区分大小写）
    /// - `includeSystem`：是否包含系统应用（默认 `false` —— 系统应用通常没有数据容器）
    private static func appsLookup(_ args: [String: Any]) -> (Int32, String) {
        let wanted = (args["bundleId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let includeSystem = (args["includeSystem"] as? Bool) ?? false
        do {
            let all = try AppDiscovery().fetchInstalledApps()
            var rows: [[String: Any]] = []
            for app in all {
                if !includeSystem && app.isSystem { continue }
                if let wanted, !wanted.isEmpty,
                   app.bundleIdentifier.lowercased() != wanted { continue }
                var row: [String: Any] = [
                    "bundleId": app.bundleIdentifier,
                    "name": app.name,
                    "container": app.containerPath,
                    "type": app.applicationType ?? "",
                    "isSystem": app.isSystem,
                ]
                if let version = app.version { row["version"] = version }
                rows.append(row)
            }
            if let wanted, !wanted.isEmpty, rows.isEmpty {
                return fail("设备上没有这个 bundle id（或它是系统应用且未开 includeSystem）：\(wanted)",
                            extra: ["bundleId": wanted, "count": 0, "via": "installation_proxy"])
            }
            return ok(["apps": rows, "count": rows.count, "via": "installation_proxy"])
        } catch {
            return fail("枚举已安装应用失败：\(error.localizedDescription)",
                        extra: ["via": "installation_proxy"])
        }
    }

    // MARK: - proc.*

    /// 进程接口不需要跳主线程：`ProcessManagerService` 是 `Sendable` 的非 MainActor
    /// 类型，内部自己用 `operationQueue` 串行化（隧道是设备侧单例资源）.
    private static func procList() -> (Int32, String) {
        do {
            let entries = try ProcessManagerService.shared.listProcesses()
            let list: [[String: Any]] = entries.map { entry in
                var item: [String: Any] = [
                    "pid": entry.pid,
                    "name": entry.displayName,
                    "path": entry.executablePath,
                ]
                if let mem = entry.memoryBytes { item["memoryBytes"] = mem }
                return item
            }
            return ok(["processes": list, "count": list.count])
        } catch {
            return fail("枚举进程失败：\(error.localizedDescription)")
        }
    }

    private static func procSignal(_ args: [String: Any]) -> (Int32, String) {
        guard let name = args["process"] as? String, !name.isEmpty else {
            return fail("proc.signal 缺少 process（进程名）")
        }
        let rawSignal = ((args["signal"] as? String) ?? "SIGKILL").uppercased()
        let action: ProcessControlAction
        switch rawSignal {
        case "SIGSTOP": action = .pause
        case "SIGCONT": action = .resume
        case "SIGKILL", "SIGTERM": action = .kill
        default:
            return fail("不认识的 signal「\(rawSignal)」（仅 SIGKILL / SIGSTOP / SIGCONT）")
        }

        let entries: [ProcessEntry]
        do {
            entries = try ProcessManagerService.shared.listProcesses()
        } catch {
            return fail("枚举进程失败：\(error.localizedDescription)")
        }
        // 与宿主 signal 动作一致：对 displayName / executablePath 做大小写不敏感包含匹配
        let matched = entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(name)
                || $0.executablePath.localizedCaseInsensitiveContains(name)
        }
        guard !matched.isEmpty else {
            return fail("进程列表里没找到「\(name)」（系统守护进程可能对宿主不可见）")
        }

        var affected: [String] = []
        var failed: [String] = []
        for entry in matched {
            do {
                try ProcessManagerService.shared.sendSignal(action, toPID: entry.pid)
                affected.append("\(entry.displayName)(\(entry.pid))")
            } catch {
                failed.append("\(entry.displayName)(\(entry.pid)): \(error.localizedDescription)")
            }
        }
        return ok(["affected": affected, "failed": failed, "signal": rawSignal])
    }

    // MARK: - notify.post

    private static func notifyPost(_ args: [String: Any]) -> (Int32, String) {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return fail("notify.post 缺少 title")
        }
        let body = (args["body"] as? String) ?? ""

        guard notificationAuthorized() else {
            return fail("通知未授权：请在系统设置里允许 EscapeSpace 发送通知后重试")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)

        // UNUserNotificationCenter 的回调是异步的，而本接口是同步的 ⇒ 用信号量等
        // （带超时，避免回调不来时把调用线程永久挂住）
        final class Box: @unchecked Sendable { var error: String? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { error in
            box.error = error?.localizedDescription
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            return fail("发送通知超时（5 秒未回调）")
        }
        if let error = box.error {
            return fail("发送通知失败：\(error)")
        }
        return ok()
    }

    private static func notificationAuthorized(timeout: TimeInterval = 3) -> Bool {
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            box.value = (settings.authorizationStatus == .authorized
                         || settings.authorizationStatus == .provisional)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return false }
        return box.value
    }

    // MARK: - afc.*（AFC 文件操作，支持多个根）

    /// `afc.*` 能用的根 —— 每个根是**一条不同的 RSD 服务会话**。
    ///
    /// ## 为什么只有两个（如实说清，别让模块作者以为能浏览整个 /var）
    /// RSD 服务表（64 个服务）里，**能枚举目录**的只有这两条：
    ///
    /// | 根 | 服务 | 覆盖 |
    /// |---|---|---|
    /// | `media` | `com.apple.afc` | `/var/mobile/Media`（DCIM / Downloads / Books / 各 App 共享文件） |
    /// | `crash` | `com.apple.crashreportcopymobile` | `/var/mobile/Library/Logs/CrashReporter` |
    ///
    /// **`/var` 根、`/var/mobile/Library`、其他 App 容器都列不出来** ——
    /// 没有任何服务把根设在它们上面；`house_arrest` 的 `VendContainer` 在 iOS 27 实测被拒。
    ///
    /// ## 为什么这条路稳
    /// 两条服务都在同一条 RSD 隧道上（设备广播服务 → host 直连端口）。
    /// **不依赖 bad_query，也不依赖 MHA** —— 不随那两条被修而失效。
    enum AfcRoot: String {
        case media
        case crash

        var displayPath: String {
            switch self {
            case .media: return "/var/mobile/Media"
            case .crash: return "/var/mobile/Library/Logs/CrashReporter"
            }
        }

        var serviceName: String {
            switch self {
            case .media: return "com.apple.afc"
            case .crash: return "com.apple.crashreportcopymobile"
            }
        }

        static func parse(_ raw: String?) -> AfcRoot {
            switch (raw ?? "").lowercased() {
            case "crash", "crashreporter", "crashreport", "crashlog", "logs":
                return .crash
            default:
                return .media
            }
        }
    }

    /// 在指定根上执行一段 AFC 操作（复用一条连接）。
    private static func withAfcRoot<T>(_ root: AfcRoot,
                                       _ body: (OpaquePointer) throws -> T) throws -> T {
        switch root {
        case .media:
            // AFCService 自己会开/关连接，用 batch 复用同一条
            return try AFCService.shared.batch { try body($0) }
        case .crash:
            // crashreport 是另一条服务会话，只有 CrashLogService 知道怎么连
            return try CrashLogService.shared.withAfc { try body($0) }
        }
    }

    /// 规范化成 AFC 口径（去掉前导/尾随 `/`）.
    ///
    /// ## ▸ v0.3.501：**不再拒绝 `..`**
    /// 原来见到 `..` 就直接拒，理由是「根就是边界」。但**真正的边界是 AFC 服务自己的沙盒**
    /// （`com.apple.afc` 只被授权 `/var/mobile/Media`；`com.apple.crashreportcopymobile`
    /// 只被授权 `/var/mobile/Library/Logs/CrashReporter`）—— 设备侧会独立做这个检查。
    /// 我们这里的字符串过滤既挡不住什么，又挡住了一个**关键实验**：
    /// 「crash 那个根的沙盒到底覆盖多大」—— 用 `..` 探一次就知道。
    ///
    /// ⇒ 现在放行 `..`，把判定权交回设备侧（越界会得到 `Afc(PermDenied)`）。
    /// 仍然拒绝 NUL（那是真会造成 C 字符串截断的东西）。
    private static func afcPath(_ raw: String?) -> String? {
        var p = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.unicodeScalars.contains(where: { $0.value == 0 }) { return nil }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    /// 统一的「根 + 路径」解析：返回 (root, path) 或报错
    private static func afcResolve(_ args: [String: Any],
                                   needFile: Bool) -> (AfcRoot, String, (Int32, String)?) {
        let root = AfcRoot.parse(args["root"] as? String)
        guard let path = afcPath(args["path"] as? String) else {
            return (root, "/", fail("path 非法（不接受 `..`）"))
        }
        if needFile && path == "/" {
            return (root, path, fail("需要 path（不能是根目录）"))
        }
        return (root, path, nil)
    }

    private static func afcList(_ args: [String: Any]) -> (Int32, String) {
        let (root, path, err) = afcResolve(args, needFile: false)
        if let err { return err }
        do {
            let items = try withAfcRoot(root) { try AFCService.listDirectory(client: $0, path: path) }
            let entries: [[String: Any]] = items.map { item in
                var entry: [String: Any] = [
                    "name": item.name,
                    "path": item.path,
                    "isDir": item.isDirectory,
                    "size": Int(item.size),
                ]
                if let modified = item.modified {
                    entry["mtime"] = ISO8601DateFormatter().string(from: modified)
                }
                return entry
            }
            return ok(["root": root.rawValue, "rootPath": root.displayPath,
                       "service": root.serviceName, "path": path,
                       "entries": entries, "count": entries.count])
        } catch {
            return fail("列目录失败：\(error.localizedDescription)",
                        extra: ["root": root.rawValue, "rootPath": root.displayPath,
                                "path": path])
        }
    }

    /// `afc.stat` —— 查**单条路径**的元数据（v0.3.501 新增）.
    ///
    /// ## 为什么它值得单独开一个能力（真机实测 2026-09-20）
    /// `afc_get_file_info` 会**跟随中间那一段 symlink**，而且**不受 AFC 沙盒限制** ——
    /// 同一条路径上 `afc.read` / `afc.write` / `afc.list` 全是 `Afc(PermDenied)`，
    /// 只有 stat 能过。于是：在 Media 里放一条指向**目标父目录**的 symlink，
    /// 就能对**任意路径**问「在不在 / 多大 / 是文件还是目录」。
    ///
    /// ## 局限（诚实写出来）
    /// 只能**点查**（给定名字），**不能列目录**。
    ///
    /// 参数：`path`（相对当前根的路径，可含 `..`）、`root`（`media` / `crash`）
    private static func afcStat(_ args: [String: Any]) -> (Int32, String) {
        let (root, path, err) = afcResolve(args, needFile: true)
        if let err { return err }
        do {
            let result = try withAfcRoot(root) { client in
                AFCService.statFile(client: client, path: path)
            }
            let extra: [String: Any] = [
                "root": root.rawValue,
                "rootPath": root.displayPath,
                "path": path,
                "exists": result.exists,
                "isDir": result.isDirectory,
                "size": result.size,
                "ifmt": result.ifmt ?? "",
                "linkTarget": result.linkTarget ?? "",
                "describe": result.describe,
            ]
            return result.exists ? ok(extra)
                                 : fail("这条路径取不到元数据（不存在，或被沙盒挡住）："
                                        + result.describe, extra: extra)
        } catch {
            return fail("stat 失败：\(error.localizedDescription)",
                        extra: ["root": root.rawValue, "path": path, "exists": false])
        }
    }

    private static func afcRead(_ args: [String: Any]) -> (Int32, String) {
        let (root, path, err) = afcResolve(args, needFile: true)
        if let err { return err }
        let encoding = (args["encoding"] as? String) ?? "base64"
        guard encoding == "base64" || encoding == "utf8" else {
            return fail("afc.read 的 encoding 只支持 base64 / utf8")
        }
        do {
            let data = try withAfcRoot(root) { try AFCService.readFile(client: $0, path: path) }
            guard let text = encode(data, encoding: encoding) else {
                return fail("读到了 \(data.count) 字节但按 \(encoding) 编码失败（可能是二进制）",
                            extra: ["size": data.count])
            }
            return ok(["root": root.rawValue, "path": path, "data": text, "size": data.count])
        } catch {
            return fail("读失败：\(error.localizedDescription)",
                        extra: ["root": root.rawValue, "path": path])
        }
    }

    private static func afcWrite(_ args: [String: Any]) -> (Int32, String) {
        let (root, path, err) = afcResolve(args, needFile: true)
        if let err { return err }
        guard let text = args["data"] as? String else { return fail("afc.write 缺少 data") }
        let encoding = (args["encoding"] as? String) ?? "base64"
        guard encoding == "base64" || encoding == "utf8" else {
            return fail("afc.write 的 encoding 只支持 base64 / utf8")
        }
        guard let data = decode(text, encoding: encoding) else {
            return fail("data 按 \(encoding) 解码失败")
        }
        do {
            try withAfcRoot(root) { try AFCService.writeFile(client: $0, data: data, to: path) }
            return ok(["root": root.rawValue, "path": path, "size": data.count])
        } catch {
            return fail("写失败：\(error.localizedDescription)",
                        extra: ["root": root.rawValue, "path": path])
        }
    }

    private static func afcDelete(_ args: [String: Any]) -> (Int32, String) {
        let (root, path, err) = afcResolve(args, needFile: true)
        if let err { return err }
        let recursive = (args["recursive"] as? Bool) ?? false
        do {
            try withAfcRoot(root) {
                try AFCService.removePath(client: $0, path: path, includingContents: recursive)
            }
            return ok(["root": root.rawValue, "path": path, "recursive": recursive])
        } catch {
            let text = error.localizedDescription
            // ▸ 如实区分失败原因 —— 原来一律提示「目录非空需要 recursive」，
            //   而真机上最常见的是**权限**（例：CrashReporter 里 `sysdiagnose` 归档
            //   的内容由系统账号创建，AFC 以 mobile 身份删不动）。
            //   误导性的 hint 会让人去改 recursive，白试一轮。
            if text.contains("PermDenied") {
                return fail("删除被拒（权限）：该条目不属于当前身份，"
                            + "AFC 无权删除它。",
                            extra: ["root": root.rawValue, "path": path,
                                    "note": "这类条目通常由系统账号创建（如 sysdiagnose 归档内容），"
                                          + "读/列通常仍可用，但删/写不行。"])
            }
            return fail("删除失败：\(text)",
                        extra: ["root": root.rawValue, "path": path,
                                "hint": recursive ? "已用 recursive，仍失败"
                                                  : "目录非空时需要 recursive: true"])
        }
    }

    private static func afcMkdir(_ args: [String: Any]) -> (Int32, String) {
        let (root, path, err) = afcResolve(args, needFile: true)
        if let err { return err }
        do {
            try withAfcRoot(root) { try AFCService.makeDirectory(client: $0, path: path) }
            return ok(["root": root.rawValue, "path": path])
        } catch {
            return fail("建目录失败：\(error.localizedDescription)",
                        extra: ["root": root.rawValue, "path": path])
        }
    }

    // MARK: - 调用日志（给 SSH 排障用）

    /// 宿主能力调用日志文件（`Documents/CapabilityLog/run.log`）.
    ///
    /// 放 `Documents/` 而不是某个模块的数据目录：能力调用是**宿主级**行为，
    /// 而且原生界面的模块（视图编译进宿主）本来就没有自己的数据目录，
    /// 放这里才能保证「任何模块形态都查得到」.
    static var callLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CapabilityLog", isDirectory: true)
            .appendingPathComponent("run.log")
    }

    /// 单条记录里 args / result 各自的上限。
    ///
    /// ▸ v0.3.492：从 **1200 提到 8192**。原来的 1200 太小 ——
    /// 有些能力的 `details` 判据动辄 1200~3600 字符，一截就把最关键的
    /// 那几行切掉，于是每次排障都得再绕去设备上 `cat` 原文。
    /// 8192 足以完整容纳这类判据，同时仍防止单条记录把日志撑爆。
    private static let callLogTextLimit = 8192
    /// 日志文件大小上限；超过就只留后半段（最近的调用才是排障要看的）。
    /// ▸ v0.3.492：512KB → 2MB（配合单条上限提高；仍是有限值，不会无限增长）。
    private static let callLogFileLimit = 2 * 1024 * 1024

    /// 追加一笔能力调用记录.
    ///
    /// ## 为什么在宿主侧统一记，而不是让模块自己记
    /// · 原生界面的模块（视图编译进宿主）**没有自己的日志通道** —— 日志只在内存里，
    ///   用户手机上出问题时看不到；
    /// · dylib 模块虽然有 `data/` 目录，但「宿主到底收到什么、返回什么」只有宿主知道；
    /// · 统一在这里记，任何模块形态都被覆盖，而且**模块一行代码都不用改**.
    ///
    /// 用 `NSLock` 保护：模块可能从非主线程调用，而 `FileHandle` 追加不是原子的.
    private static let callLogLock = NSLock()

    private static func appendCallLog(capability: String, jsonArgs: String,
                                      result: String, ok: Bool, elapsedMS: Int) {
        callLogLock.lock()
        defer { callLogLock.unlock() }

        let fm = FileManager.default
        let url = callLogURL
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(ok ? "OK " : "ERR") \(capability) (\(elapsedMS)ms)\n"
            + "  args: \(clip(jsonArgs, callLogTextLimit))\n"
            + "  ret : \(clip(result, callLogTextLimit))\n"

        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }

        // 体积守卫
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > callLogFileLimit,
           let data = fm.contents(atPath: url.path) {
            let header = Data("…（日志超过上限，已截断，下面是最近的部分）\n".utf8)
            try? (header + data.suffix(callLogFileLimit / 2)).write(to: url)
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…（截断，原文 \(text.count) 字符）"
    }

    // MARK: - JSON 小工具

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func jsonText(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"结果 JSON 序列化失败\"}"
        }
        return text
    }

    private static func ok(_ extra: [String: Any] = [:]) -> (Int32, String) {
        var dict = extra
        dict["ok"] = true
        return (0, jsonText(dict))
    }

    private static func fail(_ error: String, extra: [String: Any] = [:]) -> (Int32, String) {
        var dict = extra
        dict["ok"] = false
        dict["error"] = error
        return (1, jsonText(dict))
    }
}
