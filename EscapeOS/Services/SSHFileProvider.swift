//
//  SSHFileProvider.swift
//  EscapeSpace
//
//  SSH/SFTP 升级（文件域）——**统一文件后端适配器**.
//
//  背景：现有 SSH 服务（`SSHServerService`）只有 exec 通道，PC 端只能用
//  `exec_command` 一条条跑。本文件提供 `FileProvider` 统一接口，供 SFTP
//  （`SFTPDelegateImpl.swift`）以及将来的 WebDAV 复用 —— **一套适配器，多个协议**。
//
//  后端（mount）：
//   - `sandbox` → 本 App 沙盒 `Documents/`（FileManager）
//   - `media`   → 设备 AFC `com.apple.afc`（根 = /var/mobile/Media）
//   - `crash`   → 设备 AFC `com.apple.crashreportcopymobile`
//                 （根 = /var/mobile/Library/Logs/CrashReporter）
//
//  ## 稳定性铁律（本项目已因并发建隧道打死设备两次，见 MY-FAULTS.md 缺陷 17）
//  1. **绝不自建 RSD 隧道、绝不并发** —— AFC 后端只走 `AFCService.shared.batch`
//     / `CrashLogService.shared.withAfc`，即复用既有串行队列（`AFCService.afcQueue`）。
//  2. **每个可能阻塞的操作都有硬超时** —— 所有 provider 调用都由
//     `runFileOpWithTimeout` 包裹，超时**明确抛错**，不挂住调用方。
//     （注：底层 FFI 调用无法被抢占，超时只是让**调用方**不再等待并报错；
//      被卡住的后台线程会在 FFI 返回后自行结束。）
//  3. **分块**：`read`/`write` 都带 offset 语义，单次搬运量由调用方限制；
//     AFC 写内部再按 1MB 分块（与 `AFCService.writeFile` 同款）。
//
//  ## 安全
//  所有后端都做**路径越界拒绝**：标准化后必须仍在允许根内，且拒绝 `..` 与 NUL。
//

import Foundation

// MARK: - 条目与错误

/// 一个文件/目录条目（后端口径）.
struct FileEntry: Sendable, Equatable {
    /// 后端口径的完整路径（以 "/" 开头，相对该后端根）.
    let path: String
    /// 末级名字（列目录用）.
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date?
    /// 含文件类型位（目录 0o040755 / 文件 0o100644），供 SFTP `ls -l` 判别类型.
    let permissions: UInt32
}

/// FileProvider 统一错误.
enum FileProviderError: Error, LocalizedError, Sendable {
    /// 路径不存在
    case notFound(String)
    /// 权限不足（含设备侧 AFC PermDenied）
    case permissionDenied(String)
    /// 路径越界（沙盒逃逸）
    case outOfRoot(String)
    /// 该后端不支持该操作
    case unsupported(String)
    /// 硬超时
    case timedOut(String)
    /// 其它 IO 错误
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p):       return "路径不存在：\(p)"
        case .permissionDenied(let p): return "权限不足：\(p)"
        case .outOfRoot(let p):      return "路径越界（仅限允许根内）：\(p)"
        case .unsupported(let s):    return "不支持：\(s)"
        case .timedOut(let s):       return "操作超时：\(s)"
        case .io(let s):             return s
        }
    }
}

// MARK: - 统一接口

/// 统一文件后端接口.
///
/// 同步 `throws`：调用方（SFTP delegate）负责把阻塞调用丢到后台线程 + 加硬超时，
/// 见 `runFileOpWithTimeout`。这样接口本身保持简单，超时策略集中在协议层之上。
protocol FileProvider: Sendable {
    /// 挂载点名字（用于日志与虚拟根列出）.
    var displayName: String { get }
    /// 该后端单次操作的硬超时（秒）.
    var operationTimeout: TimeInterval { get }

    /// 列目录.
    func list(_ path: String) throws -> [FileEntry]
    /// **有界**列举：最多为前 `limit` 条取元数据，回传 `(entries, total)`；
    /// `total > entries.count` 即表示被截断。
    ///
    /// 默认实现退化为「全量 `list` 后截断」——语义正确，但对 AFC 后端**不省成本**
    /// （仍会逐条 stat 全量）。`AfcFileProvider` 覆写为「先廉价取名字、超限即停止逐条 stat」，
    /// 把大目录的单次 opendir 成本封在超时内。用途见 `SFTPDelegateImpl.swift` 的 R1 说明。
    func list(_ path: String, limit: Int) throws -> (entries: [FileEntry], total: Int)
    /// 取元数据.
    func stat(_ path: String) throws -> FileEntry
    /// 从 `offset` 读最多 `length` 字节（可能短读；EOF 返回空 Data）.
    func read(_ path: String, offset: UInt64, length: Int) throws -> Data
    /// 从 `offset` 写 `data`（父目录须已存在；必要时创建文件）.
    func write(_ path: String, offset: UInt64, data: Data) throws
    /// 为「写」准备目标：`truncate == true` 创建/清空，否则仅在不存在时创建.
    ///
    /// ## 为什么必须单独这一步（P0-1：多块上传被逐块截断）
    /// AFC 的 `AfcWrOnly`("w") 每次 open 都带 **O_TRUNC**（`rust/idevice-ffi/src/afc.rs`：
    /// `AfcWrOnly = 0x3 // w  O_WRONLY | O_CREAT | O_TRUNC`）。若**每个分块**都用它 open，
    /// 第 2 块一 open 就把第 1 块截成 0 ⇒ **多块上传必损坏**（单块小文件反而正常，最难发现）。
    /// 修法：写入改用 **`AfcRw`("r+")**（`O_RDWR | O_CREAT`，**不截断**），
    /// 并在开始时用这一步一次性把文件建好/清空。
    func prepareForWrite(_ path: String, truncate: Bool) throws
    /// 新建目录.
    func mkdir(_ path: String) throws
    /// 删除**文件**（SFTP `unlink` 语义）。目标是目录 ⇒ 抛错，**绝不递归**.
    func removeFile(_ path: String) throws
    /// 删除**空目录**（SFTP `rmdir` 语义）。非空 ⇒ 抛错，**绝不递归**.
    func removeDirectory(_ path: String) throws
    /// 重命名 / 移动（同后端内）.
    func rename(_ from: String, to: String) throws
}

extension FileProvider {
    /// 有界列举的**默认实现**：全量列举 → **按名字排序** → 截断 → 按 (目录优先, 名字) 定序。
    ///
    /// 对 `SandboxFileProvider`（本地 FileManager，全量列举本就廉价）与
    /// `MountedFileProvider`（已在下方覆写为按挂载路由）足够；
    /// AFC 后端必须覆写，否则「全量 stat」的代价仍在（见协议注释）。
    ///
    /// ## 为什么截断前必须先排序（与 AFC 同一缺陷，勿删）
    /// `SandboxFileProvider.list` 返回 `FileManager.contentsOfDirectory` 的顺序（目录项顺序，
    /// 不保证稳定）。若直接取前 `limit` 条，**同一目录两次列举可能截断出不同子集**——
    /// 这正是 `AFCService.listDirectoryBounded` 修掉的同一个缺陷（后端不同、根因相同）。
    /// 故此处复用同一个比较器 `DirectoryOrdering.nameAscending`（locale 无关 + 全序，见其说明）：
    /// 先按名字排序得到**确定的**前 `limit` 条，再按 (目录优先, 名字) 做最终全序排序，
    /// 使 `/sandbox` 与 `/media`（AFC）的展示顺序与截断口径**一致**。
    func list(_ path: String, limit: Int) throws -> (entries: [FileEntry], total: Int) {
        let all = try list(path)
        let byName = all.sorted { DirectoryOrdering.nameAscending($0.name, $1.name) }
        let use = byName.count > limit ? Array(byName.prefix(limit)) : byName
        let sorted = use.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return DirectoryOrdering.nameAscending($0.name, $1.name)
        }
        return (sorted, all.count)
    }
}

// MARK: - 路径工具

/// 路径归一化：以 "/" 开头、折叠 "."、**拒绝 ".." 与 NUL**.
///
/// 为什么不放行 `..`：`HostCapabilityService.afcPath`（v0.3.501）放行 `..`
/// 是把边界交给**设备侧 AFC 沙盒**。但 SFTP 是我们自己新开的暴露面，
/// 且虚拟根下挂着三个不同后端 —— 放行 `..` 会让 `/media/../sandbox` 这类
/// 跨后端穿越变得难判定。这里**在字符串层直接拒绝**，把攻击面收死。
enum SSHPath {
    static func normalize(_ path: String) throws -> String {
        if path.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw FileProviderError.outOfRoot(path)
        }
        var out: [String] = []
        for comp in path.split(separator: "/").map(String.init) {
            if comp == "." { continue }
            if comp == ".." { throw FileProviderError.outOfRoot(path) }
            out.append(comp)
        }
        return "/" + out.joined(separator: "/")
    }

    /// 拼接父路径 + 子名字（父为 "/" 时避免双斜杠）.
    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    /// 取末级名字.
    static func lastComponent(_ path: String) -> String {
        let norm = (try? normalize(path)) ?? path
        if norm == "/" { return "/" }
        return norm.split(separator: "/").last.map(String.init) ?? norm
    }
}

// MARK: - 硬超时助手

/// 一次性认领盒子：保证 continuation 只被 resume 一次（超时与完成竞争）.
private final class TimeoutClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// SFTP 阻塞操作专用后台队列。
///
/// **并发**（`attributes: .concurrent`）：原先用串行队列，会让「一个客户端在 /media 慢读」
/// 把「另一个客户端在 /sandbox 的快 ls」堵在队尾（head-of-line blocking）。
/// AFC 的串行化由 `AFCService.afcQueue` 自己保证，这里**不需要**再串一次；
/// sandbox 的 FileManager 操作本身线程安全。故改为并发，只保证「不占用 NIO 事件循环」。
private let sftpBlockingQueue = DispatchQueue(label: "com.escapeos.sftp.blocking",
                                              qos: .utility,
                                              attributes: .concurrent)

/// 在后台线程执行**可能阻塞**的文件操作，并加**硬超时**。
///
/// 超时后：调用方立刻收到 `.timedOut` 错误，**不再等待**。
/// 被卡住的底层 FFI 线程会在返回后自行结束（无法被抢占，这一点如实标注）。
///
/// - Important: 这是本项目「每个可能阻塞的操作都必须有硬超时」铁律的落点，
///   **任何** provider 调用都必须经过它。
func runFileOpWithTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ label: String,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    let claim = TimeoutClaim()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        sftpBlockingQueue.async {
            let outcome: Result<T, FileProviderError>
            do {
                outcome = .success(try work())
            } catch let e as FileProviderError {
                outcome = .failure(e)
            } catch {
                outcome = .failure(.io("\(label)：\(error.localizedDescription)"))
            }
            if claim.claim() { cont.resume(with: outcome) }
        }
        // 计时器放 global，**不能**放 sftpBlockingQueue —— 否则会排在阻塞任务后面，永远不触发.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            if claim.claim() {
                cont.resume(throwing: FileProviderError.timedOut("\(label) 超过 \(String(format: "%.1f", seconds))s"))
            }
        }
    }
}

// MARK: - 后端 1：本 App 沙盒（Documents）

/// 本 App 沙盒 `Documents/` 后端（FileManager）。
///
/// 根 = `Documents`：与现有 `ls` / `cat` 命令的可见范围**完全一致**
/// （见 `SSHServerService.execute` 的 `case "ls"` / `case "cat"`），
/// 不扩大到整个 App 容器，避免把 `Library/` 里的密钥、配对文件暴露给 SFTP。
final class SandboxFileProvider: FileProvider, @unchecked Sendable {
    let displayName = "sandbox"
    let operationTimeout: TimeInterval = 15

    private let root: URL

    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.root = root
    }

    /// 把后端口径路径解析成绝对路径，并做**沙盒越界拒绝**.
    private func resolve(_ path: String) throws -> String {
        let norm = try SSHPath.normalize(path)
        let rootPath = root.standardizedFileURL.path
        let rel = norm == "/" ? "" : String(norm.dropFirst())
        let target = rel.isEmpty ? rootPath : (rootPath as NSString).appendingPathComponent(rel)
        // `standardizingPath` 按词法折叠 "." / ".." / "//"（".." 已在上一步拒绝，这里只兜底）
        let std = (target as NSString).standardizingPath
        guard std == rootPath || std.hasPrefix(rootPath + "/") else {
            throw FileProviderError.outOfRoot(path)
        }
        return std
    }

    func list(_ path: String) throws -> [FileEntry] {
        let abs = try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir) else {
            throw FileProviderError.notFound(path)
        }
        guard isDir.boolValue else { throw FileProviderError.io("不是目录：\(path)") }
        let names = try FileManager.default.contentsOfDirectory(atPath: abs)
        return names.map { name in
            let full = (abs as NSString).appendingPathComponent(name)
            let attrs = (try? FileManager.default.attributesOfItem(atPath: full)) ?? [:]
            let isD = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = attrs[.modificationDate] as? Date
            return FileEntry(
                path: SSHPath.join(path, name),
                name: name,
                isDirectory: isD,
                size: size,
                modified: mtime,
                permissions: isD ? 0o040755 : 0o100644
            )
        }
    }

    func stat(_ path: String) throws -> FileEntry {
        let abs = try resolve(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: abs) else {
            throw FileProviderError.notFound(path)
        }
        let isD = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return FileEntry(
            path: path,
            name: SSHPath.lastComponent(path),
            isDirectory: isD,
            size: size,
            modified: attrs[.modificationDate] as? Date,
            permissions: isD ? 0o040755 : 0o100644
        )
    }

    func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        let abs = try resolve(path)
        guard let fh = FileHandle(forReadingAtPath: abs) else {
            throw FileProviderError.notFound(path)
        }
        defer { try? fh.close() }
        if offset > 0 { try fh.seek(toOffset: offset) }
        return (try fh.read(upToCount: max(0, length))) ?? Data()
    }

    func write(_ path: String, offset: UInt64, data: Data) throws {
        let abs = try resolve(path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: abs) {
            // 父目录须已存在（与 AFC 后端语义一致）；createFile 失败由下面 open 报错兜底
            _ = fm.createFile(atPath: abs, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: abs) else {
            throw FileProviderError.io("无法打开写入：\(path)")
        }
        defer { try? fh.close() }
        if offset > 0 { try fh.seek(toOffset: offset) }
        try fh.write(contentsOf: data)
    }

    func mkdir(_ path: String) throws {
        let abs = try resolve(path)
        try FileManager.default.createDirectory(atPath: abs, withIntermediateDirectories: true)
    }

    func prepareForWrite(_ path: String, truncate: Bool) throws {
        let abs = try resolve(path)
        let fm = FileManager.default
        if truncate {
            // 只清空**文件**；目标是目录 ⇒ 抛错。
            // （`removeItem` 对目录是递归删除，放它过去会把整棵目录树删掉）
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: abs, isDirectory: &isDir) {
                guard !isDir.boolValue else {
                    throw FileProviderError.unsupported("目标是目录，不能作为写入目标：\(path)")
                }
                try fm.removeItem(atPath: abs)
            }
            guard fm.createFile(atPath: abs, contents: nil) else {
                throw FileProviderError.io("无法创建文件：\(path)")
            }
        } else if !fm.fileExists(atPath: abs) {
            guard fm.createFile(atPath: abs, contents: nil) else {
                throw FileProviderError.io("无法创建文件：\(path)")
            }
        }
    }

    /// SFTP `unlink`：只删文件。目标是目录 ⇒ 抛错（绝不递归删目录）.
    func removeFile(_ path: String) throws {
        let abs = try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir) else {
            throw FileProviderError.notFound(path)
        }
        guard !isDir.boolValue else {
            throw FileProviderError.unsupported("目标是目录，unlink 不能删除：\(path)")
        }
        try FileManager.default.removeItem(atPath: abs)
    }

    /// SFTP `rmdir`：只删空目录。非空 ⇒ 抛错（绝不递归删整棵树）.
    func removeDirectory(_ path: String) throws {
        let abs = try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir) else {
            throw FileProviderError.notFound(path)
        }
        guard isDir.boolValue else {
            throw FileProviderError.unsupported("目标不是目录：\(path)")
        }
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: abs)) ?? []
        guard kids.isEmpty else {
            throw FileProviderError.io("目录非空，rmdir 不能删除：\(path)")
        }
        try FileManager.default.removeItem(atPath: abs)
    }

    func rename(_ from: String, to: String) throws {
        let a = try resolve(from)
        let b = try resolve(to)
        try FileManager.default.moveItem(atPath: a, toPath: b)
    }
}

// MARK: - 后端 2：设备 AFC（media / crash）

/// 设备 AFC 后端。
///
/// **复用既有能力层调用路径**：`media` 走 `AFCService.shared.batch`
/// （内部 `afcQueue` 串行），`crash` 走 `CrashLogService.shared.withAfc`
/// （crashreport 服务会话只有它知道怎么连）。**不新建隧道、不新开队列**。
///
/// - Important: 每次操作 = 一次 `batch`（建隧道 + 连 AFC + 操作 + 关闭）。
///   这是**刻意**的：持有一条长连接会让别的功能（如界面里的 AFC 浏览器）
///   在 `afcQueue` 空闲时另开第二条隧道 ⇒ 触发 RSD 隧道并发铁律（缺陷 17）。
///   代价是**慢**（每块都可能重建隧道），如实标注；优化需与 `AFCService` 一起改。
final class AfcFileProvider: FileProvider, @unchecked Sendable {
    /// 后端根。rawValue 即挂载 token（"media" / "crash"），与
    /// `HostCapabilityService.AfcRoot` 及共享判据 `AfcRootPolicy` 同口径。
    enum Root: String, Sendable {
        case media
        case crash
    }

    let root: Root
    let operationTimeout: TimeInterval = 90   // 建隧道本身可能十几秒，留足

    init(root: Root) { self.root = root }

    var displayName: String { root.rawValue }

    /// 复用既有串行队列执行一段 AFC 操作（拿到 client 句柄）.
    private func withClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        switch root {
        case .media:
            return try AFCService.shared.batch { try body($0) }
        case .crash:
            return try CrashLogService.shared.withAfc { try body($0) }
        }
    }

    /// AFC 口径路径：去掉前导/尾随 "/"、拒绝 NUL 与 ".."（见 `SSHPath.normalize`）.
    private func afcPath(_ path: String) throws -> String {
        let norm = try SSHPath.normalize(path)
        return norm == "/" ? "/" : String(norm.dropFirst())
    }

    /// 写操作门禁（SFTP 暴露面）。
    ///
    /// 判据**不在本文件**，而是共享的 `AfcRootPolicy`（`AFCService.swift`）——
    /// 因为 I1 有两个暴露面（SFTP 走这里、SSH exec 走 `HostCapabilityService.afc.*`），
    /// 若两处各写一份 `== .crash` 必然漂移。本次对抗审计证明：门禁只堵了 SFTP 一路，
    /// `afc.delete {root:"crash",recursive:true}` 从 exec 侧完全绕过，可递归删光崩溃日志。
    /// ⇒ 判据收敛到 `AfcRootPolicy` 一处。
    ///
    /// 理由：崩溃日志是**诊断证据**，无正当的写/删用途；SFTP 在局域网可达，
    /// 误删会毁掉排障线索（正是 I1 要防的「局域网任意人可删设备文件」）。
    /// 抛 `.unsupported` ⇒ SFTP 回 `SSH_FX_OP_UNSUPPORTED`（`sftpStatus` 映射），
    /// 走「返回状态码」路径、**不会让客户端挂起**。
    ///
    /// 注：`media` 是否也收只读属**待用户定的设计决策**，`AfcRootPolicy` 当前**只覆盖 `.crash`**。
    private func requireWritable(_ op: String) throws {
        try AfcRootPolicy.requireWritable(root.rawValue, op: op)
    }

    /// FFI 错误 → FileProviderError（并释放 FFI 分配的错误对象）.
    private func ffiError(_ e: UnsafeMutablePointer<IdeviceFfiError>?, _ fallback: String) -> FileProviderError {
        guard let e else { return .io(fallback) }
        let message = e.pointee.message.map { String(cString: $0) } ?? ""
        let code = Int(e.pointee.code)
        idevice_error_free(e)
        let text = message.isEmpty ? fallback : message
        if text.contains("PermDenied") || text.contains("Permission") {
            return .permissionDenied("\(fallback)：\(text) (code=\(code))")
        }
        if text.contains("NoSuchFile") || text.contains("NotFound") {
            return .notFound("\(fallback)：\(text)")
        }
        return .io("\(fallback)：\(text) (code=\(code))")
    }

    func list(_ path: String) throws -> [FileEntry] {
        try list(path, limit: Int.max).entries
    }

    /// 有界列举（覆写默认实现）：AFC 的成本是**逐条** `afc_get_file_info`（~7.5ms/条），
    /// 故先一次 `afc_list_directory` 廉价取名字，**超限就不再逐条 stat**，
    /// 把大目录 opendir 的成本封在超时内（R1）。
    func list(_ path: String, limit: Int) throws -> (entries: [FileEntry], total: Int) {
        let p = try afcPath(path)
        let base = p == "/" ? "/" : "/" + p
        let (items, total) = try withClient { client in
            try AFCService.listDirectoryBounded(client: client, path: p, maxEntries: limit)
        }
        let entries = items.map { item in
            FileEntry(
                path: SSHPath.join(base, item.name),
                name: item.name,
                isDirectory: item.isDirectory,
                size: UInt64(max(0, item.size)),
                modified: item.modified,
                permissions: item.isDirectory ? 0o040755 : 0o100644
            )
        }
        return (entries, total)
    }

    func stat(_ path: String) throws -> FileEntry {
        let p = try afcPath(path)
        let result: AFCService.StatResult = try withClient { client in
            AFCService.statFile(client: client, path: p)
        }
        guard result.exists else { throw FileProviderError.notFound(path) }
        return FileEntry(
            path: path,
            name: SSHPath.lastComponent(path),
            isDirectory: result.isDirectory,
            size: UInt64(max(0, result.size)),
            modified: nil,
            permissions: result.isDirectory ? 0o040755 : 0o100644
        )
    }

    func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        let p = try afcPath(path)
        guard length > 0 else { return Data() }
        return try withClient { client in
            var handle: OpaquePointer?
            if let e = p.withCString({ afc_file_open(client, $0, AfcRdOnly, &handle) }) {
                throw self.ffiError(e, "打开文件失败")
            }
            guard let handle else { throw FileProviderError.io("打开文件失败：\(path)") }
            defer { _ = afc_file_close(handle) }
            if offset > 0 {
                var newPos: Int64 = 0
                if let e = afc_file_seek(handle, Int64(offset), 0, &newPos) {
                    throw self.ffiError(e, "定位失败")
                }
            }
            var data: UnsafeMutablePointer<UInt8>?
            var bytesRead = 0
            if let e = afc_file_read(handle, &data, UInt(length), &bytesRead) {
                throw self.ffiError(e, "读取失败")
            }
            defer { if let data { afc_file_read_data_free(data, bytesRead) } }
            guard let data, bytesRead > 0 else { return Data() }
            return Data(bytes: data, count: bytesRead)
        }
    }

    func write(_ path: String, offset: UInt64, data: Data) throws {
        try requireWritable("write")
        let p = try afcPath(path)
        guard !data.isEmpty else { return }
        try withClient { client in
            var handle: OpaquePointer?
            // 注意： 必须用 AfcRw("r+", O_RDWR|O_CREAT，**不截断**)而不是 AfcWrOnly("w", O_TRUNC)。
            //    否则每个分块 open 都会把文件截成 0 ⇒ 多块上传必损坏（P0-1）。
            //    文件的存在/清空由 `prepareForWrite` 在 openFile 时一次性处理。
            if let e = p.withCString({ afc_file_open(client, $0, AfcRw, &handle) }) {
                throw self.ffiError(e, "打开文件失败")
            }
            guard let handle else { throw FileProviderError.io("打开文件失败：\(path)") }
            defer { _ = afc_file_close(handle) }
            if offset > 0 {
                var newPos: Int64 = 0
                if let e = afc_file_seek(handle, Int64(offset), 0, &newPos) {
                    throw self.ffiError(e, "定位失败")
                }
            }
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                let chunk = 1 << 20   // 1MB，与 AFCService.writeFile 同款
                var written = 0
                while written < data.count {
                    let n = min(chunk, data.count - written)
                    if let e = afc_file_write(handle, base.advanced(by: written), n) {
                        throw self.ffiError(e, "写入失败")
                    }
                    written += n
                }
            }
        }
    }

    /// 为「写」准备目标（见协议注释：AFC 的 `AfcWrOnly` 带 O_TRUNC，不能每块 open）.
    ///
    /// - `truncate == true`：用 `AfcWrOnly` 建/清空一次（**唯一一次**允许截断）。
    /// - `truncate == false`：只在文件**不存在**时建空文件；已存在则什么都不做（**不截断**）。
    func prepareForWrite(_ path: String, truncate: Bool) throws {
        try requireWritable("prepareForWrite")
        let p = try afcPath(path)
        try withClient { client in
            if !truncate {
                // 已存在 → 不动它（避免误截断）；不存在才建
                let st = AFCService.statFile(client: client, path: p)
                if st.exists { return }
            }
            var handle: OpaquePointer?
            if let e = p.withCString({ afc_file_open(client, $0, AfcWrOnly, &handle) }) {
                throw self.ffiError(e, "创建/清空文件失败")
            }
            if let handle { _ = afc_file_close(handle) }
        }
    }

    func mkdir(_ path: String) throws {
        try requireWritable("mkdir")
        let p = try afcPath(path)
        try withClient { try AFCService.makeDirectory(client: $0, path: p) }
    }

    /// SFTP `unlink`：只删文件。**用非递归原语**，且先确认目标不是目录.
    func removeFile(_ path: String) throws {
        try requireWritable("removeFile")
        let p = try afcPath(path)
        let entry = try stat(path)
        guard !entry.isDirectory else {
            throw FileProviderError.unsupported("目标是目录，unlink 不能删除：\(path)")
        }
        try withClient { try AFCService.removePath(client: $0, path: p, includingContents: false) }
    }

    /// SFTP `rmdir`：只删空目录。**用非递归原语**，先确认是目录且为空.
    func removeDirectory(_ path: String) throws {
        try requireWritable("removeDirectory")
        let p = try afcPath(path)
        let entry = try stat(path)
        guard entry.isDirectory else {
            throw FileProviderError.unsupported("目标不是目录：\(path)")
        }
        guard try list(path).isEmpty else {
            throw FileProviderError.io("目录非空，rmdir 不能删除：\(path)")
        }
        try withClient { try AFCService.removePath(client: $0, path: p, includingContents: false) }
    }

    func rename(_ from: String, to: String) throws {
        try requireWritable("rename")
        let a = try afcPath(from)
        let b = try afcPath(to)
        try withClient { client in
            let e: UnsafeMutablePointer<IdeviceFfiError>? = a.withCString { s in
                b.withCString { t in
                    afc_rename_path(client, s, t)
                }
            }
            if let e { throw self.ffiError(e, "重命名失败") }
        }
    }
}

// MARK: - 虚拟根（把多个后端拼成一个 SFTP 命名空间）

/// 把多个后端挂到一个虚拟根下：
/// ```
/// /sandbox/...   本 App Documents
/// /media/...     设备 /var/mobile/Media
/// /crash/...     设备 CrashReporter
/// ```
/// SFTP 客户端连上来先看到 `/` 下这三个目录。
final class MountedFileProvider: FileProvider, @unchecked Sendable {
    struct Mount: Sendable {
        let name: String
        let provider: FileProvider
    }

    let displayName = "root"
    /// 虚拟根本身不做阻塞 IO，给一个保守的小超时即可.
    let operationTimeout: TimeInterval = 15

    private let order: [String]
    private let providers: [String: FileProvider]

    init(mounts: [Mount]) {
        var order: [String] = []
        var map: [String: FileProvider] = [:]
        for m in mounts where map[m.name] == nil {
            order.append(m.name)
            map[m.name] = m.provider
        }
        self.order = order
        self.providers = map
    }

    /// 拆路径 → (后端, 该后端内的子路径).
    private func route(_ path: String) throws -> (FileProvider, String) {
        let norm = try SSHPath.normalize(path)
        guard norm != "/" else { throw FileProviderError.unsupported("根目录不是文件") }
        let comps = norm.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = comps.first, let provider = providers[String(first)] else {
            throw FileProviderError.notFound(path)
        }
        let sub = comps.count > 1 ? "/" + comps[1] : "/"
        return (provider, sub)
    }

    private func syntheticMountEntry(_ name: String) -> FileEntry {
        FileEntry(path: "/" + name, name: name, isDirectory: true, size: 0,
                  modified: nil, permissions: 0o040755)
    }

    func list(_ path: String) throws -> [FileEntry] {
        try list(path, limit: Int.max).entries
    }

    /// 有界列举：把 `limit` 透传给**被挂载的子后端**（否则默认实现会在虚拟根层
    /// 先全量列举，AFC 的逐条 stat 成本就白省了）。
    func list(_ path: String, limit: Int) throws -> (entries: [FileEntry], total: Int) {
        let norm = try SSHPath.normalize(path)
        if norm == "/" { return (order.map(syntheticMountEntry), order.count) }
        let (provider, sub) = try route(norm)
        return try provider.list(sub, limit: limit)
    }

    func stat(_ path: String) throws -> FileEntry {
        let norm = try SSHPath.normalize(path)
        if norm == "/" { return FileEntry(path: "/", name: "/", isDirectory: true, size: 0, modified: nil, permissions: 0o040755) }
        let comps = norm.dropFirst().split(separator: "/")
        if comps.count == 1, let name = comps.first.map(String.init), providers[name] != nil {
            return syntheticMountEntry(name)
        }
        let (provider, sub) = try route(norm)
        return try provider.stat(sub)
    }

    func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        let (provider, sub) = try route(path)
        return try provider.read(sub, offset: offset, length: length)
    }

    func write(_ path: String, offset: UInt64, data: Data) throws {
        let (provider, sub) = try route(path)
        try provider.write(sub, offset: offset, data: data)
    }

    func mkdir(_ path: String) throws {
        let (provider, sub) = try route(path)
        try provider.mkdir(sub)
    }

    func prepareForWrite(_ path: String, truncate: Bool) throws {
        let (provider, sub) = try route(path)
        try provider.prepareForWrite(sub, truncate: truncate)
    }

    func removeFile(_ path: String) throws {
        let (provider, sub) = try route(path)
        try provider.removeFile(sub)
    }

    func removeDirectory(_ path: String) throws {
        let (provider, sub) = try route(path)
        try provider.removeDirectory(sub)
    }

    func rename(_ from: String, to: String) throws {
        let (aProvider, aSub) = try route(from)
        let (bProvider, bSub) = try route(to)
        guard aProvider.displayName == bProvider.displayName else {
            throw FileProviderError.unsupported("不支持跨挂载点移动（\(aProvider.displayName) → \(bProvider.displayName)）")
        }
        try aProvider.rename(aSub, to: bSub)
    }
}

// MARK: - 工厂

/// 生产环境的默认 FileProvider（虚拟根 + 三个后端）.
enum SSHFileProviderFactory {
    static func makeDefault() -> FileProvider {
        MountedFileProvider(mounts: [
            .init(name: "sandbox", provider: SandboxFileProvider()),
            .init(name: "media", provider: AfcFileProvider(root: .media)),
            .init(name: "crash", provider: AfcFileProvider(root: .crash)),
        ])
    }
}
