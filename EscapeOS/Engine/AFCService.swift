import Foundation

/// AFC 管理服务：通过「配对文件 + LocalDevVPN 本地隧道」的 RSD 通道连接
/// 本机 AFC 服务（com.apple.afc，**根目录 = /var/mobile/media**），
/// 提供浏览 / 读取 / 下载 / 上传 / 删除 / 新建目录 / 重命名能力。
///
/// 复用 DeviceControlService 同一套隧道机制（tunnel_create_rppairing），
/// 并遵循 RSD 隧道并发铁律：本服务所有操作走同一条串行队列，
/// 避免与进程管理 / 设备控制并发建隧道互相抢占。
final class AFCService {

    static let shared = AFCService()
    private init() {}

    /// RSD 隧道并发铁律：同一 hostname 并发 `tunnel_create_rppairing` 会互相抢占，
    /// 本服务所有操作全部经 `afcQueue` 串行执行。
    private let afcQueue = DispatchQueue(label: "com.ipaside.escapeos.afc")

    /// 浏览条目（对齐 FileRow 展示所需字段）。
    struct Entry: Identifiable, Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
        var id: String { path }
    }

    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "AFCService", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "AFCService", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: - 隧道（与 DeviceControlService 同款）

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
            let ffiError = "EscapeSpaceAFC".withCString { hn in
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

    /// 打开 AFC 连接并执行操作（每次一条连接，用完即释放）。
    /// `afc_client_connect_rsd` 与建隧道一样需要 3 次退避重试（RSD 铁律）。
    private func withClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var lastError: NSError?
        for attempt in 0..<3 {
            var client: OpaquePointer?
            if let ffiError = afc_client_connect_rsd(adapter, handshake, &client) {
                lastError = error(from: ffiError, fallback: "连接 AFC 服务失败")
            } else if let client {
                defer { afc_client_free(client) }
                return try body(client)
            } else {
                lastError = makeError("连接 AFC 服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接 AFC 服务失败")
    }

    /// 释放 C 字符串数组（Rust 侧 CString::into_raw 分配，与 libc free 兼容）。
    private func freeCStrings(_ entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ count: Int) {
        guard let entries else { return }
        for index in 0..<count {
            if let p = entries[index] { free(p) }
        }
        entries.deallocate()
    }

    /// 在串行队列上执行可能抛错的闭包。
    ///
    /// 不直接用 `try afcQueue.sync { ... }`：Theos 的 GCD 桥接里
    /// `DispatchQueue.sync` 只有非 throwing 重载，throwing 闭包会报
    /// "invalid conversion from throwing function"（v0.2.122 实锤）。
    /// 这里用 Result 包装绕开。
    private func syncOnQueue<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        afcQueue.sync {
            do { result = .success(try body()) }
            catch { result = .failure(error) }
        }
        return try result.get()
    }

    // MARK: - 浏览

    /// 静态辅助：在**已建立的 AFC 连接**上列出目录（供 CrashLogService 等
    /// 使用 crashreport 转出的 AFC 客户端时复用，避免复制逻辑）。
    static func listDirectory(client: OpaquePointer, path: String) throws -> [Entry] {
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        let cPath = path.isEmpty ? "/" : path
        if let ffiError = cPath.withCString({ afc_list_directory(client, $0, &entries, &count) }) {
            let message = ffiError.pointee.message.map { String(cString: $0) } ?? "rc=\(ffiError.pointee.code)"
            let code = Int(ffiError.pointee.code)
            idevice_error_free(ffiError)
            throw NSError(domain: "AFCService", code: code,
                          userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "列出目录失败：\(cPath)" : message])
        }
        defer {
            if let entries {
                for index in 0..<count {
                    if let p = entries[index] { free(p) }
                }
                entries.deallocate()
            }
        }

        var result: [Entry] = []
        guard let entries else { return result }
        for index in 0..<count {
            guard let p = entries[index] else { continue }
            let name = String(cString: p)
            if name == "." || name == ".." { continue }
            let full = (cPath == "/" ? "" : cPath) + "/" + name
            let info = try? fileInfo(client: client, path: full)
            let isDir: Bool
            if let fmt = info?.st_ifmt {
                isDir = String(cString: fmt) == "S_IFDIR"
            } else {
                isDir = false
            }
            result.append(Entry(
                name: name,
                path: full,
                isDirectory: isDir,
                size: Int64(info?.size ?? 0),
                modified: info.map { Date(timeIntervalSince1970: TimeInterval($0.modified)) }
            ))
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 静态辅助：获取 AFC 文件信息（供复用同一连接的调用方使用）。
    static func fileInfo(client: OpaquePointer, path: String) throws -> AfcFileInfo {
        var info = AfcFileInfo()
        if let ffiError = path.withCString({ afc_get_file_info(client, $0, &info) }) {
            let message = ffiError.pointee.message.map { String(cString: $0) } ?? "rc=\(ffiError.pointee.code)"
            let code = Int(ffiError.pointee.code)
            idevice_error_free(ffiError)
            throw NSError(domain: "AFCService", code: code,
                          userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "获取文件信息失败：\(path)" : message])
        }
        return info
    }

    /// 在一条 AFC 连接上执行批量操作（供 IPCC 安装 / 铃声管理复用，
    /// 避免逐文件重建隧道）。已在串行队列内，body 里可直接调 C 函数。
    func batch<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try syncOnQueue {
            try withClient { client in
                try body(client)
            }
        }
    }

    /// 列出目录内容。`path` 为空或 "/" 表示 AFC 根。
    /// v0.2.126 结论：`afc_client_connect_rsd`（com.apple.afc.shim.remote）
    /// 根目录 = /var/mobile/media（与标准 AFC1 相同，不是整个文件系统）。
    /// 因此本服务只能访问媒体目录（DCIM / Downloads / iTunes_Control /
    /// PublicStaging 等）；/var/mobile/Library 之外的系统路径不可达。
    func listDirectory(_ path: String) throws -> [Entry] {
        try syncOnQueue {
            try withClient { client in
                try Self.listDirectory(client: client, path: path)
            }
        }
    }

    private func fileInfo(client: OpaquePointer, path: String) throws -> AfcFileInfo {
        var info = AfcFileInfo()
        if let ffiError = path.withCString({ afc_get_file_info(client, $0, &info) }) {
            throw error(from: ffiError, fallback: "获取文件信息失败：\(path)")
        }
        return info
    }

    // MARK: - 文件操作

    /// 下载文件全部内容。
    func readFile(_ path: String) throws -> Data {
        try syncOnQueue {
            try withClient { client in
                var handle: OpaquePointer?
                if let ffiError = path.withCString({ afc_file_open(client, $0, AfcRdOnly, &handle) }) {
                    throw error(from: ffiError, fallback: "打开文件失败：\(path)")
                }
                guard let handle else { throw makeError("打开文件失败：\(path)") }
                defer { afc_file_close(handle) }

                var data: UnsafeMutablePointer<UInt8>?
                var length = 0
                if let ffiError = afc_file_read_entire(handle, &data, &length) {
                    throw error(from: ffiError, fallback: "读取文件失败：\(path)")
                }
                defer {
                    if let data { afc_file_read_data_free(data, length) }
                }
                guard let data else { return Data() }
                return Data(bytes: data, count: length)
            }
        }
    }

    /// 上传文件（父目录必须已存在）。v0.2.127：改为 1MB 分块写入，
    /// 避免超大文件（如 .ipcc）一次性提交超出 AFC 协议包限制。
    func writeFile(_ data: Data, to path: String) throws {
        try syncOnQueue {
            try withClient { client in
                var handle: OpaquePointer?
                if let ffiError = path.withCString({ afc_file_open(client, $0, AfcWrOnly, &handle) }) {
                    throw error(from: ffiError, fallback: "创建文件失败：\(path)")
                }
                guard let handle else { throw makeError("创建文件失败：\(path)") }
                defer { afc_file_close(handle) }

                let chunkSize = 1_048_576
                try data.withUnsafeBytes { buffer in
                    let base = buffer.bindMemory(to: UInt8.self).baseAddress
                    var offset = 0
                    while offset < data.count {
                        let chunk = min(chunkSize, data.count - offset)
                        if let ffiError = afc_file_write(handle, base?.advanced(by: offset), chunk) {
                            throw error(from: ffiError, fallback: "写入文件失败：\(path)")
                        }
                        offset += chunk
                    }
                }
            }
        }
    }

    /// 新建目录。
    func makeDirectory(_ path: String) throws {
        try syncOnQueue {
            try withClient { client in
                if let ffiError = path.withCString({ afc_make_directory(client, $0) }) {
                    throw error(from: ffiError, fallback: "新建目录失败：\(path)")
                }
            }
        }
    }

    /// 删除文件或目录（目录需为空，空目录用 `removePathAndContents`）。
    func removePath(_ path: String, includingContents: Bool = false) throws {
        try syncOnQueue {
            try withClient { client in
                let ffiError: UnsafeMutablePointer<IdeviceFfiError>? = path.withCString { p in
                    if includingContents {
                        afc_remove_path_and_contents(client, p)
                    } else {
                        afc_remove_path(client, p)
                    }
                }
                if let ffiError {
                    throw error(from: ffiError, fallback: "删除失败：\(path)")
                }
            }
        }
    }

    /// 重命名 / 移动。
    func renamePath(_ source: String, to target: String) throws {
        try syncOnQueue {
            try withClient { client in
                let ffiError = source.withCString { s in
                    target.withCString { t in
                        afc_rename_path(client, s, t)
                    }
                }
                if let ffiError {
                    throw error(from: ffiError, fallback: "重命名失败：\(source)")
                }
            }
        }
    }
}
