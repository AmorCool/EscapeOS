import Foundation
import Network
import Darwin

/// v0.3.379：在线安装（OTA / `itms-services`）用的**本机** HTTP 服务器。
///
/// 只服务一个文件：`GET /package.ipa`，并且**必须支持 `Range` / `Accept-Ranges`**
/// （大 IPA 断点续传，参考工具牛蛙的 `GCDWebServer` 就带这一项）。
///
/// ## 为什么不复用既有的 `ProfileHTTPServer`
/// `Engine/ProfileHTTPServer.swift` 已有一套裸 socket 服务器，但它：
/// · 只服务一份固定的 `.mobileconfig` 载荷（`application/x-apple-aspen-config`），
/// · **完全不认 `Range` 头**，也没有 `Accept-Ranges`；
/// 大 IPA 走它会一次性把整包塞进一次响应，且无法续传。因此这里单独实现一个
/// 只服务一个 IPA 文件、带 Range 的服务器。
///
/// ## 监听地址（v0.3.383：默认局域网 IP）
/// 绑 **`0.0.0.0` + 随机端口**，manifest 里的 `software-package.url` 默认用**设备
/// en0 的 IPv4**（`http://<LAN-IP>:<port>/package.ipa`），取不到才回落 `127.0.0.1`。
/// 理由：系统 OTA 安装器（itunesstored/installd）**可能**不接受 loopback 形式的
/// 分发包地址（Feather / JSBox 都用局域网 IP）—— 但**这条未确证**，所以做成
/// 「默认 LAN、可回落回环」，两边都能取到（听着 0.0.0.0 即同时覆盖）。
///
/// ## 安全边界（有意收窄）
/// · 只有一个**只读**路由 `GET/HEAD /package.ipa`（无目录列举、无写、无上传）；
/// · 只发当前这一份安装包，端口随机，不做端口复用之外的任何暴露；
/// · 会话结束由 `stop(after:)` 到点即关（调用方给 15 分钟），不常驻。
///
/// ## 用途（`Purpose`）—— 单例一次只服务一份文件
/// 本服务器是 `shared` 单例，且 `start()` 会**先 `stop()` 掉上一份会话**，
/// 所以「在线安装」和「提取下载链接」这两条通道会互相挤掉。`currentPurpose`
/// 记录「现在是谁在用」，下载面板据此把会挤掉当前会话的入口**置灰**：
/// · 服务器是 `.ota`（安装中）→ 面板的「提取下载链接」不可点；
/// · 服务器是 `.share`（分享中）→ 面板的「在线安装」不可点。
final class IPALocalHTTPServer {

    static let shared = IPALocalHTTPServer()

    /// 服务器用途：`start()` 时由调用方声明，`stop()` 清空。
    enum Purpose {
        /// 「在线安装」在跑：清单已发出，等系统来拉 IPA（保活 15 分钟）。
        case ota
        /// 「提取下载链接」在跑：把本机地址分享出去（保活 10 分钟）。
        case share
    }

    /// 启动结果：端口 / 监听接口 / manifest 里用的包地址
    struct Serving {
        /// 实际监听端口
        var port: UInt16
        /// 实际监听接口（`0.0.0.0` = 所有接口）
        var listenHost: String
        /// manifest 里 `software-package` 用的地址
        var packageURL: String
        /// `packageURL` 用的是局域网 IP（false = 回落到回环）
        var usesLAN: Bool
    }

    private let queue = DispatchQueue(label: "com.ipaside.escapeos.ota.http")
    private var listener: NWListener?
    private var fileURL: URL?
    private var fileSize: UInt64 = 0
    private var stopWorkItem: DispatchWorkItem?

    /// 当前监听端口（0 = 未启动）
    private(set) var port: UInt16 = 0

    /// 当前用途（`nil` = 未启动）。面板据此把会互相挤掉的入口置灰。
    private(set) var currentPurpose: Purpose?

    private init() {}

    // MARK: - 启停

    /// 启动服务器；`fileURL` 必须是存在的本地 IPA。
    /// `purpose` 声明这次是谁在用（`stop()` 会清空）。
    @discardableResult
    func start(fileURL: URL, purpose: Purpose) throws -> Serving {
        stop()

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0 else {
            throw IPALocalHTTPServerError.emptyFile
        }

        self.fileURL = fileURL
        self.fileSize = size

        // 绑所有接口 + 系统随机端口（LAN 与回环都能取到）
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        var becameReady = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                becameReady = true
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)

        guard becameReady, let resolvedPort = listener.port?.rawValue else {
            listener.cancel()
            throw IPALocalHTTPServerError.notReady
        }

        self.listener = listener
        self.port = resolvedPort
        self.currentPurpose = purpose

        let lan = Self.lanIPv4()
        let host = lan ?? "127.0.0.1"
        return Serving(port: resolvedPort,
                       listenHost: "0.0.0.0",
                       packageURL: "http://\(host):\(resolvedPort)/package.ipa",
                       usesLAN: lan != nil)
    }

    /// 立即关闭。
    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        listener?.cancel()
        listener = nil
        port = 0
        currentPurpose = nil
        fileURL = nil
        fileSize = 0
    }

    /// 延迟关闭（给 iOS 留出拉完 IPA 的时间）。
    func stop(after delay: TimeInterval) {
        stopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        stopWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeader(connection, buffer: Data())
    }

    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: accumulated)
                return
            }
            if error != nil || isComplete || accumulated.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.readHeader(connection, buffer: accumulated)
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else {
            respondStatus(connection, status: "400 Bad Request")
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let method = parts.first.map(String.init)?.uppercased() ?? ""
        let rawTarget = parts.dropFirst().first.map(String.init) ?? ""
        let path = rawTarget.split(separator: "?").first.map(String.init) ?? ""

        guard let fileURL, fileSize > 0 else {
            respondStatus(connection, status: "404 Not Found")
            return
        }
        guard method == "GET" || method == "HEAD", path == "/package.ipa" else {
            respondStatus(connection, status: "404 Not Found")
            return
        }

        // Range: bytes=start-end
        var start: UInt64 = 0
        var end: UInt64 = fileSize - 1
        var isPartial = false
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = String(rangeLine.drop { $0 != ":" }.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            guard let spec = value.split(separator: "=").last.map(String.init),
                  let parsed = Self.parseRange(spec, total: fileSize) else {
                // 无法满足：按 RFC 回 416（带 Content-Range: bytes */total）
                let head = Self.headData("416 Range Not Satisfiable",
                                         ["Content-Range": "bytes */\(fileSize)",
                                          "Content-Length": "0",
                                          "Connection": "close"])
                connection.send(content: head, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            start = parsed.0
            end = parsed.1
            isPartial = true
        }

        let length = end - start + 1
        var headers: [String: String] = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(length)",
            "Accept-Ranges": "bytes",
            "Connection": "close"
        ]
        if isPartial {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(fileSize)"
        }

        let head = Self.headData(isPartial ? "206 Partial Content" : "200 OK", headers)
        connection.send(content: head, contentContext: .defaultMessage, isComplete: false,
                        completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                connection.cancel()
                return
            }
            guard method == "GET" else {
                // HEAD：只回头，不发体
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                connection.cancel()
                return
            }
            try? handle.seek(toOffset: start)
            FilePump(connection: connection, handle: handle, remaining: length).start()
        })
    }

    private func respondStatus(_ connection: NWConnection, status: String) {
        let head = Self.headData(status, ["Content-Length": "0", "Connection": "close"])
        connection.send(content: head, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 工具

    private static func headData(_ status: String, _ headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// 解析 `bytes=start-end` / `start-` / `-suffix`
    private static func parseRange(_ spec: String, total: UInt64) -> (UInt64, UInt64)? {
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let first = String(parts[0])
        let second = String(parts[1])

        if first.isEmpty {
            // 末尾 N 字节
            guard let suffix = UInt64(second), suffix > 0 else { return nil }
            let start = suffix >= total ? 0 : total - suffix
            return (start, total - 1)
        }
        guard let start = UInt64(first), start < total else { return nil }
        if second.isEmpty { return (start, total - 1) }
        guard let end = UInt64(second), end >= start else { return nil }
        return (start, min(end, total - 1))
    }

    /// 取设备当前的局域网 IPv4（优先 `en0` Wi-Fi；跳过回环与 169.254 自分配）。
    /// 取不到返回 `nil`，调用方回落 `127.0.0.1`。
    static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var wifi: String?
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            cursor = ifa.ifa_next

            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty, ip != "127.0.0.1", !ip.hasPrefix("169.254.") else { continue }

            if String(cString: ifa.ifa_name) == "en0" {
                wifi = ip
                break
            }
            if fallback == nil { fallback = ip }
        }
        return wifi ?? fallback
    }

    /// 分块把文件发给客户端（背压式：上一块发完才读下一块，避免把整包读进内存）。
    ///
    /// 注意：`send` 的 completion 里**强引用** `self`——否则 `FilePump` 会在
    /// `start()` 返回后立刻被释放，回调拿到 nil，响应体永远发不出去。
    /// NWConnection 在回调触发后会释放闭包，所以传输结束即释放，不会泄漏。
    private final class FilePump {
        private let connection: NWConnection
        private let handle: FileHandle
        private var remaining: UInt64
        private static let chunkSize = 256 * 1024

        init(connection: NWConnection, handle: FileHandle, remaining: UInt64) {
            self.connection = connection
            self.handle = handle
            self.remaining = remaining
        }

        func start() { step() }

        private func step() {
            guard remaining > 0 else {
                finish()
                return
            }
            let want = Int(min(UInt64(Self.chunkSize), remaining))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else {
                finish()
                return
            }
            remaining -= UInt64(chunk.count)
            connection.send(content: chunk, contentContext: .defaultMessage, isComplete: false,
                            completion: .contentProcessed { error in
                if error != nil {
                    self.finish()
                } else {
                    self.step()
                }
            })
        }

        private func finish() {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in
                self.connection.cancel()
            })
        }
    }
}

enum IPALocalHTTPServerError: Error, LocalizedError, CustomStringConvertible {
    case emptyFile
    case notReady

    var description: String {
        switch self {
        case .emptyFile: return "安装包为空"
        case .notReady: return "本机服务未就绪"
        }
    }

    var errorDescription: String? { description }
}
