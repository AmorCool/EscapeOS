import Foundation

/// 爱思「应用修复安装」服务层（**只做逻辑，不含 UI**）.
///
/// ## 移植范围（严格限定，照设计报告《设计_爱思应用修复安装.md》）
/// 只复刻爱思修复链里的 **「经 AFC 写设备 `/iTunes_Control/iTunes/i4tool2.acc` + 读回校验」**
/// 这一段（设计报告 §①：可移植 = A 入口 + B 设备身份 + D 落盘①）。**不移植**：
///   - 联网 `XX-AUTH` 授权：协议在 `idm_sync.dll` + 爱思服务端，iOS 侧拿不到（设计报告 §1.2 A/C）；
///   - 代理 App 容器里的 `AppInstall_SyncInfo.dat`：落点是 FairPlay 马甲包容器、读者不在我们手里
///     （设计报告 §1.1′ / §④，本轮不做）；
///   - 「兜底安装代理 App」：代理 App 是 FairPlay 加密马甲包，我们装不了（设计报告 §1.3）。
///
/// ## `auth` 字段
/// 用 i4 自己的硬编码兜底 `"1,2,3,4"`（设计报告 §1.2 选项 B）。**能写、效用未证实** ——
/// 设备端读者是爱思代理 App，大概率不在本机；本服务在**返回值**里如实标注，不承诺「能修好」。
///
/// ## 诚实边界（写进返回值，不只在注释里）
/// - 本服务**不能**解 App Store 加密包的 `-42112`：`i4tool2.acc` 是爱思私有 plist，
///   iOS/installd/fairplay **不读它**，其内容**不含 FairPlay 密钥**（机制报告 §1.5 / §4.1）。
///   ⇒ `Report.canResolveFairPlay42112` 恒为 `false`。
/// - 写入分支**默认关**（`allowWrite: Bool = false`）：默认只做「读 + 展示」，零副作用。
/// - 效用**未证实** ⇒ `Report.effectVerified` 恒为 `false`。
///
/// ## 为什么是 `enum` + `static` 方法（而非单例）
/// 底层 `AFCService.shared` / `DeviceInfoService` 都是**同步阻塞**且各自管着自己的 RSD 串行队列；
/// 本服务自身**没有任何可变状态**，用 `static` 方法即可，避免引入需要 `nonisolated(unsafe)` 的
/// 非 Sendable 单例（Swift 6 严格并发）。调用方负责把阻塞调用放到后台线程.
enum I4AppFixService {

    // MARK: - 常量（照机制报告《爱思9_i4tool2acc机制.md》§1.2 A）

    /// 设备侧落盘路径（AFC 根 = `/var/mobile/media`，故此处不带前导斜杠；
    /// 与 `RingtonesService.ringtonesPlistAFCPath` 同款口径）.
    static let accAFCPath = "iTunes_Control/iTunes/i4tool2.acc"

    /// `cid` 常量 —— 爱思固定分发渠道号（机制报告 §1.4，VA `0x14116be24`）.
    static let cidConstant = "700000"

    /// `auth` 硬编码兜底 —— i4 在「sync 成功但输出为空」时写的值（机制报告 §1.3，VA `0x14116c148`）.
    /// **不是**服务端 `XX-AUTH` 签发的真值（那份拿不到）.
    static let authFallback = "1,2,3,4"

    /// 爱思移动端（代理 App）bundle id 候选（9 个）.
    ///
    /// 来源：`调研_爱思移动端IPA来源.md` §1.2 / §27 —— 6 个「代理 App」+ 并列出现的 3 个
    /// （`com.a.emoji` 已在 6 个里，故并集为 9）.
    /// **用途**：只做「本机是否装了读者」的**检测**（缺失则警告），不参与写入.
    ///
    /// 注：`com.MK.AwsomeFiles`（`photo.ipa`，照片处理工具）同属该家族但证据较弱，未计入这 9 个.
    static let i4MobileBundleIds: Set<String> = [
        "com.ownbook.notes",
        "rn.notes.best",
        "com.pd.A4Player",
        "com.diary.mood",
        "com.a.emoji",
        "com.best.vaultnotes",
        "com.i4.picture",
        "com.aswallpaper.mito",
        "com.aisi.aisiring",
    ]

    // MARK: - 错误

    enum I4FixError: LocalizedError {
        /// 必填身份键缺失（serial / udid）—— 拒绝写入，宁可不写也不写一个身份残缺的授权文件.
        case identityIncomplete([String])
        /// AFC 写入失败 —— 原样带上底层错误，**不静默**.
        case writeFailed(String, Error)
        /// plist 构造失败.
        case plistBuildFailed(String)

        var errorDescription: String? {
            switch self {
            case .identityIncomplete(let fields):
                return "设备身份不完整，缺少必填键 \(fields.joined(separator: ", "))，已拒绝写入."
            case .writeFailed(let path, let underlying):
                return "写入 \(path) 失败：\(underlying.localizedDescription)"
            case .plistBuildFailed(let reason):
                return "构造 i4tool2.acc plist 失败：\(reason)"
            }
        }
    }

    // MARK: - 模型

    /// 候选 App 的命中来源（两条识别路径取并集，各带诚实口径）.
    enum MatchSource: String {
        /// P1：本 App 的爱思源下载台账里有该 bundleId（覆盖「经本 App 下载过」的包）.
        case downloadLedger = "下载台账"
        /// P2：已安装 App 的购买邮箱属于爱思共享账号白名单（覆盖「任何用爱思共享账号签的包」）.
        case sharedAccount = "共享账号"
    }

    /// 一个候选 App（设备上「疑似爱思源安装」的应用）.
    struct Candidate: Identifiable, Hashable {
        var bundleId: String
        var name: String
        var version: String?
        var iconURL: String?
        /// 命中的识别路径（可能两条都命中）.
        var matchedBy: Set<MatchSource>

        var id: String { bundleId }

        /// 仅由 P2（共享账号）命中 —— 白名单口径未证实 100% 等价于「爱思源安装」，界面上标「疑似」.
        var isSuspected: Bool { matchedBy == [.sharedAccount] }
    }

    /// 设备身份（供构造 plist 与 UI 展示）；每个字段可空 = 该来源这次没读到，**不编默认值**.
    struct DeviceIdentity {
        var serial: String?
        var imei: String?
        var productiondate: String?
        var region: String?
        var modelnumber: String?
        var udid: String?

        /// 写入前必填的键（设计报告 §③：serial / udid 为空则拒绝写入）.
        var missingRequiredFields: [String] {
            var missing: [String] = []
            if (serial ?? "").isEmpty { missing.append("serial") }
            if (udid ?? "").isEmpty { missing.append("udid") }
            return missing
        }

        /// 8 个 plist 键各自的**取值与来源**（供 UI / 简报展示；来源逐条写清）.
        ///
        /// 读得到的：`serial` / `region` / `modelnumber` / `udid` 来自 lockdown 根字典；
        /// `imei` 来自 lockdown（WiFi 机型 / 无基带时为 nil）；`productiondate` 由**本地**解码器算
        /// （不联网、不外发）；`auth` / `cid` 是常量.
        var fieldSources: [(key: String, value: String?, source: String)] {
            [
                ("auth", I4AppFixService.authFallback,
                 "常量：i4 无网兜底值（服务端 XX-AUTH 应答拿不到）"),
                ("serial", serial, "lockdown SerialNumber"),
                ("imei", imei, "lockdown InternationalMobileEquipmentIdentity"),
                ("productiondate", productiondate,
                 "本地解码：DeviceSerialDate.productionDate(from: mlbSerial)"),
                ("region", region, "lockdown RegionInfo（parseRegion 截断 16 字符）"),
                ("modelnumber", modelnumber, "lockdown ModelNumber"),
                ("udid", udid, "lockdown UniqueDeviceID"),
                ("cid", I4AppFixService.cidConstant, "常量：700000（爱思固定分发渠道号）"),
            ]
        }
    }

    /// 读到的 `i4tool2.acc` 内容（键值对，按 key 排序；含字节数与格式）.
    struct AccContent {
        let entries: [(key: String, value: String)]
        let byteCount: Int
        /// `"xml"` / `"binary"` / `"unknown"`（按首字节判定）.
        let format: String

        var dictionary: [String: String] {
            Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        var keys: [String] { entries.map(\.key) }
    }

    /// 一次「修复」的**如实结果**（不美化）.
    ///
    /// 诚实边界在这里显式暴露：`canResolveFairPlay42112` 与 `effectVerified` 恒为 `false`，
    /// 让 UI 层无法把它当成「修好了」来展示.
    struct Report {
        let identity: DeviceIdentity
        /// 请求写入（= 传入的 `allowWrite`）.
        let writeRequested: Bool
        /// 是否真的写了（`writeRequested == false` 时恒为 `false`）.
        let didWrite: Bool
        let writePath: String
        let bytesWritten: Int?
        /// 读回内容：写入分支 = 写后读回；只读分支 = 设备上现有的（不存在则 nil）.
        let readBack: AccContent?
        /// 写后读回是否与写入内容一致（只读分支为 nil）.
        let readBackMatchesWritten: Bool?
        /// 本机检测到的爱思代理 App bundle id（没有则 nil）.
        let proxyAppBundleId: String?
        /// 未写入的原因（只读分支）.
        let notWrittenReason: String?
        /// 如实的补充说明（逐条事实 + 边界）.
        let notes: [String]
        /// 一句话结论（含边界）.
        let verdict: String
        /// **恒为 false**：本功能不能解 App Store 加密包的 `-42112`.
        let canResolveFairPlay42112: Bool
        /// **恒为 false**：效用未证实（读者是设备端爱思代理 App，不在我们手里）.
        let effectVerified: Bool
    }

    // MARK: - 前置条件（事实查询，供 UI 常驻提示）

    /// 本地隧道是否已连接（`LocalDevVPN.isConnected`，不假设网段）.
    static var isTunnelConnected: Bool { LocalDevVPN.isConnected }

    /// 配对文件是否已导入（与 `AFCService` 同一路径口径）.
    static var hasPairingFile: Bool {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - ① 列出候选 App（P1 台账 × P2 白名单，取并集）

    /// 列出设备上「疑似爱思源安装」的 App.
    ///
    /// - Parameter installed: 已安装应用列表（由 `AppDiscovery.fetchInstalledApps()` 取得；调用方传入，
    ///   使本方法保持纯逻辑、不自己建隧道）.
    /// - Note: 会读 `IPADownloadLibrary.shared.items()`（下载台账）. 该方法按既有约定在主线程调用.
    static func candidates(installed: [InstalledApp]) -> [Candidate] {
        let ledger = IPADownloadLibrary.shared.items()
        let i4Source = IPADownloadCenter.Source.i4Free.rawValue

        // P1：爱思源台账里的 bundleId → 图标地址（顺带把图标回填给候选）.
        var ledgerIcons: [String: String] = [:]
        var ledgerBundleIds: Set<String> = []
        for item in ledger where item.source == i4Source {
            guard let bundleId = item.bundleId, !bundleId.isEmpty else { continue }
            ledgerBundleIds.insert(bundleId)
            if let icon = item.iconURL, !icon.isEmpty, ledgerIcons[bundleId] == nil {
                ledgerIcons[bundleId] = icon
            }
        }

        var result: [Candidate] = []
        for app in installed {
            var matched: Set<MatchSource> = []
            if ledgerBundleIds.contains(app.bundleIdentifier) {
                matched.insert(.downloadLedger)
            }
            // P2：购买邮箱 ∈ 爱思共享账号白名单（用 AppTypeDetector 的既有口径判定）.
            let type = AppTypeDetector.detect(
                entitlements: [:],
                applicationType: app.applicationType,
                iTunesAppleID: app.iTunesAppleID,
                hasITunesMetadata: app.hasITunesMetadata
            )
            if type == .appStoreShared {
                matched.insert(.sharedAccount)
            }
            guard !matched.isEmpty else { continue }
            result.append(Candidate(
                bundleId: app.bundleIdentifier,
                name: app.name,
                version: app.version,
                iconURL: ledgerIcons[app.bundleIdentifier],
                matchedBy: matched
            ))
        }

        let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        LoginLogger.shared.log(
            "[i4修复] 候选 \(sorted.count) 个（台账命中 \(sorted.filter { $0.matchedBy.contains(.downloadLedger) }.count)，"
            + "共享账号命中 \(sorted.filter { $0.matchedBy.contains(.sharedAccount) }.count)），"
            + "bundleIds=\(sorted.map(\.bundleId).joined(separator: ","))",
            category: .i4Fix)
        return sorted
    }

    /// 本机是否装了爱思代理 App（读者强候选）；返回命中的 bundle id，没有则 nil.
    static func proxyAppBundleId(in installed: [InstalledApp]) -> String? {
        installed.first { i4MobileBundleIds.contains($0.bundleIdentifier) }?.bundleIdentifier
    }

    // MARK: - ② 读回设备上现有的 i4tool2.acc

    /// 读设备上现有的 `/iTunes_Control/iTunes/i4tool2.acc` 并解析.
    /// 文件不存在返回 `nil`（不是错误）；读失败（隧道/权限）**抛错**，不静默.
    static func readExistingAcc() throws -> AccContent? {
        // 先点查存在性：`statFile` 是单条 `afc_get_file_info`，不受 AFC 根沙盒挡住（见 AFCService 注释）.
        let stat = try AFCService.shared.batch { client in
            AFCService.statFile(client: client, path: accAFCPath)
        }
        guard stat.exists else {
            LoginLogger.shared.log("[i4修复] 设备上不存在 \(accAFCPath)（stat: \(stat.describe)）",
                                   category: .i4Fix)
            return nil
        }
        let data = try AFCService.shared.readFile(accAFCPath)
        let content = parseAcc(data)
        LoginLogger.shared.log(
            "[i4修复] 读回 \(accAFCPath)：\(data.count) bytes, format=\(content.format), "
            + "keys=\(content.keys.joined(separator: ","))",
            category: .i4Fix)
        return content
    }

    /// 解析 plist 字节 → 键值对（兼容 xml / binary；解不出时 entries 为空，不抛错）.
    static func parseAcc(_ data: Data) -> AccContent {
        let format = accFormat(data)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return AccContent(entries: [], byteCount: data.count, format: format)
        }
        let entries = dict
            .map { (key: $0.key, value: Self.stringValue($0.value)) }
            .sorted { $0.key < $1.key }
        return AccContent(entries: entries, byteCount: data.count, format: format)
    }

    // MARK: - ③ 构造 plist（8 键）

    /// 按设备身份构造修复路径的 8 键字典（机制报告 §1.2 A）.
    /// 缺失的可选键写空串（不编造值）；`serial` / `udid` 的缺失由调用方在写入前硬拒绝.
    static func accDictionary(_ identity: DeviceIdentity) -> [String: String] {
        [
            "auth": authFallback,
            "serial": identity.serial ?? "",
            "imei": identity.imei ?? "",
            "productiondate": identity.productiondate ?? "",
            "region": identity.region ?? "",
            "modelnumber": identity.modelnumber ?? "",
            "udid": identity.udid ?? "",
            "cid": cidConstant,
        ]
    }

    /// 构造 plist 字节（xml 格式；读回解析对 xml / binary 都兼容）.
    static func makeAccData(_ identity: DeviceIdentity) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: accDictionary(identity), format: .xml, options: 0)
        } catch {
            throw I4FixError.plistBuildFailed(String(describing: error))
        }
    }

    // MARK: - ④ 设备身份

    /// 读设备身份（一次 `DeviceInfoService.collectFull()`，字段来源见 `DeviceIdentity.fieldSources`）.
    ///
    /// - Note: 阻塞调用（建 RSD 隧道 + 读 lockdown 整棵字典），调用方放到后台线程.
    static func deviceIdentity() throws -> DeviceIdentity {
        let model = try DeviceInfoService.collectFull()
        // productiondate 由**本地**解码器算（`DeviceSerialDate`，纯整数、不联网、不外发设备标识）.
        let productiondate = model.mlbSerial.flatMap { DeviceSerialDate.productionDate(from: $0) }
        let identity = DeviceIdentity(
            serial: model.serialNumber,
            imei: model.imei,
            productiondate: productiondate,
            region: model.region,
            modelnumber: model.modelNumber,
            udid: model.udid
        )
        // 日志只写事实（各字段是否读到 + 值）；为何用本地解码器见上方注释.
        LoginLogger.shared.log(
            "[i4修复] 设备身份：serial=\(identity.serial ?? "nil"), udid=\(identity.udid ?? "nil"), "
            + "imei=\(identity.imei ?? "nil"), region=\(identity.region ?? "nil"), "
            + "modelnumber=\(identity.modelnumber ?? "nil"), productiondate=\(identity.productiondate ?? "nil"), "
            + "mlbSerial=\(model.mlbSerial ?? "nil")",
            category: .i4Fix)
        return identity
    }

    // MARK: - ⑤ 修复（读 + 可选写 + 读回校验）

    /// 执行一次「修复」.
    ///
    /// - Parameters:
    ///   - allowWrite: **写入开关，默认关**. `false` = 只读 + 展示（确定可交付、零副作用）；
    ///     `true` = 构造 8 键 plist → 经 AFC 写设备 → 写后读回比对（实验性，效用未证实）.
    ///   - installedApps: 已安装应用列表，用于检测本机是否装了爱思代理 App（读者）.
    /// - Returns: `Report`（含读回内容与诚实边界；`canResolveFairPlay42112` / `effectVerified` 恒 false）.
    /// - Throws: 身份读取失败、必填键缺失（`allowWrite == true` 时）、plist 构造失败、AFC 写入失败.
    ///   写入失败**必抛**，绝不静默.
    static func repair(allowWrite: Bool = false,
                       installedApps: [InstalledApp] = []) throws -> Report {
        let identity = try deviceIdentity()
        let proxy = proxyAppBundleId(in: installedApps)

        // 硬拒绝：serial / udid 任一为空 → 不写（宁可不写，也不写一个身份残缺的授权文件）.
        let missing = identity.missingRequiredFields
        if allowWrite && !missing.isEmpty {
            LoginLogger.shared.log("[i4修复] 拒绝写入：缺少必填键 \(missing.joined(separator: ","))",
                                   category: .i4Fix)
            throw I4FixError.identityIncomplete(missing)
        }

        var didWrite = false
        var bytesWritten: Int? = nil
        var readBack: AccContent? = nil
        var matches: Bool? = nil
        var notWrittenReason: String? = nil

        if allowWrite {
            let data = try makeAccData(identity)
            do {
                try AFCService.shared.writeFile(data, to: accAFCPath)
            } catch {
                LoginLogger.shared.log("[i4修复] 写入失败：\(accAFCPath), error=\(error.localizedDescription)",
                                       category: .i4Fix)
                throw I4FixError.writeFailed(accAFCPath, error)
            }
            didWrite = true
            bytesWritten = data.count
            LoginLogger.shared.log(
                "[i4修复] 已写入 \(accAFCPath)：\(data.count) bytes, "
                + "keys=\(accDictionary(identity).keys.sorted().joined(separator: ","))",
                category: .i4Fix)

            // 写后读回校验.
            readBack = try readExistingAcc()
            let written = accDictionary(identity)
            matches = readBack.map { $0.dictionary == written }
            LoginLogger.shared.log(
                "[i4修复] 写后读回：keys=\(readBack?.keys.joined(separator: ",") ?? "nil"), "
                + "matches=\(matches.map { String($0) } ?? "nil")",
                category: .i4Fix)
        } else {
            readBack = try readExistingAcc()
            notWrittenReason = "allowWrite=false，本次未写入，仅读取并展示设备上现有的 \(accAFCPath)."
            LoginLogger.shared.log("[i4修复] 只读分支：allowWrite=false，未写入", category: .i4Fix)
        }

        // 如实的补充说明（事实 + 边界）.
        var notes: [String] = []
        if let reason = notWrittenReason { notes.append(reason) }
        if proxy == nil {
            notes.append("本机未检测到爱思代理 App（\(i4MobileBundleIds.count) 个候选 bundle id 均不在已安装列表），"
                         + "写入的文件可能无人读取.")
        } else {
            notes.append("本机检测到爱思代理 App：\(proxy ?? "").")
        }
        notes.append("auth 使用硬编码兜底 \(authFallback)（非服务端 XX-AUTH 真值），效用未证实.")
        notes.append("i4tool2.acc 是爱思私有 plist，iOS/installd/fairplay 不读它，其内容不含 FairPlay 密钥，"
                     + "不能解决 App Store 加密包的 -42112.")

        let verdict: String
        if allowWrite {
            verdict = "已写入 \(accAFCPath)（\(bytesWritten ?? 0) bytes，读回一致=\(matches.map { String($0) } ?? "nil"))."
                + "是否生效取决于设备端爱思代理 App，本机\(proxy == nil ? "未检测到" : "检测到")该 App."
                + "本功能不能解决 App Store 加密包的 -42112 问题."
        } else {
            verdict = "本次未写入，仅读取并展示设备上的 \(accAFCPath).写入分支默认关闭."
                + "本功能不能解决 App Store 加密包的 -42112 问题."
        }

        return Report(
            identity: identity,
            writeRequested: allowWrite,
            didWrite: didWrite,
            writePath: accAFCPath,
            bytesWritten: bytesWritten,
            readBack: readBack,
            readBackMatchesWritten: matches,
            proxyAppBundleId: proxy,
            notWrittenReason: notWrittenReason,
            notes: notes,
            verdict: verdict,
            canResolveFairPlay42112: false,
            effectVerified: false
        )
    }

    // MARK: - 内部

    /// 按首字节判 plist 格式（只用于展示；解析本身对两种格式都兼容）.
    private static func accFormat(_ data: Data) -> String {
        if data.starts(with: Array("bplist00".utf8)) { return "binary" }
        if let first = data.first, first == UInt8(ascii: "<") { return "xml" }
        return "unknown"
    }

    /// plist 值 → 展示字符串（字符串原样；数字用 stringValue；布尔转 true/false；其余 describing）.
    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default: return String(describing: value)
        }
    }
}
