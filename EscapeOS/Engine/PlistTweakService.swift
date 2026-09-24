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
        let raw = try readFresh(path)          // 写入底稿必须真读
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
        let raw = try readFresh(path)          // 写入底稿必须真读
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

    /// 本地缓存里的**统计**（字节 / 顶层键数）—— 给界面显示「当前是什么样」.
    ///
    /// 走缓存**不触发 airlift**（读一次 10~20 秒），所以界面能秒出.
    /// 缓存可能是过期的 ⇒ 返回值里带 `fresh: false` 的语义，界面要说明「可能不是最新」.
    ///
    /// - Returns: 没有缓存 ⇒ `nil`
    static func cachedStats(path: String) -> (bytes: Int, keys: Int?)? {
        guard let data = try? Data(contentsOf: cacheURL(path)), !data.isEmpty else { return nil }
        return (data.count, AirliftBackupStore.plistKeyCount(data))
    }

    /// 强制从设备重读一遍并更新缓存（「重新读取」按钮走这条）.
    ///
    /// 同样过 `readFresh` 的坏读检查 —— 别让一次坏读把缓存基准污染掉
    /// （否则后面那道护栏就废了）.
    @discardableResult
    static func refresh(path: String) throws -> Int {
        try readFresh(path).count
    }

    /// 取内容用于**展示**：缓存优先（快）.
    ///
    /// 注意：**不要拿它当「读—改—写」的底稿** —— 缓存可能是过期的（甚至是我们
    /// 之前写坏的旧状态），拿它当底稿会把坏状态写回去. 写入路径走 readFresh.
    ///
    /// 没有缓存时走 `readFresh`（而不是裸读）—— 免得把一次**坏读**的结果
    /// 当成基准存进缓存，把后面那道护栏废掉.
    private static func read(_ path: String) throws -> Data {
        if let cached = try? Data(contentsOf: cacheURL(path)), !cached.isEmpty {
            return cached
        }
        return try readFresh(path)
    }

    /// 取内容用于**写入底稿**：永远从设备真读，不走缓存.
    ///
    /// 为什么必须这样（真机踩过两次）：
    /// 缓存是性能优化（airlift 读一次 10~20 秒），但它会**过期** ——
    /// 2026-09-24 那次，缓存里是「被写坏的 21 键版本」，写入直接拿它当底稿，
    /// 于是**把坏状态又写回去了一次**. 正确性优先：写入前一律真读.
    ///
    /// ## 读回来的东西先过一道「可证明的坏读」检查
    /// 我们自己的每个操作（`set` / `unset`）只可能让键数 **±1**（`guardKeyCount`）.
    /// ⇒ 若**缓存里（= 我们上次亲手写进去的）有 ≥8 个键**，而这次**真读只剩 ≤1 个键**，
    /// 那在数学上就是**不可能**发生的 —— 必然是读坏了（真机事故就是这么发生的：
    /// 5764 B / 49 键的文件被读成 1 个键，然后照写不误 ⇒ 偏好文件被覆盖没了）.
    /// ⇒ **直接中止，且不把这份坏内容存进缓存**（否则下一次比对就失去基准）.
    ///
    /// 为什么这不是「自作聪明的启发式」（用户否决过那类东西）：
    /// 它不猜「哪份备份更好」，只在**违反我们自己维护的不变量**时拒绝写入，
    /// 而且判据是**单向**的（只拦「多→1」）—— 用户主动还原一份少键的备份时，
    /// 缓存里也是少键（写入后就更新了缓存）⇒ **不会误拦**.
    private static func readFresh(_ path: String) throws -> Data {
        let data = try readFromDevice(path)
        let freshKeys = AirliftBackupStore.plistKeyCount(data)
        if let cached = cachedStats(path: path)?.keys, cached >= 8, (freshKeys ?? 0) <= 1 {
            throw TweakError.readFailed(
                "读回的内容只有 \(freshKeys ?? 0) 个键，而我们上次写进去的是 \(cached) 个键 —— "
                + "单次操作不可能掉这么多，判定为**坏读**，已中止（**设备上的文件未被改动**）. "
                + "重试一次通常就好；一直失败就换个时间再试.")
        }
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
        // 3 次 + 退避（与 AirCard 的 retries=3 同款思路）
        for attempt in 1...3 {
            let outcome = AirliftExploit.pocReadFile(path: path)
            if let data = outcome.data, !data.isEmpty {
                return data
            }
            lastError = outcome.summary
            if attempt < 3 { Thread.sleep(forTimeInterval: 2 + 0.4 * Double(attempt)) }
        }
        throw TweakError.readFailed("连读 3 次都读不到（\(lastError)）")
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
        // 写成功后更新缓存（下次**显示**不用再读）
        store(data, for: path)

        // 关键一步：杀掉 cfprefsd，逼它从磁盘重读（否则写入会被它的内存副本覆盖回去）
        settlePreferences(path: path, note: "plist tweak 后")
        return data.count
    }

    /// **写完 plist 之后的收尾** —— 唯一能让偏好改动真正生效的办法.
    ///
    /// ## 为什么必须做（用户反馈「respring 了好像没有效果」）
    /// `Preferences/` 下的 plist 归 `cfprefsd` 管：它把偏好缓存在**内存**里，
    /// 而且会**间歇性把内存副本刷回磁盘**（实测：还原成 5764 B 后两分钟又被改回 3556 B）.
    /// 不杀它：一是设置不生效（进程读的是它的缓存，respring 也没用）；
    ///         二是我们的写入随时被它覆盖.
    /// 杀掉后 launchd 会立刻重启它，重启时从磁盘重读，我们的写入才真正生效.
    ///
    /// ## 为什么做成公开方法
    /// 一开始只在 `plist.tweak` 的写路径里杀了它 —— 而**「备份与还原」页是另一条路**
    /// （直接走 `AirliftExploit.pocWriteFile`），那条路没杀 ⇒ 从备份还原一个
    /// SpringBoard plist 之后，cfprefsd 会**把我们刚还原的内容再覆盖回去**.
    /// 两条路必须共用同一套收尾.
    ///
    /// - Returns: 杀掉的实例数；`0` = 没找到（可能对宿主不可见）
    @discardableResult
    static func settlePreferences(path: String, note: String) -> Int {
        // 只对 Preferences 下的文件做 —— 其它路径（如 Caches）不归 cfprefsd 管
        guard path.contains("/Library/Preferences/") else { return 0 }
        let killed = killCfprefsd()
        AirliftChangeLog.append(action: "kill-cfprefsd", path: path, bytes: 0,
                                verified: false,
                                note: killed > 0
                                    ? "已杀掉 \(killed) 个 cfprefsd 实例，逼它从磁盘重读（\(note)）"
                                    : "没找到 cfprefsd 进程（\(note)：设置可能不会立刻生效）")
        return killed
    }

    /// 杀掉 cfprefsd（用户态的偏好守护进程）.
    ///
    /// 用宿主现成的进程控制（与 proc.signal 同一条路），不自己发 signal.
    ///
    /// - Returns: 实际杀掉的实例数（0 = 没找到，可能对宿主不可见）
    private static func killCfprefsd() -> Int {
        guard let entries = try? ProcessManagerService.shared.listProcesses() else { return 0 }
        var killed = 0
        for entry in entries
        where entry.displayName.localizedCaseInsensitiveContains("cfprefsd")
            || entry.executablePath.localizedCaseInsensitiveContains("cfprefsd") {
            if (try? ProcessManagerService.shared.sendSignal(.kill, toPID: entry.pid)) != nil {
                killed += 1
            }
        }
        return killed
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
