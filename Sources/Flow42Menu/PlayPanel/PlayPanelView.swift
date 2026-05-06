// PlayPanelView.swift - Vertical floating panel with the macOS Tahoe / liquid-
// glass aesthetic. Eyebrow + phase title, intent prose, the current step's
// screenshot, step caption, optional pause callout, and a media-player-style
// transport bar at the bottom.
//
// Two visual states keyed off `play.state` + `play.pause`:
//
//   driving  → orange accent, center button is Pause
//   watching → blue accent,   center button is Play (Resume if pause != nil)
//
// Width fixed at 320 pt; height grows with the pause callout. The controller
// passes in the resolved current-step screenshot, step text, intent, and
// params dict so this view stays a pure renderer (no I/O).

import AppKit
import Combine
import Flow42Core
import SwiftUI

// MARK: - Tokens

// Internal so AgentActivityRow + ChatModeView can share the same accent
// palette and metrics — keeps the floating panel visually coherent
// without each subview redeclaring the same Color literals.
enum PanelTokens {
    static let width: CGFloat = 400                 // 360 → 400 for screenshot room (matches recording panel)
    static let outerCornerRadius: CGFloat = 20
    static let innerSpacing: CGFloat = 16
    static let edgePadding: CGFloat = 20
    static let screenshotCorner: CGFloat = 10

    // Type hierarchy. Wider delta between eyebrow / title / body so the
    // structure reads at a glance — eyebrows feel like labels, the phase
    // title dominates, body reads at a comfortable 14pt.
    static let eyebrowSize: CGFloat = 10
    static let titleSize: CGFloat = 22
    static let bodySize: CGFloat = 14
    static let stepCaptionSize: CGFloat = 14
    static let pauseReasonSize: CGFloat = 14

    static let orange = Color(red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255)
    static let blue   = Color(red: 0x3D/255, green: 0xB6/255, blue: 0xFF/255)
    // Chat-bubble shared palette. Used by ChatBubble + AgentActivityRow
    // so tool-call / result / error / done styling is consistent across
    // the compact bubble and the full chat surface.
    static let purple = Color(red: 0xB0/255, green: 0x6F/255, blue: 0xFF/255)
    static let green  = Color(red: 0x36/255, green: 0xC8/255, blue: 0x5B/255)
    static let red    = Color(red: 0xFF/255, green: 0x5C/255, blue: 0x5C/255)
}

// MARK: - Session client box
//
// `@ObservedObject` doesn't take optionals, but the floating panel
// only has a chat session SOMETIMES (no session during recording,
// no session before the agent has spawned a chat). This thin
// wrapper holds an optional SessionClient and republishes its
// changes — so the view binds to the box and the box swaps the
// inner client without recreating the view.

@MainActor
final class SessionClientBox: ObservableObject {
    @Published var client: SessionClient?
    private var inner: AnyCancellable?

    init(client: SessionClient? = nil) {
        self.client = client
        bind(client)
    }

    func set(_ client: SessionClient?) {
        self.client = client
        bind(client)
    }

    private func bind(_ client: SessionClient?) {
        inner = client?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - PlayPanelView

/// Where the panel is being rendered. Controls glass/shadow + which primary
/// icon button is shown in the top-right (`floating` shows "minimize" so
/// the user can close the floating window without ending the session;
/// `popover` shows "expand" so the user can promote the popover content
/// into the floating window).
enum PlayPanelStyle {
    case floating
    case popover
}

struct PlayPanelView: View {
    let state: AppState
    let intent: String
    let stepText: String
    let stepScreenshotPath: String?
    let params: [String: String]
    let style: PlayPanelStyle

    /// Closures wired up by the controller — keep the view free of process
    /// spawning so it stays previewable.
    let onPause: () -> Void
    let onResume: () -> Void
    /// User confirmed they completed the manual step the agent was stuck
    /// on. Should advance the play position AND resume so the agent picks
    /// up at the next phase rather than retrying this one.
    let onResumeAndAdvance: () -> Void
    /// Step navigation in watching mode (Guide-me + manual scrubbing).
    /// In driving mode the agent owns position; these are no-ops there.
    let onNextStep: () -> Void
    let onPrevStep: () -> Void
    /// Primary top-right action: close-floating (in `.floating`) or
    /// open-floating (in `.popover`).
    let onPrimaryAction: () -> Void
    /// End the session entirely.
    let onStop: () -> Void

    /// Live chat session for autonomous runs. Per-recording (or per-
    /// play) — drives the in-panel chat bubble + chat-mode swap.
    /// Optional because there isn't always an active session
    /// (recording mode, idle, or before the agent starts a session).
    /// Owned by PlayPanelController so the FSEvents subscription
    /// survives view rebuilds.
    @ObservedObject var chatSession: SessionClientBox

    private var play: PlayInfo? { state.play }
    private var isPaused: Bool { play?.pause != nil }
    private var isWatching: Bool { play?.state == .watching && !isPaused }
    private var isDriving: Bool { play?.state == .driving && !isPaused }

    private var accent: Color { isDriving ? PanelTokens.orange : PanelTokens.blue }

    /// True when the panel has a live chat session attached AND its
    /// latest snapshot is from THIS play (snapshot.playId matches).
    /// Gates the bubble + 💬 toggle visibility during compact mode.
    private var hasActiveAgent: Bool {
        guard let client = chatSession.client else { return false }
        guard let snap = client.snapshot.event,
              let snapPlayId = client.snapshot.playId,
              let activePlayId = play?.id else { return false }
        _ = snap
        return snapPlayId == activePlayId
    }

    /// Pre-play "chat-only" mode — the runner has spawned an ACP
    /// session (chatSession.client is non-nil) but `state.play` is
    /// still nil because the agent is gathering params from the
    /// user before calling `flow42 play start`. The whole panel
    /// becomes a chat surface in this mode.
    var isChatOnlyMode: Bool {
        play == nil && chatSession.client != nil
    }

    /// One-tap toggle between compact (default) and chat-mode body
    /// during driving/watching. Same construction as RecordingPanelView's
    /// `showingList`. Ignored in chat-only mode (where the body IS chat).
    @State private var showingChat: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if isChatOnlyMode {
                    // Pre-play: agent is talking to the user about
                    // params. Whole panel is a chat surface.
                    chatOnlyBody
                        .padding(.horizontal, PanelTokens.edgePadding)
                        .padding(.top, PanelTokens.edgePadding)
                        .padding(.bottom, PanelTokens.edgePadding - 4)
                } else if showingChat && hasActiveAgent {
                    // Mid-execution: user toggled the chat surface
                    // open from the floating panel's 💬 button.
                    inExecutionChatBody
                        .padding(.horizontal, PanelTokens.edgePadding)
                        .padding(.top, PanelTokens.edgePadding)
                        .padding(.bottom, PanelTokens.edgePadding - 4)
                } else {
                    // Default execution view: phase header + screenshot
                    // + step caption + agent-activity bubble + transport.
                    content
                        .padding(.horizontal, PanelTokens.edgePadding)
                        .padding(.top, PanelTokens.edgePadding)
                        .padding(.bottom, 10)

                    transport
                        .padding(.horizontal, PanelTokens.edgePadding)
                        .padding(.bottom, PanelTokens.edgePadding - 4)
                }
            }

            // Top-right: primary action (close-floating / open-floating)
            // + stop. Two small icon buttons.
            topRightButtons
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
        .frame(width: PanelTokens.width)
        .modifier(GlassChromeIfFloating(style: style, cornerRadius: PanelTokens.outerCornerRadius))
        .animation(.easeInOut(duration: 0.18), value: showingChat)
        .animation(.easeInOut(duration: 0.18), value: isChatOnlyMode)
        // If the agent run ends while we're in chat mode, drop back to
        // compact so the user isn't staring at a frozen transcript.
        .onChange(of: hasActiveAgent) { _, active in
            if !active { showingChat = false }
        }
    }

    /// Chat-only body — used before the play exists. Renders the
    /// shared `Flow42ChatView` bound to the active session. Same
    /// component the main app uses; one consistent UX no matter
    /// which window the chat shows up in.
    @ViewBuilder
    private var chatOnlyBody: some View {
        if let client = chatSession.client {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AUTONOMOUS RUN")
                        .font(.system(size: PanelTokens.eyebrowSize, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Text("Setup")
                        .font(.system(size: PanelTokens.titleSize, weight: .semibold))
                        .padding(.trailing, 56) // room for top-right buttons
                }
                Flow42ChatView(
                    client: client,
                    placeholder: "Reply to Claude…",
                    header: nil,
                    isReadOnly: client.session.status != .active
                )
                .frame(height: 480)
            }
        } else {
            EmptyView()
        }
    }

    /// Mid-execution chat body — the user toggled 💬. Phase header
    /// stays at the top so they remember the action context, then the
    /// shared chat below it. Renders nothing when no live session is
    /// attached (recording mode, idle, or pre-spawn).
    @ViewBuilder
    private var inExecutionChatBody: some View {
        VStack(alignment: .leading, spacing: PanelTokens.innerSpacing) {
            phaseHeader
                .padding(.trailing, 78) // room for the three top-right buttons
            if let client = chatSession.client {
                Flow42ChatView(
                    client: client,
                    placeholder: "Reply to Claude…",
                    header: nil,
                    isReadOnly: client.session.status != .active
                )
                .frame(height: 360)
            } else {
                Text("No live chat session.")
                    .font(.system(size: PanelTokens.bodySize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 360)
            }
        }
    }

    @ViewBuilder
    private var topRightButtons: some View {
        HStack(spacing: 8) {
            // Chat toggle — visible only during execution (compact
            // mode + an active agent). Hidden in chat-only mode
            // because the whole panel IS the chat already.
            if hasActiveAgent && !isChatOnlyMode {
                Button { showingChat.toggle() } label: {
                    Image(systemName: showingChat
                          ? "chevron.left.circle.fill"
                          : "bubble.left.and.text.bubble.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showingChat
                      ? "Back to the step view"
                      : "Open the agent's full conversation")
            }

            Button(action: onPrimaryAction) {
                Image(systemName: primaryActionIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primaryActionTooltip)

            // Destructive — opens a native confirmation alert before
            // ending the session. Cancel is the default action so a
            // stray Return key never accidentally fires Stop.
            ArmedStopButton(
                confirmTitle: stopConfirmTitle,
                confirmMessage: stopConfirmMessage,
                onStop: onStop
            )
        }
    }

    private var primaryActionIcon: String {
        switch style {
        case .floating: return "rectangle.compress.vertical"
        case .popover:  return "macwindow.on.rectangle"
        }
    }
    private var primaryActionTooltip: String {
        switch style {
        case .floating: return "Hide the floating window — the session keeps running. Reopen from the menu bar."
        case .popover:  return "Open the floating window — show the panel anywhere on screen."
        }
    }

    // MARK: - Stop confirmation copy

    /// Title shown in the NSAlert. Stays consistent across states; the
    /// detail goes in `stopConfirmMessage`.
    private var stopConfirmTitle: String {
        "Stop the session?"
    }

    /// State-aware body copy. Tells the user what they're cancelling so
    /// they don't accidentally end something they care about.
    private var stopConfirmMessage: String {
        let agent = play?.startedBy.capitalized ?? "The agent"
        let flow = play?.flowName ?? "this flow"
        if isPaused {
            return "\(agent) is paused waiting on you. Stopping now will end the play of \(flow) without resuming. The full log of what happened so far stays on disk."
        }
        if isWatching {
            return "You're guiding \(agent) through \(flow). Stopping now will end the watching session."
        }
        // Driving.
        return "\(agent) is driving \(flow) right now. Stopping will end the play immediately and the agent will stop touching the screen. Anything done so far is logged."
    }

    // MARK: - Content stack

    @ViewBuilder
    private var content: some View {
        if play != nil {
            VStack(alignment: .leading, spacing: PanelTokens.innerSpacing) {
                phaseHeader
                if !intent.isEmpty {
                    Text(substituteParams(intent))
                        .font(.system(size: PanelTokens.bodySize))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                screenshot
                stepCaption
                if isPaused, let reason = play?.pause?.reason, !reason.isEmpty {
                    pauseCallout(reason)
                }
                // Live agent activity — only renders during an
                // autonomous run, when there's a fresh event from the
                // current play. Hidden during recording / guide-me /
                // when the agent hasn't said anything yet.
                if hasActiveAgent,
                   let event = chatSession.client?.snapshot.event {
                    AgentActivityRow(
                        event: event,
                        onOpenChat: { showingChat = true }
                    )
                }
            }
        }
    }

    // MARK: - Phase header

    @ViewBuilder
    private var phaseHeader: some View {
        if let pos = play?.position {
            VStack(alignment: .leading, spacing: 6) {
                Text("PHASE \(pos.phaseIndex + 1) OF \(pos.totalPhases)")
                    .font(.system(size: PanelTokens.eyebrowSize, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(displayName(pos.phaseName))
                    .font(.system(size: PanelTokens.titleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 26) // leave room for the stop button
            }
        }
    }

    // MARK: - Screenshot

    @ViewBuilder
    private var screenshot: some View {
        if let path = stepScreenshotPath, let img = loadImage(at: path) {
            ScreenshotButton(image: img, path: path) {
                ScreenshotPreview.show(img)
            }
        } else {
            // Skeleton when the screenshot is missing — kept very light so
            // it doesn't compete with the surrounding glass material.
            RoundedRectangle(cornerRadius: PanelTokens.screenshotCorner, style: .continuous)
                .fill(.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTokens.screenshotCorner, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                )
                .frame(height: 140)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                )
        }
    }


    // MARK: - Step caption

    @ViewBuilder
    private var stepCaption: some View {
        if let pos = play?.position, pos.totalStepsInPhase > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("STEP \(pos.stepIndex + 1) OF \(pos.totalStepsInPhase)")
                    .font(.system(size: PanelTokens.eyebrowSize, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                if !stepText.isEmpty {
                    Text(substituteParams(stepText))
                        .font(.system(size: PanelTokens.stepCaptionSize))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Pause callout (blockquote-style, no heavy box)

    private func pauseCallout(_ reason: String) -> some View {
        // A quiet, conversational treatment: a thin colored vertical bar
        // on the left, then a label + the reason as italic body text.
        // Reads like a teammate's note rather than a system warning.
        HStack(alignment: .top, spacing: 12) {
            // Left accent bar — matches the panel accent (cyan for paused).
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(play?.startedBy.capitalized ?? "Agent") says")
                    .font(.system(size: PanelTokens.eyebrowSize, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(substituteParams(reason))
                    .font(.system(size: PanelTokens.pauseReasonSize))
                    .italic()
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Compact phase label used in the resume-confirm alert headline.
    private var phaseTitleForAlert: String {
        guard let pos = play?.position else { return "" }
        return "Phase \(pos.phaseIndex + 1) of \(pos.totalPhases) · \(displayName(pos.phaseName))"
    }

    // MARK: - Transport bar

    private var transport: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.35)
                .padding(.bottom, 12)
            HStack(spacing: 22) {
                Spacer()
                transportSideButton(
                    symbol: "backward.fill",
                    action: onPrevStep,
                    enabled: stepNavEnabled
                )
                transportCenterButton
                transportSideButton(
                    symbol: "forward.fill",
                    action: onNextStep,
                    enabled: stepNavEnabled
                )
                Spacer()
            }
        }
    }

    /// Step nav (prev / next) is meaningful only when the user is
    /// driving — i.e. watching mode (whether user-initiated or agent-
    /// paused). In driving mode the agent owns position; we don't want
    /// the user accidentally bumping it mid-action.
    private var stepNavEnabled: Bool { isWatching || isPaused }

    /// Step nav buttons. Active in watching/paused mode (the user is
    /// driving), disabled in driving mode (the agent owns position).
    private func transportSideButton(
        symbol: String,
        action: @escaping () -> Void,
        enabled: Bool
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1.0 : 0.28)
        .disabled(!enabled)
        .help(enabled
              ? (symbol == "forward.fill" ? "Next step" : "Previous step")
              : "Step nav is available when you take over (watching mode)")
    }

    private var transportCenterButton: some View {
        Button(action: {
            if isDriving {
                onPause()
            } else if isPaused {
                // Agent paused asking for help — fire a native macOS
                // confirmation so the user explicitly tells us whether
                // they completed the manual unblock (advance + resume)
                // or just want the agent to retry this phase (no advance).
                ResumeConfirmAlert.run(
                    phaseTitle: phaseTitleForAlert,
                    stepText: substituteParams(stepText),
                    pauseReason: substituteParams(play?.pause?.reason ?? ""),
                    screenshotPath: stepScreenshotPath,
                    accent: accent,
                    onYes: onResumeAndAdvance,
                    onNo: onResume
                )
            } else {
                // User-initiated watching (took over without an agent
                // pause). Resume immediately, no ceremony.
                onResume()
            }
        }) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: isDriving ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .offset(x: isDriving ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(isDriving
              ? "Pause — hand control back to you"
              : (isPaused ? "Resume — let the agent continue" : "Take over"))
    }

    // MARK: - Helpers

    /// Replace ${param} occurrences with their resolved example values.
    /// We never modify flow.yaml; this is purely for legibility on screen.
    private func substituteParams(_ text: String) -> String {
        guard !params.isEmpty else { return text }
        var out = text
        for (key, value) in params {
            out = out.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return out
    }

    private func displayName(_ snake: String) -> String {
        snake.split(separator: "_")
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

// MARK: - Screenshot button (clickable, hover affordance)

/// The step screenshot, presented as a button. On hover we surface a small
/// magnifier badge in the top-right so the affordance reads — click opens
/// the image in Preview at full size.
private struct ScreenshotButton: View {
    let image: NSImage
    let path: String
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: PanelTokens.screenshotCorner, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if hovered {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(
                                Circle().fill(.black.opacity(0.55))
                            )
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: PanelTokens.screenshotCorner, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
                .scaleEffect(hovered ? 1.012 : 1.0)
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .help("Click to preview at full size — Esc or Space to close")
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Stop button with confirmation dialog

/// Stop is destructive — clicking it ends the session, no undo. We make
/// it visually distinct (red) and present a native NSAlert before firing.
/// The alert's primary button is destructive ("Stop") and Cancel is the
/// default keyboard action so accidental Enter doesn't fire stop.
private struct ArmedStopButton: View {
    let confirmTitle: String
    let confirmMessage: String
    let onStop: () -> Void

    private let red = Color(red: 0xFF/255, green: 0x4C/255, blue: 0x4C/255)

    var body: some View {
        Button(action: confirmAndMaybeStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(red)
                .frame(width: 22, height: 22)
                .overlay(
                    Capsule()
                        .strokeBorder(red.opacity(0.45), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop the session — opens a confirmation.")
    }

    private func confirmAndMaybeStop() {
        let alert = NSAlert()
        alert.messageText = confirmTitle
        alert.informativeText = confirmMessage
        alert.alertStyle = .warning

        // Order matters: first button is the default (rightmost in macOS
        // alert layout). We make Cancel the default so that hitting Return
        // does NOT fire stop. Stop is marked destructive so the system
        // tints it red.
        alert.addButton(withTitle: "Cancel")
        let stopButton = alert.addButton(withTitle: "Stop")
        if #available(macOS 11.0, *) {
            stopButton.hasDestructiveAction = true
        }
        // Cancel: keyEquivalent = "\r" (default action: Return).
        alert.buttons[0].keyEquivalent = "\r"
        // Stop: Cmd-period as a shortcut (matches "stop the operation"
        // convention on macOS), but no default-key.
        alert.buttons[1].keyEquivalent = ""

        let response = alert.runModal()
        // alertSecondButtonReturn == .alertSecondButtonReturn == Stop
        // (since we added Cancel first and Stop second).
        if response == .alertSecondButtonReturn {
            onStop()
        }
    }
}

// MARK: - Conditional chrome (glass + border + shadow only in floating mode)

/// In `.floating` mode we apply Liquid Glass + a hairline border + a soft
/// shadow so the panel reads as a free-standing card. In `.popover` mode
/// we skip all of that — the NSPopover provides its own background and
/// shadow, so adding our own would compound the chrome.
private struct GlassChromeIfFloating: ViewModifier {
    let style: PlayPanelStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .floating:
            applyGlass(content)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
        case .popover:
            content   // bare; popover host provides chrome
        }
    }

    @ViewBuilder
    private func applyGlass(_ content: Content) -> some View {
        // We deliberately use the FROSTED variant (vs. `.clear`).
        // Reason: chat is text-heavy. `.clear` lets so much desktop
        // bleed through that whatever is behind the panel competes
        // with the messages — agent text, code blocks, and the input
        // field are all hard to read. The frosted/regular variant
        // (Liquid Glass `.regular` on macOS 26+, NSVisualEffectView
        // .underWindowBackground on older OSes) gives us a near-
        // opaque surface with just enough material vibrancy to
        // still feel like a system panel, not a flat dark rectangle.
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    OpaqueChromeBackground()
                        .clipShape(RoundedRectangle(
                            cornerRadius: cornerRadius, style: .continuous
                        ))
                )
        }
    }
}

/// Sonoma / Sequoia fallback — NSVisualEffectView with the most opaque
/// material macOS exposes. Reads as "Mail's sidebar" rather than
/// "tooltip floating in space".
private struct OpaqueChromeBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Resume confirmation alert (native NSAlert with accessory view)
//
// The agent paused asking for help. The user did the manual thing and is
// clicking Play. We intercept with a native macOS confirmation so the user
// can tell us:
//   "Yes, let's move on"  → advance to the next phase + resume
//   "No, I didn't"        → just resume; agent retries this phase
// The alert shows the step screenshot + caption + the agent's pause reason
// as an accessory view above the buttons so the user has full context
// without having to look back at the floating panel.

enum ResumeConfirmAlert {

    @MainActor
    static func run(
        phaseTitle: String,
        stepText: String,
        pauseReason: String,
        screenshotPath: String?,
        accent: Color,
        onYes: @escaping () -> Void,
        onNo:  @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Did you finish this step?"
        // Informative text shows the phase title; the screenshot + step
        // body + reason go in the accessory view below so they get more
        // visual weight than NSAlert's compressed informativeText layout
        // would allow.
        alert.informativeText = phaseTitle
        alert.alertStyle = .informational

        alert.accessoryView = makeAccessoryView(
            stepText: stepText,
            pauseReason: pauseReason,
            screenshotPath: screenshotPath
        )

        // Button order: first button = default (rightmost in macOS).
        // "Yes, let's move on" is the forward action and the default
        // (Return triggers it); "No, I didn't" is the alternate; Cancel
        // dismisses without doing anything.
        let yesButton = alert.addButton(withTitle: "Yes, let’s move on")
        alert.addButton(withTitle: "No, I didn’t")
        alert.addButton(withTitle: "Cancel")

        // Cancel: Esc.
        alert.buttons[2].keyEquivalent = "\u{1b}"
        // Yes is already default ("\r"). Don't tint — NSAlert default is
        // already visually distinct, and accent colors here would conflict
        // with the user's system tint preferences. (The `accent` arg is
        // available if we want to add tinting later.)
        _ = yesButton
        _ = accent

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  onYes()
        case .alertSecondButtonReturn: onNo()
        default: break // Cancel: leave the play paused, do nothing.
        }
    }

    /// Accessory: a vertical stack with the step screenshot (capped at
    /// 360×200) on top, a small step-text caption below it, then the
    /// agent's pause reason in italics. Width is fixed; height grows with
    /// content so long reasons aren't truncated.
    @MainActor
    private static func makeAccessoryView(
        stepText: String,
        pauseReason: String,
        screenshotPath: String?
    ) -> NSView {
        let width: CGFloat = 380
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        // Screenshot (skip if missing; the alert still reads fine without).
        if let path = screenshotPath,
           let img = loadResolvedImage(at: path) {
            let imgView = NSImageView()
            imgView.image = img
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.imageAlignment = .alignCenter
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 8
            imgView.layer?.masksToBounds = true
            imgView.layer?.borderWidth = 0.5
            imgView.layer?.borderColor = NSColor.separatorColor.cgColor
            // Constrain to a sensible aspect-fit box.
            let maxH: CGFloat = 200
            let aspect = img.size.height / max(img.size.width, 1)
            let h = min(maxH, width * aspect)
            imgView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imgView.widthAnchor.constraint(equalToConstant: width),
                imgView.heightAnchor.constraint(equalToConstant: h),
            ])
            container.addArrangedSubview(imgView)
        }

        // Step caption.
        if !stepText.isEmpty {
            let stepLabel = wrappingLabel(text: stepText, width: width, italic: false, secondary: false)
            container.addArrangedSubview(stepLabel)
        }

        // Pause reason — italicized + secondary so it reads as the agent's
        // note rather than a system instruction.
        if !pauseReason.isEmpty {
            let reasonLabel = wrappingLabel(
                text: "“\(pauseReason)”",
                width: width,
                italic: true,
                secondary: true
            )
            container.addArrangedSubview(reasonLabel)
        }

        // Wrap in a view with a fixed width so NSAlert doesn't stretch us.
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            wrapper.widthAnchor.constraint(equalToConstant: width),
        ])
        // NSAlert needs a non-zero frame on the accessory view before it
        // measures the layout; the autolayout pass refines it.
        wrapper.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        return wrapper
    }

    private static func wrappingLabel(
        text: String,
        width: CGFloat,
        italic: Bool,
        secondary: Bool
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        if italic {
            // Italic via font descriptor — no system "italic body" preset.
            let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            if let desc = base.fontDescriptor.withSymbolicTraits(.italic) as NSFontDescriptor?,
               let italicFont = NSFont(descriptor: desc, size: base.pointSize) {
                label.font = italicFont
            } else {
                label.font = base
            }
        } else {
            label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }
        if secondary {
            label.textColor = .secondaryLabelColor
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: width),
        ])
        return label
    }

    /// Path-resolving image loader — the screenshot path stored in
    /// state.json may be relative (per the recording layout) or absolute.
    /// The view-side `loadImage` is private; we re-implement here against
    /// the same conventions.
    private static func loadResolvedImage(at path: String) -> NSImage? {
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return NSImage(contentsOfFile: expanded)
        }
        return nil
    }
}

// MARK: - Image loader (best-effort, synchronous)

/// Synchronous image load — file is local and small, view rebuild rate is
/// FSEvents-driven (~once per state.json change).
private func loadImage(at path: String) -> NSImage? {
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else { return nil }
    return NSImage(contentsOfFile: expanded)
}
