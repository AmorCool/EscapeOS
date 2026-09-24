//
//  PlistTweakService.swift
//  EscapeSpace
//
//  改**沙盒外** plist 里的单个键 —— 移植 Nugget 那套「系统选项」用的底座.
//
//  ## 为什么需要它
//  Nugget（leminlimez/Nugget）的功能本质是「往某个 plist 里写几个键」：
//  ```
//  TweakID.SBDontLockAfterCrash: BasicPlistTweak(FileLocation.springboard, "SBDontLockAfterCrash")
//  ```
//  而它自己的机制（SparseRestore / 部分恢复）**在 iOS 27 上已被 Apple 补掉**
//  （Nugget README 原文：DO NOT USE THIS ON iOS 27）⇒ 那套没法用.
//
//  但我们的 airlift 能**直接读写文件**，只要目标 plist 在可写区就行. 实测：
//  · `/var/mobile/Library/Preferences/com.apple.springboard.plist`（5764 B，49 个键）✓ 可写
//  · `/var/mobile/Library/Preferences/com.apple.sharingd.plist`（11746 B）✓ 可写
//  · `/var/mobile/Library/Preferences/com.apple.UIKit.plist`（341 B）✓ 可写
//  · 而且**`cfprefsd` 不会把我们写的内容冲掉**（实测：写入后立刻与 40 秒后读回，键都在）
//
//  ## 「还原」怎么做（跟 Nugget 一个思路）
//  Nugget 的 UI 每个设置三个单选 `Default / Enabled / Disabled`，
//  而 `Default` 的动作是 `set_enabled(False)` = **不碰这个键** ⇒
//  **「还原」= 把这个键删掉，让系统用它自己的默认值.**
//  ⇒ 本服务提供 `unset`；配合 `AirliftChangeLog`（记了改过哪些键）就能回滚.
//
//  ## 边界
//  · 只能改**已存在**的 plist（不新建文件 —— 新建要 airlift 能写，那没问题，
//    但 cfprefsd 对新文件的态度未验证，所以先不碰）
//  · 改完**不一定立刻生效**：SpringBoard 在启动时读这些偏好
//    ⇒ 多数要 respring / 重启才看得到效果
//

import Foundation

/// 改沙盒外 plist 单个键的服务（纯静态）.
enum PlistTweakService {

    enum TweakError: LocalizedError {
        case readFailed(String)
        case parseFailed(String)
        case writeFailed(String)
        case badArgs(String)

        var errorDescription: String? {
            switch self {
            case .readFailed(let m): return "读目标失败：\(m)"
            case .parseFailed(let m): return "解析 plist 失败：\(m)"
            case .writeFailed(let m): return "写回失败：\(m)"
            case .badArgs(let m): return "参数非法：\(m)"
            }
        }
    }

    /// 读一个沙盒外 plist 的全部键（值只回报类型与可读文本，不回报二进制内容）.
    static func readKeys(path: String) throws -> [String: String] {
        let data = try read(path)
        let dict = try parse(data)
        var out: [String: String] = [:]
        for (key, value) in dict {
            out[key] = describe(value)
        }
        return out
    }

    /// 设置一个键（值支持 `bool` / `int` / `double` / `string`）.
    ///
    /// - Returns: 写回后的文件字节数
    @discardableResult
    static func set(path: String, key: String, value: Any) throws -> Int {
        guard !key.isEmpty else { throw TweakError.badArgs("key 不能为空") }
        var dict = try parse(try read(path))
        dict[key] = value
        let bytes = try write(path, dict: dict)
        AirliftChangeLog.append(action: "plist-set", path: path,
                                bytes: bytes, verified: false,
                                note: "\(key) = \(describe(value))")
        return bytes
    }

    /// **删掉**一个键 —— 这就是「还原成系统默认」（Nugget 的 `Default` 语义）.
    ///
    /// - Returns: `true` = 键本来就在、已删；`false` = 本来就没有（无需改动）
    @discardableResult
    static func unset(path: String, key: String) throws -> Bool {
        guard !key.isEmpty else { throw TweakError.badArgs("key 不能为空") }
        var dict = try parse(try read(path))
        guard dict[key] != nil else { return false }
        dict.removeValue(forKey: key)
        let bytes = try write(path, dict: dict)
        AirliftChangeLog.append(action: "plist-unset", path: path,
                                bytes: bytes, verified: false,
                                note: "删键 \(key)（回到系统默认）")
        return true
    }

    // MARK: - 内部

    /// 用 airlift 把文件读进 Media，再取回来.
    private static func read(_ path: String) throws -> Data {
        let outcome = AirliftExploit.pocReadFile(path: path)
        guard let data = outcome.data else {
            throw TweakError.readFailed(outcome.summary)
        }
        return data
    }

    /// 把字典写回（二进制 plist），用 airlift 覆盖.
    private static func write(_ path: String, dict: [String: Any]) throws -> Int {
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: dict,
                                                      format: .binary, options: 0)
        } catch {
            throw TweakError.parseFailed("重新序列化失败：\(error.localizedDescription)")
        }
        // 先落进 AIR（AFC 根下，廉价），再 airlift 覆盖目标
        let name = "plisttweak-\(UUID().uuidString.prefix(8)).plist"
        do {
            try airWrite(name: name, data: data)
        } catch {
            throw TweakError.writeFailed("写 AIR 失败：\(error.localizedDescription)")
        }
        let outcome = AirliftExploit.pocWriteFile(path: path, data: data, backup: true)
        guard outcome.ok else {
            throw TweakError.writeFailed(outcome.summary)
        }
        return data.count
    }

    private static func parse(_ data: Data) throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [],
                                                                    format: &format),
              let dict = obj as? [String: Any] else {
            throw TweakError.parseFailed("不是字典形式的 plist（\(data.count) 字节）")
        }
        return dict
    }

    /// 把值描述成可读文本（界面用；二进制值只报大小）.
    private static func describe(_ value: Any) -> String {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return "\(i)"
        case let d as Double: return "\(d)"
        case let s as String: return s.count > 60 ? String(s.prefix(60)) + "…" : s
        case let d as Data: return "<\(d.count) 字节>"
        case let a as [Any]: return "[\(a.count) 项]"
        case let d as [String: Any]: return "{\(d.count) 键}"
        default: return "\(value)"
        }
    }

    /// 往 AIR 写一个文件（AFC 根下）.
    private static func airWrite(name: String, data: Data) throws {
        let dir = "/var/mobile/Media/AIR"
        try AFCService.shared.batch { client in
            if (try? AFCService.listDirectory(client: client, path: "/"))?
                .contains(where: { $0.name == "AIR" }) != true {
                try? AFCService.makeDirectory(client: client, path: dir)
            }
            try AFCService.writeFile(client: client, path: dir + "/" + name, data: data)
        }
    }
}
