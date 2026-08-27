import Foundation
import UIKit

/// 启用 JIT 服务（汉化移植自 StikDebug 的 JITEnableContext，核心机制同源）。
///
/// 原理：通过 LocalDevVPN 隧道（RPPairing 配对文件）连接设备的 debug_proxy /
/// process_control 开发者服务，以「调试模式」启动目标 App——App 进程带
/// get-task-allow 调试附着启动后即获得 JIT 权限（与 debugserver attach 等价，
/// 无越狱要求；与 Xcode「在设备上调试」同一通道）。
///
/// 前提：配对文件（Documents/pairingFile.plist）+ LocalDevVPN 已连接 + 目标 App
/// 的签名带 get-task-allow（证书直装签名默认带）。
final class JITEnableService {

    static let shared = JITEnableService()

    private init() {}

    /// EscapeSpace 的配对文件路径（与「应用」页 / 虚拟定位共用）。
    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "JITEnable", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
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
        return NSError(domain: "JITEnable", code: code, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
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

        // 隧道建立失败自动重试（最多 3 次、短退避）：Wi-Fi↔蜂窝切换等
        // 瞬时抖动会导致 RPPairing 握手失败，重试后通常成功
        // （对齐 StikDebug PR #432 的隧道重试思路）。
        var lastError: NSError?
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

    // MARK: - 应用列表

    /// 列出全部已安装应用（含系统应用，用于「拉起应用」）。
    func listAllApps() throws -> [JITAppInfo] {
        try listApps(requireGetTaskAllow: false)
    }

    /// 列出可启用 JIT 的应用（签名带 get-task-allow 的已安装应用）。
    func listJITCapableApps() throws -> [JITAppInfo] {
        try listApps(requireGetTaskAllow: true)
    }

    private func listApps(requireGetTaskAllow: Bool) throws -> [JITAppInfo] {
        var tunnel = try createTunnel(hostname: "EscapeSpaceJITList")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        var client: OpaquePointer?
        if let ffiError = installation_proxy_connect_rsd(adapter, handshake, &client) {
            throw error(from: ffiError, fallback: "连接安装代理失败")
        }
        defer { installation_proxy_client_free(client) }
        guard let client else { throw makeError("连接安装代理失败") }

        var rawApps: UnsafeMutableRawPointer?
        var count = 0
        if let ffiError = installation_proxy_get_apps(client, nil, nil, 0, &rawApps, &count) {
            throw error(from: ffiError, fallback: "获取应用列表失败")
        }
        guard let rawApps, count > 0 else { return [] }

        let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count {
                plist_free(apps[index])
            }
            idevice_data_free(rawApps.assumingMemoryBound(to: UInt8.self), UInt(count * MemoryLayout<plist_t?>.stride))
        }

        var result: [JITAppInfo] = []
        for index in 0..<count {
            var binaryPlist: UnsafeMutablePointer<CChar>?
            var binaryLength: UInt32 = 0
            guard plist_to_bin(apps[index], &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                  let binaryPlist, binaryLength > 0 else { continue }
            let data = Data(bytes: binaryPlist, count: Int(binaryLength))
            plist_mem_free(binaryPlist)

            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any],
                  let bundleID = dict["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else { continue }

            if requireGetTaskAllow {
                // 只看用户安装且带 get-task-allow 的应用（JIT 调试启动的前提）。
                guard let entitlements = dict["Entitlements"] as? [String: Any],
                      (entitlements["get-task-allow"] as? Bool) == true else { continue }
            }

            let name = (dict["CFBundleDisplayName"] as? String)
                ?? (dict["CFBundleName"] as? String)
                ?? bundleID
            result.append(JITAppInfo(bundleID: bundleID, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - App 图标

    /// 通过 SpringBoardServices 服务获取应用图标（与 StikDebug 同源）。
    /// 设备端按 Bundle ID 返回真实图标 PNG —— 对系统应用与第三方应用均有效。
    ///
    /// 为什么不用进程内私有 API `UIImage._applicationIconImageForBundleIdentifier:format:scale:`：
    /// 它读的是本机 IconServices 图标缓存，证书直装 / 侧载的第三方应用经常取不到
    /// （图标不在该缓存可达范围）→ 列表显示灰色占位；而 SpringBoardServices 由
    /// 设备端按 bundle id 查询，与查询方沙盒无关，任何已安装应用都能拿到。
    func getAppIcon(bundleID: String) throws -> UIImage {
        var tunnel = try createTunnel(hostname: "EscapeSpaceIcon")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        var client: OpaquePointer?
        if let ffiError = springboard_services_connect_rsd(adapter, handshake, &client) {
            throw error(from: ffiError, fallback: "连接主屏服务失败")
        }
        defer { springboard_services_free(client) }
        guard let client else { throw makeError("连接主屏服务失败") }

        var rawIconData: UnsafeMutableRawPointer?
        var rawIconLength = 0
        if let ffiError = bundleID.withCString { cString in
            springboard_services_get_icon(client, cString, &rawIconData, &rawIconLength)
        } {
            throw error(from: ffiError, fallback: "获取应用图标失败")
        }
        guard let rawIconData, rawIconLength > 0 else {
            throw makeError("应用图标数据为空")
        }
        // Rust 侧分配（into_boxed_slice），必须用 Rust 侧释放函数。
        defer { idevice_data_free(rawIconData.assumingMemoryBound(to: UInt8.self), UInt(rawIconLength)) }

        let data = Data(bytes: rawIconData, count: rawIconLength)
        guard let image = UIImage(data: data) else {
            throw makeError("应用图标解码失败")
        }
        return image
    }

    // MARK: - 拉起应用（普通启动，不调试）

    /// 普通启动指定应用（不启用 JIT）。
    func launchApp(bundleID: String) throws {
        var tunnel = try createTunnel(hostname: "EscapeSpaceLaunch")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        var remoteServer: OpaquePointer?
        if let ffiError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            throw error(from: ffiError, fallback: "连接设备服务失败")
        }
        defer { remote_server_free(remoteServer) }
        guard let remoteServer else { throw makeError("连接设备服务失败") }

        var processControl: OpaquePointer?
        if let ffiError = process_control_new(remoteServer, &processControl) {
            throw error(from: ffiError, fallback: "打开进程控制失败")
        }
        defer { process_control_free(processControl) }
        guard let processControl else { throw makeError("打开进程控制失败") }

        var pid: UInt64 = 0
        if let ffiError = bundleID.withCString { bundleID in
            process_control_launch_app(processControl, bundleID, nil, 0, nil, 0, false, true, &pid)
        } {
            throw error(from: ffiError, fallback: "启动应用失败（应用可能未安装）")
        }
        guard pid != 0 else { throw makeError("启动应用失败：未取得进程号") }
    }

    // MARK: - 启用 JIT

    /// 以调试模式启动目标应用，使其获得 JIT 权限。
    /// 调用后应用会被拉起（EscapeSpace 退到后台），JIT 保持到应用退出。
    func enableJIT(bundleID: String, progress: ((String) -> Void)? = nil) throws {
        // 关键保活：process_control 调试启动目标应用后，本应用立即退到后台，
        // iOS 数秒内就会挂起进程——若此时 attach/detach 流程还没跑完，
        // 目标应用会一直停在 SIGSTOP（黑屏无反应）。持有后台租约保证
        // 整个会话期间本应用不被挂起（对齐 StikDebug 的 DebugKeepAliveLease）。
        let keepAliveLease = JITBackgroundLease()
        defer { keepAliveLease.invalidate() }

        var tunnel = try createTunnel(hostname: "EscapeSpaceJIT")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        // 1) 连接 RemoteXPC
        var remoteServer: OpaquePointer?
        if let ffiError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            throw error(from: ffiError, fallback: "连接设备服务失败")
        }
        defer { remote_server_free(remoteServer) }
        guard let remoteServer else { throw makeError("连接设备服务失败") }

        // 2) 连接调试代理（debug_proxy）
        var debugProxy: OpaquePointer?
        if let ffiError = debug_proxy_connect_rsd(adapter, handshake, &debugProxy) {
            throw error(from: ffiError, fallback: "连接调试代理失败")
        }
        defer { debug_proxy_free(debugProxy) }
        guard let debugProxy else { throw makeError("连接调试代理失败") }

        // 3) 以调试模式启动应用（process_control）
        var processControl: OpaquePointer?
        if let ffiError = process_control_new(remoteServer, &processControl) {
            throw error(from: ffiError, fallback: "打开进程控制失败")
        }
        defer { process_control_free(processControl) }
        guard let processControl else { throw makeError("打开进程控制失败") }

        var pid: UInt64 = 0
        progress?("正在以调试模式启动 \(bundleID)…")
        if let ffiError = bundleID.withCString { bundleID in
            process_control_launch_app(processControl, bundleID, nil, 0, nil, 0, true, false, &pid)
        } {
            throw error(from: ffiError, fallback: "调试模式启动失败（应用可能未安装或签名不带 get-task-allow）")
        }
        guard pid != 0 else { throw makeError("调试模式启动失败：未取得进程号") }

        // 4) debugserver 握手 + attach + detach（让调试器确认 JIT 生效）
        debug_proxy_send_ack(debugProxy)
        debug_proxy_send_ack(debugProxy)

        if let cmd = debugserver_command_new("QStartNoAckMode", nil, 0) {
            var response: UnsafeMutablePointer<CChar>?
            let err = debug_proxy_send_command(debugProxy, cmd, &response)
            debugserver_command_free(cmd)
            if let response { idevice_string_free(response) }
            if let err { idevice_error_free(err) }
            debug_proxy_set_ack_mode(debugProxy, 0)
        }

        let attachCommand = "vAttach;\(String(UInt32(pid), radix: 16))"
        progress?("正在附着调试器 (PID \(pid))…")
        if let cmd = debugserver_command_new(attachCommand, nil, 0) {
            var response: UnsafeMutablePointer<CChar>?
            let err = debug_proxy_send_command(debugProxy, cmd, &response)
            debugserver_command_free(cmd)
            if let err {
                if let response { idevice_string_free(response) }
                throw error(from: err, fallback: "调试器附着失败")
            }
            if let response {
                let text = String(cString: response)
                idevice_string_free(response)
                // debugserver 的 vAttach 成功时返回的是 stop reply（如
                // `T11thread:...;...`，T11 = SIGSTOP，目标进程被暂停），**不是 "OK"**。
                // 只有以 "E" 开头的响应（debugserver 错误包）才是真正的失败。
                // v0.2.71 误把成功响应当失败 → throw 后 detach 未执行，目标应用
                // 停在 SIGSTOP、连接断开后被 debugserver 终止（闪退）。
                // 对齐 StikDebug：原版不检查 attach 响应，成功失败都继续 detach。
                if text.hasPrefix("E") {
                    throw makeError("调试器附着失败：\(text)")
                }
            }
        }

        // 5) 分离调试器——JIT 保留，应用正常运行
        if let cmd = debugserver_command_new("D", nil, 0) {
            var response: UnsafeMutablePointer<CChar>?
            let err = debug_proxy_send_command(debugProxy, cmd, &response)
            debugserver_command_free(cmd)
            if let response { idevice_string_free(response) }
            if let err { idevice_error_free(err) }
        }

        progress?("JIT 已启用并分离调试器")
    }
}

/// 可启用 JIT 的应用。
struct JITAppInfo: Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
}

/// App 图标内存缓存加载器（「启用 JIT」/「拉起应用」共用）。
///
/// 与 StikDebug 的 AppIconRepository 同思路：icon 通过 RSD 隧道向设备端
/// SpringBoardServices 服务获取（每次请求需建隧道，较慢），因此必须
/// ① 内存缓存（滚动不重复建隧道）；② in-flight 去重（同一 bundle id 只建一次）；
/// ③ 限制并发（避免一次给几十个应用同时建隧道）。
@MainActor
final class JITAppIconLoader {
    static let shared = JITAppIconLoader()

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let semaphore = IconFetchSemaphore(permits: 4)

    private init() {}

    /// 已缓存图标（同步查询，用于避免重复触发加载）。
    func cached(for bundleID: String) -> UIImage? { cache[bundleID] }

    /// 异步取图标：命中缓存直接返回；否则建隧道获取（失败返回 nil，由调用方回退占位）。
    func load(bundleID: String) async -> UIImage? {
        if let img = cache[bundleID] { return img }
        if let task = inFlight[bundleID] { return await task.value }

        let task = Task<UIImage?, Never> {
            let img = await semaphore.withPermit {
                await Task.detached(priority: .utility) {
                    try? JITEnableService.shared.getAppIcon(bundleID: bundleID)
                }.value
            }
            if let img { cache[bundleID] = img }
            inFlight[bundleID] = nil
            return img
        }
        inFlight[bundleID] = task
        return await task.value
    }
}

/// 简易信号量：限制同时建隧道的数量。
private actor IconFetchSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) { self.permits = permits }

    func withPermit<T>(_ body: @escaping () async -> T) async -> T {
        await acquire()
        let value = await body()
        release()
        return value
    }

    private func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }
}

/// JIT 会话后台保活租约（对齐原版 StikDebug 的 DebugKeepAliveLease 与
/// PR #432 的续期思路）。
///
/// 为什么必须保活：`process_control_launch_app(debug: true)` 调试启动目标应用后，
/// 本应用立即退到后台，iOS 数秒内就会挂起进程。若此时 QStartNoAckMode /
/// vAttach / D（detach）流程尚未完成，目标应用会一直停在 SIGSTOP ——
/// 表现为启动后永久黑屏无反应。
///
/// 为什么不用静音音频保活：目标应用启动时会激活自己的 AVAudioSession，
/// 抢占/打断本应用的音频会话（KeepAliveManager 等音频保活会失效，
/// 这是 v0.2.73 前用户开启「保持后台运行」仍黑屏的根因）。因此这里
/// 只依赖 `beginBackgroundTask`：到期自动续期，直到 JIT 会话结束
/// （invalidate），与用户设置、音频会话完全解耦。
private final class JITBackgroundLease {
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isActive = true

    init() {
        DispatchQueue.main.sync {
            renew()
        }
    }

    /// 申请后台执行宽限；到期回调里若会话仍活跃则自动续期。
    /// 会话通常只有几秒，最多续期 1~2 次，不会触发系统惩罚。
    private func renew() {
        guard isActive else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "EscapeSpaceJIT") { [weak self] in
            guard let self, self.isActive else { return }
            self.renew()
        }
    }

    func invalidate() {
        isActive = false
        DispatchQueue.main.sync {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
    }
}
