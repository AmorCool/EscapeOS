import Foundation

// MARK: - AirFair 同步授权协议的「形状」
//
// 本文件把 AppFlexPC 客户端那条「主机↔iOS 同步授权」链路的**形状**落地成一个 Engine 层模块。
// 它只做三件事，且每件事都是**可编译、可测试的骨架**，不依赖任何后端：
//   1. 用类型把协议的输入/输出形状钉死（设备身份 5 项 / Grappa 会话 / RS 应答 / RS 请求）；
//   2. 用一个 `AirFairSigningService` 协议把「算 Grappa / 算 RS」这两件**需要外部能力**
//      的事抽象出去（后端 / Unicorn harness 由注入的实现负责）；
//   3. 用 `AirFairSyncService` 把 6 步流程串起来，设备侧文件读写复用既有 AFC / lockdown 能力。
//
// ## 协议全链 6 步（AirFair 状态机，见 P7 逆向简报）
//   [1] SyncAllowed           前置就绪：配对 + lockdown 可达
//   [2] RequestingSync        生成主机 Grappa 会话（84 字节，由 UDID 派生）
//   [3] ReadyForSync          设备回传同步请求文件 rq / rq.sig
//   [4] GenerateRS            打包 dsid + 5 项设备身份 + rq/rq.sig + grappa → 算 RS
//   [5] FinishedSyncingMetadata 把 rs / rs.sig 写回设备 /AirFair/sync/
//   [6] SyncFinished          成功；任一步失败即抛错（不静默降级）
//
// ## 诚实边界（写进类型注释，不在日志里解释）
//   · **Grappa 只管建会话，RS 才管账号授权**：Grappa 是主机↔设备的会话密钥材料，
//     它本身**不授予任何装机权限**；真正决定「这台设备能不能同步/授权」的是 RS ——
//     而 RS 必须经 `AirFairSyncAccountAuthorize` 注入真实 DSID，且需匹配真实 AppleID
//     授权过的 SC Info，无账号池时本地算不出（见 P7 `研究_AirFair协议与移植.md` §4.2）。
//   · 因此本模块的**默认签名实现**是 `UnavailableSigningService` —— 没后端时**如实抛错**，
//     绝不假装能算。
//   · 本模块**不联网**：任何网络请求都由注入的 `AirFairSigningService` 实现负责。
//
// ## 不做什么（明确边界）
//   · 不实现 Unicorn harness（另一 agent 在写，本文件只留接口 + TODO）；
//   · 不接 NB 后端（另一 agent 在做对比）；
//   · 不碰 UI；不改既有链路。

// MARK: - 协议形状的类型定义

/// 设备 FairPlay 身份 —— 对齐 GenerateRS 契约里的 5 项设备身份，
/// 全部取自 lockdown `com.apple.mobile.iTunes` 域（`fair_play_guid` 即 UDID）.
///
/// 每项都可能是 `nil`：iOS 版本不同、域内容不同都会导致缺项。**缺项如实暴露**，
/// 由调用方（`AirFairSyncService.sync`）在打包 RS 请求前判定，绝不静默补默认值。
struct DeviceFairPlayIdentity: Sendable, Equatable {
    /// 协议键 `fair_play_certificate`：设备 FairPlay 证书（二进制）.
    let fairPlayCertificate: Data?
    /// 协议键 `fair_device_type`：设备类型.
    let fairDeviceType: String?
    /// 协议键 `KeyTypeSupportVersion`：密钥类型支持版本.
    let keyTypeSupportVersion: String?
    /// 协议键 `fair_play_guid`：设备 GUID，按协议**等于 UDID**.
    let fairPlayGuid: String?
    /// 协议键 `grappa`：设备侧 Grappa 材料（二进制）.
    let grappa: Data?

    /// 缺失的协议键名（用于错误报告，便于对照 GenerateRS 的 9 键契约）.
    var missingFields: [String] {
        var missing: [String] = []
        if fairPlayCertificate == nil { missing.append("fair_play_certificate") }
        if fairDeviceType == nil { missing.append("fair_device_type") }
        if keyTypeSupportVersion == nil { missing.append("KeyTypeSupportVersion") }
        if fairPlayGuid == nil { missing.append("fair_play_guid") }
        if grappa == nil { missing.append("grappa") }
        return missing
    }

    /// 5 项是否齐全.
    var isComplete: Bool { missingFields.isEmpty }
}

/// Grappa 会话 —— `POST /GenerateGrappa` 的产物（由注入的签名实现负责获取）.
///
/// 诚实边界：Grappa 是**会话密钥材料**，只负责在主机与设备之间建立 AirFair 会话，
/// 它本身不携带账号授权，也不代表装机能力.
struct GrappaSession: Sendable, Equatable {
    /// 协议键 `grappaData`（base64 解码后的二进制，84 字节）.
    let grappaData: Data
    /// 协议键 `grappa_session_id`（uint32）.
    let sessionId: UInt32
}

/// RS 应答 —— `POST /GenerateRS` 的产物（由注入的签名实现负责获取）.
///
/// 诚实边界：RS 才是**账号授权**的载体；它由设备侧用 FairPlay 根验证.
struct RemoteSignature: Sendable, Equatable {
    /// 协议键 `rs_data`（base64 解码后的二进制）.
    let rsData: Data
    /// 协议键 `rs_sig_data`（base64 解码后的二进制，21 字节）.
    let rsSigData: Data
}

/// RS 请求 —— 打包 GenerateRS 契约所需的全部输入.
///
/// 9 键契约的归属：
///   · `dsid`              → 本结构 `dsid`
///   · `grappa_session_id` → 本结构 `grappaSessionId`
///   · `rq_data`           → 本结构 `rqData`
///   · `rq_sig_data`       → 本结构 `rqSigData`
///   · 其余 5 项           → 本结构 `identity`（`fair_play_certificate` / `fair_device_type` /
///                            `KeyTypeSupportVersion` / `fair_play_guid` / `grappa`）
struct RSRequest: Sendable, Equatable {
    /// 协议键 `dsid`：购买者 ID（PurchaserID），来自账号后端，本模块**不联网获取**.
    let dsid: String
    /// 协议键 `grappa_session_id`：`generateGrappa` 返回的会话 ID.
    let grappaSessionId: UInt32
    /// 5 项设备身份.
    let identity: DeviceFairPlayIdentity
    /// 协议键 `rq_data`：设备侧同步请求内容.
    let rqData: Data
    /// 协议键 `rq_sig_data`：设备侧同步请求签名.
    let rqSigData: Data
}

/// AirFair 链路的失败类型 —— 每一步失败都抛错，不做静默降级.
enum AirFairError: Error, LocalizedError, Sendable {
    /// 未注入可用的签名实现（默认实现 `UnavailableSigningService` 抛此错）.
    case signingServiceUnavailable
    /// 设备身份缺项（附带缺失的协议键名）.
    case missingDeviceIdentity([String])
    /// 读 lockdown 失败（附带域/键与原因）.
    case lockdownReadFailed(String)
    /// 读设备请求文件失败（附带路径与原因）.
    case requestFileReadFailed(path: String, reason: String)
    /// 写设备应答文件失败（附带路径与原因）.
    case responseFileWriteFailed(path: String, reason: String)
    /// Grappa harness 未接线（`LocalGrappaSigningService` 的桩实现抛此错）.
    case grappaHarnessNotWired
    /// 本地无法计算 RS（必须注入真实 DSID 且匹配真实 AppleID 授权过的 SC Info）.
    case remoteSignatureRequiresAccount

    var errorDescription: String? {
        switch self {
        case .signingServiceUnavailable:
            return "AirFair 签名服务不可用：未注入 AirFairSigningService 实现."
        case let .missingDeviceIdentity(fields):
            return "设备 FairPlay 身份缺项：\(fields.joined(separator: ", "))."
        case let .lockdownReadFailed(detail):
            return "读 lockdown 失败：\(detail)."
        case let .requestFileReadFailed(path, reason):
            return "读设备请求文件失败 \(path)：\(reason)."
        case let .responseFileWriteFailed(path, reason):
            return "写设备应答文件失败 \(path)：\(reason)."
        case .grappaHarnessNotWired:
            return "本地 Grappa 未接线：Unicorn harness 尚未装配."
        case .remoteSignatureRequiresAccount:
            return "本地无法计算 RS：需注入真实 DSID 并匹配 AppleID 授权过的 SC Info."
        }
    }
}

// MARK: - 签名服务抽象（关键抽象）

/// 「算 Grappa / 算 RS」两件事的抽象 —— 这是本模块与外部能力（后端 / Unicorn harness）的**唯一接缝**.
///
/// 本模块**不联网、不跑解释器**：这些都由注入的实现负责。
/// 之所以把两件事放在同一个协议里：它们共享同一个 DSID 上下文与同一条 AirFair 会话，
/// 拆成两个协议只会让「会话 ID 要在两者间传递」这件事无处安放。
protocol AirFairSigningService: Sendable {
    /// 生成主机 Grappa 会话（协议 `POST /GenerateGrappa`，输入仅 UDID）.
    func generateGrappa(udid: String) async throws -> GrappaSession

    /// 计算 RS（协议 `POST /GenerateRS`，输入为 `RSRequest` 打包的 9 键）.
    func generateRS(request: RSRequest) async throws -> RemoteSignature
}

// MARK: - 实现 1：默认（诚实抛错）

/// **默认实现**：没后端时如实抛错，绝不假装能算.
///
/// 这是本模块的默认签名实现 —— 任何未显式注入实现的调用路径都会走到这里，
/// 并以 `AirFairError.signingServiceUnavailable` 明确失败，而不是返回空/占位数据.
struct UnavailableSigningService: AirFairSigningService {
    func generateGrappa(udid: String) async throws -> GrappaSession {
        throw AirFairError.signingServiceUnavailable
    }

    func generateRS(request: RSRequest) async throws -> RemoteSignature {
        throw AirFairError.signingServiceUnavailable
    }
}

// MARK: - 实现 2：本地 Grappa（桩，接口 + TODO）

/// **本地 Grappa 实现（桩）**：预留给 Unicorn 解释执行的 Grappa harness.
///
/// 边界：本类型**只留接口 + TODO**，不实现 Unicorn（harness 由另一 agent 在写）.
///   · `generateGrappa`：将来接 `SapMachine`（Unicorn x86-64 + CoreFP）解释执行
///     `AirFairSyncGrappaCreate`，产出 84 字节 Grappa 与会话 ID；
///   · `generateRS`：**本地永远算不出** —— RS 必须经 `AirFairSyncAccountAuthorize`
///     注入真实 DSID 且匹配真实 AppleID 授权过的 SC Info（无账号池时成功概率 ≈ 0），
///     故这里如实抛 `remoteSignatureRequiresAccount`，不提供假实现.
struct LocalGrappaSigningService: AirFairSigningService {
    func generateGrappa(udid: String) async throws -> GrappaSession {
        // TODO: 接入 Unicorn harness（另一 agent 在写）。此处只声明接口，不实现解释执行.
        //       预期落点：SapMachine 加载 AirTrafficHost x86-64 镜像 →
        //       `AirFairSyncGrappaCreate(udid)` → 84 字节 grappaData + grappa_session_id.
        throw AirFairError.grappaHarnessNotWired
    }

    func generateRS(request: RSRequest) async throws -> RemoteSignature {
        // RS 不是「本地算力」问题，而是「账号授权」问题：没有真实 DSID + SC Info 就无解.
        throw AirFairError.remoteSignatureRequiresAccount
    }
}

// MARK: - 6 步流程的编排

/// 一次 `sync` 成功后的结果（6 步的产物快照）.
struct AirFairSyncResult: Sendable {
    /// 读到的设备 FairPlay 身份.
    let identity: DeviceFairPlayIdentity
    /// 生成的主机 Grappa 会话.
    let grappaSession: GrappaSession
    /// 算出的 RS 应答（已写回设备）.
    let remoteSignature: RemoteSignature
}

/// AirFair 同步服务 —— 串起 6 步，设备侧文件读写复用既有 AFC / lockdown 能力.
///
/// 为什么是 `enum`（无 case）而非 `final class`：本类型**没有任何可变实例状态**，
/// 只是一个命名空间，用无 case 的 `enum` 表达最贴切，也天然满足 Swift 6 严格并发
/// （不存在非 Sendable 的 `static let`）.
///
/// ## 设备侧文件落点
///   `/AirFair/sync/afsync.rq`     主机 → 设备（同步请求）
///   `/AirFair/sync/afsync.rq.sig` 主机 → 设备（请求签名）
///   `/AirFair/sync/afsync.rs`     设备 ← 主机（RS 应答）
///   `/AirFair/sync/afsync.rs.sig` 设备 ← 主机（应答签名）
enum AirFairSyncService {

    // MARK: 设备侧路径常量

    /// 设备侧同步目录.
    static let syncDirectory = "/AirFair/sync"
    /// 同步请求文件（设备 ← 主机）.
    static let requestPath = "/AirFair/sync/afsync.rq"
    /// 同步请求签名（设备 ← 主机）.
    static let requestSignaturePath = "/AirFair/sync/afsync.rq.sig"
    /// RS 应答文件（主机 → 设备）.
    static let responsePath = "/AirFair/sync/afsync.rs"
    /// RS 应答签名（主机 → 设备）.
    static let responseSignaturePath = "/AirFair/sync/afsync.rs.sig"

    // MARK: [1] 读设备身份（lockdown）

    /// 读 5 项设备 FairPlay 身份（lockdown `com.apple.mobile.iTunes` 域，一次隧道）.
    ///
    /// 诚实边界：AFC/lockdown 的读取失败**如实抛出**（`AirFairError.lockdownReadFailed`），
    /// 不返回空结构冒充成功.
    static func readDeviceIdentity() throws -> DeviceFairPlayIdentity {
        let domain: [String: Any]
        do {
            domain = try DeviceInfoService.lockdownDomainDict("com.apple.mobile.iTunes")
        } catch {
            throw AirFairError.lockdownReadFailed(
                "com.apple.mobile.iTunes (\(error.localizedDescription))")
        }
        // fair_play_guid 按协议等于 UDID；iTunes 域里通常直接给该键，
        // 故一次隧道即可拿全 5 项（缺项由 missingFields 如实暴露，不做二次回退读取）.
        return DeviceFairPlayIdentity(
            fairPlayCertificate: Self.dataValue(domain["fair_play_certificate"]),
            fairDeviceType: Self.stringValue(domain["fair_device_type"]),
            keyTypeSupportVersion: Self.stringValue(domain["KeyTypeSupportVersion"]),
            fairPlayGuid: Self.stringValue(domain["fair_play_guid"]),
            grappa: Self.dataValue(domain["grappa"])
        )
    }

    // MARK: [3] 读设备请求文件（AFC）

    /// 读设备侧同步请求 `afsync.rq` + `afsync.rq.sig`（AFC）.
    ///
    /// 诚实边界：AFC 的根是 `/var/mobile/media`，而 `/AirFair/sync/` 落在系统数据卷上，
    /// 两者不在同一挂载点 —— 该路径**可能不可直接读**（需 symlink 之类的可达路由）。
    /// 本方法不猜、不降级：读不到就抛 `requestFileReadFailed`.
    static func readRequestFiles() throws -> (rqData: Data, rqSigData: Data) {
        let rqData: Data
        do {
            rqData = try AFCService.shared.readFile(requestPath)
        } catch {
            throw AirFairError.requestFileReadFailed(
                path: requestPath, reason: error.localizedDescription)
        }
        let rqSigData: Data
        do {
            rqSigData = try AFCService.shared.readFile(requestSignaturePath)
        } catch {
            throw AirFairError.requestFileReadFailed(
                path: requestSignaturePath, reason: error.localizedDescription)
        }
        return (rqData, rqSigData)
    }

    // MARK: [5] 写设备应答文件（AFC）

    /// 把 RS 应答 `afsync.rs` + `afsync.rs.sig` 写回设备（AFC）.
    ///
    /// 诚实边界：与 `readRequestFiles` 同 —— AFC 根为 media，写 `/AirFair/sync/` 可能
    /// 因挂载点/权限失败（P7 简报实测 `afc` 写 `../Library` 得 `code=106`）。
    /// 写失败**如实抛出** `responseFileWriteFailed`，不吞错.
    static func writeResponseFiles(rs: Data, rsSig: Data) throws {
        do {
            try AFCService.shared.writeFile(rs, to: responsePath)
        } catch {
            throw AirFairError.responseFileWriteFailed(
                path: responsePath, reason: error.localizedDescription)
        }
        do {
            try AFCService.shared.writeFile(rsSig, to: responseSignaturePath)
        } catch {
            throw AirFairError.responseFileWriteFailed(
                path: responseSignaturePath, reason: error.localizedDescription)
        }
    }

    // MARK: 6 步编排

    /// 串起 AirFair 6 步（调用方应在后台线程调用：本方法含同步设备 IO）.
    ///
    /// 步骤 → 实现映射：
    ///   [1] SyncAllowed            → `readDeviceIdentity()`（含缺项校验）
    ///   [2] RequestingSync         → `service.generateGrappa(udid:)`
    ///   [3] ReadyForSync           → `readRequestFiles()`
    ///   [4] GenerateRS             → `service.generateRS(request:)`
    ///   [5] FinishedSyncingMetadata → `writeResponseFiles(rs:rsSig:)`
    ///   [6] SyncFinished           → 返回 `AirFairSyncResult`
    ///
    /// - Parameter dsid: 购买者 ID（PurchaserID）。它来自账号后端，**本模块不联网获取**，
    ///   故由调用方注入；这是 RS 的必要输入，不能凭空造（见类型注释的诚实边界）.
    /// - Parameter service: 签名实现。默认场景传 `UnavailableSigningService`（诚实抛错）。
    /// - Returns: 6 步产物快照.
    /// - Throws: `AirFairError`（任一步失败）或注入实现抛出的错误.
    static func sync(dsid: String, using service: AirFairSigningService) async throws -> AirFairSyncResult {
        // [1] SyncAllowed —— 前置就绪：读设备身份，缺项即失败.
        let identity = try readDeviceIdentity()
        let missing = identity.missingFields
        guard missing.isEmpty else {
            throw AirFairError.missingDeviceIdentity(missing)
        }
        guard let udid = identity.fairPlayGuid else {
            // 理论上被上面的 missingFields 拦住，这里做防御性收口.
            throw AirFairError.missingDeviceIdentity(["fair_play_guid"])
        }
        LoginLogger.shared.log(
            "[AirFair] [1] SyncAllowed 设备身份就绪 udid=\(udid.prefix(8))…",
            category: .general)

        // [2] RequestingSync —— 生成主机 Grappa 会话（网络/解释器由注入实现负责）.
        let grappaSession = try await service.generateGrappa(udid: udid)
        LoginLogger.shared.log(
            "[AirFair] [2] RequestingSync grappa=\(grappaSession.grappaData.count)B"
                + " session=\(grappaSession.sessionId)",
            category: .general)

        // [3] ReadyForSync —— 读设备回传的同步请求文件.
        let request = try readRequestFiles()
        LoginLogger.shared.log(
            "[AirFair] [3] ReadyForSync rq=\(request.rqData.count)B rqSig=\(request.rqSigData.count)B",
            category: .general)

        // [4] GenerateRS —— 打包 9 键，交注入实现算 RS.
        let rsRequest = RSRequest(
            dsid: dsid,
            grappaSessionId: grappaSession.sessionId,
            identity: identity,
            rqData: request.rqData,
            rqSigData: request.rqSigData)
        let signature = try await service.generateRS(request: rsRequest)
        LoginLogger.shared.log(
            "[AirFair] [4] GenerateRS rs=\(signature.rsData.count)B rsSig=\(signature.rsSigData.count)B",
            category: .general)

        // [5] FinishedSyncingMetadata —— 写回设备.
        try writeResponseFiles(rs: signature.rsData, rsSig: signature.rsSigData)
        LoginLogger.shared.log("[AirFair] [5] FinishedSyncingMetadata 已写回 \(responsePath)",
            category: .general)

        // [6] SyncFinished.
        LoginLogger.shared.log("[AirFair] [6] SyncFinished", category: .general)
        return AirFairSyncResult(
            identity: identity,
            grappaSession: grappaSession,
            remoteSignature: signature)
    }

    // MARK: lockdown 值的类型归一化

    /// 把 lockdown 值归一化成 `Data`（`<data>` 直接给 Data；字符串按 base64 解码）.
    private static func dataValue(_ any: Any?) -> Data? {
        if let data = any as? Data { return data }
        if let text = any as? String { return Data(base64Encoded: text) }
        return nil
    }

    /// 把 lockdown 值归一化成 `String`（字符串原样；数字取十进制文本）.
    private static func stringValue(_ any: Any?) -> String? {
        if let text = any as? String { return text }
        if let number = any as? NSNumber { return number.stringValue }
        return nil
    }
}
