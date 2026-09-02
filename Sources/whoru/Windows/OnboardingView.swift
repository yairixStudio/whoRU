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
    @State private var agents: [AgentStatus] = []
    @State private var detecting = true
    @State private var engineChoice: EngineChoice = .none
    @State private var demoTriggered = false

    private var steps: [Step] { Step.allCases.filter { $0 != .move || MoveToApplications.isNeeded } }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 44)
            footer
                .padding(20)
        }
        .frame(width: 460, height: 560)
        .background(.background)
        .task { await detectAgents() }
        .task { await pollAccessibility() }
        .onAppear {
            if !MoveToApplications.isNeeded { step = AccessibilityPermission.isGranted ? .ai : .accessibility }
            engineChoice = model.settings.engine == .auto ? .none : model.settings.engine
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
            Text("Explain with an AI agent?")
                .font(.largeTitle.weight(.semibold))
            Text("The evidence works without it. An agent you already have adds a plain-language explanation and answers questions. Nothing to sign up for; you can change this later.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            VStack(spacing: 8) {
                if detecting {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(agents) { agent in
                        let usable = agent.isInstalled && (agent.engine != .claudeCode || agent.verified)
                        engineCard(agent.engine, title: usable ? "Use \(agent.engine.displayName)" : agent.engine.displayName,
                                   detail: usable ? agent.summary : (agent.isInstalled ? "Found but its signature could not be verified" : "Not installed"),
                                   enabled: usable, installLink: agent.isInstalled ? nil : agent.engine)
                    }
                    engineCard(.none, title: "No AI for now", detail: "Hard evidence and a deterministic verdict only. Nothing is sent anywhere.", enabled: true, installLink: nil)
                }
            }
            .frame(maxWidth: 380)
            Spacer()
        }
    }

    private func engineCard(_ choice: EngineChoice, title: String, detail: String, enabled: Bool, installLink: EngineChoice?) -> some View {
        Button {
            if enabled { engineChoice = choice }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: engineChoice == choice ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(engineChoice == choice ? Color.accentColor : Color.secondary)
                    .opacity(enabled ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).opacity(enabled ? 1 : 0.6)
                    HStack(spacing: 8) {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let installLink { InstallLink(engine: installLink).font(.caption) }
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(.quaternary.opacity(engineChoice == choice ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(steps, id: \.rawValue) { s in
                    Circle().fill(s == step ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if let previous = previousStep {
                Button("Back") { withAnimation { step = previous } }
            }
            switch step {
            case .move:
                Button("Not now") { goForward() }
                Button("Move to Applications") { MoveToApplications.moveAndRelaunch() }.buttonStyle(.borderedProminent)
            case .accessibility:
                if accessibilityGranted {
                    Button("Continue") { goForward() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") {
                        _ = AccessibilityPermission.requestWithSystemPrompt()
                        AccessibilityPermission.openSystemSettings()
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            case .ai:
                Button("Continue") { commitEngine(); goForward() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(detecting)
            case .tryIt:
                Button("Skip") { goForward() }
                Button(demoTriggered ? "Continue" : "Try it now") {
                    if demoTriggered { goForward() } else { demoTriggered = true; AppDelegate.shared?.triggerDemoPrompt() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .done:
                Button("Done") {
                    model.settings.onboardingCompleted = true
                    finish()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var previousStep: Step? {
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        let previous = steps[index - 1]
        // Never go back to the Accessibility step once it is granted; there is nothing to do there.
        if previous == .accessibility, accessibilityGranted, index > 1 { return steps[index - 2] }
        return previous
    }

    private func goForward() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        withAnimation { step = steps[index + 1] }
    }

    // MARK: Actions

    private func detectAgents() async {
        agents = await AgentStatus.detectAll(settings: model.settings)
        detecting = false
        let usable = agents.filter { $0.isInstalled && ($0.engine != .claudeCode || $0.verified) }
        if engineChoice == .none || !usable.contains(where: { $0.engine == engineChoice }) {
            engineChoice = usable.first?.engine ?? .none
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

    private func commitEngine() {
        var settings = model.settings
        settings.engine = engineChoice
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
