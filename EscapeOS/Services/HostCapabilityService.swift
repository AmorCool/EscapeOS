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
    /// ## 备份语义
    /// `backup: true`（默认）时，覆盖前先 `airPull` 目标把原内容存到 `AIR/<名>.bak`。
    /// **备份失败就中止覆盖** —— 产品要求是「先拷贝目标文件，再写入」，不能反着来。
    ///
    /// - Returns: `(rc, json, 是否真的写入了)`
    private static func airOverwrite(target: String, data: Data,
                                     backup: Bool) -> (Int32, String) {
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
        steps.append("已写入 \(data.count) 字节（airlift 不校验落点，要确认请再 pull 一次读回）")
        return (0, jsonText(["ok": true,
                             "path": target,
                             "size": data.count,
                             "via": "airlift",
                             "backup": backup ? "\(airDir)/\(airFlattenName(for: target)).bak" : "",
                             "steps": steps]))
    }

    /// `airlift.overwrite` —— 用 AIR 里的文件（或 App 沙盒里的文件）覆盖任意沙盒外路径。
    ///
    /// 参数：
    /// - `target`：目标绝对路径（必填）
    /// - `airName`：AIR 里的源文件名（与 `source` 二选一）
    /// - `source`：App 沙盒内的源文件绝对路径（与 `airName` 二选一）
    /// - `backup`：覆盖前是否把目标原内容备份到 AIR（默认 `true`）
    private static func airliftOverwrite(_ args: [String: Any]) -> (Int32, String) {
        guard let target = args["target"] as? String, !target.isEmpty else {
            return fail("airlift.overwrite 缺少 target（目标绝对路径）")
        }
        let airName = args["airName"] as? String
        let source = args["source"] as? String
        let backup = (args["backup"] as? Bool) ?? true

        let data: Data
        var sourceDesc: String
        if let airName, !airName.isEmpty {
            do {
                data = try airRead(name: airName)
                sourceDesc = "AIR/\(airName)"
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
        } else {
            return fail("airlift.overwrite 需要 airName（AIR 里的文件）或 source（沙盒内文件）之一")
        }

        let (rc, json) = airOverwrite(target: target, data: data, backup: backup)
        guard rc == 0 else { return (rc, json) }
        // 补一句源描述，方便 UI 显示「用谁覆盖了谁」
        var dict = parseArgs(json)
        dict["source"] = sourceDesc
        return (0, jsonText(dict))
    }

    private static func stringList(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
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

    /// 开关监督模式：**全程走 airlift**（读 → 改 → 写 → 读回校验）.
    ///
    /// ## 为什么读也要走 airlift
    /// 本路径属于系统组（SystemGroup）。iOS 26.5/26.6 对 `configurationprofiles`
    /// 拒绝签发沙盒扩展 ⇒ `FileManager` 连**读**都读不到（`fileExists` 因无法穿越沙盒
    /// 返回 false，表现为「配置文件不存在」这种误导性错误 —— v0.3.481 真机实测踩到）。
    /// airlift 不依赖沙盒扩展，所以读写统一走它。
    ///
    /// ## ⚠️ 读是移动，所以每一步失败都必须把原字节写回
    /// 见 `airliftReadAndRestore` 与 `restoreOriginal` —— 绝不留下
    /// 「文件不在原位而用户不知道」这种状态。
    ///
    /// ## 成本
    /// 一次 airlift 约 10~20 秒。`verify: true`（默认）时共 4 次操作
    /// （读 / 写 / 读回 / 写回），约 40~80 秒；`verify: false` 时 2 次。
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

        /// 把读到的原字节写回原位置（任何后续步骤失败时的兜底）.
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

        // ★★★ v0.3.493：**备份到 AIR 挪到最后做**（原来插在读与写之间）。
        //
        // 为什么必须挪：AIR 备份走的是 **AFC**（另一条隧道/另一条服务会话），
        // 而 airlift 的「读」和「写」是**两次 AT 会话操作** ——
        // **在它们之间插一次 AFC 操作，第 2 次 airlift 操作就会失败**
        // （真机实测：`supervisedSet` 报「第 2 次 move 没发生」，
        //   而 `airliftReadAndRestore` 因为读/写紧挨着、AFC 放在最后 ⇒ 一直成功）。
        //
        // 数据安全不受影响：`pocReadFile` 读的时候已经把原字节备份在
        // `LoginLogs/airlift_read_<token>.bin`，AIR 这份是**第二重**备份。
        //
        // 位置：放在**校验之后**（见 ⑤b），这样读→写、读→写两对 airlift 操作
        // 全程相邻，中间不夹任何 AFC 调用。
        var airBackup: String?

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

        // ⑤ 写回新内容（airlift）
        let write = withAirlift { AirliftExploit.pocWriteFile(path: path, data: newData) }
        steps.append(contentsOf: write.details.map { "⑤ write: \($0)" })
        guard write.ok else {
            let ok = restoreOriginal("写入失败")
            return fail("⑤ 写入失败：\(write.summary)（原文件\(ok ? "已" : "**未能**")写回原位）",
                        extra: ["path": path, "steps": steps,
                                "backup": airBackup ?? "", "isSupervised": before])
        }
        steps.append("⑤ 已写入新内容")

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

        // ⑥ 读回校验 —— **不轻信写入返回值**
        //    这次读同样会移动文件，所以 airliftReadAndRestore 内部会再写回一次。
        let check = airliftReadAndRestore(path: path)
        steps.append(contentsOf: check.details.map { "⑥ \($0)" })
        extra["steps"] = steps
        guard let checkData = check.data, let checkDict = parsePlist(checkData) else {
            return fail("⑥ 写入后读回失败，无法确认结果（文件可能不在原位置）",
                        extra: extra)
        }
        let after = checkDict["IsSupervised"] as? Bool
        steps.append("⑥ 读回：IsSupervised = \(after.map(String.init) ?? "读不到")")
        extra["steps"] = steps
        extra["isSupervised"] = after ?? enabled

        guard after == enabled else {
            return fail("⑥ 读回校验不一致：期望 \(enabled)，实际 \(after.map(String.init) ?? "读不到")",
                        extra: extra)
        }
        guard check.restored else {
            return fail("⑥ 内容已生效，但**没能把文件写回原位置**（它现在在 Media 里）",
                        extra: extra)
        }
        // ⑤b 原内容备份到 AIR（**放在两次 airlift 操作之后**，见上面 ① 处的说明）
        let backupName = airFlattenName(for: path) + ".bak"
        do {
            try airWrite(name: backupName, data: oldData)
            airBackup = backupName
            steps.append("⑤b 原内容已备份到 \(airDir)/\(backupName)")
        } catch {
            steps.append("⑤b ⚠️ 备份到 AIR 失败：\(error.localizedDescription)（继续，但请留意）")
        }

        extra["verified"] = true
        extra["organizationName"] = checkDict["OrganizationName"] as? String ?? ""
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
