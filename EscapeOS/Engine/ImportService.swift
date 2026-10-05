import Foundation

// 共享转换 · 导入服务
//
// 职责：**接住**用户自己传进来的 IPA → **落盘** `Documents/Imports/<包名>/original.ipa` → **校验** → 生成
// `ImportRecord` → **交给修补流程**（`RepairService`）。
//
// 边界（重要）：
//   · 导入**只做**：接住 / 落盘 / 体检 / 算 sha256 / 交接。
//   · 导入**不做**：不注入 sinf、不安装、不联网重取（那些是 `RepairService` 的事）。
//   · 导入**不改包字节**（不剥离 / 不重打包，整包原样复制）。
//
// 校验复用现有两道关卡，**不新写一套**：
//   · 关卡 A（是不是 IPA）：`IPAPackageInspector.inspect`（走中央目录，不解整包）。
//   · 关卡 B（越界防护）：`ArchiveEntryPath.resolve`（复用 `FileKind.swift`，本仓唯一的 ZIP slip 防线）。
//
// 注意： 硬约束：条目名从**中央目录读出**到**落盘**之间，不得再经任何解码 / 规范化 / URL 处理；
//    落盘必须使用 `ArchiveEntryPath.resolve` 已判定的那个路径。本服务**不做条目级解压**
//    （只整包复制 + 只读体检），因此天然规避；若将来加「预览 / 剥离后重打包」，必须走已判定路径。

// MARK: - 数据模型

/// 一次导入的完整记录。字段名对齐传输层 manifest 的 `app` / `payload` / `sinf`。
struct ImportRecord: Codable {
    let id: String
    let importedAt: Date
    let sourceKind: SourceKind
    let originalFileName: String        // 净化前（仅展示）
    let storedFileName: String          // 净化 + 去重后的目录名（一个包一个文件夹）
    let storedPath: String              // Documents/Imports/<storedFileName>/original.ipa
    let sizeBytes: Int64
    let sha256: String                  // 原件 original.ipa 落盘后的整包 sha256（原件指纹；修补**不改它**）
    /// 修补产物 repaired.ipa 的 sha256（与原件指纹**分开存**，绝不覆盖 `sha256`）。
    /// 默认 nil = 尚未修补过；修补成功后由调用方回填（见 `RepairResult.repairedIPASha256`）。
    var repairedSha256: String? = nil

    let app: AppInfo
    let payload: PayloadInfo
    let sinf: SinfPresence
    let purchaseMeta: PurchaseMeta
    let trust: TrustInfo
    let repairHandoff: RepairManifest   // 交给 RepairService（复用其定义，不重复）

    enum SourceKind: String, Codable {
        case fileApp        // 用户拖进「文件」App 里的 EscapeSpace 目录
        case picker         // 应用内 SharedDocumentPicker
        case openInURL      // AirDrop /「用其他应用打开」→ onOpenURL
        case sftp           // 自有 SFTP 收件区
        case clipboard      // 预留
    }

    struct AppInfo: Codable {
        var bundleId: String?
        var version: String?
        var displayName: String?
        var storeItemId: String?
    }
    struct PayloadInfo: Codable {
        /// "encryptedIPA" | "decryptedIPA" | "unknownIPA"（v0.3.570：主二进制读不出时为 unknownIPA）
        var kind: String
        /// `nil` = 加密状态未知（**不等于**未加密）
        var encrypted: Bool?
        var cryptid: UInt32
    }
    struct SinfPresence: Codable {
        var present: Bool
        var sha256: String?
        var accountHint: String?    // 脱敏，如 "c***@126.com"
    }
    struct PurchaseMeta: Codable {
        var iTunesMetadataPresent: Bool
        var appleIdPresent: Bool
        var appleIdRedacted: String?
        var stripped: Bool            // 本流程不做剥离（未实现），恒 false
    }
    struct TrustInfo: Codable {
        var sourceUntrusted: Bool   // 导入的一律 true
        var entryCount: Int?
        var notes: [String]         // 体检备注（**告警**，不等于拒收）
    }
}

/// 导入结果（UI 据此显示）。**拒收**与**告警降级**是两条分支：拒收 → `.rejected`；告警 → `.ok` + `details`。
struct ImportResult {
    enum Status { case ok, rejected, needsUserChoice }
    let status: Status
    let code: String            // I0…I7
    let message: String         // 一句人话
    let suggestion: String      // 一句「你可以怎么办」
    let record: ImportRecord?   // 成功时
    let details: [String]
}

// MARK: - ImportService

/// 导入服务。**无状态门面**，可直接 `static` 调用。
enum ImportService {

    /// 导入目录：`Documents/Imports/`（与自下载的 `AppStoreDownloads/` 分开）。
    static func importsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Imports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: 主入口

    /// 接住一个文件并导入。
    ///
    /// - Parameters:
    ///   - url: 源 URL（`SharedDocumentPicker` 已 `asCopy` 到沙盒；`onOpenURL` 可能读不了 → 见 `handleOpenURL`）。
    ///   - sourceKind: 来源类型（落台账用）。
    ///   - progress: **当前不触发**。导入阶段无可测的确定进度（复制 / 流式 sha256 都拿不到内部进度），
    ///     故不再上报；UI 无进度时走 `indeterminate`。保留该参数以便将来接入真实进度，**不得**再写死数值。
    static func importFile(at url: URL,
                           sourceKind: ImportRecord.SourceKind,
                           progress: (@Sendable (Double, String) -> Void)? = nil) async -> ImportResult {

        var log: [String] = []
        func note(_ s: String) {
            log.append(s)
            LoginLogger.shared.log("[导入] \(s)", category: .shareConvert)
        }

        // ── (1) 存在性 ──────────────────────────────────────────────
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return .init(status: .rejected, code: "I1",
                         message: "没找到要导入的文件.",
                         suggestion: "重新选择一次文件.", record: nil, details: log)
        }

        // ── (2) 大小上限（防 zip bomb 的第一道）─────────────────────
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let maxIPA: Int64 = 4 * 1024 * 1024 * 1024   // 4GB 硬上限
        guard size > 0, size <= maxIPA else {
            return .init(status: .rejected, code: "I2",
                         message: "文件为空或过大.",
                         suggestion: "确认这是一个正常的 .ipa 安装包.", record: nil, details: log)
        }

        // ── (3) 文件名净化 + 唯一目录名（复用现有工具，不自己拼路径）────
        let rawName = url.lastPathComponent
        guard let safeLeaf = FileNameRules.sanitize(rawName) else {
            return .init(status: .rejected, code: "I3",
                         message: "文件名不合法.",
                         suggestion: "重命名后重试.", record: nil, details: log)
        }
        let destDir = importsDirectory()
        // 落点：新导入不再平铺到 Imports/，而是「一个包一个文件夹」：
        //   Imports/<净化包名>/original.ipa
        // 这样修补产物可落在同目录的 repaired.ipa，**原件 original.ipa 永不被就地改写**
        // （否则「修补后取消安装」会破坏原件、且无副本可退，见 RepairService）。
        //
        // 目录名去掉 `.ipa` 后缀：目录名若以 .ipa 结尾（如 Imports/MyApp.ipa/），会被扫描器当成
        // 「平铺 ipa 文件」形态（形态判定先看扩展名），于是把包自己的**目录**当成新包，
        // 导入时报 I1「没找到要导入的文件」。
        let folderBase = (safeLeaf as NSString).pathExtension.lowercased() == "ipa"
            ? (safeLeaf as NSString).deletingPathExtension
            : safeLeaf
        //
        // 并发安全：这里用 `reserveUniqueDirectory` **原子抢占**目录名（`mkdir(2)`，EEXIST 换名），
        // 不再用 `uniqueDestination` 的 check-then-act —— 后者在 `handleOpenURL` 的 nonisolated
        // `Task` 与 picker 的 `startImport` 并发进 `importFile` 时，会让两者算到**同一目录**，
        // 互相覆写 `original.ipa`，并在复制失败时删掉对方已落盘的目录（跨任务误删 / 静默损坏）。
        let folderURL: URL
        do {
            folderURL = try FileService().reserveUniqueDirectory(in: destDir.path, preferredName: folderBase)
        } catch {
            return .init(status: .rejected, code: "I4",
                         message: "创建导入目录失败.",
                         suggestion: "确认存储空间充足后重试.",
                         record: nil, details: log + ["\(error)"])
        }
        let destURL = folderURL.appendingPathComponent("original.ipa")

        // ── (4) 复制到 Imports/<包名>/original.ipa（不移动源文件，避免破坏用户原件）────
        // 目录是本次导入**原子独占**的（见上），故：
        //   · 无需再判断 / 删除已存在的 original.ipa —— 本目录内不可能有别人的文件；
        //   · 失败清理只删**本次占位目录**（cleanupOwnFolder），绝不误删并发对方已落盘的目录。
        do {
            try FileManager.default.copyItem(at: url, to: destURL)
            note("已落盘：\(folderURL.lastPathComponent)/original.ipa")
        } catch {
            cleanupOwnFolder(folderURL)
            return .init(status: .rejected, code: "I4",
                         message: "复制文件失败.",
                         suggestion: "确认存储空间充足后重试.",
                         record: nil, details: log + ["\(error)"])
        }

        // ── (5) 关卡 A：是不是 IPA（复用 IPAPackageInspector，不解整包）──
        guard let ins = IPAPackageInspector.inspect(ipaPath: destURL.path) else {
            cleanupOwnFolder(folderURL)
            return .init(status: .rejected, code: "I5",
                         message: "这不是一个可安装的 IPA（缺 Payload/Info.plist）.",
                         suggestion: "确认对方分享的是 .ipa 而不是别的文件（zip 改后缀也不行）.",
                         record: nil, details: log)
        }
        note("包信息：\(ins.bundleIdentifier ?? "-") \(ins.bundleVersion ?? "-") · \(ins.summary)")

        // ── (6) 关卡 B：ZIP slip 越界防护（复用 ArchiveEntryPath.resolve）──
        // 只读地枚举中央目录条目名并逐个判定；**不解压**。命中越界 → 拒收（不做「将就装」）。
        var entryCount: Int?
        var warnings: [String] = []
        do {
            let reader = try ZipReader(url: destURL)
            defer { reader.close() }
            let names = reader.entryNames()
            entryCount = names.count
            if names.count > 20_000 {
                cleanupOwnFolder(folderURL)
                return .init(status: .rejected, code: "I6",
                             message: "安装包条目过多（可能异常）.",
                             suggestion: "让对方用未改动的原始包重传.", record: nil, details: log)
            }
            for name in names {
                // 命中 `..` / 绝对路径 / 标准化后逃逸 → 抛错 → 拒收
                do { _ = try ArchiveEntryPath.resolve(name, under: destDir.path) }
                catch {
                    cleanupOwnFolder(folderURL)
                    return .init(status: .rejected, code: "I6",
                                 message: "安装包内含越界路径，已拒绝导入.",
                                 suggestion: "让对方用未改动的原始包重传；本机不做「将就装」.",
                                 record: nil, details: log + ["越界条目：\(name)"])
                }
            }
            let dupCount = names.count - Set(names).count
            if dupCount > 0 { warnings.append("包内有 \(dupCount) 个重复条目名（结构可疑）") }
        } catch {
            // 中央目录读不出来 —— 与「不是 IPA」分开报（这是「ZIP 结构异常」）
            cleanupOwnFolder(folderURL)
            return .init(status: .rejected, code: "I6",
                         message: "安装包 ZIP 结构异常，无法解析.",
                         suggestion: "让对方用未改动的原始包重传.", record: nil, details: log + ["\(error)"])
        }

        // ── (7) 「是 IPA」≠「结构完整」：结构告警走**降级**分支（不拒收）──
        //   · 主二进制缺失 → 告警；
        //   · pkg.stat 可用时看 testzipOk / orphanLocalCount → 异常只告警。
        if ins.missingExecutable { warnings.append("主二进制缺失，包结构可疑") }
        if let zip = hostPkgStat(path: destURL.path) {
            let testzipOk = zip["testzipOk"] as? Bool ?? true
            let orphan = zip["orphanLocalCount"] as? Int ?? 0
            if !testzipOk { warnings.append("pkg.stat: testzipOk=false（ZIP 结构告警）") }
            if orphan > 0 { warnings.append("pkg.stat: orphanLocalCount=\(orphan)（孤儿 local header）") }
        }
        for w in warnings { note("告警（不阻断）：\(w)") }

        // ── (8) 包内 sinf 体检（只记录；是否可用由修补流程判）────────
        let sinfData = IPAPackageInspector.extractSINF(ipaPath: destURL.path)
        let sinfSha = sinfData.map { RepairService.sha256Hex(of: $0) }
        note(sinfData != nil ? "包内已有 sinf（\(sinfData!.count) 字节）" : "包内无 sinf")

        // ── (9) 购买者元数据体检（含 appleId 的包要提示）─────────────
        // 注意：本流程**不剥离** iTunesMetadata（整包原样复制），因此 `stripped` 恒为 false。
        let purchase = inspectPurchaseMeta(ipaPath: destURL.path, note: note)
        if purchase.appleIdPresent {
            note("包内 iTunesMetadata 含购买者账号（已脱敏：\(purchase.appleIdRedacted ?? "?")）")
        }

        // ── (10) 算 sha256（流式，不整包读内存）──────────────────────
        // 导入阶段**不上报进度**：复制走系统 `copyItem`（拿不到内部进度），流式 sha256 也无廉价进度可报。
        // 曾在此写死 `progress?(0.5, ...)` ⇒ 进度条恒走 0 → 50% → 结束，是**假进度**（比没有更糟）。
        // 无确定进度时 UI 走 `indeterminate` 转圈 —— 转圈是真的，写死的进度条是假的。
        guard let sha = RepairService.sha256Hex(ofFileAt: destURL.path) else {
            // v0.3.570：读失败必须**清掉已落盘的副本**。
            // 否则 `Imports/` 里会留一个**无台账记录的孤儿包**（用户看不到、也不会被清理）。
            // 其余拒收分支（I4 / I5 / I6）都清理，唯独这处漏了 —— 审计 D2。
            cleanupOwnFolder(folderURL)
            return .init(status: .rejected, code: "I6",
                         message: "读取文件失败.", suggestion: "重试.",
                         record: nil, details: log)
        }
        note("sha256=\(sha.prefix(16))…")

        // ── (11) 组装 ImportRecord ──────────────────────────────────
        let itemId = extractStoreItemId(ipaPath: destURL.path)
        // v0.3.570：加密状态三态 —— 主二进制读不出时是 unknownIPA，**不得**记成 decryptedIPA。
        let payloadKind: String
        let payloadSuggestion: String
        switch ins.encryption {
        case .encrypted:
            payloadKind = "encryptedIPA"
            payloadSuggestion = "下一步将把包内解密授权铺满并安装."
        case .plaintext:
            payloadKind = "decryptedIPA"
            payloadSuggestion = "这是明文包，可直接安装."
        case .unknown:
            payloadKind = "unknownIPA"
            payloadSuggestion = "无法判定这个包是否加密（主二进制读不出），请确认包是否完整."
        }
        let record = ImportRecord(
            id: UUID().uuidString,
            importedAt: Date(),
            sourceKind: sourceKind,
            originalFileName: rawName,
            storedFileName: folderURL.lastPathComponent,   // 净化 + 去重后的目录名（= 包名）
            storedPath: destURL.path,                      // …/Imports/<包名>/original.ipa
            sizeBytes: size,
            sha256: sha,
            app: .init(bundleId: ins.bundleIdentifier,
                       version: ins.bundleVersion,
                       displayName: ins.displayName,
                       storeItemId: itemId),
            payload: .init(kind: payloadKind,
                           encrypted: ins.isEncrypted,
                           cryptid: ins.cryptid),
            sinf: .init(present: sinfData != nil, sha256: sinfSha,
                        accountHint: purchase.appleIdRedacted),
            purchaseMeta: purchase,
            trust: .init(sourceUntrusted: true, entryCount: entryCount, notes: warnings),
            repairHandoff: .init(bundleId: ins.bundleIdentifier,
                                 storeItemId: itemId,
                                 payloadKind: payloadKind,
                                 payloadSha256: sha,
                                 sourceHint: nil)
        )
        note("导入完成，准备交给修补流程")

        return .init(status: .ok, code: "I0",
                     message: "已导入：\(ins.displayName ?? folderURL.lastPathComponent).",
                     suggestion: payloadSuggestion,
                     record: record, details: log)
    }

    // MARK: 目录扫描（文件 App 拖入路径）

    /// 目录扫描结果：**区分「确实没有新包」与「目录读不出来」**。
    ///
    /// 为什么不能只返回裸 `[URL]`：旧实现用 `try?` 吞掉 `contentsOfDirectory` 的枚举错误后
    /// 返回空数组，于是「读不出来」和「确实没有」在调用方看来完全一样 —— 用户看到的是
    /// 「没有发现新的安装包」，而真相是**没能观察到**（本轮要清的静默失败）。
    /// `unreadableDirectories` 非空时，「没有新包」这个结论**不可信**，调用方必须让用户察觉。
    struct ScanResult {
        /// 发现的新包（已按最近修改优先排序）。
        let urls: [URL]
        /// 枚举失败、因而无法确认是否含新包的目录。
        let unreadableDirectories: [URL]
    }

    /// 扫描 `Documents/Imports/`（可选连 `Documents/` 根）发现新增包。
    /// **文件 App 拖入不会给 App 任何回调**，只能主动扫描（启动 / 回前台 / 手动刷新）。
    ///
    /// 双形态兼容（一个包一个文件夹的新落点上线后，老平铺包**必须仍能列出**）：
    ///   · 老平铺：`Imports/*.ipa`（直接认这个 .ipa 文件）
    ///   · 新落点：`Imports/<包名>/original.ipa`（认目录里的 original.ipa）
    /// 修补产物**一律排除** —— 它不是新导入的包，认了会被重复导入：
    ///   · 新落点同目录的 `repaired.ipa`；
    ///   · 老平铺的 `Imports/repaired/<包名>.ipa`（`Imports/repaired/` 目录不含 `original.ipa`，天然不被认）。
    ///
    /// 返回 `ScanResult`（`urls` 按「最近修改优先」排序 —— `contentsOfDirectory` 顺序不保证，
    /// 调用方取 `.first` 必须得到确定结果）；`known` 命中的（已导入的）会被过滤掉。
    ///
    /// 注意： 枚举失败**不再**被吞成空数组：失败的目录会记进 `unreadableDirectories`，
    /// 调用方据此提示「读不出来」而不是「没有新包」（见 `ScanResult` 的说明）。
    static func scanForNewImports(alsoScanDocumentsRoot: Bool = true,
                                  known: [ImportRecord]) -> ScanResult {
        let fm = FileManager.default
        let importsDir = importsDirectory()
        let dirs: [URL] = [importsDir] + (alsoScanDocumentsRoot
            ? [fm.urls(for: .documentDirectory, in: .userDomainMask)[0]] : [])
        var out: [URL] = []
        var unreadable: [URL] = []
        for dir in dirs {
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(at: dir,
                            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                            options: [.skipsHiddenFiles])
            } catch {
                // 读不出来 ≠ 确定没有：记下失败目录并留痕，**不**当作空目录继续。
                unreadable.append(dir)
                LoginLogger.shared.log(
                    "[导入] 目录枚举失败：\(dir.lastPathComponent)（\(error.localizedDescription)）",
                    category: .shareConvert)
                continue
            }
            for u in items {
                // **先判「是不是目录」**：新落点（含 v0.3.571 已落盘的 `Imports/<包名>.ipa/` 目录）
                // 必须是「目录」形态。若先判扩展名，`Imports/MyApp.ipa/` 这种以 .ipa 结尾的目录会被
                // 误判成平铺包文件，形态二分支对它永不可达。
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: u.path, isDirectory: &isDir)
                if exists && isDir.boolValue {
                    // 形态二（新落点）：`Imports/<包名>/original.ipa`。
                    // 只对 Imports/ 目录做一级下探；Documents/ 根不做（新落点只会在 Imports/ 下）。
                    guard dir.path == importsDir.path else { continue }
                    let original = u.appendingPathComponent("original.ipa")
                    guard fm.fileExists(atPath: original.path) else { continue }
                    if known.contains(where: { $0.storedPath == original.path }) { continue }
                    out.append(original)
                    continue
                }
                // 形态一（老平铺）：`Imports/*.ipa`。排除修补产物 repaired.ipa。
                if u.pathExtension.lowercased() == "ipa" {
                    if u.lastPathComponent == "repaired.ipa" { continue }
                    if known.contains(where: { $0.storedPath == u.path }) { continue }
                    out.append(u)
                    continue
                }
            }
        }
        let sorted = out.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
            if da != db { return da > db }
            return a.lastPathComponent < b.lastPathComponent
        }
        return ScanResult(urls: sorted, unreadableDirectories: unreadable)
    }

    // MARK: onOpenURL（AirDrop /「用其他应用打开」）

    /// 处理 `CFBundleDocumentTypes` 声明的类型被打开时的 URL。
    ///
    /// 注意： LiveContainer 下 `LSSupportsOpeningDocumentsInPlace=true` 可能给**安全作用域 URL**
    ///    （而非 `Inbox/` 副本），安全作用域访问在 LC guest 下常被拒 ⇒ **先试，失败降级**。
    ///    降级动作由调用方通过 `fallbackToPicker` 决定（当前实现：切到共享转换页并提示手动选择，
    ///    **不会**自动弹出文件选择器）。
    ///
    /// 注意： 两个回调都声明为 `@MainActor`（它们本就是 UI 回调）。这同时解决 Swift 6 严格并发：
    ///    全局 actor 隔离的闭包**隐式 `Sendable`**，因此可以合法地被下方 `Task {}` 捕获并送进
    ///    `MainActor.run`，无需 `@unchecked Sendable` / `nonisolated(unsafe)` 之类的逃生舱。
    static func handleOpenURL(_ url: URL,
                              fallbackToPicker: @escaping @MainActor () -> Void,
                              completion: @escaping @MainActor (ImportResult) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            LoginLogger.shared.log("[导入] onOpenURL 读取失败（可能是 LC 安全作用域限制），降级到应用内选择",
                                   category: .shareConvert)
            // 两个回调都是 UI 回调（切 tab + toast），签名上已是 `@MainActor`。
            // 本函数**刻意保持 nonisolated**（理由见下方 Task 处），所以这里显式回主 actor 再调。
            Task { @MainActor in
                fallbackToPicker()
                completion(.init(status: .needsUserChoice, code: "I7",
                                 message: "无法直接读取这个文件.",
                                 suggestion: "请到「更多 → 应用安装 → 共享转换」里手动选择这个文件.",
                                 record: nil, details: ["\(error)"]))
            }
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        // 注意： 本函数**必须保持 nonisolated**，且这里**必须**是 `Task {}`（不是 `Task.detached`）。
        //    原因：`Task {}` 只在**非隔离**上下文里才不会被主 actor 继承 —— 而 `importFile`
        //    要做几百 MB 的整包复制 + 流式 sha256 + 解 ZIP 中央目录，必须留在主线程之外。
        //    若把本函数标成 `@MainActor`（或在 `@MainActor` 上下文里 `Task {}`），在
        //    `SWIFT_APPROACHABLE_CONCURRENCY=YES`（SE-0461 NonisolatedNonsendingByDefault）下
        //    `await importFile` 会**跑在主线程** → 导入大包时界面卡死。
        //    实测见 `_verify_swift6/_runtime/option_probe.swift`（mode a 命中主 actor，mode d 不命中）。
        //    两个回调改成 `@MainActor` 后即隐式 `Sendable`，因此可以合法地跨进这个 Task。
        Task {
            let r = await importFile(at: tmp, sourceKind: .openInURL)
            try? FileManager.default.removeItem(at: tmp)
            await MainActor.run { completion(r) }
        }
    }

    // MARK: 交接到修补流程

    /// 导入完成后调用：把 record 交给 `RepairService`。
    static func handOffToRepair(_ record: ImportRecord,
                                runLaunchCheck: Bool = true,
                                progress: (@Sendable (Double, String) -> Void)? = nil,
                                onLog: (@Sendable (String) -> Void)? = nil,
                                confirmInstall: (@MainActor () async -> Bool)? = nil) async -> RepairResult {
        let req = RepairRequest(ipaPath: record.storedPath,
                                manifest: record.repairHandoff,
                                runLaunchCheck: runLaunchCheck)
        return await RepairService.repair(req, progress: progress, onLog: onLog,
                                          confirmInstall: confirmInstall)
    }

    // MARK: 从磁盘重建记录（已导入包列表 → 进入修补流程）

    /// 为 `Imports/` 里**已存在**的原件重建一条 `ImportRecord`，
    /// 让「已导入的包」列表点某一行时复用既有的「包信息 → 开始修补」入口。
    ///
    /// 与 `importFile` 的差别：不落盘、不净化文件名、不写台账，只**重读原件**补齐修补所需字段。
    /// `repairHandoff.payloadSha256` 用**现场重算的原件 sha256** —— 与 `RepairService` 的完整性
    /// 校验同源，必然自洽。
    ///
    /// 返回 `nil` 表示原件读不出（缺失 / 不是 IPA / 哈希失败），调用方据此提示，不静默。
    static func rebuildRecord(forOriginalAt path: String) -> ImportRecord? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let url = URL(fileURLWithPath: path)

        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let when = (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date) ?? Date()

        guard let ins = IPAPackageInspector.inspect(ipaPath: path) else { return nil }
        guard let sha = RepairService.sha256Hex(ofFileAt: path) else { return nil }

        let sinfData = IPAPackageInspector.extractSINF(ipaPath: path)
        let sinfSha = sinfData.map { RepairService.sha256Hex(of: $0) }
        let purchase = inspectPurchaseMeta(ipaPath: path, note: { _ in })
        let itemId = extractStoreItemId(ipaPath: path)

        let payloadKind: String
        switch ins.encryption {
        case .encrypted: payloadKind = "encryptedIPA"
        case .plaintext: payloadKind = "decryptedIPA"
        case .unknown:   payloadKind = "unknownIPA"
        }

        // 展示名：新落点取目录名（= 包名），老平铺取去扩展名的文件名。
        let storedName = url.lastPathComponent == "original.ipa"
            ? url.deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent

        return ImportRecord(
            id: UUID().uuidString,
            importedAt: when,
            // 来源类型从磁盘现状不可考（列表只反推落点形态）—— 仅台账字段，不参与修补与展示。
            sourceKind: .picker,
            originalFileName: url.lastPathComponent,
            storedFileName: storedName,
            storedPath: path,
            sizeBytes: size,
            sha256: sha,
            app: .init(bundleId: ins.bundleIdentifier,
                       version: ins.bundleVersion,
                       displayName: ins.displayName,
                       storeItemId: itemId),
            payload: .init(kind: payloadKind,
                           encrypted: ins.isEncrypted,
                           cryptid: ins.cryptid),
            sinf: .init(present: sinfData != nil, sha256: sinfSha,
                        accountHint: purchase.appleIdRedacted),
            purchaseMeta: purchase,
            trust: .init(sourceUntrusted: true, entryCount: nil, notes: []),
            repairHandoff: .init(bundleId: ins.bundleIdentifier,
                                 storeItemId: itemId,
                                 payloadKind: payloadKind,
                                 payloadSha256: sha,
                                 sourceHint: nil)
        )
    }

    // MARK: 修补成功后删除原件（用户需求 #17）

    /// 修补成功后删除**原件**（需求 #17：修好后自动删掉那份待修补的包）。
    ///
    /// **只删原件，产物保留** —— 产物才是后续安装 / 导出的对象。原件删掉后，该包目录只剩产物，
    /// `ImportedPackageList` 会据磁盘现状把它归到「已修补」块（新落点看同目录 `repaired.ipa`；
    /// 老平铺看 `Imports/repaired/<包名>.ipa`）。
    ///
    /// **自证安全（不依赖调用方传对）**：删除前必须确认「产物路径 ≠ 原件路径，且产物存在且是普通文件」。
    /// 任一条不满足就**不删**并返回 `false` —— 否则一旦产物没落成独立文件（例如旧明文分支把原件当产物），
    /// 删原件会让该包从两个列表静默消失（原件 + 产物全无）。
    ///
    /// 只在**修补成功**（`RepairResult.status == .ok`）后由调用方调用；失败 / 取消（`.skipped`）
    /// **绝不**调用 —— 那两种情形原件必须完好（与需求 #10 一致）。
    ///
    /// - Returns: 确实删掉了原件返回 `true`；产物不满足安全前提或删除失败返回 `false`（不抛、不静默阻断）。
    @discardableResult
    static func deleteOriginalAfterRepairSuccess(_ record: ImportRecord) -> Bool {
        let original = record.storedPath
        // 产物路径由原件路径推导（新落点 Imports/<包名>/repaired.ipa；老平铺 Imports/repaired/<包名>.ipa）。
        let product = RepairService.repairedOutputPath(forOriginal: original)
        guard product != original else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: product, isDirectory: &isDir), !isDir.boolValue else {
            LoginLogger.shared.log("[共享修补] 未发现独立产物，保留原件不删：\(product)",
                                   category: .shareConvert)
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: original)
            LoginLogger.shared.log("[共享修补] 修补成功，已删除原件（保留产物 \(product)）",
                                   category: .shareConvert)
            return true
        } catch {
            LoginLogger.shared.log("[共享修补] 删除原件失败：\(error)",
                                   category: .shareConvert)
            return false
        }
    }

    // MARK: 小工具

    /// 清掉**本次导入原子占位**的那个目录（`reserveUniqueDirectory` 保证它归本任务独占）。
    ///
    /// 只删这一个目录 —— 绝不触碰其它并发导入的目录。旧实现用裸 `removeItem(folderURL)` 时，
    /// 因占位是 check-then-act（非独占），复制失败会删掉**并发对方已落盘的目录**（跨任务误删，
    /// 进而让对方的 `record.sha256` 与实际文件不符 → 静默损坏 / 误报 E2）。原子占位后本目录
    /// 必为己有，删除才安全。
    private static func cleanupOwnFolder(_ folderURL: URL) {
        try? FileManager.default.removeItem(at: folderURL)
    }

    /// 购买者元数据体检（日志**只记脱敏值**）。
    private static func inspectPurchaseMeta(ipaPath: String,
                                            note: (String) -> Void) -> ImportRecord.PurchaseMeta {
        guard let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: ipaPath),
              let plist = try? PropertyListSerialization.propertyList(from: meta, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return .init(iTunesMetadataPresent: false, appleIdPresent: false,
                         appleIdRedacted: nil, stripped: false)
        }
        let raw = (dict["appleId"] as? String) ?? (dict["AppleID"] as? String) ?? ""
        let redacted = raw.isEmpty ? nil : redactEmail(raw)
        return .init(iTunesMetadataPresent: true,
                     appleIdPresent: !raw.isEmpty,
                     appleIdRedacted: redacted,
                     stripped: false)
    }

    /// 邮箱脱敏：`c***@126.com`
    private static func redactEmail(_ s: String) -> String {
        guard let at = s.firstIndex(of: "@") else { return "***" }
        let name = s[s.startIndex..<at]
        let domain = s[at...]
        return "\(name.prefix(1))***\(domain)"
    }

    /// trackId：包内 iTunesMetadata.itemId（可能被重签 / 归档剥掉 → nil）。
    private static func extractStoreItemId(ipaPath: String) -> String? {
        guard let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: ipaPath),
              let plist = try? PropertyListSerialization.propertyList(from: meta, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        if let n = dict["itemId"] as? NSNumber { return n.stringValue }
        return dict["itemId"] as? String
    }

    /// 直调 `pkg.stat`（JSON 字符串入参）拿 `zip` 摘要；不可用 → nil（降级）。
    private static func hostPkgStat(path: String) -> [String: Any]? {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let (rc, json) = HostCapabilityService.call(capability: "pkg.stat",
                                                    jsonArgs: "{\"path\":\"\(escaped)\"}")
        guard rc == 0,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zip = obj["zip"] as? [String: Any] else { return nil }
        return zip
    }
}
