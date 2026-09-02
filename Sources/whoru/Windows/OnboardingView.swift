import AppKit
import SwiftUI
import WhoRUCore
import WhoRUMac

/// First run: one window, a few steps, one sentence each. Nothing to read.
struct OnboardingView: View {
    @Bindable var model: AppModel
    let finish: () -> Void

    enum Step: Int, CaseIterable { case move, accessibility, ai, tryIt, done }

    @State private var step: Step = .move
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var claudeCodePath: String? = nil
    @State private var claudeCodeVersion: String? = nil
    @State private var claudeCodeTrusted = false
    @State private var engineChoice: EngineChoice = .none
    @State private var apiKey = ""
    @State private var keyStatus: KeyStatus = .unknown
    @State private var demoTriggered = false

    enum KeyStatus: Equatable { case unknown, checking, valid(Int), invalid(String) }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 44)
            footer
                .padding(20)
        }
        .frame(width: 460, height: 540)
        .background(.background)
        .task { await detectEngines() }
        .task { await pollAccessibility() }
        .onAppear {
            if !MoveToApplications.isNeeded { step = AccessibilityPermission.isGranted ? .ai : .accessibility }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .move:
            stepView(symbol: "folder.badge.gearshape", title: "Move to Applications", text: "whoRU asks for a permission that is tied to where the app lives. Moving it to the Applications folder first means you grant it once.")
        case .accessibility:
            VStack(spacing: 12) {
                stepView(symbol: accessibilityGranted ? "checkmark.circle.fill" : "hand.raised.fill",
                         title: "Allow Accessibility",
                         text: "To see when macOS asks, whoRU needs the Accessibility permission. It only reads the text of permission dialogs. It never clicks anything.",
                         tint: accessibilityGranted ? .green : .accentColor)
                if !accessibilityGranted {
                    VStack(spacing: 6) {
                        Text("Already switched on in System Settings, but still stuck here? That entry belongs to an earlier build of whoRU. Reset it and switch it on again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Reset the permission and ask again") {
                            Task {
                                await AccessibilityPermission.resetAndAskAgain()
                                AccessibilityPermission.openSystemSettings()
                            }
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: 360)
                    .padding(.bottom, 8)
                }
            }
        case .ai:
            aiStep
        case .tryIt:
            stepView(symbol: "sparkles.rectangle.stack", title: "Try it now", text: demoTriggered
                     ? "A permission dialog for whoRU itself should have appeared, with the companion next to it. That is exactly what happens for any other program."
                     : "Trigger a real, harmless permission dialog for whoRU itself and see the companion appear next to it.")
        case .done:
            stepView(symbol: "checkmark.seal.fill", title: "That’s it", text: "whoRU lives in the menu bar. It appears when a permission dialog does, and stays out of the way otherwise.", tint: .green)
        }
    }

    private func stepView(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey, tint: Color = .accentColor) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 80)
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Spacer()
        }
    }

    private var aiStep: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(height: 72)
            Text("Explain with AI?")
                .font(.largeTitle.weight(.semibold))
            Text("The evidence works without it. An AI model adds a plain-language explanation and answers questions. Pick what you have; you can change this later.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            VStack(spacing: 8) {
                if let path = claudeCodePath {
                    engineCard(.claudeCode, title: "Use Claude Code",
                               detail: claudeCodeTrusted ? "\(claudeCodeVersion ?? "found") · signature verified · no key needed" : "found at \(path) but the signature could not be verified",
                               enabled: claudeCodeTrusted)
                }
                engineCard(.claudeAPI, title: "Use an API key", detail: "Faster answers. Pasted below, stored in your Keychain.", enabled: true)
                if engineChoice == .claudeAPI {
                    HStack {
                        SecureField("sk-ant-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await checkKey() } }
                        Button("Check") { Task { await checkKey() } }
                            .disabled(apiKey.isEmpty || keyStatus == .checking)
                    }
                    keyStatusLine
                }
                engineCard(.none, title: "No AI for now", detail: "Hard evidence and a deterministic verdict only.", enabled: true)
            }
            .frame(maxWidth: 380)
            Spacer()
        }
    }

    private func engineCard(_ choice: EngineChoice, title: LocalizedStringKey, detail: String, enabled: Bool) -> some View {
        Button {
            if enabled { engineChoice = choice }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: engineChoice == choice ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(engineChoice == choice ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(10)
            .background(.quaternary.opacity(engineChoice == choice ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var keyStatusLine: some View {
        switch keyStatus {
        case .unknown: EmptyView()
        case .checking: Label("Checking…", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary)
        case .valid(let n): Label("Key works · \(n) models available", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .invalid(let why): Label(why, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases.filter { $0 != .move || MoveToApplications.isNeeded }, id: \.rawValue) { s in
                    Circle().fill(s == step ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            switch step {
            case .move:
                Button("Not now") { step = AccessibilityPermission.isGranted ? .ai : .accessibility }
                Button("Move to Applications") { MoveToApplications.moveAndRelaunch() }.buttonStyle(.borderedProminent)
            case .accessibility:
                if accessibilityGranted {
                    Button("Continue") { step = .ai }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") {
                        _ = AccessibilityPermission.requestWithSystemPrompt()
                        AccessibilityPermission.openSystemSettings()
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            case .ai:
                Button("Continue") { commitEngine(); step = .tryIt }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(engineChoice == .claudeAPI && !isKeyValid)
            case .tryIt:
                Button("Skip") { step = .done }
                Button(demoTriggered ? "Continue" : "Try it now") {
                    if demoTriggered { step = .done } else { demoTriggered = true; AppDelegate.shared?.triggerDemoPrompt() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .done:
                Button("Done") {
                    model.settings.onboardingCompleted = true
                    finish()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isKeyValid: Bool {
        if case .valid = keyStatus { return true }
        return false
    }

    // MARK: Actions

    private func detectEngines() async {
        if let path = ClaudeCodeAnalyst.locate() {
            claudeCodePath = path
            claudeCodeTrusted = await ClaudeCodeVerifier.isTrusted(path)
            claudeCodeVersion = await ClaudeCodeAnalyst.version(of: path)
            if claudeCodeTrusted { engineChoice = .claudeCode }
        } else if model.secrets.secret(.anthropicAPIKey) != nil {
            engineChoice = .claudeAPI
            keyStatus = .valid(0)
        }
    }

    private func pollAccessibility() async {
        while !Task.isCancelled {
            let granted = AccessibilityPermission.isGranted
            if granted != accessibilityGranted {
                withAnimation { accessibilityGranted = granted }
                if granted, step == .accessibility {
                    try? await Task.sleep(for: .seconds(0.8))
                    withAnimation { step = .ai }
                    AppDelegate.shared?.startWatcherIfPossible()
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func checkKey() async {
        keyStatus = .checking
        do {
            let models = try await ClaudeAPIAnalyst.listModels(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            keyStatus = .valid(models.count)
        } catch {
            keyStatus = .invalid(String(describing: error))
        }
    }

    private func commitEngine() {
        var settings = model.settings
        settings.engine = engineChoice
        if engineChoice == .claudeCode { settings.claudeCodePath = claudeCodePath }
        if engineChoice == .claudeAPI, !apiKey.isEmpty {
            try? model.secrets.setSecret(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .anthropicAPIKey)
        }
        model.settings = settings
        Task { await model.refreshEngineDescription() }
    }
}

/// Accessibility is tied to the app's path; move before asking.
enum MoveToApplications {
    static var isNeeded: Bool {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return false }
        return !url.path.hasPrefix("/Applications/") && !url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path)
    }

    @MainActor
    static func moveAndRelaunch() {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not move whoRU"
            alert.informativeText = "Drag whoRU to the Applications folder yourself, then open it again. (\(error.localizedDescription))"
            alert.runModal()
        }
    }
}
