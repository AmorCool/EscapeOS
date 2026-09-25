import Foundation
import UIKit

/// 反激活设备 —— 移植自爱思 9.0「反激活设备」.
///
/// ## 它做什么
/// 让设备端 `mobileactivationd` 把本机的激活记录作废，设备随即回到「Hello / 激活」界面.
/// 走 Apple 官方激活通道（lockdown 服务 `com.apple.mobileactivationd`），
/// 协议只有一条二进制 plist：`{ Command = "DeactivateRequest" }`.
/// 不依赖漏洞、不需要越狱、不需要 Apple ID.
///
/// ## 通道（为什么用 `_rsd` 变体）
/// 我们手上只有 RpPairingFile（RSD / 无线配对格式），**没有** lockdown 配对文件，
/// 所以仓库里已有的 `mobileactivationd_connect(provider)` 那条路走不通
/// （它内部要 `provider.get_pairing_file()`，见 `CDProbe.swift` 实测）.
/// `mobileactivationd_deactivate_rsd(adapter, handshake)` 在 FFI 层用 RSD 通道
/// 自建 LockdownClient → StartService → adapter.connect → 发 plist，是本项目唯一可用的一条.
///
/// ## 安全闸（三条，缺一不可）
/// 反激活**不可逆**：执行后设备停在激活界面，必须走 Apple 官方激活才能回桌面；
/// 带激活锁的设备反激活后必须知道原 Apple ID 密码才能重新激活，**否则变砖**.
/// 因此 `readStatus()` 先读两个键并给出明确结论：
/// 1. `ActivationState` 必须是 `Activated`（`Unactivated`/`FactoryActivated` → 拒绝）；
/// 2. `com.apple.fmip` → `IsAssociated` 必须**明确为 false**
///    （true = 激活锁已开 → 拒绝；读不到 = 无法确认 → **同样拒绝**，不给「跳过」口子）.
/// 视图层在真正下发前再叠一道**不可跳过**的确认弹窗（写清「会变成未激活状态」
/// 「带激活锁会变砖」），且不提供任何「一键跳过警告」的开关.
///
/// 还有一条**本机无法检测**的前置：设备必须先关网络，否则 `mobileactivationd`
/// 会立刻联网重新激活、白做 —— 只能写进确认文案让用户自行保证（见 `ActivationView`）.
enum ActivationService {

    // MARK: - 类型

    /// 激活状态（lockdown `ActivationState` 的取值）.
    enum ActivationState: String {
        case activated = "Activated"
        case unactivated = "Unactivated"
        case factoryActivated = "FactoryActivated"
        /// 读不到 / 不认识的取值
        case unknown = ""

        var label: String {
            switch self {
            case .activated: return "已激活"
            case .unactivated: return "未激活"
            case .factoryActivated: return "工厂激活"
            case .unknown: return "读取失败"
            }
        }
    }

    /// 激活锁（「查找我的 iPhone」）三态.
    /// **unknown 与 on 同等对待** —— 不可逆操作不能建立在「没读到就当没有」上.
    enum ActivationLock {
        case off
        case on
        case unknown

        var label: String {
            switch self {
            case .off: return "已关闭"
            case .on: return "已开启"
            case .unknown: return "读取失败"
            }
        }
    }

    /// 设备状态 + 前置闸结论.
    struct Status {
        let activationState: ActivationState
        let activationLock: ActivationLock
        /// 三条前置全过才 true
        let canDeactivate: Bool
        /// 不能执行时的原因（界面直接显示这一句）；可执行时为 nil
        let blockedReason: String?
    }

    enum DeactivateError: LocalizedError {
        case noPairingFile
        case tunnelFailed(String)
        case connectFailed(String)
        case readFailed(String)
        case blocked(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noPairingFile:
                return "未检测到配对文件.请先导入配对文件（需 LocalDevVPN + 开发者模式）"
            case .tunnelFailed(let m):
                return "建立隧道失败：\(m)"
            case .connectFailed(let m):
                return "连接设备服务失败：\(m)"
            case .readFailed(let m):
                return "读取设备状态失败：\(m)"
            case .blocked(let m):
                // 前置闸的原因原样透出（不套「反激活失败」前缀）
                return m
            case .failed(let m):
                return "反激活失败：\(m)"
            }
        }
    }

    // MARK: - 路径

    private static var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    // MARK: - 隧道

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    /// 建隧道（与 `IconCleanupService` / `JITEnableService` 同款：3 次重试 + 短退避）.
    private static func makeTunnel(hostname: String) throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw DeactivateError.noPairingFile
        }
        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw DeactivateError.tunnelFailed(message(from: ffiError, fallback: "读取配对文件失败"))
        }
        guard let pairingFile else { throw DeactivateError.tunnelFailed("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw DeactivateError.tunnelFailed("隧道 IP 无效：\(deviceIP)")
        }

        var lastError: String?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = hostname.withCString { hostname in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hostname,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
                    }
                }
            }
            if let ffiError {
                lastError = message(from: ffiError, fallback: "创建开发者隧道失败")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = "创建开发者隧道失败"
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw DeactivateError.tunnelFailed(lastError ?? "创建开发者隧道失败")
    }

    /// 把 FFI 错误转成可读文案（读完即释放）.
    private static func message(from ffiError: UnsafeMutablePointer<IdeviceFfiError>, fallback: String) -> String {
        let code = ffiError.pointee.code
        let text = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        idevice_error_free(ffiError)
        return text.isEmpty ? "\(fallback)（code=\(code)）" : text
    }

    /// 读 lockdown 单键，返回解码后的 plist 对象.
    ///
    /// 注意 `com.apple.fmip` 整域读是空的，但**单键**有值（`DeviceInfoService:503` 已实测），
    /// 所以这里必须用 `lockdownd_get_value(client, key, domain, ...)` 的单键形式.
    private static func value(_ client: OpaquePointer, key: String, domain: String?) throws -> Any? {
        var node: plist_t?
        var rc: UnsafeMutablePointer<IdeviceFfiError>?
        if let domain {
            rc = key.withCString { keyCStr in
                domain.withCString { domainCStr in
                    lockdownd_get_value(client, keyCStr, domainCStr, &node)
                }
            }
        } else {
            rc = key.withCString { keyCStr in
                lockdownd_get_value(client, keyCStr, nil, &node)
            }
        }
        if let rc {
            throw DeactivateError.readFailed(message(from: rc, fallback: "读取 \(key) 失败"))
        }
        guard let node else { return nil }
        defer { plist_free(node) }
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
              let binPtr, binLen > 0 else { return nil }
        defer { plist_mem_free(binPtr) }
        return try? PropertyListSerialization.propertyList(
            from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil)
    }

    // MARK: - 状态读取（只读，不改设备）

    /// 读设备当前状态并给出前置闸结论.
    ///
    /// 单条隧道内读两个键（`ActivationState` + `com.apple.fmip.IsAssociated`），
    /// 避免两次建隧道；整段跑在 `AFCService` 的串行队列上（RSD 隧道并发铁律）.
    /// 同步阻塞 —— 调用方放到后台线程.
    static func readStatus() throws -> Status {
        // 显式标注出参类型（而不是给闭包写 `() -> (…)` 签名）——
        // 后者会把闭包声明成非 throwing，里面的 `try` 就编不过了.
        let read: (state: String?, lock: Bool?) = try AFCService.shared.runExclusively {
            var tunnel = try makeTunnel(hostname: "EscapeSpaceActivation")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw DeactivateError.tunnelFailed("隧道未建立")
            }
            var client: OpaquePointer?
            if let ffiError = lockdownd_connect_rsd(adapter, handshake, &client) {
                throw DeactivateError.connectFailed(message(from: ffiError, fallback: "连接 lockdownd 失败"))
            }
            defer { lockdownd_client_free(client) }
            guard let client else { throw DeactivateError.connectFailed("连接 lockdownd 失败") }

            let state = try value(client, key: "ActivationState", domain: nil) as? String
            let lock = try value(client, key: "IsAssociated", domain: "com.apple.fmip") as? Bool
            return (state: state, lock: lock)
        }
        let stateRaw = read.state
        let lockRaw = read.lock

        let state = ActivationState(rawValue: stateRaw ?? "") ?? .unknown
        let lock: ActivationLock
        switch lockRaw {
        case .some(true): lock = .on
        case .some(false): lock = .off
        case .none: lock = .unknown
        }

        let reason: String?
        if state != .activated {
            reason = (state == .unactivated || state == .factoryActivated)
                ? "设备已是\(state.label)状态，无须再反激活"
                : "无法确认设备激活状态"
        } else if lock == .on {
            reason = "已开启激活锁（查找我的 iPhone），反激活后设备将无法重新激活"
        } else if lock == .unknown {
            reason = "无法确认激活锁状态，请先在设备上关闭「查找我的 iPhone」"
        } else {
            reason = nil
        }

        return Status(activationState: state,
                      activationLock: lock,
                      canDeactivate: reason == nil,
                      blockedReason: reason)
    }

    // MARK: - 反激活（不可逆）

    /// 下发 `{ Command = "DeactivateRequest" }`，作废本机激活记录.
    ///
    /// - Important: 本函数**自带硬闸** —— 进入前先 `readStatus()`，前置不满足直接抛
    ///   `.blocked`，不依赖界面是否禁用按钮（界面那道只是第一层，这里是不给绕过的第二层）.
    ///   界面那道「不可跳过的确认弹窗」仍必须存在：本函数是同步 IO，不能自己弹窗.
    /// - Note: 整段跑在 `AFCService` 的串行队列上（RSD 隧道并发铁律）.
    ///   注意 `readStatus()` 内部也会进同一条串行队列，所以**必须等它返回后**再进队列 ——
    ///   在队列里再 `sync` 同一条队列会死锁.
    ///   上游注释说 Deactivate 可能**不给应答**，故以「FFI 返回 nil 错误」为准.
    static func deactivate() throws {
        let status = try readStatus()
        guard status.canDeactivate else {
            throw DeactivateError.blocked(status.blockedReason ?? "前置条件未满足，已阻止反激活")
        }

        try AFCService.shared.runExclusively {
            var tunnel = try makeTunnel(hostname: "EscapeSpaceActivation")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw DeactivateError.tunnelFailed("隧道未建立")
            }
            // 动作型 `_rsd` FFI：只吃 adapter + handshake，内部自建 lockdown 连接、
            // StartService("com.apple.mobileactivationd")、连端口、发二进制 plist.
            if let ffiError = mobileactivationd_deactivate_rsd(adapter, handshake) {
                throw DeactivateError.failed(message(from: ffiError, fallback: "反激活失败"))
            }
            LoginLogger.shared.log("[反激活] 已下发 DeactivateRequest（RSD 通道）", category: .general)
        }
    }
}
