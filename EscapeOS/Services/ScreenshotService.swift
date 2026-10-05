//
//  ScreenshotService.swift
//  EscapeOS
//
//  v0.3.5xx：宿主能力 `ui.screenshot` 的底层实现 —— 经 RSD 隧道 + DVT 取屏幕截图。
//
//  ## 注意： 为什么不是 screenshotr（2026-10-05 更正）
//  原实现走 `screenshotr_*`，**在本设备必现 `ServiceNotFound(21)`**：
//  本设备的 RSD 服务表里**根本没有 screenshotr 服务**（真机服务表 dump `grep -ic screenshot == 0`；
//  PC 侧 pymobiledevice3 交叉验证一致；`rsd.rs:171-189` 是纯 HashMap 查表、**无回退**）。
//  iOS 17 起截图已迁到 **DVT**（`developer dvt screenshot`）。
//  ⇒ 改走 DVT 三连，与「进程管理内存查询」（sysmontap，同属 DVT）**同一条路**。
//
//  ## FFI（真实签名，来自 EscapeOS/Tunnel/idevice.h）
//  · `:2963` `struct IdeviceFfiError *remote_server_connect_rsd(struct AdapterHandle *provider,
//                                                               struct RsdHandshakeHandle *handshake,
//                                                               struct RemoteServerHandle **handle);`
//  · `:2976` `void remote_server_free(struct RemoteServerHandle *handle);`
//  · `:2994` `struct IdeviceFfiError *screenshot_client_new(struct RemoteServerHandle *server,
//                                                          struct ScreenshotClientHandle **handle);`
//  · `:3010` `void screenshot_client_free(struct ScreenshotClientHandle *handle);`
//  · `:3033` `struct IdeviceFfiError *screenshot_client_take_screenshot(struct ScreenshotClientHandle *handle,
//                                                                     uint8_t **data, uintptr_t *len);`
//  · `:867`  `void idevice_data_free(uint8_t *data, uintptr_t len);`
//  释放**逆序**：idevice_data_free → screenshot_client_free → remote_server_free → 隧道。
//
//  ## 稳定性铁律
//  `rust/idevice-ffi/src/lib.rs:118-142` 的 `run_sync` **没有 timeout ⇒ C 调用可永久阻塞**。
//  ⇒ **不是 FFI 在兜底，必须我们自己兜**：本文件用信号量给整段（建隧道 + 连 DVT + 截图）
//  包一层**硬超时**（默认 15s），超时后调用线程立即拿到明确错误、**绝不挂住**。
//
//  ## 每次截图重建会话
//  上游 issue：DVT 通道长时间复用会断连、大图会阻塞。因此**每次都新建**隧道 + RemoteServer +
//  ScreenshotClient，用完即释放，不做跨调用缓存。
//
//  ## 返回的已经是 PNG
//  `screenshot_client_take_screenshot` 回传的就是 PNG 字节，无需再编码；宽高由调用方读 IHDR。
//

import Foundation
import Darwin

/// 屏幕截图服务（纯静态，无实例状态；隧道/DVT 句柄都是方法内局部量）。
///
/// `Sendable`（非 unchecked）：唯一存储属性是 `let` 的串行队列（`DispatchQueue` 本身 Sendable），
/// 其余全是方法内局部量。
final class ScreenshotService: Sendable {

    static let shared = ScreenshotService()
    private init() {}

    /// 串行队列：同一时刻只跑一次隧道 + 截图，避免 RSD/DVT 通道竞争。
    /// 若某次 C 调用真的挂住，后续调用会排在它后面一起超时 —— 这是刻意选择：
    /// 宁可让调用方拿到「超时」，也不并发建多条隧道把设备侧搞乱。
    private let operationQueue = DispatchQueue(label: "com.ipaside.escapeos.screenshot",
                                               qos: .userInitiated)

    /// EscapeSpace 的配对文件路径（与「进程管理 / 设备控制」共用同一份）。
    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "Screenshot", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
                       fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message: String
        if let cString = ffiError.pointee.message {
            message = String(cString: cString)
        } else {
            message = ""
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "Screenshot", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: - 隧道（与 ProcessManagerService / DeviceControlService 同款写法）

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
            throw makeError("未检测到配对文件.请到「更多 → 配对文件导入」导入配对文件（需 LocalDevVPN + 开发者模式）.")
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

    // MARK: - 截图（DVT）

    /// 取一张 PNG 截图（带硬超时，超时抛错而非挂住）。
    ///
    /// - Parameter timeout: 秒；覆盖「建隧道 + 连 DVT + 截图」全过程。
    /// - Returns: PNG 字节。
    func capturePNG(timeout: TimeInterval = 15) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        operationQueue.async {
            do { box.result = .success(try self.capturePNGSync()) }
            catch { box.result = .failure(error) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            // 面向调用方/用户只给一句可行动的短句；「C 调用无法取消、只能放弃」的细节留在文件头注释里。
            throw makeError("截图超时（\(Int(timeout)) 秒）：设备未返回，请确认 LocalDevVPN 已连接后重试。")
        }
        guard let result = box.result else {
            throw makeError("截图失败（后台未产生结果）")
        }
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    /// 真正干活（阻塞）：建隧道 → RemoteServer → ScreenshotClient → 截图。
    /// 只允许在 `operationQueue` 上跑（`capturePNG` 已经这么做了）。
    private func capturePNGSync() throws -> Data {
        var tunnel = try createTunnel(hostname: "EscapeSpaceScreenshot")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        // 1. RemoteServer（DVT 底座，与 sysmontap 同一套）
        var server: OpaquePointer?
        if let ffiError = remote_server_connect_rsd(adapter, handshake, &server) {
            throw error(from: ffiError, fallback: "创建 RemoteServer 失败（DVT 底座）")
        }
        guard let server else { throw makeError("RemoteServer 为空") }
        defer { remote_server_free(server) }

        // 2. ScreenshotClient
        var client: OpaquePointer?
        if let ffiError = screenshot_client_new(server, &client) {
            throw error(from: ffiError, fallback: "创建 ScreenshotClient 失败")
        }
        guard let client else { throw makeError("ScreenshotClient 为空") }
        defer { screenshot_client_free(client) }

        // 3. 截图（回传的就是 PNG）
        var data: UnsafeMutablePointer<UInt8>?
        var len: UInt = 0
        if let ffiError = screenshot_client_take_screenshot(client, &data, &len) {
            throw error(from: ffiError, fallback: "截图失败")
        }
        guard let data, len > 0 else { throw makeError("截图返回空数据") }
        defer { idevice_data_free(data, len) }   // 逆序释放：data → client → server → tunnel

        return Data(bytes: data, count: Int(len))
    }

    /// 跨线程传结果的小盒子。写入发生在 `sem.signal()` 之前、读取发生在 `sem.wait()` 之后，
    /// 有 happens-before 保证，故 `@unchecked Sendable` 成立。
    private final class ResultBox: @unchecked Sendable {
        var result: Result<Data, Error>?
    }
}
