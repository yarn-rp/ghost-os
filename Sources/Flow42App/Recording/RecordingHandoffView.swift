// RecordingHandoffView.swift - Landing surface that fires the moment
// a fresh recording lands in Flow42App. Renders the recording's
// metadata strip on the left and the inline chat on the right so the
// user can converse with flow-creator without leaving this page.
//
// What the view does:
//   1. Kick off `AutonomousRunner.startForRecording(...)` so the
//      agent connects, runs the flow-creator skill, and starts
//      producing transcript events.
//   2. Render Flow42ChatView (the shared chat component) for the
//      user's conversation with the agent.
//   3. Watch the recording dir for `flow.yaml`. Once flow-creator
//      writes one, surface a banner with "Open the structured flow"
//      so the user can navigate to the regular FlowDetailView while
//      keeping the chat scrollback intact.

import AppKit
import Combine
import Flow42Core
import SwiftUI

/// Stable navigation value for the handoff route. Mirrors how
/// `FlowSummary` is used as the value type for the regular detail
/// destination. `autoStart` decides whether the view kicks off the
/// flow-creator chat the moment it appears (post-record handoff from
/// the menu's Stop button) or waits for the user to click the
/// "Process this recording" button (manual entry from the flows
/// grid's draft cards).
struct RecordingHandoff: Equatable, Hashable {
    let dir: String
    let slug: String
    var autoStart: Bool = false
}

struct RecordingHandoffView: View {
    let handoff: RecordingHandoff

    @EnvironmentObject private var router: DetailRouter
    @StateObject private var providerStore = ProviderConfigStore()
    @StateObject private var autonomousRunner = AutonomousRunner()

    /// SessionClient bound to the chat surface. Rebuilt whenever the
    /// runner's `activeSession` changes (start, stop, provider swap)
    /// or on appear when we discover a most-recent archived session
    /// to render in read-only mode.
    @State private var sessionClient: SessionClient?

    /// Shows up when the runner can't start — typically "no provider
    /// selected" or a conflicting active session. The user gets a
    /// clear remediation in the message and can retry once they fix
    /// it.
    @State private var startError: String?
    /// Becomes the resolved FlowSummary the moment flow-creator writes
    /// `flow.yaml` into the recording dir. We push a regular
    /// `FlowDetailView` for it; the chat keeps running in the floating
    /// panel during the swap.
    @State private var resolvedFlow: FlowSummary?
    /// Polls the recording dir for `flow.yaml`. Cheap (filesystem
    /// `stat` on a single path every second) and works without
    /// FSEvents wiring; flow-creator's first pass typically takes
    /// 10–60 seconds anyway.
    @State private var poller: Timer?

    /// True once the user clicks "Process this recording". Until
    /// then we render an idle state with capture metadata + the
    /// trigger button. The auto-fire path (post-record handoff from
    /// the menu's Stop button) and the manual path (clicking an
    /// unstructured card in the flows list) both go through this
    /// same button — we just call it programmatically when an
    /// `autoStart` flag is set.
    @State private var didStartSession: Bool = false

    /// Active tab. The Recording tab shows the captured metadata; the
    /// Chat tab is the live conversation with flow-creator. Pressing
    /// "Process this recording" auto-switches to Chat — starting the
    /// session is, conceptually, "entering the chat."
    @State private var activeTab: HandoffTab = .recording

    enum HandoffTab: String, CaseIterable, Identifiable {
        case recording, chat
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recording: return "Recording"
            case .chat: return "Chat"
            }
        }
        var symbol: String {
            switch self {
            case .recording: return "waveform"
            case .chat: return "bubble.left.and.bubble.right.fill"
            }
        }
    }

    /// Convenience accessor — kept as a computed property pulling from
    /// the navigation value so we don't lose the bit on view rebuilds.
    private var autoStart: Bool { handoff.autoStart }

    var body: some View {
        // Tab layout: header strip on top with a segmented control
        // (Recording | Chat). Tapping "Process this recording" auto-
        // switches to the Chat tab — entering the chat IS processing
        // the recording, conceptually. The Recording tab keeps the
        // captured metadata; the Chat tab fills the page edge-to-edge
        // for proper conversation breathing room.
        VStack(spacing: 0) {
            pageHeader
            tabBar
            Divider().opacity(0.4)
            tabContent
        }
        .background(AppBackdrop())
        .onAppear {
            startPollingForFlowYaml()
            loadLatestSession()
            // Auto-fire only when the post-record handoff brought us
            // here. Manual entry (clicking a draft card) waits for
            // the user to hit the trigger button. `startSession`
            // already switches the tab to Chat; manual entry stays on
            // Recording so the user sees what they captured first.
            if autoStart && !didStartSession {
                startSession()
            }
        }
        .onDisappear {
            poller?.invalidate()
            poller = nil
            // Tear down the live agent process — transcript is
            // persisted on disk under the recording's chat/sessions/
            // dir so the user can come back and see it. Any active
            // session metadata is flipped to `.ended` by stop().
            autonomousRunner.stop()
        }
        .onChange(of: autonomousRunner.activeSession?.id) { _, _ in
            // Rebind the chat client when the runner swaps sessions
            // (start, stop, future provider swap).
            rebindClientToActiveSession()
        }
        .onChange(of: resolvedFlow) { _, newFlow in
            // We surface a "Structured — open the flow" CTA in
            // `statusCard` rather than auto-navigating; once we've
            // detected `flow.yaml` once, kill the poller so we're not
            // stat()-ing it forever.
            if newFlow != nil {
                poller?.invalidate()
                poller = nil
            }
        }
    }

    // MARK: - Page header (always visible, above tabs)

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: DT.f11, weight: .medium))
                    .foregroundStyle(DT.magenta)
                Text("RECORDING CAPTURED")
                    .font(.system(size: DT.f10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                if didStartSession && resolvedFlow == nil {
                    Button(role: .destructive) { autonomousRunner.stop() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: DT.f12, weight: .semibold))
                            Text("Stop")
                                .font(.system(size: DT.f12, weight: .semibold))
                        }
                        .foregroundStyle(DT.magenta)
                    }
                    .buttonStyle(.plain)
                    .help("Abort the run (⌘.)")
                    .keyboardShortcut(".", modifiers: [.command])
                }
                if let flow = resolvedFlow {
                    Button { router.push(.flow(flow)) } label: {
                        HStack(spacing: 5) {
                            Text("Open structured flow")
                                .font(.system(size: DT.f12, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: DT.f11, weight: .semibold))
                        }
                    }
                    .glassSubtleCapsule(tint: DT.green)
                }
            }
            Text(handoff.slug.isEmpty ? "Untitled recording" : handoff.slug)
                .font(.system(size: DT.f22, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(handoff.dir)
                .font(.system(size: DT.f10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, DT.s24)
        .padding(.top, DT.s20)
        .padding(.bottom, DT.s12)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(HandoffTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, DT.s24)
        .padding(.bottom, DT.s8)
    }

    private func tabButton(_ tab: HandoffTab) -> some View {
        let active = (activeTab == tab)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { activeTab = tab }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: DT.f11, weight: .semibold))
                Text(tab.label)
                    .font(.system(size: DT.f13, weight: .medium))
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .padding(.horizontal, DT.s12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(alignment: .bottom) {
                // Underline accent for the active tab — Apple uses
                // this in Notes / Mail's tab strip. Subtle but
                // unambiguous.
                if active {
                    Rectangle()
                        .fill(DT.magenta)
                        .frame(height: 2)
                        .offset(y: 9)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        ZStack {
            switch activeTab {
            case .recording:
                recordingTab
                    .transition(.opacity)
            case .chat:
                chatTab
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s24) {
                introCard
                RecordingOverviewCard(dir: handoff.dir)
                RecordingNarrationCard(dir: handoff.dir)
                RecordingEventsList(dir: handoff.dir)
            }
            .padding(.horizontal, DT.s24)
            .padding(.top, DT.s20)
            .padding(.bottom, DT.s32)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var chatTab: some View {
        if let client = sessionClient {
            Flow42ChatView(
                client: client,
                placeholder: "Reply to flow-creator…",
                header: nil,  // page header above the tabs handles context
                isReadOnly: client.session.status != .active,
                onResume: { startSession() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // No session yet (recording was never processed). Empty
            // state with a quick-start CTA — same one the Recording
            // tab's introCard offers.
            VStack(spacing: DT.s12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("No conversation yet")
                    .font(.system(size: DT.f14, weight: .semibold))
                Text("Process the recording to start chatting with flow-creator.")
                    .font(.system(size: DT.f12))
                    .foregroundStyle(.secondary)
                Button(action: startSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: DT.f12, weight: .semibold))
                        Text("Process this recording")
                            .font(.system(size: DT.f12, weight: .semibold))
                    }
                }
                .glassProminentCapsule(tint: DT.magenta)
                .padding(.top, DT.s8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Compact intro for the Recording tab — replaces the old big
    /// "Process this recording" CTA with a calmer card that explains
    /// what's next + offers the start button when nothing's running.
    private var introCard: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            Image(systemName: introIconName)
                .font(.system(size: DT.f17, weight: .medium))
                .foregroundStyle(introIconColor)
                .frame(width: 28, height: 28)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(introTitle)
                    .font(.system(size: DT.f14, weight: .semibold))
                Text(introSubtitle)
                    .font(.system(size: DT.f12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !didStartSession && resolvedFlow == nil {
                    Button(action: startSession) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: DT.f12, weight: .semibold))
                            Text("Process this recording")
                                .font(.system(size: DT.f12, weight: .semibold))
                        }
                    }
                    .glassProminentCapsule(tint: DT.magenta)
                    .padding(.top, DT.s8)
                    .help("Hand this recording to flow-creator and switch to the Chat tab")
                }
                if let err = startError {
                    Text(err)
                        .font(.system(size: DT.f11))
                        .foregroundStyle(DT.red)
                        .padding(.top, DT.s4)
                    Button("Retry") { startSession() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DT.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .strokeBorder(.primary.opacity(0.05), lineWidth: 0.5)
        )
    }

    private var introIconName: String {
        if resolvedFlow != nil { return "checkmark.circle.fill" }
        if !didStartSession { return "sparkles" }
        switch autonomousRunner.status {
        case .idle, .starting: return "waveform.circle.fill"
        case .running, .completed: return "bubble.left.and.bubble.right.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private var introIconColor: Color {
        if resolvedFlow != nil { return DT.green }
        if startError != nil { return DT.red }
        return DT.magenta
    }

    private var introTitle: String {
        if resolvedFlow != nil { return "flow.yaml ready" }
        if !didStartSession { return "Ready to structure" }
        switch autonomousRunner.status {
        case .idle:        return "Connecting to your agent…"
        case .starting:    return "Spinning up flow-creator…"
        case .running:     return "Structuring in chat"
        case .completed:   return "Agent finished — review the chat"
        case .failed(let e): return "Couldn't start: \(e)"
        case .cancelled:   return "Session cancelled"
        }
    }

    private var introSubtitle: String {
        if resolvedFlow != nil {
            return "Open the structured flow when you're ready."
        }
        if !didStartSession {
            return "Click below to hand this recording to flow-creator. We'll switch you to the Chat tab automatically."
        }
        return "Switch to the Chat tab to see the conversation."
    }

    // MARK: - Lifecycle

    /// Find the most-recent chat session for this recording (if any)
    /// and bind the chat client to it in read-only mode. Stale
    /// `.active` rows from a crash are reconciled to `.failed` here
    /// before binding, so the user never sees a stale "live" badge.
    private func loadLatestSession() {
        if let stale = ChatSession.reconcileAndFindActive(ownerDir: handoff.dir) {
            // We tore down on disappear, but if the app crashed we
            // might find an `.active` row. Mark it ended so the
            // chat surface treats it as archived.
            _ = try? stale.markEnded()
        }
        let mostRecent = ChatSession.list(ownerDir: handoff.dir).first
        if let mostRecent {
            sessionClient = SessionClient(session: mostRecent)
        } else {
            sessionClient = nil
        }
    }

    /// Re-bind the chat client when the runner starts/stops/swaps
    /// sessions. When the runner has an active session we observe
    /// that one (live transcript); otherwise we fall back to the
    /// most-recent on-disk session for this recording.
    private func rebindClientToActiveSession() {
        if let live = autonomousRunner.activeSession {
            sessionClient = SessionClient(session: live)
        } else {
            // Runner went quiet — re-load the most recent archived
            // session so the chat tab shows the just-ended transcript
            // instead of going blank.
            let mostRecent = ChatSession.list(ownerDir: handoff.dir).first
            sessionClient = mostRecent.map { SessionClient(session: $0) }
        }
    }

    private func startSession() {
        startError = nil
        didStartSession = true
        do {
            try autonomousRunner.startForRecording(
                dir: handoff.dir,
                slug: handoff.slug,
                provider: providerStore.selected
            )
            // "Processing the recording" IS entering the chat —
            // switch tabs the moment the session is live.
            withAnimation(.easeInOut(duration: 0.22)) {
                activeTab = .chat
            }
        } catch {
            startError = "\(error)"
        }
    }

    /// Watch the recording directory for `flow.yaml`. The first time
    /// flow-creator writes one, resolve it into a FlowSummary so the
    /// user can navigate to the structured surface. Stops polling
    /// once we have it.
    private func startPollingForFlowYaml() {
        let yamlPath = (handoff.dir as NSString).appendingPathComponent("flow.yaml")
        let dir = handoff.dir
        // Capture nothing the timer body would carry across actors —
        // we read state from the FS, hop to the main actor to write
        // `resolvedFlow`, and let the .onChange observer invalidate
        // the timer on the next tick.
        poller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: yamlPath) else { return }
            Task { @MainActor in
                if let summary = FlowsRepository.loadSummary(directory: dir) {
                    resolvedFlow = summary
                }
            }
        }
    }
}
