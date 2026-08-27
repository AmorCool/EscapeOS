import Foundation

// 虚拟定位：DVT 定位模拟引擎（移植自 Bellaboy/locus-ZH，MIT）。
//
// 原理：通过 LocalDevVPN 本机隧道（10.7.0.1:49152）+ RPPairing 配对文件，
// 走 Apple 开发者工具用的 DVT location simulation 服务（Xcode「模拟位置」
// 同一机制），把模拟坐标注入 locationd——不需要越狱 / 漏洞。
// FFI 符号（location_simulation_* 等）由 rust/idevice-ffi 提供，
// 经 TunnelContext.h → idevice.h 暴露给 Swift（见 EscapeOS-Bridging-Header.h）。

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
        case .invalidIP: return "隧道 IP 无效。请检查设置 → 本地隧道（默认 10.7.0.1）。"
        case .pairingRead: return "无法读取配对文件。请用 idevice_pair 生成 RPPairing 格式的配对文件并导入。"
        case .tunnelCreate: return "无法建立开发隧道。请确认 LocalDevVPN 已连接（Wi-Fi 下）。"
        case .remoteServer: return "已连接隧道，但 RemoteXPC 握手失败。"
        case .simulationCreate: return "无法打开 Apple 的定位模拟服务。"
        case .locationSet: return "设置模拟坐标失败。"
        case .locationClear: return "清除模拟定位失败。"
        case .notActive: return "当前没有活动的模拟会话。"
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

/// idevice DVT 定位模拟的薄封装（注入 locationd）。
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

        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(setError)
            cleanup()
            return locationSet
        }
        return ok
    }

    private static func clearLocked() -> Int32 {
        guard let locationSimulation else { return locationClear }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            idevice_error_free(err)
            return locationClear
        }
        return ok
    }
}
