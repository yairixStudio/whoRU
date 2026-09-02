import AppKit
import SwiftUI
import WhoRUCore

/// The fixed strip above the scrolling content: who is speaking, and a close
/// button that is always reachable, however far the content is scrolled.
struct CompanionHeader: View {
    let session: ScanSession
    let onClose: () -> Void

    var body: some View {
        HStack {
            Label("whoRU", systemImage: "person.fill.questionmark")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if session.fromCache, let at = session.cachedAt {
                Text("from \(at, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// Three layers of information in one panel that grows: glance, explain,
/// inspect, and a question field. Built from system parts only. The glass,
/// the rounded clip and the header live in `CompanionRoot`, around the scroll.
struct CompanionView: View {
    @Bindable var session: ScanSession
    let model: AppModel
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showExplain = false
    @State private var showEvidence = false
    @State private var showRaw: EvidenceItem?
    @FocusState private var questionFocused: Bool

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identity
            verdictRow
            if session.hardScore != nil {
                explainSection
                evidenceSection
                if session.record?.analystSession != nil, !session.isManualWithoutEngine {
                    chatSection
                }
            }
            if session.dialogClosed, session.decision == .unknown, !session.isManual {
                decisionRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 2)
        .animation(animation, value: session.evidence.count)
        .animation(animation, value: session.verdict)
        .animation(animation, value: showExplain)
        .animation(animation, value: showEvidence)
        .animation(animation, value: session.messages.count)
        .sheet(item: $showRaw) { item in RawOutputSheet(item: item) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("whoRU")
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: 10) {
            AppIcon(path: session.subject?.verificationPath)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.subject?.displayName ?? session.prompt.requesterName)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let publisher = session.evidence.first(where: { $0.key == .publisher })?.facts[Fact.publisherName]
            ?? session.evidence.first(where: { $0.key == .signerIdentity })?.facts[Fact.signerName] {
            parts.append(publisher)
        }
        if let version = session.subject?.version { parts.append(version) }
        if let subject = session.subject, subject.displayName != session.prompt.requesterName, session.prompt.locale != "und" {
            parts.append("“\(session.prompt.requesterName)”")
        }
        if parts.isEmpty { parts.append(session.prompt.service == .other ? session.rawTitle : session.prompt.requestPhrase) }
        return parts.joined(separator: " · ")
    }

    // MARK: Verdict

    private var verdictRow: some View {
        HStack(alignment: .top, spacing: 10) {
            verdictSymbol
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                if let headline = session.displayedHeadline {
                    Text(headline.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(color(session.presentation.color))
                        .contentTransition(.opacity)
                    Text(headline.sentence)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    confidenceLine
                } else {
                    Text("Checking…")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(session.evidence.isEmpty ? session.prompt.requestPhrase : "\(session.evidence.count) checks so far")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var verdictSymbol: some View {
        let p = session.presentation
        if session.hardScore == nil {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: !reduceMotion)
        } else {
            Image(systemName: p.symbol)
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color(p.color))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    @ViewBuilder
    private var confidenceLine: some View {
        HStack(spacing: 6) {
            if let verdict = session.verdict {
                Text("\(confidenceWord(verdict.confidence)) · \(verdict.confidence)%")
                    .contentTransition(.numericText())
            } else if session.analysis == .thinking {
                Image(systemName: "sparkles")
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    .foregroundStyle(.tint)
                Text(session.toolActivity ?? "AI is reading the evidence…")
            } else if case .skipped(let reason) = session.analysis {
                Text(reason)
            } else if case .failed = session.analysis {
                Text("AI unavailable · evidence only")
            } else if case .rejected = session.analysis {
                Text("AI contradicted hard evidence · showing evidence only")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    // MARK: Explain

    @ViewBuilder
    private var explainSection: some View {
        if let verdict = session.verdict {
            DisclosureGroup(isExpanded: $showExplain) {
                VStack(alignment: .leading, spacing: 8) {
                    labeled("What it is", verdict.whatItIs)
                    labeled("Why it asks", verdict.whyItAsks)
                    labeled("If you deny", verdict.ifDenied)
                    if !verdict.suggestedQuestions.isEmpty, session.record?.analystSession != nil {
                        FlowLayout(spacing: 6) {
                            ForEach(verdict.suggestedQuestions, id: \.self) { question in
                                Button(question) { model.send(question, in: session) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 2)
            } label: {
                Text("Explanation").font(.callout)
            }
        }
    }

    private func labeled(_ label: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Evidence

    private var evidenceSection: some View {
        DisclosureGroup(isExpanded: $showEvidence) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(session.evidence) { item in
                    Button { showRaw = item } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: symbol(for: item.status))
                                .foregroundStyle(color(for: item.status))
                                .font(.caption)
                                .frame(width: 14)
                            Text(item.key.rawValue)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                                .environment(\.layoutDirection, .leftToRight)
                            Text(item.summary)
                                .font(.callout)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.status.rawValue): \(item.key.rawValue), \(item.summary)")
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                HStack(spacing: 8) {
                    if let record = session.record {
                        Button("What was sent?") { showRaw = Self.bundleItem(for: record) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    if let subject = session.subject {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: subject.verificationPath)]) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Evidence").font(.callout)
                Text("· \(session.evidence.filter { $0.status == .pass }.count) passed")
                    .font(.caption).foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
        }
    }

    static func bundleItem(for record: ScanRecord) -> EvidenceItem {
        let bundle = EvidenceBundle(prompt: record.prompt, subject: record.subject, candidates: record.candidates, evidence: record.evidence,
                                    hardScore: record.hardScore ?? HardScoreResult(score: .amber, reasons: []))
            .redactedForModel(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let json = (try? JSONValue(encoding: bundle).string(pretty: true)) ?? "{}"
        return EvidenceItem(key: "what_was_sent", status: .info, weight: .base, summary: "The exact JSON the AI received", raw: json, method: "evidence bundle")
    }

    // MARK: Chat

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(session.messages) { message in
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.role == .user ? "You" : "whoRU")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(message.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            if session.isReplying {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("whoRU").font(.caption2).foregroundStyle(.tertiary)
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        if let activity = session.toolActivity { Text(activity).font(.caption2).foregroundStyle(.tertiary) }
                    }
                    if !session.streamingReply.isEmpty {
                        Text(session.streamingReply).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint).font(.callout)
                TextField("Ask about this request…", text: $session.draft)
                    .textFieldStyle(.plain)
                    .focused($questionFocused)
                    .onSubmit { model.send(session.draft, in: session) }
                    .disabled(session.isReplying)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    // MARK: Decision

    private var decisionRow: some View {
        HStack(spacing: 8) {
            Text("What did you choose?").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Allowed") { model.recordDecision(.allowed, for: session) }.buttonStyle(.bordered).controlSize(.small)
            Button("Denied") { model.recordDecision(.denied, for: session) }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    // MARK: Helpers

    private func confidenceWord(_ confidence: Int) -> String {
        switch confidence {
        case 85...: "High confidence"
        case 60..<85: "Medium confidence"
        default: "Low confidence"
        }
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "accent": .accentColor
        default: .secondary
        }
    }

    private func symbol(for status: EvidenceStatus) -> String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .info: "info.circle"
        case .neutral: "circle.dashed"
        case .skipped: "minus.circle"
        case .error: "questionmark.circle"
        }
    }

    private func color(for status: EvidenceStatus) -> Color {
        switch status {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        default: .secondary
        }
    }
}

extension ScanSession {
    var isManualWithoutEngine: Bool { false }
}

/// The real icon of the program, as Finder shows it.
struct AppIcon: View {
    let path: String?

    var body: some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }
}

/// “How did you check?” for one row.
struct RawOutputSheet: View {
    let item: EvidenceItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.key.rawValue).font(.headline).environment(\.layoutDirection, .leftToRight)
                    if let method = item.method { Text(method).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            ScrollView {
                Text(item.raw ?? "(no raw output)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.raw ?? item.summary, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 380)
    }
}

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
