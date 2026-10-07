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
import CryptoKit       // fs.hash：md5 / sha1 / sha256
import Compression     // pkg.read：ZIP 里 deflate 条目的解压
import Darwin          // host.info：sysctlbyname 取 hw.machine

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
    /// 注意： `EscapeModule.missingCapabilities` 依赖这个符号（`static let` / `[String]`
    /// 的签名不能改）；模块仓库的 `validate.py` 里 `KNOWN_CAPABILITIES` 也对应这一份，
    /// **两边必须同步改**.
    static let capabilityList: [String] = [
        "host.version",
        "host.capabilities",
        "host.info",          // 沙盒路径 / 设备信息（省得每次猜容器 UUID）
        "fs.read",            // 支持 offset / length 分块（大二进制不用一次读完）
        "fs.write",
        "fs.delete",
        "fs.exists",
        "fs.list",
        "fs.hash",            // md5 / sha1 / sha256（比对文件不用传回本地）
        "fs.find",            // 递归按名查找
        "fs.copy",            // 沙盒内复制
        "pkg.list",           // 列 IPA/ZIP 内条目（含偏移，配合 fs.read 取单个文件）
        "pkg.read",           // 读 IPA/ZIP 内单个条目（stored 直读 / deflate 解压）
        "pkg.stat",           // 一次拿全 IPA 体检摘要（ZIP + Mach-O cryptid + sinf），零字节搬运
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
        "ui.screenshot",      // 经隧道取屏幕截图（PNG；默认返回 base64，可落盘到沙盒）
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
        case "host.info":             return hostInfo()
        case "fs.read":               return fsRead(args)
        case "fs.write":              return fsWrite(args)
        case "fs.delete":             return fsDelete(args)
        case "fs.exists":             return fsExists(args)
        case "fs.list":               return fsList(args)
        case "fs.hash":               return fsHash(args)
        case "fs.find":               return fsFind(args)
        case "fs.copy":               return fsCopy(args)
        case "pkg.list":              return pkgList(args)
        case "pkg.read":              return pkgRead(args)
        case "pkg.stat":              return pkgStat(args)
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
        case "ui.screenshot":         return uiScreenshot(args)
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

    /// 沙盒根（App 的 home：`/var/mobile/Containers/Data/Application/<UUID>`）
    private static var homeDir: String { NSHomeDirectory() }

    /// 把调用方给的路径**归一化成沙盒内的绝对路径**。
    ///
    /// 加这层的原因：以前 `fs.*` 只认 `NSHomeDirectory()` 开头的绝对路径，而容器
    /// UUID 是随机且会变的 —— 调用方（尤其 SSH 里的排查脚本）拿不到它，就只能绕道
    /// afc，而 afc 的根是 `/var/mobile/Media`，**根本够不到 App 沙盒**。
    ///
    /// 现在四种写法都行：
    /// - `Documents/a.ipa`        → 相对 Documents（最常用，与 `ls` / `cat` 同口径）
    /// - `~/Documents/a.ipa`      → 相对沙盒根
    /// - `/Documents/a.ipa`       → 同上（开头的 `/` 当沙盒根）
    /// - `/var/mobile/...`        → 已是绝对路径，原样用（仍需落在沙盒内才放行）
    private static func resolvePath(_ raw: String) -> String {
        let home = homeDir
        let joined: String
        if raw.hasPrefix("/var/") || raw.hasPrefix("/private/") || raw.hasPrefix("/System/") {
            joined = raw
        } else if raw == "~" {
            joined = home
        } else if raw.hasPrefix("~/") {
            joined = home + "/" + String(raw.dropFirst(2))
        } else if raw.hasPrefix("/") {
            joined = home + raw
        } else {
            joined = home + "/Documents/" + raw
        }
        return (joined as NSString).standardizingPath
    }

    /// 路径是否在 App 沙盒内（沙盒内直接用 FileManager，不需要漏洞利用）
    private static func isInSandbox(_ path: String) -> Bool {
        let home = homeDir
        return path == home || path.hasPrefix(home + "/")
    }

    /// `host.info`：一次把「沙盒在哪、设备是什么」全给出来.
    ///
    /// 存在的意义：以前每次要读沙盒文件都得先想办法问出容器 UUID（要么翻日志、
    /// 要么二分猜），现在一条命令就有.
    private static func hostInfo() -> (Int32, String) {
        let home = homeDir
        let fm = FileManager.default
        var docs = home + "/Documents"
        if let u = fm.urls(for: .documentDirectory, in: .userDomainMask).first { docs = u.path }
        var caches = ""
        if let u = fm.urls(for: .cachesDirectory, in: .userDomainMask).first { caches = u.path }
        var tmp = NSTemporaryDirectory()
        if tmp.hasSuffix("/") { tmp = String(tmp.dropLast()) }

        // 沙盒根的属主：从 home 路径里把容器 UUID 抠出来
        var containerUUID = ""
        if let r = home.range(of: "/Data/Application/") {
            containerUUID = String(home[r.upperBound...])
        }

        let pi = ProcessInfo.processInfo
        let osv = pi.operatingSystemVersion
        let osVersion = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"

        var diskTotal: Int64 = 0, diskFree: Int64 = 0
        if let a = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            diskTotal = (a[.systemSize] as? NSNumber)?.int64Value ?? 0
            diskFree = (a[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }

        return ok([
            "home": home,
            "containerUUID": containerUUID,
            "documents": docs,
            "caches": caches,
            "tmp": tmp,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "appVersion": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
            "appBuild": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "",
            "osVersion": osVersion,
            "model": hwMachine(),
            "name": pi.hostName,
            "processorCount": pi.processorCount,
            "physicalMemory": pi.physicalMemory,
            "diskTotal": diskTotal,
            "diskFree": diskFree,
            "uptime": pi.systemUptime,
            // 列一下 Documents 顶层，省得再单独发一次 fs.list
            "documentsTop": (try? fm.contentsOfDirectory(atPath: docs).sorted()) ?? [],
        ])
    }

    /// 硬件机型标识（`sysctlbyname("hw.machine")`），如 `iPhone12,1`
    private static func hwMachine() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
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
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return fail("fs.read 缺少 path")
        }
        let encoding = (args["encoding"] as? String) ?? "base64"
        guard encoding == "base64" || encoding == "utf8" else {
            return fail("fs.read 的 encoding 只支持 base64 / utf8")
        }
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            // 沙盒外**没有**可用原语了：宿主唯一能碰沙盒外的机制是 airlift 漏洞利用，
            // 而它已整体移除（用户 2026-09-25 决定不再使用）。如实报错，不假装知道.
            return fail(
                "fs.read 只支持 App 沙盒内路径：沙盒外的读取原语（airlift）已从宿主移除.",
                extra: ["via": "none", "resolved": path, "home": homeDir])
        }

        guard let fh = FileHandle(forReadingAtPath: path) else {
            return fail("读失败（不存在或不可读）：\(path)",
                        extra: ["via": "direct", "resolved": path])
        }
        defer { try? fh.close() }

        let total = (try? fh.seekToEnd()) ?? 0
        let offset = max(0, UInt64((args["offset"] as? Int) ?? 0))
        guard offset <= total else {
            return fail("offset \(offset) 超出文件大小 \(total)",
                        extra: ["size": Int(total), "resolved": path])
        }
        try? fh.seek(toOffset: offset)
        let want = (args["length"] as? Int) ?? 0
        let avail = total - offset
        let take: Int = want > 0 ? Int(min(UInt64(want), avail)) : Int(avail)
        let data = (try? fh.read(upToCount: take)) ?? Data()

        guard let text = encode(data, encoding: encoding) else {
            return fail("读到了 \(data.count) 字节但按 \(encoding) 编码失败（可能是二进制）",
                        extra: ["via": "direct", "size": data.count, "resolved": path])
        }
        return ok([
            "data": text,
            "size": data.count,
            "offset": Int(offset),
            "total": Int(total),
            "eof": offset + UInt64(data.count) >= total,
            "via": "direct",
            "resolved": path,
        ])
    }

    private static func fsWrite(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
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
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            // 沙盒外**没有**可用原语了（见 `fsRead`）.
            return fail(
                "fs.write 只支持 App 沙盒内路径：沙盒外的写入原语（airlift）已从宿主移除.",
                extra: ["via": "none", "resolved": path, "home": homeDir])
        }

        // 可选：写前把原内容备份到 App 沙盒（覆盖前留一条后路）
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

        // 父目录不存在就建（写新文件时省一次 fs.mkdir）
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        do {
            try data.write(to: URL(fileURLWithPath: path))
            var extra: [String: Any] = ["size": data.count, "via": "direct", "resolved": path]
            if let backupPath { extra["backup"] = backupPath }
            return ok(extra)
        } catch {
            return fail("写失败（沙盒内）：\(error.localizedDescription)",
                        extra: ["via": "direct", "resolved": path])
        }
    }

    private static func fsDelete(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return fail("fs.delete 缺少 path")
        }
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            return fail(
                "fs.delete 只支持 App 沙盒内路径：沙盒外的删除原语（airlift）已从宿主移除.",
                extra: ["via": "none", "resolved": path, "home": homeDir])
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return ok(["via": "direct", "resolved": path])
        } catch {
            return fail("删除失败（沙盒内）：\(error.localizedDescription)",
                        extra: ["via": "direct", "resolved": path])
        }
    }

    private static func fsExists(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return fail("fs.exists 缺少 path")
        }
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            return fail(
                "fs.exists 只支持 App 沙盒内路径：沙盒外的查询原语已从宿主移除.",
                extra: ["via": "none", "resolved": path, "home": homeDir])
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        var size = 0
        if exists, let a = try? FileManager.default.attributesOfItem(atPath: path),
           let s = a[.size] as? Int { size = s }
        return ok(["exists": exists, "isDir": isDir.boolValue, "size": size,
                   "via": "direct", "resolved": path])
    }

    private static func fsList(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return fail("fs.list 缺少 path")
        }
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            // 宿主没有沙盒外目录枚举原语，如实报错.
            return fail(
                "fs.list 只支持 App 沙盒内路径：沙盒外的枚举原语已从宿主移除.",
                extra: ["via": "none", "resolved": path, "home": homeDir])
        }
        let url = URL(fileURLWithPath: path)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []) else {
            return fail("列目录失败（不存在或不可读）：\(path)",
                        extra: ["via": "direct", "resolved": path])
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

    // MARK: - fs.hash / fs.find / fs.copy

    /// `fs.hash`：在设备上算摘要，省得把整个文件传回本地再比.
    private static func fsHash(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return fail("fs.hash 缺少 path")
        }
        let algo = ((args["algo"] as? String) ?? "md5").lowercased()
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            return fail("fs.hash 只支持 App 沙盒内路径",
                        extra: ["resolved": path, "home": homeDir])
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return fail("读失败（不存在或不可读）：\(path)", extra: ["resolved": path])
        }
        let hex: String
        switch algo {
        case "md5":
            hex = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha1":
            hex = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha256":
            hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            return fail("algo 只支持 md5 / sha1 / sha256")
        }
        return ok(["algo": algo, "hex": hex, "size": data.count, "resolved": path])
    }

    /// `fs.find`：按文件名子串递归查找（不区分大小写）.
    private static func fsFind(_ args: [String: Any]) -> (Int32, String) {
        let needle = ((args["name"] as? String) ?? "").lowercased()
        guard !needle.isEmpty else {
            return fail("fs.find 缺少 name（文件名子串，不区分大小写）")
        }
        let root = resolvePath((args["path"] as? String) ?? "Documents")
        guard isInSandbox(root) else {
            return fail("fs.find 只支持 App 沙盒内路径",
                        extra: ["resolved": root, "home": homeDir])
        }
        let limit = (args["limit"] as? Int) ?? 200
        let fm = FileManager.default
        var hits: [[String: Any]] = []
        var truncated = false
        if let en = fm.enumerator(atPath: root) {
            for case let rel as String in en {
                if hits.count >= limit { truncated = true; break }
                guard rel.lowercased().contains(needle) else { continue }
                let full = root + "/" + rel
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: full, isDirectory: &isDir)
                var size = 0
                if !isDir.boolValue, let a = try? fm.attributesOfItem(atPath: full),
                   let s = a[.size] as? Int { size = s }
                hits.append(["path": full, "rel": rel, "isDir": isDir.boolValue, "size": size])
            }
        }
        return ok(["count": hits.count, "root": root, "truncated": truncated, "hits": hits])
    }

    /// `fs.copy`：沙盒内复制（改包前先留一份原件）.
    private static func fsCopy(_ args: [String: Any]) -> (Int32, String) {
        guard let fromRaw = args["from"] as? String, let toRaw = args["to"] as? String,
              !fromRaw.isEmpty, !toRaw.isEmpty else {
            return fail("fs.copy 需要 from / to")
        }
        let from = resolvePath(fromRaw)
        let to = resolvePath(toRaw)
        guard isInSandbox(from), isInSandbox(to) else {
            return fail("fs.copy 只支持 App 沙盒内路径", extra: ["from": from, "to": to])
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else {
            return fail("源不存在：\(from)")
        }
        try? fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if fm.fileExists(atPath: to) {
            guard (args["overwrite"] as? Bool) == true else {
                return fail("目标已存在（要覆盖请传 overwrite:true）：\(to)")
            }
            try? fm.removeItem(atPath: to)
        }
        do {
            try fm.copyItem(atPath: from, toPath: to)
            var size = 0
            if let a = try? fm.attributesOfItem(atPath: to), let s = a[.size] as? Int { size = s }
            return ok(["from": from, "to": to, "size": size])
        } catch {
            return fail("复制失败：\(error.localizedDescription)")
        }
    }

    // MARK: - pkg.*（IPA / ZIP 内条目读取）

    /// ZIP 小端读整（越界返回 0，不崩）
    private static func le16(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        return Int(d[o]) | Int(d[o + 1]) << 8
    }

    private static func le32(_ d: Data, _ o: Int) -> UInt64 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return UInt64(d[o]) | UInt64(d[o + 1]) << 8
            | UInt64(d[o + 2]) << 16 | UInt64(d[o + 3]) << 24
    }

    /// 解析 ZIP 的中央目录，返回条目表（含 `localHeaderOffset`）.
    ///
    /// **只解析不解压** —— 配合 `fs.read` 的 offset/length，就能把 IPA 里任意
    /// 一个文件（如 `SC_Info/Via.sinf`，几 KB）单独取出来，
    /// 不必把 3.5MB 整包传回本地.
    private static func zipEntries(path: String) -> ([[String: Any]]?, String) {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return (nil, "打开失败：\(path)")
        }
        defer { try? fh.close() }
        let total = (try? fh.seekToEnd()) ?? 0
        guard total > 22 else { return (nil, "文件太小，不是 zip") }

        let tailLen = Int(min(total, 70_000))
        try? fh.seek(toOffset: total - UInt64(tailLen))
        guard let tail = try? fh.read(upToCount: tailLen), tail.count >= 22 else {
            return (nil, "读尾部失败")
        }
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4b, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return (nil, "找不到 EOCD，不是有效 zip") }

        var entryCount = le16(tail, eocd + 10)
        var cdSize = le32(tail, eocd + 12)
        var cdOffset = le32(tail, eocd + 16)

        // zip64 兜底：上面三个字段全 FFFF/FFFFFFFF 时去 zip64 EOCD locator 取真值
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let loc = eocd - 20
            if loc >= 0, tail[loc] == 0x50, tail[loc + 1] == 0x4b,
               tail[loc + 2] == 0x06, tail[loc + 3] == 0x07 {
                try? fh.seek(toOffset: le32(tail, loc + 8))
                if let z = try? fh.read(upToCount: 56), z.count >= 56 {
                    entryCount = Int(le32(z, 32))
                    cdSize = le32(z, 40)
                    cdOffset = le32(z, 48)
                }
            }
        }
        guard cdOffset + cdSize <= total else { return (nil, "中央目录越界") }
        try? fh.seek(toOffset: cdOffset)
        guard let cd = try? fh.read(upToCount: Int(cdSize)) else { return (nil, "读中央目录失败") }

        var out: [[String: Any]] = []
        var p = 0
        while p + 46 <= cd.count && (entryCount == 0 || out.count < entryCount) {
            guard cd[p] == 0x50, cd[p + 1] == 0x4b,
                  cd[p + 2] == 0x01, cd[p + 3] == 0x02 else { break }
            let method = le16(cd, p + 10)
            var csize = le32(cd, p + 20)
            var usize = le32(cd, p + 24)
            let nameLen = le16(cd, p + 28)
            let extraLen = le16(cd, p + 30)
            let commentLen = le16(cd, p + 32)
            var lho = le32(cd, p + 42)
            let nameEnd = min(p + 46 + nameLen, cd.count)
            let name = String(data: cd.subdata(in: (p + 46)..<nameEnd), encoding: .utf8) ?? ""

            // zip64 扩展字段（id 0x0001）：顺序固定 usize / csize / lho
            var e = p + 46 + nameLen
            let exEnd = min(e + extraLen, cd.count)
            while e + 4 <= exEnd {
                let hid = le16(cd, e)
                let hsz = le16(cd, e + 2)
                if hid == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= exEnd { usize = le32(cd, q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= exEnd { csize = le32(cd, q); q += 8 }
                    if lho == 0xFFFF_FFFF, q + 8 <= exEnd { lho = le32(cd, q); q += 8 }
                    break
                }
                e += 4 + hsz
            }
            out.append([
                "name": name,
                "method": method,                    // 0=stored 8=deflate
                "compressedSize": Int(csize),
                "size": Int(usize),
                "localHeaderOffset": Int(lho),
                "flags": le16(cd, p + 8),            // 通用位标志（bit3 = 0x08：用了 data descriptor）
            ])
            p += 46 + nameLen + extraLen + commentLen
        }
        return (out, "")
    }

    /// `pkg.list`：列 IPA / ZIP 内条目（可 `match` 过滤）.
    private static func pkgList(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return fail("pkg.list 缺少 path")
        }
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            return fail("pkg.list 只支持 App 沙盒内路径",
                        extra: ["resolved": path, "home": homeDir])
        }
        let (entries, err) = zipEntries(path: path)
        guard let entries else {
            return fail("解析 zip 失败：\(err)", extra: ["resolved": path])
        }
        let filter = ((args["match"] as? String) ?? "").lowercased()
        let filtered = filter.isEmpty ? entries
            : entries.filter { (($0["name"] as? String) ?? "").lowercased().contains(filter) }
        // 默认上限 500 条：大 IPA 有几千个条目，全吐出来会把 SSH 通道撑爆.
        // 要看全部就显式传 limit:0，或先用 match 过滤.
        let limit = (args["limit"] as? Int) ?? 500
        let shown = limit > 0 ? Array(filtered.prefix(limit)) : filtered
        return ok([
            "count": filtered.count,
            "totalEntries": entries.count,
            "returned": shown.count,
            "truncated": shown.count < filtered.count,
            "entries": shown,
            "resolved": path,
        ])
    }

    /// `pkg.read`：读 IPA / ZIP 内单个条目（stored 直读 / deflate 解压）.
    private static func pkgRead(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty,
              let want = args["entry"] as? String, !want.isEmpty else {
            return fail("pkg.read 需要 path + entry")
        }
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            return fail("pkg.read 只支持 App 沙盒内路径",
                        extra: ["resolved": path, "home": homeDir])
        }
        let (entries, err) = zipEntries(path: path)
        guard let entries else {
            return fail("解析 zip 失败：\(err)", extra: ["resolved": path])
        }

        // 精确匹配 → 路径后缀匹配（IPA 内都是 Payload/X.app/... 长路径）
        var hit = entries.first { ($0["name"] as? String) == want }
        if hit == nil {
            hit = entries.first { (($0["name"] as? String) ?? "").hasSuffix("/" + want) }
        }
        if hit == nil {
            hit = entries.first {
                (($0["name"] as? String) ?? "").lowercased().hasSuffix(want.lowercased())
            }
        }
        guard let entry = hit,
              let name = entry["name"] as? String,
              let lho = entry["localHeaderOffset"] as? Int,
              let method = entry["method"] as? Int,
              let csize = entry["compressedSize"] as? Int,
              let usize = entry["size"] as? Int else {
            return fail("包内没有这个条目：\(want)",
                        extra: ["resolved": path, "totalEntries": entries.count])
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { return fail("打开失败：\(path)") }
        defer { try? fh.close() }
        // 本地头 30 字节固定 + 文件名 + 扩展字段
        try? fh.seek(toOffset: UInt64(lho))
        guard let lh = try? fh.read(upToCount: 30), lh.count >= 30 else {
            return fail("读本地头失败", extra: ["entry": name])
        }
        let dataStart = UInt64(lho + 30 + le16(lh, 26) + le16(lh, 28))
        try? fh.seek(toOffset: dataStart)
        guard let raw = try? fh.read(upToCount: csize) else {
            return fail("读条目数据失败", extra: ["entry": name])
        }

        let out: Data
        if method == 0 {
            out = raw
        } else if method == 8 {
            guard let inflated = inflateRaw(raw, expected: usize) else {
                return fail("deflate 解压失败",
                            extra: ["entry": name, "method": method, "compressedSize": csize])
            }
            out = inflated
        } else {
            return fail("不支持的压缩方式 method=\(method)", extra: ["entry": name])
        }

        let encoding = (args["encoding"] as? String) ?? "base64"
        guard let text = encode(out, encoding: encoding) else {
            return fail("按 \(encoding) 编码失败", extra: ["size": out.count])
        }
        return ok([
            "entry": name,
            "method": method,
            "size": out.count,
            "declaredSize": usize,
            "data": text,
            "encoding": encoding,
            "resolved": path,
        ])
    }

    /// 解 ZIP 的 method 8（raw deflate）.
    /// Apple 的 `COMPRESSION_ZLIB` 吃的就是 raw deflate（无 zlib 头），与 ZIP 一致.
    private static func inflateRaw(_ src: Data, expected: Int) -> Data? {
        let cap = max(expected, 64)
        var dst = Data(count: cap)
        let n = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let dBase = d.bindMemory(to: UInt8.self).baseAddress,
                      let sBase = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dBase, cap, sBase, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        return dst.prefix(n)
    }

    // MARK: - pkg.stat（IPA 体检：ZIP 摘要 + Mach-O cryptid + sinf）

    /// `pkg.stat` —— 一次拿全 IPA 体检摘要，**零字节搬运**（响应里没有任何文件字节）.
    ///
    /// 入参：`path`（App 沙盒内的 IPA/ZIP 路径，规则同 `pkg.list`）。
    ///
    /// 返回（详见 `pkgStatSync`）：中央目录条目数 / 重复条目名 / 孤儿 local header /
    /// data descriptor 计数 / bit3 条目数；`Payload/*.app` 结构；主二进制 `cryptid`
    /// （Mach-O `LC_ENCRYPTION_INFO(_64)`，支持 thin 与 fat）；`SC_Info/*.sinf` 的
    /// 格式判定（sinf-TLV 容器 / SuperBlob / 疑似 hex 被当 base64 解码）。
    ///
    /// ## 硬超时
    /// 整个分析（含全文件扫描）包在 **30s 硬超时** 里：超时明确报错、不挂住调用线程。
    /// 扫描是**分块**的（4MB/块），**不会把 230MB 的整包读进内存**。
    private static func pkgStat(_ args: [String: Any]) -> (Int32, String) {
        guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
            return fail("pkg.stat 缺少 path")
        }
        let path = resolvePath(rawPath)
        guard isInSandbox(path) else {
            return fail("pkg.stat 只支持 App 沙盒内路径",
                        extra: ["resolved": path, "home": homeDir])
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return fail("文件不存在：\(path)", extra: ["resolved": path])
        }

        let timeout: TimeInterval = 30
        let sem = DispatchSemaphore(value: 0)
        let box = StatBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = pkgStatSync(path: path)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return fail("pkg.stat 超时（\(Int(timeout)) 秒）：已放弃等待，避免阻塞调用线程，"
                        + "大包请改用 pkg.list / pkg.read 分步做.",
                        extra: ["resolved": path, "timeoutSeconds": Int(timeout)])
        }
        guard let result = box.result else {
            return fail("pkg.stat 失败（后台未产生结果）", extra: ["resolved": path])
        }
        return result
    }

    /// 后台结果盒子（写入在 `sem.signal()` 之前、读取在 `sem.wait()` 之后，有 happens-before）
    private final class StatBox: @unchecked Sendable {
        var result: (Int32, String)?
    }

    /// `pkg.stat` 的真正实现（阻塞；由 `pkgStat` 放到后台队列并加超时）.
    private static func pkgStatSync(path: String) -> (Int32, String) {
        let (entries, err) = zipEntries(path: path)
        guard let entries else {
            return fail("解析 zip 失败：\(err)", extra: ["resolved": path])
        }
        let totalEntries = entries.count

        // ── 重复条目名 ──
        var seen = Set<String>()
        var dupNames: [String] = []
        for e in entries {
            let n = (e["name"] as? String) ?? ""
            if !seen.insert(n).inserted, !dupNames.contains(n) { dupNames.append(n) }
        }

        // ── 扫描 local header（**做结构校验**，避免数据里碰巧的 PK\x03\x04 误报，F4）──
        let localScan = scanLocalHeaders(path: path, cap: 20000)
        // data descriptor：PK\x07\x08 只是 4 字节签名、无结构可校验 ⇒ 按原始出现次数报（如实标注）
        let ddScan = scanSignature(path: path, sig: Data([0x50, 0x4B, 0x07, 0x08]), cap: 20000)

        // 孤儿 local header：结构自洽、但偏移不被任何中央目录条目引用（返回**文件名**，最多 64 个）
        var cdOffsets = Set<Int>()
        for e in entries { if let o = e["localHeaderOffset"] as? Int { cdOffsets.insert(o) } }
        var orphanLocal: [String] = []
        var orphanLocalCount = 0
        for (i, off) in localScan.offsets.enumerated() where !cdOffsets.contains(off) {
            orphanLocalCount += 1
            if orphanLocal.count < 64 { orphanLocal.append(localScan.names[i]) }
        }

        // 宣称 bit3（用了 data descriptor）的条目数
        let bit3Entries = entries.filter { ((($0["flags"] as? Int) ?? 0) & 0x08) != 0 }.count

        // 中央目录驱动的结构校验（**不是**逐条 CRC 校验）
        let testzipOk = verifyLocalHeaders(path: path, entries: entries)

        // ── Payload 结构 ──
        let payload = payloadSummary(entries: entries, path: path)
        let appName = (payload["app"] as? String) ?? ""
        let exe = (payload["exe"] as? String) ?? ""
        let exeEntryName = (appName.isEmpty || exe.isEmpty) ? "" : "Payload/\(appName)/\(exe)"

        // ── 主二进制 cryptid ──
        let macho = machOCryptid(path: path, exeEntryName: exeEntryName, entries: entries)
        // F2/F6：cryptid 未知时给 null，**不要给 0** —— 否则与「未加密（读到 LC 且 cryptid=0）」混淆
        let cryptidKnown = (macho.source != "unknown")
        let cryptidValue: Any = cryptidKnown ? macho.cryptid : NSNull()

        // ── sinf 判定 ──
        let sinf = sinfSummary(entries: entries, path: path, exe: exe)

        var extra: [String: Any] = [
            "totalEntries": totalEntries,
            "centralCount": totalEntries,     // schema 字段；与 totalEntries 同源（都来自中央目录）
            "dupNames": dupNames,
            "orphanLocal": orphanLocal,
            "orphanLocalCount": orphanLocalCount,
            "payload": payload,
            "exe": exe,                       // schema 顶层也有 exe
            "cryptid": cryptidValue,          // int|null（schema）
            "cryptidKnown": cryptidKnown,     // 显式区分「未加密=0」与「无法判定」
            "cryptidSource": macho.source,
            "sinf": sinf,
            "zip": [
                "testzipOk": testzipOk,
                "localHeaders": localScan.offsets.count,        // 结构自洽的 local header 数
                "localHeaderCandidates": localScan.candidates,  // 原始 PK\x03\x04 命中数（含误报）
                "descriptors": ddScan.count,
                "bit3Entries": bit3Entries,
            ],
            "resolved": path,
        ]
        if !macho.note.isEmpty { extra["cryptidNote"] = macho.note }
        return ok(extra)
    }

    /// local header 扫描结果
    private struct LocalHeaderScan {
        var candidates: Int        // 原始 PK\x03\x04 命中数（含数据里碰巧出现的）
        var offsets: [Int]         // 通过结构校验的偏移
        var names: [String]        // 与 offsets 一一对应的文件名
    }

    /// 扫描 local header：先用字节签名找候选，再对每个候选做**结构校验**
    /// （签名 / version-needed ∈ 10..63 / nameLen ∈ 1..255 / 文件名可打印），
    /// **只保留结构自洽的** —— 这样 stored/deflate 数据里碰巧出现的 `PK\x03\x04`
    /// 不会被误报成孤儿头（F4）。
    private static func scanLocalHeaders(path: String, cap: Int) -> LocalHeaderScan {
        let cand = scanSignature(path: path, sig: Data([0x50, 0x4B, 0x03, 0x04]), cap: cap)
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return LocalHeaderScan(candidates: cand.count, offsets: [], names: [])
        }
        defer { try? fh.close() }
        var offsets: [Int] = []
        var names: [String] = []
        for off in cand.positions {
            if let name = localHeaderName(fh: fh, offset: off) {
                offsets.append(off)
                names.append(name)
            }
        }
        return LocalHeaderScan(candidates: cand.count, offsets: offsets, names: names)
    }

    /// 读 `offset` 处的 local file header 并做结构校验；通过返回文件名，否则 nil.
    /// local file header 布局：签名(4) / version-needed(2)@4 / flags(2)@6 / method(2)@8 …
    ///                        / nameLen(2)@26 / extraLen(2)@28 / name@30
    private static func localHeaderName(fh: FileHandle, offset: Int) -> String? {
        guard offset >= 0, (try? fh.seek(toOffset: UInt64(offset))) != nil,
              let h = try? fh.read(upToCount: 30), h.count == 30 else { return nil }
        let b = h.startIndex
        guard h[b] == 0x50, h[b + 1] == 0x4B, h[b + 2] == 0x03, h[b + 3] == 0x04 else { return nil }
        let versionNeeded = le16(h, 4)
        let nameLen = le16(h, 26)
        guard versionNeeded >= 10, versionNeeded <= 63, nameLen >= 1, nameLen <= 255 else { return nil }
        guard let nameData = try? fh.read(upToCount: nameLen), nameData.count == nameLen,
              let name = String(data: nameData, encoding: .utf8), !name.isEmpty else { return nil }
        // 文件名应可打印（UTF-8 多字节中文也算；排除控制字符）
        guard name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return name
    }

    /// 分块扫描整个文件，统计 4 字节签名的出现次数并记录起始偏移（最多记 `cap` 个）。
    /// 块间保留 3 字节重叠，避免签名跨块漏计；用 `Data.range(of:)` 走底层优化搜索。
    private static func scanSignature(path: String, sig: Data, cap: Int) -> (count: Int, positions: [Int]) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (0, []) }
        defer { try? fh.close() }
        let chunkSize = 4 << 20
        var count = 0
        var positions: [Int] = []
        var fileOffset = 0
        var carry = Data()
        while true {
            let chunk = (try? fh.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            var buf = carry
            buf.append(chunk)
            let base = fileOffset - carry.count
            var search = buf.startIndex
            while search < buf.endIndex,
                  let r = buf.range(of: sig, options: [], in: search..<buf.endIndex) {
                count += 1
                if positions.count < cap { positions.append(base + (r.lowerBound - buf.startIndex)) }
                search = r.lowerBound + sig.count
            }
            carry = buf.count >= 3 ? buf.suffix(3) : buf
            fileOffset += chunk.count
        }
        return (count, positions)
    }

    /// 中央目录驱动的结构校验：每个条目在其 `localHeaderOffset` 处都应能找到
    /// `PK\x03\x04` 本地头签名。
    ///
    /// 注意： 这**不是** `zip.testzip()` 的等价物，也**不是**完整校验 ——
    /// 它只看「中央目录 ↔ 本地头」是否对齐，**看不到** local header 与真实数据的
    /// 边界错位、也不逐条验 CRC。所以它通过**不等于**包是好的。
    private static func verifyLocalHeaders(path: String, entries: [[String: Any]]) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        for e in entries {
            guard let off = e["localHeaderOffset"] as? Int, off >= 0 else { return false }
            guard (try? fh.seek(toOffset: UInt64(off))) != nil,
                  let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
            let b = head.startIndex
            guard head[b] == 0x50, head[b + 1] == 0x4B,
                  head[b + 2] == 0x03, head[b + 3] == 0x04 else { return false }
        }
        return true
    }

    /// 读出 ZIP 条目**解压后前 `maxOut` 字节**。
    ///
    /// - stored（method 0）：直读。
    /// - deflate（method 8）：读入至多 `maxOut` 压缩字节后用 `compression_decode_buffer`
    ///   只解到 `maxOut` —— 与 `IPAPackageInspector.inflatePrefix` 同一手法，
    ///   **不把几十 MB 的主二进制整个展开**。
    private static func zipEntryPrefix(path: String, entry: [String: Any], maxOut: Int) -> Data? {
        guard maxOut > 0,
              let lho = entry["localHeaderOffset"] as? Int,
              let method = entry["method"] as? Int,
              let csize = entry["compressedSize"] as? Int else { return nil }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(max(0, lho)))
        guard let lh = try? fh.read(upToCount: 30), lh.count >= 30 else { return nil }
        let dataStart = UInt64(lho + 30 + le16(lh, 26) + le16(lh, 28))
        try? fh.seek(toOffset: dataStart)

        if method == 0 {
            let want = min(csize, maxOut)
            guard want > 0 else { return Data() }
            return (try? fh.read(upToCount: want)) ?? nil
        }
        if method == 8 {
            let wantComp = min(csize, maxOut)   // 压缩数据必然 <= 解压后，读这么多足够
            guard wantComp > 0, let comp = try? fh.read(upToCount: wantComp), !comp.isEmpty else {
                return nil
            }
            return inflatePrefixCapped(comp, maxOut: maxOut)
        }
        return nil
    }

    /// raw DEFLATE 解压，只取前 `maxOut` 字节（`COMPRESSION_ZLIB` = 无 zlib 头的 raw deflate）
    private static func inflatePrefixCapped(_ input: Data, maxOut: Int) -> Data? {
        var out = Data(count: maxOut)
        let written: Int = out.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, maxOut, srcBase, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(out.prefix(written))
    }

    /// 解析 `Payload/*.app` 结构（app 名 / 是否有 Info.plist / _CodeSignature / SC_Info / 可执行名）.
    private static func payloadSummary(entries: [[String: Any]], path: String) -> [String: Any] {
        var appName = ""
        for e in entries {
            let n = (e["name"] as? String) ?? ""
            guard n.hasPrefix("Payload/") else { continue }
            let rest = String(n.dropFirst("Payload/".count))
            if let r = rest.range(of: ".app/") {
                appName = String(rest[rest.startIndex..<r.lowerBound]) + ".app"
                break
            }
        }

        var hasInfo = false, hasCS = false, hasSC = false
        if !appName.isEmpty {
            let prefix = "Payload/\(appName)/"
            for e in entries {
                let n = (e["name"] as? String) ?? ""
                guard n.hasPrefix(prefix) else { continue }
                let tail = String(n.dropFirst(prefix.count))
                if tail == "Info.plist" { hasInfo = true }
                if tail.hasPrefix("_CodeSignature/") { hasCS = true }
                if tail.hasPrefix("SC_Info/") { hasSC = true }
            }
        }

        // exe 优先取 Info.plist 的 CFBundleExecutable；取不到就退回 app 名去扩展名
        var exe = appName.hasSuffix(".app") ? String(appName.dropLast(4)) : appName
        if hasInfo, !appName.isEmpty {
            let infoName = "Payload/\(appName)/Info.plist"
            if let entry = entries.first(where: { ($0["name"] as? String) == infoName }),
               let data = zipEntryPrefix(path: path, entry: entry, maxOut: 1 << 20),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dict = plist as? [String: Any],
               let real = dict["CFBundleExecutable"] as? String, !real.isEmpty {
                exe = real
            }
        }

        return ["app": appName, "hasInfoPlist": hasInfo, "hasCodeSignature": hasCS,
                "hasSCInfo": hasSC, "exe": exe]
    }

    /// 从主二进制解析 `cryptid`（Mach-O `LC_ENCRYPTION_INFO` 0x21 / `LC_ENCRYPTION_INFO_64` 0x2C），
    /// **支持 thin 与 fat**.
    ///
    /// 返回 `(cryptid, source, note)`：`source` 是命中的加载命令名（或 `none` / `unknown`），
    /// `note` 是补充说明（fat 切片信息 / 解析失败原因），空串表示无补充。
    private static func machOCryptid(path: String, exeEntryName: String,
                                     entries: [[String: Any]]) -> (cryptid: Int, source: String, note: String) {
        guard !exeEntryName.isEmpty,
              let entry = entries.first(where: { ($0["name"] as? String) == exeEntryName }) else {
            return (0, "unknown", "主二进制不在包内（entry=\(exeEntryName.isEmpty ? "<未识别>" : exeEntryName)）")
        }
        guard let head = zipEntryPrefix(path: path, entry: entry, maxOut: 256 * 1024), head.count >= 8 else {
            return (0, "unknown", "主二进制解压失败或过短")
        }

        let le = le32(head, 0)
        let be = be32(head, 0)

        // thin（本机序或字节序反转都认）
        if le == 0xFEEDFACE || be == 0xFEEDFACE || le == 0xFEEDFACF || be == 0xFEEDFACF {
            let is64 = (le == 0xFEEDFACF || be == 0xFEEDFACF)
            let bigEndian = (be == 0xFEEDFACE || be == 0xFEEDFACF)
            if let r = parseThinMachOCryptid(head, base: 0, is64: is64, bigEndian: bigEndian) {
                return (r.0, r.1, "")
            }
            return (0, "unknown", "Mach-O 加载命令解析失败")
        }

        // fat（big-endian）
        if be == 0xCAFEBABE || be == 0xCAFEBABF {
            let fat64 = (be == 0xCAFEBABF)
            let nArch = Int(be32(head, 4))
            guard nArch > 0, nArch <= 64 else { return (0, "unknown", "fat 头 nArch 异常：\(nArch)") }
            let archSize = fat64 ? 32 : 20
            guard 8 + nArch * archSize <= head.count else {
                return (0, "unknown", "fat 架构表超出已读头部")
            }
            // 优先 arm64（cputype 0x0100000C），否则第一片
            var sliceOffset = 0
            var chosenCPU: UInt32 = 0
            for i in 0..<nArch {
                let e = 8 + i * archSize
                let cputype = be32(head, e)
                let off = Int(be32(head, e + 8))
                if i == 0 { sliceOffset = off; chosenCPU = cputype }
                if cputype == 0x0100000C { sliceOffset = off; chosenCPU = cputype; break }
            }
            // 需要把解压流推进到 slice 偏移 + 64KB；上限 16MB 防极端 fat 撑爆内存
            let cap = min(sliceOffset + 64 * 1024, 16 * 1024 * 1024)
            guard let all = zipEntryPrefix(path: path, entry: entry, maxOut: cap),
                  all.count >= sliceOffset + 8 else {
                return (0, "unknown", "fat 的切片偏移 \(sliceOffset) 超出可解出范围（上限 16MB）")
            }
            let slice = Data(all[sliceOffset...])
            let sLE = le32(slice, 0), sBE = be32(slice, 0)
            let is64 = (sLE == 0xFEEDFACF || sBE == 0xFEEDFACF)
            let bigEndian = (sBE == 0xFEEDFACE || sBE == 0xFEEDFACF)
            if let r = parseThinMachOCryptid(slice, base: 0, is64: is64, bigEndian: bigEndian) {
                return (r.0, r.1, "fat/\(fat64 ? "64" : "32")，切片 cputype=0x\(String(chosenCPU, radix: 16))，sliceOffset=\(sliceOffset)")
            }
            return (0, "unknown", "fat 切片加载命令解析失败")
        }

        return (0, "unknown",
                "不是可识别的 Mach-O（magic le=0x\(String(le, radix: 16)) be=0x\(String(be, radix: 16))）")
    }

    /// 解析 thin Mach-O 的加密加载命令；返回 `(cryptid, 命令名)`。
    /// 解析成功但无加密命令 ⇒ `(0, "none")`；结构异常 ⇒ nil。
    private static func parseThinMachOCryptid(_ data: Data, base: Int, is64: Bool,
                                              bigEndian: Bool) -> (Int, String)? {
        let headerSize = is64 ? 32 : 28
        guard base + headerSize <= data.count else { return nil }
        let ncmds = Int(read32(data, base + 16, bigEndian: bigEndian))
        var p = base + headerSize
        for _ in 0..<ncmds {
            guard p + 8 <= data.count else { return nil }
            let cmd = read32(data, p, bigEndian: bigEndian)
            let cmdsize = Int(read32(data, p + 4, bigEndian: bigEndian))
            if cmd == 0x2C || cmd == 0x21 {
                guard p + 20 <= data.count else { return nil }
                let cryptid = Int(read32(data, p + 16, bigEndian: bigEndian))
                return (cryptid, cmd == 0x2C ? "LC_ENCRYPTION_INFO_64" : "LC_ENCRYPTION_INFO")
            }
            guard cmdsize >= 8 else { return nil }
            p += cmdsize
        }
        return (0, "none")
    }

    /// 读 32 位（可选字节序）
    private static func read32(_ d: Data, _ o: Int, bigEndian: Bool) -> UInt32 {
        return bigEndian ? be32(d, o) : UInt32(le32(d, o))
    }

    /// 判定 `SC_Info/*.sinf` 的存在与格式（**两种格式都认**）.
    private static func sinfSummary(entries: [[String: Any]], path: String, exe: String) -> [String: Any] {
        let sinfEntries = entries.filter { e in
            let name = (e["name"] as? String) ?? ""
            return name.hasPrefix("Payload/") && name.contains(".app/SC_Info/") && name.hasSuffix(".sinf")
        }
        guard !sinfEntries.isEmpty else {
            return ["present": false, "reason": "包内无 Payload/*.app/SC_Info/*.sinf"]
        }
        // 优先与可执行文件同名的那一个
        let preferred = sinfEntries.first {
            (($0["name"] as? String) ?? "").hasSuffix("/\(exe).sinf")
        } ?? sinfEntries[0]
        let fullName = (preferred["name"] as? String) ?? ""
        let shortName = fullName.split(separator: "/").last.map(String.init) ?? fullName

        guard let data = zipEntryPrefix(path: path, entry: preferred, maxOut: 64 * 1024), !data.isEmpty else {
            return ["present": true, "name": shortName, "len": 0, "format": "unknown",
                    "verdict": "sinf 存在但读不出来", "structurallyValid": false,
                    "hexOrBase64Misdecode": false]
        }
        let (format, verdict, valid) = classifySinf(data)
        let misdecoded = looksLikeHexAsBase64(data)
        var out: [String: Any] = ["present": true, "name": shortName, "len": data.count,
                                  "format": format, "verdict": verdict,
                                  "structurallyValid": valid,
                                  "hexOrBase64Misdecode": misdecoded]
        if misdecoded {
            out["misdecodeNote"] = "长度≈合法 sinf 长度×1.5 且 base64 再编码后全为 hex 字符："
                + "疑似 hex 文本被当 base64 解码（判据未用真机样本校准）"
        }
        return out
    }

    /// sinf 格式判定（**不要**把 `00 00 04 30` 之类的长度当固定魔数）.
    ///
    /// 返回 `(format, verdict, structurallyValid)`：
    /// - `format ∈ superblob | container | unknown`（对齐 schema）；
    /// - `verdict`：人读的判定（以「结构自洽」开头 = 好；「可疑」/「垃圾/损坏」= 坏）；
    /// - `structurallyValid`：机器可读的**质量门**信号（消费方应据此拒收坏包）。
    ///
    /// ## 判据（F3：不只看顶层长度，还要递归验子结构）
    /// - **superblob**：`magic 0xFADE0CC0` + 声明长度 == 实际 + `count` 与索引表条数一致（0<count≤32）
    ///   + 每个 blob 偏移在界内 + 含 CodeDirectory(type=0)。
    /// - **container**：`{4B 大端总长}` + `"sinf"` + 递归 TLV；顶层长度 == 实际，
    ///   且**递归聚合**「子项恰好铺满」（内层越界/空洞也算坏），并含 `frma` 或 `schi`。
    ///
    /// 为什么必须递归：只验顶层会让「顶层长度对、内层块长度错」的坏包被判成自洽 —— 漏报坏包
    /// 比误报更危险（用户装上去会闪退）。
    private static func classifySinf(_ data: Data) -> (format: String, verdict: String, valid: Bool) {
        let len = data.count
        if len < 8 {
            return ("unknown", "垃圾：长度不足 8 字节", false)
        }

        // ---- SuperBlob：magic(4) + length(4) + count(4) + count×(type(4)+offset(4)) + blobs ----
        if be32(data, 0) == 0xFADE0CC0 {
            let declared = Int(be32(data, 4))
            let count = len >= 12 ? Int(be32(data, 8)) : 0
            // 索引表是**定长 8 字节步进**（type 4B + offset 4B），不能用 offset 推进指针
            var blobTypes: [UInt32] = []
            var blobOffsets: [Int] = []
            var p = 12
            for _ in 0..<min(count, 64) {
                guard p + 8 <= len else { break }
                blobTypes.append(be32(data, p))
                blobOffsets.append(Int(be32(data, p + 4)))
                p += 8
            }
            let countOk = (count == blobOffsets.count) && count > 0 && count <= 32
            let offsetsOk = !blobOffsets.isEmpty && blobOffsets.allSatisfy { $0 > 0 && $0 < len }
            let hasCodeDirectory = blobTypes.contains(0)

            if declared != len {
                return ("superblob", "垃圾/损坏：声明长度 \(declared) != 实际 \(len)", false)
            }
            if !countOk {
                return ("superblob", "垃圾/损坏：blob 计数 \(count) 与索引不一致（实际索引 \(blobOffsets.count) 条）", false)
            }
            if !offsetsOk {
                return ("superblob", "垃圾/损坏：blob 偏移越界", false)
            }
            if !hasCodeDirectory {
                return ("superblob", "可疑：无 CodeDirectory(type=0) blob", false)
            }
            return ("superblob", "结构自洽，疑似有效 sinf（SuperBlob，count=\(count)）", true)
        }

        // ---- container：{4B 大端总长} + "sinf" + 递归 TLV ----
        if be32(data, 4) == 0x73696E66 {   // "sinf"
            let declared = Int(be32(data, 0))
            var tiled = true
            var tags: [String] = []
            walkSinfTLV(data, start: 0, end: len, depth: 0, tiled: &tiled, tags: &tags)

            if declared != len {
                return ("container", "垃圾/损坏：顶层声明长度 \(declared) != 实际 \(len)", false)
            }
            if !tiled {
                return ("container", "垃圾/损坏：TLV 子项未能恰好铺满（越界/空洞）", false)
            }
            if !(tags.contains("frma") || tags.contains("schi")) {
                return ("container", "可疑：缺少 frma/schi 关键子项", false)
            }
            return ("container", "结构自洽（sinf-TLV 容器，子项完整）", true)
        }

        return ("unknown", "垃圾：非 SuperBlob 也非 sinf-TLV 容器", false)
    }

    /// 递归遍历 sinf TLV 列表。块 = `{4B 大端长度}{4B tag}{长度-8 字节值}`；
    /// tag 为 `sinf`/`schi` 时**递归进其值**。
    ///
    /// `tiled` 必须**递归聚合**：只要任一层子项越界或没铺满，整体就不是自洽 ——
    /// 否则「顶层恰好铺满、内层越界」的坏包会被漏判（F3）。
    private static func walkSinfTLV(_ d: Data, start: Int, end: Int, depth: Int,
                                    tiled: inout Bool, tags: inout [String]) {
        guard depth < 8 else { return }        // 防病态深嵌套
        var off = start
        while off + 8 <= end {
            let ln = Int(be32(d, off))
            if ln < 8 || off + ln > end {
                tiled = false
                return
            }
            let tag = String(data: Data(d[(off + 4)..<(off + 8)]), encoding: .ascii) ?? ""
            tags.append(tag)
            if tag == "sinf" || tag == "schi" {
                walkSinfTLV(d, start: off + 8, end: off + ln, depth: depth + 1, tiled: &tiled, tags: &tags)
            }
            off += ln
        }
        if off != end { tiled = false }
    }

    /// 疑似「hex 文本被当 base64 解码」的启发式判据。
    ///
    /// 注意： **该阈值尚未用真机样本校准**（实现时设备 SSH 不可用，见交付报告）：
    /// 判据 = 长度恰为某已知合法 sinf 长度（1032/1048/1056/1072）× 1.5，
    /// 且把内容 base64 再编码后**全是 hex 字符**。
    /// 若日后拿到真机样本发现误报/漏报，可改成「按已知合法长度表比对」。
    private static func looksLikeHexAsBase64(_ data: Data) -> Bool {
        let legalLengths = [1032, 1048, 1056, 1072]
        guard legalLengths.contains(where: { Int(Double($0) * 1.5) == data.count }) else { return false }
        let b64 = data.base64EncodedString()
        guard !b64.isEmpty else { return false }
        return b64.allSatisfy { $0.isHexDigit }
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

    // MARK: - ui.screenshot

    /// `ui.screenshot` —— 经 RSD 隧道 + DVT 取设备当前屏幕（PNG）.
    ///
    /// ## 契约（对齐 `capability-schema.json` 的 `ui.screenshot`）
    /// - 入参：`toFile`（可选，落盘相对路径）、`overwrite`（可选，默认 `true`）、
    ///   `inline`（可选，默认 `false`；**本实现的扩展**，用来显式要 base64）。
    ///   `path` 作为 `toFile` 的兼容别名仍被接受。
    /// - **默认落盘**（设计正文：截图默认落盘，内联才 base64）：`toFile` 缺省时落到
    ///   `Documents/Screenshots/shot-<ts>.png`；只有 `inline:true` 才回传 base64。
    /// - 返回：落盘 `{ok,toFile,bytes,width,height,via}`；内联 `{ok,bytes,data,width,height,via}`。
    ///
    /// ## 底层与超时
    /// 走 `ScreenshotService`（**DVT 三连**，不是 screenshotr —— 本设备无 screenshotr 服务），
    /// **硬超时 15s**：超时返回明确错误，绝不挂住调用线程。不需要越狱，只需配对隧道。
    ///
    /// ## 为什么内联要设上限
    /// 真机 PNG 常 1–5MB，base64 后 1.3–6.6MB。能力通道有「响应被截断」的历史问题，
    /// 故内联超过 2MB 直接拒绝，要求改用 `toFile`。
    private static func uiScreenshot(_ args: [String: Any]) -> (Int32, String) {
        // toFile 优先；path 作兼容别名（老调用方不至于静默失效）
        let toFileRaw = (args["toFile"] as? String) ?? (args["path"] as? String)
        let overwrite = (args["overwrite"] as? Bool) ?? true
        let inline = (args["inline"] as? Bool) ?? false

        // 目标路径：给了 toFile 就归一化；没给就默认 Documents/Screenshots/shot-<ts>.png
        let resolved: String
        if let toFileRaw, !toFileRaw.isEmpty {
            let p = resolvePath(toFileRaw)
            guard isInSandbox(p) else {
                return fail("ui.screenshot 的 toFile 只支持 App 沙盒内路径",
                            extra: ["toFile": p, "home": homeDir])
            }
            resolved = p
        } else {
            let ts = Int(Date().timeIntervalSince1970)
            resolved = homeDir + "/Documents/Screenshots/shot-\(ts).png"
        }

        // 落盘模式下才做 overwrite 检查（内联不落盘）
        if !inline, !overwrite, FileManager.default.fileExists(atPath: resolved) {
            return fail("目标已存在且 overwrite=false：\(resolved)",
                        extra: ["toFile": resolved])
        }

        let png: Data
        do {
            png = try ScreenshotService.shared.capturePNG(timeout: 15)
        } catch {
            return fail("截图失败：\(error.localizedDescription)",
                        extra: ["via": "dvt.screenshot", "timeoutSeconds": 15])
        }

        let dims = pngDimensions(png)
        let width = dims?.0 ?? 0
        let height = dims?.1 ?? 0

        if inline {
            let cap = 2 * 1024 * 1024
            guard png.count <= cap else {
                return fail("PNG 超过内联上限 2MB，请改用 toFile 落盘",
                            extra: ["bytes": png.count, "width": width, "height": height,
                                    "via": "dvt.screenshot"])
            }
            return ok(["bytes": png.count, "data": png.base64EncodedString(),
                       "width": width, "height": height, "via": "dvt.screenshot"])
        }

        do {
            let parent = (resolved as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: resolved))
            return ok(["toFile": resolved, "bytes": png.count,
                       "width": width, "height": height, "via": "dvt.screenshot"])
        } catch {
            return fail("截图已拿到，但落盘失败：\(error.localizedDescription)",
                        extra: ["bytes": png.count, "via": "dvt.screenshot"])
        }
    }

    /// 读 PNG 的 IHDR 取宽高.
    /// 标准 PNG 签名是 **8 字节** `89 50 4E 47 0D 0A 1A 0A`（F7：此前只校验前 4 字节）。
    /// 之后：块长 4B + `"IHDR"` 4B ⇒ 宽在偏移 16、高在 20，均**大端** 32 位.
    private static func pngDimensions(_ data: Data) -> (Int, Int)? {
        guard data.count >= 24 else { return nil }
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(data.prefix(8)) == sig else { return nil }
        guard data[12] == 0x49, data[13] == 0x48, data[14] == 0x44, data[15] == 0x52 else {
            return nil   // 第 12..16 字节应是 "IHDR"
        }
        return (Int(be32(data, 16)), Int(be32(data, 20)))
    }

    /// 大端读 32 位（越界返回 0，不崩）
    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16
            | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
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

    /// 写门禁（SSH exec 暴露面）：只读根 ⇒ **明确报错**（错误码 + 人话），
    /// **不静默成功、不静默 no-op**。
    ///
    /// 判据来自**共享**的 `AfcRootPolicy`（`AFCService.swift`），与 SFTP 侧
    /// `AfcFileProvider` 用的是**同一份** —— 避免「两处各写一份 `== .crash`」再次漂移，
    /// 那正是本次绕过漏洞（`afc.delete {root:"crash",recursive:true}` 递归删崩溃日志）的根因。
    ///
    /// - Returns: `nil` 表示放行；非 `nil` 即拒绝用的 `(code, json)` 结果。
    private static func afcReadOnlyGuard(_ root: AfcRoot, op: String,
                                         path: String) -> (Int32, String)? {
        guard AfcRootPolicy.isReadOnly(root.rawValue) else { return nil }
        return fail("\(root.rawValue) 根只读（设计不变量 I1）：不允许 \(op)",
                    extra: ["code": "READONLY_ROOT",
                            "root": root.rawValue,
                            "rootPath": root.displayPath,
                            "path": path,
                            "reason": "崩溃日志是排查闪退的唯一现场，暴露面默认只读"])
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
        // I1 写门禁：crash 根只读 —— 先于任何连接/写入动作拒绝（共享判据）
        if let deny = afcReadOnlyGuard(root, op: "afc.write", path: path) { return deny }
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
        // I1 写门禁：crash 根只读 —— **recursive 与否都挡**（共享判据，先于任何连接/删除动作）
        if let deny = afcReadOnlyGuard(root, op: "afc.delete", path: path) { return deny }
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
                            + "AFC 无权删除它.",
                            extra: ["root": root.rawValue, "path": path,
                                    "note": "这类条目通常由系统账号创建（如 sysdiagnose 归档内容），"
                                          + "读/列通常仍可用，但删/写不行."])
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
        // I1 写门禁：crash 根只读 —— 先于任何连接/建目录动作拒绝（共享判据）
        if let deny = afcReadOnlyGuard(root, op: "afc.mkdir", path: path) { return deny }
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
