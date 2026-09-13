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
/// 只服务一个 IPA 文件、带 Range 的服务器（仍沿用「127.0.0.1 + 随机端口」的做法）。
///
/// ## 生命周期
/// 只在「在线安装」期间启动，**不在打开清单后立刻关**：iOS 用户点了「安装」之后
/// 才会来拉包，关早了 IPA 就下载失败。调用方用 `stop(after:)` 定时收尾。
final class IPALocalHTTPServer {

    static let shared = IPALocalHTTPServer()

    private let queue = DispatchQueue(label: "com.ipaside.escapeos.ota.http")
    private var listener: NWListener?
    private var fileURL: URL?
    private var fileSize: UInt64 = 0
    private var stopWorkItem: DispatchWorkItem?

    /// 当前监听端口（0 = 未启动）
    private(set) var port: UInt16 = 0

    private init() {}

    // MARK: - 启停

    /// 启动服务器并返回实际监听的端口；`fileURL` 必须是存在的本地 IPA。
    @discardableResult
    func start(fileURL: URL) throws -> UInt16 {
        stop()

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0 else {
            throw IPALocalHTTPServerError.emptyFile
        }
        guard let chosen = Self.freeLoopbackPort(), let nwPort = NWEndpoint.Port(rawValue: chosen) else {
            throw IPALocalHTTPServerError.notReady
        }

        self.fileURL = fileURL
        self.fileSize = size

        // 只绑 127.0.0.1（不暴露到局域网）。端口先自己探一个空闲的再显式绑定，
        // 比依赖 `listener.port` 在 requiredLocalEndpoint 下的取值更稳。
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)

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

        guard becameReady else {
            listener.cancel()
            throw IPALocalHTTPServerError.notReady
        }

        self.listener = listener
        self.port = chosen
        return chosen
    }

    /// 立即关闭。
    func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        listener?.cancel()
        listener = nil
        port = 0
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

    /// 探一个当前空闲的回环端口
    private static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_zero = (0, 0, 0, 0, 0, 0, 0, 0)

        let bindRes = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { return nil }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameRes == 0 else { return nil }
        return UInt16(bigEndian: actual.sin_port)
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
