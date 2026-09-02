import SwiftUI
import WhoRUCore

@main
struct WhoRUApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menu-bar item is an NSStatusItem owned by the delegate; the only
    // SwiftUI scene is Settings, so ⌘, and the openSettings action work.
    var body: some Scene {
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}
