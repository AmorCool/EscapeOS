import Foundation
import Darwin

/// 一个极简的本地 HTTP 服务器，用于把生成的 .mobileconfig 描述文件
/// 通过 Safari 下载的方式交给系统安装。
///
/// 使用方式：
///   let port = try ProfileHTTPServer.shared.start(payload: data, filename: "blocked.mobileconfig")
///   UIApplication.shared.open(URL(string: "http://127.0.0.1:\(port)/")!)
///
/// 服务器会返回一个自动跳转页面，随后把文件以
/// `application/x-apple-aspen-config` MIME 类型输出，触发 iOS 的描述文件安装流程。
final class ProfileHTTPServer: NSObject {
    static let shared = ProfileHTTPServer()

    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var thread: Thread?
    private var payload: Data?
    private var payloadFilename = "profile.mobileconfig"

    private var _port: UInt16?
    var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return _port
    }

    /// 启动本地服务器并返回实际监听的端口。失败时抛出错误。
    @discardableResult
    func start(payload: Data, filename: String = "profile.mobileconfig") throws -> UInt16 {
        stop()

        self.payload = payload
        self.payloadFilename = filename

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ProfileServerError.socket(errno: Int(errno))
        }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_zero = (0, 0, 0, 0, 0, 0, 0, 0)

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            close(fd)
            throw ProfileServerError.bind(errno: Int(errno))
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw ProfileServerError.listen(errno: Int(errno))
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameRes == 0 else {
            close(fd)
            throw ProfileServerError.getsockname(errno: Int(errno))
        }

        let port = UInt16(bigEndian: actual.sin_port)

        lock.lock()
        listenFd = fd
        _port = port
        lock.unlock()

        thread = Thread(target: self, selector: #selector(run), object: nil)
        thread?.start()

        return port
    }

    /// 关闭监听 socket，让后台线程退出。
    func stop() {
        lock.lock()
        let fd = listenFd
        listenFd = -1
        _port = nil
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        // 关闭监听 socket 后 accept() 会返回错误，线程自然退出。
    }

    @objc private func run() {
        while true {
            lock.lock(); let fd = listenFd; lock.unlock()
            guard fd >= 0 else { break }

            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }

            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        // 读取 HTTP 请求头（直到 \r\n\r\n）。
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 1024)
        while buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) == nil {
            let n = recv(client, &temp, temp.count, 0)
            guard n > 0 else { break }
            buffer.append(temp[0..<n])
        }

        // 解析请求行，例如 "GET /blocked.mobileconfig HTTP/1.1"。
        guard let lineEnd = buffer.firstIndex(of: 0x0D),
              let line = String(data: buffer[..<lineEnd], encoding: .utf8),
              let path = line.split(separator: " ").dropFirst().first.map(String.init) else {
            return
        }

        if path == "/" || path == "/index.html" {
            let html = """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="refresh" content="1;url=/\(payloadFilename)">
            <title>下载描述文件</title>
            <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: #f2f2f7;
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              color: #1c1c1e;
            }
            .card {
              background: #fff;
              border-radius: 32px;
              padding: 48px 32px;
              text-align: center;
              width: 280px;
              box-shadow: 0 8px 24px rgba(0,0,0,0.08);
            }
            .spinner {
              width: 48px; height: 48px;
              border: 4px solid #e5e5ea;
              border-top-color: #007aff;
              border-radius: 50%;
              margin: 0 auto 20px;
              animation: spin 1s linear infinite;
            }
            @keyframes spin { to { transform: rotate(360deg); } }
            h1 { font-size: 20px; margin-bottom: 8px; }
            p { font-size: 14px; color: #8e8e93; }
            </style>
            </head>
            <body>
              <div class="card">
                <div class="spinner"></div>
                <h1>正在下载描述文件…</h1>
                <p>完成后将自动跳转至“设置”安装。</p>
              </div>
            </body>
            </html>
            """
            let body = html.data(using: .utf8) ?? Data()
            respond(client, status: "200 OK", contentType: "text/html; charset=utf-8", body: body)
        } else if path == "/\(payloadFilename)", let payload = payload {
            respond(client, status: "200 OK", contentType: "application/x-apple-aspen-config", body: payload)
        } else {
            let body = Data()
            respond(client, status: "404 Not Found", contentType: "text/plain", body: body)
        }
    }

    private func respond(_ client: Int32, status: String, contentType: String, body: Data) {
        let headers = """
        HTTP/1.1 \(status)\r\n\
        Content-Type: \(contentType)\r\n\
        Content-Length: \(body.count)\r\n\
        Connection: close\r\n\r\n
        """
        _ = sendAll(client, Data(headers.utf8))
        _ = sendAll(client, body)
    }

    @discardableResult
    private func sendAll(_ fd: Int32, _ data: Data) -> Int {
        var total = 0
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while total < data.count {
                let remaining = data.count - total
                let n = send(fd, base.advanced(by: total), remaining, 0)
                if n <= 0 { break }
                total += n
                sent += n
            }
        }
        return total
    }
}

enum ProfileServerError: Error, LocalizedError, CustomStringConvertible {
    case socket(errno: Int)
    case bind(errno: Int)
    case listen(errno: Int)
    case getsockname(errno: Int)

    var description: String {
        switch self {
        case .socket(let e): return "创建 socket 失败 (errno \(e))"
        case .bind(let e): return "绑定端口失败 (errno \(e))"
        case .listen(let e): return "监听端口失败 (errno \(e))"
        case .getsockname(let e): return "获取端口失败 (errno \(e))"
        }
    }

    var errorDescription: String? { description }
}
