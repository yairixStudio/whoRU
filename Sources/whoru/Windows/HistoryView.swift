import AppKit
import SwiftUI
import WhoRUCore

/// Every scan, searchable, with the conversation continued in the detail pane.
struct HistoryView: View {
    let model: AppModel

    enum Filter: String, CaseIterable, Identifiable {
        case all, safe, look, deny
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .safe: "Safe"
            case .look: "Worth a look"
            case .deny: "Do not allow"
            }
        }
        var symbol: String {
            switch self {
            case .all: "clock"
            case .safe: "checkmark.seal"
            case .look: "exclamationmark.triangle"
            case .deny: "xmark.shield"
            }
        }
    }

    @State private var records: [ScanRecord] = []
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(Filter.allCases, selection: $filter) { f in
                Label(f.title, systemImage: f.symbol).tag(f)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } content: {
            Table(filtered, selection: $selection) {
                TableColumn("When") { r in Text(r.startedAt, format: .dateTime.day().month(.abbreviated).hour().minute()) }.width(120)
                TableColumn("Program") { r in Text(r.subject?.displayName ?? r.prompt.requesterName) }
                TableColumn("Permission") { r in Text(r.prompt.service.shortName) }.width(120)
                TableColumn("Verdict") { r in
                    HStack(spacing: 4) {
                        Image(systemName: presentation(r).symbol).foregroundStyle(color(presentation(r).color))
                        Text(presentation(r).title)
                    }
                }.width(130)
                TableColumn("Decision") { r in Text(r.userDecision == .unknown ? "—" : r.userDecision.rawValue) }.width(70)
            }
            .searchable(text: $search, prompt: "Program or publisher")
            .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            if let id = selection, let record = records.first(where: { $0.id == id }) {
                HistoryDetail(model: model, record: record, onUpdate: { updated in
                    if let i = records.firstIndex(where: { $0.id == updated.id }) { records[i] = updated }
                })
                .id(record.id)
            } else {
                ContentUnavailableView("Select a scan", systemImage: "magnifyingglass")
            }
        }
        .task { await reload() }
        .toolbar {
            ToolbarItem {
                Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(records.isEmpty)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
    }

    private var filtered: [ScanRecord] {
        records.filter { r in
            let p = presentation(r)
            switch filter {
            case .all: break
            case .safe: guard p.color == "green" || p.symbol == "apple.logo" else { return false }
            case .look: guard p.color == "orange" || p.color == "secondary" else { return false }
            case .deny: guard p.color == "red" else { return false }
            }
            guard !search.isEmpty else { return true }
            let hay = [r.subject?.displayName, r.prompt.requesterName, r.teamID, r.evidence.first { $0.key == .publisher }?.facts[Fact.publisherName]].compactMap { $0 }.joined(separator: " ")
            return hay.localizedCaseInsensitiveContains(search)
        }
    }

    private func reload() async {
        records = (try? await model.store.all()) ?? []
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

    private func exportCSV() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "whoRU-history.csv"
        guard save.runModal() == .OK, let url = save.url else { return }
        var lines = ["date,program,permission,hard_score,verdict,confidence,decision,cost_usd,path"]
        let iso = ISO8601DateFormatter()
        for r in records {
            func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            lines.append([iso.string(from: r.startedAt), q(r.subject?.displayName ?? r.prompt.requesterName), r.prompt.service.shortName, r.hardScore?.score.rawValue ?? "", r.verdict?.verdict.rawValue ?? "", r.verdict.map { String($0.confidence) } ?? "", r.userDecision.rawValue, String(format: "%.4f", r.costUSD), q(r.subject?.path)].joined(separator: ","))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

struct HistoryDetail: View {
    let model: AppModel
    let record: ScanRecord
    let onUpdate: (ScanRecord) -> Void

    @State private var session: ScanSession
    @State private var showRaw: EvidenceItem?

    init(model: AppModel, record: ScanRecord, onUpdate: @escaping (ScanRecord) -> Void) {
        self.model = model
        self.record = record
        self.onUpdate = onUpdate
        _session = State(initialValue: ScanSession(record: record))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AppIcon(path: record.subject?.verificationPath).frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(record.subject?.displayName ?? record.prompt.requesterName).font(.title2.weight(.semibold))
                        Text(record.prompt.title).font(.callout).foregroundStyle(.secondary)
                        Text(record.subject?.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") ?? "not identified")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary).environment(\.layoutDirection, .leftToRight)
                    }
                }
                if let headline = record.bestHeadline {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: session.presentation.symbol).font(.system(size: 26)).symbolRenderingMode(.hierarchical)
                            .foregroundStyle(color(session.presentation.color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline.title).font(.title3.weight(.semibold)).foregroundStyle(color(session.presentation.color))
                            Text(headline.sentence).font(.body).foregroundStyle(.secondary)
                            if let v = record.verdict {
                                Text("\(v.confidence)% · \(v.recommendation.rawValue) · \(record.engine ?? "") \(record.model ?? "")\(record.costUSD > 0 ? String(format: " · $%.4f", record.costUSD) : "")\(record.fromCache ? " · from cache" : "")")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if let v = record.verdict {
                    GroupBox("Explanation") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(v.whatItIs)
                            Text(v.whyItAsks)
                            Text("If denied: \(v.ifDenied)").foregroundStyle(.secondary)
                            ForEach(v.reasons, id: \.self) { r in
                                Label(r.text, systemImage: r.kind == .evidence ? "checkmark.circle" : "lightbulb").font(.callout)
                            }
                            if !v.technicalNotes.isEmpty { Text(v.technicalNotes).font(.caption).foregroundStyle(.tertiary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GroupBox("Evidence") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(record.evidence) { item in
                            Button { showRaw = item } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.status.rawValue).font(.caption).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
                                    Text(item.key.rawValue).font(.system(.caption, design: .monospaced)).frame(width: 130, alignment: .leading).environment(\.layoutDirection, .leftToRight)
                                    Text(item.summary).font(.callout)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text("Your decision:").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { session.decision }, set: { d in
                        model.recordDecision(d, for: session)
                        if let r = session.record { onUpdate(r) }
                    })) {
                        Text("—").tag(UserDecision.unknown)
                        Text("Allowed").tag(UserDecision.allowed)
                        Text("Denied").tag(UserDecision.denied)
                    }
                    .labelsHidden().frame(width: 110)
                    if session.decision != .unknown, session.decisionSource == "system-log" {
                        Text("read from the system log").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Copy Report") { copyReport() }
                }
                aiSection
            }
            .padding(20)
        }
        .sheet(item: $showRaw) { RawOutputSheet(item: $0) }
        .onChange(of: session.messages.count) { _, _ in if let r = session.record { onUpdate(r) } }
        .onChange(of: session.verdict) { _, _ in if let r = session.record { onUpdate(r) } }
        .onChange(of: session.analysis) { _, _ in if let r = session.record { onUpdate(r) } }
    }

    /// What the AI can do for this record now, not what it did when the record
    /// was made: with the agent off there is no conversation, only a note; with
    /// an agent that can continue the conversation on file, the chat; otherwise
    /// a button that sends the scan to the current agent.
    @ViewBuilder
    private var aiSection: some View {
        if model.settings.engine == .none {
            if !session.messages.isEmpty { conversation(readOnly: true) }
            GroupBox {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    Text("The AI agent is off in Settings, so there is no conversation here. Choose an agent to ask about this scan.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Settings…") { AppDelegate.shared?.showSettings() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if session.canContinueConversation(with: model.currentAnalystID) {
            conversation(readOnly: false)
        } else {
            if !session.messages.isEmpty { conversation(readOnly: true) }
            if session.canAskAI, let agent = model.onDemandAgents.first {
                GroupBox {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        if session.analysis == .thinking {
                            ProgressView().controlSize(.small)
                            Text(session.toolActivity ?? "AI is reading the evidence…").foregroundStyle(.secondary)
                        } else if let engine = record.analystSession?.engine {
                            Text("This conversation was with \(model.describe(engine)). Your agent is now \(model.engineDescription); asking starts a new one.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("This scan was not sent to the AI.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.analysis != .thinking {
                            Button("Ask \(agent.displayName)") { model.askAI(session) }
                                .help("Sends the evidence to \(model.describe(agent)). File contents never leave this Mac.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func conversation(readOnly: Bool) -> some View {
        GroupBox("Conversation") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.messages) { m in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.role == .user ? "You" : "whoRU").font(.caption2).foregroundStyle(.tertiary)
                        Text(m.text).textSelection(.enabled)
                    }
                }
                if session.isReplying { ProgressView().controlSize(.small) }
                if !readOnly {
                    HStack {
                        TextField("Ask about this scan…", text: Binding(get: { session.draft }, set: { session.draft = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { send() }
                        Button("Send") { send() }.disabled(session.draft.isEmpty || session.isReplying)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        model.send(session.draft, in: session)
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "red": .red
        default: .secondary
        }
    }

    private func copyReport() {
        var lines = ["# whoRU report", "", "**\(record.prompt.title)**", "", "Program: \(record.subject?.path ?? "not identified")", "Hard score: \(record.hardScore?.score.rawValue ?? "?")"]
        if let h = record.bestHeadline { lines += ["", "## \(h.title)", h.sentence] }
        if let v = record.verdict { lines += ["", v.whatItIs, "", v.whyItAsks, "", "If denied: \(v.ifDenied)", ""] + v.reasons.map { "- \($0.kind == .evidence ? "evidence" : "inference"): \($0.text)" } }
        lines += ["", "## Evidence"] + record.evidence.map { "- \($0.status.rawValue) `\($0.key.rawValue)` \($0.summary)" }
        if !record.messages.isEmpty { lines += ["", "## Conversation"] + record.messages.map { "**\($0.role.rawValue)**: \($0.text)" } }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

extension ScanSession {
    /// A session rebuilt from a stored record, for the history window.
    convenience init(record: ScanRecord) {
        self.init(id: record.id.uuidString, dialog: nil, prompt: record.prompt, rawTitle: record.prompt.title)
        subject = record.subject
        candidates = record.candidates
        evidence = record.evidence
        hardScore = record.hardScore
        headline = record.deterministicHeadline
        verdict = record.verdict
        analysis = record.verdict != nil ? .done : .idle
        self.record = record
        messages = record.messages
        decision = record.userDecision
        fromCache = record.fromCache
        dialogClosed = true
        startedAt = record.startedAt
        decisionSource = record.decisionSource
        decisionLookup = .notFound
    }
}
