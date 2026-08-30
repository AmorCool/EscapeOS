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
        // Liquid Glass 外观（标签栏 / 导航栏）。必须在任何 UI 创建之前调用：
        // UIAppearance 代理只对之后创建的实例生效，放在 View.onAppear 里太晚。
        LiquidGlassAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
