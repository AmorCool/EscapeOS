import Foundation

/// v0.3.305：IPA 下载库 —— 已下载安装包的本地台账.
///
/// 目录沿用 `Documents/AppStoreDownloads`（下载落地点，文件 App 可见），
/// 旁边放一份 `Documents/ipa_downloads.json` 索引记录「下载时知道的元信息」
/// （应用名/来源/图标地址），这些信息只有在商店列表里才有，包本身读不出来。
///
/// 索引与磁盘**双向对齐**：
/// · 磁盘上有、索引里没有（例如早期版本下载的包）→ 现场用 `IPAPackageInspector` 读包补登记；
/// · 索引里有、磁盘上已删 → 从索引剔除。所以任何来源放进该目录的 IPA 都会出现在下载管理里。
struct IPADownloadItem: Codable, Identifiable, Hashable {
    var fileName: String          // 唯一键，也是磁盘文件名
    var displayName: String?      // 商店里的应用名（下载时记录）
    var bundleId: String?
    var version: String?
    var sizeBytes: Int64
    var downloadedAt: Date
    var iconURL: String?
    var source: String            // 「爱思免登录」/「App Store」…
    var packageName: String?      // 包内 Info.plist 的显示名
    var isEncrypted: Bool?
    var hasSINF: Bool?
    var lastInstalledAt: Date?

    var id: String { fileName }

    /// 界面主标题：优先商店名 → 包内显示名 → 文件名
    var title: String {
        if let d = displayName, !d.isEmpty { return d }
        if let p = packageName, !p.isEmpty { return p }
        return (fileName as NSString).deletingPathExtension
    }

    var sizeText: String { IPADownloadLibrary.sizeText(sizeBytes) }

    /// 加密状态文案（加密包靠包内 sinf 安装）
    var kindText: String {
        switch isEncrypted {
        case true: return hasSINF == true ? "加密包 · 带 sinf" : "加密包 · 缺 sinf"
        case false: return "明文包"
        default: return "未检测"
        }
    }
}

/// 下载库（单例；只在主线程使用）
final class IPADownloadLibrary {

    static let shared = IPADownloadLibrary()
    private init() {}

    /// 下载目录：`Documents/AppStoreDownloads`
    var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AppStoreDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var indexURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ipa_downloads.json")
    }

    /// 本地绝对路径
    func path(for item: IPADownloadItem) -> String {
        directory.appendingPathComponent(item.fileName).path
    }

    // MARK: - 读取（索引 ∪ 磁盘）

    /// 列出全部已下载 IPA（按下载时间倒序）.
    /// 会顺带做一次索引/磁盘对齐，所以新增/删除文件都能反映出来。
    func items() -> [IPADownloadItem] {
        var index = loadIndex()
        let onDisk = diskFiles()

        // 1) 磁盘上新增的（索引里没有）→ 读包补登记
        for name in onDisk where !index.contains(where: { $0.fileName == name }) {
            index.append(makeItem(fileName: name))
        }
        // 2) 索引里有、磁盘上没了的 → 剔除
        index.removeAll { !onDisk.contains($0.fileName) }
        // 3) 顺手补齐容量/包信息（索引可能来自更早版本，字段不全）
        for i in index.indices {
            if index[i].sizeBytes <= 0 { index[i].sizeBytes = fileSize(index[i].fileName) }
            if index[i].packageName == nil || index[i].isEncrypted == nil {
                let ins = IPAPackageInspector.inspect(ipaPath: path(for: index[i]))
                index[i].packageName = index[i].packageName ?? ins?.displayName
                index[i].bundleId = index[i].bundleId ?? ins?.bundleIdentifier
                index[i].version = index[i].version ?? ins?.bundleVersion
                index[i].isEncrypted = ins?.isEncrypted ?? index[i].isEncrypted
                index[i].hasSINF = IPAPackageInspector.extractSINF(ipaPath: path(for: index[i])) != nil
            }
        }
        saveIndex(index)
        return index.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    var totalBytes: Int64 {
        items().reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    /// 下载完成后登记（同一个应用重复下载会覆盖旧记录的元信息）.
    func record(fileURL: URL,
                displayName: String?,
                bundleId: String?,
                version: String?,
                iconURL: String?,
                source: String) {
        let name = fileURL.lastPathComponent
        var index = loadIndex()
        index.removeAll { $0.fileName == name }
        var item = makeItem(fileName: name)
        item.displayName = displayName
        item.bundleId = bundleId ?? item.bundleId
        item.version = version ?? item.version
        item.iconURL = iconURL
        item.source = source
        index.append(item)
        saveIndex(index)
    }

    /// 安装成功后打时间戳
    func markInstalled(fileName: String) {
        var index = loadIndex()
        guard let i = index.firstIndex(where: { $0.fileName == fileName }) else { return }
        index[i].lastInstalledAt = Date()
        saveIndex(index)
    }

    // MARK: - 删除

    /// 删除一个下载包（文件 + 索引）
    func remove(_ item: IPADownloadItem) {
        try? FileManager.default.removeItem(atPath: path(for: item))
        var index = loadIndex()
        index.removeAll { $0.fileName == item.fileName }
        saveIndex(index)
    }

    /// 批量删除（配合列表编辑模式）
    func remove(fileNames: Set<String>) {
        for name in fileNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        var index = loadIndex()
        index.removeAll { fileNames.contains($0.fileName) }
        saveIndex(index)
    }

    // MARK: - 内部

    private func diskFiles() -> Set<String> {
        let list = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(list.filter { $0.lowercased().hasSuffix(".ipa") })
    }

    private func fileSize(_ name: String) -> Int64 {
        let p = directory.appendingPathComponent(name).path
        let attrs = try? FileManager.default.attributesOfItem(atPath: p)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 从磁盘文件现场构造条目（读包拿包内信息）
    private func makeItem(fileName: String) -> IPADownloadItem {
        let url = directory.appendingPathComponent(fileName)
        let ins = IPAPackageInspector.inspect(ipaPath: url.path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)
            ?? Date()
        return IPADownloadItem(fileName: fileName,
                               displayName: nil,
                               bundleId: ins?.bundleIdentifier,
                               version: ins?.bundleVersion,
                               sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                               downloadedAt: created,
                               iconURL: nil,
                               source: "本地",
                               packageName: ins?.displayName,
                               isEncrypted: ins?.isEncrypted,
                               hasSINF: IPAPackageInspector.extractSINF(ipaPath: url.path) != nil,
                               lastInstalledAt: nil)
    }

    private func loadIndex() -> [IPADownloadItem] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let dec = JSONDecoder()
        // 与 saveIndex 的 .iso8601 必须成对，否则解码日期失败整份台账读不出来
        dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([IPADownloadItem].self, from: data) else { return [] }
        return list
    }

    private func saveIndex(_ list: [IPADownloadItem]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(list) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 字节数 → 可读文本
    static func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
