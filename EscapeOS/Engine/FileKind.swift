import Foundation

/// How a file should be opened by default.
enum FileOpenMode: String, Hashable {
    case auto
    case preview
    case text
    case hex
    case image
    case pdf
    case media
    /// 结构化 plist 查看 / 编辑器（可增删改键值，见 PlistEditorView）。
    case plist
}

/// Classifies a file by extension for icons and default open behavior.
enum FileContentKind: String {
    case directory
    case image
    case pdf
    case audio
    case video
    case text
    case plist
    case json
    case xml
    case archive
    case database
    case binary

    var symbolName: String {
        switch self {
        case .directory: return "folder.fill"
        case .image: return "photo"
        case .pdf: return "doc.richtext.fill"
        case .audio: return "waveform"
        case .video: return "film.fill"
        case .text: return "doc.plaintext.fill"
        case .plist: return "list.bullet.rectangle"
        case .json: return "curlybraces"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "doc.zipper"
        case .database: return "cylinder.split.1x2"
        case .binary: return "doc.fill"
        }
    }

    static func classify(name: String, isDirectory: Bool) -> FileContentKind {
        if isDirectory { return .directory }
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if plistExtensions.contains(ext) { return .plist }
        if jsonExtensions.contains(ext) { return .json }
        if xmlExtensions.contains(ext) { return .xml }
        if archiveExtensions.contains(ext) { return .archive }
        if databaseExtensions.contains(ext) { return .database }
        if textExtensions.contains(ext) { return .text }
        return .binary
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico", "svg"
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "amr"
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "3gp", "3gpp"
    ]
    static let plistExtensions: Set<String> = [
        "plist", "entitlements", "mobileprovision", "mobileconfig", "strings"
    ]
    static let jsonExtensions: Set<String> = ["json", "jsonl"]
    static let xmlExtensions: Set<String> = ["xml", "html", "htm", "xhtml", "svg"]
    static let archiveExtensions: Set<String> = [
        "zip", "ipa", "apk", "jar", "deb", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "7z", "rar", "xz", "txz", "lz4", "lzma"
    ]
    static let databaseExtensions: Set<String> = [
        "db", "sqlite", "sqlite3", "realm", "wal", "shm"
    ]
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "md", "markdown", "csv", "tsv", "yml", "yaml",
        "ini", "conf", "cfg", "env", "toml", "rtf",
        "c", "h", "m", "mm", "cpp", "cc", "hpp", "swift", "js", "ts", "jsx", "tsx",
        "py", "rb", "php", "java", "kt", "go", "rs", "sh", "bash", "zsh", "lua",
        "css", "scss", "less", "sql", "pbxproj", "xcconfig", "gitignore",
        "dockerfile", "makefile", "mk", "plist", "strings", "entitlements",
        "json", "xml", "html", "htm", "svg"
    ]
}

enum FileNameRules {
    static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("/") && !trimmed.contains("\\") && trimmed != "." && trimmed != ".." else {
            return nil
        }
        return trimmed
    }
}

/// Resolves an archive member name under `destDir`. Rejects `..` and paths that escape the folder.
enum ArchiveEntryPath {
    static func resolve(_ entryName: String, under destDir: String) throws -> (path: String, isDirectory: Bool) {
        let root = (destDir as NSString).standardizingPath
        let normalized = entryName.replacingOccurrences(of: "\\", with: "/")
        let isDirectory = normalized.hasSuffix("/")
        let parts = normalized.split(separator: "/").map(String.init)
        if parts.contains("..") {
            throw FileServiceError.operationFailed("Unsafe path in archive: \(entryName)")
        }
        let dest = parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
        let destStd = (dest as NSString).standardizingPath
        guard destStd == root || destStd.hasPrefix(root + "/") else {
            throw FileServiceError.operationFailed("Unsafe path in archive: \(entryName)")
        }
        return (destStd, isDirectory)
    }
}
