import Foundation
import UIKit

/// 壁纸包导入错误。
enum WallpaperImportError: Error, LocalizedError {
    case notTendiesArchive
    case noDescriptors
    case extractFailed(String)
    case persistFailed(String)

    var errorDescription: String? {
        switch self {
        case .notTendiesArchive:
            return "未识别到壁纸描述符，请确认文件为 .tendies 格式。"
        case .noDescriptors:
            return "该压缩包内没有可应用的壁纸描述符。"
        case .extractFailed(let m):
            return "解压失败：\(m)"
        case .persistFailed(let m):
            return "保存失败：\(m)"
        }
    }
}

/// 负责解析 .tendies 壁纸包并准备 PosterBoard 描述符。
final class WallpaperHandler {

    private let fm = FileManager.default

    /// 壁纸包持久化根目录（Documents/Wallpapers）。
    static var wallpapersFolder: URL {
        BackupPaths.documentsDirectory().appendingPathComponent("Wallpapers", isDirectory: true)
    }

    /// 从 .tendies 文件创建壁纸包对象，并将描述符持久化到沙盒。
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

            // 有时文件会多嵌套一层，先找到真正的根目录。
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

            // 检查 1：目录名直接包含 descriptor / ordered-descriptor / video-descriptor。
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

            // 检查 2：嵌套在 container 目录下，需要匹配三种目标路径之一。
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

    /// 随机化描述符中的 identifier，避免与系统已有壁纸冲突。
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

    /// 枚举 /var/mobile/Containers/Data/Application，查找 PosterBoard 容器路径。
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
        path.withCString { cPath in
            guard let list = bad_query_list(UnsafeMutablePointer(mutating: cPath), 100000) else {
                return []
            }
            defer { free(list) }
            return String(cString: list).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }
}
