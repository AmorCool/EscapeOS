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

        let names = Self.entryNames(at: path)

        var items: [FileItem] = []
        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            // 属性查不到时仍保留该条目（回退枚举出来的路径上 lstat 可能失败），
            // 至少让用户看到文件存在，而不是整个目录显示为空。
            guard let attrs = try? fm.attributesOfItem(atPath: full) else {
                items.append(FileItem(
                    name: name,
                    path: full,
                    kind: .other,
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

    /// 列出目录的一级条目名。
    ///
    /// 优先 FileManager（调用方通常已持有沙盒扩展，快）；返回空时回退
    /// `BadQueryLister`（bad_query_list inode 扫描）—— LiveContainer 访客沙盒下
    /// FileManager 对跨容器目录的列表会被裁剪，实测不可信（容器根目录尤其明显）。
    private static func entryNames(at path: String) -> [String] {
        let fmNames = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        if !fmNames.isEmpty { return fmNames }
        return BadQueryLister.entryNames(at: path)
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
