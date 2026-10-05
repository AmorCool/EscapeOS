import Foundation

// 共享转换 · 导入服务
//
// 职责：**接住**用户自己传进来的 IPA → **落盘** `Documents/Imports/` → **校验** → 生成
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
// ⚠️ 硬约束：条目名从**中央目录读出**到**落盘**之间，不得再经任何解码 / 规范化 / URL 处理；
//    落盘必须使用 `ArchiveEntryPath.resolve` 已判定的那个路径。本服务**不做条目级解压**
//    （只整包复制 + 只读体检），因此天然规避；若将来加「预览 / 剥离后重打包」，必须走已判定路径。

// MARK: - 数据模型

/// 一次导入的完整记录。字段名对齐传输层 manifest 的 `app` / `payload` / `sinf`。
struct ImportRecord: Codable {
    let id: String
    let importedAt: Date
    let sourceKind: SourceKind
    let originalFileName: String        // 净化前（仅展示）
    let storedFileName: String          // 净化 + 去重后
    let storedPath: String              // Documents/Imports/<storedFileName>
    let sizeBytes: Int64
    let sha256: String                  // 落盘后（整包原样复制，不做剥离 / 重打包）

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
        var kind: String        // "encryptedIPA" | "decryptedIPA"
        var encrypted: Bool
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
    static func importFile(at url: URL,
                           sourceKind: ImportRecord.SourceKind,
                           progress: (@Sendable (Double, String) -> Void)? = nil) async -> ImportResult {

        var log: [String] = []
        func note(_ s: String) {
            log.append(s)
            LoginLogger.shared.log("[导入] \(s)", category: .appStore)
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

        // ── (3) 文件名净化 + 唯一名（复用现有工具，不自己拼路径）────
        let rawName = url.lastPathComponent
        guard let safeLeaf = FileNameRules.sanitize(rawName) else {
            return .init(status: .rejected, code: "I3",
                         message: "文件名不合法.",
                         suggestion: "重命名后重试.", record: nil, details: log)
        }
        let destDir = importsDirectory()
        let storedName = FileService().uniqueDestination(in: destDir.path, preferredName: safeLeaf)
        let destURL = URL(fileURLWithPath: storedName)

        // ── (4) 复制到 Imports/（不移动源文件，避免破坏用户原件）────
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: url, to: destURL)
            note("已落盘：\(destURL.lastPathComponent)")
        } catch {
            return .init(status: .rejected, code: "I4",
                         message: "复制文件失败.",
                         suggestion: "确认存储空间充足后重试.",
                         record: nil, details: log + ["\(error)"])
        }

        // ── (5) 关卡 A：是不是 IPA（复用 IPAPackageInspector，不解整包）──
        guard let ins = IPAPackageInspector.inspect(ipaPath: destURL.path) else {
            try? FileManager.default.removeItem(at: destURL)
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
                try? FileManager.default.removeItem(at: destURL)
                return .init(status: .rejected, code: "I6",
                             message: "安装包条目过多（可能异常）.",
                             suggestion: "让对方用未改动的原始包重传.", record: nil, details: log)
            }
            for name in names {
                // 命中 `..` / 绝对路径 / 标准化后逃逸 → 抛错 → 拒收
                do { _ = try ArchiveEntryPath.resolve(name, under: destDir.path) }
                catch {
                    try? FileManager.default.removeItem(at: destURL)
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
            try? FileManager.default.removeItem(at: destURL)
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
        progress?(0.5, "校验中")
        guard let sha = RepairService.sha256Hex(ofFileAt: destURL.path) else {
            return .init(status: .rejected, code: "I6",
                         message: "读取文件失败.", suggestion: "重试.",
                         record: nil, details: log)
        }
        note("sha256=\(sha.prefix(16))…")

        // ── (11) 组装 ImportRecord ──────────────────────────────────
        let itemId = extractStoreItemId(ipaPath: destURL.path)
        let record = ImportRecord(
            id: UUID().uuidString,
            importedAt: Date(),
            sourceKind: sourceKind,
            originalFileName: rawName,
            storedFileName: destURL.lastPathComponent,
            storedPath: destURL.path,
            sizeBytes: size,
            sha256: sha,
            app: .init(bundleId: ins.bundleIdentifier,
                       version: ins.bundleVersion,
                       displayName: ins.displayName,
                       storeItemId: itemId),
            payload: .init(kind: ins.isEncrypted ? "encryptedIPA" : "decryptedIPA",
                           encrypted: ins.isEncrypted,
                           cryptid: ins.cryptid),
            sinf: .init(present: sinfData != nil, sha256: sinfSha,
                        accountHint: purchase.appleIdRedacted),
            purchaseMeta: purchase,
            trust: .init(sourceUntrusted: true, entryCount: entryCount, notes: warnings),
            repairHandoff: .init(bundleId: ins.bundleIdentifier,
                                 storeItemId: itemId,
                                 payloadKind: ins.isEncrypted ? "encryptedIPA" : "decryptedIPA",
                                 payloadSha256: sha,
                                 sourceHint: nil)
        )
        note("导入完成，准备交给修补流程")

        return .init(status: .ok, code: "I0",
                     message: "已导入：\(ins.displayName ?? destURL.lastPathComponent).",
                     suggestion: ins.isEncrypted
                        ? "下一步将把包内解密授权铺满并安装."
                        : "这是明文包，可直接安装.",
                     record: record, details: log)
    }

    // MARK: 目录扫描（文件 App 拖入路径）

    /// 扫描 `Documents/Imports/`（可选连 `Documents/` 根）发现新增 `.ipa`。
    /// **文件 App 拖入不会给 App 任何回调**，只能主动扫描（启动 / 回前台 / 手动刷新）。
    ///
    /// 返回按「最近修改优先」排序（`contentsOfDirectory` 顺序不保证，调用方取 `.first`
    /// 必须得到确定结果）；`known` 命中的（已导入的）会被过滤掉。
    static func scanForNewImports(alsoScanDocumentsRoot: Bool = true,
                                  known: [ImportRecord]) -> [URL] {
        let fm = FileManager.default
        let dirs: [URL] = [importsDirectory()] + (alsoScanDocumentsRoot
            ? [fm.urls(for: .documentDirectory, in: .userDomainMask)[0]] : [])
        var out: [URL] = []
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir,
                        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles])) ?? []
            for u in items where u.pathExtension.lowercased() == "ipa" {
                if known.contains(where: { $0.storedPath == u.path }) { continue }
                out.append(u)
            }
        }
        return out.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
            if da != db { return da > db }
            return a.lastPathComponent < b.lastPathComponent
        }
    }

    // MARK: onOpenURL（AirDrop /「用其他应用打开」）

    /// 处理 `CFBundleDocumentTypes` 声明的类型被打开时的 URL。
    ///
    /// ⚠️ LiveContainer 下 `LSSupportsOpeningDocumentsInPlace=true` 可能给**安全作用域 URL**
    ///    （而非 `Inbox/` 副本），安全作用域访问在 LC guest 下常被拒 ⇒ **先试，失败降级**。
    ///    降级动作由调用方通过 `fallbackToPicker` 决定（当前实现：切到共享转换页并提示手动选择，
    ///    **不会**自动弹出文件选择器）。
    static func handleOpenURL(_ url: URL,
                              fallbackToPicker: @escaping () -> Void,
                              completion: @escaping (ImportResult) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            LoginLogger.shared.log("[导入] onOpenURL 读取失败（可能是 LC 安全作用域限制），降级到应用内选择",
                                   category: .appStore)
            fallbackToPicker()
            completion(.init(status: .needsUserChoice, code: "I7",
                             message: "无法直接读取这个文件.",
                             suggestion: "请到「更多 → 应用安装 → 共享转换」里手动选择这个文件.",
                             record: nil, details: ["\(error)"]))
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

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

    // MARK: 小工具

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
