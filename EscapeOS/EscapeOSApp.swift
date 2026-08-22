import SwiftUI

@main
struct EscapeSpaceApp: App {
    init() {
        // MHA branch: configure the iOS 26 App Group sacrifice route.
        // Replace the placeholder with the App Group registered to EscapeOS's
        // signing identity before relying on class-7 (App Group) access.
        MCMIntegration.configure(appGroup: "group.com.ipaside.escapeos.placeholder")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
