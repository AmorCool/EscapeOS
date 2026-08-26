import Foundation

/// 轻量日志引擎：内存环形缓冲（500 条）+ 持久化到 Documents/escapeos.log。
/// 对应原版 Erosion 的日志面板（mgr.logOutput + LogView）。追加日志后通过
/// `EscapeLog.didChange` 通知 LogView 刷新。
final class EscapeLog {
    static let shared = EscapeLog()

    /// 日志追加时发出的通知（LogView 监听后刷新）。
    static let didChange = Notification.Name("EscapeLogDidChange")

    private let lock = NSLock()
    private var lines: [String] = []
    private var fileURL: URL?

    private init() {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            fileURL = docs.appendingPathComponent("escapeos.log")
        }
    }

    /// 追加一行带时间戳的日志（线程安全），并持久化到日志文件。
    func append(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        let full = "[\(stamp)] \(line)"
        lock.lock()
        lines.append(full)
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
        lock.unlock()

        if let url = fileURL {
            let data = (full + "\n").data(using: .utf8) ?? Data()
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 当前日志全文（内存缓冲，最多 500 条）。
    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    /// 日志文件位置（用于导出分享）。可能为 nil（拿不到 Documents 时）。
    func exportURL() -> URL? {
        fileURL
    }

    /// 清空内存缓冲与日志文件。
    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
