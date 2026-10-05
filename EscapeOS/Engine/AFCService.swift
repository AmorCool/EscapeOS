import Foundation

/// AFC 管理服务：通过「配对文件 + LocalDevVPN 本地隧道」的 RSD 通道连接
/// 本机 AFC 服务（com.apple.afc，**根目录 = /var/mobile/media**），
/// 提供浏览 / 读取 / 下载 / 上传 / 删除 / 新建目录 / 重命名能力.
///
/// 复用 DeviceControlService 同一套隧道机制（tunnel_create_rppairing），
/// 并遵循 RSD 隧道并发铁律：本服务所有操作走同一条串行队列，
/// 避免与进程管理 / 设备控制并发建隧道互相抢占.
final class AFCService {

    /// Swift 6 并发检查：本类型非 Sendable，但**没有任何可变实例状态** ——
    /// 只有一条串行队列 `afcQueue` 与计算属性 `pairingPath`，隧道句柄都是方法内局部量，
    /// 且所有 FFI 操作都在这条串行队列上执行（见 `afcQueue` 注释）。
    /// 因此实例本身线程安全，`shared` 跨线程共享无风险。
    nonisolated(unsafe) static let shared = AFCService()
    private init() {}

    /// RSD 隧道并发铁律：同一 hostname 并发 `tunnel_create_rppairing` 会互相抢占，
    /// 本服务所有操作全部经 `afcQueue` 串行执行.
    private let afcQueue = DispatchQueue(label: "com.ipaside.escapeos.afc")

    /// 浏览条目（对齐 FileRow 展示所需字段）.
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
            throw makeError("未检测到配对文件.请到「更多 → 配对文件导入」导入配对文件（需 LocalDevVPN + 开发者模式）.")
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

    /// 打开 AFC 连接并执行操作（每次一条连接，用完即释放）.
    /// `afc_client_connect_rsd` 与建隧道一样需要 3 次退避重试（RSD 铁律）.
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

    /// 释放 C 字符串数组（Rust 侧 CString::into_raw 分配，与 libc free 兼容）.
    private func freeCStrings(_ entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ count: Int) {
        guard let entries else { return }
        for index in 0..<count {
            if let p = entries[index] { free(p) }
        }
        entries.deallocate()
    }

    /// 在串行队列上执行可能抛错的闭包.
    ///
    /// 不直接用 `try afcQueue.sync { ... }`：Theos 的 GCD 桥接里
    /// `DispatchQueue.sync` 只有非 throwing 重载，throwing 闭包会报
    /// "invalid conversion from throwing function"（v0.2.122 实锤）.
    /// 这里用 Result 包装绕开.
    private func syncOnQueue<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        afcQueue.sync {
            do { result = .success(try body()) }
            catch { result = .failure(error) }
        }
        return try result.get()
    }

    /// 把**任意可能建 RSD 隧道**的操作放到 AFC 的这条串行队列上执行.
    ///
    /// 存在的唯一理由：让别的模块（目前只有只读诊断 `DDIMountProbe`）复用同一条队列，
    /// 而不是自建第二条 —— 同一 hostname 并发 `tunnel_create_rppairing` 会互相抢占
    /// （RSD 隧道并发铁律，见本文件 8-9 行）. 队列是私有的，所以只暴露这个受控入口.
    func runExclusively<T>(_ body: () throws -> T) throws -> T {
        try syncOnQueue(body)
    }

    // MARK: - 浏览

    /// 静态辅助：在**已建立的 AFC 连接**上列出目录（供 CrashLogService 等
    /// 使用 crashreport 转出的 AFC 客户端时复用，避免复制逻辑）.
    static func listDirectory(client: OpaquePointer, path: String) throws -> [Entry] {
        try listDirectoryBounded(client: client, path: path, maxEntries: Int.max).entries
    }

    /// 只列名字：一次 `afc_list_directory`，**不**做逐条 `afc_get_file_info`。
    ///
    /// 这是列目录里**廉价**的那一步 —— 成本与条目数**基本无关**
    /// （真机实测固定项 ~0.15s；与之相对，逐条 `afc_get_file_info` 约 7.5ms/条）。
    /// 单独暴露它是为了让 `AfcFileProvider` 能在「超限」时**不付**逐条 stat 的代价。
    static func listNames(client: OpaquePointer, path: String) throws -> [String] {
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

        guard let entries else { return [] }
        var names: [String] = []
        names.reserveCapacity(count)
        for index in 0..<count {
            guard let p = entries[index] else { continue }
            let name = String(cString: p)
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// **有界**列举：最多为前 `maxEntries` 条取元数据，并回传**全部**条目数 `total`。
    /// `total > entries.count` 即表示被截断。
    ///
    /// 为什么要单独一个入口（R1，2026-10-05）：SFTP 的 `openDirectory` 一次性取全目录，
    /// 而 AFC 的成本是**逐条** `afc_get_file_info`（~7.5ms/条）⇒ 约 1.2 万条即触及
    /// `operationTimeout = 90s`。有了这个入口，`openDirectory` 可以先廉价取名字、
    /// 超限就不再逐条 stat，把单次 opendir 的成本封在超时之内。
    ///
    /// - Note: `maxEntries == Int.max` 时与旧的 `listDirectory` 行为**完全一致**
    ///   （同样的名字、同样的逐条 stat、同样的排序）。
    static func listDirectoryBounded(client: OpaquePointer, path: String, maxEntries: Int) throws -> (entries: [Entry], total: Int) {
        let cPath = path.isEmpty ? "/" : path
        // **截断前先按名字排序** ⇒ 被保留的子集是**确定的**（不随 AFC 的列举顺序变化，
        // 用户每次列同一目录看到同一批）。对未截断路径（maxEntries == Int.max）无影响：
        // 最终结果还要按 (类型, 名字) 做全序排序，输入顺序不影响输出。
        //
        // 比较器用 `DirectoryOrdering.nameAscending`：**locale 无关**（不随系统语言变子集）且
        // **无并列**（不依赖 Swift `sort` 的稳定性）—— 见该类型的说明。
        let names = try listNames(client: client, path: cPath)
            .sorted { DirectoryOrdering.nameAscending($0, $1) }
        let total = names.count
        let use = total > maxEntries ? Array(names.prefix(maxEntries)) : names

        var result: [Entry] = []
        result.reserveCapacity(use.count)
        for name in use {
            let full = (cPath == "/" ? "" : cPath) + "/" + name
            // 类型 / 大小**只能**来自 `afc_get_file_info`：`afc_list_directory` 只回名字，
            // 不携带类型，所以「来自 listDirectory」并**不能**推断出它是目录。
            //
            // 旧代码 `try? fileInfo` 在读失败时把 info 落成 nil ⇒ isDir=false、size=0 ⇒
            // 该条目被呈现成「0 字节普通文件」，**目录被伪装成文件** —— 正是
            // 「读不出被当成确定答案」的形状（独立验证 R1 报告顺带实测到）。
            //
            // 改为**如实抛出**：类型不可知时绝不猜（R1 已让 openDirectory 把列举失败显示为
            // 可见标记，不再静默假空）。Rust FFI 在成功路径上保证 `st_ifmt` 非空
            // （见 rust/idevice-ffi/src/afc.rs 的 `CString::new(file_info.st_ifmt)`），
            // 故 info 非 nil ⇒ 类型一定可知，不存在「成功但类型未知」的降级路径。
            //
            // ## 爆炸半径（team-lead 2026-10-05 裁决：保持抛错；此处如实写清，避免两种误判）
            // 本 `try` 经 `listDirectory(maxEntries: Int.max)` 外溢到**非 SFTP** 调用方。
            // **真正**会从「条目降级」变为「整表抛错」的只有下列 **4 个**（均为用户发起 /
            // App 自有的目录，条目抖动概率低，且失败可见、刷新可恢复）：
            //   - CrashLogService.swift:172          （崩溃日志）
            //   - RingtonesService.swift:161         （铃声）
            //   - HostCapabilityService.swift:1818   （能力调用）
            //   - AFCBrowserView.swift:290           （应用内浏览器）
            // **不受影响**：`DeviceSlimService.swift:222/832` 本就是
            //   `try? AFCService.listDirectory(...)` + `guard let … else { continue }`
            //   ⇒ 新行为对它等价于「跳过该节点」，与旧行为一致（勿把它算进爆炸半径）。
            // **不在影响面**：`AppFileBrowserView` / `WallpaperHandler` 用的是各自的
            //   `FileSharingService.listDirectory` / `WallpaperHandler.listDirectory`，
            //   **不是** AFCService 这条路径。
            //
            // ## `AfcFileProvider.removeDirectory` 无数据风险（勿据此去改别处）
            // `SSHFileProvider.swift:608` 是 `guard try list(path).isEmpty else { throw }`，
            // 底层删除用 `AFCService.removePath(..., includingContents: false)`（**非递归**）。
            // 旧行为（条目降级 ⇒ 目录看起来非空）与新行为（list 抛错）**都拒绝删除**；
            // 且底层非递归 ⇒ **不存在**「跳过条目 ⇒ 看似空 ⇒ 误删非空目录」这条路径。
            let info = try fileInfo(client: client, path: full)
            let isDir = info.st_ifmt.map { String(cString: $0) == "S_IFDIR" } ?? false
            result.append(Entry(
                name: name,
                path: full,
                isDirectory: isDir,
                size: Int64(info.size),
                modified: Date(timeIntervalSince1970: TimeInterval(info.modified))
            ))
        }
        let sorted = result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            // 与截断排序同一比较器：同样必须 locale 无关 + 无并列，
            // 否则同一目录在不同系统语言下展示顺序不同（并在并列时顺序不定）。
            return DirectoryOrdering.nameAscending($0.name, $1.name)
        }
        return (sorted, total)
    }

    /// 静态辅助：获取 AFC 文件信息（供复用同一连接的调用方使用）.
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
    /// 避免逐文件重建隧道）.已在串行队列内，body 里可直接调 C 函数.
    func batch<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try syncOnQueue {
            try withClient { client in
                try body(client)
            }
        }
    }

    /// 列出目录内容.`path` 为空或 "/" 表示 AFC 根.
    /// v0.2.126 结论：`afc_client_connect_rsd`（com.apple.afc.shim.remote）
    /// 根目录 = /var/mobile/media（与标准 AFC1 相同，不是整个文件系统）.
    /// 因此本服务只能访问媒体目录（DCIM / Downloads / iTunes_Control /
    /// PublicStaging 等）；/var/mobile/Library 之外的系统路径不可达.
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

    /// 下载文件全部内容（根 = Media）。实现委托给 `readFile(client:path:)`。
    func readFile(_ path: String) throws -> Data {
        try syncOnQueue { try withClient { try Self.readFile(client: $0, path: path) } }
    }

    /// 上传文件（父目录必须已存在；根 = Media）。
    /// 实现委托给 `writeFile(client:data:to:)`（1MB 分块写入的逻辑在那里）。
    func writeFile(_ data: Data, to path: String) throws {
        try syncOnQueue { try withClient { try Self.writeFile(client: $0, data: data, to: path) } }
    }

    /// 新建目录（根 = Media）。实现委托给 `makeDirectory(client:path:)`。
    func makeDirectory(_ path: String) throws {
        try syncOnQueue { try withClient { try Self.makeDirectory(client: $0, path: path) } }
    }

    /// 删除文件或目录（根 = Media）。实现委托给 `removePath(client:path:includingContents:)`。
    func removePath(_ path: String, includingContents: Bool = false) throws {
        try syncOnQueue {
            try withClient {
                try Self.removePath(client: $0, path: path, includingContents: includingContents)
            }
        }
    }

    /// 重命名 / 移动.
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

    // MARK: ▸ v0.3.490：可复用「调用方给的连接」的静态操作
    //
    // ## 为什么需要
    // `afc.*` 能力要支持**多个根**（`Media` 与 `CrashReporter` 各是一条 AFC 会话，
    // 服务名不同 ⇒ 根不同）。把「拿着 client 干活」抽成静态方法后，
    // 两个根共用同一套读写删建实现，不必各写一遍。

    /// 把 FFI 错误转成 NSError，并**释放** FFI 分配的错误对象
    private static func ffiError(_ e: UnsafeMutablePointer<IdeviceFfiError>?,
                                _ fallback: String) -> NSError {
        let message = e?.pointee.message.map { String(cString: $0) } ?? fallback
        let code = Int(e?.pointee.code ?? 0)
        if let e { idevice_error_free(e) }
        return NSError(domain: "AFCService", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    /// 读一个文件的全部内容（复用调用方的连接）
    /// `afc_get_file_info` 的可读结果（`afc.stat` 能力用）.
    struct StatResult {
        let exists: Bool
        let size: Int64
        let isDirectory: Bool
        let ifmt: String?
        let linkTarget: String?
        let describe: String
    }

    /// 查一条路径的元数据（`afc_get_file_info`）.
    ///
    /// ## 为什么它不受 AFC 沙盒限制（真机实测 2026-09-20）
    /// `afc_get_file_info` 会**跟随中间那一段 symlink**，而且不像
    /// read / write / list 那样被 AFC 的根沙盒挡住 —— 同一条路径上
    /// `read` / `write` / `list` 全是 `Afc(PermDenied)`，只有 stat 能过。
    /// 于是「在 Media 里放一条指向目标父目录的 symlink」就能对**任意路径**问
    /// 「在不在 / 多大 / 是文件还是目录」。
    ///
    /// ## 局限（诚实写出来）
    /// 只能**点查**（给定名字），**不能列目录**。
    ///
    /// - Note: `client` 由调用方连接/释放；`path` 是 AFC 口径（相对根，可含 `..`）。
    static func statFile(client: OpaquePointer, path: String) -> StatResult {
        var info = AfcFileInfo()
        if let e = path.withCString({ afc_get_file_info(client, $0, &info) }) {
            let code = e.pointee.code
            let message = e.pointee.message.map { String(cString: $0) } ?? ""
            idevice_error_free(e)
            return StatResult(exists: false, size: 0, isDirectory: false,
                              ifmt: nil, linkTarget: nil,
                              describe: "失败 code=\(code) \(message)")
        }
        let ifmt = info.st_ifmt.map { String(cString: $0) }
        let linkTarget = info.st_link_target.map { String(cString: $0) }
        let size = Int64(info.size)
        afc_file_info_free(&info)
        var text = "成功 size=\(size) st_ifmt=\(ifmt ?? "?")"
        // `st_link_target` 只有 symlink 才有 —— 它是「link 真的指向哪」的直接证据。
        if let linkTarget { text += " st_link_target=\(linkTarget)" }
        return StatResult(exists: true, size: size,
                          isDirectory: ifmt == "S_IFDIR", ifmt: ifmt,
                          linkTarget: linkTarget, describe: text)
    }

    static func readFile(client: OpaquePointer, path: String) throws -> Data {
        var handle: OpaquePointer?
        if let e = path.withCString({ afc_file_open(client, $0, AfcRdOnly, &handle) }) {
            throw ffiError(e, "打开文件失败：\(path)")
        }
        guard let handle else {
            throw NSError(domain: "AFCService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "打开文件失败：\(path)"])
        }
        defer { afc_file_close(handle) }
        var data: UnsafeMutablePointer<UInt8>?
        var length = 0
        if let e = afc_file_read_entire(handle, &data, &length) {
            throw ffiError(e, "读取文件失败：\(path)")
        }
        defer { if let data { afc_file_read_data_free(data, length) } }
        guard let data else { return Data() }
        return Data(bytes: data, count: length)
    }

    /// 写一个文件的全部内容（复用调用方的连接；父目录须已存在）
    static func writeFile(client: OpaquePointer, data: Data, to path: String) throws {
        var handle: OpaquePointer?
        if let e = path.withCString({ afc_file_open(client, $0, AfcWrOnly, &handle) }) {
            throw ffiError(e, "创建文件失败：\(path)")
        }
        guard let handle else {
            throw NSError(domain: "AFCService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "创建文件失败：\(path)"])
        }
        defer { afc_file_close(handle) }
        let chunkSize = 1_048_576
        try data.withUnsafeBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress
            var offset = 0
            while offset < data.count {
                let chunk = min(chunkSize, data.count - offset)
                if let e = afc_file_write(handle, base?.advanced(by: offset), chunk) {
                    throw ffiError(e, "写入文件失败：\(path)")
                }
                offset += chunk
            }
        }
    }

    /// 新建目录（复用调用方的连接）
    static func makeDirectory(client: OpaquePointer, path: String) throws {
        if let e = path.withCString({ afc_make_directory(client, $0) }) {
            throw ffiError(e, "新建目录失败：\(path)")
        }
    }

    /// 删除文件或目录（复用调用方的连接）
    static func removePath(client: OpaquePointer, path: String,
                           includingContents: Bool) throws {
        let e: UnsafeMutablePointer<IdeviceFfiError>? = path.withCString { p in
            if includingContents { afc_remove_path_and_contents(client, p) }
            else { afc_remove_path(client, p) }
        }
        if let e { throw ffiError(e, "删除失败：\(path)") }
    }
}

// MARK: - 列目录排序（所有 FileProvider 后端的单一真相源）

/// 列目录排序用的**全序**比较器（`true` 表示 `a` 应排在 `b` 之前）。
///
/// ## 为什么是共享的单一真相源
/// 「截断前先排序」这一不变量在**所有后端**都必须成立，否则同一缺陷会在不同后端各修一半：
///   - `AfcFileProvider` → `AFCService.listDirectoryBounded`（先廉价取名字 → 排序 → 截断）；
///   - `SandboxFileProvider` → `FileProvider.list(_:limit:)` **默认实现**（全量列举 → 排序 → 截断）。
/// 两处若各写一份比较器，就多了一个「有人改回 `localizedStandardCompare`」的入口，
/// 故把比较器收敛到这里，两处共同引用。
///
/// ## 为什么不能用 locale 相关的比较（`localizedStandardCompare` / `localizedCompare`）
/// `localizedStandardCompare` 按**当前系统语言**做排序。目录超过上限（3000）条时，先排序再取前 3000；
/// 若排序随系统语言变化，则**同一目录在不同语言的机器上会截断出不同的子集**。
/// **实测强度**：语料含 `ärger`/`zebra`（各 1500 条，瑞典语下 `ä` 排在 `z` 之后，英语相反），
/// 在 `en_US_POSIX` 与 `sv_SE` 下截断出的前 3000 条**对称差 = 3000 条、完全不相交** ——
/// 即「同一目录在不同系统语言下显示完全不同的文件」，而非「子集略有不同」。
/// 而客户端（FileZilla / Finder / 我们自己的增量同步与缓存）**依赖这个子集稳定**：
/// 子集一变，客户端会把「同一目录」当成换了一批文件，触发重复下载 / 缓存失效 / 看似文件消失。
/// 因此必须用 **locale 无关** 的比较。
///
/// ## 选型：固定 `en_US_POSIX` + `.numeric`（而非纯 UTF-8 字节序）
/// 保留「自然数字序」（`f2` < `f10`，符合用户直觉，也与 FileZilla/Finder 的默认观感一致），
/// 但把 locale **显式钉死**为 `en_US_POSIX`，不再读取系统语言 ⇒ 结果与系统语言无关。
/// （纯字节序虽最简，但会丢掉数字序，`f10` 排到 `f9` 前面，不直观。）
///
/// ## 为什么必须有 tie-breaker
/// 主比较器可能返回 `.orderedSame`（并列）—— 例如 Unicode 规范等价形式
/// （预组合 `"café"` vs 组合变音 `"cafe\u{0301}"`；实测二者被判并列）。
/// 而 Swift 的 `sort` **不是稳定排序**，并列项的相对顺序**不保证** ⇒ 同一批输入两次排序
/// 可能得到不同排列，截断边界随之漂移（第二处非确定性）。故当主比较器判并列时，
/// **退化到按原始名字的 UTF-8 字节序**比较，得到一个严格全序 —— 不依赖 `sort` 的稳定性。
/// （UTF-8 的字节序与 Unicode 标量码点序一致，故字节序是一个稳定、可移植的全序。）
///
/// - Note: 组合后的关系仍是严格弱序：collation 是传递的弱序，在等价类内再用全序打破并列，
///   得到的即全序。`a == b` 时两边都返回 `false`，行为自洽。
enum DirectoryOrdering {
    static func nameAscending(_ a: String, _ b: String) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let result = a.compare(b, options: [.numeric], range: nil, locale: locale)
        if result == .orderedSame {
            // 主比较器判并列 ⇒ 用 UTF-8 字节序打破并列，保证全序（Swift sort 非稳定，不能靠它）。
            return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
        return result == .orderedAscending
    }
}

// MARK: - 挂载根只读策略（暴露面写门禁的单一真相源）

/// AFC 挂载根的**只读策略** —— 所有暴露面写门禁的**唯一判据**。
///
/// ## 为什么必须只有一个真相源（本次绕过漏洞的根因）
/// 设计不变量 **I1**：默认暴露面只读，写操作需显式开启；违反后果是
/// 「局域网任意人可删设备文件」。I1 有两个暴露面：
/// - **SFTP**：`AfcFileProvider`（`SSHFileProvider.swift`）
/// - **SSH exec 能力**：`HostCapabilityService.afc.*`（`HostCapabilityService.swift`）
///
/// 这两处曾**各写一份** `root == .crash` 判断。对抗审计证明：两份实现必然漂移 ——
/// 门禁只堵住了 SFTP 那一路，`{"cap":"afc.delete","root":"crash","recursive":true}`
/// 直调 `AFCService.removePath` 完全绕过，可递归删光崩溃日志。
/// 因此判据集中在这里，**任何写路径都必须先经它放行**（两个暴露面共用同一错误类型）。
enum AfcRootPolicy {
    /// 只读根（暴露面上不允许 写 / 删 / 建 / 改名）。
    ///
    /// **为什么 `.crash` 只读**：crashreport 是**诊断挂载**，崩溃日志是排查闪退的
    /// **唯一现场证据**；暴露面（局域网可达）一旦允许写，现场就可被任意删除、不可复现。
    /// **为什么 `.media` 不在列**：它是主力文件通道（共享转换上传 IPA 靠它），
    /// 必须保持可写；App 沙盒根同理，且它根本不在 AFC 暴露面上。
    static let readOnlyRoots: Set<String> = ["crash"]

    /// 根标识规范化（两个暴露面的枚举 token 都是 "media" / "crash"）。
    static func canonical(_ raw: String) -> String { raw.lowercased() }

    /// 该根是否只读。
    static func isReadOnly(_ raw: String) -> Bool {
        readOnlyRoots.contains(canonical(raw))
    }

    /// 写门禁：只读根 ⇒ 抛 `.unsupported`（两个暴露面共用同一错误类型）。
    ///
    /// - Parameter op: 操作名（write / delete / mkdir / rename …），用于错误消息。
    static func requireWritable(_ raw: String, op: String) throws {
        guard isReadOnly(raw) else { return }
        throw FileProviderError.unsupported("crash 根只读（设计不变量 I1），不允许 \(op)")
    }
}
