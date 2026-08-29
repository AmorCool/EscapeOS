import Foundation

/// 崩溃分析服务：通过「配对文件 + LocalDevVPN」隧道连接
/// com.apple.crashreportcopymobile，再用 `crash_report_client_to_afc`
/// 把它转成 **AFC 客户端**浏览日志目录（v0.2.127）。
///
/// 为什么转 AFC：crashreportcopymobile 的 ls 对子目录参数会返回
/// Afc(ObjectNotFound)（服务端行为），而转成的 AFC 视图是**标准文件系统
/// 视图**（根下是 CrashReporter / DiagnosticLogs / Logs 等真实子目录），
/// 目录 / 文件类型一目了然，进入子目录、读内容、删除全部走 AFC 协议。
///
/// 同样遵循 RSD 隧道并发铁律（本服务内所有操作串行）。
final class CrashLogService {

    static let shared = CrashLogService()
    private init() {}

    private let queue = DispatchQueue(label: "com.ipaside.escapeos.crashlog")

    /// 崩溃日志条目（AFC 视图路径）。
    struct Entry: Identifiable, Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
        var id: String { path }
    }

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

    /// 连接 crashreportcopymobile → `crash_report_client_to_afc` 转 AFC 客户端。
    /// 注意：to_afc 会**消费并释放** crashreport 客户端，之后直接使用 AFC 句柄。
    private func withAfcClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var lastError: NSError?
        for attempt in 0..<3 {
            var crashClient: OpaquePointer?
            if let ffiError = crash_report_client_connect_rsd(adapter, handshake, &crashClient) {
                lastError = error(from: ffiError, fallback: "连接崩溃日志服务失败")
            } else if let crashClient {
                var afc: OpaquePointer?
                if let ffiError = crash_report_client_to_afc(crashClient, &afc) {
                    lastError = error(from: ffiError, fallback: "转换崩溃日志 AFC 客户端失败")
                } else if let afc {
                    defer { afc_client_free(afc) }
                    return try body(afc)
                } else {
                    lastError = makeError("转换崩溃日志 AFC 客户端失败")
                }
            } else {
                lastError = makeError("连接崩溃日志服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接崩溃日志服务失败")
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

    // MARK: - 列表 / 拉取 / 删除（AFC 视图）

    /// 列出日志目录。`subdirectory` 为 nil 时列根目录
    /// （含 CrashReporter / DiagnosticLogs / Logs 等子目录，v0.2.127 起可进入）。
    func list(subdirectory: String? = nil) throws -> [Entry] {
        try syncOnQueue {
            try withAfcClient { afc in
                let list = try AFCService.listDirectory(client: afc, path: subdirectory ?? "/")
                return list.map { Entry(name: $0.name, path: $0.path, isDirectory: $0.isDirectory) }
            }
        }
    }

    /// v0.2.128：改为 1MB 分块 `afc_file_read`。
    /// `afc_file_read_entire` 在导出时返回 Afc(UnknownError)，分块读更稳，
    /// 且失败时能带上"已读多少字节"便于定位。
    private func pullInternal(client: OpaquePointer, path: String) throws -> Data {
        var handle: OpaquePointer?
        if let ffiError = path.withCString({ afc_file_open(client, $0, AfcRdOnly, &handle) }) {
            throw error(from: ffiError, fallback: "打开日志失败：\(path)")
        }
        guard let handle else { throw makeError("打开日志失败：\(path)") }
        defer { afc_file_close(handle) }

        var result = Data()
        let chunkSize = 1 << 20
        while true {
            var buffer: UnsafeMutablePointer<UInt8>?
            var got = 0
            if let ffiError = afc_file_read(handle, &buffer, chunkSize, &got) {
                throw error(from: ffiError,
                            fallback: "读取日志失败（已读 \(result.count) 字节）：\(path)")
            }
            defer {
                if let buffer { afc_file_read_data_free(buffer, got) }
            }
            guard let buffer, got > 0 else { break }
            result.append(Data(bytes: buffer, count: got))
            if got < chunkSize { break }
        }
        return result
    }

    /// 拉取日志文件内容（.ips 是 JSON 文本）。
    func pull(_ path: String) throws -> Data {
        try syncOnQueue {
            try withAfcClient { afc in
                try pullInternal(client: afc, path: path)
            }
        }
    }

    private func removeInternal(client: OpaquePointer, path: String) throws {
        if let ffiError = path.withCString({ afc_remove_path(client, $0) }) {
            throw error(from: ffiError, fallback: "删除日志失败：\(path)")
        }
    }

    /// 删除日志（目录会连内容一起删）。
    func remove(_ path: String) throws {
        try syncOnQueue {
            try withAfcClient { afc in
                try removeInternal(client: afc, path: path)
            }
        }
    }

    // MARK: - 导出

    /// 导出目录（EscapeSpace 自己 Documents 下的 CrashLogs 文件夹，文件 App 可见）。
    static var exportDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// 批量导出：**同一条 AFC 连接**循环拉取（v0.2.125 修复过死锁，v0.2.127 改为
    /// AFC 视图后保留同款结构）。progress 在后台队列调用，UI 负责切主线程。
    func export(entries: [Entry], progress: ((Int, Int) -> Void)? = nil) throws -> [String] {
        try syncOnQueue {
            try withAfcClient { afc in
                var exported: [String] = []
                for (index, entry) in entries.enumerated() {
                    let data = try pullInternal(client: afc, path: entry.path)
                    let safeName = entry.path.replacingOccurrences(of: "/", with: "_")
                    let target = URL(fileURLWithPath: Self.exportDirectory)
                        .appendingPathComponent(safeName)
                    try data.write(to: target)
                    exported.append(target.path)
                    progress?(index + 1, entries.count)
                }
                return exported
            }
        }
    }

    /// 批量删除：同一条 AFC 连接循环删除，返回失败数。
    func removeBatch(_ entries: [Entry], progress: ((Int, Int) -> Void)? = nil) throws -> Int {
        try syncOnQueue {
            try withAfcClient { afc in
                var failed = 0
                for (index, entry) in entries.enumerated() {
                    do {
                        try removeInternal(client: afc, path: entry.path)
                    } catch {
                        failed += 1
                    }
                    progress?(index + 1, entries.count)
                }
                return failed
            }
        }
    }
}
