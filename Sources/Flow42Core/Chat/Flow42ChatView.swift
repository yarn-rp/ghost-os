// Flow42ChatView .swift - The single chat surface used everywhere.
//
// In-house implementation (we tried SwiftyChat — its bubbles render
// poorly on macOS and require iOS-leaning styling) tailored to our
// agent transcript model. Lifted into Flow42Core so both Flow42App
// (recording handoff, run-autonomously expander, autonomous-run
// route) and Flow42Menu (floating panel chat sidebar) consume the
// SAME view.
//
// Design beats:
//   - Asymmetric Messages-style bubbles (sender right with brand
//     fill, agent left with subtle material)
//   - Tool calls collapse into a "Ran N commands" expander so a long
//     agent turn doesn't drown the conversation
//   - System / final-result / error events have their own slim
//     treatments
//   - Optional date divider when consecutive messages are >5min apart
//   - Composer: rounded multi-line text field, Send button only
//     lights up when text is non-empty, ⏎ sends, ⇧⏎ newline
//   - "Claude is thinking" pulse pill between the last bubble and
//     the composer while the agent has a turn open

import Combine
import MarkdownUI
import SwiftUI

// MARK: - Public entry point

@MainActor
public struct Flow42ChatView: View {

    /// Optional banner above the conversation. Each surface that
    /// embeds this view passes its own (e.g. RecordingHandoffView
    /// uses "FLOW-CREATOR / <slug>", FlowDetailView uses "AUTONOMOUS
    /// RUN / <flow name>", the floating panel passes nil and lets
    /// the surrounding transport bar handle context).
    public struct Header {
        public var eyebrow: String?
        public var title: String?
        public var onStop: (() -> Void)?
        public init(eyebrow: String? = nil, title: String? = nil, onStop: (() -> Void)? = nil) {
            self.eyebrow = eyebrow
            self.title = title
            self.onStop = onStop
        }
    }

    /// The session this chat is observing. Drives the transcript,
    /// the latest snapshot, and the input pipe — every read/write
    /// is scoped to `client.session`.
    @ObservedObject var client: SessionClient
    /// When `true`, the composer disables and a "Start a new session"
    /// banner replaces it. Used when the consumer is rendering a
    /// past, archived session for read-only browsing.
    let isReadOnly: Bool
    /// Optional callback to start a fresh session in read-only mode.
    /// Wired by RecordingHandoffView's "Resume" / "Start new" CTA.
    let onResume: (() -> Void)?
    let placeholder: String
    let header: Header?

    public init(
        client: SessionClient,
        placeholder: String = "Reply to Claude…",
        header: Header? = nil,
        isReadOnly: Bool = false,
        onResume: (() -> Void)? = nil
    ) {
        self.client = client
        self.placeholder = placeholder
        self.header = header
        self.isReadOnly = isReadOnly
        self.onResume = onResume
    }

    @State private var pendingEchoes: [TranscriptEvent] = []
    @State private var isPinnedToBottom: Bool = true
    @State private var input: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            if let header { headerBar(header) }
            conversation
            inputBar
        }
        // Same near-black backdrop the rest of the app uses.
        // DT.backdrop is appearance-aware so it goes off-white in
        // light mode automatically.
        .background(DT.backdrop)
        .onChange(of: client.transcript.count) { _, _ in
            // Drop pending echoes that the canonical transcript has
            // caught up with. Echoes carry a client-minted UUID; the
            // canonical event has a different (server-minted) UUID
            // but the SAME text + a timestamp within ~30s of when we
            // appended the echo. Match on (text, recency window).
            let canonicalUserMessages: [(text: String, ts: Date)] = client.transcript.compactMap { e in
                if case .userMessage(let t) = e.kind { return (t, e.timestamp) }
                return nil
            }
            pendingEchoes.removeAll { echo in
                guard case .userMessage(let echoText) = echo.kind else { return false }
                return canonicalUserMessages.contains { canonical in
                    canonical.text == echoText
                        && abs(canonical.ts.timeIntervalSince(echo.timestamp)) < 60
                }
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func headerBar(_ h: Header) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow = h.eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                }
                if let title = h.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if let onStop = h.onStop {
                Button(role: .destructive, action: onStop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(DT.magenta)
                }
                .buttonStyle(.plain)
                .help("Abort this run (⌘.)")
                .keyboardShortcut(".", modifiers: [.command])
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(
            VStack(spacing: 0) {
                Spacer()
                Divider().opacity(0.5)
            }
        )
    }

    // MARK: Conversation

    private var items: [Flow42ChatItem] {
        let raw = client.transcript
        let canonical = Set(raw.map(\.id))
        let echoes = pendingEchoes.filter { !canonical.contains($0.id) }
        return Flow42ChatItem.group(events: raw + echoes)
    }

    private var isAgentThinking: Bool {
        guard client.snapshot.event != nil else { return false }
        guard let last = client.transcript.last else { return false }
        switch last.kind {
        case .finalResult, .error: return false
        default: return true
        }
    }

    /// Stable spring used for both message insertion (fade + rise
    /// from below) and the conversation diff animation. Tuned to
    /// feel like Messages.app — a quick rise that overshoots slightly
    /// then settles. Same curve everywhere so insertions land
    /// consistently regardless of which surface the chat renders in.
    private static let messageSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        // Date divider when there's a 5+ minute gap
                        // between this item and the previous one.
                        if shouldShowDateDivider(at: idx) {
                            Flow42DateDivider(date: item.timestamp)
                                .padding(.vertical, 6)
                        }
                        renderItem(item)
                            .id(item.id)
                            .padding(.horizontal, 16)
                            // Per-row entrance animation. Each bubble
                            // fades in and rises 8pt from below when
                            // it lands. Removal is a quick fade
                            // (echoes don't need a rise-out — the
                            // canonical bubble takes their place).
                            .transition(
                                .asymmetric(
                                    insertion: .opacity
                                        .combined(with: .offset(y: 10))
                                        .combined(with: .scale(scale: 0.96, anchor: .center)),
                                    removal: .opacity
                                )
                            )
                    }
                    if isAgentThinking {
                        Flow42ThinkingIndicator()
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .id("thinking")
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    Color.clear.frame(height: 4).id("bottom-anchor")
                }
                .padding(.vertical, 14)
                // Diff the LazyVStack against the actual list of ids
                // so insertions/removals run their transitions. Using
                // `.count` alone misses the case where the SAME count
                // hides one item and reveals another (echo→canonical
                // swap during streaming).
                .animation(Self.messageSpring, value: items.map(\.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: client.transcript.count) { _, _ in
                if isPinnedToBottom {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom {
                    Button {
                        isPinnedToBottom = true
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isAgentThinking)
        }
    }

    @ViewBuilder
    private func renderItem(_ item: Flow42ChatItem) -> some View {
        switch item {
        case .event(let event):
            Flow42ChatBubble(event: event)
        case .toolBatch(_, let entries):
            Flow42ToolBatchRow(entries: entries)
        }
    }

    private func shouldShowDateDivider(at idx: Int) -> Bool {
        guard idx > 0 else { return false }
        let cur = items[idx].timestamp
        let prev = items[idx - 1].timestamp
        return cur.timeIntervalSince(prev) > 300  // 5 minutes
    }

    // MARK: Composer

    @ViewBuilder
    private var inputBar: some View {
        if isReadOnly {
            // Past session — composer is disabled. Surface a quiet
            // "this conversation is over, want to keep going?" CTA.
            readOnlyBanner
        } else {
            Flow42ChatInputField(text: $input, placeholder: placeholder) {
                send()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(
                VStack(spacing: 0) {
                    Divider().opacity(0.5)
                    Spacer()
                }
            )
        }
    }

    @ViewBuilder
    private var readOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("This session has ended.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let onResume {
                Button(action: onResume) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start a new session")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(DT.magenta.opacity(0.15))
                    )
                    .overlay(Capsule().strokeBorder(DT.magenta.opacity(0.40), lineWidth: 0.5))
                    .foregroundStyle(DT.magenta)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                Spacer()
            }
        )
    }

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let echo = TranscriptEvent(kind: .userMessage(trimmed))
        pendingEchoes.append(echo)
        // Per-session input pipe — the runner watching this session's
        // input.jsonl picks the line up. Other sessions stay quiet.
        let line = AgentInputLine(kind: .prompt, text: trimmed)
        try? SessionInputLog.append(line, to: client.session)
        input = ""
    }
}

// MARK: - ChatItem grouping

@MainActor
enum Flow42ChatItem: Identifiable {
    case event(TranscriptEvent)
    case toolBatch(id: UUID, entries: [ToolEntry])

    struct ToolEntry: Identifiable {
        let id: UUID
        let name: String
        let summary: String
        let resultSummary: String?
        let isError: Bool
    }

    var id: UUID {
        switch self {
        case .event(let e): return e.id
        case .toolBatch(let id, _): return id
        }
    }

    var timestamp: Date {
        switch self {
        case .event(let e): return e.timestamp
        case .toolBatch: return Date()  // batches use the first entry's timestamp implicitly via grouping order; date divider uses neighbor comparison so this is rarely sampled
        }
    }

    static func group(events: [TranscriptEvent]) -> [Flow42ChatItem] {
        var out: [Flow42ChatItem] = []
        var batch: [ToolEntry] = []

        func flush() {
            guard !batch.isEmpty else { return }
            out.append(.toolBatch(id: batch[0].id, entries: batch))
            batch.removeAll()
        }

        for event in events {
            switch event.kind {
            case .toolCall(let name, let summary):
                batch.append(ToolEntry(id: event.id, name: name, summary: summary, resultSummary: nil, isError: false))
            case .toolResult(let summary, let isError):
                if let last = batch.last, last.resultSummary == nil {
                    batch[batch.count - 1] = ToolEntry(
                        id: last.id, name: last.name, summary: last.summary,
                        resultSummary: summary, isError: isError
                    )
                } else {
                    batch.append(ToolEntry(
                        id: event.id, name: "result", summary: "",
                        resultSummary: summary, isError: isError
                    ))
                }
            default:
                flush()
                out.append(.event(event))
            }
        }
        flush()
        return out
    }
}

// MARK: - Date divider

@MainActor
private struct Flow42DateDivider: View {
    let date: Date

    private var label: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack {
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Bubble

@MainActor
private struct Flow42ChatBubble: View {
    let event: TranscriptEvent

    var body: some View {
        switch event.kind {
        case .userMessage(let text):
            messageRow(text: text, isUser: true)
        case .assistantText(let text):
            messageRow(text: text, isUser: false)
        case .systemInfo(let text):
            systemRow(text)
        case .finalResult:
            // "Done / Stop reason: end_turn" is internal protocol
            // state — the user already sees "Claude is thinking"
            // dimming when the agent finishes its turn. Don't
            // surface a redundant green confirmation bubble.
            EmptyView()
        case .error(let text):
            errorRow(text)
        case .raw(let text):
            systemRow(text)
        case .toolCall, .toolResult:
            EmptyView()
        }
    }

    /// Asymmetric Messages-style bubble: trailing-anchored for the
    /// user (orange fill + white text), leading-anchored for the
    /// agent (subtle material). User messages are plain text; agent
    /// messages render Markdown (bold, italic, code, lists, code
    /// blocks, links) via MarkdownUI.
    private func messageRow(text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            bubbleContent(text: text, isUser: isUser)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground(isUser: isUser))
                .overlay(bubbleOverlay(isUser: isUser))
                .shadow(color: .black.opacity(0.05), radius: 1.5, x: 0, y: 1)
                .textSelection(.enabled)
                .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                // Streaming-friendly height growth: when the agent's
                // last bubble keeps getting longer as tokens arrive,
                // animate the size delta so the bubble pulses out
                // smoothly instead of snapping. Keyed on text length
                // so identical reflows don't trigger a re-animate.
                .animation(.easeOut(duration: 0.18), value: text.count)
            if !isUser { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func bubbleContent(text: String, isUser: Bool) -> some View {
        if isUser {
            // User text is plain — Markdown styling on user input
            // would feel weird ("did I bold that?"). Render as-is.
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(.white)
        } else {
            // Agent messages can include lists, code blocks,
            // inline code, headers, links. MarkdownUI handles all
            // of them. We apply a Flow42 theme that matches the
            // surrounding bubble: 14pt body, monospaced inline
            // code, slightly tinted blockquote/codeblock backings.
            Markdown(text)
                .markdownTheme(.flow42)
                .markdownTextStyle {
                    FontSize(14)
                    ForegroundColor(.primary)
                }
        }
    }

    @ViewBuilder
    private func bubbleBackground(isUser: Bool) -> some View {
        if isUser {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [DT.orange, DT.orange.opacity(0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        }
    }

    @ViewBuilder
    private func bubbleOverlay(isUser: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isUser ? Color.white.opacity(0.15) : Color.primary.opacity(0.08),
                lineWidth: 0.5
            )
    }

    private func systemRow(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            Spacer()
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DT.red)
                .padding(.top, 1)
            Markdown(text)
                .markdownTheme(.flow42)
                .markdownTextStyle {
                    FontSize(13)
                    ForegroundColor(.primary)
                }
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DT.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DT.red.opacity(0.30), lineWidth: 0.5)
        )
        .frame(maxWidth: 560, alignment: .leading)
    }

}

// MARK: - Tool batch

@MainActor
private struct Flow42ToolBatchRow: View {
    let entries: [Flow42ChatItem.ToolEntry]
    @State private var expanded: Bool = false

    private var commandCount: Int { entries.count }
    private var hasErrors: Bool { entries.contains(where: \.isError) }
    private var accent: Color { hasErrors ? DT.red : DT.cyan }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 12)
                        Text("Ran \(commandCount) command\(commandCount == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if hasErrors {
                            Text("·").font(.system(size: 12)).foregroundStyle(.tertiary)
                            Text("\(entries.filter(\.isError).count) failed")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DT.red)
                        }
                        Spacer()
                        if !expanded, let preview = entries.last?.summary, !preview.isEmpty {
                            Text(preview)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 220, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider().opacity(0.3)
                        ForEach(entries) { entry in
                            toolRow(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.22), lineWidth: 0.5)
            )
            .frame(maxWidth: 560, alignment: .leading)

            Spacer(minLength: 40)
        }
    }

    private func toolRow(_ entry: Flow42ChatItem.ToolEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text(entry.summary.isEmpty ? entry.name : entry.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            if let result = entry.resultSummary {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.isError ? DT.red : DT.green)
                        .frame(width: 14)
                    Text(result)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("running…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 22)
            }
        }
    }
}

// MARK: - Thinking pill

@MainActor
private struct Flow42ThinkingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.32, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DT.orange)
            Text("Claude is thinking")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 3, height: 3)
                        .opacity(phase == i ? 1.0 : 0.3)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - Markdown theme

extension MarkdownUI.Theme {
    /// Matches the chat bubble's body font + breathing room. Inline
    /// code gets a subtle tinted background; code blocks get a
    /// material card so they read as "different surface" from prose.
    static let flow42 = MarkdownUI.Theme()
        .text {
            FontSize(14)
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            BackgroundColor(.primary.opacity(0.08))
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(DT.cyan) }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(18)
                }
                .padding(.vertical, 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .padding(.vertical, 2)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                    }
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.vertical, 4)
        }
        .blockquote { configuration in
            HStack(spacing: 8) {
                Rectangle().fill(.primary.opacity(0.18)).frame(width: 2)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
            }
            .padding(.vertical, 2)
        }
}

// MARK: - Composer

@MainActor
struct Flow42ChatInputField: View {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void

    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // Real macOS text field — TextField(.vertical) gives us
            // native key handling (cmd+A, cut/copy/paste, arrow-key
            // selection, undo/redo, the whole AppKit suite) AND
            // grows vertically when the user pastes a long block or
            // hits Shift+Return for a newline. TextEditor (which we
            // were using before) is meant for full editor surfaces
            // and drops most of those bindings.
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .focused($focused)
                .onSubmit { onSend() }
                .onKeyPress(.return) {
                    // ⇧⏎ = newline (let the TextField insert it).
                    // ⏎ = send. We can't intercept the regular
                    // Return because TextField swallows it for line
                    // wrapping when axis: .vertical is used; the
                    // .onSubmit above catches the submit gesture.
                    if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                    onSend()
                    return .handled
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(focused ? 0.20 : 0.10), lineWidth: 0.5)
                )

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(canSend
                                  ? AnyShapeStyle(LinearGradient(
                                      colors: [DT.orange, DT.orange.opacity(0.85)],
                                      startPoint: .top, endPoint: .bottom
                                  ))
                                  : AnyShapeStyle(Color.secondary.opacity(0.30)))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(canSend ? "Send (↩)" : "Type a message")
        }
        .onAppear { focused = true }
    }
}
