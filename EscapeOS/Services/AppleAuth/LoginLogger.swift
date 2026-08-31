import Foundation

/// 登录诊断日志：把 Apple 认证引擎每一步的关键事件（请求/响应/错误）记录到
/// `Documents/LoginLogs/login.log`，支持在登录界面查看、复制与导出分享，便于排查
/// Anisette / GrandSlam 握手失败的真实原因。
final class LoginLogger {
    static let shared = LoginLogger()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxBufferLines = 500

    /// 日志文件位置（App 沙盒 Documents 内，LiveContainer 中同样可写、可被文件浏览器访问）。
    var logFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/LoginLogs")
            .appendingPathComponent("login.log")
    }

    private init() {
        // 启动时保证目录存在
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > maxBufferLines { buffer.removeFirst(buffer.count - maxBufferLines) }
        lock.unlock()
        appendToFile(line)
        // iOS 26 SDK 把 NSLog 的 variadic 形式标 unavailable，用 print 代替；
        // print 仍然进 Apple 系统日志（Console.app 可见），仅 path 不同（用户日常习惯差异）。
        print("[Login] \(message)")
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    /// 全部日志文本（内存缓冲 + 文件内容合并，去重）。
    func fullLog() -> String {
        lock.lock()
        let mem = buffer
        lock.unlock()

        var fileLines: [String] = []
        if let data = try? Data(contentsOf: logFileURL),
           let text = String(data: data, encoding: .utf8) {
            fileLines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        let merged = mem + fileLines.filter { !mem.contains($0) }
        return merged.joined(separator: "\n")
    }

    private func appendToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
