import Foundation

/// 爱思「开启高级功能」服务层（**只做逻辑，不含 UI**）.
///
/// ## 这个功能是什么
/// 爱思的「高级功能」（APP 更新 / 验机 / 导入铃声）**不是 PC 端直接做的**，而是由设备端
/// 「爱思移动端」（一组伪装成笔记 / 工具类的 RN 马甲包，首选 `com.ownbook.notes`）起一个
/// VPN（NetworkExtension）去转发 Apple 锁定的流量。要让它起得来，PC 端得先往**该 App 的沙盒**
/// 写三份文件（见 `P3_爱思助手_逆向/_简报/爱思9_配对与设备端Agent.md` §①）：
///
///   1. `/Documents/pair.config` —— 无线锁定（wireless_lockdown）**配对记录**，由 PC 端
///      `idm_info!ios_repair_record` 生成；设备端 Agent 靠它 `DevManager.autoStart(pair.config)`
///      起 VPN（JS：`exists(Documents/pair.config)` 是前置条件）。
///   2. `/Documents/RTD.cfg` —— 设备端**资源清单**，PC 从本地 `/files/other/RTD.cfg` 读后下发。
///   3. `/Documents/8es1421dg.be` —— **授权标记**（plist），内容 = `i4tool2.acc` 的 auth plist
///      （`auth/serial/imei/productiondate/region/modelnumber/udid/cid`）。设备端 Agent 会把它
///      从 `Documents/` 拷到 `Library/`，`isauth = exists(Library/8es1421dg.be)`。
///      （`com.diary.mood` 的标记文件直接叫 `i4tool2.acc`；`com.MK.AwsomeFiles` 是空文件
///      `1954c668802341a120e240ceefe27d97.epl`。见该报告 §3.3 的 5 项清单。）
///
/// ## 本服务实际能做什么（**不美化**）
/// - ✅ **授权标记 `8es1421dg.be`：可写、可读回校验。** 内容由 `I4AppFixService` 的设备身份
///   + 8 键构造器产出（`deviceIdentity()` / `accDictionary(_:)` / `makeAccData(_:)`），
///   经 **house_arrest**（`FileSharingService.openAppDocuments(bundleId:)`）写进载体 App 的
///   `Documents/`。**为什么走 house_arrest 而不是 `AFCService`**：`AFCService` 的根是设备级
///   `/var/mobile/media`（`com.apple.afc`），够不到 App 沙盒；App 沙盒只能经 house_arrest
///   （`com.apple.mobile.house_arrest`）的 `vend_documents` 进。两者是同一 AFC 协议、不同服务。
/// - ❌ **`pair.config`：造不出。** 它是 PC ↔ 设备的「无线锁定配对记录」，由 PC 端在做完一次
///   带锁屏密码 / 开发者模式 / 设备点「信任」的配对后 `ios_repair_record` 产出。本应用持有的是
///   **RSD 远程配对文件**（`RpPairingFile`，Ed25519，见 `rust/idevice-ffi/src/rp_pairing_file.rs`），
///   与 lockdown 的无线配对记录是**两套不同机制**，前者不含后者的 HostCertificate / RootCertificate /
///   EscrowBag 等字段 ⇒ 无法拼出真值。**宁可不写，也不写一份假的。**
/// - ❌ **`RTD.cfg`：造不出。** 它是 PC 本地 `/files/other/RTD.cfg` 的资源清单（字段 `//config/v711/file`、
///   `items/item/name/size`、`minos`、`maxos`），本应用没有这份文件，格式亦未完全解出。
///
/// ⇒ 结论：本服务能把**授权标记**如实写进去并校验，但 `pair.config` 缺位 ⇒ 设备端 Agent 的
/// VPN 起不来 ⇒ **完整「高级功能」仍无法开启**。这一点在 `Report.verdict` 与 `notConstructed`
/// 里逐条写明，不假装能开.
///
/// ## 为什么是 `enum` + `static` 方法
/// 底层 `AppDiscovery` / `DeviceInfoService` / `FileSharingService` 都是**同步阻塞**且各自管着
/// 自己的 RSD 串行队列；本服务自身**没有任何可变状态**，用 `static` 方法即可，避免引入需要
/// `nonisolated(unsafe)` 的非 Sendable 单例（Swift 6 严格并发）。调用方负责把阻塞调用放到后台线程.
enum I4PairingService {

    // MARK: - 常量（照 `爱思9_配对与设备端Agent.md` §3.3 的 5 项马甲包清单）

    /// 授权标记文件名（4 个马甲包共用这一个名字）.
    static let markerFileName = "8es1421dg.be"
    /// VPN 配对记录文件名（设备端 Agent 起 VPN 的输入）.
    static let pairConfigName = "pair.config"
    /// 设备端资源清单文件名.
    static let rtdConfigName = "RTD.cfg"
    /// `com.diary.mood` 的标记文件名（照爱思清单：直接叫 `i4tool2.acc`）.
    static let altAccMarkerName = "i4tool2.acc"
    /// `com.MK.AwsomeFiles` 的空标记文件名（照爱思清单：写入的是 0 字节空文件）.
    static let emptyMarkerName = "1954c668802341a120e240ceefe27d97.epl"

    /// 载体 bundle id → 授权标记文件名（照爱思 5 项清单；6 个马甲包全覆盖）.
    static let markerByBundleId: [String: String] = [
        "com.ownbook.notes": markerFileName,
        "com.best.vaultnotes": markerFileName,
        "rn.notes.best": markerFileName,
        "com.pd.A4Player": markerFileName,
        "com.diary.mood": altAccMarkerName,
        "com.MK.AwsomeFiles": emptyMarkerName,
    ]

    /// 载体优先级（首选爱思全能版 `com.ownbook.notes`，与 `I4MobileInstallService.agentBundleId` 同值）.
    static let carrierPreference: [String] = [
        "com.ownbook.notes",
        "com.best.vaultnotes",
        "rn.notes.best",
        "com.pd.A4Player",
        "com.diary.mood",
        "com.MK.AwsomeFiles",
    ]

    /// `pair.config` 造不出的原因（逐条事实，供 UI / 简报直接引用）.
    static let pairConfigUnavailableReason =
        "pair.config 是 PC 与设备做过一次「无线锁定配对」后由 ios_repair_record 生成的配对记录；"
        + "本应用只有 RSD 远程配对文件（Ed25519），不含 lockdown 无线配对身份（HostCertificate / "
        + "EscrowBag 等），无法构造真值."

    /// `RTD.cfg` 造不出的原因.
    static let rtdConfigUnavailableReason =
        "RTD.cfg 是爱思 PC 从本地 /files/other/RTD.cfg 读取后下发的设备端资源清单；"
        + "本应用没有这份清单文件，格式亦未完全解出，无法构造."

    /// 载体 bundle id → 该载体在沙盒里应写入的标记文件名（未列出的回退到默认名）.
    static func markerName(for bundleId: String) -> String {
        markerByBundleId[bundleId] ?? markerFileName
    }

    // MARK: - 错误

    enum PairingError: LocalizedError {
        /// 设备上没装任何载体马甲包 —— 高级功能由它们提供，装不上就无从写起.
        case noCarrier([String])
        /// 授权标记 plist 构造失败（设备身份读不到 / plist 序列化失败）.
        case markerBuildFailed(String)
        /// 打不开载体 App 的 Documents 沙盒（未配对 / 未开启文档共享 / App 无数据容器）.
        case sandboxOpenFailed(String, String)
        /// 写入失败.
        case writeFailed(String, String)
        /// 写后读回：设备上不存在该文件.
        case readBackMissing(String)

        var errorDescription: String? {
            switch self {
            case .noCarrier(let ids):
                return "设备上没有安装爱思移动端（候选 \(ids.count) 个：\(ids.joined(separator: ", "))），"
                    + "高级功能由该 App 提供，无法写入."
            case .markerBuildFailed(let reason):
                return "构造授权标记失败：\(reason)"
            case .sandboxOpenFailed(let bundleId, let reason):
                return "打不开 \(bundleId) 的 Documents 沙盒：\(reason)"
            case .writeFailed(let name, let reason):
                return "写入 \(name) 失败：\(reason)"
            case .readBackMissing(let name):
                return "写后读回失败：设备沙盒里不存在 \(name)，写入未生效."
            }
        }
    }

    // MARK: - 模型

    /// 设备上已安装的载体（马甲包）信息.
    struct CarrierInfo: Sendable, Hashable {
        let bundleId: String
        let name: String
        let version: String?
        /// 数据容器路径（`installation_proxy` 的 `Container`；可能为空 = 从未启动）.
        let containerPath: String

        var hasContainer: Bool { !containerPath.isEmpty }
    }

    /// 一个配对 / 授权文件的如实状态.
    struct PairFileStatus: Sendable, Identifiable {
        /// 文件名（如 `8es1421dg.be`）.
        let name: String
        /// 类别（中文）.
        let kind: String
        /// 本应用**能不能**构造出这个文件的内容.
        let constructible: Bool
        /// 不可构造时的原因（可构造则为 nil）.
        let reason: String?
        /// 设备沙盒里当前是否存在.
        let exists: Bool
        /// 存在时的字节数（不存在为 nil）.
        let bytes: Int64?

        var id: String { name }
    }

    /// 设备侧探测快照（探测失败**不抛错**，如实记 `error`）.
    struct Probe: Sendable {
        /// 选中的载体（未装任何载体则为 nil）.
        let carrier: CarrierInfo?
        /// 已装的载体候选（按优先级排序）.
        let candidates: [CarrierInfo]
        /// 三个文件的如实状态（未选中载体时为空）.
        let files: [PairFileStatus]
        /// 探测失败原因（nil = 成功）.
        let error: String?
        /// 本地隧道是否已连接（`LocalDevVPN.isConnected`）.
        let tunnelConnected: Bool
        /// 是否已导入配对文件（RSD 远程配对）.
        let hasPairingFile: Bool
    }

    /// 一次「开启高级功能」的如实结果（不美化）.
    struct Report: Sendable {
        /// 写入的载体.
        let carrier: CarrierInfo?
        /// 成功写入的文件名.
        let wrote: [String]
        /// 写后读回一致的文件名.
        let verified: [String]
        /// 构造不出、未写入的文件（含原因）.
        let notConstructed: [SkippedFile]
        /// 如实的补充说明（逐条事实）.
        let warnings: [String]
        /// 一句话结论.
        let verdict: String
    }

    /// 构造不出而跳过的文件（含原因）.
    struct SkippedFile: Sendable {
        let name: String
        let reason: String
    }

    // MARK: - 前置条件（供 UI 常驻提示）

    /// 本地隧道是否已连接（与 `I4AppFixService.isTunnelConnected` 同口径）.
    static var isTunnelConnected: Bool { LocalDevVPN.isConnected }

    /// 是否已导入 RSD 配对文件.
    static var hasPairingFile: Bool { I4AppFixService.hasPairingFile }

    // MARK: - ① 探测（只读）

    /// 读设备实际状态：装了哪个载体、三个文件在不在。**不抛错**（失败记进 `Probe.error`）.
    ///
    /// - Note: 阻塞调用（建 RSD 隧道 + instproxy 枚举 + house_arrest 打开沙盒），放后台线程.
    static func probe() async -> Probe {
        let tunnel = isTunnelConnected
        let pairing = hasPairingFile
        do {
            let pick = try await Task.detached(priority: .utility) {
                try discoverCarrier()
            }.value
            guard let carrier = pick.carrier else {
                return Probe(carrier: nil, candidates: pick.candidates, files: [], error: nil,
                             tunnelConnected: tunnel, hasPairingFile: pairing)
            }
            let files = try await Task.detached(priority: .utility) {
                try readFileStatuses(carrier: carrier)
            }.value
            return Probe(carrier: carrier, candidates: pick.candidates, files: files, error: nil,
                         tunnelConnected: tunnel, hasPairingFile: pairing)
        } catch {
            return Probe(carrier: nil, candidates: [], files: [], error: error.localizedDescription,
                         tunnelConnected: tunnel, hasPairingFile: pairing)
        }
    }

    // MARK: - ② 开启（写 + 读回校验）

    /// 执行一次「开启高级功能」：枚举载体 → 构造授权标记 → 经 house_arrest 写入载体沙盒 → 读回校验.
    ///
    /// - Parameter onLog: 逐条事实日志回调（调用方可转发到 `LoginLogger`）.
    /// - Returns: `Report`（含写入 / 读回 / 未构造的逐条事实）.
    /// - Throws: 无载体（`noCarrier`）、标记构造失败、沙盒打不开、写入失败、写后读回缺失.
    ///   失败**必抛**，绝不静默.
    /// - Note: 可取消 —— 各阻塞步骤前检查 `Task.isCancelled`.
    static func enable(onLog: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        func log(_ line: String) {
            onLog?(line)
            LoginLogger.shared.log(line, category: .i4Fix)
        }

        if Task.isCancelled { throw CancellationError() }

        // 1. 找载体（设备端爱思移动端）.
        log("[i4高级] 开始：枚举设备已装应用，找爱思移动端载体")
        let pick = try await Task.detached(priority: .userInitiated) {
            try discoverCarrier()
        }.value
        guard let carrier = pick.carrier else {
            log("[i4高级] 未找到任何载体马甲包，中止")
            throw PairingError.noCarrier(carrierPreference)
        }
        let markerName = Self.markerName(for: carrier.bundleId)
        log("[i4高级] 载体：\(carrier.bundleId)（\(carrier.name)），"
            + "版本=\(carrier.version ?? "?"), 数据容器=\(carrier.hasContainer ? carrier.containerPath : "无")")

        // 2. 构造授权标记（= i4tool2.acc 的 auth plist；复用 I4AppFixService 的身份 + 8 键构造器）.
        if Task.isCancelled { throw CancellationError() }
        log("[i4高级] 读设备身份，构造授权标记 plist（8 键）")
        let markerData: Data
        do {
            markerData = try await Task.detached(priority: .userInitiated) {
                let identity = try I4AppFixService.deviceIdentity()
                return try I4AppFixService.makeAccData(identity)
            }.value
        } catch {
            log("[i4高级] 构造授权标记失败：\(error.localizedDescription)")
            throw PairingError.markerBuildFailed(error.localizedDescription)
        }
        log("[i4高级] 授权标记 \(markerData.count) bytes")

        // 3. 经 house_arrest 打开载体 Documents，写入标记（open + write + stat 全在后台闭包内完成，
        //    非 Sendable 的 AFC handle 不跨并发边界）.
        if Task.isCancelled { throw CancellationError() }
        log("[i4高级] 经 house_arrest 打开 \(carrier.bundleId) 的 Documents，写 /\(markerName)")
        let writtenSize: Int64
        do {
            writtenSize = try await Task.detached(priority: .userInitiated) {
                let afc = try FileSharingService.openAppDocuments(bundleId: carrier.bundleId)
                defer { afc_client_free(afc) }
                try FileSharingService.uploadFile(afc: afc, data: markerData, to: "/" + markerName)
                return FileSharingService.fileSize(afc: afc, path: "/" + markerName) ?? -1
            }.value
        } catch {
            log("[i4高级] 写入 \(markerName) 失败：\(error.localizedDescription)")
            throw PairingError.writeFailed(markerName, error.localizedDescription)
        }
        guard writtenSize >= 0 else {
            log("[i4高级] 写后 stat 不到 /\(markerName)")
            throw PairingError.readBackMissing(markerName)
        }
        log("[i4高级] 已写入 /\(markerName)：设备侧 \(writtenSize) bytes")

        // 4. 写后读回，比对字节.
        if Task.isCancelled { throw CancellationError() }
        let verified = try await Task.detached(priority: .userInitiated) { () -> Bool in
            let afc = try FileSharingService.openAppDocuments(bundleId: carrier.bundleId)
            defer { afc_client_free(afc) }
            let back = try FileSharingService.downloadFile(afc: afc, path: "/" + markerName)
            return back == markerData
        }.value
        log("[i4高级] 写后读回：/\(markerName) 与写入内容一致=\(verified)")

        // 5. 组装如实报告.
        var warnings: [String] = []
        if !verified {
            warnings.append("授权标记写后读回不一致（写入 \(markerData.count) bytes，设备侧 \(writtenSize) bytes）.")
        }
        if !carrier.hasContainer {
            warnings.append("该 App 在设备上尚无数据容器（可能从未启动）；house_arrest 仍成功写入了 Documents.")
        }
        if !isTunnelConnected {
            warnings.append("写入时本地隧道未连接（LocalDevVPN.isConnected=false）；若写入成功，说明经其它通道完成.")
        }

        let notConstructed: [SkippedFile] = [
            SkippedFile(name: pairConfigName, reason: pairConfigUnavailableReason),
            SkippedFile(name: rtdConfigName, reason: rtdConfigUnavailableReason),
        ]

        let verdict: String
        if verified {
            verdict = "已写入授权标记 /\(markerName)（\(markerData.count) bytes，读回一致）；"
                + "但 \(pairConfigName) / \(rtdConfigName) 无法构造 ⇒ 设备端 VPN 高级功能仍未完整开启."
        } else {
            verdict = "授权标记已写入但读回不一致；且 \(pairConfigName) / \(rtdConfigName) 无法构造，"
                + "高级功能未开启."
        }

        log("[i4高级] 结束：\(verdict)")
        return Report(
            carrier: carrier,
            wrote: [markerName],
            verified: verified ? [markerName] : [],
            notConstructed: notConstructed,
            warnings: warnings,
            verdict: verdict
        )
    }

    // MARK: - 内部

    /// 载体选择结果（纯值，可跨并发边界）.
    private struct CarrierPick: Sendable {
        let carrier: CarrierInfo?
        let candidates: [CarrierInfo]
    }

    /// 枚举设备已装应用，按 `carrierPreference` 优先级选出载体.
    /// - Note: 阻塞调用（建 RSD 隧道 + instproxy 枚举）.
    private static func discoverCarrier() throws -> CarrierPick {
        let apps = try AppDiscovery().fetchInstalledApps()
        let byId = Dictionary(apps.map { ($0.bundleIdentifier, $0) },
                              uniquingKeysWith: { first, _ in first })
        var candidates: [CarrierInfo] = []
        for id in carrierPreference {
            guard let app = byId[id] else { continue }
            candidates.append(CarrierInfo(bundleId: app.bundleIdentifier, name: app.name,
                                          version: app.version, containerPath: app.containerPath))
        }
        return CarrierPick(carrier: candidates.first, candidates: candidates)
    }

    /// 打开载体 Documents，点查三个文件的如实状态（标记 / pair.config / RTD.cfg）.
    /// - Note: 阻塞调用（house_arrest 打开沙盒 + AFC stat）.
    private static func readFileStatuses(carrier: CarrierInfo) throws -> [PairFileStatus] {
        let afc = try FileSharingService.openAppDocuments(bundleId: carrier.bundleId)
        defer { afc_client_free(afc) }

        let marker = markerName(for: carrier.bundleId)
        let markerSize = FileSharingService.fileSize(afc: afc, path: "/" + marker)
        let pairSize = FileSharingService.fileSize(afc: afc, path: "/" + pairConfigName)
        let rtdSize = FileSharingService.fileSize(afc: afc, path: "/" + rtdConfigName)

        return [
            PairFileStatus(name: marker, kind: "授权标记", constructible: true, reason: nil,
                           exists: markerSize != nil, bytes: markerSize),
            PairFileStatus(name: pairConfigName, kind: "VPN 配对记录", constructible: false,
                           reason: pairConfigUnavailableReason,
                           exists: pairSize != nil, bytes: pairSize),
            PairFileStatus(name: rtdConfigName, kind: "资源清单", constructible: false,
                           reason: rtdConfigUnavailableReason,
                           exists: rtdSize != nil, bytes: rtdSize),
        ]
    }
}
