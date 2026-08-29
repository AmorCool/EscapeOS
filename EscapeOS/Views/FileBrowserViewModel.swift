import SwiftUI

enum CreateKind {
    case file
    case folder
}

final class FileBrowserViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentPath: String = "/"
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sharePayload: SharePayload?
    @Published var isExporting = false
    @Published var isZipping = false
    @Published var isPasting = false
    @Published var busyTitle = "处理中…"
    @Published var exportError: IdentifiedError?
    @Published var operationError: IdentifiedError?
    @Published var unzipPasswordItem: FileItem?
    @Published var unzipPasswordMessage = "该压缩包已加密，请输入密码后解压。"

    var isBusy: Bool { isZipping || isExporting || isPasting }

    /// 目录路径 → 解析出的容器名（App 名），仅在容器根浏览时有值。
    @Published var containerNames: [String: String] = [:]

    let rootPath: String
    let title: String
    /// 当前根是否是「容器根」。容器根走 `bad_query_list` 枚举，不消费沙盒扩展。
    let isContainerRoot: Bool
    /// bundle id → App 显示名（来自已加载的 App 列表，隧道数据，安全）。
    /// 为空时容器行只显示 bundle id（对齐 Erosion 原版）。
    let appNameIndex: [String: String]
    private let escape = SandboxEscape()
    private let files = FileService()

    /// 兼容原调用点（App 详情 / 空间回收）。class 的委托初始化必须标记为 convenience。
    convenience init(app: InstalledApp, initialPath: String? = nil) {
        self.init(rootPath: app.containerPath, title: app.name, initialPath: initialPath)
    }

    /// - Parameters:
    ///   - rootPath: 沙盒扩展的签发锚点 —— 每个文件操作都以它为基准申请扩展。
    ///   - title: 根层级的显示标题。
    ///   - appNameIndex: bundle id → App 显示名（可选）。
    init(rootPath: String, title: String, initialPath: String? = nil, appNameIndex: [String: String] = [:]) {
        self.rootPath = rootPath
        self.title = title
        self.isContainerRoot = FileSystemRoots.badQueryListRoots.contains(rootPath)
        self.appNameIndex = appNameIndex
        if let initialPath = initialPath {
            self.currentPath = initialPath
        } else {
            self.currentPath = rootPath
        }
    }

    var displayTitle: String {
        let last = (currentPath as NSString).lastPathComponent
        return currentPath == rootPath ? title : (last.isEmpty ? title : last)
    }

    func open(_ path: String) {
        isLoading = true
        errorMessage = nil
        currentPath = path

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let listed = try self.list(at: self.currentPath)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.items = listed
                    self.isLoading = false
                    self.resolveContainerNames()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.errorMessage = self.localizedOpenError(error)
                    self.isLoading = false
                }
            }
        }
    }

    /// 根据根路径类型选择正确的枚举方式：
    /// - 容器根：走 `bad_query_list`（多级回退），不消费沙盒扩展；空结果时
    ///   再兜底尝试签发扩展后用 FileManager 直接列（iOS 27 上部分只读目录可列）。
    /// - 普通根 / 容器内部：先尝试用沙盒扩展；失败时退回直接 `FileManager`。
    private func list(at path: String) throws -> [FileItem] {
        if isContainerRoot && path == rootPath {
            let items = try files.listContainerRoot(at: path)
            if !items.isEmpty { return items }
            // 兜底：签发扩展后用 FileManager 直接列（绕过 isDirectory 前置检查，
            // 沙盒下 fileExists 对跨容器路径可能误判）。成功则用，失败保持空列表。
            if let fallback = try? escape.withHandle(for: rootPath) { _ in
                try files.listDirectly(at: path)
            } {
                return fallback
            }
            return items
        }
        do {
            return try escape.withHandle(for: rootPath) { _ in
                try files.list(directory: path)
            }
        } catch {
            // 部分环境（如特定 LiveContainer 扩展已覆盖的路径）不需要显式签发
            // 就能用 FileManager 直接列出，失败时退回一次直接读取。
            return try files.list(directory: path)
        }
    }

    private func localizedOpenError(_ error: Error) -> String {
        if let sandboxError = error as? SandboxEscapeError {
            switch sandboxError {
            case .kernelRejected:
                if let entry = FileSystemRoots.entry(for: rootPath), entry.requiresRave {
                    return "当前系统版本无法访问「\(entry.title)」。该目录需要 iOS 27 特定预览版（24A5355q / 24A5370h / 24A5380h / 24A5390f）才支持。"
                }
                return "系统拒绝为此目录签发沙盒扩展，当前环境无法访问。"
            case .notAbsolutePath:
                return "路径格式不正确。"
            case .targetMissing:
                return "目标路径不存在。"
            case .resolveFailed:
                return "无法解析容器管理器符号。"
            case .queryCreateFailed:
                return "无法创建容器查询。"
            case .outsideSandbox:
                return "路径不在容器管理器沙盒内。"
            case .asprintfFailed:
                return "内部错误：构建查询字符串失败。"
            case .invalidHandle:
                return "沙盒句柄已失效。"
            case .unknown(let code):
                return "未知沙盒错误（代码 \(code)）。"
            }
        }
        return error.localizedDescription
    }

    /// 在容器根（如 /var/mobile/Containers/Data/Application）浏览时，把 UUID 目录
    /// 解析成可读标识。每个容器读一次 metadata plist 拿 bundle id（/ App Group 的
    /// group id），再用 `appNameIndex`（来自已加载的 App 列表，隧道数据）补 App
    /// 显示名，组合为「全名 (bundleId)」；无显示名时只显示 bundle id（对齐 Erosion）。
    /// 解析在后台批量跑（bad_query + plist，线程安全），结果回主线程刷新。
    private func resolveContainerNames() {
        guard FileSystemRoots.containerNameRoots.contains(currentPath) else {
            if !containerNames.isEmpty { containerNames = [:] }
            return
        }
        let paths = items.filter(\.isDirectory).map(\.path)
        guard !paths.isEmpty else { return }
        let resolver = ContainerNameResolver.shared
        let nameIndex = appNameIndex
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let resolved = resolver.resolveAll(containerPaths: paths)
            // bundle id → 显示名（有则组合，无则原样）
            var display: [String: String] = [:]
            for (path, identifier) in resolved {
                if let name = nameIndex[identifier], !name.isEmpty {
                    display[path] = "\(name) (\(identifier))"
                } else {
                    display[path] = identifier
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.containerNames = display
            }
        }
    }

    func create(name: String, kind: CreateKind) {
        guard let safe = FileNameRules.sanitize(name) else {
            operationError = IdentifiedError(message: "请输入不含斜杠的文件名。")
            return
        }
        let dest = (currentPath as NSString).appendingPathComponent(safe)
        mutate {
            if kind == .folder {
                try self.files.createDirectory(at: dest)
            } else {
                try self.files.createEmptyFile(at: dest)
            }
        }
    }

    func rename(item: FileItem, to newName: String) {
        guard let safe = FileNameRules.sanitize(newName) else {
            operationError = IdentifiedError(message: "请输入不含斜杠的文件名。")
            return
        }
        mutate {
            try self.files.renameItem(at: item.path, to: safe)
        }
    }

    func delete(item: FileItem) {
        delete(items: [item])
    }

    func delete(items: [FileItem]) {
        guard !items.isEmpty else { return }
        mutate {
            for item in items {
                try self.files.deleteItem(at: item.path)
            }
        }
    }

    func paste() {
        guard let clip = FileClipboard.shared.payload, !clip.items.isEmpty else { return }
        isPasting = true
        busyTitle = "粘贴中…"
        let destDir = currentPath
        let destContainer = rootPath
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try self.paste(clip, into: destDir, destContainer: destContainer)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isPasting = false
                    if clip.mode == .cut {
                        FileClipboard.shared.clear()
                    }
                    self.open(self.currentPath)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isPasting = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    private func paste(_ clip: FileClipboard.Payload, into destDir: String, destContainer: String) throws {
        for item in clip.items {
            if Self.wouldNest(source: item.path, inside: destDir) {
                throw FileServiceError.operationFailed("无法将文件夹粘贴到自身内部。")
            }
        }
        if clip.containerPath == destContainer {
            try escape.withHandle(for: destContainer) { _ in
                try self.transferSameContainer(clip, destDir: destDir)
            }
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapeos-clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try escape.withHandle(for: clip.containerPath) { _ in
            for item in clip.items {
                try self.files.copyItem(
                    at: item.path,
                    to: staging.appendingPathComponent(item.name).path
                )
            }
        }
        try escape.withHandle(for: destContainer) { _ in
            for item in clip.items {
                let dest = self.files.uniqueDestination(in: destDir, preferredName: item.name)
                try self.files.copyItem(
                    at: staging.appendingPathComponent(item.name).path,
                    to: dest
                )
            }
        }
        if clip.mode == .cut {
            try escape.withHandle(for: clip.containerPath) { _ in
                for item in clip.items {
                    try self.files.deleteItem(at: item.path)
                }
            }
        }
    }

    private func transferSameContainer(_ clip: FileClipboard.Payload, destDir: String) throws {
        let destNorm = (destDir as NSString).standardizingPath
        for item in clip.items {
            let parent = ((item.path as NSString).deletingLastPathComponent as NSString).standardizingPath
            if clip.mode == .cut && parent == destNorm {
                continue
            }
            let dest = files.uniqueDestination(in: destDir, preferredName: item.name)
            if clip.mode == .cut {
                try files.moveItem(at: item.path, to: dest)
            } else {
                try files.copyItem(at: item.path, to: dest)
            }
        }
    }

    private static func wouldNest(source: String, inside destDir: String) -> Bool {
        let src = (source as NSString).standardizingPath
        let dest = (destDir as NSString).standardizingPath
        return dest == src || dest.hasPrefix(src + "/")
    }

    func duplicate(item: FileItem) {
        duplicate(items: [item])
    }

    func duplicate(items: [FileItem]) {
        guard !items.isEmpty else { return }
        mutate {
            for item in items {
                let parent = (item.path as NSString).deletingLastPathComponent
                let ns = item.name as NSString
                let ext = ns.pathExtension
                let base = ns.deletingPathExtension
                let preferred = ext.isEmpty ? "\(item.name) copy" : "\(base) copy.\(ext)"
                let dest = self.files.uniqueDestination(in: parent, preferredName: preferred)
                try self.files.copyItem(at: item.path, to: dest)
            }
        }
    }

    func importFiles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        isZipping = true
        busyTitle = urls.count == 1 ? "正在导入…" : "正在导入 \(urls.count) 项…"
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try self.escape.withHandle(for: self.rootPath) { _ in
                    for url in urls {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        let dest = self.files.uniqueDestination(
                            in: self.currentPath,
                            preferredName: url.lastPathComponent
                        )
                        try self.files.writeFile(data: data, to: dest)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    self.open(self.currentPath)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func export(item: FileItem) {
        isExporting = true
        busyTitle = "准备中…"
        exportError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let dest = try Self.shareStagingURL(named: Self.shareName(for: item))
                try self.escape.withHandle(for: self.rootPath) { _ in
                    if item.isDirectory {
                        let zip = ZipWriter()
                        try zip.begin(at: dest)
                        do {
                            try zip.addItems([item], files: self.files, skipPath: dest.path)
                            try zip.finish()
                        } catch {
                            try? zip.finish()
                            throw error
                        }
                    } else {
                        let data = try self.files.readFile(at: item.path)
                        try data.write(to: dest, options: .atomic)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isExporting = false
                    self.sharePayload = SharePayload(url: dest)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isExporting = false
                    self.exportError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func zip(items: [FileItem]) {
        guard !items.isEmpty, !isZipping else { return }
        isZipping = true
        busyTitle = items.count == 1 ? "正在压缩…" : "正在压缩 \(items.count) 项…"
        operationError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let destPath: String = try self.escape.withHandle(for: self.rootPath) { _ in
                    let dest = self.files.uniqueDestination(
                        in: self.currentPath,
                        preferredName: Self.zipName(for: items)
                    )
                    let zip = ZipWriter()
                    try zip.begin(at: URL(fileURLWithPath: dest))
                    do {
                        try zip.addItems(items, files: self.files, skipPath: dest)
                        try zip.finish()
                    } catch {
                        try? zip.finish()
                        try? FileManager.default.removeItem(atPath: dest)
                        throw error
                    }
                    return dest
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    let name = (destPath as NSString).lastPathComponent
                    CopyFeedback.shared.show("已创建「\(name)」")
                    self.open(self.currentPath)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    func clearUnzipPasswordPrompt() {
        unzipPasswordItem = nil
        unzipPasswordMessage = "该压缩包已加密，请输入密码后解压。"
    }

    func unzip(item: FileItem, password: String? = nil) {
        guard !isZipping else { return }
        isZipping = true
        busyTitle = "正在解压…"
        operationError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let destName: String = try self.escape.withHandle(for: self.rootPath) { _ in
                    let bytes = try self.files.readFile(at: item.path)
                    if ArchiveExtractor.archiveNeedsPassword(bytes, name: item.name),
                       password == nil || password?.isEmpty == true {
                        throw ZipReaderError.passwordRequired
                    }
                    let preferred = ArchiveExtractor.folderName(from: item.name)
                    let dest = self.files.uniqueDestination(
                        in: self.currentPath,
                        preferredName: preferred.isEmpty ? "归档" : preferred
                    )
                    do {
                        try ArchiveExtractor.extract(
                            data: bytes,
                            originalName: item.name,
                            into: dest,
                            files: self.files,
                            password: password
                        )
                    } catch {
                        try? FileManager.default.removeItem(atPath: dest)
                        throw error
                    }
                    return (dest as NSString).lastPathComponent
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    self.clearUnzipPasswordPrompt()
                    CopyFeedback.shared.show("已解压到「\(destName)」")
                    self.open(self.currentPath)
                }
            } catch ZipReaderError.passwordRequired {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    self.unzipPasswordMessage = "该压缩包已加密，请输入密码后解压。"
                    self.unzipPasswordItem = item
                }
            } catch ZipReaderError.wrongPassword {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    self.unzipPasswordMessage = "密码错误，请重试。"
                    self.unzipPasswordItem = item
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isZipping = false
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }

    private static func zipName(for items: [FileItem]) -> String {
        if items.count == 1 {
            let name = items[0].name
            let ns = name as NSString
            if ns.pathExtension.lowercased() == "zip" {
                return "\(ns.deletingPathExtension) 归档.zip"
            }
            return "\(name).zip"
        }
        return "归档.zip"
    }

    private static func shareName(for item: FileItem) -> String {
        if item.isDirectory {
            return "\(item.name).zip"
        }
        return item.name
    }

    /// Stage a share file in EscapeOS Documents under the original name (no `shared_` prefix).
    private static func shareStagingURL(named name: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let dest = docs.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        return dest
    }

    private func mutate(_ body: @escaping () throws -> Void) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try self.escape.withHandle(for: self.rootPath) { _ in
                    try body()
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.open(self.currentPath)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.operationError = IdentifiedError(message: error.localizedDescription)
                }
            }
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct IdentifiedError: Identifiable {
    let id = UUID()
    let message: String
}

