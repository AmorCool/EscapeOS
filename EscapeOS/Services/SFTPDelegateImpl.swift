//
//  SFTPDelegateImpl.swift
//  EscapeSpace
//
//  SSH/SFTP 升级（文件域）——把 Citadel 的 `SFTPDelegate`（SFTP v3）桥接到
//  `FileProvider`（见 `SSHFileProvider.swift`）。
//
//  本文件只做三件事：
//   1. 把 Citadel 的 async delegate 调用，转成对**同步** FileProvider 的调用，
//      并统一走 `runFileOpWithTimeout`（硬超时）；
//   2. 把 `FileEntry` 映射成 SFTP 的 `SFTPFileAttributes` / `SFTPFileListing`；
//   3. 限制单次读的搬运量（防客户端一次请求巨量数据把内存打爆）。
//
//  ## Citadel API 出处（2026-10-05 核对）
//   - `SFTPDelegate` 协议与 `enableSFTP(withDelegate:)`：
//     https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/SFTP/Server/SFTPServer.swift
//     https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/Server.swift
//   - 0.8.0 → 0.12.1 唯一差异是新增 `Sendable` 约束，方法签名**完全一致**
//     （已逐文件 diff 核对）。`project.yml` 用 `from: 0.8.0`，CI 会解析到 0.12.x，
//     因此本文件按 0.12.1 签名实现，并对 0.8.0 同样成立。
//
//  ## 认证（安全硬要求）
//  挂 SFTP **不会**绕过认证：SSH 会话仍必须先通过 `PasswordAuthDelegate`
//  （`SSHServerService` 现有密码认证）。`enableSFTP` 只在**已认证的 session**上
//  额外开放一个子系统。**本文件不引入任何免密/匿名路径。**
//
//  ## ⚠️ Citadel 上游缺陷与应对（逐行核对 SFTPServerInboundHandler 后确认）
//  Citadel 入站处理器在**错误路径**上的行为不一致，直接抛错会导致：
//   - `remove / rename / setstat / symlink / stat / lstat / opendir` →
//     `.flatMapErrorThrowing { _ in }`（**吞错、不回 status**）→ 客户端**永久挂起**；
//   - `mkdir / rmdir / read / write` → `.flatMapError { 关通道 }` → **直接断连**。
//  应对（零成本、不改依赖）：
//   - **凡是返回 `SFTPStatusCode` 的 delegate 方法**（remove/mkdir/rmdir/rename/
//     addSymlink/write）一律 catch 后返回映射状态码，**绝不外抛**；
//   - `openFile` 不做 stat 探活（避免自己制造挂起）；
//   - `fileAttributes` / `openDirectory` 返回的是 attributes/handle，**协议上无法回状态码**
//     ⇒ 不抛错（抛错会让客户端挂起到自身超时）。
//       · `fileAttributes`：兜底回空 attributes（假阳性「存在」），不产生数据损坏。
//       · `openDirectory`：**不**回空 listing —— 失败回一条**可见的错误标记**，
//         截断在末尾追加**可见的截断标记**，绝不把「失败 / 截断」伪装成「空 / 完整目录」
//         （R1，见 `sftpMaxDirectoryEntries` 的说明）。此档亦不产生数据损坏
//         （`read` 仍 throw、写失败仍回状态码）。
//     彻底修好（回真正的 `SSH_FX_NO_SUCH_FILE` / 状态码）仍需给 Citadel 打补丁
//     （补丁文本见 `P0_工作产物标准区/EscapeSpace-SSH升级/impl-sftp/citadel_patch_sftp_error_status.md`）。
//

import Citadel
import Foundation
import NIO

// MARK: - 单次读上限

/// 单次 SFTP 读允许搬运的最大字节数。
///
/// SFTP 的 `read` 请求带一个 `UInt32 length`，理论上客户端能一次要 4GB。
/// 若直接按请求分配，会被单个恶意/异常请求打爆内存。
/// SFTP 允许**短读**（返回少于请求量，客户端会再发一次读），所以这里直接截断。
private let sftpMaxReadBytes = 256 * 1024

// MARK: - 读写合并（把「每包一次隧道」降为「每窗口 / 每 1MB 一次隧道」）

/// 预读窗口：一次 AFC 往返（= 新建并销毁一条 RSD 隧道 + AFC 连接）搬多少字节。
///
/// ## 根因（2026-10-05 真机实测，见交付说明）
/// AFC 后端的**每次** provider 调用都是一次 `AFCService.batch`，即
/// **新建并销毁一条 RSD 隧道 + AFC 连接**（实测约 0.16s）。
/// 而客户端（paramiko）按 **8KiB** 发 READ 包 ⇒ 3MiB 读回要 ~384 次隧道 ≈ **63s**，
/// 超过验收脚本的单操作硬超时（40s）⇒ 客户端熔断，并打印**通用**的
/// 「设备 SSH 服务疑似已被打死」提示（实测设备全程存活、sha256 一致）。
///
/// 修法：**预读窗口**把连续读包合并成一次隧道；**写合并**把连续写包合并成一次隧道。
/// 两者都只复用既有 `AFCService.batch` —— **不持有长连接、不新建队列**
/// （遵守 `SSHFileProvider.swift` 的 RSD 隧道铁律：绝不自建隧道、绝不并发）。
private let sftpReadAheadBytes = 256 * 1024

/// 写合并阈值：攒够这么多才落盘一次（每次落盘 = 一次 RSD 隧道）。
/// 客户端按 32KiB 发 WRITE 包 ⇒ 3MiB 上传从 96 次隧道降到 3 次。
private let sftpWriteCoalesceBytes = 1 << 20

/// 单次列目录**建元数据**（逐条 stat）的条目数上限（R1）。
///
/// ## 为什么需要（2026-10-05 真实客户端评估）
/// `openDirectory` 一次性取全目录。AFC 后端的成本是**逐条** `afc_get_file_info`
/// （真机实测 ~7.5ms/条）：`/media/DCIM/104APPLE` 1030 条 = **7.72s**；
/// 外推约 **1.2 万条**即触及 AFC 后端 `operationTimeout = 90s` ⇒ `provider.list`
/// 抛 `.timedOut` ⇒ 旧兜底回**空 listing** ⇒ 客户端把大目录显示成**空文件夹**
/// （静默假空，即本项目最忌讳的「静默错误答案」）。
///
/// ## 修法
/// 把「逐条 stat」的条目数**封顶**：名字由一次 `afc_list_directory` 廉价取回
/// （见 `AFCService.listNames`），超限的部分**不再 stat**；listing 末尾追加一条
/// **可见的截断标记**。失败时改回一条**可见的错误标记**（不再回空）。
/// 两者都让客户端**不可能**把「失败 / 截断」误当成「空目录 / 完整目录」。
///
/// 取值 3000：约 3000 × 7.5ms ≈ **22.5s**，低于客户端单操作硬超时（~40s）
/// 与 AFC `operationTimeout`（90s），留足余量。
private let sftpMaxDirectoryEntries = 3000

/// 标记条目的名字前缀：用**醒目的 `!!_`**（而非 `.` 开头）确保不会被客户端
/// 当隐藏文件过滤掉 —— 标记若被隐藏就失去了「可区分」的意义。
private let sftpMarkerPrefix = "!!_ESCAPESPACE_"


// MARK: - FileProviderError → SFTP 状态码

extension FileProviderError {
    /// 映射成 SFTP 状态码（供返回 `SFTPStatusCode` 的 delegate 方法使用）。
    ///
    /// 为什么不直接抛错：见 `SFTPFileSystemDelegate.status(_:_:)` 的说明 ——
    /// Citadel 入站处理器在错误路径上会「吞错不回」（客户端挂起）或「直接断连」。
    var sftpStatus: SFTPStatusCode {
        switch self {
        case .notFound:
            return .noSuchFile
        case .outOfRoot:
            // 越界「假装不存在」：**不泄露**该路径是否存在（安全口径，采纳 design-fileprovider
            // 与 research-sftp 的建议）。代价是客户端看到「不存在」而非「无权限」——
            // 对本调试工具无实际影响（越界路径客户端本就进不去）。
            return .noSuchFile
        case .permissionDenied:
            return .permissionDenied
        case .unsupported:
            return .unsupportedOperation
        case .timedOut, .io:
            return .failure
        }
    }
}

// MARK: - SFTPDelegate 实现

/// `SFTPDelegate`（SFTP v3）实现，桥接到统一 `FileProvider`。
///
/// `@unchecked Sendable`：本类无可变实例状态（只有两个 `let`），
/// 与 Citadel 0.12+ 对 `SFTPDelegate: Sendable` 的要求一致。
final class SFTPFileSystemDelegate: SFTPDelegate, @unchecked Sendable {
    private let provider: FileProvider

    init(provider: FileProvider) {
        self.provider = provider
    }

    // MARK: 属性映射

    static func attributes(for entry: FileEntry) -> SFTPFileAttributes {
        var attrs = SFTPFileAttributes(
            size: entry.size,
            accessModificationTime: entry.modified.map {
                SFTPFileAttributes.AccessModificationTime(accessTime: $0, modificationTime: $0)
            }
        )
        attrs.permissions = entry.permissions
        return attrs
    }

    private static func longname(for entry: FileEntry, formatter: DateFormatter) -> String {
        let type = entry.isDirectory ? "d" : "-"
        let perms = entry.isDirectory ? "rwxr-xr-x" : "rw-r--r--"
        let date = formatter.string(from: entry.modified ?? Date(timeIntervalSince1970: 0))
        return "\(type)\(perms) 1 mobile mobile \(entry.size) \(date) \(entry.name)"
    }

    /// 生成一条**可见的标记条目**，用于把「失败 / 截断」显式告诉客户端。
    ///
    /// 为什么不抛错也不回状态码：Citadel 的 `openDir` 处理器是
    /// `.flatMapErrorThrowing { _ in }`（吞错、不回包）⇒ 抛错 = 客户端**永久挂起**；
    /// 且 `openDirectory` 返回的是 handle，**协议上无法回状态码**（见文件头）。
    /// 因此唯一能传「这不是空目录 / 这不是完整目录」的通道，就是 **listing 的内容本身**。
    ///
    /// - Note: 标记是**普通文件条目**（size 0、非目录），故客户端可能尝试下载/删除它 ——
    ///   它会失败（该路径并不真实存在）。这是「可区分」的必要代价：宁可让用户看到一条
    ///   打不开的标记，也不要把失败伪装成空目录。名字前缀 `!!_ESCAPESPACE_` 使其一眼可辨。
    private static func markerListing(_ name: String, formatter: DateFormatter) -> SFTPFileListing {
        let entry = FileEntry(path: "/" + name, name: name, isDirectory: false, size: 0,
                              modified: nil, permissions: 0o100644)
        return SFTPFileListing(path: [
            SFTPPathComponent(
                filename: name,
                longname: longname(for: entry, formatter: formatter),
                attributes: attributes(for: entry)
            )
        ])
    }

    // MARK: SFTPDelegate

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        do {
            let entry = try await runFileOpWithTimeout(provider.operationTimeout, "stat \(path)") {
                try self.provider.stat(path)
            }
            return Self.attributes(for: entry)
        } catch {
            // 兜底：回空 attributes，**不抛**。
            //
            // 为什么：Citadel 的 STAT/LSTAT 处理器是 `.flatMapErrorThrowing { _ in }`
            // （吞错、不回包）⇒ 抛错会让客户端**挂起**到它自己的超时。对文件浏览器
            // （Finder / FileZilla）来说，**拼错一次路径就卡死**，比「答错」更糟。
            //
            // 兜底的准确语义：`.none` 被编码成一个**合法的 `SSH_FXP_ATTRS`**（`flags == 0`）
            // = 「条目存在、属性未知」⇒ 对不存在的路径会得到一次**假阳性「存在」**。
            //
            // 这不违背「禁止伪造成功」那条：那条针对的是**数据损坏类**
            // （空 buffer = EOF ⇒ 静默截断）。这里是**存在性检查**这一档，
            // **不产生数据损坏** —— `read` 仍然 throw（不会退化成 0 字节假成功），
            // 写失败由 `write` 回状态码。
            //
            // 已加日志让这个行为**可观测**；fork 后应换成真正的 `SSH_FX_NO_SUCH_FILE`。
            LoginLogger.shared.log("[SFTP] stat 失败 → 回空 attributes（假阳性存在，已知限制）：\(path) — \(error)")
            return .none
        }
    }

    /// 把 provider 调用收敛成 SFTP 状态码，**绝不外抛**。
    ///
    /// ⚠️ 为什么必须这样（已逐行核对 Citadel `SFTPServerInboundHandler`）：
    /// 这些操作的错误路径在 Citadel 里是
    ///   - `.flatMapErrorThrowing { _ in }`（remove / rename / setstat / symlink / stat / lstat / opendir）
    ///     → **吞错、不回 status → 客户端永久挂起**；
    ///   - `.flatMapError { 关通道 }`（mkdir / rmdir / read / write）→ **直接断连**。
    /// 所以「抛错」在客户端看来比「返回一个明确的状态码」更糟。
    /// 凡是**返回 `SFTPStatusCode`** 的 delegate 方法，一律 catch 后返回映射状态码。
    private func status(_ label: String, _ body: () async throws -> Void) async -> SFTPStatusCode {
        do {
            try await body()
            return .ok
        } catch let e as FileProviderError {
            return e.sftpStatus
        } catch {
            return .failure
        }
    }

    func openFile(_ filePath: String,
                  withAttributes: SFTPFileAttributes,
                  flags: SFTPOpenFileFlags,
                  context: SSHContext) async throws -> SFTPFileHandle {
        // 写打开：**一次性**把目标建好/清空（P0-1）。
        // 之后每个分块的 write 用不截断的模式（AFC 用 AfcRw）逐块写，
        // 否则每块 open 都 O_TRUNC ⇒ 多块上传被逐块截断。
        //
        // ⚠️ 用 `try?` 吞掉准备阶段的错误：Citadel 的 openFile 处理器**没有任何错误处理**，
        //    一旦 openFile 抛错 → 客户端挂起。真正的失败（如父目录不存在）
        //    由后续 write 以状态码暴露（write 已 catch 成状态码，不挂起）。
        if flags.contains(.write) {
            _ = try? await runFileOpWithTimeout(provider.operationTimeout, "prepare \(filePath)") {
                try self.provider.prepareForWrite(filePath, truncate: flags.contains(.truncate))
            }
        }

        return ProviderFileHandle(provider: provider, path: filePath)
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        await status("remove \(filePath)") {
            try await runFileOpWithTimeout(self.provider.operationTimeout, "remove \(filePath)") {
                try self.provider.removeFile(filePath)
            }
        }
    }

    func createDirectory(_ filePath: String,
                         withAttributes: SFTPFileAttributes,
                         context: SSHContext) async throws -> SFTPStatusCode {
        await status("mkdir \(filePath)") {
            try await runFileOpWithTimeout(self.provider.operationTimeout, "mkdir \(filePath)") {
                try self.provider.mkdir(filePath)
            }
        }
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        await status("rmdir \(filePath)") {
            try await runFileOpWithTimeout(self.provider.operationTimeout, "rmdir \(filePath)") {
                try self.provider.removeDirectory(filePath)
            }
        }
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let norm = (try? SSHPath.normalize(canonicalUrl)) ?? "/"
        let attrs = (try? await runFileOpWithTimeout(provider.operationTimeout, "realpath \(canonicalUrl)") {
            try self.provider.stat(norm)
        }).map(Self.attributes) ?? .none
        return [SFTPPathComponent(filename: norm, longname: norm, attributes: attrs)]
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        // 兜底**绝不回空 listing**（R1）。
        //
        // 旧兜底回空 listing 的语义是「一个合法的 OPENDIR 成功（零条目）」=「该目录存在但为空」
        // ⇒ 对**失败**（超时 / IO / 越界）与**不存在的路径**，客户端都会显示成
        // **空文件夹**，与「真实空目录」**无法区分** —— 这正是本项目最忌讳的
        // 「静默错误答案」。抛错又不可行：Citadel 的 `openDir` 是
        // `.flatMapErrorThrowing { _ in }`（吞错不回包）⇒ 客户端**永久挂起**。
        //
        // 唯一可行的可区分信号是 **listing 的内容本身**：失败回一条**可见的错误标记**，
        // 截断在末尾追加一条**可见的截断标记**。两者都**不可能**被当成空 / 完整目录。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"

        // 有界列举：最多 stat `sftpMaxDirectoryEntries` 条（AFC 后端会先廉价取名字、
        // 超限即停止逐条 stat ⇒ 单次 opendir 成本封在超时内）。
        let result: (entries: [FileEntry], total: Int)
        do {
            result = try await runFileOpWithTimeout(provider.operationTimeout, "list \(path)") {
                try self.provider.list(path, limit: sftpMaxDirectoryEntries)
            }
        } catch {
            LoginLogger.shared.log("[SFTP] opendir 失败 → 回**错误标记**条目（不再静默假空）：\(path) — \(error)")
            return ProviderDirectoryHandle(listings: [
                Self.markerListing("\(sftpMarkerPrefix)LISTING_FAILED", formatter: formatter)
            ])
        }

        var listings = result.entries.map { entry in
            SFTPFileListing(path: [
                SFTPPathComponent(
                    filename: entry.name,
                    longname: Self.longname(for: entry, formatter: formatter),
                    attributes: Self.attributes(for: entry)
                )
            ])
        }
        if result.total > result.entries.count {
            // 截断：把已取到的前 N 条 + 一条**可见的截断标记**回给客户端。
            // 标记里带上「已回条数 / 全部条数」，让用户知道被截断了多少。
            LoginLogger.shared.log("[SFTP] opendir 截断：\(path) 共 \(result.total) 条，超过上限 \(sftpMaxDirectoryEntries)，只回前 \(result.entries.count) 条（已追加截断标记）")
            listings.append(Self.markerListing(
                "\(sftpMarkerPrefix)TRUNCATED_\(result.entries.count)_OF_\(result.total)",
                formatter: formatter
            ))
        }
        return ProviderDirectoryHandle(listings: listings)
    }

    func setFileAttributes(to attributes: SFTPFileAttributes,
                           atPath path: String,
                           context: SSHContext) async throws -> SFTPStatusCode {
        // 后端不支持改属性（沙盒/AFC 都没有可移植的 chmod/utimes 原语）。
        // 返回 .ok 让客户端（上传后常会 fsetstat 设 mtime）继续，不因一个
        // 无意义的属性调用中断传输。**如实标注：属性并未真正写入。**
        .ok
    }

    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
        // 返回状态码而非抛错：Citadel 的 symlink 处理器吞错 → 抛错会让客户端挂起。
        .unsupportedOperation
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        // 返回类型是组件数组，无法回状态码；但 Citadel 的 readlink 处理器
        // 会 `writeAndFlush(status(.failure))`（**不是**吞错），所以抛错是安全的。
        throw FileProviderError.unsupported("不支持读取符号链接")
    }

    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        await status("rename \(oldPath) → \(newPath)") {
            try await runFileOpWithTimeout(self.provider.operationTimeout, "rename \(oldPath) → \(newPath)") {
                try self.provider.rename(oldPath, to: newPath)
            }
        }
    }
}

// MARK: - 文件句柄

/// 一个打开的 SFTP 文件：把连续 read/write 包**合并**后落到 FileProvider。
///
/// ## 为什么必须合并（2026-10-05 真机实测的根因）
/// AFC 后端每次 provider 调用 = 一次 `AFCService.batch` = 新建并销毁一条 RSD 隧道 +
/// AFC 连接（实测约 0.16s）。客户端按 8KiB 发 READ 包、32KiB 发 WRITE 包，
/// 若**逐包**落到 provider，则 3MiB 往返要 ~384 次（读）/ 96 次（写）隧道 ⇒ 读回约 63s，
/// 超过验收脚本的单操作硬超时（40s）⇒ 客户端熔断并**误报**「设备被打死」（实测设备存活）。
///
/// 合并只发生在本句柄的内存里：**不持有隧道、不持有 AFC 连接**，
/// 每次落盘仍是既有 `AFCService.batch`（遵守 RSD 隧道铁律，绝不并发建隧道）。
///
/// ## ⚠️ 耐久性已知限制（R2，2026-10-05 评估，**刻意保留、如实标注**）
/// `write` 返回 `.ok` 只表示「已进入内存缓冲」，**不表示已落盘** —— 最多
/// `sftpWriteCoalesceBytes`（1 MiB）仍在内存。后果：
/// - **优雅关闭（客户端发 `CLOSE`）：正确**。`close()` 强制 flush 尾巴，文件完整；
///   落盘失败还会重试一次（见 `close()`），**绝不静默丢**。
/// - **异常断开（未发 `CLOSE`）：已回 `.ok` 的 ≤1 MiB 会随句柄销毁而丢**。
///   若客户端随后**从「已确认偏移」续传**（跳过已 ack 的部分），文件会出现
///   **空洞 / 内容错位**（本子系统**唯一的静默损坏面**）；若客户端重传整文件、
///   或从**服务器实测 size** 续传，则无碍。
///
/// **为什么不用「写即落盘」消除它**：那等于退回「逐包一次隧道」，
/// 会把刚修好的 63.5s 超时（见上）原样带回。折中（调小阈值 / 定时 flush）
/// 只是**缩小**而非消除窗口，且会**改变**刚引入的性能特性，属需单独决策的调参，
/// 不宜在本次修复里静默改动。真正的根治是**会话级写穿透**（写即落盘），
/// 代价是慢 —— 留作后续架构项。**故本次选择「文档化」而非「修改」。**
final class ProviderFileHandle: SFTPFileHandle, @unchecked Sendable {
    private let provider: FileProvider
    private let path: String

    /// 保护下面的读窗口 / 写缓冲状态。Citadel 已用 `previousTask` 把同一会话的
    /// read/write/close 串行化，这里的锁只为满足 Swift 6 的 Sendable 检查。
    private let bufferLock = NSLock()
    /// 预读窗口（一次 AFC 往返取一个窗口，后续读包命中缓存）。
    private var readWindow = Data()
    private var readWindowStart: UInt64 = 0
    private var readWindowValid = false
    /// 读窗口代际：**每次写**都 +1。用于让「fetch 期间发生了写」的读窗口作废，
    /// 与写侧的 `clearWriteBufferIfUnchanged(base:count:)` 对称（见其说明）。
    private var readWindowGeneration: UInt64 = 0
    /// 写合并缓冲（连续写包攒到阈值才落盘一次）。
    private var writeBuffer = Data()
    private var writeBufferStart: UInt64 = 0
    private var writeBufferActive = false

    init(provider: FileProvider, path: String) {
        self.provider = provider
        self.path = path
    }

    // 必须写 `NIOCore.ByteBuffer`：`vendor/ApplePackage/Supplement/AsyncHTTPClientShim.swift:22`
    // 定义了一个**自己的** `public struct ByteBuffer`，与本文件同时可见 ⇒ 不限定模块会解析到它，
    // 表现为「`ByteBuffer` 没有 `getBytes`」+「`ProviderFileHandle` 不满足 `SFTPFileHandle`」。
    // （同一个 shim 还导出 `HTTPHeaders` / `HTTPResponseStatus` / `TLSConfiguration` /
    //  `EventLoopGroupProvider` —— 引用 NIO 同名类型时一并限定。）
    func read(at offset: UInt64, length: UInt32) async throws -> NIOCore.ByteBuffer {
        // 真错误只能抛（Citadel 的 readFile 处理器会关通道 = 断连，不是挂起）。
        // 刻意**不**把「读不到」转成空 buffer —— 那会被 Citadel 当作 EOF，
        // 客户端会生成一个 0 字节文件 = 假成功，比断连更糟。
        //
        // ⚠️⚠️ 入口校验的对象是**整个访问区间 `[offset, offset + length)`**，
        //      **不是 `offset` 单值**。只校验 `offset <= Int64.max` 是**不够**的：
        //      `offset == Int64.max` 能通过单值校验，但其后 helper 里的
        //      `rel + length`（即 `offset - base + length`）与 provider 侧的
        //      `Int(offset) + window` 仍会**溢出陷阱 = SIGILL**（独立复现）。
        //      只要保证「区间右端 ≤ Int64.max」，其后的 `offset - base + length` 必然也 ≤ Int64.max。
        //
        // 先钳制再转换：`sftpMaxReadBytes`(256KiB) 远小于 `UInt32.max`，钳制后 `Int(...)`
        // 不可能 trap（即便上游将来把 `length` 放宽成 UInt64，此处写法依然安全）。
        //
        // offset 单值就超出 Int64（> 8 EiB）⇒ 不可能是合法文件位置。
        //
        // ⚠️ 这里**有意抛错**，**不是**返回空 buffer / 0 字节 —— **不要**改成回空：
        //    越界读返回空会被 Citadel 当作 EOF ⇒ 客户端可能据此生成 0 字节文件 = 假成功
        //    （正是本函数开头禁止的那类静默截断）。抛错会让 Citadel 关闭通道（断连），
        //    这是**刻意**的取舍：宁可断连也不给出「看起来确定的错误答案」。
        guard offset <= UInt64(Int64.max) else {
            throw FileProviderError.unsupported("read offset 越界（超出 Int64）：\(offset)")
        }
        // 区间右端余量：上面的 guard 保证 `Int64(offset)` 合法且该差非负、不溢出。
        let maxReadable = Int64.max - Int64(offset)
        var want = Int(min(UInt64(length), UInt64(sftpMaxReadBytes)))
        // 把 want 收进区间右端（**短读**，SFTP 协议本就允许短读）⇒ 恒有 `offset + want <= Int64.max`。
        // 刻意**不**在此时抛错：offset 仍在 Int64 内的读**不该被误杀**
        // （如 `read(Int64.max - 10, 100)`，短读 10 字节即可，无需断连）。
        if Int64(want) > maxReadable { want = Int(maxReadable) }
        guard want > 0 else { return Self.makeBuffer(Data()) }

        // 未落盘的写必须对**同一句柄**的读可见（写后读一致性）：
        //  - 读范围被写缓冲**完全覆盖** → 直接切片返回（零隧道，覆盖「写完立刻读回」的常见路径）；
        //  - 只**部分相交** → 先落盘（一次隧道），再走正常读路径读回最新数据。
        // 不这样做的话，`appendToWriteBuffer` 已把读窗口置为失效，读会退回 provider，
        // 而此刻磁盘尚未更新 ⇒ 返回**旧字节**（独立验证报告的反例 1）。
        //
        // ⚠️ 这里 `flushWriteBuffer` **不 catch**：落盘失败即让 read 抛错（Citadel 关通道）。
        //    与写路径（catch 成状态码）**刻意不一致** —— 读侧宁可断连也**绝不**返回过期字节。
        if let hit = bufferedWriteRead(offset: offset, length: want) {
            return Self.makeBuffer(hit)
        }
        if writeBufferIntersects(offset: offset, length: want) {
            try await flushWriteBuffer()
        }

        if let hit = cachedRead(offset: offset, length: want) {
            return Self.makeBuffer(hit)
        }
        // 未命中：一次取满一个预读窗口，后续读包都命中缓存。
        // 窗口同样收进区间右端（`maxReadable`）：否则 provider 侧 `Int(offset) + window` 仍会溢出。
        let window = Int(min(Int64(max(want, sftpReadAheadBytes)), maxReadable))
        // 记下发起 fetch 时的读窗口代际；fetch 期间若发生写，代际会 +1，
        // 返回后就不再把这个（可能已过期的）窗口标为有效 —— 否则会覆盖写侧刚做的失效
        // （独立验证报告的反例 2）。
        let generation = currentReadWindowGeneration()
        let data = try await runFileOpWithTimeout(provider.operationTimeout, "read \(path)@\(offset)") {
            try self.provider.read(self.path, offset: offset, length: window)
        }
        storeReadWindowIfUnchanged(data, start: offset, generation: generation)
        return Self.makeBuffer(Data(data.prefix(want)))
    }

    func write(_ data: NIOCore.ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        // 用 `readableBytesView` 而不是 `getBytes(at:length:)`：后者在新版 NIO 上已不推荐，
        // 而这里要的就是「当前可读区间的全部字节」。
        let payload = Data(data.readableBytesView)
        guard !payload.isEmpty else { return .ok }
        // 同 read：入口校验的是**整个写入区间 `[offset, offset + payload.count)`**，
        // **不是 `offset` 单值**。只校验 offset 会让 `offset == Int64.max` 通过，
        // 随后 `shouldFlushBeforeAppending` 的 `writeBufferStart + count` 与
        // `writeBufferIntersects` 的 `offset + length` 触发**溢出陷阱 = 进程崩溃**（SIGILL）。
        // 写**无法短写**（不能丢字节），故直接回状态码拒绝；**不抛错**
        // （Citadel 的 writeFile 处理器抛错会直接断连，回状态码客户端才能收到明确错误）。
        guard offset <= UInt64(Int64.max),
              UInt64(payload.count) <= UInt64(Int64.max) - offset else { return .failure }
        do {
            // 偏移不连续 ⇒ 先落盘旧缓冲（保证 offset 语义正确）。
            if shouldFlushBeforeAppending(offset: offset) {
                try await flushWriteBuffer()
            }
            appendToWriteBuffer(offset: offset, payload: payload)
            // 攒够阈值 ⇒ 落盘一次（一次隧道写整段）。
            if shouldFlushWriteBuffer() {
                try await flushWriteBuffer()
            }
            return .ok
        } catch let e as FileProviderError {
            // 返回状态码而非抛错：Citadel 的 writeFile 处理器抛错会直接关通道（断连），
            // 返回状态码则客户端能收到明确的错误。
            return e.sftpStatus
        } catch {
            return .failure
        }
    }

    func close() async throws -> SFTPStatusCode {
        // 收尾：把不足一个阈值的尾巴落盘（文件大小/内容以此刻为准）。
        //
        // 失败时**重试一次**，但**只对 `.io`**（隧道抖动这类瞬态故障）：落盘是幂等的
        // （同一 offset 写同一份字节），且失败不会清空缓冲（见 `flushWriteBuffer`），故重试
        // **数据安全**；它给瞬态故障一次补救机会 —— 否则最后一次 close 失败时，缓冲尾巴会随
        // 句柄销毁而丢（独立验证报告的反例 3）。
        //
        // 其余错误**不重试**：
        //  - `.timedOut`：`runFileOpWithTimeout` 不可抢占，超时后底层 FFI 线程仍在跑，重试只会
        //    排在它后面，把 close 拖到 2×超时（AFC 为 2×90s）；
        //  - `.notFound` / `.permissionDenied` / `.unsupported` 等**确定性**错误必再失败，
        //    重试只是白开一条隧道。
        do {
            try await flushWriteBuffer()
            return .ok
        } catch let e as FileProviderError {
            guard case .io = e else { return e.sftpStatus }
        } catch {
            return .failure
        }
        // 第一次是瞬态失败：缓冲仍在，重试一次。
        do {
            try await flushWriteBuffer()
            return .ok
        } catch let e as FileProviderError {
            return e.sftpStatus
        } catch {
            return .failure
        }
    }

    // MARK: - 读缓存

    /// 命中预读窗口就切片返回（零 AFC 往返）；未命中返回 nil。
    private func cachedRead(offset: UInt64, length: Int) -> Data? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard readWindowValid, offset >= readWindowStart else { return nil }
        // 纵深防御：**不依赖溢出**的写法 —— 先比较、后相减
        // （`offset >= readWindowStart` 保证差非负，无需 `Int(offset - start)` 直接转）。
        let delta = offset - readWindowStart
        guard delta < UInt64(readWindow.count) else { return nil }
        let rel = Int(delta)   // delta < readWindow.count ⇒ 转 Int 安全
        let n = min(length, readWindow.count - rel)
        // rel + n <= readWindow.count ⇒ 不可能溢出。
        return readWindow.subdata(in: rel..<(rel + n))
    }

    /// 取当前读窗口代际（**同步**方法，不持锁跨越 await）。
    private func currentReadWindowGeneration() -> UInt64 {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return readWindowGeneration
    }

    /// 落读缓存 —— **仅当 fetch 期间没有写发生**（代际未变）时才写入。
    ///
    /// 与写侧的 `clearWriteBufferIfUnchanged(base:count:)` 对称：`read` 的「取数 → 落缓存」
    /// 跨越了 `await`，若期间有写把 `readWindowValid` 置为 false，无条件落缓存会把
    /// **过期窗口重新标为有效**，后续读就会命中旧数据。代际守卫让这种 in-flight 结果被丢弃。
    private func storeReadWindowIfUnchanged(_ data: Data, start: UInt64, generation: UInt64) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard readWindowGeneration == generation else { return }
        readWindow = data
        readWindowStart = start
        readWindowValid = true
    }

    // MARK: - 写合并

    private func shouldFlushBeforeAppending(offset: UInt64) -> Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard writeBufferActive else { return false }
        // 纵深防御：**不依赖溢出**的写法 —— 旧写法 `writeBufferStart + UInt64(writeBuffer.count)`
        // 在 `writeBufferStart` 接近 UInt64.max 时会溢出（SIGILL 向量 4）。这里改成先比较、后相减。
        let count = UInt64(writeBuffer.count)
        guard offset >= writeBufferStart else { return true }   // 落后于缓冲起点 ⇒ 必不连续
        return offset - writeBufferStart != count
    }

    private func shouldFlushWriteBuffer() -> Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return writeBufferActive && writeBuffer.count >= sftpWriteCoalesceBytes
    }

    private func appendToWriteBuffer(offset: UInt64, payload: Data) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        readWindowValid = false          // 写过之后读缓存可能过期
        readWindowGeneration &+= 1       // 让 in-flight 的读窗口 fetch 作废（见 storeReadWindowIfUnchanged）
        if !writeBufferActive {
            writeBufferStart = offset
            writeBuffer = Data()
            writeBufferActive = true
        }
        writeBuffer.append(payload)
    }

    /// 若写缓冲**完全覆盖** `[offset, offset+length)`，返回对应切片；否则返回 nil。
    /// 供 `read` 在落盘前读到未落盘的写（**同步**方法，不持锁跨越 await）。
    private func bufferedWriteRead(offset: UInt64, length: Int) -> Data? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard writeBufferActive, !writeBuffer.isEmpty, offset >= writeBufferStart else { return nil }
        // 纵深防御：**不依赖溢出**的写法 —— 旧写法 `rel + length` 在 `rel` 接近 Int.max 时
        // 溢出（SIGILL 向量 2）。这里全部用 UInt64 比较区间，再在已证安全后才转 Int。
        let delta = offset - writeBufferStart          // offset >= writeBufferStart ⇒ 非负
        let count = UInt64(writeBuffer.count)
        guard delta < count, UInt64(length) <= count - delta else { return nil }
        let rel = Int(delta)                            // delta < count ⇒ 转 Int 安全
        // rel + length <= count ⇒ 不可能溢出。
        return writeBuffer.subdata(in: rel..<(rel + length))
    }

    /// 写缓冲是否与 `[offset, offset+length)` **相交**（半开区间）。**同步**方法。
    private func writeBufferIntersects(offset: UInt64, length: Int) -> Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard writeBufferActive, !writeBuffer.isEmpty else { return false }
        let start = writeBufferStart
        let count = UInt64(writeBuffer.count)
        // 纵深防御：半开区间相交 = `offset < start+count && start < offset+length`。
        // 两处都不做裸加法（`start + count` / `offset + length` 都可能溢出，SIGILL 向量 4）。
        let beforeEnd: Bool
        if offset >= start {
            beforeEnd = offset - start < count      // 减法非负
        } else {
            beforeEnd = true                        // offset 在缓冲起点之前 ⇒ 必 < 右端
        }
        let sum = offset.addingReportingOverflow(UInt64(length))
        let afterStart = sum.overflow ? true : (start < sum.partialValue)
        return beforeEnd && afterStart
    }

    /// 取写缓冲快照（**同步**方法，不持锁跨越 await）。
    ///
    /// Swift 6 禁止在 async 上下文里调用 `NSLock.lock()/unlock()`
    /// （`error: instance method 'lock' is unavailable from asynchronous contexts`）。
    /// 所以把临界区**抽成同步方法**，async 函数只调用它们 —— 不依赖 `withLock` 的可用性。
    private func takeWriteBufferSnapshot() -> (base: UInt64, bytes: Data)? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard writeBufferActive, !writeBuffer.isEmpty else { return nil }
        return (writeBufferStart, writeBuffer)
    }

    /// 落盘成功后清空缓冲 —— **仅当缓冲未被并发改动过**（base 与长度都没变）。
    private func clearWriteBufferIfUnchanged(base: UInt64, count: Int) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        if writeBufferActive && writeBufferStart == base && writeBuffer.count == count {
            writeBuffer = Data()
            writeBufferActive = false
        }
    }

    /// 把写缓冲落盘一次；**成功才清空**，失败保留（下次 write/close 可重试，绝不静默丢）。
    private func flushWriteBuffer() async throws {
        guard let snap = takeWriteBufferSnapshot() else { return }

        try await runFileOpWithTimeout(provider.operationTimeout, "write \(path)@\(snap.base)") {
            try self.provider.write(self.path, offset: snap.base, data: snap.bytes)
        }

        clearWriteBufferIfUnchanged(base: snap.base, count: snap.bytes.count)
    }

    private static func makeBuffer(_ data: Data) -> NIOCore.ByteBuffer {
        var buffer = NIOCore.ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func readFileAttributes() async throws -> SFTPFileAttributes {
        let entry = try await runFileOpWithTimeout(provider.operationTimeout, "fstat \(path)") {
            try self.provider.stat(self.path)
        }
        return SFTPFileSystemDelegate.attributes(for: entry)
    }

    func setFileAttributes(to attributes: SFTPFileAttributes) async throws {
        // 同 delegate：后端无属性写入原语，接受但忽略（如实标注）。
    }
}

// MARK: - 目录句柄

/// 目录句柄：`openDirectory` 时**一次性**取好列表（与 Citadel handler 的用法一致），
/// `readDir` 阶段直接吐缓存，不再触达后端。
final class ProviderDirectoryHandle: SFTPDirectoryHandle, @unchecked Sendable {
    private let listings: [SFTPFileListing]

    init(listings: [SFTPFileListing]) {
        self.listings = listings
    }

    func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
        listings
    }
}
