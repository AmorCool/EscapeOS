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
    /// v0.3.378：下载时的**来源直链**（这个包当初是从哪个 URL 下下来的，例如爱思的
    /// `https://d-app6.i4.cn/soft/....ipa`）。只有走直链下载的条目才有 —— Apple ID 通道没有公开直链。
    ///
    /// **v0.3.386 起语义归位**：它是操作面板「**提取下载链接**」的取值（纯读台账）。
    /// 面板上的「**复制下载链接**」另取一处 —— 读包内 `iTunesMetadata.plist` 的 `itemId`
    /// 拼 App Store 商店链接。**两者严格互斥、不互相回落**，别再把它们混成一个来源。
    var sourceURL: String? = nil
    /// v0.3.391：**App Store 商品号（`trackId`）** —— 拼「商店链接」用。
    ///
    /// 为什么记这个而不是读包内的 `iTunesMetadata.itemId`：
    /// **重签工具会把 `iTunesMetadata.plist` 删掉**（本机 `AssppPro-4.2.5.ipa` 与 `NBPro_v3.6.2.ipa`
    /// 实测都不含该文件），所以读包这条路对重签包必然失败；
    /// 而**下载的那一刻我们本来就拿着商品号**（`AppStoreItem.id` 就是 `trackId`）。
    /// 只有 AppleID 通道有（爱思 / 直链来源没有 App Store 商品号）。
    var storeItemId: String? = nil
    var packageName: String?      // 包内 Info.plist 的显示名
    var isEncrypted: Bool?
    var hasSINF: Bool?
    /// v0.3.568：包内 sinf 的**结构**是否自洽（nil = 未检测 / 包内无 sinf）。
    ///
    /// 为什么单靠 `hasSINF` 不够：`extractSINF` **只判存在性、不判有效性** ——
    /// 一个写坏的 sinf（例如 hex-as-base64 的 1.5 倍垃圾）也会让 `hasSINF == true`。
    /// 有了这一位，标签才能把「带 sinf」「sinf 写坏了」「真的没有」三件事分开。
    var sinfStructurallyValid: Bool? = nil
    var lastInstalledAt: Date?
    /// v0.3.413（D8 修法 B）：**下载时拿到的 sinf**（base64 的标准 `.sinf` 容器）。
    ///
    /// 为什么必须落台账：牛蛙源的加密包只有把 sinf 写回包内 `SC_Info/` 才能过
    /// FairPlay 验证。而 sinf 以前只活在内存里的 `Job.sinfBase64` ——
    /// 于是「下载管理 → 重装」（走 `installLocal`，读不到内存 Job）必然失败：
    /// 真机报「该 IPA 是加密包，但缺少 SC_Info/*.sinf」。
    ///
    /// 落盘之后，**重装时能从这里读回来写进包内**，不需要重下。
    /// 只有牛蛙源有；爱思源（服务端已签名）与 AppleID 通道（`SignatureInjector` 自己写回）为 nil。
    var sinfBase64: String? = nil

    var id: String { fileName }

    /// 界面主标题：优先商店名 → 包内显示名 → 文件名
    var title: String {
        if let d = displayName, !d.isEmpty { return d }
        if let p = packageName, !p.isEmpty { return p }
        return (fileName as NSString).deletingPathExtension
    }

    var sizeText: String { IPADownloadLibrary.sizeText(sizeBytes) }

    /// 加密状态文案（加密包靠包内 sinf 安装）
    ///
    /// v0.3.568：加密包再细分一层 —— 「缺 sinf」（真没有，装不上）与
    /// 「sinf 异常」（有、但结构写坏了，同样装不上/装后崩）是**两件不同的处置**，
    /// 不能再都显示成「缺 sinf」。
    var kindText: String {
        switch isEncrypted {
        case true:
            if hasSINF != true { return "加密包 · 缺 sinf" }
            return sinfStructurallyValid == false ? "加密包 · sinf 异常" : "加密包 · 带 sinf"
        case false: return "明文包"
        default: return "未检测"
        }
    }
}

/// 下载库（单例；只在主线程使用）
///
/// `@unchecked Sendable`：本类**没有任何可变实例状态**——唯一的持久化状态是磁盘上的
/// `Documents/ipa_downloads.json` 台账（每次调用现场读、现场写），实例本身只是一个
/// 无状态门面，因此跨隔离域共享引用是安全的。
final class IPADownloadLibrary: @unchecked Sendable {

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

    /// 本地绝对路径（按文件名）—— v0.3.314：设备瘦身的「重装」只需要文件名，
    /// 不必为了拿路径去拼一个假的 item.
    func path(forFileName name: String) -> String {
        directory.appendingPathComponent(name).path
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
            }
            // v0.3.568：加密包的 `hasSINF` **必须现算** —— 台账里的值是个「下载瞬间」的旧快照。
            //
            // 为什么它会旧：`IPADownloadCenter.handle` 是**先** `record()`（此刻包内还没写回 sinf）
            // **后**才异步 `PackageSINFWriter.writeIfNeeded()` 写回包内（两步紧邻，顺序就是如此）。
            // 于是每个走写回链路的加密包（NB / 牛蛙源）都被记成 `false`，而写回成功后
            // **没有任何代码把它改回 true** ⇒ 下载管理永久显示「缺 sinf」（假阳性）。
            //
            // 性能取舍：只在「还不是 true」时开包（修正后即持久化，后续不再开）；
            // 明文包的标签不看 `hasSINF`，直接跳过。真正缺 sinf 的包会每次重开 ——
            // 但这类包本就少见（本机 20 条里 2 条），且它们正需要被标出来。
            if index[i].isEncrypted == true, index[i].hasSINF != true {
                let sinf = IPAPackageInspector.extractSINF(ipaPath: path(for: index[i]))
                index[i].hasSINF = sinf != nil
                index[i].sinfStructurallyValid = sinf.map {
                    PackageSINFWriter.isStructurallyValidSinf($0)
                }
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
                source: String,
                sourceURL: String? = nil,
                storeItemId: String? = nil,
                sinfBase64: String? = nil) {
        let name = fileURL.lastPathComponent
        var index = loadIndex()
        index.removeAll { $0.fileName == name }
        var item = makeItem(fileName: name)
        item.displayName = displayName
        item.bundleId = bundleId ?? item.bundleId
        item.version = version ?? item.version
        item.iconURL = iconURL
        item.source = source
        // 只在拿到真直链时才覆盖，避免 Apple ID 通道把已有直链抹掉
        if let sourceURL, !sourceURL.isEmpty { item.sourceURL = sourceURL }
        // 同理：没给商品号就保留台账里已有的（别把它抹成 nil）
        if let storeItemId, !storeItemId.isEmpty { item.storeItemId = storeItemId }
        // v0.3.413（D8 B）：sinf 也落台账 —— 同样只在真拿到时覆盖，别把已有的抹成 nil。
        // 这是「重装不用重下」的关键：`installLocal` 会从这里读回来写进包内。
        if let sinfBase64, !sinfBase64.isEmpty { item.sinfBase64 = sinfBase64 }
        index.append(item)
        saveIndex(index)
    }

    /// v0.3.413（D8 修法 B）：读回该包**下载时拿到的 sinf**（base64）。没有则 `nil`。
    ///
    /// 用途：`IPADownloadCenter.installLocal` 在安装前把它写回包内 `SC_Info/`，
    /// 让「下载管理 → 重装」也能过 FairPlay 验证（以前必然报「缺少 SC_Info/*.sinf」）。
    func sinf(forFileName fileName: String) -> String? {
        loadIndex().first { $0.fileName == fileName }?.sinfBase64
    }

    /// v0.3.568：**sinf 写回包内成功后**，把台账的 `hasSINF` / `sinfStructurallyValid` 定正。
    ///
    /// 为什么需要：`record()` 是在「写回之前」记的（见 `IPADownloadCenter.handle`），
    /// 所以新下载的加密包一开始必然是 `hasSINF == false`。写完不更新，标签就会一直
    /// 显示「缺 sinf」（本仓实测的假阳性来源）。`items()` 的现算能兜住历史记录，
    /// 这里让**新下载**当场就正确、不必等下一次重算。
    func markSinf(fileName: String, structurallyValid: Bool) {
        var index = loadIndex()
        guard let i = index.firstIndex(where: { $0.fileName == fileName }) else { return }
        // 幂等：值没变就不写盘
        guard index[i].hasSINF != true || index[i].sinfStructurallyValid != structurallyValid else { return }
        index[i].hasSINF = true
        index[i].sinfStructurallyValid = structurallyValid
        saveIndex(index)
    }

    /// 安装成功后打时间戳
    func markInstalled(fileName: String) {
        var index = loadIndex()
        guard let i = index.firstIndex(where: { $0.fileName == fileName }) else { return }
        index[i].lastInstalledAt = Date()
        saveIndex(index)
    }

    /// v0.3.360：把查到的图标地址**落盘**。
    ///
    /// 为什么需要：真机 `ipa_downloads.json` 里 5 条记录**都没有 `iconURL`** ——
    /// 「本地」来源的条目大多由 `makeItem`（磁盘扫描）现场构造，那条路径固定传 `iconURL: nil`，
    /// 于是列表永远只能显示占位图。界面侧会按 bundleId 反查图标补齐，
    /// **这里把结果持久化**，避免每次进页面都重新发一轮 lookup 请求（条目多了会变成请求风暴）。
    func updateIconURL(fileName: String, url: String) {
        guard !url.isEmpty else { return }
        var index = loadIndex()
        guard let i = index.firstIndex(where: { $0.fileName == fileName }) else { return }
        guard index[i].iconURL != url else { return }
        index[i].iconURL = url
        saveIndex(index)
    }

    /// v0.3.378：把**来源直链**回填进台账（供操作面板「提取下载链接」用）。
    ///
    /// 补齐方式与 `updateIconURL` 同源：下载中心的任务里记着 `remoteURL`，
    /// 界面侧把「已完成且有直链」的任务回填到这里并落盘，于是历史记录里也有链接可复制。
    func updateSourceURL(fileName: String, url: String) {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        var index = loadIndex()
        guard let i = index.firstIndex(where: { $0.fileName == fileName }) else { return }
        guard index[i].sourceURL != link else { return }
        index[i].sourceURL = link
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

    /// 删除单个包（按文件名）—— 下载中心取消任务时用
    func remove(fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        var index = loadIndex()
        index.removeAll { $0.fileName == fileName }
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
        // 读一次 sinf，同时定「有没有」与「结构对不对」（避免开两次包）
        let sinf = IPAPackageInspector.extractSINF(ipaPath: url.path)
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
                               hasSINF: sinf != nil,
                               sinfStructurallyValid: sinf.map {
                                   PackageSINFWriter.isStructurallyValidSinf($0)
                               },
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
