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
//     ⇒ 只能抛错，此时上游会挂起。**彻底修好需给 Citadel 打补丁**（补丁文本见
//     `P0_工作产物标准区/EscapeSpace-SSH升级/impl-sftp/citadel_patch_sftp_error_status.md`）。
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

    // MARK: SFTPDelegate

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        // 错误**不外抛**：Citadel 的 STAT/LSTAT 处理器是 `.flatMapErrorThrowing { _ in }`
        // （吞错、不回任何包）⇒ 抛错会让客户端**永久挂起**。
        // 返回空 attributes 是「避免挂起的兜底」——客户端据此判「不存在」。
        // 注意：这**不是**协议级状态码。彻底修好需给 Citadel 打补丁，回真正的
        // `SSH_FX_NO_SUCH_FILE`（见 design-fileprovider/FORK.md）。
        do {
            let entry = try await runFileOpWithTimeout(provider.operationTimeout, "stat \(path)") {
                try self.provider.stat(path)
            }
            return Self.attributes(for: entry)
        } catch {
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
        // 同 `fileAttributes`：Citadel 的 OPENDIR 处理器吞错 ⇒ 抛错会让客户端永久挂起。
        // 兜底为**空 listing**（客户端看到空目录，而不是挂死）。同样不是协议级状态码。
        let entries: [FileEntry]
        do {
            entries = try await runFileOpWithTimeout(provider.operationTimeout, "list \(path)") {
                try self.provider.list(path)
            }
        } catch {
            return ProviderDirectoryHandle(listings: [])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        let listings = entries.map { entry in
            SFTPFileListing(path: [
                SFTPPathComponent(
                    filename: entry.name,
                    longname: Self.longname(for: entry, formatter: formatter),
                    attributes: Self.attributes(for: entry)
                )
            ])
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

/// 一个打开的 SFTP 文件：每次 read/write 直接落到 FileProvider。
///
/// 不缓存文件内容、不持有连接 —— 这样即使客户端打开大文件也只按请求块搬运。
final class ProviderFileHandle: SFTPFileHandle, @unchecked Sendable {
    private let provider: FileProvider
    private let path: String

    init(provider: FileProvider, path: String) {
        self.provider = provider
        self.path = path
    }

    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        // 真错误只能抛（Citadel 的 readFile 处理器会关通道 = 断连，不是挂起）。
        // 刻意**不**把「读不到」转成空 buffer —— 那会被 Citadel 当作 EOF，
        // 客户端会生成一个 0 字节文件 = 假成功，比断连更糟。
        let want = min(Int(length), sftpMaxReadBytes)
        let data = try await runFileOpWithTimeout(provider.operationTimeout, "read \(path)@\(offset)") {
            try self.provider.read(self.path, offset: offset, length: want)
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        let bytes = data.getBytes(at: data.readerIndex, length: data.readableBytes) ?? []
        let payload = Data(bytes)
        do {
            try await runFileOpWithTimeout(provider.operationTimeout, "write \(path)@\(offset)") {
                try self.provider.write(self.path, offset: offset, data: payload)
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
        .ok
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
