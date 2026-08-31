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
    static func jitAvailable() -> Bool {
        #if arch(arm64) || arch(arm64e)
        let MAP_JIT: Int32 = 0x0800
        let pageSize = 0x4000
        let ptr = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_JIT | MAP_ANON | MAP_PRIVATE, -1, 0)
        guard ptr != MAP_FAILED else { return false }
        munmap(ptr, pageSize)
        return true
        #else
        return true
        #endif
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
            case .unavailable: return "未启用（解释器模式运行）"
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
