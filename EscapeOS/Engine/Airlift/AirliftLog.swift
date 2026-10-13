import Foundation

/// Airlift 运行时日志收集器（移植自 AirBeep 的 `AirBeepLog`，功能逐字一致）.
///
/// Rust/FFI 层会从**任意线程**回调 C 日志函数，故写入用锁保护，UI 侧按需取走.
///
/// 命名说明：AirBeep 原类名 `AirBeepLog`；本仓统一放在 `Airlift/` 目录下，
/// 故按目录前缀改名 `AirliftLog`，**语义与实现与上游一致**（见文件头「移植」约定）.
final class AirliftLog: @unchecked Sendable {
    static let shared = AirliftLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 1000

    private init() {}

    /// 从任意线程追加一行.
    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    /// 返回已收集的全部行并清空缓冲.
    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = lines
        lines.removeAll()
        return out
    }

    /// 返回已收集的全部行（不清空）.
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// 带时间戳的日志文本，供导出 / 分享.
    func exportText() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = snapshot().joined(separator: "\n")
        return "AirLift log — \(stamp)\n----------------------------\n\(body)"
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }
}

/// 无捕获的 C 回调，才能作为函数指针交给 Airlift FFI.
/// Rust 会传一个以 NUL 结尾的消息字符串.
private let alLogBridge: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { _, msg in
    guard let msg else { return }
    AirliftLog.shared.append(String(cString: msg))
}

extension AirliftLog {
    /// 交给 `al_exploit_read_file` / `al_exploit_write_dir` 的 C 回调.
    /// `@convention(c)` 函数类型是 Sendable，故可从 `AirliftToneTransport` 的
    /// nonisolated static 辅助方法传入.
    static var ffiCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void {
        alLogBridge
    }
}
