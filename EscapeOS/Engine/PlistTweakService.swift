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

import CryptoKit
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
        let raw = try read(path)
        let original = try parse(raw)
        var dict = original
        dict[key] = value
        try guardKeyCount(before: original.count, after: dict.count, op: "设置")
        let bytes = try write(path, dict: dict, originalData: raw)
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
        let raw = try read(path)
        let original = try parse(raw)
        var dict = original
        guard dict[key] != nil else { return false }
        dict.removeValue(forKey: key)
        try guardKeyCount(before: original.count, after: dict.count, op: "删除")
        let bytes = try write(path, dict: dict, originalData: raw)
        AirliftChangeLog.append(action: "plist-unset", path: path,
                                bytes: bytes, verified: false,
                                note: "删键 \(key)（回到系统默认）")
        return true
    }

    /// **灾难护栏**：键数变化必须是「一个键之内」，否则中止.
    ///
    /// ## 为什么（真机事故 2026-09-24）
    /// 那次读到的内容被截断成 1 个键（原 49 键），而我**照写不误**
    /// ⇒ 把用户的 SpringBoard 偏好文件覆盖没了.
    /// 事后看：**set / unset 只可能让键数不变或 ±1**，任何更大的变化
    /// 都说明「读坏了」或「逻辑错了」⇒ **宁可不动**.
    private static func guardKeyCount(before: Int, after: Int, op: String) throws {
        guard abs(after - before) <= 1 else {
            throw TweakError.parseFailed(
                "\(op)后键数从 \(before) 变成 \(after) —— 相差超过 1 个，"
                + "判定为**读到了被截断的内容**，已中止（**文件未被改动**）")
        }
        // 另一道：本来有一堆键、突然变成 1 个，几乎肯定是读坏了
        guard !(before > 3 && after <= 1) else {
            throw TweakError.parseFailed(
                "键数从 \(before) 掉到 \(after) —— 判定为读坏了，已中止（**文件未被改动**）")
        }
    }

    // MARK: - 内部

    /// **本地缓存**：airlift 读一次要 10~20 秒，绝不能每次改值都重读.
    ///
    /// ## 为什么必须缓存（用户反馈「就修改几个值要你多久」）
    /// 上一版为了「读得准」做了「连读两次要求一致」，而 airlift **每次读 10~20 秒**
    /// ⇒ 一次开关要读 2~4 遍再写 1 遍 ⇒ **1~2 分钟**. 那根本没法用.
    ///
    /// ⇒ 现在：**读一次就缓存**（落在 App 沙盒 `Documents/PlistTweakCache/`），
    ///   之后改值只在**本地副本**上改，再写一次 ⇒ **一次开关 = 1 次 airlift**.
    ///
    /// ## 缓存的正确性怎么保证
    /// - **形状护栏**：改一个键 ⇒ 键数只能 ±1（`guardKeyCount`）——
    ///   缓存过期最多让「读到的值」旧一点，**不会让我们写坏文件**
    /// - 想强制刷新：调 `refresh(path:)`（界面上的「重新读取」按钮）
    private static var cacheDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlistTweakCache", isDirectory: true)
    }

    private static func cacheURL(_ path: String) -> URL {
        // 路径当文件名会踩转义/长度坑 ⇒ 用 sha1
        let digest = Insecure.SHA1.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(20).description
        return cacheDir.appendingPathComponent(name + ".plist")
    }

    /// 缓存里有没有这个文件（界面用它决定要不要显示「重新读取」提示）.
    static func hasCache(path: String) -> Bool {
        FileManager.default.fileExists(atPath: cacheURL(path).path)
    }

    /// 强制从设备重读一遍并更新缓存（「重新读取」按钮走这条）.
    @discardableResult
    static func refresh(path: String) throws -> Int {
        let data = try readFromDevice(path)
        store(data, for: path)
        return data.count
    }

    /// 取内容：**缓存优先**；没缓存才真去设备读一次.
    private static func read(_ path: String) throws -> Data {
        if let cached = try? Data(contentsOf: cacheURL(path)), !cached.isEmpty {
            return cached
        }
        let data = try readFromDevice(path)
        store(data, for: path)
        return data
    }

    private static func store(_ data: Data, for path: String) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(path), options: .atomic)
    }

    /// 真去设备读（慢，10~20 秒）—— **带一次重试**，只在这里花时间.
    private static func readFromDevice(_ path: String) throws -> Data {
        var lastError = "未知"
        for attempt in 1...2 {
            let outcome = AirliftExploit.pocReadFile(path: path)
            if let data = outcome.data, !data.isEmpty {
                return data
            }
            lastError = outcome.summary
            if attempt == 1 { Thread.sleep(forTimeInterval: 3) }   // 会话冷却
        }
        throw TweakError.readFailed("读不到内容（\(lastError)）")
    }

    /// 把字典写回（二进制 plist），用 airlift 覆盖.
    ///
    /// ## 写入前先存快照
    /// 这里**不走** `airlift.overwrite`（那是能力层），所以备份要自己做 ——
    /// 用同一套 `AirliftBackupStore`：**1 号 = 初始备份（永不覆盖）**，
    /// 之后每次写前各存一份. 少了这一步，「还原」就没有回滚点.
    private static func write(_ path: String, dict: [String: Any],
                              originalData: Data) throws -> Int {
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: dict,
                                                      format: .binary, options: 0)
        } catch {
            throw TweakError.parseFailed("重新序列化失败：\(error.localizedDescription)")
        }

        // 写前快照（1 号 = 初始备份）
        //
        // 用**调用方已经读到的** `originalData`，**不再重读一遍** ——
        // 每次 airlift 读要 10~20 秒，而设备端会话不稳、读多了还会失败；
        // 少一次读 = 少一次失败机会 + 快一半.
        _ = AirliftBackupStore.snapshot(path: path, data: originalData, note: "plist tweak 前")

        // 再落进 AIR（AFC 根下，廉价），最后 airlift 覆盖目标
        let name = "plisttweak-\(UUID().uuidString.prefix(8)).plist"
        try? airWrite(name: name, data: data)

        // ⚠️ `pocWriteFile` 的签名是 `(path:data:)` —— **没有 backup 参数**
        //   （备份由调用方负责，见上面那步）
        let outcome = AirliftExploit.pocWriteFile(path: path, data: data)
        guard outcome.ok else {
            throw TweakError.writeFailed(outcome.summary)
        }
        // 写成功后把新内容更新进缓存 —— 下次改值就不用再读了
        store(data, for: path)
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
            // ⚠️ 真实签名是 `writeFile(client:data:to:)` —— 标签是 `to:`
            try AFCService.writeFile(client: client, data: data, to: dir + "/" + name)
        }
    }
}
