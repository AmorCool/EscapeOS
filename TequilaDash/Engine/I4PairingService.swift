import Foundation
import UIKit

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
/// - ⚙️ **`pair.config`：可尝试「现场配对」（路径 A）。** 见 `attemptLockdownPair` —— 经 RSD
///   隧道连设备本机的 `lockdownd`，用 `idevice-ffi` 的 `lockdownd_pair` 发一次真 lockdown
///   `Pair` 请求；**设备接受**则拿到它签发的配对记录（`idevice_pairing_file_serialize` 出 XML），
///   再经 house_arrest 写进载体 `Documents/pair.config`。**能不能成，取决于设备认不认** ——
///   这是唯一真正的未知，所以本步把设备返回的**原始错误**（如 `InvalidHostID` /
///   `UserDeniedPairing` / `PasswordProtected`）如实摆出来，绝不把「请求已发出」说成「已配对」。
///   （对照：`pair.config` 的**离线**构造不可能 —— 本应用只有 RSD 远程配对文件 `RpPairingFile`
///   （Ed25519，见 `rust/idevice-ffi/src/rp_pairing_file.rs`），不含 lockdown 记录的
///   HostCertificate / RootCertificate / EscrowBag 等字段。）
/// - ❌ **`RTD.cfg`：造不出。** 它是 PC 本地 `/files/other/RTD.cfg` 的资源清单（字段 `//config/v711/file`、
///   `items/item/name/size`、`minos`、`maxos`），本应用没有这份文件，格式亦未完全解出。
///
/// ⇒ 结论：本服务能把**授权标记**如实写进去并校验；`pair.config` 走「现场配对」**尝试**，
/// 成败以设备对 `Pair` 的应答为准。两者齐备后设备端 Agent 才可能起 VPN ⇒ **完整「高级功能」
/// 是否可开，由设备对 `Pair` 的应答决定**。这一点在 `Report.verdict`、`LivePairReport.detail`
/// 与 `notConstructed` 里逐条写明，不假装能开.
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

    /// RSD 远程配对文件名（本应用持有；「现场配对」的隧道入口）.
    static let rsdPairingFileName = "pairingFile.plist"

    /// 现场配对写入配对记录时的主机名（写进 Pair 请求的 `HostName`）.
    static let pairHostName = "TequilaDash"

    /// 现场配对使用的 SystemBUID（照 pymobiledevice3 `lockdown.py` 的 `SYSTEM_BUID` 常量）.
    static let pairSystemBUID = "30142955-444094379208051516"

    /// 现场配对优先连的 lockdown RSD 服务名 —— **未受信版**.
    ///
    /// RSD 服务表里 lockdown 有两条（pymobiledevice3 `misc/RemoteXPC.md`）：
    /// - `com.apple.mobile.lockdown.remote.trusted`：受信版，上游 `idevice` crate 写死的那条，
    ///   期待「已受信的 host」；
    /// - `com.apple.mobile.lockdown.remote.untrusted`：未受信版，**给尚未配对的对端用** ——
    ///   配对（`Pair`）本该走这条。设备侧不接电脑时回 `InvalidHostID` 的成因与「连了受信版」相关，
    ///   故本服务改为**先连未受信版**.
    static let untrustedLockdownService = "com.apple.mobile.lockdown.remote.untrusted"

    /// 现场配对的回退 lockdown 服务名 —— **受信版**（旧系统 / 服务表无未受信版时回退）.
    static let trustedLockdownService = "com.apple.mobile.lockdown.remote.trusted"

    /// RSD 隧道并发铁律（`AFCService` / `WirelessLockdownService` 同款）：同一 hostname 并发
    /// `tunnel_create_rppairing` 会互相抢占；本服务所有隧道操作经此队列串行.
    private static let pairQueue = DispatchQueue(label: "com.tequila.dash.i4-pair")

    /// `pair.config` **离线**构造不可能的原因（逐条事实，供 UI / 简报直接引用）.
    static let pairConfigUnavailableReason =
        "pair.config 是 PC 与设备做过一次「无线锁定配对」后由 ios_repair_record 生成的配对记录；"
        + "本应用只有 RSD 远程配对文件（Ed25519），不含 lockdown 无线配对身份（HostCertificate / "
        + "EscrowBag 等），无法离线拼出真值."

    /// `pair.config` 的**运行时前提**（它只能靠现场配对拿到）.
    static let pairConfigLiveNote =
        "需现场配对：经 RSD 隧道向设备发起 lockdown Pair，设备接受后才拿得到真记录."

    /// `pair.config` 在「写授权标记」那一步不写的原因（它有独立的现场配对入口）.
    static let pairConfigDeferredReason =
        "pair.config 需走独立的「尝试现场配对」一步（经 RSD 隧道向设备发起 lockdown Pair）；"
        + "本步只写授权标记."

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
        /// 载体 App 从未启动过，没有数据容器（house_arrest 因此拿不到 Documents）.
        /// v0.3.xxx：真机 iPhone 11 实证 —— 这正是「创建文件失败」的根因.
        case carrierNotLaunched(String, String)
        /// 写入失败.
        case writeFailed(String, String)
        /// 写后读回：设备上不存在该文件.
        case readBackMissing(String)
        /// 未导入 RSD 配对文件（现场配对的隧道入口缺失）.
        case noPairingFile
        /// 现场配对的传输层失败（建隧道 / 连 lockdownd / 序列化）.
        case pairTransportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCarrier(let ids):
                return "设备上没有安装爱思移动端（候选 \(ids.count) 个：\(ids.joined(separator: ", "))），"
                    + "高级功能由该 App 提供，无法写入."
            case .markerBuildFailed(let reason):
                return "构造授权标记失败：\(reason)"
            case .sandboxOpenFailed(let bundleId, let reason):
                return "打不开 \(bundleId) 的 Documents 沙盒：\(reason)"
            case .carrierNotLaunched(let name, let bundleId):
                return "\(name)（\(bundleId)）尚未启动过，没有数据容器；请先在设备上打开它一次，再回来重试."
            case .writeFailed(let name, let reason):
                return "写入 \(name) 失败：\(reason)"
            case .readBackMissing(let name):
                return "写后读回失败：设备沙盒里不存在 \(name)，写入未生效."
            case .noPairingFile:
                return "未检测到配对文件（Documents/\(rsdPairingFileName)），请先导入或生成配对文件."
            case .pairTransportFailed(let reason):
                return "现场配对传输失败：\(reason)"
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
        /// 可构造但**有运行时前提**时的补充说明（无则 nil）.
        let note: String?
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

    /// 一次「现场配对」（路径 A）的如实结果（不美化）.
    struct LivePairReport: Sendable {
        /// 设备是否签发了配对记录（lockdown `Pair` 成功）.
        let paired: Bool
        /// 配对失败时设备返回的原始错误（如 `InvalidHostID` / `UserDeniedPairing` / `PasswordProtected`）.
        let deviceError: String?
        /// 序列化后的 `pair.config` 字节数（配对成功才有）.
        let pairConfigBytes: Int?
        /// 已写入的载体 bundleId（写入成功才有）.
        let wroteToCarrier: String?
        /// 写后读回是否一致.
        let verified: Bool
        /// 一句话如实结论.
        let detail: String
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
            // 载体已选中，但沙盒读不出来（如从未启动、无数据容器）时**保留载体信息**，
            // 只把原因记进 error —— 否则载体卡片会整块消失，用户看不到「装了什么」.
            do {
                let files = try await Task.detached(priority: .utility) {
                    try readFileStatuses(carrier: carrier)
                }.value
                return Probe(carrier: carrier, candidates: pick.candidates, files: files, error: nil,
                             tunnelConnected: tunnel, hasPairingFile: pairing)
            } catch {
                return Probe(carrier: carrier, candidates: pick.candidates, files: [],
                             error: error.localizedDescription,
                             tunnelConnected: tunnel, hasPairingFile: pairing)
            }
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
        guard let picked = pick.carrier else {
            log("[i4高级] 未找到任何载体马甲包，中止")
            throw PairingError.noCarrier(carrierPreference)
        }
        log("[i4高级] 载体：\(picked.bundleId)（\(picked.name)），"
            + "版本=\(picked.version ?? "?"), 数据容器=\(picked.hasContainer ? picked.containerPath : "无")")

        // 1.5 载体若无数据容器（从未启动），先启动一次让 iOS 建容器；仍无则如实报错 ——
        //     house_arrest 的 vend_documents 依赖数据容器，缺容器时底层应答被丢弃，
        //     只在第一次 AFC 写时炸成误导性的「创建文件失败」（v0.3.xxx 真机实证）.
        let carrier = try await ensureCarrierContainer(picked)
        guard carrier.hasContainer else {
            log("[i4高级] 启动后仍无数据容器，中止")
            throw PairingError.carrierNotLaunched(carrier.name, carrier.bundleId)
        }
        let markerName = Self.markerName(for: carrier.bundleId)

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
                try FileSharingService.uploadFile(afc: afc, data: markerData,
                                                   to: FileSharingService.appDocumentsPath + "/" + markerName)
                return FileSharingService.fileSize(afc: afc,
                                                   path: FileSharingService.appDocumentsPath + "/" + markerName) ?? -1
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
            let back = try FileSharingService.downloadFile(afc: afc,
                                                           path: FileSharingService.appDocumentsPath + "/" + markerName)
            return back == markerData
        }.value
        log("[i4高级] 写后读回：/\(markerName) 与写入内容一致=\(verified)")

        // 5. 组装如实报告.
        var warnings: [String] = []
        if !verified {
            warnings.append("授权标记写后读回不一致（写入 \(markerData.count) bytes，设备侧 \(writtenSize) bytes）.")
        }
        if !isTunnelConnected {
            warnings.append("写入时本地隧道未连接（LocalDevVPN.isConnected=false）；若写入成功，说明经其它通道完成.")
        }

        let notConstructed: [SkippedFile] = [
            SkippedFile(name: pairConfigName, reason: pairConfigDeferredReason),
            SkippedFile(name: rtdConfigName, reason: rtdConfigUnavailableReason),
        ]

        let verdict: String
        if verified {
            verdict = "已写入授权标记 /\(markerName)（\(markerData.count) bytes，读回一致）；"
                + "\(pairConfigName) 需另走「尝试现场配对」一步，\(rtdConfigName) 无法构造 ⇒ "
                + "设备端 VPN 高级功能仍未完整开启."
        } else {
            verdict = "授权标记已写入但读回不一致；\(pairConfigName) / \(rtdConfigName) 亦未就绪，"
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

    // MARK: - ③ 现场配对（路径 A：经 RSD 隧道向设备发起 lockdown Pair）

    /// 现场配对（路径 A）：经 RSD 隧道连设备本机 `lockdownd`，发一次真 lockdown `Pair`；
    /// 设备接受则把签发的配对记录序列化后写进载体 App 的 `Documents/pair.config`，并读回校验.
    ///
    /// - Important: **成败取决于设备是否接受来自它自身隧道的 `Pair` 请求** —— 这是唯一真正的未知。
    ///   本方法把设备返回的**原始错误**如实放进 `LivePairReport.deviceError`，绝不把「请求已发出」
    ///   说成「已配对」.
    /// - Parameter onLog: 逐条事实日志回调（调用方可转发到 `LoginLogger`）.
    /// - Returns: `LivePairReport`（配对 / 写入 / 读回的逐条事实）.
    /// - Throws: 无 RSD 配对文件（`noPairingFile`）、建隧道 / 连 lockdownd / 序列化失败
    ///   （`pairTransportFailed`）、写入失败 / 写后读回缺失（`writeFailed` / `readBackMissing`）。
    ///   **设备拒绝 Pair 不抛错**，而以 `paired=false` + `deviceError` 如实返回.
    /// - Note: 可取消 —— 各阻塞步骤前检查 `Task.isCancelled`.
    static func attemptLockdownPair(
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> LivePairReport {
        func log(_ line: String) {
            onLog?(line)
            LoginLogger.shared.log(line, category: .i4Fix)
        }

        if Task.isCancelled { throw CancellationError() }
        guard hasPairingFile else {
            log("[i4配对] 未导入配对文件，无法建隧道，中止")
            throw PairingError.noPairingFile
        }

        log("[i4配对] 开始：尝试现场 lockdown 配对（路径 A，经 RSD 隧道 → lockdownd Pair）")
        if !isTunnelConnected {
            log("[i4配对] 注意：本地隧道未连接（LocalDevVPN.isConnected=false），建隧道大概率失败")
        }

        // 载体（可选）：没装也照样做配对实验，只是无处写入.
        let carrier = (try? await Task.detached(priority: .utility) {
            try discoverCarrier()
        }.value)?.carrier
        log("[i4配对] 载体：\(carrier.map { "\($0.bundleId)（\($0.name)）" } ?? "未安装爱思移动端")")

        if Task.isCancelled { throw CancellationError() }

        // 现场配对（阻塞：读文件 + 建隧道 + 连 lockdownd + Pair + 序列化）；经 pairQueue 串行，尊重 RSD 铁律.
        let outcome = try await Task.detached(priority: .userInitiated) {
            try pairQueue.sync { try performPair() }
        }.value

        switch outcome {
        case .refused(let deviceError, let service):
            log("[i4配对] 设备拒绝了 Pair（服务 \(service)）：\(deviceError)")
            return LivePairReport(
                paired: false,
                deviceError: deviceError,
                pairConfigBytes: nil,
                wroteToCarrier: nil,
                verified: false,
                detail: "设备拒绝了 lockdown Pair 请求（服务 \(service)，原始错误：\(deviceError)）。"
                    + "路径 A 在此设备 / 系统上不通；\(pairConfigUnavailableReason)"
            )

        case .paired(let pairConfig, let service):
            log("[i4配对] 设备已签发配对记录（服务 \(service)），pair.config \(pairConfig.count) bytes")
            guard let carrier else {
                return LivePairReport(
                    paired: true,
                    deviceError: nil,
                    pairConfigBytes: pairConfig.count,
                    wroteToCarrier: nil,
                    verified: false,
                    detail: "设备已签发配对记录（\(pairConfig.count) bytes），"
                        + "但设备上没装爱思移动端载体，无处写入 \(pairConfigName)."
                )
            }

            // 载体若从未启动（无数据容器），先启动一次让 iOS 建容器；仍无则如实报错.
            let activeCarrier = try await ensureCarrierContainer(carrier)
            guard activeCarrier.hasContainer else {
                throw PairingError.carrierNotLaunched(activeCarrier.name, activeCarrier.bundleId)
            }

            // 经 house_arrest 写进载体 Documents，并读回校验.
            if Task.isCancelled { throw CancellationError() }
            let name = pairConfigName
            log("[i4配对] 经 house_arrest 写 /\(name) 到 \(activeCarrier.bundleId)")
            let wroteSize: Int64
            do {
                wroteSize = try await Task.detached(priority: .userInitiated) {
                    let afc = try FileSharingService.openAppDocuments(bundleId: activeCarrier.bundleId)
                    defer { afc_client_free(afc) }
                    try FileSharingService.uploadFile(afc: afc, data: pairConfig,
                                                       to: FileSharingService.appDocumentsPath + "/" + name)
                    return FileSharingService.fileSize(afc: afc,
                                                       path: FileSharingService.appDocumentsPath + "/" + name) ?? -1
                }.value
            } catch {
                log("[i4配对] 写入 \(name) 失败：\(error.localizedDescription)")
                throw PairingError.writeFailed(name, error.localizedDescription)
            }
            guard wroteSize >= 0 else {
                log("[i4配对] 写后 stat 不到 /\(name)")
                throw PairingError.readBackMissing(name)
            }
            let verified = try await Task.detached(priority: .userInitiated) { () -> Bool in
                let afc = try FileSharingService.openAppDocuments(bundleId: activeCarrier.bundleId)
                defer { afc_client_free(afc) }
                let back = try FileSharingService.downloadFile(afc: afc,
                                                               path: FileSharingService.appDocumentsPath + "/" + name)
                return back == pairConfig
            }.value
            log("[i4配对] 写后读回：/\(name) 一致=\(verified)")
            return LivePairReport(
                paired: true,
                deviceError: nil,
                pairConfigBytes: pairConfig.count,
                wroteToCarrier: activeCarrier.bundleId,
                verified: verified,
                detail: "设备已签发配对记录并写入 \(activeCarrier.bundleId) 的 Documents/\(name)"
                    + "（\(pairConfig.count) bytes，读回一致=\(verified)）。"
                    + "这是路径 A 的完整产物；设备端 VPN 能否起，仍取决于设备端 Agent 的校验."
            )
        }
    }

    // MARK: - 现场配对内部

    /// 现场配对的结果：设备签发（`paired`）或设备拒绝（`refused`，带原始错误）.
    /// 两者都带**实际用到的 lockdown RSD 服务名**（未受信 / 受信），供如实上报.
    private enum PairOutcome: Sendable {
        case paired(Data, service: String)
        case refused(String, service: String)
    }

    /// RSD 隧道句柄对（构造成功即两者非空，随后免 force unwrap）.
    private struct PairTunnel {
        let adapter: OpaquePointer
        let handshake: OpaquePointer

        func release() {
            rsd_handshake_free(handshake)
            adapter_free(adapter)
        }
    }

    /// 取 FFI 错误正文并释放该错误对象（与 `WirelessLockdownService.error(from:)` 同口径）.
    /// Rust 侧用 `{:?}` 序列化 `IdeviceError`，`UnexpectedResponse("正文")` 的调试外壳在此剥掉，只留正文.
    private static func ffiMessage(_ ffiError: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        var message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        if message.hasPrefix("UnexpectedResponse(\""), message.hasSuffix("\")") {
            message = String(message.dropFirst("UnexpectedResponse(\"".count).dropLast(2))
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return message.isEmpty ? "code=\(code)" : message
    }

    /// 建 RSD 隧道（重试 3 次，与 `WirelessLockdownService.createTunnel` 同款）.
    /// - Note: 阻塞调用；调用方保证已在 `pairQueue` 上.
    private static func createPairTunnel(rpFile: OpaquePointer) throws -> PairTunnel {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        // 蜂窝隧道支持（默认关）：开关开 + 无 Wi-Fi 时先等本地隧道就绪；其余情况为 no-op.
        CellularTunnelManager.shared.prepareForTunnel()
        let deviceIP = LocalDevVPN.targetIP
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw PairingError.pairTransportFailed(
                "隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: String?
        for attempt in 0..<3 {
            var adapter: OpaquePointer?
            var handshake: OpaquePointer?
            let ffiError = pairHostName.withCString { hostname in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                                                hostname, rpFile, nil, nil, &adapter, &handshake)
                    }
                }
            }
            if let ffiError {
                lastError = ffiMessage(ffiError)
                if let handshake { rsd_handshake_free(handshake) }
                if let adapter { adapter_free(adapter) }
            } else if let adapter, let handshake {
                return PairTunnel(adapter: adapter, handshake: handshake)
            } else {
                lastError = "隧道句柄为空"
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw PairingError.pairTransportFailed(
            "创建 RSD 隧道失败（请确认 LocalDevVPN 已连接）：\(lastError ?? "未知")")
    }

    /// 阻塞执行一次现场配对：读 RSD 配对文件 → 建隧道 → 连 lockdownd（**先未受信版**，
    /// 服务表无它再回退受信版）→ `Pair` → 序列化.
    /// - Returns: `.paired(XML bytes, service)` 或 `.refused(设备原始错误, service)`（`service` 为实际用到的服务名）.
    /// - Throws: 读文件 / 建隧道 / 连 lockdownd（两条服务名均失败）/ 序列化失败（传输层问题）.
    /// - Note: 阻塞调用；调用方保证已在 `pairQueue` 上.
    private static func performPair() throws -> PairOutcome {
        let pairingPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(rsdPairingFileName).path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw PairingError.noPairingFile
        }

        // 1. 读 RSD 远程配对文件（隧道入口）.
        var rpFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &rpFile) }) {
            throw PairingError.pairTransportFailed("读取 RSD 配对文件失败：\(ffiMessage(ffiError))")
        }
        guard let rpFile else { throw PairingError.pairTransportFailed("RSD 配对文件解析为空") }
        defer { rp_pairing_file_free(rpFile) }

        // 2. 建隧道.
        let tunnel = try createPairTunnel(rpFile: rpFile)
        defer { tunnel.release() }

        // 3. 连 lockdownd（RSD 隧道即信任边界，无 StartSession）.
        //    先连**未受信版**（`com.apple.mobile.lockdown.remote.untrusted`，配对本该走的那条），
        //    服务表里没有它时回退**受信版**（`…remote.trusted`，上游写死的那条，旧系统兼容）.
        //    端口一律由 FFI 从设备回的服务表按名查表取得，不在此硬编码.
        var client: OpaquePointer?
        var usedService = ""
        var lastConnectError: String?
        for service in [untrustedLockdownService, trustedLockdownService] {
            var candidate: OpaquePointer?
            let ffiError = service.withCString { name in
                lockdownd_connect_rsd_named(tunnel.adapter, tunnel.handshake, name, &candidate)
            }
            if let ffiError {
                lastConnectError = "\(service)：\(ffiMessage(ffiError))"
                if let candidate { lockdownd_client_free(candidate) }
            } else if let candidate {
                client = candidate
                usedService = service
                break
            } else {
                lastConnectError = "\(service)：客户端创建为空"
            }
        }
        guard let client else {
            throw PairingError.pairTransportFailed(
                "连接 lockdownd 失败（未受信 / 受信两条均失败）：\(lastConnectError ?? "未知")")
        }
        defer { lockdownd_client_free(client) }
        LoginLogger.shared.log("[i4配对] 已连 lockdown 服务：\(usedService)", category: .i4Fix)

        // 4. 发 Pair（HostID 现场生成；SystemBUID 照 pymobiledevice3）.
        let hostID = UUID().uuidString
        var pairFile: OpaquePointer?
        let pairError = pairHostName.withCString { hostName in
            hostID.withCString { h in
                pairSystemBUID.withCString { b in
                    lockdownd_pair(client, h, b, hostName, &pairFile)
                }
            }
        }
        if let pairError {
            // 设备拒绝（或协议层报错）—— 如实回报，不抛错.
            return .refused(ffiMessage(pairError), service: usedService)
        }
        guard let pairFile else { return .refused("lockdownd_pair 返回空记录", service: usedService) }
        defer { idevice_pairing_file_free(pairFile) }

        // 5. 序列化成 XML（= pair.config 内容）.
        var dataPtr: UnsafeMutablePointer<UInt8>?
        var size: UInt = 0
        if let ffiError = idevice_pairing_file_serialize(pairFile, &dataPtr, &size) {
            throw PairingError.pairTransportFailed("序列化配对记录失败：\(ffiMessage(ffiError))")
        }
        guard let dataPtr, size > 0 else {
            throw PairingError.pairTransportFailed("序列化配对记录为空")
        }
        let data = Data(bytes: dataPtr, count: Int(size))
        idevice_data_free(dataPtr, size)
        return .paired(data, service: usedService)
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

    /// 载体 App 从未启动时 iOS 不会给它建数据容器，house_arrest 因此拿不到 Documents
    /// （表现为误导性的「创建文件失败」）。这里先启动一次载体让 iOS 建容器，再重探容器路径.
    ///
    /// - 启动复用本工程既有的普通启动原语 `JITEnableService.launchApp(bundleID:)`
    ///   （RSD 隧道 → process_control，与「拉起应用」页同一条，不启用 JIT）。
    /// - 启动后本应用会退到后台、数秒内被挂起，故先取后台租约，保证随后的重探跑得完.
    /// - 容器已存在则原样返回（正常路径零副作用）。
    /// - 启动失败 / 容器仍缺时**不抛错**，原样返回，由调用方按 `carrierNotLaunched` 如实上报.
    /// - Note: 阻塞（启动 + 重探都走 RSD 隧道）；可取消.
    private static func ensureCarrierContainer(_ carrier: CarrierInfo) async throws -> CarrierInfo {
        if carrier.hasContainer { return carrier }
        LoginLogger.shared.log(
            "[i4高级] \(carrier.bundleId) 尚无数据容器（从未启动），先启动一次让它建容器",
            category: .i4Fix)

        let lease = await MainActor.run { CarrierLaunchLease() }
        let pick: CarrierPick?
        do {
            // 启动本身失败不抛错：容器是否出现由下面的重探说了算.
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableService.shared.launchApp(bundleID: carrier.bundleId)
                }.value
            } catch {
                LoginLogger.shared.log(
                    "[i4高级] 启动载体失败：\(error.localizedDescription)", category: .i4Fix)
            }
            try await Task.sleep(nanoseconds: 2_500_000_000)
            pick = try await Task.detached(priority: .utility) { try discoverCarrier() }.value
        } catch {
            await MainActor.run { lease.invalidate() }
            throw error
        }
        await MainActor.run { lease.invalidate() }

        let updated = pick?.candidates.first { $0.bundleId == carrier.bundleId } ?? carrier
        LoginLogger.shared.log(
            "[i4高级] 启动后数据容器：\(updated.hasContainer ? updated.containerPath : "仍无")",
            category: .i4Fix)
        return updated
    }

    /// 打开载体 Documents，点查三个文件的如实状态（标记 / pair.config / RTD.cfg）.
    /// - Note: 阻塞调用（house_arrest 打开沙盒 + AFC stat）.
    private static func readFileStatuses(carrier: CarrierInfo) throws -> [PairFileStatus] {
        let afc = try FileSharingService.openAppDocuments(bundleId: carrier.bundleId)
        defer { afc_client_free(afc) }

        let marker = markerName(for: carrier.bundleId)
        let docs = FileSharingService.appDocumentsPath
        let markerSize = FileSharingService.fileSize(afc: afc, path: docs + "/" + marker)
        let pairSize = FileSharingService.fileSize(afc: afc, path: docs + "/" + pairConfigName)
        let rtdSize = FileSharingService.fileSize(afc: afc, path: docs + "/" + rtdConfigName)

        return [
            PairFileStatus(name: marker, kind: "授权标记", constructible: true, reason: nil,
                           note: nil, exists: markerSize != nil, bytes: markerSize),
            PairFileStatus(name: pairConfigName, kind: "VPN 配对记录", constructible: true, reason: nil,
                           note: pairConfigLiveNote,
                           exists: pairSize != nil, bytes: pairSize),
            PairFileStatus(name: rtdConfigName, kind: "资源清单", constructible: false,
                           reason: rtdConfigUnavailableReason, note: nil,
                           exists: rtdSize != nil, bytes: rtdSize),
        ]
    }
}

/// 启动载体 App 期间的后台存活租约：iOS 会把发起方切后台并在数秒内挂起，
/// 没有它「重探数据容器」可能来不及跑完。与 `JITBackgroundLease` 同款收敛到主线程，
/// 到期回调里自动续期（会话只有几秒，最多续一两次，不会触发系统惩罚）。
@MainActor
private final class CarrierLaunchLease {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var active = true

    init() { renew() }

    private func renew() {
        guard active else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "i4-carrier-launch") { [weak self] in
            guard let self, self.active else { return }
            self.renew()
        }
    }

    func invalidate() {
        active = false
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }
}
