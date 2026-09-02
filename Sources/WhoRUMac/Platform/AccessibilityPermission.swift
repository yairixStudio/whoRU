import ApplicationServices
import AppKit
import Foundation

/// The one permission whoRU needs: reading the text of other apps' windows.
public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its own prompt (which points at System Settings).
    public static func requestWithSystemPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    @MainActor
    public static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
