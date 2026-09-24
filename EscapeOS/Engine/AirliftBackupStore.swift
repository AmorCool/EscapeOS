//
//  AirliftBackupStore.swift
//  EscapeSpace
//
//  沙盒外文件的**带序号备份** —— 1 号永远是「初始备份」，永不覆盖.
//
//  ## 为什么不能用「一个 .bak 覆盖式备份」（用户指出）
//  原来的做法是每次覆盖前把目标存到 `AIR/<名>.bak` —— **同一个名字，每次覆盖**.
//  ⇒ 写第 3 次之后，**最初的原文件就没了**，想还原也回不去. 那是数据安全问题.
//
//  ## 现在的语义（用户要求）
//  ```
//  AirliftBackups/<路径哈希>/
//      1.bak      ← **第一次写入前的原文件**（初始备份，永不覆盖）
//      2.bak      ← 第 2 次写入前的快照
//      3.bak      ← 第 3 次写入前的快照
//  ```
//  ⇒ 「还原」默认回 **1 号**（回到我们介入之前的状态），也可以选任意序号.
//
//  ## 为什么不直接拿路径当目录名
//  路径里有 `/`、空格、中文 ⇒ 当目录名会踩转义/长度坑. 用 `sha1(路径)` 的十六进制
//  当目录名，再用 `index.json` 把哈希映射回真实路径（人可读）.
//
//  ## 为什么不自动挑「哪一份是好的」（用户否决）
//  曾想按「最大/最全」自动挑一份来还原 —— **错的**：文件变小不等于坏
//  （正常删键也会变小），拿大小当判据会**误判**，可能把用户主动删过的状态
//  当成「坏的」而拒绝还原. ⇒ 本仓库**只存、只列、只回放**，把
//  **键数 / 字节 / 时间**摊开给用户自己看，选择权完全交给用户.
//

import CryptoKit
import Foundation

/// 沙盒外文件的带序号备份仓库（纯静态）.
enum AirliftBackupStore {

    /// 一份备份.
    struct Version: Codable {
        /// 从 1 开始. **1 = 初始备份**
        let index: Int
        let time: String
        let bytes: Int
        let note: String
    }

    /// 某个路径的备份索引.
    struct Record: Codable {
        let path: String
        var versions: [Version]
    }

    private static let lock = NSLock()

    private static var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirliftBackups", isDirectory: true)
    }
    private static var indexURL: URL { rootURL.appendingPathComponent("index.json") }

    /// 路径 → 目录名（sha1 前 16 位十六进制）.
    private static func dirName(for path: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private static func dir(for path: String) -> URL {
        rootURL.appendingPathComponent(dirName(for: path), isDirectory: true)
    }

    private static func fileURL(for path: String, index: Int) -> URL {
        dir(for: path).appendingPathComponent("\(index).bak")
    }

    // MARK: - 写

    /// 存一份「写入前」的快照.
    ///
    /// - Returns: 这份快照的序号；**1 表示这是初始备份**（此前没有备份过）
    @discardableResult
    static func snapshot(path: String, data: Data, note: String = "") -> Int {
        lock.lock()
        defer { lock.unlock() }

        var all = readIndexUnlocked()
        var record = all[path] ?? Record(path: path, versions: [])
        // 序号 = 已有份数 + 1 ⇒ 1 号只在第一次产生，之后永远不动
        let index = (record.versions.map(\.index).max() ?? 0) + 1

        do {
            try FileManager.default.createDirectory(at: dir(for: path),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL(for: path, index: index), options: .atomic)
        } catch {
            return 0        // 存不下来就返回 0，调用方据此决定是否中止
        }

        record.versions.append(Version(index: index,
                                       time: ISO8601DateFormatter().string(from: Date()),
                                       bytes: data.count,
                                       note: note))
        all[path] = record
        writeIndexUnlocked(all)
        return index
    }

    // MARK: - 读

    /// 某个路径的全部备份（按序号升序）.
    static func versions(path: String) -> [Version] {
        lock.lock()
        defer { lock.unlock() }
        return (readIndexUnlocked()[path]?.versions ?? []).sorted { $0.index < $1.index }
    }

    /// 取某一份备份的内容.
    static func data(path: String, index: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: fileURL(for: path, index: index))
    }

    /// 一份数据的「顶层键数」—— 能解析成**字典 plist** 时才有值，否则 `nil`.
    ///
    /// ## 为什么在**读取时**算，而不是存的时候记进 index.json
    /// 一是老备份（已经躺在设备上的那些）当时没记，事后补不上；
    /// 二是算一次就是一次本地文件解析，**毫秒级**，比让它跟 index 不同步划算.
    static func plistKeyCount(_ data: Data) -> Int? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let object = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: &format),
              let dict = object as? [String: Any] else { return nil }
        return dict.count
    }

    /// 某一份备份的顶层键数（非字典 plist ⇒ `nil`）.
    static func keyCount(path: String, index: Int) -> Int? {
        guard let data = data(path: path, index: index) else { return nil }
        return plistKeyCount(data)
    }

    /// 全部有备份的路径（界面用）.
    static func allPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return readIndexUnlocked().keys.sorted()
    }

    /// 备份目录（界面显示用）.
    static var rootPath: String { rootURL.path }

    // MARK: - 内部

    private static func readIndexUnlocked() -> [String: Record] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return list
    }

    private static func writeIndexUnlocked(_ all: [String: Record]) {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
