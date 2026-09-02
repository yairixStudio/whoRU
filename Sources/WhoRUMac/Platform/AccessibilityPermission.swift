import ApplicationServices
import AppKit
import Foundation
import WhoRUCore

/// The one permission whoRU needs: reading the text of other apps' windows.
public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its own prompt (which points at System Settings).
    public static func requestWithSystemPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// A grant made to an earlier build with a different signature shows as
    /// enabled in System Settings but is not honored. Removing the entry and
    /// asking again is the only way out; this does both.
    public static func resetAndAskAgain() async {
        if let bundleID = Bundle.main.bundleIdentifier {
            _ = try? await Command.run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID], timeout: .seconds(5))
        }
        _ = requestWithSystemPrompt()
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    @MainActor
    public static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
