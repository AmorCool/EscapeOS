import Foundation

/// 铃声管理服务：访问设备铃声目录，支持导入 / 导出 / 删除 / 提取 / 刷新。
///
/// 通道说明（v0.2.126）：v0.2.125 曾走 AFC 隧道，实测
/// `com.apple.afc.shim.remote` 根 = /var/mobile/media，够不到
/// /var/mobile/Library/Ringtones（全部 Afc(ObjectNotFound)）。
/// 本版改回 **bad_query**（SandboxEscape + FileService）访问系统用户目录：
/// - 用户铃声：`/var/mobile/Library/Ringtones`（读 / 写 / 删）
/// - 系统提示音：`/System/Library/Audio/UISounds`（只读；iOS 26 rootless 下
///   系统分区只读，bad_query 若能签发扩展则可读，否则该段提示不可用）
final class RingtonesService {

    static let shared = RingtonesService()
    private init() {}

    private let escape = SandboxEscape()
    private let files = FileService()

    /// 用户铃声目录（可写）。
    static let userRingtonesRoot = "/var/mobile/Library/Ringtones"
    /// 系统提示音目录（只读）。
    static let systemSoundsRoot = "/System/Library/Audio/UISounds"

    /// 本地导出目录（文件 App 可见）。
    static var exportDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Ringtones", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// 条目。
    struct Entry: Identifiable, Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        var id: String { path }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "Ringtones", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - 列表

    /// 用户铃声列表（bad_query 扩展下用 FileManager 列出）。
    func listUserRingtones() throws -> [Entry] {
        let handle = try escape.consume(path: Self.userRingtonesRoot, create: true)
        defer { escape.release(handle) }
        guard files.isDirectory(at: Self.userRingtonesRoot),
              let names = try? FileManager.default.contentsOfDirectory(atPath: Self.userRingtonesRoot) else {
            return []
        }
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> Entry? in
                let path = Self.userRingtonesRoot + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return Entry(name: name, path: path,
                             isDirectory: isDir.boolValue,
                             size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 系统提示音列表（bad_query 尝试签发扩展；失败时抛错由 UI 提示）。
    func listSystemSounds() throws -> [Entry] {
        let handle = try escape.consume(path: Self.systemSoundsRoot)
        defer { escape.release(handle) }
        guard files.isDirectory(at: Self.systemSoundsRoot),
              let names = try? FileManager.default.contentsOfDirectory(atPath: Self.systemSoundsRoot) else {
            throw makeError("无法读取系统提示音目录（/System/Library/Audio/UISounds）")
        }
        var result: [Entry] = []
        for name in names where !name.hasPrefix(".") {
            let path = Self.systemSoundsRoot + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // 展开一层子目录（如 UISounds/Modern/...）
                if let children = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    for child in children where !child.hasPrefix(".") {
                        let childPath = path + "/" + child
                        var childIsDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: childPath, isDirectory: &childIsDir),
                              !childIsDir.boolValue else { continue }
                        let attrs = try? FileManager.default.attributesOfItem(atPath: childPath)
                        result.append(Entry(name: name + "/" + child, path: childPath,
                                            isDirectory: false,
                                            size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0))
                    }
                }
            } else {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                result.append(Entry(name: name, path: path, isDirectory: false,
                                    size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0))
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - 导入 / 导出 / 删除

    /// 导入铃声（本地文件 → 用户 Ringtones 目录）。
    @discardableResult
    func importRingtone(localURL: URL) throws -> String {
        let data = try Data(contentsOf: localURL)
        guard !data.isEmpty else {
            throw makeError("文件为空")
        }
        let name = localURL.lastPathComponent
        let remote = Self.userRingtonesRoot + "/" + name
        let handle = try escape.consume(path: Self.userRingtonesRoot, create: true)
        defer { escape.release(handle) }
        try files.createDirectory(at: Self.userRingtonesRoot)
        try files.writeFile(data: data, to: remote)
        return remote
    }

    /// 下载铃声到本地导出目录，返回本地路径。
    func download(path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let name = (path as NSString).lastPathComponent
        let target = URL(fileURLWithPath: Self.exportDirectory).appendingPathComponent(name)
        try data.write(to: target)
        return target.path
    }

    /// 删除用户铃声。
    func deleteRingtone(path: String) throws {
        let handle = try escape.consume(path: Self.userRingtonesRoot, create: true)
        defer { escape.release(handle) }
        if files.exists(at: path) {
            try files.deleteItem(at: path)
        }
    }
}
