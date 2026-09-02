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
            Section {
                Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
                Toggle("Show next to permission dialogs", isOn: $model.settings.showNextToDialogs)
                if model.settings.engine != .none, !model.settings.localOnly {
                    Toggle("Ask the AI automatically", isOn: $model.settings.askModelAutomatically)
                }
            } footer: {
                if model.settings.engine != .none, !model.settings.localOnly {
                    Text("With automatic asking off, the panel shows the evidence and the deterministic verdict; the AI runs when you ask a question.")
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
    /// For agents that are not a file on disk (Apple Intelligence): why it cannot be used, if it cannot.
    var unavailableReason: String?
    var id: String { engine.rawValue }

    var isInstalled: Bool { path != nil }
    /// Can be chosen right now.
    var isUsable: Bool {
        switch engine {
        case .appleIntelligence: unavailableReason == nil
        case .claudeCode: isInstalled && verified
        default: isInstalled
        }
    }

    var summary: String {
        if engine == .appleIntelligence { return unavailableReason ?? "On-device · nothing leaves this Mac" }
        guard let path else { return "Not installed" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = path.replacingOccurrences(of: home, with: "~")
        var parts = [version ?? "found"]
        if engine == .claudeCode { parts.append(verified ? "verified" : "not verified") }
        parts.append(short)
        return parts.joined(separator: " · ")
    }

    static func detectAll(settings: WhoRUCore.Settings) async -> [AgentStatus] {
        var result: [AgentStatus] = []
        if let path = settings.claudeCodePath ?? ClaudeCodeAnalyst.locate() {
            result.append(AgentStatus(engine: .claudeCode, path: path, version: await ClaudeCodeAnalyst.version(of: path), verified: await ClaudeCodeVerifier.isTrusted(path)))
        } else {
            result.append(AgentStatus(engine: .claudeCode, path: nil, version: nil, verified: false))
        }
        if let path = settings.codexPath ?? CodexAnalyst.locate() {
            result.append(AgentStatus(engine: .codex, path: path, version: await CodexAnalyst.version(of: path), verified: true))
        } else {
            result.append(AgentStatus(engine: .codex, path: nil, version: nil, verified: false))
        }
        if let path = settings.geminiPath ?? GeminiAnalyst.locate() {
            result.append(AgentStatus(engine: .gemini, path: path, version: await GeminiAnalyst.version(of: path), verified: true))
        } else {
            result.append(AgentStatus(engine: .gemini, path: nil, version: nil, verified: false))
        }
        result.append(AgentStatus(engine: .appleIntelligence, path: nil, version: nil, verified: true, unavailableReason: AppleFoundationAnalyst.unavailabilityReason()))
        return result
    }
}

/// One button: opens Terminal with the tool's install script (the script says
/// where to look if it fails), or System Settings for Apple Intelligence.
struct InstallLink: View {
    let engine: EngineChoice

    var body: some View {
        if engine == .appleIntelligence {
            Button("Open System Settings") { NSWorkspace.shared.open(AppleFoundationAnalyst.settingsURL) }
                .controlSize(.small)
        } else {
            Button("Install") { try? AgentInstaller.install(engine) }
                .controlSize(.small)
                .help(engine.installCommand ?? "")
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
            if model.settings.localOnly {
                Section {
                    LabeledContent("AI agent", value: "Off")
                } footer: {
                    Text("Local-only mode is on (Privacy). Nothing leaves this Mac, so no agent runs. Evidence and the deterministic verdict still work.")
                }
            } else {
                Section {
                    // Only what can actually be used right now is offered.
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
                } footer: {
                    switch engine {
                    case .none: Text("Evidence and the deterministic verdict only. Nothing is sent anywhere.")
                    case .appleIntelligence: Text("Apple's on-device model explains the evidence without anything leaving this Mac. Smaller than the cloud agents, so expect shorter answers.")
                    default: Text("The agent explains the evidence and answers questions; it cannot override it.")
                    }
                }

                Section("Agents on this Mac") {
                    ForEach(agents) { agent in
                        LabeledContent(agent.engine.displayName) {
                            HStack(spacing: 10) {
                                Text(agent.summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if !agent.isUsable { InstallLink(engine: agent.engine) }
                            }
                        }
                    }
                    if agents.isEmpty { ProgressView().controlSize(.small) }
                }
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

    private var usableAgents: [EngineChoice] {
        let usable = agents.filter(\.isUsable).map(\.engine)
        // Keep the current choice visible even if it just became unavailable, so the picker stays consistent.
        if EngineChoice.agents.contains(engine), !usable.contains(engine) { return usable + [engine] }
        return usable
    }

    private func detect() async {
        agents = await AgentStatus.detectAll(settings: model.settings)
        // "Automatic" is how the app starts; the picker shows a concrete agent.
        if model.settings.engine == .auto {
            model.settings.engine = agents.first(where: \.isUsable)?.engine ?? .none
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
            } footer: {
                Text("Turns off every network request, including cloud AI and official release manifests. Evidence and the deterministic verdict still work.")
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
        for key in SecretKey.allCases { try? model.secrets.setSecret(nil, for: key) }
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
