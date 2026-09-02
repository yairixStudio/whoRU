import AppKit
import ApplicationServices
import Foundation
import WhoRUCore

/// The one permission whoRU needs. Granted in System Settings only; the
/// app never asks the system to show its own prompt, because that dialog
/// ("whoRU would like to control this Mac") cannot be closed by the user,
/// stays on screen after the permission is granted, and appears even when
/// the permission is already on.
public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    private static let grantedOnceKey = "accessibilityGrantedOnce"

    /// Whether this Mac has honored the permission for whoRU before. A grant
    /// is tied to the app's code signature: after a build signed differently,
    /// System Settings still shows whoRU as on, but the system ignores it.
    /// Seeing "granted before, not granted now" is how that is told apart
    /// from a fresh install.
    public static var wasGrantedBefore: Bool { UserDefaults.standard.bool(forKey: grantedOnceKey) }

    public static func noteGranted() {
        if !wasGrantedBefore { UserDefaults.standard.set(true, forKey: grantedOnceKey) }
    }

    public enum State {
        /// The system honors the permission.
        case granted
        /// Never granted on this Mac: add whoRU in System Settings.
        case missing
        /// Granted to an earlier build with another signature: the entry in
        /// System Settings looks on but does nothing; it has to be removed and
        /// added again.
        case stale
    }

    public static var state: State {
        if isGranted { return .granted }
        return wasGrantedBefore ? .stale : .missing
    }

    /// Removes whoRU's entry from the Accessibility list, so it can be added
    /// again for the current build. The app disappears from the list; the
    /// user adds it back with the + button.
    public static func reset() async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        _ = try? await Command.run("/usr/bin/tccutil", ["reset", "Accessibility", bundleID], timeout: .seconds(5))
        UserDefaults.standard.removeObject(forKey: grantedOnceKey)
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    @MainActor
    public static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
