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
                Toggle("Ask the AI automatically", isOn: $model.settings.askModelAutomatically)
            } footer: {
                Text("With automatic asking off, the panel shows the evidence and the deterministic verdict; the AI runs when you ask a question.")
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

private struct AITab: View {
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var keyMessage = ""
    @State private var detected: [EngineChoice: String] = [:]

    private var engine: EngineChoice { model.settings.engine }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $model.settings.engine) {
                    ForEach([EngineChoice.auto, .claudeCode, .claudeAPI, .codex, .gemini, .local, .none], id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                LabeledContent("Active", value: model.engineDescription)
            } footer: {
                Text("Automatic picks the first one available: Claude Code, an API key, Codex, Gemini.")
            }

            Section("Installed") {
                LabeledContent("Claude Code", value: detected[.claudeCode] ?? "…")
                LabeledContent("Codex CLI", value: detected[.codex] ?? "…")
                LabeledContent("Gemini CLI", value: detected[.gemini] ?? "…")
                LabeledContent("Claude API key", value: model.secrets.secret(.anthropicAPIKey) != nil ? "Saved in Keychain" : "None")
            }

            if [.claudeCode, .codex, .gemini].contains(engine) {
                Section {
                    ModelPicker(engine: engine, settings: $model.settings)
                } header: {
                    Text("Model")
                } footer: {
                    Text("“Default” uses whatever the command-line tool is configured with.")
                }
            }

            if engine == .claudeAPI || engine == .auto {
                Section("Claude API") {
                    SecureField("API key", text: $apiKey, prompt: Text(model.secrets.secret(.anthropicAPIKey) != nil ? "•••••••• (saved)" : "sk-ant-…"))
                    HStack {
                        Button("Save and Check") { Task { await saveKey() } }.disabled(apiKey.isEmpty)
                        Button("Remove") { try? model.secrets.setSecret(nil, for: .anthropicAPIKey); keyMessage = "Removed"; refresh() }
                        Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Analysis depth", selection: $model.settings.depth) {
                        ForEach(AnalysisDepth.allCases, id: \.self) { depth in
                            Text("\(depth.rawValue.capitalized) · \(depth.modelID)").tag(depth)
                        }
                    }
                    Stepper(value: $model.settings.monthlyBudgetUSD, in: 1...100, step: 1) {
                        LabeledContent("Monthly budget", value: String(format: "$%.0f · spent $%.2f", model.settings.monthlyBudgetUSD, model.monthlySpend))
                    }
                    Toggle("Allow the AI to search the web", isOn: $model.settings.allowWebSearch)
                }
            }

            if engine == .local {
                Section("Local model") {
                    TextField("Server", text: $model.settings.localModelURL)
                    TextField("Model", text: $model.settings.localModelName)
                }
            }
        }
        .formStyle(.grouped)
        .task { await detect() }
    }

    private func detect() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func short(_ path: String) -> String { path.replacingOccurrences(of: home, with: "~") }
        if let path = model.settings.claudeCodePath ?? ClaudeCodeAnalyst.locate() {
            let trusted = await ClaudeCodeVerifier.isTrusted(path)
            let version = await ClaudeCodeAnalyst.version(of: path) ?? "?"
            detected[.claudeCode] = "\(version) · \(trusted ? "verified" : "not verified") · \(short(path))"
        } else {
            detected[.claudeCode] = "Not installed"
        }
        if let path = model.settings.codexPath ?? CodexAnalyst.locate() {
            detected[.codex] = "\(await CodexAnalyst.version(of: path) ?? "found") · \(short(path))"
        } else {
            detected[.codex] = "Not installed"
        }
        if let path = model.settings.geminiPath ?? GeminiAnalyst.locate() {
            detected[.gemini] = "\(await GeminiAnalyst.version(of: path) ?? "found") · \(short(path))"
        } else {
            detected[.gemini] = "Not installed"
        }
    }

    private func saveKey() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let models = try await ClaudeAPIAnalyst.listModels(apiKey: key)
            try model.secrets.setSecret(key, for: .anthropicAPIKey)
            keyMessage = "Works · \(models.count) models"
            apiKey = ""
            refresh()
        } catch {
            keyMessage = "Not accepted: \(error)"
        }
    }

    private func refresh() {
        model.settings = model.settings
        Task { await model.refreshEngineDescription() }
    }
}

private struct ModelPicker: View {
    let engine: EngineChoice
    @Binding var settings: WhoRUCore.Settings
    @State private var custom = ""

    private var current: String { settings.model(for: engine) }
    private var isSuggested: Bool { engine.suggestedModels.contains(current) }

    var body: some View {
        Picker("Model", selection: Binding(
            get: { isSuggested ? current : "custom" },
            set: { value in
                if value == "custom" { custom = current; settings.engineModels[engine.rawValue] = custom.isEmpty ? "custom" : custom } else { settings.engineModels[engine.rawValue] = value }
            }
        )) {
            ForEach(engine.suggestedModels, id: \.self) { name in
                Text(name.isEmpty ? "Default" : name).tag(name)
            }
            Text("Custom…").tag("custom")
        }
        if !isSuggested {
            TextField("Model name", text: Binding(
                get: { settings.model(for: engine) == "custom" ? "" : settings.model(for: engine) },
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
