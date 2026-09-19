import Foundation
import UIKit

/// 壁纸包导入错误.
enum WallpaperImportError: Error, LocalizedError {
    case notTendiesArchive
    case noDescriptors
    case extractFailed(String)
    case persistFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notTendiesArchive:
            return "未识别到壁纸描述符，请确认文件为 .tendies 格式."
        case .noDescriptors:
            return "该压缩包内没有可应用的壁纸描述符."
        case .extractFailed(let m):
            return "解压失败：\(m)"
        case .persistFailed(let m):
            return "保存失败：\(m)"
        case .operationFailed(let m):
            return "操作失败：\(m)"
        }
    }
}

/// 负责解析 .tendies 壁纸包并准备 PosterBoard 描述符.
final class WallpaperHandler {

    private let fm = FileManager.default

    /// 壁纸包持久化根目录（Documents/Wallpapers）.
    static var wallpapersFolder: URL {
        BackupPaths.documentsDirectory().appendingPathComponent("Wallpapers", isDirectory: true)
    }

    /// 可被提取的系统描述符（来自 PosterBoard 容器）.
    struct ExtractableDescriptor: Identifiable, Hashable {
        let id = UUID()
        let provider: PBPath
        let name: String
        let path: String
        let fileCount: Int
    }

    /// 从 PosterBoard 容器中扫描可被提取的描述符.
    /// - Parameters:
    ///   - pbContainerPath: PosterBoard 容器根路径.
    ///   - sandbox: 用于消费沙盒扩展以读取 PosterBoard 容器.
    /// - Returns: 每个 provider 目录下找到的描述符列表.
    func extractableDescriptors(from pbContainerPath: String, using sandbox: SandboxEscape) throws -> [ExtractableDescriptor] {
        let handle = try sandbox.consume(path: pbContainerPath)
        defer { sandbox.release(handle) }

        let files = FileService()
        var results: [ExtractableDescriptor] = []
        for provider in PBPath.allCases {
            let providerPath = "\(pbContainerPath)/\(provider.path)"
            guard files.exists(at: providerPath), files.isDirectory(at: providerPath) else { continue }
            let children = try files.list(directory: providerPath)
            for child in children where child.isDirectory {
                let count = countFiles(at: child.path, files: files)
                results.append(ExtractableDescriptor(
                    provider: provider,
                    name: child.name,
                    path: child.path,
                    fileCount: count
                ))
            }
        }
        return results
    }

    private func countFiles(at path: String, files: FileService) -> Int {
        guard files.isDirectory(at: path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var count = 0
        for case let name as String in enumerator {
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                count += 1
            }
        }
        return count
    }

    /// 把选中的 PosterBoard 描述符导出为 .tendies 压缩包.
    /// - Parameters:
    ///   - descriptors: 要导出的描述符（可来自不同 provider）.
    ///   - pbContainerPath: PosterBoard 容器根路径.
    ///   - destination: 导出的 .tendies 文件目标路径.
    ///   - sandbox: 用于消费沙盒扩展.
    /// - Throws: 沙盒扩展失败或文件复制失败时抛出.
    func exportTendies(
        descriptors: [ExtractableDescriptor],
        from pbContainerPath: String,
        to destination: URL,
        using sandbox: SandboxEscape
    ) throws {
        guard !descriptors.isEmpty else {
            throw WallpaperImportError.operationFailed("未选择任何描述符")
        }

        let handle = try sandbox.consume(path: pbContainerPath)
        defer { sandbox.release(handle) }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ExtractTendies_\(UUID().uuidString)")
        let containerRoot = tempRoot.appendingPathComponent("container")
        defer { try? fm.removeItem(at: tempRoot) }

        // 重建与导入器兼容的 container/.../descriptors/<name> 目录结构.
        for descriptor in descriptors {
            let relativeToProvider = descriptor.path.dropFirst(pbContainerPath.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destDir = containerRoot.appendingPathComponent(relativeToProvider)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let children = try FileService().list(directory: descriptor.path)
            for child in children {
                let src = child.path
                let dst = destDir.appendingPathComponent(child.name)
                try fm.copyItem(atPath: src, toPath: dst.path)
            }
        }

        let writer = ZipWriter()
        try writer.begin(at: destination)
        let files = FileService()
        let topItems = try files.list(directory: tempRoot.path).map {
            FileItem(name: $0.name, path: $0.path, kind: $0.kind, size: $0.size, modified: $0.modified, isReadable: $0.isReadable, isWritable: $0.isWritable)
        }
        try writer.addItems(topItems, files: files, skipPath: destination.path)
        try writer.finish()
    }

    /// 从 .tendies 文件创建壁纸包对象，并将描述符持久化到沙盒.
    func makeObject(from url: URL) throws -> TendiesObject {
        let data = try Data(contentsOf: url)
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("ImportedTendies_\(url.lastPathComponent)_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let files = FileService()
        try ArchiveExtractor.extract(data: data, originalName: url.lastPathComponent, into: tempDir.path, files: files, password: nil)

        var rootURLs = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        var pbPath = PBPath.wpKit

        func descriptorURLs() -> [URL]? {
            var urls: [URL] = []

            // 有时文件会多嵌套一层，先找到真正的根目录.
            if let realRoot = rootURLs.first(where: {
                let name = $0.lastPathComponent
                return !name.localizedCaseInsensitiveContains("descriptor")
                    && !name.localizedCaseInsensitiveContains("ordered-descriptor")
                    && !name.localizedCaseInsensitiveContains("container")
                    && name != "__MACOSX"
            }) {
                if let inner = try? fm.contentsOfDirectory(at: realRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    rootURLs = inner
                }
            }

            // 检查 1：目录名直接包含 descriptor / ordered-descriptor / video-descriptor.
            for dirURL in rootURLs {
                let dirName = dirURL.lastPathComponent
                if dirName.localizedCaseInsensitiveContains("descriptor")
                    || dirName.localizedCaseInsensitiveContains("ordered-descriptor")
                    || dirName.localizedCaseInsensitiveContains("video-descriptor") {
                    if dirName.localizedCaseInsensitiveContains("video-descriptor") {
                        pbPath = .photos
                    }
                    guard let folderURLs = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
                        continue
                    }
                    if folderURLs.contains(where: { $0.lastPathComponent == "VideoCAML" }) {
                        pbPath = .photos
                    }
                    urls.append(contentsOf: folderURLs)
                    return urls
                }
            }

            // 检查 2：嵌套在 container 目录下，需要匹配三种目标路径之一.
            if let containerDir = rootURLs.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains("container") }) {
                for option in PBPath.allCases {
                    let candidate = containerDir.appendingPathComponent(option.path)
                    if fm.fileExists(atPath: candidate.path) {
                        pbPath = option
                        guard let folderURLs = try? fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
                            return nil
                        }
                        urls.append(contentsOf: folderURLs)
                        return urls
                    }
                }
            }
            return nil
        }

        guard let descrURLs = descriptorURLs(), !descrURLs.isEmpty else {
            throw WallpaperImportError.noDescriptors
        }

        let tendiesName = url.deletingPathExtension().lastPathComponent
        let folderName = "ImportedTendies_\(tendiesName)_\(UUID().uuidString)"
        let descrRoot = Self.wallpapersFolder.appendingPathComponent(folderName)
        try fm.createDirectory(at: descrRoot, withIntermediateDirectories: true)

        var descrNames: [String] = []
        for url in descrURLs {
            let descrName = "CustomDescriptor_\(tendiesName)_\(UUID().uuidString)"
            let target = descrRoot.appendingPathComponent(descrName)
            try fm.moveItem(at: url, to: target)
            randomizeWallpaperIDs(target)
            descrNames.append(descrName)
        }

        return TendiesObject(
            name: tendiesName,
            folderName: folderName,
            descrNames: descrNames,
            isOn: false,
            targetDescr: pbPath
        )
    }

    /// 随机化描述符中的 identifier，避免与系统已有壁纸冲突.
    private func randomizeWallpaperIDs(_ descrURL: URL) {
        let id = Int.random(in: 9999...99999)
        guard let enumerator = fm.enumerator(at: descrURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            switch fileURL.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try? String(id).data(using: .utf8)?.write(to: fileURL)
            case "com.apple.posterkit.provider.contents.userInfo":
                setPlistValue(fileURL, key: "wallpaperRepresentingIdentifier", value: id)
            case "Wallpaper.plist":
                setPlistValue(fileURL, key: "identifier", value: id)
            default:
                break
            }
        }
    }

    private func setPlistValue(_ url: URL, key: String, value: Any) {
        do {
            guard let data = fm.contents(atPath: url.path),
                  var dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return
            }
            dict[key] = value
            guard let newData = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) else { return }
            try newData.write(to: url)
        } catch {
            print("[wallpaper] failed to update plist \(url): \(error)")
        }
    }
}

// MARK: - PosterBoard 容器路径发现

extension WallpaperHandler {

    /// 枚举 /var/mobile/Containers/Data/Application，查找 PosterBoard 容器路径.
    static func discoverPosterBoardContainer() -> String {
        let base = "/var/mobile/Containers/Data/Application"
        let paths = listDirectory(base)
        for path in paths {
            let supportDir = "\(path)/Library/Application Support"
            let inner = listDirectory(supportDir)
            if inner.contains(where: { $0.contains("PRBPosterExtensionDataStore") }) {
                return path
            }
        }
        return ""
    }

    private static func listDirectory(_ path: String) -> [String] {
        // 跨容器目录在 LiveContainer 沙盒下列不出来，走漏洞利用注册表.
        ExploitRegistry.run { $0.paths(at: path, maxInode: 100_000) } ?? []
    }
}

// MARK: - 移除已应用的自定义描述符

extension WallpaperHandler {

    /// 移除我们**记录在案**的已应用描述符目录；记录之外的一律不碰.
    ///
    /// 为什么必须查记录、不能再靠特征猜：v0.3.460 之前这里是按「目录内 identifier 能取到整数」
    /// 判「自定义」，依据是「Apple 内置用 UUID」—— 真机上 Apple 的默认收藏**也是整数**，
    /// 于是被一并删掉。任何「按特征猜归属」的判据都不可靠；唯一可靠的依据是**我们自己装的时候
    /// 记下来的目录名**（`TendiesObject.appliedDescriptors`，由 `applyObjects()` 写入）。
    /// 记录之外的一切 —— Apple 默认收藏、以及本修复之前装的没有记录的目录 —— **一律不删**，
    /// 只如实报个数.
    ///
    /// - Parameters:
    ///   - containerPath: PosterBoard 容器根路径.
    ///   - recorded: 记录在案的目录名，key = `PBPath.rawValue`.
    ///   - sandbox: 用于消费沙盒扩展以获得容器写权限（与 `applyObjects()` 同一条路）.
    /// - Returns: `(removed: 删掉的目录名（按 provider 分组，供调用方清记录）, failed: 删除失败数,
    ///   unreadable: 读不了的目录数, unrecorded: 不在记录中的目录数)`.
    ///   单个删除失败**不中断**、也不吞掉 —— 否则「删了 2 个、第 3 个失败」会被报成整体失败，
    ///   而用户的数据其实已经动过了（`CORE.md`：如实报）.
    ///   `unreadable` **单独占一格**：目录列不出来时**里面有几个是未知的**，混进 `failed` 就是编数字；
    ///   未知 ≠ 失败（同「无法判定 ≠ 没找到」）.
    /// - Throws: 只在**一件事都没开始做**时抛：`WallpaperImportError` 容器路径非法 / 无 provider 目录；
    ///           `SandboxEscapeError` 拿不到沙盒扩展（两者都发生在下面**第一遍**收集阶段）.
    func removeAppliedDescriptors(
        containerPath: String,
        recorded: [String: [String]],
        using sandbox: SandboxEscape
    ) throws -> (removed: [String: [String]], failed: Int, unreadable: Int, unrecorded: Int) {
        // 容器根合法性：空路径或 "/" 会让下面的遍历在错误的层级上删东西.
        guard !containerPath.isEmpty, containerPath != "/" else {
            throw WallpaperImportError.operationFailed("未找到 PosterBoard 容器")
        }

        let files = FileService()

        // 第一遍：只收集存在的 provider 目录并逐个拿沙盒扩展，**一个都不删**.
        // 任何一个拿不到扩展都在这里抛 —— 此时还什么都没动，报「没有写权限」才是准的；
        // 若边拿边删，provider 3 拿不到扩展时前两个已经删掉了，报出来的话就是错的.
        // 姿势与 applyObjects() 一致：先收齐全部 handle，再动手写.
        var targets: [(provider: PBPath, path: String, handle: SandboxEscape.Handle)] = []
        defer {
            // 函数级统一释放（不是循环内 defer）：中途抛错也要把已拿到的 handle 全部还回去.
            for target in targets { sandbox.release(target.handle) }
        }

        for provider in PBPath.allCases {
            let providerPath = "\(containerPath)/\(provider.path)"
            guard files.exists(at: providerPath), files.isDirectory(at: providerPath) else { continue }
            let handle = try sandbox.consume(path: providerPath)
            targets.append((provider, providerPath, handle))
        }

        // 三个 provider 目录一个都不在 ⇒ 容器路径已失效（例如 generation 变了），如实报错而不是报「0 张」.
        guard !targets.isEmpty else {
            throw WallpaperImportError.operationFailed("未找到 PosterBoard 容器")
        }

        // 第二遍：动手删。单个失败只计数、继续删剩下的，最后把几个数字一起如实报给用户.
        var removed: [String: [String]] = [:]
        var failed = 0
        var unreadable = 0
        var unrecorded = 0

        for target in targets {
            // 目录列不出来 ⇒ 里面有几个无从得知，只能单独记一笔「读不了」，不能算成「N 个失败」.
            let children: [FileItem]
            do {
                children = try files.list(directory: target.path)
            } catch {
                print("[wallpaper] failed to list \(target.path): \(error)")
                unreadable += 1
                continue
            }

            // 只有「记录里点了名」的目录才进待删名单；其余只数、不碰.
            let recordedNames = Set(recorded[target.provider.rawValue] ?? [])

            for child in children {
                // 只认目录：普通文件及其它类型一律跳过.
                guard child.isDirectory else { continue }

                // 拒绝符号链接：不跟随链接删除，否则可能删到 provider 目录之外.
                let values = try? URL(fileURLWithPath: child.path)
                    .resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }

                // 路径包含性校验：待删目录必须真的在 provider 目录内（防路径穿越误删）.
                guard child.path.hasPrefix(target.path + "/") else { continue }

                // 判据只有一条：这个目录名在我们自己的记录里。除此之外不看任何特征.
                guard recordedNames.contains(child.name) else {
                    // 不在记录里 ⇒ 可能是 Apple 默认收藏，也可能是本修复之前装的 —— 无法确认归属，不猜、不删.
                    unrecorded += 1
                    continue
                }

                // 逐个删：失败只计数、继续删剩下的.
                do {
                    try fm.removeItem(atPath: child.path)
                    removed[target.provider.rawValue, default: []].append(child.name)
                } catch {
                    print("[wallpaper] failed to remove \(child.path): \(error)")
                    failed += 1
                }
            }
        }

        return (removed, failed, unreadable, unrecorded)
    }

}
