import Foundation

/// 蓝牙位置模拟的**独立日志存储**。
///
/// ## 为什么不复用 `LoginLogger`
///
/// 蓝牙链路是**两台设备之间**的事（广播 / 扫描 / 配对 / 坐标下发），
/// 排查时的读法跟 Apple 登录、AppStore 下载完全不同：看的是「有没有扫到对端」
/// 「连上后有没有收到负载」「对端什么时候消失的」。
/// 混进 `LoginLogger` 的任何板块都会两边都读不干净（用户实测指正过这件事）。
/// 所以这里单开一份存储：**只写蓝牙链路自己的事件**，与其它板块互不干扰。
///
/// ## 存储位置
///
/// `Documents/BLELogs/ble.log` —— 与 `Documents/LoginLogs/login.log` 并列。
/// 放在 Documents 下是为了在 LiveContainer / 文件浏览器里能直接捞出来看。
///
/// ## 内存与磁盘的关系
///
/// `BLECoordinator.log` 那个 `@Published` 数组**只留最近 60 行**，供面板里的小窗预览；
/// 本存储**不设上限**（按 2MB 滚动截断，见 `maxFileBytes`），
/// 独立日志页读的就是这里。两者是「预览」与「全量」的关系，不是同一份数据。
final class BluetoothLogStore: @unchecked Sendable {
    static let shared = BluetoothLogStore()

    /// 单文件上限：超过就把前半截丢掉（保留最新的一半）。
    ///
    /// 为什么要有上限：蓝牙在链路不稳时会大量重试，日志增长很快；
    /// 无上限最终会把 App 的 Documents 撑爆。2MB ≈ 两万行左右，
    /// 足够覆盖任意一次现场排查，又不至于影响设备存储。
    private static let maxFileBytes = 2 * 1024 * 1024

    private let lock = NSLock()

    /// 日志文件位置（App 沙盒 Documents 内）。
    var logFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/BLELogs")
            .appendingPathComponent("ble.log")
    }

    /// 独立日志页要渲染的行数上限 —— 与 `LogConsoleView.maxRenderedLines` 对齐。
    private static let maxReadLines = 2000

    private init() {
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// 追加一行。**写盘失败不抛错**（日志本身就是排查工具，不能反过来把主流程搞挂）。
    func append(_ line: String) {
        let stamped = "[\(Self.timestamp())] \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 文件还不存在（首次运行）→ 直接建。
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    /// 读最近若干行（**新的在后面**，与 `LogConsoleView` 的输入约定一致）。
    func recentLines(_ limit: Int = maxReadLines) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8) else { return [] }
        let all = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return all.count > limit ? Array(all.suffix(limit)) : all
    }

    /// 清空（连文件一起删，与其它日志页的「清除」语义一致）。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logFileURL)
    }

    /// 超过 `maxFileBytes` 时丢掉前半截，保留后半截。
    ///
    /// 按**字节**截断会把某一行的 UTF-8 序列切一半，所以这里按行重组：
    /// 从尾部往前凑够「目标字节数的 90%」即可（少留一点，避免下次写入立刻又超限）。
    private func rotateIfNeeded() {
        // 注意 `attributesOfItem` 抛错时整个表达式走 `?? 0`，
        // 所以这里拿到的是**非可选** Int —— 不能再写 `guard let size`（CI 实证报错）。
        let size = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? Int) ?? 0
        guard size > Self.maxFileBytes else { return }
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var kept: [String] = []
        var budget = Self.maxFileBytes * 9 / 10
        for line in lines.reversed() {
            let cost = line.utf8.count + 1
            if cost > budget, !kept.isEmpty { break }
            budget -= cost
            kept.append(line)
        }
        let rebuilt = kept.reversed().joined(separator: "\n") + "\n"
        try? rebuilt.write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
