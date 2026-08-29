import Foundation

/// 设备控制服务：重启 SpringBoard（sigkill）/ 重启设备 / 关机 / 进入恢复模式。
///
/// 全部走「配对文件 + LocalDevVPN 本地隧道」的 RSD 通道（与进程管理 / 虚拟定位
/// 同一套机制），复用 idevice.h 暴露的 C 函数：
/// - `app_service_*`：枚举进程 + 发送信号 → sigkill SpringBoard
/// - `diagnostics_relay_client_*`：重启 / 关机
/// - `lockdownd_connect_rsd` + `lockdownd_enter_recovery`：进入恢复模式
///
/// 「网页崩溃 SpringBoard」不需要隧道（本进程 WKWebView 内存压力），见
/// `RespringView`（ConfigurationsView 已使用），由 UI 层直接展示。
final class DeviceControlService {

    static let shared = DeviceControlService()
    private init() {}

    /// EscapeSpace 的配对文件路径（与「应用」页 / 进程管理共用）。
    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "DeviceControl", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message: String
        if let cString = ffiError.pointee.message {
            message = String(cString: cString)
        } else {
            message = ""
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "DeviceControl", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: 隧道（与 ProcessManagerService 同款写法）

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private func createTunnel(hostname: String) throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件。请先在「应用」页导入配对文件（需 LocalDevVPN + 开发者模式）。")
        }

        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian

        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = hostname.withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn,
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
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if attempt < 2 {
                usleep(useconds_t(300_000 * (attempt + 1)))
            }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }

    // MARK: 进程信号

    /// connect 失败自动重试（最多 3 次、短退避）。RSD 服务发现偶发
    /// 「ServiceNotFound」——多页面并发建隧道竞争导致，重试覆盖大部分偶发失败。
    private func withAppService<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var tunnel = try createTunnel(hostname: "EscapeSpaceDevice")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var lastError: NSError?
        for attempt in 0..<3 {
            var appService: OpaquePointer?
            if let ffiError = app_service_connect_rsd(adapter, handshake, &appService) {
                lastError = error(from: ffiError, fallback: "连接应用服务失败")
            } else if let appService {
                defer { app_service_free(appService) }
                return try body(appService)
            } else {
                lastError = makeError("连接应用服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接应用服务失败")
    }

    /// 在设备进程列表里找 SpringBoard 的 PID（可执行路径包含 SpringBoard）。
    func springBoardPID() throws -> Int? {
        try withAppService { appService in
            var processes: UnsafeMutablePointer<ProcessTokenC>?
            var count = UInt(0)
            if let ffiError = app_service_list_processes(appService, &processes, &count) {
                throw error(from: ffiError, fallback: "枚举进程失败")
            }
            defer {
                if let processes { app_service_free_process_list(processes, count) }
            }
            guard let processes else { return nil }
            for index in 0..<Int(count) {
                let p = processes[index]
                if let path = p.executable_url.flatMap({ String(cString: $0) }),
                   path.contains("SpringBoard") {
                    return Int(p.pid)
                }
            }
            return nil
        }
    }

    /// 方法一：SIGKILL 终止 SpringBoard（桌面立即重启，App 进程保留）。
    func respringSpringBoard() throws {
        let pid = try springBoardPID()
        guard let pid else { throw makeError("未在进程列表中找到 SpringBoard") }
        var tunnel = try createTunnel(hostname: "EscapeSpaceDevice")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var appService: OpaquePointer?
        var connectError: NSError?
        for attempt in 0..<3 {
            var candidate: OpaquePointer?
            if let ffiError = app_service_connect_rsd(adapter, handshake, &candidate) {
                connectError = error(from: ffiError, fallback: "连接应用服务失败")
            } else if let candidate {
                appService = candidate
                break
            } else {
                connectError = makeError("连接应用服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        guard let appService else { throw connectError ?? makeError("连接应用服务失败") }
        defer { app_service_free(appService) }

        var response: UnsafeMutablePointer<SignalResponseC>?
        let ffiError = app_service_send_signal(appService, UInt32(pid), UInt32(SIGKILL), &response)
        if let ffiError {
            throw error(from: ffiError, fallback: "发送 SIGKILL 失败")
        }
        defer { if let response { app_service_free_signal_response(response) } }
    }

    // MARK: 电源（diagnostics relay）

    private func withDiagnosticsRelay<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var tunnel = try createTunnel(hostname: "EscapeSpaceDevice")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var lastError: NSError?
        for attempt in 0..<3 {
            var client: OpaquePointer?
            if let ffiError = diagnostics_relay_client_connect_rsd(adapter, handshake, &client) {
                lastError = error(from: ffiError, fallback: "连接诊断服务失败（该功能需要配对 + LocalDevVPN）")
            } else if let client {
                defer { diagnostics_relay_client_free(client) }
                return try body(client)
            } else {
                lastError = makeError("连接诊断服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接诊断服务失败")
    }

    /// 重启设备。
    func restartDevice() throws {
        try withDiagnosticsRelay { client in
            if let ffiError = diagnostics_relay_client_restart(client) {
                throw error(from: ffiError, fallback: "发送重启指令失败")
            }
        }
    }

    /// 关机。
    func shutdownDevice() throws {
        try withDiagnosticsRelay { client in
            if let ffiError = diagnostics_relay_client_shutdown(client) {
                throw error(from: ffiError, fallback: "发送关机指令失败")
            }
        }
    }

    // MARK: 恢复模式（lockdownd）

    /// 进入恢复模式（设备屏幕显示连接电脑图标）。
    func enterRecovery() throws {
        var tunnel = try createTunnel(hostname: "EscapeSpaceDevice")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var client: OpaquePointer?
        var connectError: NSError?
        for attempt in 0..<3 {
            var candidate: OpaquePointer?
            if let ffiError = lockdownd_connect_rsd(adapter, handshake, &candidate) {
                connectError = error(from: ffiError, fallback: "连接 lockdownd 失败")
            } else if let candidate {
                client = candidate
                break
            } else {
                connectError = makeError("连接 lockdownd 失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        guard let client else { throw connectError ?? makeError("连接 lockdownd 失败") }
        defer { lockdownd_client_free(client) }

        if let ffiError = lockdownd_enter_recovery(client) {
            throw error(from: ffiError, fallback: "发送恢复模式指令失败")
        }
    }
}
