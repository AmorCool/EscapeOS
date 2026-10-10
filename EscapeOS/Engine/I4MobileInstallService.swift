import Foundation

/// 爱思「安装移动端」服务层（只做逻辑，不含 UI）—— 移植自爱思助手 PC 端 9.0.
///
/// ## 移植的是什么（v2：修正 sinf 来源）
/// 爱思 PC 端「安装爱思移动端」的真实做法**不是**「把包内自带的 sinf 直接递给 installd」：
///   ① 解压内嵌 IPA（libzip）；
///   ② 往包里**写一份 sinf**（覆盖 `Payload/<X>.app/SC_Info/<exe>.sinf`）——
///      这份 sinf 来自 **Apple 服务端**（`MZFinance` 响应 `songList[].sinfs[0]`），
///      **不是**包内原有的那份；
///   ③ 重打包；
///   ④ `idm_app.dll` 再从包里**读回**这份 sinf，作为 `ApplicationSINF` 参数交 installd。
/// 核心函数 `addSinfToZip()`（VA `0x1407dd6b0`），目标路径模板 `Payload/%1/SC_Info/%2.sinf`；
/// 重取路径 `WriteAppSignature start` → 轮询 → 下载解析 → `addSinfToZip`。
///
/// ## 为什么必须现取 sinf（决定性证据）
/// 三个内嵌 IPA 包内自带的 sinf，其 `schi.name` 属**原始购买者**，**不是**爱思共享账号
/// `share_appleid003@163.com`（三包 `iTunesMetadata.appleId` 才是该共享账号）：
///   · `217.ipa`   `schi.user=0xab6d95d8` `schi.name=李 明`
///   · `220.ipa`   `schi.user=0xa775eea7` `schi.name=小 敏`
///   · `photo.ipa` `schi.user=0xab5c9f49` `schi.name=chongwei stven`
/// ⇒ 包内 sinf 与「本设备」无关，直接递交 installd **必然**过不了 FairPlay（装不上，
/// 或装上后运行期 `fairplayOpen()` 失败而闪退，即 `-42112` 一类）。
/// 这正是本服务 v1 的错误：它 `extractSINF` 取包内自带、直接装。
///
/// ## sinf 来源（只有一条路，照爱思）
/// **NB 服务端** —— `NBStoreClient.packageByVersion(appID:appVerId:bundleID:country:)`
/// 按「包内 `iTunesMetadata` 的 `itemId` + `softwareVersionExternalIdentifier`」
/// 现取该版本的 sinf，**写进包内覆盖**，再装。
/// 取不到即**明确失败**（抛 `serverSinfUnavailable`），**不回退到包内自带**。
///
/// **为什么不做「优先级 + 兜底」**：包内自带 sinf 属**原始购买者**（实测 `schi.name`
/// = 李 明 / 小 敏 / chongwei stven），把它当兜底会让「装上了但闪退」变成常态，
/// 而不是**明确报错** —— 那比不做更糟。故只有服务端这一条路。
///
/// ## 实现（照爱思）
/// 复制 IPA 到临时目录（**绝不改 bundle 内原件**）→ `PackageSINFWriter.injectAllPaths`
/// 把 sinf 写进副本的 `SC_Info/*.sinf` → `IPAInstallService.installWithSINF` 装那份副本
/// （同一份 sinf 同时作为 `ApplicationSINF` 递交，与爱思「写进包再读回」等价）。
///
/// ## 诚实边界（写进返回值，不只在注释里）
/// - `Report.sinfSource` 恒为 `"server"`（本服务只有服务端这一条路）；
///   `Report.sinfAccountName` / `sinfAccountUser` 由 `schi` 解析得出
///   （让用户看到「这是谁的授权」）。
/// - `Report.launchVerified` **恒为 `false`**（本服务只做安装，不验证能否启动）。
/// - 日志走 `onLog` 闭包（不直接写 `LoginLogger`）；调用方可转发到
///   `LoginLogger.shared.log(_:category: .i4Fix)`。
///
/// ## 为什么是 `enum` + `static`（而非单例）
/// 底层 `IPAInstallService.shared`（`@unchecked Sendable`）与 `AppDiscovery` 各自管着 RSD
/// 串行队列；本服务自身**没有任何可变状态**，用 `static` 方法即可，避免引入需要
/// `nonisolated(unsafe)` 的非 Sendable 单例（Swift 6 严格并发）。调用方负责把阻塞调用放到后台线程.
enum I4MobileInstallService {

    // MARK: - 常量

    /// App bundle 内的资源目录名（`project.yml` 以 folder reference 打进 bundle，见其注释）.
    static let bundleDirectoryName = "I4Mobile"

    /// 导入兜底目录名（`Documents/I4Mobile/`；bundle 内缺失时按此回退）.
    static let importedDirectoryName = "I4Mobile"

    /// 爱思共享 Apple ID（三包 `iTunesMetadata` 的 `appleId`，见 `爱思9_安装移动端.md` §②）.
    static let sharedAccountEmail = "share_appleid003@163.com"

    /// 内嵌的 3 个「爱思移动端」IPA（移植材料，元数据见 `Resources/I4Mobile/README.md`）.
    ///
    /// `expectedBundleId` / `expectedVersion` 只用于**安装前后探测设备上的同名 App**；
    /// 实际安装用的 bundle id 以**包内 Info.plist** 为准（`install` 会先 `inspect` 取真值）.
    static let packs: [Pack] = [
        Pack(fileName: "217.ipa",   expectedBundleId: "rn.notes.best",      expectedVersion: "2.1.7"),
        Pack(fileName: "220.ipa",   expectedBundleId: "com.ownbook.notes",  expectedVersion: "2.2.0"),
        Pack(fileName: "photo.ipa", expectedBundleId: "com.MK.AwsomeFiles", expectedVersion: "1.5"),
    ]

    // MARK: - 模型

    /// 一个内嵌包（对应 `Resources/I4Mobile/` 里的一个 IPA）.
    struct Pack: Identifiable, Hashable, Sendable {
        /// 资源目录内的文件名（如 `217.ipa`）.
        let fileName: String
        /// 期望的 bundle id（用于探测设备上的同名 App；实际以包内 Info.plist 为准）.
        let expectedBundleId: String
        /// 期望版本（仅供参考，实际以包内 Info.plist 为准）.
        let expectedVersion: String
        var id: String { fileName }
    }

    /// `schi` 块解析结果（sinf 里描述「这份授权属于谁」）.
    struct SinfAccount: Sendable, Equatable {
        /// `schi.name`：账号显示名（如 `李 明`）.
        let name: String?
        /// `schi.user`：账号标识（4 字节，十六进制，如 `0xab6d95d8`）.
        let userHex: String?
        /// `schi.crdt`：凭据标识（4 字节，十六进制）.
        let crdtHex: String?
    }

    /// sinf 解析结果（内部用，不跨 `Report` 边界）.
    struct SinfResolution: Sendable {
        let sinf: Data
        let account: SinfAccount?
    }

    /// 内嵌包的**资源就位情况**（供 UI 展示；只查本地文件，不读设备）.
    struct PackStatus: Identifiable, Sendable {
        let pack: Pack
        /// 资源是否已就位（bundle 或导入目录里有该 IPA）.
        let present: Bool
        /// 来源：`"bundle"` / `"imported"` / `nil`（缺失）.
        let origin: String?
        var id: String { pack.fileName }
    }

    /// 设备侧探测快照（安装前/后各取一次；探测失败**不抛错**，如实记 `error`）.
    struct DeviceProbe: Sendable {
        /// 设备上已存在的**同名 bundle id** App 的版本（未安装则 `nil`）.
        let existingVersion: String?
        /// 探测失败原因（`nil` = 探测成功）.
        let error: String?
    }

    /// 一次安装的**如实结果**（不美化）.
    ///
    /// 诚实边界在这里显式暴露：`sinfSource`（恒为 `"server"`）/ `sinfAccountName`
    /// 让用户看到「用的是谁的授权」；`launchVerified` 恒为 `false`.
    struct Report: Sendable {
        let pack: Pack
        /// 原始资源 IPA 路径与大小.
        let ipaPath: String
        let ipaBytes: Int
        /// **实际安装的那份**临时副本路径（注入了 sinf；不改原件）.
        let workIPAPath: String
        /// sinf 来源：固定 `"server"`（本服务只有服务端这一条路）.
        let sinfSource: String
        /// sinf 的 `schi` 账号名 / user（解析出来展示；解析失败为 `nil`）.
        let sinfAccountName: String?
        let sinfAccountUser: String?
        /// 递交 installd 的 `sinf` 字节数.
        let sinfBytes: Int
        /// 实际写入包内的 sinf 路径（相对 IPA 根）.
        let injectedPaths: [String]
        /// 是否随包递交了 `iTunesMetadata`.
        let hasITunesMetadata: Bool
        /// 是否用 `Upgrade` 命令（覆盖安装）.
        let upgrade: Bool
        /// 包内 Info.plist 读到的 bundle id / 版本（读不出则回退期望值）.
        let bundleId: String
        let bundleVersion: String
        /// 安装前 / 后设备探测.
        let before: DeviceProbe
        let after: DeviceProbe
        /// 安装后设备上是否出现该 bundle id（回读确认；探测失败时为 `nil`）.
        let installedConfirmed: Bool?
        /// **恒为 `false`**：本服务不验证包能否在本机启动.
        let launchVerified: Bool
        /// 启动风险提示：安装后未在设备上回读到时为 `true`.
        let mayCrashAtLaunch: Bool
        /// 如实的补充说明（逐条事实 + 边界）.
        let notes: [String]
        /// 一句话结论（含边界）.
        let verdict: String
    }

    // MARK: - 错误

    enum I4MobileError: LocalizedError {
        /// 资源缺失（bundle 与导入目录都没有该 IPA）.
        case packResourceMissing(String)
        /// 服务端取 sinf 失败（缺 store id / 服务端没回 sinf / 结构不合法）.
        case serverSinfUnavailable(reason: String)
        /// 复制工作副本失败（临时目录 / 复制 IPA）.
        case workCopyFailed(String)
        /// 把 sinf 写进副本失败.
        case sinfInjectFailed(String)

        var errorDescription: String? {
            switch self {
            case .packResourceMissing(let name):
                return "找不到内嵌 IPA \(name)：App 资源目录（\(bundleDirectoryName)/）与导入目录都没有该文件."
            case .serverSinfUnavailable(let reason):
                return "服务端未取到可用的 sinf：\(reason)"
            case .workCopyFailed(let reason):
                return "准备工作副本失败：\(reason)"
            case .sinfInjectFailed(let reason):
                return "把 sinf 写进安装包副本失败：\(reason)"
            }
        }
    }

    // MARK: - ① 列包 / 定位资源

    /// App bundle 内的资源目录（folder reference，见 `project.yml`）.
    static func bundleDirectory() -> URL? {
        Bundle.main.url(forResource: bundleDirectoryName, withExtension: nil)
    }

    /// 导入兜底目录 `Documents/I4Mobile/`（bundle 内缺失时用）.
    static func importedDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(importedDirectoryName, isDirectory: true)
    }

    /// 定位包资源：App bundle 内 `I4Mobile/` 优先，其次导入目录 `Documents/I4Mobile/`.
    /// 都没有则返回 `nil`（调用方抛 `packResourceMissing`）.
    static func resolveURL(for pack: Pack) -> URL? {
        if let dir = bundleDirectory() {
            let url = dir.appendingPathComponent(pack.fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let imported = importedDirectory().appendingPathComponent(pack.fileName)
        if FileManager.default.fileExists(atPath: imported.path) { return imported }
        return nil
    }

    /// 列出内嵌包 + 各自资源是否就位（供 UI 展示；不读设备）.
    static func packStatuses() -> [PackStatus] {
        let bundleDir = bundleDirectory()
        let importedDir = importedDirectory()
        return packs.map { pack in
            let inBundle = bundleDir.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(pack.fileName).path)
            } ?? false
            let inImported = FileManager.default.fileExists(
                atPath: importedDir.appendingPathComponent(pack.fileName).path)
            let origin: String? = inBundle ? "bundle" : (inImported ? "imported" : nil)
            return PackStatus(pack: pack, present: origin != nil, origin: origin)
        }
    }

    // MARK: - ② 安装（定 sinf 来源 → 复制副本 → 注入 → 装副本 → 如实报告）

    /// 安装一个内嵌包（移植自爱思 PC 端：**往包里写服务端 sinf，再装那个包**）.
    ///
    /// 流程（每步失败**必抛**，不静默）：
    ///   ① 定位 IPA（bundle → 导入目录）；缺失即 `packResourceMissing`.
    ///   ② `inspect` 读包内真值；`extractiTunesMetadata` 取 metadata（供 store id 与安装选项）.
    ///   ③ **向服务端现取 sinf**（`NBStoreClient.packageByVersion`）；取不到即
    ///      `serverSinfUnavailable`（**明确失败，不回退到包内自带**）.
    ///   ④ **复制 IPA 到临时目录**（绝不改 bundle 内原件）；复制失败即 `workCopyFailed`.
    ///   ⑤ `PackageSINFWriter.injectAllPaths` 把 sinf 写进副本；失败即 `sinfInjectFailed`.
    ///   ⑥ `IPAInstallService.installWithSINF` 装**副本**（同一份 sinf 作 `ApplicationSINF`）；
    ///      安装失败**原样抛出**（含 `ApplicationVerificationFailed` 等）.
    ///   ⑦ 安装后回读设备，组装 `Report`（含 sinf 账号名等诚实边界）.
    ///
    /// - Parameters:
    ///   - pack: 要安装的内嵌包（见 `packs`）.
    ///   - allowUpgrade: `true` = 用 `Upgrade` 命令覆盖安装（同 bundle id 已存在时）.
    ///   - progress: 整条链 0~1 的进度回调（AFC 上传段 0~0.75 + installd 段 0.75~1）.
    ///   - onLog: 逐条事实日志回调（调用方可转发到 `LoginLogger`）.
    /// - Returns: `Report`（含 `sinfSource="server"` / `sinfAccountName` / `launchVerified=false` 等）.
    /// - Throws: `I4MobileError` 或底层安装错误.
    @discardableResult
    static func install(pack: Pack,
                        allowUpgrade: Bool = false,
                        progress: (@Sendable (Double) -> Void)? = nil,
                        onLog: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        // ① 定位资源.
        guard let url = resolveURL(for: pack) else {
            throw I4MobileError.packResourceMissing(pack.fileName)
        }
        let ipaPath = url.path
        let ipaBytes = fileSize(at: ipaPath)
        onLog?("[i4移动端] 定位 \(pack.fileName)：\(originLabel(for: url)) · \(ipaBytes / 1024 / 1024) MB")

        // ② 检测包 + 取 metadata（metadata 既作安装选项，也用于服务端取 sinf 的 store id）.
        let inspection = IPAPackageInspector.inspect(ipaPath: ipaPath)
        let bundleId = inspection?.bundleIdentifier ?? pack.expectedBundleId
        let bundleVersion = inspection?.bundleVersion ?? pack.expectedVersion
        if let inspection {
            onLog?("[i4移动端] 包信息：\(bundleId) \(bundleVersion) · \(inspection.summary)")
        } else {
            onLog?("[i4移动端] 包信息读不出（主二进制 / Info.plist 解析失败），按文件名 \(pack.fileName) 继续")
        }
        let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: ipaPath)
        onLog?("[i4移动端] 包内 iTunesMetadata：\(meta != nil ? "有" : "无")")

        // ③ 向服务端现取 sinf（只有这一条路；取不到即明确失败，不回退到包内自带）.
        let resolved = try await serverSinf(bundleId: bundleId, metadata: meta, onLog: onLog)
        onLog?("[i4移动端] sinf 来源：服务端现取 · \(resolved.sinf.count) 字节"
               + accountLogSuffix(resolved.account))

        // ④ 复制到临时目录（原件只读，绝不被改写）.
        let workURL = try makeWorkCopy(of: url, fileName: pack.fileName)
        defer { try? FileManager.default.removeItem(at: workURL.deletingLastPathComponent()) }
        onLog?("[i4移动端] 已复制工作副本：\(workURL.lastPathComponent)")

        // ⑤ 把 sinf 写进副本（照爱思：覆盖 SC_Info/*.sinf）.
        let injected: [String]
        do {
            injected = try PackageSINFWriter.injectAllPaths(sinf: resolved.sinf, ipaPath: workURL.path)
        } catch {
            throw I4MobileError.sinfInjectFailed(error.localizedDescription)
        }
        onLog?("[i4移动端] 已把 sinf 写进副本 \(injected.count) 条路径：\(injected.joined(separator: ", "))")

        // ⑥ 安装前探测（best-effort，失败不阻断）.
        let before = await probeDevice(bundleId: bundleId)
        logProbe(before, phase: "安装前", onLog: onLog)

        // ⑦ 安装副本（同一份 sinf 作 ApplicationSINF；阻塞调用放后台）.
        onLog?("[i4移动端] 经 ApplicationSINF 通道安装副本"
               + "（PackageType=Customer, upgrade=\(allowUpgrade)）…")
        let svc = IPAInstallService.shared
        let workPath = workURL.path
        let sinf = resolved.sinf
        try await Task.detached(priority: .userInitiated) {
            try svc.installWithSINF(workPath,
                                    sinf: sinf,
                                    iTunesMetadata: meta,
                                    upgrade: allowUpgrade,
                                    progress: { p in progress?(p) })
        }.value
        onLog?("[i4移动端] installd 已受理安装")

        // ⑧ 安装后回读.
        let after = await probeDevice(bundleId: bundleId)
        logProbe(after, phase: "安装后", onLog: onLog)

        // ⑨ 组装报告.
        let report = buildReport(pack: pack, ipaPath: ipaPath, ipaBytes: ipaBytes,
                                 workIPAPath: workPath, resolution: resolved,
                                 injectedPaths: injected, hasITunesMetadata: meta != nil,
                                 upgrade: allowUpgrade, bundleId: bundleId, bundleVersion: bundleVersion,
                                 before: before, after: after)
        onLog?("[i4移动端] 结论：\(report.verdict)")
        return report
    }

    /// 依次安装全部内嵌包（顺序 = `packs`）.
    ///
    /// 诚实边界：**任一步失败即抛错**，不静默跳过后续包 —— 与 `install` 的「每步失败必抛」一致.
    /// 已成功安装的包**不会回滚**（installd 无批量事务）；调用方按返回数组自行处置.
    @discardableResult
    static func installAll(allowUpgrade: Bool = false,
                           progress: (@Sendable (Double) -> Void)? = nil,
                           onLog: (@Sendable (String) -> Void)? = nil) async throws -> [Report] {
        var reports: [Report] = []
        for (idx, pack) in packs.enumerated() {
            onLog?("[i4移动端] (\(idx + 1)/\(packs.count)) 安装 \(pack.fileName)")
            let report = try await install(pack: pack, allowUpgrade: allowUpgrade,
                                           progress: progress, onLog: onLog)
            reports.append(report)
        }
        return reports
    }

    // MARK: - ③ UI 对接（`I4MobileInstallView.installAction`）

    /// 生成与 `I4MobileInstallView.installAction`（`() async throws -> Void`）匹配的动作：
    /// **安装全部内嵌包**.
    ///
    /// 注：闭包体内用 `_ =` 显式丢弃 `[Report]` 返回值，让闭包返回类型确定为 `Void`
    /// （单表达式闭包会把返回类型推断成 `[Report]`，与 UI 期望的 `Void` 不符）.
    static func makeInstallAllAction(allowUpgrade: Bool = false,
                                     progress: (@Sendable (Double) -> Void)? = nil,
                                     onLog: (@Sendable (String) -> Void)? = nil) -> () async throws -> Void {
        return {
            _ = try await installAll(allowUpgrade: allowUpgrade,
                                     progress: progress, onLog: onLog)
        }
    }

    /// 生成只安装指定包的动作用于 UI.
    static func makeInstallAction(pack: Pack,
                                  allowUpgrade: Bool = false,
                                  progress: (@Sendable (Double) -> Void)? = nil,
                                  onLog: (@Sendable (String) -> Void)? = nil) -> () async throws -> Void {
        return {
            _ = try await install(pack: pack, allowUpgrade: allowUpgrade,
                                  progress: progress, onLog: onLog)
        }
    }

    // MARK: - ④ 向服务端现取 sinf（只有这一条路）

    /// 向 NB 服务端按版本现取 sinf.
    ///
    /// 取不到（无 metadata / 缺 store id / 服务端没回 sinf / 结构不合法）一律抛
    /// `serverSinfUnavailable` —— **不回退到包内自带**（包内 sinf 属原始购买者，
    /// 用它会把「装上但闪退」变成常态）.
    private static func serverSinf(bundleId: String, metadata: Data?,
                                   onLog: (@Sendable (String) -> Void)?) async throws -> SinfResolution {
        guard let metadata else {
            throw I4MobileError.serverSinfUnavailable(reason: "包内无 iTunesMetadata，拿不到 itemId / appVerId")
        }
        let identity = storeIdentity(from: metadata)
        guard let itemId = identity.itemId, let appVerId = identity.appVerId else {
            throw I4MobileError.serverSinfUnavailable(
                reason: "metadata 缺 store id（itemId=\(identity.itemId ?? "无") appVerId=\(identity.appVerId ?? "无")）")
        }
        onLog?("[i4移动端] 向服务端取 sinf：appID=\(itemId) appVerId=\(appVerId)")
        let pkg = try await NBStoreClient.packageByVersion(appID: itemId, appVerId: appVerId,
                                                            bundleID: bundleId)
        guard let b64 = pkg?.sinfBase64, !b64.isEmpty else {
            throw I4MobileError.serverSinfUnavailable(reason: "服务端响应未含 sinf")
        }
        guard let data = Data(base64Encoded: b64), PackageSINFWriter.isStructurallyValidSinf(data) else {
            throw I4MobileError.serverSinfUnavailable(reason: "服务端 sinf 不是合法 base64 / 结构不合法")
        }
        return SinfResolution(sinf: data, account: parseSinfAccount(data))
    }

    /// 从 `iTunesMetadata.plist` 读 `itemId`（trackId）与 `softwareVersionExternalIdentifier`.
    static func storeIdentity(from metadata: Data) -> (itemId: String?, appVerId: String?) {
        guard let plist = try? PropertyListSerialization.propertyList(from: metadata, options: [], format: nil),
              let dict = plist as? [String: Any] else { return (nil, nil) }
        return (stringValue(dict["itemId"]),
                stringValue(dict["softwareVersionExternalIdentifier"]))
    }

    // MARK: - ⑤ schi 解析（sinf 里「这份授权属于谁」）

    /// 解析 sinf 里的 `schi` 块，取账号名 / user / crdt.
    ///
    /// ## 结构（TLV 块式）
    /// 顶层：`{4B 大端总长}` + `"sinf"` + 块序列；每块 `{4B 大端块长}{4B tag}{body}`
    /// （**块长含 8 字节头**；前 4 字节是**长度**不是固定魔数）。顶层块为
    /// `frma / schm / schi / sign`。`schi` 的 body 同样是**裸子块序列**，其中：
    ///   · `user`：4 字节账号标识；`crdt`：4 字节凭据标识；`name`：UTF-8 定长、NUL 补齐.
    /// 实测（本仓 `Resources/I4Mobile/` 三包）：`217 → 李 明 / 0xab6d95d8`，
    /// `220 → 小 敏 / 0xa775eea7`，`photo → chongwei stven / 0xab5c9f49`.
    ///
    /// - Returns: 解析结果；非 sinf 结构 / 无 `schi` 时为 `nil`.
    static func parseSinfAccount(_ sinf: Data) -> SinfAccount? {
        let b = [UInt8](sinf)
        guard b.count >= 8, Array(b[4..<8]) == Array("sinf".utf8),
              let schiSlice = chunkBody(b, from: 8, to: b.count, tag: "schi") else { return nil }
        let schi = Array(schiSlice)
        var name: String?
        if let body = chunkBody(schi, from: 0, to: schi.count, tag: "name") {
            name = String(bytes: body.prefix { $0 != 0 }, encoding: .utf8)
        }
        let user = chunkBody(schi, from: 0, to: schi.count, tag: "user").map(hexString)
        let crdt = chunkBody(schi, from: 0, to: schi.count, tag: "crdt").map(hexString)
        return SinfAccount(name: name, userHex: user, crdtHex: crdt)
    }

    /// 在 `{4B 块长}{4B tag}{body}` 块序列里找第一个 tag 匹配块的 body.
    private static func chunkBody(_ b: [UInt8], from start: Int, to end: Int,
                                  tag: String) -> ArraySlice<UInt8>? {
        let tagBytes = Array(tag.utf8)
        var off = start
        while off + 8 <= end {
            let len = Int(be32(b, off))
            guard len >= 8, off + len <= end else { break }
            if Array(b[(off + 4)..<(off + 8)]) == tagBytes {
                return b[(off + 8)..<(off + len)]
            }
            off += len
        }
        return nil
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16)
             | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private static func hexString(_ bytes: ArraySlice<UInt8>) -> String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 内部

    /// 复制 IPA 到唯一临时目录，返回副本 URL（调用方负责删除其父目录）.
    private static func makeWorkCopy(of url: URL, fileName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("I4MobileWork-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw I4MobileError.workCopyFailed(error.localizedDescription)
        }
        let dst = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw I4MobileError.workCopyFailed(error.localizedDescription)
        }
        return dst
    }

    /// 设备探测（best-effort）：读已装应用 → 同名 App 版本；失败如实记 error.
    ///
    /// 阻塞调用（建 RSD 隧道 + instproxy 枚举），放后台；只把纯值（`DeviceProbe`）带回边界，
    /// 非 Sendable 的 `AppDiscovery` / `[InstalledApp]` 不跨边界.
    static func probeDevice(bundleId: String) async -> DeviceProbe {
        await Task.detached(priority: .utility) {
            do {
                let apps = try AppDiscovery().fetchInstalledApps()
                let existing = apps.first { $0.bundleIdentifier == bundleId }?.version
                return DeviceProbe(existingVersion: existing, error: nil)
            } catch {
                return DeviceProbe(existingVersion: nil, error: error.localizedDescription)
            }
        }.value
    }

    /// 组装如实报告（含 sinf 账号名等诚实边界与启动风险）.
    private static func buildReport(pack: Pack, ipaPath: String, ipaBytes: Int,
                                    workIPAPath: String, resolution: SinfResolution,
                                    injectedPaths: [String], hasITunesMetadata: Bool, upgrade: Bool,
                                    bundleId: String, bundleVersion: String,
                                    before: DeviceProbe, after: DeviceProbe) -> Report {
        // 安装后回读确认（探测失败 = nil，不当成「没装上」）.
        let confirmed: Bool? = after.error != nil ? nil : (after.existingVersion != nil)

        var notes: [String] = []
        notes.append("sinf 来源：服务端现取并覆盖包内（本服务只有这一条路）.")
        if let account = resolution.account {
            notes.append("sinf 的 schi.name=\(account.name ?? "?")，schi.user=\(account.userHex ?? "?")，"
                         + "schi.crdt=\(account.crdtHex ?? "?")：这是该授权所属的账号.")
        } else {
            notes.append("sinf 的 schi 未解析出账号信息（结构可能非标准）.")
        }
        notes.append("sinf 由服务端按版本现取并覆盖包内；是否已授权本机仍无法验证.")
        notes.append("本服务只做安装，不验证启动：install 成功不等于能启动.")
        if confirmed == false {
            notes.append("安装后未在设备上回读到该 bundle id（\(bundleId)），"
                         + "可能安装未落盘，或探测不可靠（隧道 / 权限）.")
        }

        let mayCrash = (confirmed == false)
        let verdict: String
        if confirmed == false {
            verdict = "已向 installd 递交安装，但未回读到该 App，安装结果存疑."
        } else {
            verdict = "已安装 \(bundleId) \(bundleVersion)，sinf 来自服务端；启动未验证."
        }

        return Report(pack: pack, ipaPath: ipaPath, ipaBytes: ipaBytes, workIPAPath: workIPAPath,
                      sinfSource: "server",
                      sinfAccountName: resolution.account?.name,
                      sinfAccountUser: resolution.account?.userHex,
                      sinfBytes: resolution.sinf.count, injectedPaths: injectedPaths,
                      hasITunesMetadata: hasITunesMetadata, upgrade: upgrade,
                      bundleId: bundleId, bundleVersion: bundleVersion,
                      before: before, after: after,
                      installedConfirmed: confirmed,
                      launchVerified: false, mayCrashAtLaunch: mayCrash,
                      notes: notes, verdict: verdict)
    }

    /// 把探测结果写进日志（只写事实，不解释）.
    private static func logProbe(_ probe: DeviceProbe, phase: String,
                                 onLog: (@Sendable (String) -> Void)?) {
        if let error = probe.error {
            onLog?("[i4移动端] \(phase)探测失败：\(error)")
            return
        }
        onLog?("[i4移动端] \(phase)探测：同名 App 版本=\(probe.existingVersion ?? "未安装")")
    }

    /// 账号信息拼成日志后缀（无解析结果时为空串）.
    private static func accountLogSuffix(_ account: SinfAccount?) -> String {
        guard let account else { return "" }
        return " · schi.name=\(account.name ?? "?") schi.user=\(account.userHex ?? "?")"
    }

    /// 资源来源标签（`bundle` / `imported`），用于日志.
    private static func originLabel(for url: URL) -> String {
        if let dir = bundleDirectory(), url.path.hasPrefix(dir.path) { return "bundle" }
        return "imported"
    }

    /// plist 值为字符串 / 数字时统一成字符串.
    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    /// 文件大小（读不到返回 0）.
    private static func fileSize(at path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
