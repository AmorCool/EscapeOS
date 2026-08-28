//
//  DialerThemeManager.swift
//  EscapeOS
//
//  拨号器主题引擎（移植自 Ketamine 的 Passcode / Customization 板块）。
//
//  原理（三层）：
//
//  1. 电话 App（com.apple.mobilephone）通过私有框架 TelephonyUI 渲染拨号键盘
//     按钮（0–9、*、#、拨号键、删除键），渲染结果以 PNG 形式缓存到自己的容器里：
//         /var/mobile/Containers/Data/Application/<UUID>/Library/Caches/TelephonyUI-<版本>/
//     这个缓存不是每次启动重算的 —— iOS 启动时命中缓存就直接读，所以替换 PNG
//     就等于换了键盘外观，重启电话 App 即可生效（不需要 respring）。
//
//  2. 该路径位于电话 App 的沙盒容器内，EscapeOS 默认无权访问。这里通过
//     `SandboxEscape`（bad_query 路径遍历）让 containermanagerd 代为签发目标
//     路径的 sandbox extension，之后 FileManager 即可正常读写。所有跨容器读写
//     必须在持有 handle 期间完成。
//
//  3. 同一资源在各语言下各有一份（en-xxx.png / de-xxx.png / zh-xxx.png …），
//     内容像素完全相同，仅仅是文件名不同。因此匹配时剥掉第一个 "-" 之前的前缀，
//     用一个 key 覆盖全部语言副本，换一次主题所有语言都生效。
//
//  移植时相对 Ketamine 的改动：
//  - 解压/打包改用 EscapeOS 自带的 ZipReader / ZipWriter，不引入 ZIPFoundation。
//  - 沙盒句柄统一走 SandboxEscape（含 LiveContainer 容器扩展的 sentinel 分支）。
//  - 缓存目录名（TelephonyUI-<版本>）不再硬编码为 -10，扫描前缀并取版本号最高者，
//    避免 iOS 大版本升级后目录名变化导致整个功能失效。
//

import Foundation

// MARK: - 错误

enum DialerThemeError: LocalizedError {
    case containerNotFound
    case cacheDirectoryNotFound
    case sandboxFailed(String)
    case notAnArchiveOrPNG
    case noPNGsInPackage
    case noMatchingAssets(liveNames: [String], packageKeys: [String])
    case noBackup
    case noImagesToExport
    case archiveWriteFailed

    var errorDescription: String? {
        switch self {
        case .containerNotFound:
            return "未能定位电话 App 的数据容器。请确认设备已激活电话功能，且 bad_query 可用（iOS 26.0–26.6.1）。"
        case .cacheDirectoryNotFound:
            return "容器里没有找到 TelephonyUI 缓存目录，系统可能尚未生成拨号键盘缓存。请打开一次电话 App 的拨号键盘后重试。"
        case .sandboxFailed(let detail):
            return "沙盒扩展签发失败：\(detail)"
        case .notAnArchiveOrPNG:
            return "所选文件既不是 .passthm/.zip 主题包，也不是 PNG 图片。"
        case .noPNGsInPackage:
            return "主题包里没有找到任何 PNG 图片。"
        case .noMatchingAssets(let liveNames, let packageKeys):
            let live = liveNames.prefix(6).joined(separator: ", ")
            let keys = packageKeys.prefix(6).joined(separator: ", ")
            return "主题包里的图片与当前主题没有任何同名项。设备上的文件：\(live)。包内（去掉语言前缀后）：\(keys)。"
        case .noBackup:
            return "还没有备份过原生主题。首次应用主题时会自动备份。"
        case .noImagesToExport:
            return "没有可导出的拨号键盘图片。"
        case .archiveWriteFailed:
            return "创建导出压缩包失败。"
        }
    }
}

// MARK: - 状态快照

struct DialerThemeStatus {
    /// 电话 App 容器绝对路径。
    let containerPath: String
    /// 缓存目录名（TelephonyUI-<版本>）。
    let cacheDirectoryName: String
    /// 缓存目录里的 PNG 数量。
    let pngCount: Int
    /// 是否已备份过原生主题。
    let hasBackup: Bool

    var cachePath: String {
        (containerPath as NSString).appendingPathComponent("Library/Caches/\(cacheDirectoryName)")
    }
}

// MARK: - 引擎

final class DialerThemeManager {

    static let shared = DialerThemeManager()

    private init() {}

    private let fm = FileManager.default
    private let escape = SandboxEscape()

    private static let containersRoot = "/var/mobile/Containers/Data/Application"
    private static let cachePrefix = "TelephonyUI-"

    private var documentsDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 原生主题的一次性快照，只写一次、永不覆盖。
    private var backupDirectory: URL {
        documentsDirectory.appendingPathComponent("DialerThemeBackup", isDirectory: true)
    }

    private var exportDirectory: URL {
        documentsDirectory.appendingPathComponent("ExportedDialerThemes", isDirectory: true)
    }

    var hasBackup: Bool {
        ((try? fm.contentsOfDirectory(atPath: backupDirectory.path)) ?? []).isEmpty == false
    }

    // MARK: - 文件名匹配

    /// 去掉语言前缀后的匹配键：取第一个 "-" 之后的部分。
    /// 没有 "-" 的文件名表示不区分语言，直接用全名。
    static func matchKey(for filename: String) -> String {
        let lowercased = filename.lowercased()
        guard let dash = lowercased.firstIndex(of: "-") else { return lowercased }
        return String(lowercased[lowercased.index(after: dash)...])
    }

    // MARK: - 目录枚举

    /// 列出目录下的一级条目名。
    ///
    /// 优先用 FileManager（调用前应已持有该路径的沙盒扩展）；返回空时回退
    /// `bad_query_list`（fsgetpath inode 扫描）— LiveContainer 访客沙盒下
    /// FileManager 列目录会被裁剪，实测不可信。
    private func entryNames(at directory: String, maxInode: Int64 = 200_000) -> [String] {
        let fmNames = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        if !fmNames.isEmpty { return fmNames }

        return Self.listViaBadQuery(directory, maxInode: maxInode)
            .map { ($0 as NSString).lastPathComponent }
    }

    /// 用 bad_query_list 枚举目录（返回完整路径）。
    static func listViaBadQuery(_ path: String, maxInode: Int64 = 200_000) -> [String] {
        path.withCString { cPath in
            guard let list = bad_query_list(UnsafeMutablePointer(mutating: cPath), maxInode) else {
                return []
            }
            defer { free(list) }
            return String(cString: list)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
    }

    // MARK: - 容器发现

    /// 找到电话 App 的数据容器，并定位其中的 TelephonyUI 缓存目录。
    ///
    /// 策略：枚举 /var/mobile/Containers/Data/Application 下的每个容器，对其
    /// `Library/Caches` 目录签发沙盒扩展后列目录，命中 `TelephonyUI-` 前缀即返回。
    /// 逐个容器签发是必要的 —— 容器内路径对 FileManager 不可见，必须先拿到扩展。
    func discoverStatus() throws -> DialerThemeStatus {
        let containers = entryNames(at: Self.containersRoot)
        guard !containers.isEmpty else { throw DialerThemeError.containerNotFound }

        for name in containers {
            let containerPath = (Self.containersRoot as NSString).appendingPathComponent(name)
            let cachesPath = (containerPath as NSString).appendingPathComponent("Library/Caches")

            // 签发失败说明这个容器我们碰不到，直接跳过（常见：-4 内核拒绝）。
            guard let handle = try? escape.consume(path: cachesPath, create: true) else { continue }
            defer { escape.release(handle) }

            let names = entryNames(at: cachesPath, maxInode: 20_000)
            guard let cacheDirectoryName = Self.preferredCacheDirectory(in: names) else { continue }

            let cachePath = (cachesPath as NSString).appendingPathComponent(cacheDirectoryName)
            let pngCount = entryNames(at: cachePath, maxInode: 20_000)
                .filter { $0.lowercased().hasSuffix(".png") }
                .count

            return DialerThemeStatus(
                containerPath: containerPath,
                cacheDirectoryName: cacheDirectoryName,
                pngCount: pngCount,
                hasBackup: hasBackup
            )
        }

        throw DialerThemeError.containerNotFound
    }

    /// 在若干 `TelephonyUI-<n>` 目录名中取版本号最高者（Ketamine 硬编码 -10，
    /// 这里改为扫描，避免 iOS 升级后目录名变化导致功能整体失效）。
    private static func preferredCacheDirectory(in names: [String]) -> String? {
        let candidates = names.filter { $0.hasPrefix(cachePrefix) }
        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { lhs, rhs in
            version(of: lhs) < version(of: rhs)
        }.last
    }

    private static func version(of name: String) -> Int {
        Int(name.dropFirst(cachePrefix.count)) ?? 0
    }

    // MARK: - 备份

    /// 首次调用时把当前缓存目录的全部 PNG 复制到 App 自己的 Documents，
    /// 之后不再覆盖 —— 与 MobileGestalt 备份同样的一次性快照策略。
    @discardableResult
    func ensureBackup(cachePath: String) throws -> Int {
        if hasBackup { return 0 }

        let handle = try consumeOrThrow(cachePath)
        defer { escape.release(handle) }

        let names = entryNames(at: cachePath, maxInode: 200_000)
            .filter { $0.lowercased().hasSuffix(".png") }

        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var saved = 0
        for name in names {
            let source = (cachePath as NSString).appendingPathComponent(name)
            let destination = backupDirectory.appendingPathComponent(name).path
            if fm.fileExists(atPath: destination) {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: source, toPath: destination)
            saved += 1
        }
        return saved
    }

    // MARK: - 应用主题

    /// 用主题包（.passthm / .zip）或散装 PNG 覆盖缓存目录里的同名图片。
    /// - Parameter sources: 一个主题包，或若干张 PNG（用户可直接多选图片，不必打包）。
    /// - Returns: 被替换的文件数。
    @discardableResult
    func apply(sources: [URL], cachePath: String) throws -> Int {
        // 1. 收集包内 PNG：按「去掉语言前缀」的 key 索引，同一 key 只取第一张。
        var packageByKey: [String: Data] = [:]
        var packageKeys: [String] = []
        for url in sources {
            let data = try Data(contentsOf: url)
            if Self.isZip(data) {
                let reader = try ZipReader(data: data)
                for name in reader.entryNames() {
                    guard name.lowercased().hasSuffix(".png") else { continue }
                    let payload = try reader.readEntry(named: name)
                    let key = Self.matchKey(for: (name as NSString).lastPathComponent)
                    if packageByKey[key] == nil {
                        packageByKey[key] = payload
                        packageKeys.append(key)
                    }
                }
            } else if url.pathExtension.lowercased() == "png" {
                let key = Self.matchKey(for: url.lastPathComponent)
                if packageByKey[key] == nil {
                    packageByKey[key] = data
                    packageKeys.append(key)
                }
            } else {
                throw DialerThemeError.notAnArchiveOrPNG
            }
        }

        guard !packageByKey.isEmpty else { throw DialerThemeError.noPNGsInPackage }

        // 2. 先备份原生主题（只做一次）。
        try ensureBackup(cachePath: cachePath)

        // 3. 持有缓存目录的沙盒扩展，逐个替换同名文件。
        let handle = try consumeOrThrow(cachePath)
        defer { escape.release(handle) }

        let liveNames = entryNames(at: cachePath, maxInode: 200_000)
            .filter { $0.lowercased().hasSuffix(".png") }

        var replaced = 0
        for name in liveNames {
            guard let payload = packageByKey[Self.matchKey(for: name)] else { continue }
            let destination = (cachePath as NSString).appendingPathComponent(name)
            try payload.write(to: URL(fileURLWithPath: destination), options: [.atomic])
            replaced += 1
        }

        guard replaced > 0 else {
            throw DialerThemeError.noMatchingAssets(
                liveNames: liveNames.sorted(),
                packageKeys: packageKeys.sorted()
            )
        }
        return replaced
    }

    // MARK: - 恢复原生主题

    @discardableResult
    func restoreOriginal(cachePath: String) throws -> Int {
        guard hasBackup else { throw DialerThemeError.noBackup }

        let handle = try consumeOrThrow(cachePath)
        defer { escape.release(handle) }

        let names = try fm.contentsOfDirectory(atPath: backupDirectory.path)
        var restored = 0
        for name in names {
            let source = backupDirectory.appendingPathComponent(name).path
            let destination = (cachePath as NSString).appendingPathComponent(name)
            try Data(contentsOf: URL(fileURLWithPath: source))
                .write(to: URL(fileURLWithPath: destination), options: [.atomic])
            restored += 1
        }
        return restored
    }

    // MARK: - 导出当前主题

    /// 把当前主题打包成 zip（有备份就用备份，否则直接读缓存），作为制作自定义主题的素材。
    /// 纯读操作，不会产生备份副作用。
    func exportCurrentTheme(cachePath: String) throws -> URL {
        let sourceNames: [String]
        let sourceDirectory: String

        if hasBackup {
            sourceDirectory = backupDirectory.path
            sourceNames = ((try? fm.contentsOfDirectory(atPath: backupDirectory.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".png") }
        } else {
            sourceDirectory = cachePath
            let handle = try consumeOrThrow(cachePath)
            defer { escape.release(handle) }
            sourceNames = entryNames(at: cachePath, maxInode: 200_000)
                .filter { $0.lowercased().hasSuffix(".png") }
        }

        guard !sourceNames.isEmpty else { throw DialerThemeError.noImagesToExport }

        if fm.fileExists(atPath: exportDirectory.path) {
            try fm.removeItem(at: exportDirectory)
        }
        try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let zipURL = exportDirectory.appendingPathComponent("DialerTheme.zip")
        let writer = ZipWriter()
        try writer.begin(at: zipURL)
        for name in sourceNames {
            let data = try Data(contentsOf: URL(fileURLWithPath: (sourceDirectory as NSString).appendingPathComponent(name)))
            try writer.addFile(name: name, data: data)
        }
        try writer.finish()
        return zipURL
    }

    // MARK: - 内部工具

    private func consumeOrThrow(_ path: String) throws -> SandboxEscape.Handle {
        do {
            return try escape.consume(path: path, create: true)
        } catch {
            let detail = (error as? SandboxEscapeError)?.errorDescription ?? error.localizedDescription
            throw DialerThemeError.sandboxFailed(detail)
        }
    }

    /// ZIP 文件头魔数 "PK"。.passthm 只是换了个扩展名的 zip。
    private static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B
    }
}
