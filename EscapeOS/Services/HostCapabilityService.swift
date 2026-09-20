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
        "airlift.air",
        "airlift.pull",
        "airlift.overwrite",
        "airlift.readdir",
        "airlift.restoredir",
        "airlift.delete",
        "airlift.writeMany",
        "apps.lookup",
        "afc.list",
        "afc.read",
        "afc.write",
        "afc.delete",
        "afc.mkdir",
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
        case "airlift.air":           return airliftAir(args)
        case "airlift.pull":          return airliftPull(args)
        case "airlift.overwrite":     return airliftOverwrite(args)
        case "airlift.readdir":       return airliftReaddir(args)
        case "airlift.restoredir":    return airliftRestoredir(args)
        case "airlift.delete":        return airliftDelete(args)
        case "airlift.writeMany":     return airliftWriteMany(args)
        case "apps.lookup":           return appsLookup(args)
        case "afc.list":              return afcList(args)
        case "afc.read":              return afcRead(args)
        case "afc.write":             return afcWrite(args)
        case "afc.delete":            return afcDelete(args)
        case "afc.mkdir":             return afcMkdir(args)
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

    /// 漏洞利用可用性.
    ///
    /// ## 为什么要报**两个**字段（不是一个布尔）
    /// 「用户有没有在『更多 → 漏洞利用』里勾上 airlift」与「airlift 的 poc 接口
    /// 能不能用」是**两件事**：
    /// · `pocReadFile/pocWriteFile/pocDeleteFile` **不检查** `ExploitSettings` ——
    ///   它们直接跑协议，所以即使设置里没勾也能用；
    /// · 设置开关影响的是 `ExploitRegistry` 那条通用路由（空间回收 / 文件浏览等
    ///   走 `SandboxEscape.consume` 的功能），以及**后台自检**是否跑
    ///   （`triggerProtocolProbeOnce` 里有 `guard ... contains(.airlift)`）。
    ///
    /// 只报一个布尔必然误导：报设置状态 ⇒ 用户以为模块坏了；报「能用」⇒
    /// 用户以为设置已开、自检在跑。所以两个都报，并附一句说明.
    private static func exploitStatus() -> (Int32, String) {
        // ExploitSettings 是 @MainActor，但它提供了 nonisolated 的快照读取
        // （就是为了后台线程用的）—— 这里正合用，不必跳主线程.
        let enabled = ExploitSettings.snapshot()
        let airliftOn = enabled.contains(.airlift)
        return ok([
            // 设置开关状态
            "airliftEnabled": airliftOn,
            "badQueryEnabled": enabled.contains(.badQueryList),
            "enabled": enabled.map(\.rawValue).sorted(),
            // 代码路径可用性：poc 接口不依赖上面的开关 ⇒ 恒为 true
            "airliftRunnable": true,
            "note": airliftOn
                ? "airlift 已在设置里启用。"
                : "airlift 未在「更多 → 漏洞利用」里勾选。**不影响本模块的读/写/删**"
                  + "（poc 接口不检查该开关）；但后台自检不会跑。"
                  + "想要自检请去「更多 → 漏洞利用」勾上 airlift。",
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

    // MARK: - AIR 工作目录（沙盒外文件的中转站）

    /// AIR 工作目录 —— 沙盒外文件的**中转站**。
    ///
    /// ## 为什么是这个路径（不是随便挑的）
    /// `/var/mobile/Media` 正是 `com.apple.afc` 的**根**（`AFCService` 里有实测结论：
    /// 「`afc_client_connect_rsd` 根目录 = /var/mobile/media」）。放在它下面的目录，
    /// 宿主可以用**一条 AFC 连接直接读/写/列/建/删**，不需要跑 airlift。
    /// 而沙盒外的目标文件只能靠 airlift 搬（一趟 10~20 秒）——
    /// 把读出来的字节落在 AIR，之后的查看 / 编辑 / 再次覆盖就全是廉价的 AFC 操作。
    ///
    /// ## 语义（对齐产品要求）
    /// · **读**：目标文件 →（airlift 读 + 原字节写回原位）→ 副本落到 `AIR/<扁平化文件名>`
    /// · **写 / 覆盖**：`AIR/<文件>` 的字节 → airlift 写回目标路径
    ///
    /// ## 与 lara 的关系（重要，别误解）
    /// 「自定义覆盖」这个**产品形态**参考了 `github.com/rooootdev/lara`
    /// （它的 Custom Overwrite = 「填目标路径 + 选源文件 → 覆盖」）。
    /// 但**漏洞利用完全不同**：lara 走 DarkSword 内核链、在内核层**原地覆盖字节**
    /// （所以它有「目标文件必须 ≥ 源文件」的硬限制）；我们走 airlift 的越界写，
    /// **不要求目标文件更大**、目标甚至可以不存在，也完全不碰内核。
    static let airDir = "/var/mobile/Media/AIR"

    /// AIR 在 AFC 里的路径（AFC 根 = /var/mobile/Media，所以是相对路径）
    private static let airAfcPath = "AIR"

    /// 把完整路径**扁平化**成一个可读文件名（AIR 里副本的命名规则）。
    ///
    /// 例：`/private/var/mobile/Library/Logs/x.bin`
    ///  → `private_var_mobile_Library_Logs_x.bin`
    ///
    /// 为什么不保留目录层级：AIR 是给人看的**中转站**，保留层级会让「里面有什么」
    /// 变成要一层层点开；扁平名里带着原路径，一眼能看出是从哪儿来的。
    static func airFlattenName(for path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let flat = trimmed.replacingOccurrences(of: "/", with: "_")
        return flat.isEmpty ? "unnamed" : flat
    }

    /// 确保 AIR 目录存在（幂等）。已存在不算失败。
    private static func airEnsureDirectory() throws {
        do {
            try AFCService.shared.makeDirectory(airAfcPath)
        } catch {
            // 已存在时 afc_make_directory 会报错 —— 列一下确认目录真在，在就算成功
            if (try? AFCService.shared.listDirectory(airAfcPath)) == nil {
                throw error
            }
        }
    }

    private static func airWrite(name: String, data: Data) throws {
        try airEnsureDirectory()
        try AFCService.shared.writeFile(data, to: "\(airAfcPath)/\(name)")
    }

    private static func airRead(name: String) throws -> Data {
        try AFCService.shared.readFile("\(airAfcPath)/\(name)")
    }

    private static func airList() throws -> [AFCService.Entry] {
        // 目录不存在时 AFC 会报错 —— 当成「还没有中转文件」，而不是失败
        (try? AFCService.shared.listDirectory(airAfcPath)) ?? []
    }

    /// `airlift.air` —— AIR 目录本身的操作（列 / 读 / 写 / 删 / 确认存在）。
    ///
    /// 全是**廉价 AFC**（不用跑 airlift），所以 UI 可以随便调。
    private static func airliftAir(_ args: [String: Any]) -> (Int32, String) {
        let op = (args["op"] as? String) ?? "list"
        let name = args["name"] as? String
        switch op {
        case "list":
            do {
                let entries = try airList()
                let list: [[String: Any]] = entries.map { entry in
                    [
                        "name": entry.name,
                        "size": Int(entry.size),
                        "isDir": entry.isDirectory,
                    ]
                }
                return ok(["dir": airDir, "entries": list, "count": list.count])
            } catch {
                return fail("列 AIR 目录失败：\(error.localizedDescription)", extra: ["dir": airDir])
            }
        case "mkdir":
            do {
                try airEnsureDirectory()
                return ok(["dir": airDir])
            } catch {
                return fail("建 AIR 目录失败：\(error.localizedDescription)", extra: ["dir": airDir])
            }
        case "read":
            guard let name, !name.isEmpty else { return fail("airlift.air 的 op=read 需要 name") }
            do {
                let data = try airRead(name: name)
                guard let text = encode(data, encoding: (args["encoding"] as? String) ?? "base64") else {
                    return fail("读到了 \(data.count) 字节但编码失败")
                }
                return ok(["name": name, "data": text, "size": data.count])
            } catch {
                return fail("读 AIR/\(name) 失败：\(error.localizedDescription)")
            }
        case "write":
            guard let name, !name.isEmpty else { return fail("airlift.air 的 op=write 需要 name") }
            guard let text = args["data"] as? String,
                  let data = decode(text, encoding: (args["encoding"] as? String) ?? "base64") else {
                return fail("airlift.air 的 op=write 需要合法的 data（base64 或 utf8）")
            }
            do {
                try airWrite(name: name, data: data)
                return ok(["name": name, "size": data.count, "path": "\(airDir)/\(name)"])
            } catch {
                return fail("写 AIR/\(name) 失败：\(error.localizedDescription)")
            }
        case "delete":
            guard let name, !name.isEmpty else { return fail("airlift.air 的 op=delete 需要 name") }
            do {
                try AFCService.shared.removePath("\(airAfcPath)/\(name)")
                return ok(["name": name])
            } catch {
                return fail("删 AIR/\(name) 失败：\(error.localizedDescription)")
            }
        default:
            return fail("airlift.air 不支持的 op「\(op)」（list / mkdir / read / write / delete）")
        }
    }

    // MARK: - airlift.pull / airlift.overwrite

    /// 读一个沙盒外文件，并把副本留在 AIR（= 产品说的「读取就把目标文件拷贝到 AIR」）。
    ///
    /// ## 为什么是「airlift 读 + 写回 + AFC 存副本」三步
    /// airlift 的读是**移动不是拷贝** —— 它把文件搬进 Media。所以：
    /// ① airlift 读（文件离开原位）
    /// ② airlift 把原字节**写回原位**（原文件回位，这一步不能省）
    /// ③ AFC 把字节写一份到 `AIR/<扁平名>`（廉价，宿主沙盒里也留一份 `data`）
    ///
    /// - Returns: `(ok, json, data)` —— `data` 给上层做后续处理（如改 plist 再覆盖）
    private static func airPull(target: String, airName: String?) -> (Int32, String, Data?) {
        let name = airName ?? airFlattenName(for: target)
        var steps: [String] = []

        // ① airlift 读
        let read = withAirlift { AirliftExploit.pocReadFile(path: target) }
        guard read.ok, let data = read.data else {
            return (1, jsonText(["ok": false,
                                "error": "airlift 读失败：\(read.summary)",
                                "steps": read.details, "path": target, "via": "airlift"]), nil)
        }
        steps.append("① airlift 读到 \(data.count) 字节（读是移动，文件已进 Media）")

        // ② 写回原位
        let restore = withAirlift { AirliftExploit.pocWriteFile(path: target, data: data) }
        steps.append(restore.ok
            ? "② 已把原字节写回原位置"
            : "② ⚠️⚠️ 写回原位失败：\(restore.summary)（原文件当前不在原位，"
              + "原字节备份在模块数据目录 LoginLogs/ 下）")

        // ③ 副本落 AIR
        var airSaved = false
        do {
            try airWrite(name: name, data: data)
            airSaved = true
            steps.append("③ 副本已存到 \(airDir)/\(name)")
        } catch {
            steps.append("③ ⚠️ 副本存 AIR 失败：\(error.localizedDescription)")
        }

        guard restore.ok else {
            return (1, jsonText(["ok": false,
                                "error": "读到内容了，但**没能把原文件写回原位**",
                                "steps": steps, "path": target, "via": "airlift",
                                "size": data.count, "airName": airSaved ? name : ""]), nil)
        }
        return (0, jsonText(["ok": true,
                             "path": target,
                             "size": data.count,
                             "airName": airSaved ? name : "",
                             "airPath": airSaved ? "\(airDir)/\(name)" : "",
                             "via": "airlift",
                             "steps": steps]), data)
    }

    /// `airlift.pull` —— 把沙盒外文件读到 AIR（并返回字节）。
    private static func airliftPull(_ args: [String: Any]) -> (Int32, String) {
        guard let target = args["path"] as? String, !target.isEmpty else {
            return fail("airlift.pull 缺少 path")
        }
        let (rc, json, _) = airPull(target: target, airName: args["name"] as? String)
        return (rc, json)
    }

    /// 用一段字节**覆盖**一个沙盒外文件（= 「自定义覆盖」的核心动作）。
    ///
    /// ## 与 lara 的 Custom Overwrite 的差别（写清楚，别被误解）
    /// lara 走 DarkSword 内核链、在内核层**原地覆盖字节** ⇒ 必须「目标文件 ≥ 源文件」。
    /// 我们走 airlift 越界写 ⇒ **没有这个限制**，目标可以比源小/大、甚至可以不存在。
    ///
    /// ## ★★★ v0.3.496：**必须读回校验**（这条是血的教训）
    /// `pocWriteFile` 的成败只看「设备回的 `AssetManifest` 里有没有我们那条」——
    /// 那只证明**消息发出去了**，**不证明字节落到盘上**。真机 2026-09-20 实测：
    /// 写 SystemGroup 容器（`…/systemgroup.com.apple.configurationprofiles/Library/
    /// ConfigurationProfiles/`）时，清单**命中**、`pocWriteFile` 报 `ok:true`，
    /// 但读回**一点没变**（412 字节原文），连**新建**一个文件都建不出来。
    /// ⇒ 那个容器允许「读/移出」，但沙盒**拒绝「创建/写入」**。
    ///
    /// 只看清单就报成功 ⇒ 上层会显示「已覆盖写入」而实际什么都没发生
    /// —— **这个谎话让我们追了好几个小时**。所以现在 `verify: true`（默认）时
    /// 一定读回比对，不一致就**如实报失败**。
    ///
    /// ## 备份语义
    /// `backup: true`（默认）时，覆盖前先 `airPull` 目标把原内容存到 `AIR/<名>.bak`。
    /// **备份失败就中止覆盖** —— 产品要求是「先拷贝目标文件，再写入」，不能反着来。
    ///
    /// - Returns: `(rc, json, 是否真的写入了)`
    private static func airOverwrite(target: String, data: Data,
                                     backup: Bool,
                                     verify: Bool = true) -> (Int32, String) {
        var steps: [String] = []

        if backup {
            let (rc, json, _) = airPull(target: target, airName: airFlattenName(for: target) + ".bak")
            steps.append(contentsOf: stringList(parseArgs(json)["steps"]).map { "备份: \($0)" })
            guard rc == 0 else {
                steps.append("⚠️ 覆盖前备份失败 —— 按「先备份再覆盖」的要求，**中止覆盖**")
                return (1, jsonText(["ok": false,
                                     "error": "备份失败，已中止覆盖（目标未被改动）",
                                     "steps": steps, "path": target]))
            }
            steps.append("备份已存到 \(airDir)/\(airFlattenName(for: target)).bak")
        }

        let write = withAirlift { AirliftExploit.pocWriteFile(path: target, data: data) }
        steps.append(contentsOf: write.details.map { "写入: \($0)" })
        guard write.ok else {
            return (1, jsonText(["ok": false,
                                "error": "写入失败：\(write.summary)",
                                "steps": steps, "path": target, "via": "airlift"]))
        }
        // ⚠️ 到这里的 `ok` **只代表「清单命中」**，不代表落点写成了 —— 见函数头注释。
        steps.append("已发出覆盖写入 \(data.count) 字节（**清单命中**；"
                     + (verify ? "下面读回校验落点" : "未校验落点") + "）")

        var extra: [String: Any] = [
            "path": target,
            "size": data.count,
            "via": "airlift",
            "backup": backup ? "\(airDir)/\(airFlattenName(for: target)).bak" : "",
            "verified": false,
        ]
        guard verify else {
            extra["note"] = "verify=false：**落点未校验** —— 清单命中不等于字节落盘。"
                + "要确认请再调一次 `airlift.pull` 读回比对。"
            extra["steps"] = steps
            return (0, jsonText(extra))
        }

        // 读回校验：唯一能证明「字节真的落盘了」的判据。
        let check = airliftReadAndRestore(path: target)
        steps.append(contentsOf: check.details.map { "校验: \($0)" })
        guard let back = check.data else {
            extra["steps"] = steps
            return (1, jsonText(extra.merging([
                "error": "覆盖后**读回失败**，无法确认落点（字节可能没落盘）：\(check.summary)"
            ]) { _, new in new }))
        }
        guard back == data else {
            steps.append("⚠️⚠️ 读回 \(back.count) 字节 ≠ 写入 \(data.count) 字节"
                         + " ⇒ **覆盖没落地**（设备端那次 move 没发生）")
            steps.append("常见原因：目标目录**不允许创建/写入**（真机实测 SystemGroup 容器"
                         + "就是这种 —— 读得到、写不进）。这是**目标的问题，不是流程的问题**。")
            extra["steps"] = steps
            extra["readBackSize"] = back.count
            return (1, jsonText(extra.merging([
                "error": "覆盖**未生效**：读回 \(back.count) 字节 ≠ 写入 \(data.count) 字节"
                         + "（清单命中了，但字节没落盘）"
            ]) { _, new in new }))
        }
        steps.append("★ 读回一致（\(back.count) 字节）⇒ **覆盖确实落地了**")
        extra["steps"] = steps
        extra["verified"] = true
        return (0, jsonText(extra))
    }

    /// `airlift.overwrite` —— 用 AIR 里的文件（或 App 沙盒里的文件）覆盖/写入任意沙盒外路径。
    ///
    /// ## ★★★ v0.3.498：**target 可以是目录**
    /// 旧版把 `target` 一律当**文件路径**，拆成「父目录 + 文件名」——
    /// 于是填一个**目录**时，它会拿**目录名当文件名**去写（写成一个叫
    /// `ConfigurationProfiles` 的文件！），这既是错的、也很危险。
    ///
    /// 现在三种写法都能用：
    /// ```
    /// target = "/var/mobile/Library/Logs/a.bin"                  // 明确给文件名
    /// target = "/var/mobile/Library/Logs/"                        // 尾斜杠 ⇒ 当目录，用源文件名
    /// target = "/var/mobile/Library/Logs", targetIsDirectory=true // 显式声明是目录
    /// ```
    /// 目录时落点 = `target/<leafName ?? 源文件名>`。
    ///
    /// 参数：
    /// - `target`：目标绝对路径（必填；可以是文件，也可以是目录）
    /// - `airName`：AIR 里的源文件名（与 `source` 二选一）
    /// - `source`：App 沙盒内的源文件绝对路径（与 `airName` 二选一）
    /// - `targetIsDirectory`：把 `target` 当**目录**（默认 `false`；`target` 以 `/` 结尾时自动为真）
    /// - `leafName`：目录模式下写入的文件名（默认取源文件名）
    /// - `backup`：覆盖前是否把目标原内容备份到 AIR（默认 `true`）
    /// - `verify`：覆盖后是否**读回比对**（默认 `true`）——
    ///   ⚠️ 强烈建议保持默认：清单命中**不等于**字节落盘（见 `airOverwrite` 头注释）
    private static func airliftOverwrite(_ args: [String: Any]) -> (Int32, String) {
        guard let rawTarget = args["target"] as? String, !rawTarget.isEmpty else {
            return fail("airlift.overwrite 缺少 target（目标绝对路径）")
        }
        let airName = args["airName"] as? String
        let source = args["source"] as? String
        let backup = (args["backup"] as? Bool) ?? true
        let verify = (args["verify"] as? Bool) ?? true
        let explicitDir = (args["targetIsDirectory"] as? Bool) ?? false
        let explicitLeaf = (args["leafName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 读源文件（AIR 或沙盒）
        let data: Data
        var sourceDesc: String
        var sourceFileName: String
        if let airName, !airName.isEmpty {
            do {
                data = try airRead(name: airName)
                sourceDesc = "AIR/\(airName)"
                sourceFileName = airName
            } catch {
                return fail("读 AIR/\(airName) 失败：\(error.localizedDescription)")
            }
        } else if let source, !source.isEmpty {
            guard isInSandbox(source) else {
                return fail("source 必须是 App 沙盒内的路径（沙盒外的文件请先 airlift.pull 到 AIR 再用 airName）")
            }
            guard let d = FileManager.default.contents(atPath: source) else {
                return fail("读不到沙盒内源文件：\(source)")
            }
            data = d
            sourceDesc = source
            sourceFileName = (source as NSString).lastPathComponent
        } else {
            return fail("airlift.overwrite 需要 airName（AIR 里的文件）或 source（沙盒内文件）之一")
        }

        // ★ 目录模式：`target` 以 `/` 结尾，或显式声明，或给了 `leafName`
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingSlash = target.hasSuffix("/") && target.count > 1
        if trailingSlash { while target.hasSuffix("/") { target.removeLast() } }
        let isDirectory = explicitDir || trailingSlash
            || (explicitLeaf?.isEmpty == false)
        var finalPath = target
        if isDirectory {
            let leaf = (explicitLeaf?.isEmpty == false ? explicitLeaf! : sourceFileName)
            guard !leaf.isEmpty, !leaf.contains("/") else {
                return fail("目录模式下 leafName 必须是一个文件名（不含 `/`）：\(leaf)")
            }
            finalPath = target + "/" + leaf
        }

        let (rc, json) = airOverwrite(target: finalPath, data: data,
                                      backup: backup, verify: verify)
        guard rc == 0 else {
            var dict = parseArgs(json)
            dict["target"] = finalPath
            dict["resolvedFrom"] = target
            dict["targetIsDirectory"] = isDirectory
            dict["source"] = sourceDesc
            return (rc, jsonText(dict))
        }
        var dict = parseArgs(json)
        dict["target"] = finalPath
        dict["resolvedFrom"] = target
        dict["targetIsDirectory"] = isDirectory
        dict["source"] = sourceDesc
        return (0, jsonText(dict))
    }

    /// `airlift.delete` —— 删掉一个**沙盒外**的已知文件（v0.3.496 新增）.
    ///
    /// ## 机制（与读同源）
    /// 设备端把文件**搬进 Media**（move 不是 copy ⇒ 原位置那一刻就空了），
    /// 实现里**先确认备份落盘、再删 Media 里的副本** ⇒ 文件彻底消失。
    ///
    /// ## ⚠️ 为什么「先备份再删」
    /// 搬进 Media 之后那份副本是数据的**唯一一份**（原位置已空）。备份没落盘就删
    /// = 直接丢数据 ⇒ **宁可不删**，并如实报出副本还在 Media 的哪个路径（还能救）。
    ///
    /// ## 参数
    /// - `path`：目标文件绝对路径（必填）
    private static func airliftDelete(_ args: [String: Any]) -> (Int32, String) {
        guard let target = args["path"] as? String, !target.isEmpty else {
            return fail("airlift.delete 缺少 path")
        }
        let outcome = withAirlift { AirliftExploit.pocDeleteFile(path: target) }
        let extra: [String: Any] = [
            "path": target, "via": "airlift",
            "steps": outcome.details,
        ]
        return outcome.ok ? ok(extra) : fail(outcome.summary, extra: extra)
    }

    /// `airlift.writeMany` —— **一次 stage 写多个文件到同一个目录**（v0.3.499 新增）.
    ///
    /// ## 为什么需要它（AirCard 的 #1 能力，用户点名要移植）
    /// 每个文件单独走一趟 airlift = 10~20 秒，而且**隧道连多了会卡死**
    /// （真机实测第 6 次 AT 会话卡在 conduit 建连、之后整条 `protocolQueue` 堵死）。
    /// 密码键盘主题一次要写 12~36 张按键图 ⇒ 逐个写根本不可行。
    /// 批量之后：**N 个文件 = 1 趟 airlift**。
    ///
    /// ## ⚠️ 前提：目标**目录**必须已经存在
    /// airlift 在 Media 之外**建不了目录**（真机实测：沙盒允许建普通文件、不允许建目录）。
    ///
    /// ## ⚠️ 判据的诚实边界
    /// 只看「每条 `FileComplete` 有没有被处理」（= `payload_i` 被搬走），**不校验落点**。
    /// 要确认内容，对其中任意一个文件调 `airlift.pull` 读回比对。
    ///
    /// 参数：
    /// - `dir`：目标**目录**绝对路径（必填）
    /// - `files`：`[{"name": "文件名", "data": "<base64>"}]`（必填；名字不能含斜杠）
    /// - `encoding`：`data` 的编码（默认 `base64`）
    private static func airliftWriteMany(_ args: [String: Any]) -> (Int32, String) {
        guard let dir = args["dir"] as? String, !dir.isEmpty else {
            return fail("airlift.writeMany 缺少 dir（目标目录绝对路径）")
        }
        guard let raw = args["files"] as? [[String: Any]], !raw.isEmpty else {
            return fail("airlift.writeMany 缺少 files（形如 [{\"name\":\"a.png\",\"data\":\"<base64>\"}]）")
        }
        let encoding = (args["encoding"] as? String) ?? "base64"
        var files: [(name: String, data: Data)] = []
        for (index, item) in raw.enumerated() {
            guard let name = item["name"] as? String, !name.isEmpty else {
                return fail("files[\(index)] 缺少 name")
            }
            guard let text = item["data"] as? String,
                  let data = decode(text, encoding: encoding) else {
                return fail("files[\(index)] 的 data 非法（encoding=\(encoding)）")
            }
            files.append((name: name, data: data))
        }
        let outcome = withAirlift { AirliftExploit.pocWriteMany(dir: dir, files: files) }
        var extra: [String: Any] = [
            "dir": dir,
            "count": files.count,
            "bytes": files.reduce(0) { $0 + $1.data.count },
            "names": files.map { $0.name },
            "via": "airlift",
            "steps": outcome.details,
            "note": "批量写只看「每条 FileComplete 是否被处理」（payload_i 被搬走），"
                  + "**不校验落点**；要确认内容请对任意一个文件调 airlift.pull 读回比对。",
        ]
        if let warn = refuseReasonForReaddir(dir) {
            extra["warning"] = warn
        }
        return outcome.ok ? ok(extra) : fail(outcome.summary, extra: extra)
    }

    private static func stringList(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }

    // MARK: - ★★★ airlift.readdir / airlift.restoredir（浏览 Media 之外的任意目录）

    /// 「缺位待搬回」的记账文件（`Documents/LoginLogs/airlift_pending_restore.txt`）.
    ///
    /// 为什么需要它：搬进 Media 的条目名带随机 token，调用方（模块界面）可能没记住；
    /// 而**搬回是必须完成的动作**（不然目标目录就空了）。把「条目名 + 原路径」落到盘上，
    /// 即使界面重启、或某一步失败，也能用 `airlift.restoredir` 只凭 path 重试.
    private static var pendingRestoreURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoginLogs", isDirectory: true)
            .appendingPathComponent("airlift_pending_restore.txt")
    }

    private static func readPendingRestores() -> [String: String] {
        guard let text = try? String(contentsOf: pendingRestoreURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { out[parts[1]] = parts[0] }
        }
        return out
    }

    private static func writePendingRestores(_ map: [String: String]) {
        let text = map.map { "\($0.value)\t\($0.key)" }.joined(separator: "\n")
        try? FileManager.default.createDirectory(at: pendingRestoreURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? text.write(to: pendingRestoreURL, atomically: true, encoding: .utf8)
    }

    private static func rememberPendingRestore(recovered: String, for path: String) {
        var map = readPendingRestores()
        map[path] = recovered
        writePendingRestores(map)
    }

    private static func clearPendingRestore(for path: String) {
        var map = readPendingRestores()
        map.removeValue(forKey: path)
        writePendingRestores(map)
    }

    /// 拒绝一批「**一动就可能让系统起不来**」的祖先路径.
    ///
    /// 这不是能力限制（airlift 搬得动它们），是**安全闸**：把 `/var/mobile/Library`
    /// 整个搬进 Media 再搬回，中间那 20~40 秒里**全系统都在读写不存在的路径**。
    /// 返回 `nil` = 放行.
    ///
    /// ## ★ v0.3.497 修正：**只精确拒绝「祖先」，不再按前缀连带拒子目录**
    /// 旧版用 `hasPrefix(prefix + "/")` 判前缀，于是
    /// `/var/containers/Bundle` 这条把**每一个 App 的容器**
    /// （`/var/containers/Bundle/Application/<uuid>`）也一起拒了 ——
    /// 等于把「浏览 App 容器」这个正经用法堵死。
    /// 现在：**祖先路径精确拒绝**（它们一搬全没），**子目录放行但带警告**
    /// （见 `warnForReaddir`）—— 由用户自己判断。
    private static func refuseReasonForReaddir(_ path: String) -> String? {
        // 归一：`/private/var/...` 与 `/var/...` 视作同一个（内核里 /var 是 symlink）
        var p = path
        if p.hasPrefix("/private/var/") { p = "/var/" + String(p.dropFirst("/private/var/".count)) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }

        let hardRefuse: Set<String> = [
            "/", "/var", "/private", "/var/mobile", "/var/containers", "/var/db",
            "/var/stash", "/var/tmp", "/var/log", "/var/root",
            "/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/Applications",
            "/var/mobile/Library",            // 太大且被全系统依赖
            "/var/mobile/Media",              // 就是我们自己的根
            "/var/mobile/Containers",
            "/var/mobile/Documents",          // 用户文档根（一搬全没）
            // ★ 容器/守护进程的**祖先**：搬走一个就少一批 App / 一批系统配置
            "/var/containers/Bundle",
            "/var/containers/Bundle/Application",
            "/var/containers/Data",
            "/var/containers/Data/Application",
            "/var/containers/Shared",
            "/var/containers/Shared/SystemGroup",
            "/var/mobile/Library/Caches",
            "/var/mobile/Library/Preferences",
            "/var/mobile/Library/Keychains",
            "/var/mobile/Library/SMS",
            "/var/mobile/Library/AddressBook",
            "/var/mobile/Library/SpringBoard",
            "/var/mobile/Library/Logs",
        ]
        if hardRefuse.contains(p) {
            return "这是被全系统依赖的祖先/根目录，搬走期间整个系统都在读写不存在的路径"
        }
        return nil
    }

    /// 放行但**必须提醒**的路径（`airlift.readdir` 用）—— 返回 `nil` 表示没什么好提醒的.
    ///
    /// 这些目录搬走本身不会立刻出事，但**很可能被系统守护进程重建**
    /// ⇒ 搬回时冲突（或搬回失败）。如实提示，由用户决定要不要继续.
    private static func warnForReaddir(_ path: String) -> String? {
        var p = path
        if p.hasPrefix("/private/var/") { p = "/var/" + String(p.dropFirst("/private/var/".count)) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }

        let appContainerPrefixes = [
            "/var/containers/Bundle/Application/",
            "/var/containers/Data/Application/",
        ]
        for prefix in appContainerPrefixes where p.hasPrefix(prefix) {
            return "这是一个 **App 容器**：搬走期间该 App 会看不到自己的数据"
                + "（可能闪退或被系统重建目录 ⇒ 搬回时冲突）。"
                + "建议**先杀掉那个 App** 再浏览。"
        }
        if p.hasPrefix("/var/mobile/Library/Logs/") || p.hasPrefix("/var/mobile/Library/Preferences/") {
            return "这个目录里的内容由系统守护进程读写，**可能被重建** ⇒ 搬回时冲突。"
        }
        if p.hasPrefix("/var/containers/Shared/") {
            return "SystemGroup 共享容器：实测**只允许读/移出、拒绝创建/写入**；"
                + "搬回（写入）很可能失败 ⇒ 目录会留在 Media 里，需要重试搬回。"
        }
        return nil
    }

    /// `airlift.readdir` —— **浏览 Media 之外的任意目录**（v0.3.496 新增）.
    ///
    /// ## 机制（2026-09-20 真机实证）
    /// 1. airlift 变体 5 把**整个目录**搬进 Media（`airlift-recovered-<t>`）——
    ///    真机实测判据：`airlift-recovered-38EC6637 → 存在（成功 size=128 st_ifmt=S_IFDIR）`
    ///    ⇒ **目录也能搬**（不只文件）；
    /// 2. 条目此刻**物理上就在 Media 里** ⇒ AFC（根 = Media）可以**递归列目录 + 读文件**：
    ///    ```
    ///    afc.list  /airlift-recovered-38EC6637       → sub(目录) + a.txt
    ///    afc.list  /airlift-recovered-38EC6637/sub   → b.txt
    ///    afc.read  /airlift-recovered-38EC6637/a.txt → 内容正确
    ///    ```
    ///    （对照：**穿过 symlink** 去列 Media 外的目录会被拒 —— `Afc(PermDenied)`，
    ///      因为沙盒对 `read_dir` 也要 `file-read-data`）；
    /// 3. **立刻搬回原位**（变体 7）。这一步**无论如何都要执行**，
    ///    否则目标目录就凭空消失了。
    ///
    /// ## ⚠️⚠️ 目标目录在 ①~③ 之间是**缺位**的（约 20~40 秒）
    /// · 默认**只列目录**（`readFiles` 默认 false）⇒ 缺位窗口最短；
    /// · 拒绝一批「一动就出事」的路径（见 `refuseReasonForReaddir`）；
    /// · 搬回失败时**如实大声报**，并把「条目名 + 原路径」记到盘上，
    ///   可用 `airlift.restoredir` 只凭 path 重试（数据没丢，就在 Media 里）。
    ///
    /// ## 参数
    /// - `path`：目标目录绝对路径（必填）
    /// - `maxDepth`：递归深度上限（默认 4）
    /// - `maxEntries`：条目数上限（默认 400）
    /// - `readFiles`：是否把小文件内容也读回来（默认 `false`）
    /// - `maxFileBytes`：`readFiles` 时单文件上限（默认 65536）
    /// - `restore`：是否搬回（默认 `true`；**只有排障才该设 false**）
    private static func airliftReaddir(_ args: [String: Any]) -> (Int32, String) {
        guard let raw = args["path"] as? String, !raw.isEmpty else {
            return fail("airlift.readdir 缺少 path")
        }
        let maxDepth = max(1, min((args["maxDepth"] as? Int) ?? 4, 12))
        let maxEntries = max(1, min((args["maxEntries"] as? Int) ?? 400, 5000))
        let readFiles = (args["readFiles"] as? Bool) ?? false
        let maxFileBytes = max(1, (args["maxFileBytes"] as? Int) ?? 65536)
        let restore = (args["restore"] as? Bool) ?? true

        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.hasPrefix("/") { target = "/" + target }
        if target.count > 1 && target.hasSuffix("/") { target.removeLast() }
        if target == "/" { return fail("airlift.readdir 不接受根目录 /") }
        if let reason = refuseReasonForReaddir(target) {
            return fail("拒绝读取 \(target)：\(reason)",
                        extra: ["path": target, "refused": true])
        }

        // ★★★ v0.3.498：**默认拒绝搬目录** —— 这是一条血的教训（2026-09-20 真机实测）
        //
        // ## 为什么（4 处落点全部实测失败）
        // 设备端 `ATAirlock` 是 `moveItemAtPath:`。实测：
        //   · 把目录**搬进 Media**：✅ 成功
        //   · 把目录**搬回 Media 之外**：❌ 全部失败
        //     （试过 `/var/mobile/Library/Logs/CrashReporter`、`…/Logs`、
        //       `…/Logs/CrashReporter/Retired`、`/var/mobile/Library/Caches`、
        //       `/var/mobile/Library/Preferences` —— 5 个落点全失败）
        //   · 同样的落点**建文件**：✅ 成功（`zt-logs.bin` / `zt-prefs.bin` 都建出来了）
        //   · 把目录搬回 **Media 内**：✅ 成功
        // ⇒ **沙盒允许在 Media 外创建「普通文件」，但不允许创建「目录」**
        //   （vnode 类型过滤）。所以「搬目录出去」是**单向、不可逆**的。
        //
        // ## 后果（我踩了）
        // 我把 `…/CrashReporter/DiagnosticLogs` 搬进 Media 后**搬不回去**，
        // 那个目录（含 2 个子目录、2 个文件）至今卡在 Media 里。
        // ⇒ 所以现在**默认直接拒绝**，要搬必须显式写 `allowOneWay: true`
        //   并在界面上确认「知道这是单向的」。
        let allowOneWay = (args["allowOneWay"] as? Bool) ?? false
        if !allowOneWay {
            return fail("拒绝：把 Media 之外的**目录**搬进来是**单向、不可逆**的"
                        + "（实测：沙盒允许在 Media 外建**文件**，但**不允许建目录**"
                        + " ⇒ 搬出去就回不来了）。"
                        + "如果你**确实**要把它搬进来（当成「导出目录内容」用），"
                        + "请显式传 `allowOneWay: true`。"
                        + "只想浏览的话：CrashReporter 那棵树请用 `afc.list`（root=crash），"
                        + "Media 用 root=media —— 这两处**不需要搬**。",
                        extra: ["path": target, "refused": true,
                                "reason": "directoryMoveIsOneWay",
                                "hint": "allowOneWay"])
        }
        var steps: [String] = []
        steps.append("⚠️⚠️ 已开启 allowOneWay：目录会被搬进 Media，"
                     + "**Media 之外搬不回去**（沙盒不允许在 Media 外创建目录）。")
        // 放行但先提醒（App 容器 / 守护进程目录 / SystemGroup 容器）
        let warning = warnForReaddir(target)
        if let warning { steps.append("⚠️ 提醒：\(warning)") }

        // ① 把整个目录搬进 Media
        let entry = withAirlift { AirliftExploit.pocReadEntry(path: target) }
        steps.append(contentsOf: entry.details)
        guard let recovered = entry.recoveredName else {
            return fail("① 把目录搬进 Media 失败：\(entry.summary)",
                        extra: ["path": target, "via": "airlift", "steps": steps])
        }
        steps.append("① \(entry.summary)")
        // 从这一刻起目标缺位 —— 先记账，保证「只凭 path 也能重试搬回」
        rememberPendingRestore(recovered: recovered, for: target)

        // ② 递归列（+ 可选读小文件）—— 条目此刻就在 Media 里，AFC 读得到
        var entries: [[String: Any]] = []
        var files: [String: String] = [:]
        var walkError: String?
        var truncated = false
        do {
            try withAfcRoot(.media) { client in
                var stack: [(path: String, depth: Int)] = [(recovered, 0)]
                while let current = stack.popLast() {
                    let items = try AFCService.listDirectory(client: client, path: current.path)
                    for item in items {
                        if entries.count >= maxEntries { truncated = true; break }
                        var row: [String: Any] = [
                            "path": item.path,
                            "name": item.name,
                            "isDir": item.isDirectory,
                            "size": Int(item.size),
                            "depth": current.depth,
                        ]
                        if let modified = item.modified {
                            row["mtime"] = ISO8601DateFormatter().string(from: modified)
                        }
                        entries.append(row)
                        if item.isDirectory {
                            if current.depth + 1 < maxDepth {
                                stack.append((item.path, current.depth + 1))
                            }
                        } else if readFiles, item.size <= Int64(maxFileBytes) {
                            if let data = try? AFCService.readFile(client: client, path: item.path),
                               let text = encode(data, encoding: "base64") {
                                files[item.path] = text
                            }
                        }
                    }
                    if truncated { break }
                }
            }
        } catch {
            walkError = error.localizedDescription
        }
        steps.append("② AFC 递归列出 \(entries.count) 个条目"
                     + (truncated ? "（**已达 maxEntries=\(maxEntries) 上限、被截断**）" : "")
                     + (walkError.map { "；⚠️ 中途出错：\($0)" } ?? ""))

        // ③ **无论如何都要搬回**
        var restored = false
        if restore {
            let back = withAirlift {
                AirliftExploit.pocRestoreEntry(originalPath: target, recoveredName: recovered)
            }
            steps.append(contentsOf: back.details)
            restored = back.ok
            steps.append(restored
                ? "③ ★ 已把 \(recovered) 搬回 \(target) —— 目标不再缺位"
                : "③ ⚠️⚠️ **搬回失败**：条目仍在 Media 的 \(recovered)"
                  + " ⇒ \(target) 此刻是**空的**！"
                  + " 请立刻调 `airlift.restoredir {\"path\":\"\(target)\"}` 重试 —— **数据没丢**。")
        } else {
            steps.append("③ restore=false ⇒ **没有搬回**；\(target) 此刻是空的，"
                         + "条目在 Media 的 \(recovered) —— 收尾请调 `airlift.restoredir`")
        }
        if restored { clearPendingRestore(for: target) }

        var extra: [String: Any] = [
            "path": target,
            "recoveredName": recovered,
            "isDirectory": entry.isDirectory,
            "entries": entries,
            "count": entries.count,
            "truncated": truncated,
            "restored": restored,
            "via": "airlift",
            "steps": steps,
        ]
        if let warning { extra["warning"] = warning }
        if let walkError { extra["walkError"] = walkError }
        if !files.isEmpty { extra["files"] = files }
        if !restore || restored { return ok(extra) }
        return fail("列到 \(entries.count) 个条目，但**没能搬回原位** ⇒ \(target) 缺位中，"
                    + "请调 airlift.restoredir 重试（数据在 Media 的 \(recovered)）",
                    extra: extra)
    }

    /// `airlift.restoredir` —— 把 `airlift.readdir` 搬进 Media 的条目**搬回原位**（重试入口）.
    ///
    /// 参数：
    /// - `path`：**原路径**（必填）
    /// - `recoveredName`：Media 里的条目名；**省略时从记账文件里按 path 取**
    ///
    /// 为什么单独开一个能力：搬回是**必须完成的动作**。一旦失败（RSD 卡死、隧道断了），
    /// 目标目录就空着 —— 必须有一个**只凭 path 就能重试**的入口，而不是重新走一遍读。
    private static func airliftRestoredir(_ args: [String: Any]) -> (Int32, String) {
        guard let raw = args["path"] as? String, !raw.isEmpty else {
            return fail("airlift.restoredir 缺少 path")
        }
        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.hasPrefix("/") { target = "/" + target }
        if target.count > 1 && target.hasSuffix("/") { target.removeLast() }

        let explicit = (args["recoveredName"] as? String)?.trimmingCharacters(in: .whitespaces)
        let recovered = (explicit?.isEmpty == false ? explicit : nil)
            ?? readPendingRestores()[target]
        guard let recovered else {
            return fail("不知道要搬回哪个条目：记账文件里没有 \(target)"
                        + "（请显式传 recoveredName，或先跑一次 airlift.readdir）",
                        extra: ["path": target, "pending": readPendingRestores()])
        }

        let back = withAirlift {
            AirliftExploit.pocRestoreEntry(originalPath: target, recoveredName: recovered)
        }
        var steps = back.details
        steps.append(back.ok
            ? "★ 已把 \(recovered) 搬回 \(target)"
            : "⚠️ 搬回仍未成立（条目可能还在 Media 的 \(recovered)）—— 可再试一次")
        if back.ok { clearPendingRestore(for: target) }
        let extra: [String: Any] = [
            "path": target, "recoveredName": recovered,
            "restored": back.ok, "via": "airlift", "steps": steps,
        ]
        return back.ok ? ok(extra) : fail(back.summary, extra: extra)
    }

    // MARK: - sys.supervised.*

    /// 一次「airlift 读 + 写回原位」的结果（`sys.supervised.*` 用）。
    private struct AirliftReadResult {
        let data: Data?
        let summary: String
        let details: [String]
        /// 是否成功把原字节写回原位置
        let restored: Bool
        /// AIR 里的副本名（备份/中转用）
        let airName: String?
    }

    /// 读一个沙盒外文件，**并立刻把原字节写回原位**，同时在 AIR 留一份副本。
    ///
    /// 这是 `sys.supervised.*` 的读入口 —— 与 `airPull` 同一套机制，
    /// 只是把 JSON 包装拆掉、直接给上层结构体。
    private static func airliftReadAndRestore(path: String) -> AirliftReadResult {
        let read = withAirlift { AirliftExploit.pocReadFile(path: path) }
        guard read.ok, let data = read.data else {
            return AirliftReadResult(data: nil, summary: read.summary,
                                     details: read.details, restored: false, airName: nil)
        }
        let restore = withAirlift { AirliftExploit.pocWriteFile(path: path, data: data) }
        var details = read.details
        details.append(restore.ok
            ? "★ 已把原字节写回原位置（读是移动，不写回文件就留在 Media 里了）"
            : "⚠️⚠️ 写回原位置失败：\(restore.summary) —— 文件当前**不在**原位置，"
              + "原字节已备份在模块数据目录 LoginLogs/ 下，请尽快处理")

        // 顺手在 AIR 留一份副本（廉价 AFC；失败不影响读的结果，只记一句）
        var airName: String?
        let name = airFlattenName(for: path)
        do {
            try airWrite(name: name, data: data)
            airName = name
            details.append("★ 副本已存到 \(airDir)/\(name)")
        } catch {
            details.append("（副本存 AIR 失败：\(error.localizedDescription)）")
        }
        return AirliftReadResult(data: data, summary: read.summary,
                                 details: details, restored: restore.ok, airName: airName)
    }

    /// 解析 plist（binary 与 XML 都能解）.
    private static func parsePlist(_ data: Data) -> [String: Any]? {
        guard let obj = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) else { return nil }
        return obj as? [String: Any]
    }

    /// 读监督模式状态（走 airlift：读 + 立刻写回原位 + 副本进 AIR）.
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
        var extra: [String: Any] = [
            "isSupervised": supervised,
            "organizationName": dict["OrganizationName"] as? String ?? "",
            "path": path,
            "via": "airlift",
            "steps": result.details,
        ]
        if let airName = result.airName {
            extra["airName"] = airName
            extra["airPath"] = "\(airDir)/\(airName)"
        }
        return ok(extra)
    }

    /// 开关监督模式：**全程走 airlift**（读 → 写回 → 覆盖 → 读回校验）.
    ///
    /// ## 为什么读也要走 airlift
    /// 本路径属于系统组（SystemGroup）。iOS 26.5/26.6 对 `configurationprofiles`
    /// 拒绝签发沙盒扩展 ⇒ `FileManager` 连**读**都读不到（`fileExists` 因无法穿越沙盒
    /// 返回 false，表现为「配置文件不存在」这种误导性错误 —— v0.3.481 真机实测踩到）。
    /// airlift 不依赖沙盒扩展，所以读写统一走它。
    ///
    /// ## ★★★ 覆盖写入的正确顺序（v0.3.495/496 真机定案）
    ///
    /// 用户原话：**「我们覆盖写入动作不能直接移动，是先写入拷贝回来的东西，
    /// 再覆盖目标文件回写」**。落地成：
    ///
    /// ```
    /// ① airlift 读            → 原字节（读是**移动**，目标位置此刻是空的）
    /// ② airlift 写回原字节    → 「先写入拷贝回来的东西」：目标回位、内容 = 原文
    /// ③ 内存里改 IsSupervised → newData
    /// ④ airlift 写 newData    → 「再覆盖目标文件回写」
    /// ⑤ 读回校验 + 写回       → **唯一能证明字节落盘的判据**
    /// ```
    ///
    /// ## ⚠️⚠️ 但真机实测（2026-09-20）：**这条路对这个目标做不到**
    ///
    /// 目标 `/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.
    /// configurationprofiles/Library/ConfigurationProfiles/CloudConfigurationDetails.plist`
    /// 所在的 **SystemGroup 容器，沙盒拒绝「创建/写入」，只允许「读/移出」**：
    ///
    /// | 实验（同一台设备） | 结果 |
    /// |---|---|
    /// | **读**这个 plist | ✅ 成功（412 字节） |
    /// | **覆盖**这个 plist | ❌ 读回仍是 412 字节原文 |
    /// | **新建** `…/ConfigurationProfiles/zt-test.bin` | ❌ 文件根本没被创建 |
    /// | 覆盖 `CrashReporter` 里一个已存在的文件（202→32 字节） | ✅ **成功** |
    /// | **新建** `/var/mobile/Library/Logs/zt-logs.bin` | ✅ **成功（32 字节）** |
    /// | **新建** `/var/mobile/Library/Preferences/zt-prefs.bin` | ✅ **成功（32 字节）** |
    /// | **新建** `/var/mobile/Documents/zt-docs.bin` | ❌ 失败 |
    ///
    /// ⇒ 结论：**`/var/mobile/Library/**` 基本可写**；被拒的是
    /// **SystemGroup 容器**（`/var/containers/Shared/SystemGroup/…`）与
    /// `/var/mobile/Documents`。
    /// ⇒ **「启用监督模式」= 写 SystemGroup 容器 = 沙盒不让做。**
    ///   这不是流程问题（顺序已经按用户说的改对了），是**目标不允许**。
    ///
    /// ## ★★ 教训：`pocWriteFile` 的 `ok` 只代表「清单命中」
    /// 设备回 `AssetManifest` 里有我们那条，只证明**消息发出去了**，
    /// **不证明字节落盘**。旧版 `airlift.overwrite` / `supervisedSet` 只看清单就报
    /// 「已覆盖写入」⇒ **对着一个没生效的写汇报成功，把排查带偏了好几个小时**。
    /// ⇒ 现在 `airlift.overwrite` 默认 `verify: true`（读回比对），
    ///   `supervisedSet` 的 ⑦ 也改口径为「已**发出**」。
    ///
    /// ## 成本
    /// 一次 airlift 约 10~20 秒。`verify: true`（默认）共 5 次操作
    /// （读 / 写回 / 写 / 读回 / 写回），约 50~100 秒；`verify: false` 共 3 次。
    /// ⚠️ 操作次数越少越好 —— 设备端 RSD 隧道在连续多次建连后有卡死的先例
    /// （真机实测：第 6 次 AT 会话卡在 conduit 建连，之后整条 `protocolQueue` 堵死）。
    private static func supervisedSet(_ args: [String: Any]) -> (Int32, String) {
        guard let enabled = args["enabled"] as? Bool else {
            return fail("sys.supervised.set 缺少 enabled（布尔）")
        }
        let orgName = (args["organizationName"] as? String) ?? ""
        let verify = (args["verify"] as? Bool) ?? true
        let path = ConfigPlistURL.cloudConfig.path
        var steps: [String] = []
        /// 原文件字节（① 读回来后填）。声明在 `restoreOriginal` **之前** ——
        /// Swift 的嵌套函数不能引用在它之后声明的局部变量（"captures before declared"）.
        var oldData = Data()

        /// 把读到的原字节写回原位置（「覆盖写入」那一步失败时的兜底）.
        ///
        /// ⚠️ 只有在 ② 已经成功写回之后才需要它 —— 那时目标内容本来就是原文，
        /// 再写一遍是幂等的。真正需要它的是 ⑦ 失败的情形（写了一半）。
        func restoreOriginal(_ why: String) -> Bool {
            let restore = withAirlift { AirliftExploit.pocWriteFile(path: path, data: oldData) }
            steps.append(restore.ok
                ? "↩︎ \(why) ⇒ 已把原字节写回原位置"
                : "⚠️⚠️ \(why) 且**写回原位失败**：\(restore.summary)"
                  + "（文件当前不在原位，原字节已备份在模块数据目录 LoginLogs/ 下）")
            return restore.ok
        }

        // ★★★ ①②③ 读 + **写回** + 备份 —— **直接复用 `airPull`**（v0.3.495 真机定案）。
        //
        // ## 为什么复用而不是自己拼三步
        // `airPull` 就是**已在真机上验证可行**的那条序列：它和「自定义覆盖」
        // （`airlift.overwrite`，内部 = `airPull` → 写）用的是**同一段代码**。
        //
        // ## 2026-09-20 真机对照（同一台设备、同一时间段）
        // · `airlift.overwrite {backup:true}`（= `airPull`[读 + **写回**] → 写）**成功**：
        //   CrashReporter 里一个 98480 字节的**已存在**文件被覆盖成 31 字节
        //   （AFC 回读确认 size=31）⇒ 「覆盖已存在文件」这件事本身成立。
        // · 旧版 `supervisedSet`（读 **不写回** → 直接写）**失败**：
        //   `airlift_at2.txt` 判据「`airlift-src-*/payload` 已被搬走 = 否（第 2 次 move 没发生）」，
        //   而穿过 symlink 看到的真实目标**仍是 412 字节的原文**。
        // ⇒ 结构性差别只有那一次「写回」。
        //
        // ## 用户原话（这就是需求）
        // **「我们覆盖写入动作不能直接移动，是先写入拷贝回来的东西，
        //    再覆盖目标文件回写」**
        //
        // ## 步骤编号沿用 `airPull` 自己的 ①②③
        //   ① airlift 读到 N 字节（读是移动，文件已进 Media）
        //   ② 已把原字节写回原位置   ← **「先写入拷贝回来的东西」**
        //   ③ 副本已存到 AIR/<名>.bak（AFC；放在这对读写**之后**，不夹在中间）
        let backupName = airFlattenName(for: path) + ".bak"
        let (pullRC, pullJSON, pullData) = airPull(target: path, airName: backupName)
        let pullDict = parseArgs(pullJSON)
        steps.append(contentsOf: stringList(pullDict["steps"]))
        guard pullRC == 0, let readData = pullData else {
            return fail("①② airlift 读 + 写回失败："
                        + ((pullDict["error"] as? String) ?? "未知错误"),
                        extra: ["path": path, "via": "airlift", "steps": steps])
        }
        oldData = readData
        let airBackup: String? = (pullDict["airName"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // ④ 解析
        guard let dict = parsePlist(oldData) else {
            let ok = restoreOriginal("原内容不是合法 plist")
            return fail("④ 读到的内容不是合法 plist（原文件\(ok ? "已" : "**未能**")写回原位）",
                        extra: ["path": path, "via": "airlift", "steps": steps])
        }
        let before = dict["IsSupervised"] as? Bool ?? false
        steps.append("④ 解析成功，当前 IsSupervised = \(before)")

        // ⑤ 改字段
        let mutable = NSMutableDictionary(dictionary: dict)
        mutable["IsSupervised"] = enabled
        if enabled, !orgName.isEmpty {
            mutable["OrganizationName"] = orgName
            steps.append("⑤ OrganizationName = \(orgName)")
        } else if !enabled {
            mutable.removeObject(forKey: "OrganizationName")
            steps.append("⑤ 已移除 OrganizationName")
        }

        // ⑥ 序列化
        guard let newData = try? PropertyListSerialization.data(
            fromPropertyList: mutable, format: .binary, options: 0) else {
            let ok = restoreOriginal("plist 序列化失败")
            return fail("plist 序列化失败（原文件\(ok ? "已" : "**未能**")写回原位）",
                        extra: ["path": path, "steps": steps])
        }
        steps.append("⑥ 新内容 \(newData.count) 字节（binary plist）")

        // ⑦ 覆盖写入新内容（airlift）—— **「再覆盖目标文件回写」**
        //
        // ⚠️ 这一步**只有在 ② 已经把原字节写回原位之后**才成立 —— 目标必须「在位」，
        // 这才是一次真正的**覆盖**（见上面 ①②③ 处的真机对照实验）。
        let write = withAirlift { AirliftExploit.pocWriteFile(path: path, data: newData) }
        steps.append(contentsOf: write.details.map { "⑦ write: \($0)" })
        guard write.ok else {
            let ok = restoreOriginal("覆盖写入失败")
            return fail("⑦ 覆盖写入失败：\(write.summary)"
                        + "（原文件\(ok ? "已" : "**未能**")写回原位）",
                        extra: ["path": path, "steps": steps,
                                "backup": airBackup ?? "", "isSupervised": before])
        }
        steps.append("⑦ 已**发出**覆盖写入（清单命中；⚠️ 清单命中**不等于**字节落盘"
            + " ⇒ 以 ⑧ 读回为准）")

        var extra: [String: Any] = [
            "path": path,
            "steps": steps,
            "isSupervised": enabled,
            "via": "airlift",
            "verified": false,
        ]
        if let airBackup { extra["backup"] = "\(airDir)/\(airBackup)" }

        guard verify else {
            extra["note"] = "verify=false：写入已发出但**未做读回校验**（airlift 写不校验落点）。"
                + "要确认请点「重新读取」。"
            return ok(extra)
        }

        // ⑧ 读回校验 —— **不轻信写入返回值**
        //    这次读同样会移动文件，所以 airliftReadAndRestore 内部会再写回一次。
        let check = airliftReadAndRestore(path: path)
        steps.append(contentsOf: check.details.map { "⑧ \($0)" })
        extra["steps"] = steps
        guard let checkData = check.data, let checkDict = parsePlist(checkData) else {
            return fail("⑧ 写入后读回失败，无法确认结果（文件可能不在原位置）",
                        extra: extra)
        }
        let after = checkDict["IsSupervised"] as? Bool
        steps.append("⑧ 读回：IsSupervised = \(after.map(String.init) ?? "读不到")")
        extra["steps"] = steps
        extra["isSupervised"] = after ?? enabled

        guard after == enabled else {
            return fail("⑧ 读回校验不一致：期望 \(enabled)，实际 \(after.map(String.init) ?? "读不到")",
                        extra: extra)
        }
        guard check.restored else {
            return fail("⑧ 内容已生效，但**没能把文件写回原位置**（它现在在 Media 里）",
                        extra: extra)
        }
        // 原内容备份已在 ①②③ 那步（`airPull` 的 ③）落到 AIR，这里不重复做。
        // ⚠️ 顺序说明：AIR 那份是 **AFC** 写的，而 ①读/②写 与 ⑧读/⑧写 是两对
        // **紧挨着的 airlift 操作** —— AFC 只落在两对之间，绝不夹在任一对内部
        // （v0.3.493 真机实测：夹在中间会让第 2 次 move 不发生）。

        extra["verified"] = true
        extra["organizationName"] = checkDict["OrganizationName"] as? String ?? ""
        return ok(extra)
    }

    // MARK: - apps.lookup（按 bundle id 查 App 容器路径）

    /// `apps.lookup` —— 列已安装应用，**带 App 数据容器路径**（v0.3.497 新增）.
    ///
    /// ## 为什么需要它（AirCard 的 #2，用户点名要移植）
    /// `airlift` 只能读写**已知绝对路径**，而 App 容器的路径里带一串随机 UUID
    /// （`/var/containers/Bundle/Application/<UUID>/`）—— 靠人猜不出来。
    /// 这个能力走 `installation_proxy`（**不是漏洞、不依赖 airlift**），
    /// 直接把 `Container`（数据容器）/ 包路径给出来，配上 `airlift.readdir`
    /// 就能浏览任意 App 的容器。
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
    /// 没有任何服务把根设在它们上面；`house_arrest` 的 `VendContainer` 在 iOS 27 实测被拒；
    /// airlift **本体**只能读写**单个已知文件**、**不能枚举目录**。
    ///
    /// ## 为什么这条路稳
    /// 两条服务都在 airlift 走的**同一条 RSD 隧道**上（设备广播服务 → host 直连端口）。
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

    /// 规范化成 AFC 口径（去掉前导/尾随 `/`；拒绝 `..` —— 根就是边界）
    private static func afcPath(_ raw: String?) -> String? {
        var p = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        if p.split(separator: "/").contains("..") { return nil }
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
            // ★ 如实区分失败原因 —— 原来一律提示「目录非空需要 recursive」，
            //   而真机上最常见的是**权限**（例：CrashReporter 里 `sysdiagnose` 归档
            //   的内容由系统账号创建，AFC 以 mobile 身份删不动）。
            //   误导性的 hint 会让人去改 recursive，白试一轮。
            if text.contains("PermDenied") {
                return fail("删除被拒（权限）：该条目不属于当前身份，"
                            + "AFC 与 airlift 都无权删除它。",
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
    /// ★ v0.3.492：从 **1200 提到 8192**。原来的 1200 太小 ——
    /// airlift 的判据（`details`）动辄 1200~3600 字符，一截就把最关键的
    /// 「清单里有没有我们那条」「删除成立」那几行切掉，
    /// 于是每次排障都得再绕去 `cat LoginLogs/airlift_at2.txt` 看原文。
    /// 8192 足以完整容纳这类判据，同时仍防止单条记录把日志撑爆。
    private static let callLogTextLimit = 8192
    /// 日志文件大小上限；超过就只留后半段（最近的调用才是排障要看的）。
    /// ★ v0.3.492：512KB → 2MB（配合单条上限提高；仍是有限值，不会无限增长）。
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
