import AppKit
import Foundation
import WhoRUCore

/// Installs an agent the way a person would: by opening Terminal with the
/// install script, so every step is visible. No automation permission needed;
/// Terminal runs `.command` files it is asked to open.
public enum AgentInstaller {
    public static func install(_ engine: EngineChoice) throws {
        guard let script = engine.installScript else { throw CommandError("no installer for \(engine.displayName)") }
        let directory = DefaultPaths().applicationSupport.appendingPathComponent("installers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("install-\(engine.rawValue).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        AppLog.shared.info("app", "opening Terminal to install \(engine.displayName)")
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error { AppLog.shared.error("app", "could not open Terminal: \(error)") }
        }
    }
}
