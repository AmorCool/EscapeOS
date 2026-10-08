import Foundation

/// v0.3.305：IPA 下载库 —— 已下载安装包的本地台账.
///
/// 目录沿用 `Documents/AppStoreDownloads`（下载落地点，文件 App 可见），
/// 旁边放一份 `Documents/ipa_downloads.json` 索引记录「下载时知道的元信息」
/// （应用名/来源/图标地址），这些信息只有在商店列表里才有，包本身读不出来。
///
/// 索引与磁盘**双向对齐**：
/// · 磁盘上有、索引里没有（例如早期版本下载的包）→ 现场用 `IPAPackageInspector` 读包补登记，
///   来源标记为「来源未知」（该目录只收下载产物；真·本地导入在 `Imports/`、不进本台账）；
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
    ///
    /// v0.3.570：再拆出**第四态** —— `sinfStructurallyValid == nil` 是「**未校验**」
    /// （旧台账没这一位、或 sinf 格式我们不认识），不能再和「已验为真」共用一个「带 sinf」。
    /// 「已校验」与「从未校验」必须能分辨，否则标签给出的确定性超过实际掌握。
    var kindText: String {
        switch isEncrypted {
        case true:
            if hasSINF != true { return "加密包 · 缺 sinf" }
            switch sinfStructurallyValid {
            case .some(false): return "加密包 · sinf 异常"
            case .some(true):  return "加密包 · 带 sinf"
            case nil:          return "加密包 · 带 sinf（未校验）"
            }
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

    /// 磁盘扫描现场构造条目时的**占位来源**（`makeItem`）.
    ///
    /// 为什么不能写「本地」：本库只扫 `Documents/AppStoreDownloads/`（下载落点），
    /// 真·本地导入走 `Documents/Imports/`，且明确**从不写本台账**（`ImportService` /
    /// `RepairService` 的契约：台账 = 「文件在 `AppStoreDownloads`、`fileName` 即磁盘文件名」）。
    /// 所以「盘上有、台账没有」的包**一律是下载产物**，只是当初没能登记
    /// （`record()` 未执行，例如 AppleID 通道下载成功后安装失败/超时）。
    /// 旧实现把它们写死成 `"本地"`，于是 AppleID 的孤儿包被误标成「本地导入」，
    /// 用户会把它当来路不明的包删掉。改用中性文案后，孤儿不再冒充任何具体来源。
    ///
    /// 注意：这不是一个真实来源，故**不进 `IPADownloadCenter.Source` 枚举**
    /// （加 case 属于另一个文件的范围）。`record()` 拿到真实来源时会覆盖它。
    private static let unrecordedSource = "来源未知"

    /// 旧版 `makeItem` 写死的误标来源（v0.3.5xx 起不再产生，仅在 `items()` 里回改历史值）.
    private static let legacyLocalSource = "本地"

    /// 删除结果 —— 让调用方能给**真实**反馈，而不是无条件报「已删除」。
    ///
    /// 为什么必须返回：删除是「文件 + 台账」两件事。台账只读（读失败加固）时**两件都不能做**，
    /// 调用方若照旧弹「已删除安装包」就是**假成功** —— 文件还在、列表也没变。
    enum RemoveResult: Equatable {
        /// 台账可写，删除已生效（文件若存在已移除，索引已更新）。
        case removed
        /// 台账没能完整读出（只读）—— **文件未删、索引未改**，本次删除被拒。
        case rejectedReadOnly
        /// 台账可写，但**文件删除失败**（被占用 / 权限），索引未改，条目仍原样保留。
        case fileRemovalFailed
    }

    /// 写被拒时给**用户可见**的反馈：日志不是反馈，用户改了却看不到变化会以为「点了没反应」。
    ///
    /// 与 `AppFavoritesStore` / `AppStoreDownloadStore` 的同类方法一致（文案点明原因与后果），
    /// 但多一层**会话内去重**：IPA 台账的写有大量**后台/自动**触发（列表刷新时的图标回填、
    /// 直链回填、sinf 标记…），台账坏一次后每次列表都会走到写被拒 —— 若每次都弹就会刷屏。
    /// 因此同一会话内只提示**一次**，用户已经被明确告知过「台账坏了、改动没保存」。
    ///
    /// `prefix`：动作前缀（删除类传「未删除安装包」，其余为 nil）。加前缀是为了让文案说清
    /// **这次想做的事没做成**，而不是只丢一句「失败」。
    private func notifyWriteRejected(_ userReason: String?, prefix: String? = nil) {
        let reason = userReason ?? "下载台账文件损坏"
        let text = prefix.map { "\($0)：\(reason)，本次改动未保存" }
            ?? "\(reason)，本次改动未保存"
        // `ToastCenter` 是 `@MainActor` 类，按全仓既有写法显式切回主 actor。
        // 去重标志也只在主 actor 上读写（本类其余访问都在主线程），实际无竞争。
        Task { @MainActor in
            guard !Self.didNotifyWriteRejected else { return }
            Self.didNotifyWriteRejected = true
            ToastCenter.shared.show(text)
        }
    }

    /// 会话内是否已经提示过「台账只读、写被拒」。只写不读回，进程重启即复位。
    ///
    /// `@MainActor` 隔离：唯一的读写都在 `notifyWriteRejected` 的 `Task { @MainActor in }`
    /// 闭包内（即主 actor），所以**不需要** `nonisolated(unsafe)` 逃生舱 —— 那个标注等于
    /// 「我知道这里有数据竞争、我自己负责」，而本字段的读-改-写（判断→置位）本就不是原子操作。
    /// 交给 MainActor 串行执行，比「声明无竞争」更诚实、也更省事。
    @MainActor private static var didNotifyWriteRejected = false

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
    ///
    /// v0.3.570：**台账没能完整读出来时只读、不回写**。
    /// 旧实现把「读失败」与「没有台账」压成同一个 `[]`，于是 `items()` 会把磁盘上的包
    /// 全部当新条目重建（丢直链 / sinf / 商品号 / 显示名），随后 `saveIndex` 覆盖原文件
    /// —— 好数据被残缺数据静默替换且不可恢复。现在只要 `loadIndex()` 报告有任何丢失
    /// （文件读不出、JSON 坏、或有记录解不出），就**不写盘**，只把能读到的那部分返回给界面。
    func items() -> [IPADownloadItem] {
        let load = loadIndex()
        var index = load.items
        let onDisk = diskFiles()

        // 1) 磁盘上新增的（索引里没有）→ 读包补登记
        for name in onDisk where !index.contains(where: { $0.fileName == name }) {
            index.append(makeItem(fileName: name))
        }
        // 2) 索引里有、磁盘上没了的 → 剔除
        index.removeAll { !onDisk.contains($0.fileName) }
        // 3) 顺手补齐容量/包信息（索引可能来自更早版本，字段不全）
        for i in index.indices {
            // v0.3.5xx：回改**历史误标**。旧版 `makeItem` 把磁盘扫描捡到的孤儿包写死成
            // `"本地"` 并持久化；但本库只扫 `AppStoreDownloads/`，真·本地导入在 `Imports/`
            // 且从不写本台账 ⇒ 台账里的 `"本地"` 只可能是这个误标，改回中性文案即可。
            // 这里只改内存里的值，是否落盘仍由下方 `load.writable` 决定（只读时绝不回写）。
            if index[i].source == Self.legacyLocalSource {
                index[i].source = Self.unrecordedSource
            }
            if index[i].sizeBytes <= 0 { index[i].sizeBytes = fileSize(index[i].fileName) }
            if index[i].packageName == nil || index[i].isEncrypted == nil {
                let ins = IPAPackageInspector.inspect(ipaPath: path(for: index[i]))
                index[i].packageName = index[i].packageName ?? ins?.displayName
                index[i].bundleId = index[i].bundleId ?? ins?.bundleIdentifier
                index[i].version = index[i].version ?? ins?.bundleVersion
                // 只在**明确读到**加密状态时才覆盖：`ins.isEncrypted` 为 nil（主二进制读不出）
                // 表示「不知道」，不能把已有值抹成未知。
                if index[i].isEncrypted == nil, let e = ins?.isEncrypted { index[i].isEncrypted = e }
            }
            // v0.3.568：加密包的 `hasSINF` **必须现算** —— 台账里的值是个「下载瞬间」的旧快照。
            //
            // 为什么它会旧：`IPADownloadCenter.handle` 是**先** `record()`（此刻包内还没写回 sinf）
            // **后**才异步 `PackageSINFWriter.writeIfNeeded()` 写回包内（两步紧邻，顺序就是如此）。
            // 于是每个走写回链路的加密包（NB / 牛蛙源）都被记成 `false`，而写回成功后
            // **没有任何代码把它改回 true** ⇒ 下载管理永久显示「缺 sinf」（假阳性）。
            //
            // v0.3.570：门槛补上 `sinfStructurallyValid == false` —— 旧门槛 `hasSINF != true`
            // 会让「已判为 sinf 异常」的条目**永不复核**：若那次是瞬时短读（`extractSINF`
            // 返回非 nil 的残缺数据），就会把 `sinf 异常` 永久冻结在台账里。补上后这类条目
            // 每次列表都会重算，读成功即自愈。
            //
            // 性能取舍：只在「还不是 true」或「判为异常」时开包（修正后即持久化，后续不再开）；
            // 明文包的标签不看 `hasSINF`，直接跳过。真正缺 sinf 的包会每次重开 ——
            // 但这类包本就少见（本机 20 条里 2 条），且它们正需要被标出来。
            if index[i].isEncrypted == true,
               index[i].hasSINF != true || index[i].sinfStructurallyValid == false {
                let sinf = IPAPackageInspector.extractSINF(ipaPath: path(for: index[i]))
                index[i].hasSINF = sinf != nil
                // 三态：`unrecognized`（格式不认识）→ nil（未校验），不写成 false 冻死成「sinf 异常」
                index[i].sinfStructurallyValid = sinf.flatMap {
                    PackageSINFWriter.sinfStructure($0).isValid
                }
            }
        }
        if load.writable {
            saveIndex(index)
        } else {
            logReadOnly(load.note)
        }
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
        let load = loadIndex()
        // 台账没完整读出来时**不写盘**：否则会把没读到的条目当成「不存在」而覆盖掉。
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        var index = load.items
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
        loadIndex().items.first { $0.fileName == fileName }?.sinfBase64
    }

    /// v0.3.568：**sinf 写回包内成功后**，把台账的 `hasSINF` / `sinfStructurallyValid` 定正。
    ///
    /// 为什么需要：`record()` 是在「写回之前」记的（见 `IPADownloadCenter.handle`），
    /// 所以新下载的加密包一开始必然是 `hasSINF == false`。写完不更新，标签就会一直
    /// 显示「缺 sinf」（本仓实测的假阳性来源）。`items()` 的现算能兜住历史记录，
    /// 这里让**新下载**当场就正确、不必等下一次重算。
    ///
    /// v0.3.570：`structurallyValid` 改为 `Bool?` —— 包内 sinf 存在但**格式不认识**时传 `nil`
    /// （标签落「未校验」），不得把「不知道」写成 `false` 冻死成「sinf 异常」。
    func markSinf(fileName: String, structurallyValid: Bool?) {
        let load = loadIndex()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        var index = load.items
        guard let i = index.firstIndex(where: { $0.fileName == fileName }) else { return }
        // 幂等：值没变就不写盘
        guard index[i].hasSINF != true || index[i].sinfStructurallyValid != structurallyValid else { return }
        index[i].hasSINF = true
        index[i].sinfStructurallyValid = structurallyValid
        saveIndex(index)
    }

    /// 安装成功后打时间戳
    func markInstalled(fileName: String) {
        let load = loadIndex()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        var index = load.items
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
        let load = loadIndex()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        var index = load.items
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
        let load = loadIndex()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        var index = load.items
        guard let i = index.firstIndex(where: { $0.fileName == fileName }) else { return }
        guard index[i].sourceURL != link else { return }
        index[i].sourceURL = link
        saveIndex(index)
    }

    // MARK: - 删除

    /// 删除一个下载包（文件 + 索引）。
    ///
    /// v0.3.571（一致性修复）：**先判台账可写，再动文件**。
    /// 旧实现把 `removeItem` 放在 `guard writable` **之前** —— 台账损坏（只读）时
    /// **文件已经删掉、台账却没改**：磁盘与台账对不上，用户重进列表看到条目「又回来了」
    /// （`items()` 从磁盘重建），而包其实已经没了。现在只读时**一个文件都不碰**，
    /// 并把结果返回给调用方，由它给**真实**反馈（而不是照旧弹「已删除」）。
    ///
    /// 返回值 `@discardableResult`：既有调用方（左滑 / 批量 / 取消任务）不关心结果时可忽略。
    @discardableResult
    func remove(_ item: IPADownloadItem) -> RemoveResult {
        let load = loadIndex()
        guard load.writable else {
            logReadOnly(load.note)
            notifyWriteRejected(load.userReason, prefix: "未删除安装包")
            return .rejectedReadOnly
        }
        let filePath = path(for: item)
        do {
            try FileManager.default.removeItem(atPath: filePath)
        } catch {
            // 文件**本就不存在**（早已删）不算失败；仍存在 = 真删不掉（被占用 / 权限）。
            // 删不掉时**不动台账**：条目仍原样保留，磁盘与台账继续一致。
            if FileManager.default.fileExists(atPath: filePath) {
                LoginLogger.shared.log("[下载库] 安装包删除失败：\(error)（\(item.fileName)）",
                                       category: .download)
                return .fileRemovalFailed
            }
        }
        var index = load.items
        index.removeAll { $0.fileName == item.fileName }
        saveIndex(index)
        return .removed
    }

    /// 删除单个包（按文件名）—— 下载中心取消任务时用。
    /// 顺序与返回值语义同 `remove(_:)`：只读时**不删文件**、返回 `.rejectedReadOnly`。
    @discardableResult
    func remove(fileName: String) -> RemoveResult {
        let load = loadIndex()
        guard load.writable else {
            logReadOnly(load.note)
            notifyWriteRejected(load.userReason, prefix: "未删除安装包")
            return .rejectedReadOnly
        }
        let filePath = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.removeItem(at: filePath)
        } catch {
            if FileManager.default.fileExists(atPath: filePath.path) {
                LoginLogger.shared.log("[下载库] 安装包删除失败：\(error)（\(fileName)）",
                                       category: .download)
                return .fileRemovalFailed
            }
        }
        var index = load.items
        index.removeAll { $0.fileName == fileName }
        saveIndex(index)
        return .removed
    }

    /// 批量删除（配合列表编辑模式）。
    /// 顺序与返回值语义同 `remove(_:)`：只读时**整批都不删**、返回 `.rejectedReadOnly`。
    /// 可写但个别文件删不掉时，**只把删成功的从台账剔除**（删不掉的留在台账里，保持一致）。
    @discardableResult
    func remove(fileNames: Set<String>) -> RemoveResult {
        guard !fileNames.isEmpty else { return .removed }
        let load = loadIndex()
        guard load.writable else {
            logReadOnly(load.note)
            notifyWriteRejected(load.userReason, prefix: "未删除安装包")
            return .rejectedReadOnly
        }
        var index = load.items
        var anyFailed = false
        for name in fileNames {
            let filePath = directory.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: filePath)
            } catch {
                if FileManager.default.fileExists(atPath: filePath.path) {
                    LoginLogger.shared.log("[下载库] 安装包删除失败：\(error)（\(name)）",
                                           category: .download)
                    anyFailed = true
                    continue
                }
            }
            index.removeAll { $0.fileName == name }
        }
        saveIndex(index)
        return anyFailed ? .fileRemovalFailed : .removed
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
                               source: Self.unrecordedSource,
                               packageName: ins?.displayName,
                               isEncrypted: ins?.isEncrypted,
                               hasSINF: sinf != nil,
                               // 三态：格式不认识 → nil（未校验），不当成「坏」
                               sinfStructurallyValid: sinf.flatMap {
                                   PackageSINFWriter.sinfStructure($0).isValid
                               },
                               lastInstalledAt: nil)
    }

    /// 台账读取结果。
    ///
    /// `writable == false` = **这一次没能完整读出台账**（文件读不出 / JSON 坏 / 有记录解不出）。
    /// 调用方**必须只读、绝不回写**：否则会把没读到的条目当成「不存在」而覆盖掉
    /// ——这正是本项目反复踩过的「没能观察到 ≠ 确定没有」。
    private struct IndexLoad {
        let items: [IPADownloadItem]
        let writable: Bool
        let note: String?
        /// 面向用户的简短原因（写被拒时弹给用户看）；`writable == true` 时为 nil。
        ///
        /// 与 `note` 分开：`note` 是给日志的**技术细节**（文件被占用 / 第几条解不出），
        /// `userReason` 是给界面的一句话（用户不需要知道 JSONSerialization 是什么）。
        let userReason: String?
    }

    private func loadIndex() -> IndexLoad {
        // 文件确实不存在 = 合法空台账（首次运行 / 从没下载过），可以写。
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return IndexLoad(items: [], writable: true, note: nil, userReason: nil)
        }
        guard let data = try? Data(contentsOf: indexURL) else {
            return IndexLoad(items: [], writable: false,
                             note: "台账文件存在但读取失败（被占用 / 磁盘错误），本次按只读处理，不回写",
                             userReason: "下载台账无法读取")
        }
        let dec = JSONDecoder()
        // 与 saveIndex 的 .iso8601 必须成对，否则解码日期失败整份台账读不出来
        dec.dateDecodingStrategy = .iso8601

        // 1) 快路径：整份解得出
        if let list = try? dec.decode([IPADownloadItem].self, from: data) {
            return IndexLoad(items: list, writable: true, note: nil, userReason: nil)
        }

        // 2) 整份解失败 → **逐条**解，能救多少救多少。
        //    单条坏记录（例如一个非法 ISO8601 的 downloadedAt）不再拖垮整份台账。
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return IndexLoad(items: [], writable: false,
                             note: "台账 JSON 解析失败（文件损坏），本次按只读处理，不回写",
                             userReason: "下载台账文件损坏")
        }
        var salvaged: [IPADownloadItem] = []
        for element in raw {
            guard let d = try? JSONSerialization.data(withJSONObject: element),
                  let item = try? dec.decode(IPADownloadItem.self, from: d) else { continue }
            salvaged.append(item)
        }
        guard !salvaged.isEmpty else {
            return IndexLoad(items: [], writable: false,
                             note: "台账 \(raw.count) 条记录全部无法解析，本次按只读处理，不回写",
                             userReason: "下载台账文件损坏")
        }
        // 有救回来的条目，但仍**不写盘**：写回会把解不出的那几条永久抹掉。
        return IndexLoad(items: salvaged, writable: false,
                         note: "台账 \(raw.count) 条里有 \(raw.count - salvaged.count) 条无法解析，"
                             + "本次按只读处理，不回写（原文件保留）",
                         userReason: "下载台账文件损坏")
    }

    private func saveIndex(_ list: [IPADownloadItem]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(list) else {
            LoginLogger.shared.log("[下载库] 台账编码失败，未写盘（\(list.count) 条）", category: .download)
            return
        }
        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // 写失败**不能静默**：调用方（record / markSinf / markInstalled…）都以为已持久化，
            // 用户以为「重装不用重下」可用，实际台账没写。
            LoginLogger.shared.log("[下载库] 台账写盘失败：\(error)（\(list.count) 条未持久化）",
                                   category: .download)
        }
    }

    /// 台账没完整读出来时的统一日志（说明本次为何只读、不回写）。
    private func logReadOnly(_ note: String?) {
        guard let note else { return }
        LoginLogger.shared.log("[下载库] \(note)", category: .download)
    }

    /// 字节数 → 可读文本
    static func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
