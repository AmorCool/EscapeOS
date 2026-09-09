import Foundation

// 虚拟定位：DVT 定位模拟引擎（移植自 Bellaboy/locus-ZH，MIT）.
//
// 原理：通过 LocalDevVPN 本机隧道（10.7.0.1:49152）+ RPPairing 配对文件，
// 走 Apple 开发者工具用的 DVT location simulation 服务（Xcode「模拟位置」
// 同一机制），把模拟坐标注入 locationd——不需要越狱 / 漏洞.
// FFI 符号（location_simulation_* 等）由 rust/idevice-ffi 提供，
// 经 TunnelContext.h → idevice.h 暴露给 Swift（见 EscapeOS-Bridging-Header.h）.

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "隧道 IP 无效.请检查设置 → 本地隧道（默认 10.7.0.1）."
        case .pairingRead: return "无法读取配对文件.请用 idevice_pair 生成 RPPairing 格式的配对文件并导入."
        case .tunnelCreate: return "无法建立开发隧道.请确认 LocalDevVPN 已连接（Wi-Fi 下）."
        case .remoteServer: return "已连接隧道，但 RemoteXPC 握手失败."
        case .simulationCreate: return "无法打开 Apple 的定位模拟服务."
        case .locationSet: return "设置模拟坐标失败."
        case .locationClear: return "清除模拟定位失败."
        case .notActive: return "当前没有活动的模拟会话."
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

/// idevice DVT 定位模拟的薄封装（注入 locationd）.
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.escapeos.location", qos: .userInitiated)

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12

    static var isSessionActive: Bool { locationSimulation != nil }

    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.locationSet)
        queue.sync {
            let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    static func clear() -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .failure(.notActive)
        queue.sync {
            let code = clearLocked()
            result = code == ok ? .success(()) : .failure(.from(code: code))
        }
        return result
    }

    /// v0.3.252：SIGKILL locationd.
    /// 清掉模拟坐标后，系统定位守护仍向客户端回报最后一次模拟值（守护内部状态 +
    /// 客户端缓存），表现为「清除成功但定位不刷新」——手动 kill 就能立刻恢复.
    /// App 无 root 直接 kill 必被 EPERM 拒（v0.3.251 真机实锤 kill 静默失败），
    /// 所以先 `setuid(0)` 提权（Dopamine 允许 App 提权）再 kill，杀完切回 501.
    /// 返回 kill 是否真的成功，调用方如实反馈.
    @discardableResult
    static func killLocationd() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc]()
        for _ in 0..<4 {                                    // 进程表可能在两次调用间增长，重试几次
            procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
            var sz = procs.count * stride
            if sysctl(&mib, 3, &procs, &sz, nil, 0) == 0 {
                let count = sz / stride
                for i in 0..<count {
                    let p = procs[i].kp_proc
                    let name = withUnsafeBytes(of: p.p_comm) { raw -> String in
                        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                    }
                    if name == "locationd" {
                        // 提权：App 普通身份 kill 守护进程必 EPERM；Dopamine 下 setuid(0) 可行
                        setgid(0)
                        setuid(0)
                        let ok = kill(p.p_pid, SIGKILL) == 0
                        setuid(501)                                  // 切回 mobile，避免影响沙盒内写文件
                        if ok { return true }
                    }
                }
                return false
            }
            if errno != ENOMEM { return false }
        }
        return false
    }

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Int32 {
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(err)
                cleanup()
            } else {
                return ok
            }
        }
        // 无活动会话（或旧会话已失效被清）→ 建立新会话再设值
        let connectCode = connectLocked(pairingPath: pairingPath, deviceIP: deviceIP)
        guard connectCode == ok else { return connectCode }
        guard let locationSimulation else { return simulationCreate }
        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(setError)
            cleanup()
            return locationSet
        }
        return ok
    }

    /// 建立 隧道→RemoteXPC→DVT 定位模拟会话（不动设备状态）.
    /// v0.3.245：从 setLocked 抽出——clear 在无活动会话时也要能建会话下发清除
    /// （App 重启后内存句柄为空，但设备 locationd 里可能残留上次注入的模拟坐标）.
    private static func connectLocked(pairingPath: String, deviceIP: String) -> Int32 {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return invalidIP }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "EscapeSpaceLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let providerError {
            idevice_error_free(providerError)
            cleanup()
            return tunnelCreate
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            idevice_error_free(remoteServerError)
            cleanup()
            return remoteServerCode
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            idevice_error_free(simError)
            cleanup()
            return simulationCreate
        }
        // location_simulation_new 接管 remote server 生命周期
        remoteServer = nil
        return ok
    }

    private static func clearLocked() -> Int32 {
        // v0.3.245 修复「清除模拟定位失败」：旧实现在无活动会话时直接报错——
        // App 重启后内存句柄必为空，一点清除就失败，而设备侧残留的模拟定位
        // 恰恰需要经 DVT 会话才能清掉（pmd3 `location clear` 同款：新建会话再
        // clear）.现在无会话时先建会话再清除；新建会话后清除报错按成功处理
        // （目标态即「无模拟」，幂等——设备重启后本就无残留，clear 被拒亦无妨）.
        let hadSession = locationSimulation != nil
        if !hadSession {
            // 与 SpoofSession.pairingPath 同一路径（共用 Documents/pairingFile.plist），
            // 不经 SpoofSession 取值——其属性挂在 @MainActor，queue.sync 内不可跨.
            let pairingPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("pairingFile.plist").path
            let connectCode = connectLocked(pairingPath: pairingPath, deviceIP: LocalDevVPN.targetIP)
            guard connectCode == ok else { return connectCode }
        }
        guard let locationSimulation else { return locationClear }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            idevice_error_free(err)
            // 会话是本次新建的：清除失败多为设备本无活动模拟（重启后），按幂等成功处理；
            // 旧会话路径的清除失败仍是真失败（隧道断开等）.
            return hadSession ? locationClear : ok
        }
        return ok
    }
}
