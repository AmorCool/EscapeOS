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
//  有了这层接口，模块只说「我要 fs.read」，由宿主决定底层走 bad_query 还是 airlift；
//  将来漏洞链被替换，模块**零改动**. 加新能力也只需要改这一个文件.
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
//  `call` 是**同步**的，而且沙盒外路径会走 airlift（一次 10~20 秒，内部
//  `protocolQueue.sync`）. **调用方必须在后台线程调用**，主线程调用会卡住界面.
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
/// **不做 MainActor 隔离**：模块在**非主线程**调用它（airlift 一次十几秒，主线程
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
        "sys.supervised.get",
        "sys.supervised.set",
        "proc.list",
        "proc.signal",
        "notify.post",
        "exploit.status",
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
        case "sys.supervised.get":    return supervisedGet()
        case "sys.supervised.set":    return supervisedSet(args)
        case "proc.list":             return procList()
        case "proc.signal":           return procSignal(args)
        case "notify.post":           return notifyPost(args)
        case "exploit.status":        return exploitStatus()
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

    private static func exploitStatus() -> (Int32, String) {
        // ExploitSettings 是 @MainActor，但它提供了 nonisolated 的快照读取
        // （就是为了后台线程枚举目录用的）—— 这里正合用，不必跳主线程.
        let enabled = ExploitSettings.snapshot()
        return ok([
            "airlift": enabled.contains(.airlift),
            "badQuery": enabled.contains(.badQueryList),
            "enabled": enabled.map(\.rawValue).sorted(),
        ])
    }

    // MARK: - fs.*

    /// 路径是否在 App 沙盒内（沙盒内直接用 FileManager，不需要漏洞利用）
    private static func isInSandbox(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/")
    }

    /// airlift 的调用必须串行化，两个原因：
    /// 1. 设备侧 AT 会话是**单例资源**（`pocStageAndAttack` 内部借 `protocolQueue.sync` 串行）；
    /// 2. `pocWriteFile` 的中转文件固定是 `Documents/airlift-poc-payload.bin`，
    ///    并发写会互相覆盖.
    private static let airliftLock = NSLock()

    private static func withAirlift<T>(_ body: () -> T) -> T {
        airliftLock.lock()
        defer { airliftLock.unlock() }
        return body()
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

        // 沙盒外走 airlift。airlift 的「读」是**移动不是拷贝** —— 所以默认把原字节
        // **立刻写回原位**（`airliftReadAndRestore`），默认行为是**非破坏性**的，
        // 调用方可以像用普通读一样用它。
        //
        // 只有显式传 `allowMove: true` 才跳过写回（= 故意把文件搬进 Media），
        // 那种用法会破坏性地移走文件，所以返回值里带 warning 说清楚。
        let moveOnly = (args["allowMove"] as? Bool) == true
        let data: Data
        var details: [String]
        if moveOnly {
            let outcome = withAirlift { AirliftExploit.pocReadFile(path: path) }
            guard outcome.ok, let d = outcome.data else {
                return fail(outcome.summary, extra: ["via": "airlift", "details": outcome.details])
            }
            data = d
            details = outcome.details
        } else {
            let result = airliftReadAndRestore(path: path)
            guard let d = result.data else {
                return fail("airlift 读失败：\(result.summary)",
                            extra: ["via": "airlift", "details": result.details])
            }
            data = d
            details = result.details
            guard result.restored else {
                return fail("读到内容了，但**没能把文件写回原位置**（它现在在 Media 里）",
                            extra: ["via": "airlift", "details": result.details])
            }
        }
        guard let text = encode(data, encoding: encoding) else {
            return fail("读到了 \(data.count) 字节但按 \(encoding) 编码失败（可能是二进制）",
                        extra: ["via": "airlift", "size": data.count])
        }
        var extra: [String: Any] = [
            "data": text,
            "size": data.count,
            "via": "airlift",
            "details": details,
        ]
        if moveOnly {
            extra["warning"] = "allowMove=true：airlift 的读是移动不是拷贝，"
                + "原位置的文件已被搬走，字节备份在模块数据目录的 "
                + "LoginLogs/airlift_read_*.bin；要保留请紧接着 fs.write 写回。"
        } else {
            extra["restored"] = true
        }
        return ok(extra)
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

        let outcome = withAirlift { AirliftExploit.pocWriteFile(path: path, data: data) }
        guard outcome.ok else {
            return fail(outcome.summary, extra: ["via": "airlift", "details": outcome.details])
        }
        var extra: [String: Any] = [
            "size": data.count,
            "via": "airlift",
            "details": outcome.details,
            "warning": "本调用**不校验落点**（真实目标在 Media 之外，AFC 读不回来）。"
                + "要确认写成功，请再调一次 fs.read 读回比对。",
        ]
        if let backupPath { extra["backup"] = backupPath }
        return ok(extra)
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
        let outcome = withAirlift { AirliftExploit.pocDeleteFile(path: path) }
        guard outcome.ok else {
            return fail(outcome.summary, extra: ["via": "airlift", "details": outcome.details])
        }
        return ok(["via": "airlift", "details": outcome.details,
                   "note": "备份留在模块数据目录的 LoginLogs/ 下"])
    }

    private static func fsExists(_ args: [String: Any]) -> (Int32, String) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("fs.exists 缺少 path")
        }
        if isInSandbox(path) {
            return ok(["exists": FileManager.default.fileExists(atPath: path), "via": "direct"])
        }
        // ⚠️ 刻意**不**用 airlift 探存在：它的读是「移动」，拿它做存在性检查
        // 会把文件搬走 —— 一个查询接口造成破坏性副作用是不能接受的.
        // 宿主也没有别的沙盒外「只 stat 不搬动」的原语，所以如实报错，不假装知道.
        return fail(
            "沙盒外无法只做存在性检查：airlift 的读是移动不是拷贝，"
            + "用它探存在会把文件搬走，故本能力不提供沙盒外路径。",
            extra: ["via": "none"])
    }

    private static func fsList(_ args: [String: Any]) -> (Int32, String) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("fs.list 缺少 path")
        }
        guard isInSandbox(path) else {
            // 如实说清限制：airlift 只能操作**单个文件**，无法枚举目录.
            // 宿主也没有别的沙盒外目录枚举原语（`escape.withHandle` + countTree 那条
            // 路要非负沙盒句柄，airlift 给不出来）.
            return fail(
                "fs.list 目前只支持 App 沙盒内路径：airlift 只能操作单个文件、无法枚举目录。",
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

    // MARK: - sys.supervised.*

    /// 一次「airlift 读 + 立刻写回原位」的结果.
    private struct AirliftReadResult {
        let data: Data?
        let summary: String
        let details: [String]
        /// 是否成功把原字节写回原位置
        let restored: Bool
    }

    /// airlift 读一个沙盒外文件，**并立刻把原字节写回原位**.
    ///
    /// ## 为什么「读」必须配一次「写」
    /// airlift 的读是**移动不是拷贝** —— 设备端把文件搬进 Media，再用 AFC 读出来
    /// （见 `AirliftExploit.pocReadFile` 的注释）。所以**不写回的话，读一次就等于把
    /// 用户的文件从原位置搬走了**。这里把「读 + 恢复」当成一个原子操作，
    /// 让上层可以像用普通读一样用它。
    ///
    /// ## 为什么不用 FileManager / bad_query 扩展读
    /// 本路径属于系统组（SystemGroup）。iOS 26.5/26.6 对 `configurationprofiles`
    /// 拒绝签发沙盒扩展（`MDMBypassService` 有记），此时 `FileManager.fileExists`
    /// 会因无法穿越沙盒而返回 false —— 表现为「配置文件不存在」这种**误导性**错误
    /// （v0.3.481 真机实测踩到）。airlift 不依赖沙盒扩展，所以读写统一走它。
    private static func airliftReadAndRestore(path: String) -> AirliftReadResult {
        let read = withAirlift { AirliftExploit.pocReadFile(path: path) }
        guard read.ok, let data = read.data else {
            return AirliftReadResult(data: nil, summary: read.summary,
                                     details: read.details, restored: false)
        }
        let restore = withAirlift { AirliftExploit.pocWriteFile(path: path, data: data) }
        var details = read.details
        details.append(restore.ok
            ? "★ 已把原字节写回原位置（读是移动，不写回文件就留在 Media 里了）"
            : "⚠️⚠️ 写回原位置失败：\(restore.summary) —— 文件当前**不在**原位置，"
              + "原字节已备份在模块数据目录 LoginLogs/ 下，请尽快处理")
        return AirliftReadResult(data: data, summary: read.summary,
                                 details: details, restored: restore.ok)
    }

    /// 解析 plist（binary 与 XML 都能解）.
    private static func parsePlist(_ data: Data) -> [String: Any]? {
        guard let obj = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) else { return nil }
        return obj as? [String: Any]
    }

    /// 读监督模式状态（走 airlift：读 + 立刻写回原位）.
    private static func supervisedGet() -> (Int32, String) {
        let path = ConfigPlistURL.cloudConfig.path
        let result = airliftReadAndRestore(path: path)

        guard let data = result.data else {
            return fail("airlift 读失败：\(result.summary)",
                        extra: ["path": path, "via": "airlift", "steps": result.details])
        }
        guard let dict = parsePlist(data) else {
            return fail("读到了 \(data.count) 字节，但不是合法 plist",
                        extra: ["path": path, "via": "airlift", "steps": result.details])
        }
        let supervised = dict["IsSupervised"] as? Bool ?? false
        guard result.restored else {
            // 内容读到了，但文件没回到原位 —— 这是必须让用户知道的严重情况
            return fail("读到内容了，但**没能把文件写回原位置**（它现在在 Media 里）",
                        extra: ["path": path, "via": "airlift",
                                "steps": result.details, "isSupervised": supervised])
        }
        return ok([
            "isSupervised": supervised,
            "organizationName": dict["OrganizationName"] as? String ?? "",
            "path": path,
            "via": "airlift",
            "steps": result.details,
        ])
    }

    /// 开关监督模式：**全程走 airlift**（读 → 改 → 写 → 读回校验）.
    ///
    /// ## 为什么读也要走 airlift
    /// 本路径属于系统组（SystemGroup）。iOS 26.5/26.6 对 `configurationprofiles`
    /// 拒绝签发沙盒扩展 ⇒ `FileManager` 连**读**都读不到（`fileExists` 因无法穿越沙盒
    /// 返回 false，表现为「配置文件不存在」这种误导性错误 —— v0.3.481 真机实测踩到）。
    /// airlift 不依赖沙盒扩展，所以读写统一走它。
    ///
    /// ## ⚠️ 读是移动，所以每一步失败都必须把原字节写回
    /// airlift 的读会把文件搬进 Media。本实现把「读 + 恢复」串成闭环：
    /// 任何一步失败都调 `restoreOriginal()` 把原字节写回原位置，
    /// 并在返回结果里如实标出**是否恢复成功**。绝不留下「文件不在原位」而用户不知道。
    ///
    /// ## 成本
    /// 一次 airlift 约 10~20 秒，本流程要 4 次（读 / 写 / 读回 / 写回），
    /// 所以整轮约 40~80 秒。`steps` 会逐条记下来，上层可以边等边看。
    private static func supervisedSet(_ args: [String: Any]) -> (Int32, String) {
        guard let enabled = args["enabled"] as? Bool else {
            return fail("sys.supervised.set 缺少 enabled（布尔）")
        }
        let orgName = (args["organizationName"] as? String) ?? ""
        let path = ConfigPlistURL.cloudConfig.path
        var steps: [String] = []
        /// 原文件字节（① 读回来后填）。声明在 `restoreOriginal` **之前** ——
        /// Swift 的嵌套函数不能引用在它之后声明的局部变量（"captures before declared"）.
        var oldData = Data()

        /// 把读到的原字节写回原位置（任何后续步骤失败时的兜底）.
        /// 返回是否成功 —— 失败意味着用户的文件当前**不在原位**，必须让上层知道.
        func restoreOriginal(_ why: String) -> Bool {
            let restore = withAirlift { AirliftExploit.pocWriteFile(path: path, data: oldData) }
            steps.append(restore.ok
                ? "↩︎ \(why) ⇒ 已把原字节写回原位置"
                : "⚠️⚠️ \(why) 且**写回原位失败**：\(restore.summary)"
                  + "（文件当前不在原位，原字节已备份在模块数据目录 LoginLogs/ 下）")
            return restore.ok
        }

        // ① 读原文件（airlift）
        let read = withAirlift { AirliftExploit.pocReadFile(path: path) }
        guard read.ok, let readData = read.data else {
            return fail("① airlift 读失败：\(read.summary)",
                        extra: ["path": path, "via": "airlift",
                                "steps": steps + read.details])
        }
        oldData = readData
        steps.append("① airlift 读到原文件 \(oldData.count) 字节（读是移动，文件已进 Media）")

        // ② 解析
        guard let dict = parsePlist(oldData) else {
            let ok = restoreOriginal("原内容不是合法 plist")
            return fail("① 读到的内容不是合法 plist（原文件\(ok ? "已" : "**未能**")写回原位）",
                        extra: ["path": path, "via": "airlift", "steps": steps])
        }
        let before = dict["IsSupervised"] as? Bool ?? false
        steps.append("② 解析成功，当前 IsSupervised = \(before)")

        // ③ 改字段
        let mutable = NSMutableDictionary(dictionary: dict)
        mutable["IsSupervised"] = enabled
        if enabled, !orgName.isEmpty {
            mutable["OrganizationName"] = orgName
            steps.append("③ OrganizationName = \(orgName)")
        } else if !enabled {
            mutable.removeObject(forKey: "OrganizationName")
            steps.append("③ 已移除 OrganizationName")
        }

        // ④ 序列化
        guard let newData = try? PropertyListSerialization.data(
            fromPropertyList: mutable, format: .binary, options: 0) else {
            let ok = restoreOriginal("plist 序列化失败")
            return fail("plist 序列化失败（原文件\(ok ? "已" : "**未能**")写回原位）",
                        extra: ["path": path, "steps": steps])
        }
        steps.append("④ 新内容 \(newData.count) 字节（binary plist）")

        // ⑤ 本地备份（覆盖前留后路；airlift 写不校验落点，更需要这条）
        var backupPath: String?
        let backupDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CapBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDir.appendingPathComponent("CloudConfigurationDetails-\(stamp).plist")
        if (try? oldData.write(to: backupURL)) != nil {
            backupPath = backupURL.path
            steps.append("⑤ 原文件已备份到 \(backupURL.path)")
        } else {
            steps.append("⑤ ⚠️ 原文件备份失败（继续，但请留意）")
        }

        // ⑥ 写回新内容（airlift）
        let write = withAirlift { AirliftExploit.pocWriteFile(path: path, data: newData) }
        steps.append(contentsOf: write.details.map { "⑥ write: \($0)" })
        guard write.ok else {
            let ok = restoreOriginal("写入失败")
            return fail("⑥ 写入失败：\(write.summary)（原文件\(ok ? "已" : "**未能**")写回原位）",
                        extra: ["path": path, "steps": steps,
                                "backup": backupPath ?? "", "isSupervised": before])
        }
        steps.append("⑥ 已写入新内容")

        // ⑦ 读回校验 —— **不轻信写入返回值**（airlift 写不校验落点）
        //    这次读同样会移动文件，所以 airliftReadAndRestore 内部会再写回一次.
        let check = airliftReadAndRestore(path: path)
        steps.append(contentsOf: check.details.map { "⑦ \($0)" })
        guard let checkData = check.data, let checkDict = parsePlist(checkData) else {
            return fail("⑦ 写入后读回失败，无法确认结果（文件可能不在原位置）",
                        extra: ["path": path, "steps": steps, "backup": backupPath ?? ""])
        }
        let after = checkDict["IsSupervised"] as? Bool
        steps.append("⑦ 读回：IsSupervised = \(after.map(String.init) ?? "读不到")")

        guard after == enabled else {
            return fail("⑦ 读回校验不一致：期望 \(enabled)，实际 \(after.map(String.init) ?? "读不到")",
                        extra: ["path": path, "steps": steps, "backup": backupPath ?? "",
                                "isSupervised": after ?? before])
        }
        guard check.restored else {
            return fail("⑦ 内容已生效，但**没能把文件写回原位置**（它现在在 Media 里）",
                        extra: ["path": path, "steps": steps, "backup": backupPath ?? "",
                                "isSupervised": after ?? before])
        }

        var extra: [String: Any] = [
            "path": path,
            "steps": steps,
            "isSupervised": after ?? enabled,
            "organizationName": checkDict["OrganizationName"] as? String ?? "",
            "via": "airlift",
            "restored": true,
        ]
        if let backupPath { extra["backup"] = backupPath }
        return ok(extra)
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

    /// 单条记录里 args / result 各自的上限
    private static let callLogTextLimit = 1200
    /// 日志文件大小上限；超过就只留后半段（最近的调用才是排障要看的）
    private static let callLogFileLimit = 512 * 1024

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
