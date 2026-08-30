import Foundation
import AVFoundation

/// 铃声管理服务 —— 走 RSD 隧道（AFCService，`com.apple.afc.shim.remote`，
/// 根 = **/var/mobile/media**）。
///
/// v0.2.128 变更：
/// - **移除系统提示音（/System/Library/Audio/UISounds）读取**：该目录在 AFC
///   根之外，bad_query 又报 `The path lies outside containermanager's sandbox`，
///   用户已要求删除这部分。
/// - 列表改为**扫描 media 内多个常见位置**的音频文件（iTunes_Control/Ringtones、
///   PublicStaging、Downloads、media 根），解决"用户铃声不显示"的问题。
///
/// ⚠️ 硬限制：系统铃声库 `/var/mobile/Library/Ringtones` 在 AFC 根（media）
/// 之外，隧道不可达，无法直接读取 —— 只能管理 media 内的铃声文件。
final class RingtonesService {

    static let shared = RingtonesService()
    private init() {}

    private let afc = AFCService.shared

    /// 主目录（= /var/mobile/media/iTunes_Control/Ringtones，iTunes/爱思同款）。
    static let userRingtonesAFCPath = "iTunes_Control/Ringtones"
    /// 扫描位置（AFC 相对路径；"" 表示 media 根）。
    static let scanRoots = [userRingtonesAFCPath, "PublicStaging", "Downloads", ""]
    /// 视为铃声的扩展名（v0.2.132 恢复过滤 —— 用户确认旧版按扩展名过滤更好）。
    static let audioExtensions: Set<String> = ["m4r", "caf", "m4a", "aiff", "wav", "aac", "mp3"]

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

    // MARK: - 列表（AFC 隧道，扫描 media 内常见位置）

    /// 扫描 media 内各常见位置的铃声文件（v0.2.132：恢复**按扩展名过滤**，
    /// 只显示音频文件 —— 用户确认旧版过滤逻辑更好）。
    /// 目录自动排除；扫描根全部失败时抛错，部分成功则返回成功的部分。
    func listUserRingtones() throws -> [Entry] {
        var found: [Entry] = []
        var seen = Set<String>()
        var failures: [String] = []
        for root in Self.scanRoots {
            do {
                let list = try afc.listDirectory(root.isEmpty ? "/" : root)
                for item in list where !item.isDirectory {
                    let ext = (item.name as NSString).pathExtension.lowercased()
                    guard Self.audioExtensions.contains(ext), !seen.contains(item.path) else { continue }
                    seen.insert(item.path)
                    found.append(Entry(name: item.name, path: item.path,
                                       isDirectory: false, size: item.size))
                }
            } catch {
                failures.append("\(root.isEmpty ? "/" : root)：\(error.localizedDescription)")
            }
        }
        if found.isEmpty && !failures.isEmpty {
            throw makeError(failures.joined(separator: "；"))
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - 导入（自动转 .m4r，爱思同款）/ 导出 / 删除

    /// 导入铃声：**先转成 .m4r**（AAC/m4a 容器，爱思助手同款 —— 用户观察：
    /// "爱思助手还要转换成铃声格式 .m4r 的"），再经 AFC 上传到
    /// iTunes_Control/Ringtones。
    @discardableResult
    func importRingtone(localURL: URL) throws -> String {
        // 1. 格式转换（mp3/wav/m4a 等任意音频 → .m4r）
        let ringtoneURL: URL
        if localURL.pathExtension.lowercased() == "m4r" {
            ringtoneURL = localURL
        } else {
            ringtoneURL = try convertToM4R(localURL: localURL)
        }
        defer {
            if ringtoneURL != localURL { try? FileManager.default.removeItem(at: ringtoneURL) }
        }
        let data = try Data(contentsOf: ringtoneURL)
        guard !data.isEmpty else {
            throw makeError("转换后文件为空")
        }

        // 2. AFC 上传
        let name = ringtoneURL.lastPathComponent
        let remote = Self.userRingtonesAFCPath + "/" + name
        try afc.batch { client in
            _ = Self.userRingtonesAFCPath.withCString { afc_make_directory(client, $0) }
        }
        try afc.writeFile(data, to: remote)
        return remote
    }

    /// 用 AVAssetExportSession 把任意音频转成 .m4r（AAC，m4a 容器改扩展名）。
    /// 输出到临时目录，调用方负责清理。
    private func convertToM4R(localURL: URL) throws -> URL {
        let asset = AVURLAsset(url: localURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw makeError("无法创建音频转换会话（不支持的格式？）")
        }
        let baseName = localURL.deletingPathExtension().lastPathComponent
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(baseName + ".m4r")
        try? FileManager.default.removeItem(at: outURL)
        session.outputURL = outURL
        session.outputFileType = .m4a   // .m4r 与 .m4a 同为 AAC/m4a 容器
        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { sem.signal() }
        _ = sem.wait(timeout: .now() + 60)
        guard session.status == .completed else {
            throw makeError("转换失败：\(session.error?.localizedDescription ?? "未知错误")")
        }
        return outURL
    }

    /// 读取铃声文件原始数据（在线播放用）。
    func readData(path: String) throws -> Data {
        try afc.readFile(path)
    }

    /// 下载铃声到本地导出目录，返回本地路径。
    func download(path: String) throws -> String {
        let data = try afc.readFile(path)
        let name = (path as NSString).lastPathComponent
        let target = URL(fileURLWithPath: Self.exportDirectory).appendingPathComponent(name)
        try data.write(to: target)
        return target.path
    }

    /// 重命名铃声（AFC rename_path）。
    func renameRingtone(path: String, to newName: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let target = (parent == "/" ? "" : parent) + "/" + newName
        try afc.renamePath(path, to: target)
    }

    /// 删除铃声。
    func deleteRingtone(path: String) throws {
        try afc.removePath(path)
    }
}
