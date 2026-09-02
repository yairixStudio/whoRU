import AppKit
import SwiftUI
import WhoRUCore
import WhoRUMac

/// Four tabs, sixteen rows. Everything else is a fixed default.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            AITab(model: model).tabItem { Label("AI", systemImage: "sparkles") }
            PrivacyTab(model: model).tabItem { Label("Privacy", systemImage: "hand.raised") }
            AdvancedTab(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
            Toggle("Show next to permission dialogs", isOn: $model.settings.showNextToDialogs)
            Toggle("Ask the AI automatically", isOn: $model.settings.askModelAutomatically)
            Section("Show for") {
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
            Section {
                LabeledContent("Accessibility", value: model.accessibilityGranted ? "Granted" : "Not granted")
                if !model.accessibilityGranted {
                    Button("Open System Settings") { AccessibilityPermission.openSystemSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AITab: View {
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var keyMessage = ""
    @State private var claudeCode: String = "detecting…"

    var body: some View {
        Form {
            Picker("Engine", selection: $model.settings.engine) {
                Text("Automatic").tag(EngineChoice.auto)
                Text("Claude Code").tag(EngineChoice.claudeCode)
                Text("Claude API").tag(EngineChoice.claudeAPI)
                Text("Local model").tag(EngineChoice.local)
                Text("None (evidence only)").tag(EngineChoice.none)
            }
            LabeledContent("Active", value: model.engineDescription)
            LabeledContent("Claude Code", value: claudeCode)

            Section("API key") {
                SecureField("sk-ant-…", text: $apiKey, prompt: Text(model.secrets.secret(.anthropicAPIKey) != nil ? "•••••••• (saved in Keychain)" : "Paste an Anthropic API key"))
                HStack {
                    Button("Save & Check") { Task { await saveKey() } }.disabled(apiKey.isEmpty)
                    Button("Remove") { try? model.secrets.setSecret(nil, for: .anthropicAPIKey); keyMessage = "Removed"; refresh() }
                    Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Analysis depth", selection: $model.settings.depth) {
                ForEach(AnalysisDepth.allCases, id: \.self) { depth in
                    Text("\(depth.rawValue.capitalized) · \(depth.modelID)").tag(depth)
                }
            }
            Section {
                Stepper(value: $model.settings.monthlyBudgetUSD, in: 1...100, step: 1) {
                    LabeledContent("Monthly budget", value: String(format: "$%.0f · spent $%.2f this month", model.settings.monthlyBudgetUSD, model.monthlySpend))
                }
                Toggle("Allow the AI to search the web", isOn: $model.settings.allowWebSearch)
            } footer: {
                Text("Web search sends program and publisher names to a search engine. Off by default.")
            }
            if model.settings.engine == .local {
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
        if let path = ClaudeCodeAnalyst.locate() {
            let trusted = await ClaudeCodeVerifier.isTrusted(path)
            let version = await ClaudeCodeAnalyst.version(of: path) ?? "?"
            claudeCode = "\(version) · \(trusted ? "verified" : "NOT verified") · \(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))"
        } else {
            claudeCode = "not installed"
        }
    }

    private func saveKey() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let models = try await ClaudeAPIAnalyst.listModels(apiKey: key)
            try model.secrets.setSecret(key, for: .anthropicAPIKey)
            keyMessage = "Saved · \(models.count) models"
            apiKey = ""
            refresh()
        } catch {
            keyMessage = "Not accepted: \(error)"
        }
    }

    private func refresh() {
        model.settings = model.settings // re-create the environment
        Task { await model.refreshEngineDescription() }
    }
}

private struct PrivacyTab: View {
    @Bindable var model: AppModel
    @State private var vtKey = ""
    @State private var vtMessage = ""

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
                Text("Only the file's SHA-256 is sent. VirusTotal sees the hash and your IP address.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Always") {
                Label("File contents never leave this Mac.", systemImage: "lock.fill")
                Label("Your user name is removed from paths before anything is sent.", systemImage: "person.crop.circle.badge.xmark")
                Label("The AI receives a JSON bundle of names, hashes and check results. “What was sent?” in any panel shows it exactly.", systemImage: "doc.text.magnifyingglass")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedTab: View {
    @Bindable var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Full Disk Access") {
                    Button("Open System Settings") { NSWorkspace.shared.open(AccessibilityPermission.fullDiskAccessSettingsURL) }
                }
            } footer: {
                Text("Optional. Lets whoRU read the decision you made from the system's permission database and fill history in automatically.")
            }
            Section("Publishers") {
                PublisherList(model: model)
            }
            Section {
                Stepper(value: $model.settings.historyRetentionDays, in: 7...3650, step: 30) {
                    LabeledContent("Keep history for", value: "\(model.settings.historyRetentionDays) days")
                }
                Toggle("Debug panel", isOn: $model.settings.debugPanel)
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.applicationSupport]) }
                }
            }
            Section {
                Button("Reset whoRU…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Delete all scans, settings and saved keys?", isPresented: $confirmReset) {
                        Button("Delete Everything", role: .destructive) { resetAll() }
                    } message: {
                        Text("The Accessibility permission is removed by you in System Settings → Privacy & Security → Accessibility.")
                    }
            }
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "whoRU-settings.json"
        guard save.runModal() == .OK, let url = save.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(model.settings).write(to: url)
    }

    private func importSettings() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        guard open.runModal() == .OK, let url = open.url, let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        model.settings = settings
    }

    private func resetAll() {
        try? FileManager.default.removeItem(at: model.paths.applicationSupport)
        for key in SecretKey.allCases { try? model.secrets.setSecret(nil, for: key) }
        model.settings = Settings()
    }
}

private struct PublisherList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.publisherDirectory.all.filter { $0.teamID != Publisher.appleTeamID }) { publisher in
                HStack {
                    Text(publisher.name).lineLimit(1)
                    Text(publisher.teamID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { publisher.trust },
                        set: { model.setTrust($0, for: publisher) }
                    )) {
                        Text("Normal").tag(PublisherTrust.normal)
                        Text("Trusted").tag(PublisherTrust.trusted)
                        Text("Blocked").tag(PublisherTrust.blocked)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            Text("Trusted publishers get a green verdict without the AI. Blocked ones are always red.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
