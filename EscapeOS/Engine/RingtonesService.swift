import Foundation

/// 铃声管理服务：经 RSD 隧道（AFC，`com.apple.afc.shim.remote`，根 = /）
/// 访问设备上的铃声目录：
/// - 用户铃声：`/var/mobile/Library/Ringtones`（读 / 写 / 删）
/// - 系统提示音：`/System/Library/Audio/UISounds`（只读，可提取/导出）
///
/// 与 AFC 管理 / IPCC 安装共用同一套隧道（AFCService）。
final class RingtonesService {

    static let shared = RingtonesService()
    private init() {}

    private let afc = AFCService.shared

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

    // MARK: - 列表

    /// 用户铃声列表。
    func listUserRingtones() throws -> [AFCService.Entry] {
        try afc.listDirectory(Self.userRingtonesRoot)
            .filter { !$0.isDirectory }
    }

    /// 系统提示音列表（含子目录展开一层：UISounds 下有分类子目录）。
    func listSystemSounds() throws -> [AFCService.Entry] {
        var result: [AFCService.Entry] = []
        let root = try afc.listDirectory(Self.systemSoundsRoot)
        for entry in root {
            if entry.isDirectory {
                // 展开一层子目录（如 /System/Library/Audio/UISounds/Modern 等）
                if let children = try? afc.listDirectory(entry.path) {
                    result.append(contentsOf: children.filter { !$0.isDirectory })
                }
            } else {
                result.append(entry)
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
            throw NSError(domain: "Ringtones", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "文件为空"])
        }
        let name = localURL.lastPathComponent
        let remote = Self.userRingtonesRoot + "/" + name
        try afc.batch { client in
            _ = Self.userRingtonesRoot.withCString { afc_make_directory(client, $0) }
        }
        try afc.writeFile(data, to: remote)
        return remote
    }

    /// 下载铃声到本地导出目录，返回本地路径。
    func download(path: String) throws -> String {
        let data = try afc.readFile(path)
        let name = (path as NSString).lastPathComponent
        let target = URL(fileURLWithPath: Self.exportDirectory).appendingPathComponent(name)
        try data.write(to: target)
        return target.path
    }

    /// 删除用户铃声。
    func deleteRingtone(path: String) throws {
        try afc.removePath(path)
    }
}
