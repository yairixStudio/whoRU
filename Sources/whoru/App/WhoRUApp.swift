import SwiftUI
import WhoRUCore

@main
struct WhoRUApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.isPaused ? "person.questionmark" : "person.fill.questionmark")
                .accessibilityLabel("whoRU")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}
