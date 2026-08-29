import Foundation

/// 铃声管理服务。
///
/// 通道说明（v0.2.127）：
/// - **用户铃声**：走 RSD 隧道（AFCService，`com.apple.afc.shim.remote`，根 =
///   /var/mobile/media），目录用 **`iTunes_Control/Ringtones`**（= 设备
///   /var/mobile/media/iTunes_Control/Ringtones）—— 这正是爱思助手 / iTunes
///   同步铃声用的目录，AFC 隧道直达，**不需要任何系统权限**。
/// - **系统提示音**：`/System/Library/Audio/UISounds` 在 media 之外，
///   AFC 隧道不可达；**仅此处经用户明确允许使用 bad_query** 尝试访问
///   （失败则明确报错）。
final class RingtonesService {

    static let shared = RingtonesService()
    private init() {}

    private let afc = AFCService.shared
    private let escape = SandboxEscape()
    private let files = FileService()

    /// 用户铃声目录（AFC 相对路径，= /var/mobile/media/iTunes_Control/Ringtones）。
    static let userRingtonesAFCPath = "iTunes_Control/Ringtones"
    /// 系统提示音目录（仅本处允许 bad_query）。
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

    // MARK: - 用户铃声（AFC 隧道）

    /// 用户铃声列表（AFC 隧道，iTunes_Control/Ringtones）。
    func listUserRingtones() throws -> [Entry] {
        let list = try afc.listDirectory(Self.userRingtonesAFCPath)
        return list
            .filter { !$0.isDirectory }
            .map { Entry(name: $0.name, path: $0.path, isDirectory: false, size: $0.size) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 导入铃声（本地文件 → AFC 上传到 iTunes_Control/Ringtones）。
    @discardableResult
    func importRingtone(localURL: URL) throws -> String {
        let data = try Data(contentsOf: localURL)
        guard !data.isEmpty else {
            throw makeError("文件为空")
        }
        let name = localURL.lastPathComponent
        let remote = Self.userRingtonesAFCPath + "/" + name
        // 确保目录存在（已存在则 mkdir 报错忽略）
        try afc.batch { client in
            _ = Self.userRingtonesAFCPath.withCString { afc_make_directory(client, $0) }
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

    // MARK: - 系统提示音（bad_query，用户仅允许此处）

    /// 系统提示音列表。bad_query 对系统分区可能被拒，失败会明确抛错。
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

    /// 系统提示音下载（bad_query 路径下直接读文件）。
    func downloadSystemSound(path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let name = (path as NSString).lastPathComponent
        let target = URL(fileURLWithPath: Self.exportDirectory).appendingPathComponent(name)
        try data.write(to: target)
        return target.path
    }
}
