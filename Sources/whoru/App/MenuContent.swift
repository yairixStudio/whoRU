import AppKit
import SwiftUI
import WhoRUCore

/// The status-item menu. Plain NSMenu look, nothing custom.
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        if let last = model.lastSession {
            Button {
                AppDelegate.shared?.showPanel(for: last)
            } label: {
                Label(lastTitle(last), systemImage: last.presentation.symbol)
            }
            Divider()
        }
        Button("History…") { AppDelegate.shared?.showHistory() }
            .keyboardShortcut("h", modifiers: [.command, .option])
        Button("Check a File…") { AppDelegate.shared?.showManualScan() }
        if model.isPaused {
            Button("Resume Watching") { model.pausedUntil = nil }
        } else {
            Button("Pause for an Hour") { model.pausedUntil = Date().addingTimeInterval(3600) }
        }
        Divider()
        Text(model.accessibilityGranted ? model.engineDescription : "Accessibility permission needed")
        if !model.accessibilityGranted {
            Button("Set Up whoRU…") { AppDelegate.shared?.showOnboarding() }
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit whoRU") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func lastTitle(_ session: ScanSession) -> String {
        let name = session.subject?.displayName ?? session.prompt.requesterName
        if let headline = session.displayedHeadline { return "\(name): \(headline.title)" }
        return "\(name): checking…"
    }
}
