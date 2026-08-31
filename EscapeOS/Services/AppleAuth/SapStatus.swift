import Foundation
import Darwin

// ─── v0.3.3：SAP 流水线状态（JIT 模式 + 资产包进度）────────────────────────
//
// 数据源两路：
//   ① 本进程 mmap(MAP_JIT) 探测（登录前一次，展示用）；
//   ② Go 侧 SapGetProgress 轮询（SapInit 阻塞期间 400ms 一次，下载进度/阶段）。
// AppStoreDownloadView 顶部状态条观察 SapStatusModel；阶段/进度同时节流写入
// LoginLogger（完整日志进登录日志）。

/// JIT 可用性探测：尝试 mmap 一块 MAP_JIT 匿名内存。
/// - 调试器附加（StikDebug → CS_DEBUGGED）或宿主授予 JIT → 成功
/// - 普通侧载 / LiveContainer 访客 → 失败（EPERM）
/// v0.3.3 起 libunicorn 为 TCI 解释器模式，JIT 与否都不阻断签名——探测仅用于展示。
enum SAPJITProbe {
    // csops(2) 的操作码与标志位（xnu bsd/sys/csr.h）
    private static let CS_OPS_STATUS: UInt32 = 5
    private static let CS_DEBUGGED: UInt32 = 0x1000_0000

    /// v0.3.8：探测「调试器已附加并生效」（CS_DEBUGGED 内核标志）——这是
    /// StikDebug 路径的权威判据。mmap MAP_JIT 探测已在 iOS 27 beta 上证伪：
    /// mmap 成功但执行 JIT 缓冲仍被 CODESIGNING Invalid Page 杀（.ips 实锤）。
    /// - StikDebug 附加 LC 进程成功 → CS_DEBUGGED 置位 → true
    /// - 未附加/附加失败/重启后未重开 → false
    static func jitAvailable() -> Bool {
        guard let dbg = csDebuggedFlag() else { return false }
        return dbg
    }

    /// 返回 nil 表示 csops 调用失败（无法判定）。
    static func csDebuggedFlag() -> Bool? {
        var flags: UInt32 = 0
        let result = csops(getpid(), CS_OPS_STATUS, &flags, UInt32(MemoryLayout<UInt32>.size))
        guard result == 0 else { return nil }
        return (flags & CS_DEBUGGED) != 0
    }
}

/// 状态条数据模型。@Published 的变更统一经 DispatchQueue.main（轮询在后台线程）。
final class SapStatusModel: ObservableObject {
    static let shared = SapStatusModel()

    enum JITMode: Equatable {
        case unknown
        case available
        case unavailable

        var text: String {
            switch self {
            case .unknown: return "检测中"
            case .available: return "已启用"
            case .unavailable: return "未生效（StikDebug 未附加到 LC）"
            }
        }
    }

    @Published var jitMode: JITMode = .unknown
    @Published var phaseText: String = "未开始"
    @Published var progress: Double? = nil
    @Published var bytesText: String = ""

    func setJIT(_ mode: JITMode) {
        DispatchQueue.main.async { [weak self] in
            self?.jitMode = mode
        }
    }

    /// 主动探测 JIT 并更新状态（页面出现时 / 状态条点击重测时调用）。
    /// v0.3.3 只在登录流程内探测 → 页面打开后永远显示「检测中」（真机实锤），
    /// v0.3.6 改为进页面立即探测。
    func probeJITNow() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = SAPJITProbe.jitAvailable()
            self?.setJIT(ok ? .available : .unavailable)
            LoginLogger.shared.log(ok ? "SAP JIT 探测（页面）：已启用" : "SAP JIT 探测（页面）：未启用")
        }
    }

    func reset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phaseText = "未开始"
            self.progress = nil
            self.bytesText = ""
        }
    }

    /// 应用 Go 侧 "phase=N;done=N;total=N" 轮询结果。
    func apply(progressString raw: String) {
        var phase: Int = -1
        var done: UInt64 = 0
        var total: UInt64 = 0
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "phase": phase = Int(kv[1]) ?? -1
            case "done": done = UInt64(kv[1]) ?? 0
            case "total": total = UInt64(kv[1]) ?? 0
            default: break
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch phase {
            case 1:
                self.phaseText = "下载 Apple 资产包"
                guard total > 0 else { return }
                self.progress = min(1.0, Double(done) / Double(total))
                self.bytesText = String(format: "%.1f / %.1f MB", Double(done) / 1_048_576, Double(total) / 1_048_576)
            case 2:
                self.phaseText = "启动模拟器"
                self.progress = nil
                self.bytesText = ""
            case 3:
                self.phaseText = "SAP 握手"
                self.progress = nil
                self.bytesText = ""
            case 4:
                self.phaseText = "就绪"
                self.progress = nil
                self.bytesText = ""
            default:
                break
            }
        }
    }
}

/// 轮询 Go 侧进度（SapInit 阻塞期间每 400ms 一次），驱动状态条 + 节流登录日志。
final class SapProgressPoller {
    static let shared = SapProgressPoller()

    private var task: Task<Void, Never>?
    private var lastPhase = -1
    private var lastPercentStep = -1

    func start() {
        guard task == nil else { return }
        lastPhase = -1
        lastPercentStep = -1
        let model = SapStatusModel.shared
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let raw = Self.readProgress()
                model.apply(progressString: raw)
                self?.logThrottled(raw)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// 调 C 导出 SapGetProgress()；返回的 malloc 字符串必须 SapFree。
    private static func readProgress() -> String {
        guard let ptr = SapGetProgress() else { return "" }
        defer { SapFree(ptr) }
        return String(cString: ptr)
    }

    /// 阶段变化逐行记日志；下载中每 +10% 记一行（避免刷屏）。
    private func logThrottled(_ raw: String) {
        guard let phase = Self.parse(raw, key: "phase") else { return }
        let done = Self.parse(raw, key: "done") ?? 0
        let total = Self.parse(raw, key: "total") ?? 0

        if phase != lastPhase {
            lastPhase = phase
            lastPercentStep = -1
            let name: String
            switch phase {
            case 1: name = "下载 Apple 资产包（约 36MB，仅首次）"
            case 2: name = "启动 Unicorn 模拟器"
            case 3: name = "SAP setup 握手"
            case 4: name = "SAP 流水线就绪"
            default: name = "阶段 \(phase)"
            }
            LoginLogger.shared.log("SAP 阶段：\(name)")
            return
        }

        guard phase == 1, total > 0 else { return }
        let percent = min(100, Int(Double(done) / Double(total) * 100))
        let step = percent / 10
        if step > lastPercentStep {
            lastPercentStep = step
            LoginLogger.shared.log(
                String(format: "SAP 下载进度 %d%%（%.1f / %.1f MB）", percent, Double(done) / 1_048_576, Double(total) / 1_048_576)
            )
        }
    }

    private static func parse(_ raw: String, key: String) -> Int? {
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key {
                return Int(kv[1])
            }
        }
        return nil
    }
}
