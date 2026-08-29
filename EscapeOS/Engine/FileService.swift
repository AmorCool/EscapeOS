import Foundation

/// A single entry in a directory listing.
struct FileItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case directory
        case regular
        case symlink
        case other
    }

    let id = UUID()
    let name: String
    let path: String
    let kind: Kind
    let size: Int64
    let modified: Date?
    let isReadable: Bool
    let isWritable: Bool

    var isDirectory: Bool { kind == .directory }
}

/// Errors surfaced by file operations.
enum FileServiceError: Error, LocalizedError {
    case pathNotFound(String)
    case permissionDenied(String)
    case notDirectory(String)
    case notRegularFile(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let p): return "Path not found: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .notDirectory(let p): return "Not a directory: \(p)"
        case .notRegularFile(let p): return "Not a regular file: \(p)"
        case .operationFailed(let m): return "Operation failed: \(m)"
        }
    }
}

/// Performs filesystem operations against a path for which a sandbox
/// extension has already been consumed via `SandboxEscape`.
final class FileService {

    private let fm = FileManager.default

    // MARK: - Metadata

    func exists(at path: String) -> Bool {
        fm.fileExists(atPath: path)
    }

    func isDirectory(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    func attributes(at path: String) throws -> [FileAttributeKey: Any] {
        do {
            return try fm.attributesOfItem(atPath: path)
        } catch {
            throw mapError(error, path: path)
        }
    }

    // MARK: - Listing

    func list(directory path: String) throws -> [FileItem] {
        guard isDirectory(at: path) else {
            throw FileServiceError.notDirectory(path)
        }

        // 只用 FileManager：调用方通常已持有沙盒扩展，速度快。
        // 注意：不要在这里回退 bad_query_list —— 那会对「空目录 / 被沙盒裁剪的
        // 目录」触发 O(maxInode) 次 fsgetpath 扫描（默认 100 万次），空间回收
        // 递归 countTree、容器管理扫描等会因此慢到不可用（v0.2.97 实测回归）。
        // 容器根这类跨容器路径由 listContainerRoot(at:) 显式走 bad_query_list。
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: path)
        } catch {
            throw mapError(error, path: path)
        }
        return try buildFileItems(names: names, basePath: path, fallbackKind: .other)
    }

    /// 容器根目录专用枚举。
    ///
    /// 与 `list(directory:)` 不同，这里不先检查 `isDirectory`，也不依赖
    /// `FileManager.contentsOfDirectory` —— 在 LiveContainer 访客沙盒下，
    /// 后者对跨容器路径会被裁剪。这里采用三级策略（对齐 Erosion 的
    /// `bad_query_list` 思路，但更稳健）：
    /// 1. FileManager 快路径：部分只读系统目录（如 /var/containers/Bundle/Application）
    ///    在部分环境可直接列出，命中即快；
    /// 2. `bad_query_list` 默认 maxInode=1M（绝大多数容器 UUID 在此范围内）；
    /// 3. 仍为空则提高 maxInode=2M 重试（inode 号偏大的场景，如长期使用的
    ///    设备上后安装的 App 容器）。
    /// 属性取不到时仍然保留条目，让用户至少能看到目录存在。
    func listContainerRoot(at path: String) throws -> [FileItem] {
        var names: [String] = []
        if let fmNames = try? fm.contentsOfDirectory(atPath: path), !fmNames.isEmpty {
            names = fmNames
        } else {
            names = BadQueryLister.entryNames(at: path)
            if names.isEmpty {
                names = BadQueryLister.entryNames(at: path, maxInode: 2_000_000)
            }
        }
        return try buildFileItems(names: names, basePath: path, fallbackKind: .directory)
    }

    /// 直接列出目录一级条目，**不做 `isDirectory` 前置检查**。
    ///
    /// 用于「已通过 SandboxEscape 消费扩展」后的兜底枚举：LiveContainer 访客沙盒下
    /// `fileExists(atPath:isDirectory:)` 对跨容器路径可能仍返回 false（导致
    /// `list(directory:)` 误报 notDirectory），但扩展生效后 `contentsOfDirectory`
    /// 实际可列。应用安装目录（/var/containers/Bundle/Application）等场景需要它。
    func listDirectly(at path: String) throws -> [FileItem] {
        let names = try fm.contentsOfDirectory(atPath: path)
        return try buildFileItems(names: names, basePath: path, fallbackKind: .directory)
    }

    private func buildFileItems(names: [String], basePath: String, fallbackKind: FileItem.Kind) throws -> [FileItem] {
        var items: [FileItem] = []
        for name in names {
            let full = (basePath as NSString).appendingPathComponent(name)
            // 属性查不到时仍保留该条目（回退枚举出来的路径上 lstat 可能失败），
            // 至少让用户看到文件存在，而不是整个目录显示为空。
            guard let attrs = try? fm.attributesOfItem(atPath: full) else {
                items.append(FileItem(
                    name: name,
                    path: full,
                    kind: fallbackKind,
                    size: 0,
                    modified: nil,
                    isReadable: false,
                    isWritable: false
                ))
                continue
            }
            let type = attrs[.type] as? FileAttributeType
            let kind: FileItem.Kind
            if type == FileAttributeType.typeDirectory {
                kind = .directory
            } else if type == FileAttributeType.typeRegular {
                kind = .regular
            } else if type == FileAttributeType.typeSymbolicLink {
                kind = .symlink
            } else {
                kind = .other
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs[.modificationDate] as? Date
            let readable = fm.isReadableFile(atPath: full)
            let writable = fm.isWritableFile(atPath: full)
            items.append(FileItem(
                name: name,
                path: full,
                kind: kind,
                size: size,
                modified: modified,
                isReadable: readable,
                isWritable: writable
            ))
        }
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Read

    func readFile(at path: String, maxBytes: Int? = nil) throws -> Data {
        guard !isDirectory(at: path) else {
            throw FileServiceError.notRegularFile(path)
        }
        guard let stream = InputStream(fileAtPath: path) else {
            throw FileServiceError.pathNotFound(path)
        }
        stream.open()
        defer { stream.close() }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        var total = 0
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { throw stream.streamError ?? FileServiceError.operationFailed("read error") }
            if read == 0 { break }
            data.append(buffer, count: read)
            total += read
            if let max = maxBytes, total >= max { break }
        }
        return data
    }

    // MARK: - Write / Mutations

    func writeFile(data: Data, to path: String) throws {
        do {
            let parent = (path as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: parent) {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw mapError(error, path: path)
        }
    }

    /// Create an empty regular file. Fails if the path already exists.
    func createEmptyFile(at path: String) throws {
        if fm.fileExists(atPath: path) {
            throw FileServiceError.operationFailed("A file named that already exists.")
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try createDirectory(at: parent)
        }
        guard fm.createFile(atPath: path, contents: Data()) else {
            throw FileServiceError.operationFailed("Could not create file at \(path)")
        }
    }

    func createDirectory(at path: String) throws {
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw mapError(error, path: path)
        }
    }

    func copyItem(at src: String, to dst: String) throws {
        do {
            try fm.copyItem(atPath: src, toPath: dst)
        } catch {
            throw mapError(error, path: src)
        }
    }

    func moveItem(at src: String, to dst: String) throws {
        do {
            try fm.moveItem(atPath: src, toPath: dst)
        } catch {
            throw mapError(error, path: src)
        }
    }

    func renameItem(at path: String, to newName: String) throws {
        let dst = (path as NSString).deletingLastPathComponent.appending("/\(newName)")
        try moveItem(at: path, to: dst)
    }

    func deleteItem(at path: String) throws {
        do {
            try fm.removeItem(atPath: path)
        } catch {
            throw mapError(error, path: path)
        }
    }

    /// Empty a folder, skipping files that refuse to delete (common under Caches).
    /// Recurses so one locked file does not keep the rest. Never follows a path
    /// that standardizes outside `path`.
    @discardableResult
    func emptyDirectoryContentsBestEffort(at path: String) -> Int {
        emptyDirectoryContentsBestEffort(at: path, stayingUnder: (path as NSString).standardizingPath)
    }

    private func emptyDirectoryContentsBestEffort(at path: String, stayingUnder root: String) -> Int {
        let std = (path as NSString).standardizingPath
        guard std == root || std.hasPrefix(root + "/") else { return 1 }
        guard isDirectory(at: path) else { return 0 }
        let children: [FileItem]
        do {
            children = try list(directory: path)
        } catch {
            return 1
        }
        var skipped = 0
        for child in children {
            let childStd = (child.path as NSString).standardizingPath
            guard childStd == root || childStd.hasPrefix(root + "/") else {
                skipped += 1
                continue
            }
            do {
                try deleteItem(at: child.path)
            } catch {
                if child.kind == .directory {
                    skipped += emptyDirectoryContentsBestEffort(at: child.path, stayingUnder: root)
                    do {
                        try deleteItem(at: child.path)
                    } catch {
                        skipped += 1
                    }
                } else {
                    skipped += 1
                }
            }
        }
        return skipped
    }

    /// Next unused path in `directory` for `preferredName` (`foo.txt` → `foo 2.txt`).
    /// Uses only the last path component so `/abs` or `../x` cannot leave `directory`.
    func uniqueDestination(in directory: String, preferredName: String) -> String {
        let leaf = (preferredName as NSString).lastPathComponent
        let preferredName = FileNameRules.sanitize(leaf) ?? "extracted"
        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var index = 1
        while true {
            let name: String
            if index == 1 {
                name = preferredName
            } else if ext.isEmpty {
                name = "\(base) \(index)"
            } else {
                name = "\(base) \(index).\(ext)"
            }
            let candidate = (directory as NSString).appendingPathComponent(name)
            if !exists(at: candidate) {
                return candidate
            }
            index += 1
        }
    }

    /// Recursive inventory of a directory. Stops after `maxNodes` entries.
    func countTree(at path: String, maxNodes: Int = 20000) throws -> (files: Int, directories: Int, bytes: Int64) {
        var files = 0
        var directories = 0
        var bytes: Int64 = 0
        var nodes = 0

        func walk(_ current: String) throws {
            if nodes >= maxNodes { return }
            let entries = try list(directory: current)
            for entry in entries {
                nodes += 1
                if nodes > maxNodes { return }
                if entry.isDirectory {
                    directories += 1
                    do {
                        try walk(entry.path)
                    } catch {
                        // Locked cache folders must not zero the whole parent size.
                    }
                } else {
                    files += 1
                    bytes += entry.size
                }
            }
        }

        try walk(path)
        return (files, directories, bytes)
    }

    // MARK: - Helpers

    private func mapError(_ error: Error, path: String) -> FileServiceError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied(path)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .pathNotFound(path)
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) {
            return .permissionDenied(path)
        }
        return .operationFailed(ns.localizedDescription)
    }
}
