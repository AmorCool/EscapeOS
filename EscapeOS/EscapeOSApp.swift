import SwiftUI

@main
struct EscapeSpaceApp: App {
    init() {
        // Consume the LiveContainer host-issued container sandbox extensions
        // (read/write) so guest containers — including shared/"converted" App
        // Group data — are reachable for scanning and reclaim on iOS 26.
        SandboxEscape.bootstrapLiveContainerExtensions()
        // MHA branch: auto-detect the host process's App Group for the iOS 26
        // sacrifice route. Inside LiveContainer the app runs as the LC process,
        // so LC's App Group is inherited and used here — no separately
        // registered App Group needed. Falls back to the placeholder if the
        // process has none (then GestaltEngine tries the InternalDaemon route).
        MCMIntegration.detectHostAppGroup()
        // Allow the user to override the detected App Group from Settings.
        if let override = UserDefaults.standard.string(forKey: "mha_app_group_override"),
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            MCMIntegration.configure(appGroup: override.trimmingCharacters(in: .whitespaces))
        }
        // Go runtime 内存节流（v0.3.81）：必须在**任何 Go 调用之前**设置——
        // Go 在 runtime 初始化时快照 environ，之后再 setenv 对 Go 不可见。
        // 目的：二进制模块服务启动阶段疑似内存超限被系统硬杀（stderr 无任何输出），
        // 这里压低 Go 堆上限与 P 数量，给 LC 宿主留出内存余量。
        setenv("GOGC", "60", 1)              // 默认 100 → 更早触发 GC
        setenv("GOMEMLIMIT", "256MiB", 1)    // 堆软上限，超限即强制 GC
        setenv("GOMAXPROCS", "4", 1)         // 6 核设备限制 P 数，减少线程与结构开销
        // SSH Debug 模式：开启后随 App 启动自动拉起 SSH 服务（见 SSH 调试页开关）
        SSHServerService.shared.autoStartIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
