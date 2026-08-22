import SwiftUI

@main
struct EscapeSpaceApp: App {
    init() {
        // MHA branch: auto-detect the host process's App Group for the iOS 26
        // sacrifice route. Inside LiveContainer the app runs as the LC process,
        // so LC's App Group is inherited and used here — no separately
        // registered App Group needed. Falls back to the placeholder if the
        // process has none (then GestaltEngine tries the InternalDaemon route).
        MCMIntegration.detectHostAppGroup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
