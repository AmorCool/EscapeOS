import Foundation

/// 崩溃分析服务：通过「配对文件 + LocalDevVPN 本地隧道」的 RSD 通道连接
/// 本机崩溃报告复制服务（com.apple.crashreportcopymobile），
/// 读取 iOS「设置 → 隐私与安全性 → 分析与改进」里展示的崩溃 / 诊断日志
/// （.ips 等），支持列表 / 拉取内容 / 删除。
///
/// 走官方服务通道（crash_report_client_*），不需要文件系统权限；
/// 同样遵循 RSD 隧道并发铁律（本服务内所有操作串行）。
final class CrashLogService {

    static let shared = CrashLogService()
    private init() {}

    private let queue = DispatchQueue(label: "com.ipaside.escapeos.crashlog")

    /// 崩溃日志条目。
    struct Entry: Identifiable, Equatable {
        /// 服务端文件名（拉取 / 删除都用它）。
        let name: String
        /// 相对路径（用于显示层级）。
        let path: String
        var id: String { path }
    }

    /// 服务端目录列表（对应 CrashReporter 目录下的分类，由服务端决定）。
    static let knownSubdirectories = ["CrashReporter", "DiagnosticLogs", "Logs"]

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "CrashLog", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "CrashLog", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
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
            let ffiError = "EscapeSpaceCrash".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn, pairingFile, nil, nil,
                            &tunnel.adapter, &tunnel.handshake
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
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }

    private func withClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var lastError: NSError?
        for attempt in 0..<3 {
            var client: OpaquePointer?
            if let ffiError = crash_report_client_connect_rsd(adapter, handshake, &client) {
                lastError = error(from: ffiError, fallback: "连接崩溃日志服务失败")
            } else if let client {
                defer { crash_report_client_free(client) }
                return try body(client)
            } else {
                lastError = makeError("连接崩溃日志服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接崩溃日志服务失败")
    }

    private func freeCStrings(_ entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ count: Int) {
        guard let entries else { return }
        for index in 0..<count {
            if let p = entries[index] { free(p) }
        }
        entries.deallocate()
    }

    /// 在串行队列上执行可能抛错的闭包（Theos 的 DispatchQueue.sync 无 throwing
    /// 重载，用 Result 包装绕开 —— v0.2.122 实锤）。
    private func syncOnQueue<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        queue.sync {
            do { result = .success(try body()) }
            catch { result = .failure(error) }
        }
        return try result.get()
    }

    // MARK: - 列表 / 拉取 / 删除

    /// 列出日志。`subdirectory` 为 nil 时列服务端根目录（可能有分类子目录）。
    /// 注：crashreportmover 的 flush 需要 IdeviceProviderHandle（本服务只有
    /// AdapterHandle，无法获取），且 crashreportcopymobile 的列表本身已覆盖
    /// 已落盘的日志，因此不再额外触发 flush。
    func list(subdirectory: String? = nil) throws -> [Entry] {
        try syncOnQueue {
            try withClient { client in
                var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var count = 0
                let ffiError = subdirectory?.withCString { dir in
                    crash_report_client_ls(client, dir, &entries, &count)
                } ?? crash_report_client_ls(client, nil, &entries, &count)
                if let ffiError {
                    throw error(from: ffiError, fallback: "列出日志失败")
                }
                defer { freeCStrings(entries, count) }
                guard let entries else { return [] }

                var result: [Entry] = []
                for index in 0..<count {
                    guard let p = entries[index] else { continue }
                    let name = String(cString: p)
                    if name == "." || name == ".." { continue }
                    if let subdirectory, !subdirectory.isEmpty {
                        result.append(Entry(name: name, path: subdirectory + "/" + name))
                    } else {
                        result.append(Entry(name: name, path: name))
                    }
                }
                return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
    }

    /// 拉取日志文件内容（.ips 是 JSON 文本）。
    func pull(_ path: String) throws -> Data {
        try syncOnQueue {
            try withClient { client in
                var data: UnsafeMutablePointer<UInt8>?
                var length = 0
                let ffiError = path.withCString { name in
                    crash_report_client_pull(client, name, &data, &length)
                }
                if let ffiError {
                    throw error(from: ffiError, fallback: "拉取日志失败：\(path)")
                }
                defer {
                    // idevice_data_free 的 len 是 uintptr_t → Swift 导入为 UInt，
                    // 而 crash_report_client_pull 的 size_t* 导入为 Int*，需转换。
                    if let data { idevice_data_free(data, UInt(length)) }
                }
                guard let data else { return Data() }
                return Data(bytes: data, count: length)
            }
        }
    }

    /// 删除日志。
    func remove(_ path: String) throws {
        try syncOnQueue {
            try withClient { client in
                let ffiError = path.withCString { name in
                    crash_report_client_remove(client, name)
                }
                if let ffiError {
                    throw error(from: ffiError, fallback: "删除日志失败：\(path)")
                }
            }
        }
    }

    // MARK: - 导出

    /// 导出目录（EscapeSpace 自己 Documents 下的 CrashLogs 文件夹，
    /// 文件 App 可见，可再分享出去）。
    static var exportDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// 批量导出：把选中的日志拉到本机 `CrashLogs/` 目录，返回导出文件路径列表。
    func export(entries: [Entry]) throws -> [String] {
        try syncOnQueue {
            var exported: [String] = []
            for entry in entries {
                let data = try pull(entry.path)
                let safeName = entry.path.replacingOccurrences(of: "/", with: "_")
                let target = URL(fileURLWithPath: Self.exportDirectory)
                    .appendingPathComponent(safeName)
                try data.write(to: target)
                exported.append(target.path)
            }
            return exported
        }
    }
}
