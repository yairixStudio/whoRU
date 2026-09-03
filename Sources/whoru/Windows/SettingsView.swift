import AppKit
import SwiftUI
import WhoRUCore
import WhoRUMac

/// Five tabs, few rows. Everything else is a fixed default.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            AITab(model: model).tabItem { Label("AI", systemImage: "sparkles") }
            PrivacyTab(model: model).tabItem { Label("Privacy", systemImage: "hand.raised") }
            HistoryTab(model: model).tabItem { Label("History", systemImage: "clock") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 640)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var showPermissions = false
    @State private var showPublishers = false

    var body: some View {
        Form {
            if let warning = model.integrityWarning {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(warning)
                        Spacer(minLength: 8)
                        Button("Dismiss") { model.integrityWarning = nil }.controlSize(.small)
                    }
                }
            }

            Section {
                Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
                Toggle("Show next to permission dialogs", isOn: $model.settings.showNextToDialogs)
                if model.settings.engine != .none {
                    Toggle("Ask the AI automatically", isOn: $model.settings.askModelAutomatically)
                }
            } footer: {
                if model.settings.engine != .none {
                    Text("With automatic asking off, the panel shows the evidence and the deterministic verdict, with an Ask AI button for the scans you want a second opinion on.")
                }
            }

            Section {
                Picker("Strictness", selection: $model.settings.strictness) {
                    Text("Standard").tag(Strictness.standard)
                    Text("Strict").tag(Strictness.strict)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(model.settings.strictness == .strict
                     ? "Green needs Apple’s notarization or a match with the publisher’s official release. Unknown download origin, or a sensitive permission from software Apple never checked, stays amber."
                     : "Known publishers with a valid signature are green even when notarization cannot be checked, which is normal for command-line tools.")
            }

            Section {
                DisclosureGroup("Permissions to watch", isExpanded: $showPermissions) {
                    ForEach(PermissionService.allCases.filter { $0 != .other && $0 != .fullDiskAccess }, id: \.self) { service in
                        Toggle(service.shortName, isOn: Binding(
                            get: { model.settings.isEnabled(service) },
                            set: { on in
                                var set = model.settings.enabledServices ?? Set(PermissionService.allCases)
                                if on { set.insert(service) } else { set.remove(service) }
                                model.settings.enabledServices = set.count == PermissionService.allCases.count ? nil : set
                            }
                        ))
                    }
                }
                DisclosureGroup("Trusted and blocked publishers", isExpanded: $showPublishers) {
                    PublisherList(model: model)
                }
            }

            Section {
                LabeledContent("Accessibility", value: model.accessibilityGranted ? "Granted" : "Not granted")
                if !model.accessibilityGranted {
                    Button("Open System Settings…") { AccessibilityPermission.openSystemSettings() }
                }
            } footer: {
                Text("Used only to read the text of permission dialogs. whoRU never clicks anything.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PublisherList: View {
    @Bindable var model: AppModel

    var body: some View {
        ForEach(model.publisherDirectory.all.filter { $0.teamID != Publisher.appleTeamID }) { publisher in
            LabeledContent {
                Picker("", selection: Binding(get: { publisher.trust }, set: { model.setTrust($0, for: publisher) })) {
                    Text("Normal").tag(PublisherTrust.normal)
                    Text("Trusted").tag(PublisherTrust.trusted)
                    Text("Blocked").tag(PublisherTrust.blocked)
                }
                .labelsHidden()
                .frame(width: 110)
            } label: {
                Text(publisher.name)
                Text(publisher.teamID).font(.system(.caption, design: .monospaced))
            }
        }
        Text("Trusted publishers are green without asking the AI. Blocked ones are always red.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - AI

/// What is known about an installed (or missing) agent, shared by Settings and onboarding.
struct AgentStatus: Identifiable {
    var engine: EngineChoice
    var path: String?
    var version: String?
    var verified: Bool
    /// Signed in to the tool's account (or given a key). `nil` when unknown or not applicable.
    var signedIn: Bool? = nil
    /// For agents that are not a file on disk (Apple Intelligence): why it cannot be used, if it cannot.
    var unavailableReason: String?
    var id: String { engine.rawValue }

    var isInstalled: Bool { path != nil }
    /// Can be chosen right now.
    var isUsable: Bool {
        switch engine {
        case .appleIntelligence: unavailableReason == nil
        case .claudeCode: isInstalled && verified && signedIn != false
        default: isInstalled && signedIn != false
        }
    }

    /// What is missing, in order: install, sign in, verify. `nil` when usable.
    enum Need { case install, signIn, unverified, enableApple }
    var need: Need? {
        if engine == .appleIntelligence { return unavailableReason == nil ? nil : .enableApple }
        if !isInstalled { return .install }
        if engine == .claudeCode, !verified { return .unverified }
        if signedIn == false { return .signIn }
        return nil
    }

    var summary: String {
        if engine == .appleIntelligence { return unavailableReason ?? "On-device · nothing leaves this Mac" }
        guard let path else { return "Not installed" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = path.replacingOccurrences(of: home, with: "~")
        var parts = [version ?? "found"]
        if engine == .claudeCode, !verified { parts.append("signature not verified") }
        if signedIn == false { parts.append("not signed in") }
        parts.append(short)
        return parts.joined(separator: " · ")
    }

    static func detectAll(settings: WhoRUCore.Settings) async -> [AgentStatus] {
        var result: [AgentStatus] = []
        if let path = settings.claudeCodePath ?? ClaudeCodeAnalyst.locate() {
            let verified = await ClaudeCodeVerifier.isTrusted(path)
            result.append(AgentStatus(engine: .claudeCode, path: path, version: await ClaudeCodeAnalyst.version(of: path), verified: verified,
                                      signedIn: verified ? await AgentAuth.isSignedIn(.claudeCode, executable: path) : nil))
        } else {
            result.append(AgentStatus(engine: .claudeCode, path: nil, version: nil, verified: false))
        }
        if let path = settings.codexPath ?? CodexAnalyst.locate() {
            result.append(AgentStatus(engine: .codex, path: path, version: await CodexAnalyst.version(of: path), verified: true, signedIn: await AgentAuth.isSignedIn(.codex, executable: path)))
        } else {
            result.append(AgentStatus(engine: .codex, path: nil, version: nil, verified: false))
        }
        if let path = settings.geminiPath ?? GeminiAnalyst.locate() {
            result.append(AgentStatus(engine: .gemini, path: path, version: await GeminiAnalyst.version(of: path), verified: true, signedIn: await AgentAuth.isSignedIn(.gemini, executable: path)))
        } else {
            result.append(AgentStatus(engine: .gemini, path: nil, version: nil, verified: false))
        }
        // Apple Intelligence is mentioned only on Macs that can run it at all.
        if AppleFoundationAnalyst.isSupported {
            result.append(AgentStatus(engine: .appleIntelligence, path: nil, version: nil, verified: true, unavailableReason: AppleFoundationAnalyst.unavailabilityReason()))
        }
        return result
    }
}

/// The one action that makes an agent usable: Install (Terminal with the
/// install script), Sign in (Terminal with the login flow), or System Settings
/// for Apple Intelligence.
struct AgentActionButton: View {
    let status: AgentStatus

    var body: some View {
        switch status.need {
        case .install:
            Button("Install") { try? AgentInstaller.install(status.engine) }.help(status.engine.installCommand ?? "")
        case .signIn:
            Button("Sign In") { try? AgentInstaller.signIn(status.engine) }.help(status.engine.loginCommand ?? "")
        case .enableApple:
            Button("Open System Settings") { NSWorkspace.shared.open(AppleFoundationAnalyst.settingsURL) }
        case .unverified, nil:
            EmptyView()
        }
    }
}

/// Agents only: the tools people already have. No keys, no accounts.
private struct AITab: View {
    @Bindable var model: AppModel
    @State private var agents: [AgentStatus] = []

    private var engine: EngineChoice { model.settings.engine }

    var body: some View {
        Form {
            Section {
                // Only what can actually be used right now is offered. In
                // local-only mode that is Apple's on-device model, or nothing.
                Picker("AI agent", selection: $model.settings.engine) {
                    ForEach(usableAgents, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                    Text("None").tag(EngineChoice.none)
                }
                if engine == .appleIntelligence {
                    LabeledContent("Model", value: "On-device model")
                } else if EngineChoice.commandLineAgents.contains(engine) {
                    ModelPicker(engine: engine, settings: $model.settings)
                }
                Text("Agents run as separate processes without whoRU's permissions; only whoru-inspect, limited to the program under review, is available to them.")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                if model.settings.localOnly {
                    Text(AppleFoundationAnalyst.isAvailable
                         ? "Local-only mode is on (Privacy), so only Apple’s on-device model is offered. Nothing leaves this Mac. Cloud agents come back when you turn local-only mode off."
                         : (AppleFoundationAnalyst.isSupported
                            ? "Local-only mode is on (Privacy), so only an on-device model could run, and Apple Intelligence is not available on this Mac right now. Evidence and the deterministic verdict still work."
                            : "Local-only mode is on (Privacy), so no cloud agent runs, and this Mac has no on-device model. Evidence and the deterministic verdict still work."))
                } else {
                    switch engine {
                    case .none: Text("Evidence and the deterministic verdict only. Nothing is sent anywhere unless you press Ask AI in the panel, which lets you pick an agent for that one scan. History shows no conversation while the agent is off.")
                    case .appleIntelligence: Text("Apple’s on-device model explains the evidence without anything leaving this Mac. Smaller than the cloud agents, so expect shorter answers.")
                    default: Text("The agent explains the evidence and answers questions; it cannot override it.")
                    }
                }
            }

            Section(model.settings.localOnly ? "On-device" : "Agents on this Mac") {
                ForEach(visibleAgents) { agent in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text(agent.summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            AgentActionButton(status: agent).controlSize(.small)
                        }
                    } label: {
                        Text(agent.engine.displayName)
                    }
                }
                if agents.isEmpty { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
        .task { await detect() }
        .onChange(of: model.settings.engine) { _, _ in Task { await model.refreshEngineDescription() } }
        // Coming back from Terminal after an install: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await detect() }
        }
    }

    /// In local-only mode only on-device agents are listed at all.
    private var visibleAgents: [AgentStatus] {
        model.settings.localOnly ? agents.filter(\.engine.isOnDevice) : agents
    }

    private var usableAgents: [EngineChoice] {
        let usable = visibleAgents.filter(\.isUsable).map(\.engine)
        // Keep the current choice visible even if it just became unavailable, so the picker stays consistent.
        if EngineChoice.agents.contains(engine), !usable.contains(engine), !(model.settings.localOnly && !engine.isOnDevice) { return usable + [engine] }
        return usable
    }

    private func detect() async {
        agents = await AgentStatus.detectAll(settings: model.settings)
        // "Automatic" is how the app starts; the picker shows a concrete agent.
        if model.settings.engine == .auto {
            model.settings.engine = visibleAgents.first(where: \.isUsable)?.engine ?? .none
        }
        // A cloud agent cannot stay selected once local-only mode is on.
        if model.settings.localOnly, !model.settings.engine.isOnDevice, model.settings.engine != .none {
            model.settings.engine = AppleFoundationAnalyst.isAvailable ? .appleIntelligence : .none
        }
        await model.refreshEngineDescription()
    }
}

private struct ModelPicker: View {
    let engine: EngineChoice
    @Binding var settings: WhoRUCore.Settings

    private var stored: String { settings.engineModels[engine.rawValue] ?? "" }
    private var isCustom: Bool { !stored.isEmpty && !engine.suggestedModels.contains(stored) }

    var body: some View {
        Picker("Model", selection: Binding(
            get: { isCustom ? "custom" : settings.model(for: engine) },
            set: { value in settings.engineModels[engine.rawValue] = value == "custom" ? "custom" : value }
        )) {
            ForEach(engine.suggestedModels, id: \.self) { name in
                Text(engine.modelDisplayName(name)).tag(name)
            }
            Text("Other…").tag("custom")
        }
        if isCustom {
            TextField("Model name", text: Binding(
                get: { stored == "custom" ? "" : stored },
                set: { settings.engineModels[engine.rawValue] = $0.isEmpty ? "custom" : $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @Bindable var model: AppModel
    @State private var vtKey = ""
    @State private var vtMessage = ""
    @State private var confirmReset = false
    @State private var diagnosticsMessage = ""

    var body: some View {
        Form {
            Section {
                Toggle("Local-only mode", isOn: $model.settings.localOnly)
                    .onChange(of: model.settings.localOnly) { _, on in
                        // Cloud agents are off the table; Apple's on-device model stays, if there is one.
                        if on, !model.settings.engine.isOnDevice, model.settings.engine != .none {
                            model.settings.engine = AppleFoundationAnalyst.isAvailable ? .appleIntelligence : .none
                        }
                        Task { await model.refreshEngineDescription() }
                    }
            } footer: {
                Text(model.settings.localOnly
                     ? (AppleFoundationAnalyst.isSupported ? "On: no network requests at all, no cloud agents, no official release manifests. Under AI, only Apple’s on-device model is offered." : "On: no network requests at all, no cloud agents, no official release manifests.")
                     : (AppleFoundationAnalyst.isSupported ? "Turns off every network request, including cloud AI and official release manifests. Evidence and the deterministic verdict still work; Apple’s on-device model remains available." : "Turns off every network request, including cloud AI and official release manifests. Evidence and the deterministic verdict still work."))
            }
            Section("VirusTotal") {
                Toggle("Look hashes up on VirusTotal", isOn: $model.settings.virusTotalEnabled)
                SecureField("API key", text: $vtKey, prompt: Text(model.secrets.secret(.virusTotalAPIKey) != nil ? "•••••••• (saved)" : "VirusTotal API key"))
                HStack {
                    Button("Save") { try? model.secrets.setSecret(vtKey, for: .virusTotalAPIKey); vtKey = ""; vtMessage = "Saved" }.disabled(vtKey.isEmpty)
                    Text(vtMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Only the file’s SHA-256 is sent. VirusTotal sees the hash and your IP address.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Always") {
                Label("File contents never leave this Mac.", systemImage: "lock.fill")
                Label("Your user name is removed from paths before anything is sent.", systemImage: "person.crop.circle.badge.xmark")
                Label("“What was sent?” in any panel shows the exact JSON the AI received.", systemImage: "doc.text.magnifyingglass")
            }
            .font(.callout)
            Section {
                LabeledContent("Full Disk Access") {
                    Button("Open System Settings…") { NSWorkspace.shared.open(AccessibilityPermission.fullDiskAccessSettingsURL) }
                }
                LabeledContent("Data") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.applicationSupport]) }
                }
                Button("Reset whoRU…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Delete all scans, settings and saved keys?", isPresented: $confirmReset) {
                        Button("Delete Everything", role: .destructive) { resetAll() }
                    } message: {
                        Text("The Accessibility permission is removed by you in System Settings → Privacy & Security → Accessibility.")
                    }
            } footer: {
                Text("Full Disk Access is optional. It lets whoRU read the decision you made from the system’s permission database and fill history in automatically.")
            }
            Section {
                LabeledContent("Log file") {
                    Button("Show in Finder") {
                        if let url = AppLog.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(AppModel.logDirectory) }
                    }
                }
                HStack {
                    Button("Copy Diagnostics Report") {
                        Task {
                            let report = await model.diagnosticsReport()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                            diagnosticsMessage = "Copied · paste it into a GitHub issue"
                        }
                    }
                    Text(diagnosticsMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The log records what whoRU saw and did: dialogs, checks with timings, engine calls and errors. No secrets, no file contents.")
            }
        }
        .formStyle(.grouped)
    }

    private func resetAll() {
        try? FileManager.default.removeItem(at: model.paths.applicationSupport)
        // Every user secret, but not the store-integrity key: it is an internal
        // signing key, not a credential, and the store still in memory signs the
        // fresh settings file with it. Deleting it here would leave that file
        // signed by a key the next launch no longer has, and read as tampered.
        for key in SecretKey.allCases where key != .storeIntegrityKey {
            try? model.secrets.setSecret(nil, for: key)
        }
        model.publisherOverrides = []
        model.integrityWarning = nil
        model.settings = WhoRUCore.Settings()
    }
}

// MARK: - History

private struct HistoryTab: View {
    @Bindable var model: AppModel
    @State private var records: [ScanRecord] = []

    static let retentionOptions: [(Int, String)] = [(1, "1 day"), (3, "3 days"), (7, "7 days"), (14, "14 days"), (30, "30 days"), (90, "90 days"), (365, "1 year"), (0, "Forever")]

    var body: some View {
        Form {
            Section {
                Picker("Keep history for", selection: $model.settings.historyRetentionDays) {
                    ForEach(Self.retentionOptions, id: \.0) { days, label in Text(label).tag(days) }
                }
                LabeledContent("Stored", value: "\(records.count) scans")
                LabeledContent("This month", value: String(format: "$%.2f in model calls", model.monthlySpend))
            } footer: {
                Text("Older scans are deleted when whoRU starts. Everything is on this Mac, in plain JSON files.")
            }
            Section("Recent decisions") {
                if records.isEmpty {
                    Text("No scans yet.").foregroundStyle(.secondary)
                }
                ForEach(records.prefix(12)) { record in
                    LabeledContent {
                        Text(decision(record)).foregroundStyle(.secondary)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: presentation(record).symbol).foregroundStyle(color(presentation(record).color))
                            Text(record.subject?.displayName ?? record.prompt.requesterName)
                        }
                        Text("\(record.prompt.service.shortName) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                HStack {
                    Button("Open History Window") { AppDelegate.shared?.showHistory() }
                    Spacer()
                    Button("Delete All…", role: .destructive) { Task { for r in records { try? await model.store.delete(id: r.id) }; await reload() } }
                        .disabled(records.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        records = (try? await model.store.all()) ?? []
    }

    private func decision(_ r: ScanRecord) -> String {
        switch r.userDecision {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .unknown: r.bestHeadline?.title ?? "—"
        }
    }

    private func presentation(_ r: ScanRecord) -> VerdictPresentation {
        if let v = r.verdict { return .forVerdict(v.verdict, locale: "en") }
        if let h = r.hardScore { return .forHardScore(h, locale: "en") }
        return .scanning
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "red": .red
        default: .secondary
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 2) {
                Text("whoRU").font(.title.weight(.semibold))
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            }
            Text("Know who is really asking before you click Allow.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Divider().frame(width: 200)
            VStack(spacing: 6) {
                Text("Made by Yairix Studio").font(.headline)
                Link("github.com/yairixStudio", destination: URL(string: "https://github.com/yairixStudio")!)
            }
            HStack(spacing: 16) {
                Link("Source code", destination: URL(string: "https://github.com/yairixStudio/whoRU")!)
                Link("Report an issue", destination: URL(string: "https://github.com/yairixStudio/whoRU/issues")!)
                Link("MIT License", destination: URL(string: "https://github.com/yairixStudio/whoRU/blob/main/LICENSE")!)
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
