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
    /// 电话 App 的 bundle id（Ketamine 用它在容器 metadata 里精确匹配）。
    private static let mobilePhoneBundleId = "com.apple.mobilephone"
    /// containermanager 在每个容器根放的元数据文件，内含 MCMMetadataIdentifier。
    private static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"

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

    /// 删除已有备份。容器路径变化时调用：旧备份可能来自错误的容器，
    /// 继续使用会把错容器的原图写进新容器。
    func resetBackup() {
        try? fm.removeItem(at: backupDirectory)
    }

    // MARK: - 文件名匹配

    /// 去掉语言前缀后的匹配键：取第一个 "-" 之后的部分。
    /// 没有 "-" 的文件名表示不区分语言，直接用全名。
    ///
    /// 这是 Ketamine 原版逻辑，对标准 locale 前缀主题包（如 en-lock-mask.png / de-lock-mask.png）
    /// 完全适用：两者都会 key 到 lock-mask.png。
    static func matchKey(for filename: String) -> String {
        let lowercased = filename.lowercased()
        guard let dash = lowercased.firstIndex(of: "-") else { return lowercased }
        return String(lowercased[lowercased.index(after: dash)...])
    }

    /// 资源名 key：去掉第一个连续 dash 组及之前的所有内容，再去掉扩展名和
    /// 末尾的 "-bold"（设备缓存里常见，如 other-0---mask-bold.png）。
    ///
    /// 某些主题包不是用标准 locale 前缀，而是用 `#---mask.png`、`*---white.png`
    /// 这种「前缀 + 多个 dash + 资源名」的格式。对这类包，用 resourceKey 可以匹配到
    /// 设备上的 `other-0---mask-bold.png` 等资源。
    static func resourceKey(for filename: String) -> String {
        let lowercased = filename.lowercased()
        // 匹配第一个连续 dash 组：优先两个及以上 "--"，否则单个 "-"。
        guard let range = lowercased.range(of: "--+", options: .regularExpression)
                ?? lowercased.range(of: "-", options: .regularExpression) else {
            return (lowercased as NSString).deletingPathExtension
        }
        let afterDash = String(lowercased[range.upperBound...])
        let withoutExt = (afterDash as NSString).deletingPathExtension
        // 设备文件名常见 `-bold` 后缀（ bold / white 两种变体），主题包通常只提供一种，
        // 匹配时把 `-bold` 剥掉，让包内的 mask.png 能同时替换 mask-bold.png / mask.png。
        if withoutExt.hasSuffix("-bold") {
            return String(withoutExt.dropLast(5))
        }
        return withoutExt
    }

    /// 同时生成两种 key：标准 locale key 与资源名 key。
    static func candidateKeys(for filename: String) -> [String] {
        let standard = matchKey(for: filename)
        let resource = resourceKey(for: filename)
        if standard == resource { return [standard] }
        return [standard, resource]
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
    /// 策略（对齐 Ketamine 原版）：
    /// 1. 主路径：枚举容器根，读每个容器的 `MCMMetadataIdentifier`，
    ///    **精确匹配 com.apple.mobilephone**，再定位其 TelephonyUI 缓存。
    ///    只凭「存在 TelephonyUI-* 目录」判断可能找错容器（其他 App 也可能带
    ///    该缓存），导致替换不生效 —— v0.2.94/95 实锤踩过。
    /// 2. 兜底：万一 metadata 读不到（bad_query 对个别路径失败），退回按
    ///    TelephonyUI-* 特征匹配，取第一个命中的容器。
    func discoverStatus() throws -> DialerThemeStatus {
        // 与 Ketamine 一致，搜多个容器根；电话 App 的数据容器在 Application 下。
        let roots = [Self.containersRoot]
        var fallbackStatus: DialerThemeStatus?
        var sawTelephonyCache = false

        for root in roots {
            let containers = entryNames(at: root)
            for name in containers {
                let containerPath = (root as NSString).appendingPathComponent(name)

                // 1) 精确匹配 bundle id（读取失败/不匹配就跳过，不消耗太多时间）。
                if let bundleId = readBundleId(fromContainerPath: containerPath) {
                    guard bundleId == Self.mobilePhoneBundleId else { continue }
                    // 容器找对了，但缓存目录可能还没生成（没打开过拨号键盘）。
                    guard let status = try? makeStatus(containerPath: containerPath) else {
                        throw DialerThemeError.cacheDirectoryNotFound
                    }
                    return status
                }

                // 2) metadata 读不到时记录 TelephonyUI 特征容器作为兜底。
                let cachesPath = (containerPath as NSString).appendingPathComponent("Library/Caches")
                guard let handle = try? escape.consume(path: cachesPath, create: true) else { continue }
                defer { escape.release(handle) }
                let names = entryNames(at: cachesPath, maxInode: 200_000)
                guard let cacheDirectoryName = Self.preferredCacheDirectory(in: names) else { continue }
                sawTelephonyCache = true
                if fallbackStatus == nil {
                    let cachePath = (cachesPath as NSString).appendingPathComponent(cacheDirectoryName)
                    let pngCount = entryNames(at: cachePath, maxInode: 200_000)
                        .filter { $0.lowercased().hasSuffix(".png") }
                        .count
                    fallbackStatus = DialerThemeStatus(
                        containerPath: containerPath,
                        cacheDirectoryName: cacheDirectoryName,
                        pngCount: pngCount,
                        hasBackup: hasBackup
                    )
                }
            }
        }

        if let fallbackStatus { return fallbackStatus }
        if sawTelephonyCache {
            // 有 TelephonyUI 缓存但没能验证 bundle id，无法确认是电话 App。
            throw DialerThemeError.containerNotFound
        }
        throw DialerThemeError.containerNotFound
    }

    /// 读容器根的 containermanager 元数据，返回 `MCMMetadataIdentifier`（即 bundle id）。
    /// 与 Ketamine 原版 BadQuery.readBundleId 一致：先试带点前缀的文件名，再试不带点的。
    private func readBundleId(fromContainerPath containerPath: String) -> String? {
        let primary = (containerPath as NSString).appendingPathComponent(Self.metadataFileName)
        if let id = readMetadataIdentifier(at: primary) { return id }
        let alt = (containerPath as NSString).appendingPathComponent("com.apple.mobile_container_manager.metadata.plist")
        return readMetadataIdentifier(at: alt)
    }

    private func readMetadataIdentifier(at path: String) -> String? {
        guard let handle = try? escape.consume(path: path, create: true) else { return nil }
        defer { escape.release(handle) }
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        return dict["MCMMetadataIdentifier"] as? String
    }

    /// 在已确认的电话容器里定位 TelephonyUI 缓存目录并统计 PNG 数量。
    private func makeStatus(containerPath: String) throws -> DialerThemeStatus {
        let cachesPath = (containerPath as NSString).appendingPathComponent("Library/Caches")
        let handle = try consumeOrThrow(cachesPath)
        defer { escape.release(handle) }

        let names = entryNames(at: cachesPath, maxInode: 200_000)
        guard let cacheDirectoryName = Self.preferredCacheDirectory(in: names) else {
            throw DialerThemeError.cacheDirectoryNotFound
        }

        let cachePath = (cachesPath as NSString).appendingPathComponent(cacheDirectoryName)
        let pngCount = entryNames(at: cachePath, maxInode: 200_000)
            .filter { $0.lowercased().hasSuffix(".png") }
            .count

        return DialerThemeStatus(
            containerPath: containerPath,
            cacheDirectoryName: cacheDirectoryName,
            pngCount: pngCount,
            hasBackup: hasBackup
        )
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

        let names = entryNames(at: cachePath, maxInode: 2_000_000)
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
        // 1. 收集包内 PNG：用「标准 locale key」和「资源名 key」两种索引，
        //    同一 key 只取第一张（先遇到的优先）。
        var packageByKey: [String: Data] = [:]
        var packageKeys: [String] = []
        for url in sources {
            let data = try Data(contentsOf: url)
            if Self.isZip(data) {
                let reader = try ZipReader(data: data)
                for name in reader.entryNames() {
                    guard name.lowercased().hasSuffix(".png") else { continue }
                    let payload = try reader.readEntry(named: name)
                    for key in Self.candidateKeys(for: (name as NSString).lastPathComponent) {
                        if packageByKey[key] == nil {
                            packageByKey[key] = payload
                            packageKeys.append(key)
                        }
                    }
                }
            } else if url.pathExtension.lowercased() == "png" {
                for key in Self.candidateKeys(for: url.lastPathComponent) {
                    if packageByKey[key] == nil {
                        packageByKey[key] = data
                        packageKeys.append(key)
                    }
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

        let liveNames = entryNames(at: cachePath, maxInode: 2_000_000)
            .filter { $0.lowercased().hasSuffix(".png") }

        var replaced = 0
        for name in liveNames {
            let liveKeys = Self.candidateKeys(for: name)
            guard let payload = liveKeys.compactMap({ packageByKey[$0] }).first else { continue }
            let destination = (cachePath as NSString).appendingPathComponent(name)
            try replaceFile(at: destination, with: payload)
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
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            try replaceFile(at: destination, with: data)
            restored += 1
        }
        return restored
    }

    // MARK: - 导出当前主题

    /// 把当前主题打包成 zip（有备份就用备份，否则直接读缓存），作为制作自定义主题的素材。
    /// 纯读操作，不会产生备份副作用。
    func exportCurrentTheme(cachePath: String) throws -> URL {
        // handle 必须提升到函数级作用域：defer 绑在 else 块上会在块结束时提前释放
        // 扩展，随后读取缓存文件时就拿不到权限（v0.2.94/95 实测「无权限」的根因）。
        var handle: SandboxEscape.Handle?
        defer {
            if let handle { escape.release(handle) }
        }

        let sourceNames: [String]
        let sourceDirectory: String

        if hasBackup {
            sourceDirectory = backupDirectory.path
            sourceNames = ((try? fm.contentsOfDirectory(atPath: backupDirectory.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".png") }
        } else {
            sourceDirectory = cachePath
            handle = try consumeOrThrow(cachePath)
            sourceNames = entryNames(at: cachePath, maxInode: 2_000_000)
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

    /// 覆盖目标文件：先把新内容写入临时文件，再「先删后拷」进缓存目录。
    /// 对齐 Ketamine 原版的 removeItem + copyItem 方式 —— 直接对沙盒扩展路径做
    /// 原子写（Data.write(atomic) = 写临时文件 + rename）在 LiveContainer 环境下
    /// 不可靠，rename 可能因文件系统/权限策略失败；而 copyItem 是壁纸功能验证过的路径。
    private func replaceFile(at destination: String, with payload: Data) throws {
        let tempURL = fm.temporaryDirectory
            .appendingPathComponent("dialer-theme-\(UUID().uuidString).png")
        try payload.write(to: tempURL)
        defer { try? fm.removeItem(at: tempURL) }

        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        try fm.copyItem(at: tempURL, to: URL(fileURLWithPath: destination))
    }

    /// ZIP 文件头魔数 "PK"。.passthm 只是换了个扩展名的 zip。
    private static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B
    }
}
