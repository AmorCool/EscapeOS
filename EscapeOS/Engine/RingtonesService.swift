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

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "Ringtones", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: - 隧道（与 AFCService / DeviceControlService 同款，供通知服务使用）

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func createTunnel() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件。请先在「应用」页导入配对文件（需 LocalDevVPN + 开发者模式）。")
        }

        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian

        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = "EscapeSpaceRingtones".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
                    }
                }
            }
            if let ffiError {
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if attempt < 2 {
                usleep(useconds_t(300_000 * (attempt + 1)))
            }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
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

    // MARK: - 导入（自动转 .m4r + 同步通知，爱思同款）/ 导出 / 删除

    /// 导入铃声：**先转成 .m4r**（AAC/m4a 容器，爱思助手同款 —— 用户观察：
    /// "爱思助手还要转换成铃声格式 .m4r 的"），再经 AFC 上传到
    /// iTunes_Control/Ringtones，最后发 iTunes 同步通知让系统刷新媒体库
    /// （爱思的「同步进铃声库」本质 = 写文件 + 通知刷新）。
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

        // 2. AFC 上传（先通知 syncWillStart / syncDidStart，与 iTunes 一致）
        try? postSyncNotification("com.apple.itunes-mobdev.syncWillStart")
        try? postSyncNotification("com.apple.itunes-mobdev.syncDidStart")
        let name = ringtoneURL.lastPathComponent
        let remote = Self.userRingtonesAFCPath + "/" + name
        try afc.batch { client in
            _ = Self.userRingtonesAFCPath.withCString { afc_make_directory(client, $0) }
        }
        try afc.writeFile(data, to: remote)

        // 3. 通知同步完成 → 系统刷新媒体库，铃声出现在「设置 → 声音 → 铃声」
        //    （爱思/iTunes 同步铃声的关键一步；失败不阻塞导入，页面提示即可）
        try? postSyncNotification("com.apple.itunes-mobdev.syncDidFinish")
        return remote
    }

    /// 通过 RSD 隧道向 notification_proxy 服务发送 iTunes 同步通知，
    /// 让系统感知媒体库变更（铃声同步协议，未越狱设备的公开通道）。
    /// 失败静默（不影响主流程），调用方按需提示。
    func postSyncNotification(_ name: String) throws {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var client: OpaquePointer?
        if let ffiError = notification_proxy_connect_rsd(adapter, handshake, &client) {
            throw error(from: ffiError, fallback: "连接通知服务失败")
        }
        guard let client else { throw makeError("连接通知服务失败") }
        defer { notification_proxy_client_free(client) }
        if let ffiError = name.withCString({ notification_proxy_post(client, $0) }) {
            throw error(from: ffiError, fallback: "发送通知失败：\(name)")
        }
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
