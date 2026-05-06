// PlayPanelController.swift - Owns the bottom-right floating panel.
//
// Subscribes to StateClient. Visible for ANY non-idle state — recording,
// driving, watching. The panel content swaps based on which one is
// active:
//
//   recording → RecordingPanelView (magenta accent, just Stop)
//   driving / watching → PlayPanelView (orange/cyan, full transport bar)
//
// Pause / Resume / Stop closures shell out to the flow42 binary; the
// resulting state.json change loops back through StateClient and the
// panel re-renders. For recordings, we also poll the events.jsonl tail
// every second to update the live event count + elapsed timer.

import AppKit
import Combine
import Flow42Core
import SwiftUI

@MainActor
final class PlayPanelController: ObservableObject {

    /// Whether the floating window is currently being shown. The user can
    /// hide it via the floating window's "minimize" button (which CLOSES
    /// the floating window without stopping the session). The menu bar
    /// popover subscribes to this to decide whether it should render the
    /// small status header (when floating is visible) or the full panel
    /// content + an "Open Floating" button (when floating is hidden).
    @Published private(set) var isFloatingVisible: Bool = true

    /// The resolved content the floating panel renders. Published so the
    /// popover can render the *same* view when the floating window is
    /// hidden — eliminates "two surfaces with similar content drifting
    /// out of sync."
    enum SessionContent: Equatable {
        case play(PlayContent)
        case recording(RecordingContent)
    }

    struct PlayContent: Equatable {
        let intent: String
        let stepText: String
        let stepScreenshotPath: String?
        let params: [String: String]
    }

    /// Recording's content is just "this is the active recording" — the
    /// event list itself comes from the shared TimelineModel which both
    /// the floating panel and the popover observe directly.
    struct RecordingContent: Equatable {
        let slug: String
    }

    @Published private(set) var currentContent: SessionContent?

    private let window: PlayPanelWindow
    private let stateClient: StateClient
    /// Shared event-tail model — used by both the floating recording
    /// panel and the menu bar popover. Both observe the same instance so
    /// they show the same live event list.
    let timelineModel: TimelineModel
    /// Box around the active `SessionClient` — rebuilt whenever the
    /// `~/.flow42/active-chat-session.json` marker changes (Flow42-
    /// App's runner writes the marker on session start, clears on
    /// stop) OR when `state.play` rotates. Empty (`client == nil`)
    /// when no chat session is alive anywhere.
    let chatSession = SessionClientBox()

    /// FSEvents-watched cross-process pointer that tells us which
    /// session Flow42App's runner is driving right now. Without it
    /// the floating panel has no way to find the session — the
    /// runner lives in a different process.
    private var chatMarkerSource: (any DispatchSourceFileSystemObject)?
    private var chatMarkerDirSource: (any DispatchSourceFileSystemObject)?
    private var chatMarkerFD: CInt = -1
    private var chatMarkerDirFD: CInt = -1
    private var hostingView: NSHostingView<AnyView>?
    private var cancellable: AnyCancellable?

    /// Tracks whether we've already anchored the window during this play
    /// session. First show → use anchorDefault (positions bottom-right
    /// with 1/20-screen-width inset). Every state change after that → use
    /// resize, which preserves the user's chosen position. Reset to false
    /// when the session ends.
    private var hasAnchoredThisSession = false

    /// Cache phase resolution by play_id + phase_index. Position changes
    /// within a phase only update step_index, so we don't re-parse
    /// flow.yaml — we just look up a different step in the cached phase.
    private struct PhaseCache {
        let key: String      // "<play_id>:<phase_index>"
        let intent: String
        let params: [String: String]
        let stepTexts: [String]
        let stepScreenshots: [String?]   // absolute paths or nil
    }
    private var phaseCache: PhaseCache?

    init(stateClient: StateClient) {
        self.stateClient = stateClient
        self.window = PlayPanelWindow()
        self.timelineModel = TimelineModel(stateClient: stateClient)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        apply(state: stateClient.state, animated: false)
        cancellable = stateClient.$state.sink { [weak self] state in
            self?.apply(state: state, animated: true)
        }
        // FSEvents-watch the chat-session marker so we react the
        // moment Flow42App's runner spawns or tears down a session.
        attachChatMarkerWatcher()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Chat marker FDs / sources are intentionally not cleaned
        // up here — the controller is effectively a singleton living
        // the menu app's lifetime, and Swift 6's actor isolation
        // forbids accessing main-actor properties from deinit. The
        // OS reclaims the FDs on process exit.
    }

    // MARK: - Apply

    private func apply(state: AppState, animated: Bool) {
        // Resolve the chat session BEFORE deciding whether to show
        // the panel — a live `active-chat-session.json` marker is a
        // valid reason to show the panel even when there's no play
        // or recording yet (the agent is asking clarifying
        // questions before driving). One floating window, one
        // mental model, every active surface.
        rebindChatSession(for: state)
        let hasActiveChat = chatSession.client != nil

        // Hide only when ALL three are absent: no play, no recording,
        // no live chat session.
        if state.play == nil && state.recording == nil && !hasActiveChat {
            phaseCache = nil
            currentContent = nil
            hasAnchoredThisSession = false
            isFloatingVisible = true
            hide(animated: animated)
            return
        }

        // Build the SwiftUI view + populate currentContent.
        let panelView: AnyView
        if let play = state.play {
            panelView = AnyView(makePlayView(state: state, play: play))
        } else if let recording = state.recording {
            panelView = AnyView(makeRecordingView(state: state, recording: recording))
        } else if hasActiveChat {
            // Pre-play autonomous run — agent is asking clarifying
            // questions. Render the same PlayPanelView with no play;
            // the view's `chatOnlyBody` branch fires when chatSession
            // has a client and play is nil.
            panelView = AnyView(makeChatOnlyView())
            currentContent = nil
        } else {
            // Unreachable — guarded above.
            return
        }

        // Center the SwiftUI panel inside the (wider) window so the
        // shadow has bleed room on all four sides.
        let host = AnyView(
            ZStack {
                Color.clear
                panelView
            }
        )
        if let existing = hostingView {
            existing.rootView = host
        } else {
            let nsHost = NSHostingView(rootView: host)
            nsHost.autoresizingMask = [.width, .height]
            window.contentView = nsHost
            hostingView = nsHost
        }

        // Resize to the SwiftUI view's intrinsic content height.
        // Min ~360 (driving with a small screenshot), max ~700 (paused with
        // a long reason + tall screenshot).
        let intrinsic = hostingView?.fittingSize.height ?? 480
        let height = max(360, min(intrinsic, 700))
        if hasAnchoredThisSession {
            // Keep the user's chosen position; only update the height.
            window.resize(toHeight: height)
        } else {
            // First show this session → place at the default bottom-right.
            window.anchorDefault(toHeight: height)
            hasAnchoredThisSession = true
        }

        // Only auto-show the window if the user hasn't explicitly hidden
        // it this session. If they closed the floating window, the popover
        // is now the only visible UI; we shouldn't surprise them by
        // re-showing the floating on every state change.
        //
        // Note: we always call `orderFrontRegardless` when visible — even
        // if `window.isVisible` reports true. Spaces switches and cold
        // launches mid-recording can leave the window technically
        // "visible" but behind another Space's chrome. The floating
        // panel is the user's main affordance during a recording, so
        // bringing it forward on every state change is the right
        // default; the cost is one cheap NSWindow call.
        if isFloatingVisible {
            let wasInvisible = !window.isVisible
            window.alphaValue = (animated && wasInvisible) ? 0 : 1
            window.orderFrontRegardless()
            if animated, wasInvisible {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    window.animator().alphaValue = 1
                }
            }
        }
    }

    // MARK: - Floating-visibility control

    /// Close the floating window; the session continues. The menu bar
    /// popover becomes the only on-screen UI for the active session.
    func hideFloating() {
        isFloatingVisible = false
        hide(animated: true)
    }

    /// Re-open the floating window. Called by the popover's "Open
    /// Floating" button. No-op if no session is active.
    func showFloating() {
        guard stateClient.state.play != nil || stateClient.state.recording != nil else { return }
        isFloatingVisible = true
        // Re-render so the window appears with current content.
        apply(state: stateClient.state, animated: true)
    }

    // MARK: - Per-state view builders

    private func makePlayView(state: AppState, play: PlayInfo) -> PlayPanelView {
        let cache = resolvePhase(for: play)
        let stepIdx = play.position.stepIndex
        let stepText = (stepIdx < cache.stepTexts.count) ? cache.stepTexts[stepIdx] : ""
        let stepShot = (stepIdx < cache.stepScreenshots.count) ? cache.stepScreenshots[stepIdx] : nil

        currentContent = .play(PlayContent(
            intent: cache.intent,
            stepText: stepText,
            stepScreenshotPath: stepShot,
            params: cache.params
        ))

        return PlayPanelView(
            state: state,
            intent: cache.intent,
            stepText: stepText,
            stepScreenshotPath: stepShot,
            params: cache.params,
            style: .floating,
            onPause: { [weak self] in self?.runFlow42(["play", "pause", "--reason", "user paused via floating window"]) },
            onResume: { [weak self] in self?.runFlow42(["play", "resume"]) },
            // User confirmed they completed the manual unblock — advance
            // the play position FIRST (so the agent's next `play current`
            // returns the next phase), then resume.
            onResumeAndAdvance: { [weak self] in
                // MUST be sequential — fire-and-forget concurrent
                // invocations race on state.json and the second writer
                // clobbers the first (so `next` advances but `resume`
                // is dropped, or vice versa).
                self?.runFlow42Sequence([["play", "next"], ["play", "resume"]])
            },
            onNextStep: { [weak self] in self?.runFlow42(["play", "next-step"]) },
            onPrevStep: { [weak self] in self?.runFlow42(["play", "prev-step"]) },
            onPrimaryAction: { [weak self] in self?.hideFloating() },
            onStop: { [weak self] in self?.runFlow42(["stop"]) },
            chatSession: chatSession
        )
    }

    /// Resolve the chat session to bind. We prefer the active-chat
    /// marker (the runner is alive) and fall back to the most recent
    /// session for the active play's flow dir. Both fail = nil = the
    /// chat surface goes empty.
    private func rebindChatSession(for state: AppState) {
        // First, did Flow42App write a live marker?
        if let pointer = ActiveChatSessionMarker.read(),
           let session = ChatSession.load(directory: pointer.directory) {
            if chatSession.client?.session.id == session.id { return }
            chatSession.set(SessionClient(session: session))
            return
        }
        // No live marker — fall back to the play-bound history (so
        // resuming an old play still shows its transcript).
        if let play = state.play {
            let session = ChatSession.list(ownerDir: play.flowDir).first
            if let session, chatSession.client?.session.id == session.id { return }
            chatSession.set(session.map { SessionClient(session: $0) })
            return
        }
        chatSession.set(nil)
    }

    // MARK: - Chat marker FSEvents

    private func attachChatMarkerWatcher() {
        attachChatMarkerFileWatcher()
        attachChatMarkerDirWatcher()
    }

    private func attachChatMarkerFileWatcher() {
        let path = ActiveChatSessionMarker.path()
        guard FileManager.default.fileExists(atPath: path) else { return }
        let fd = open(path, O_EVTONLY)
        if fd < 0 { return }
        chatMarkerFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) {
                source.cancel()
                self.chatMarkerSource = nil
                if self.chatMarkerFD >= 0 { close(self.chatMarkerFD); self.chatMarkerFD = -1 }
                // Marker gone → re-apply with no live session.
                self.apply(state: self.stateClient.state, animated: true)
            } else {
                self.apply(state: self.stateClient.state, animated: true)
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.chatMarkerFD >= 0 { close(self.chatMarkerFD); self.chatMarkerFD = -1 }
        }
        source.resume()
        chatMarkerSource = source
    }

    private func attachChatMarkerDirWatcher() {
        let dir = (ActiveChatSessionMarker.path() as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let fd = open(dir, O_EVTONLY)
        if fd < 0 { return }
        chatMarkerDirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Marker may have just been (re-)created. Re-arm the
            // file watcher and re-apply.
            if self.chatMarkerSource == nil,
               FileManager.default.fileExists(atPath: ActiveChatSessionMarker.path()) {
                self.attachChatMarkerFileWatcher()
            }
            self.apply(state: self.stateClient.state, animated: true)
        }
        source.resume()
        chatMarkerDirSource = source
    }

    /// Build a PlayPanelView for chat-only mode (live chat session,
    /// no play yet — the agent is collecting params before driving).
    /// All transport closures are no-ops here; the panel renders the
    /// chat body and the session's input pipe handles user replies.
    private func makeChatOnlyView() -> PlayPanelView {
        return PlayPanelView(
            state: stateClient.state,
            intent: "",
            stepText: "",
            stepScreenshotPath: nil,
            params: [:],
            style: .floating,
            onPause: {},
            onResume: {},
            onResumeAndAdvance: {},
            onNextStep: {},
            onPrevStep: {},
            onPrimaryAction: { [weak self] in self?.hideFloating() },
            onStop: { [weak self] in
                // Abort path for chat-only mode: write a `.stop` line
                // to the active session's input pipe — Flow42App's
                // AutonomousRunner sees it, terminates the ACP
                // subprocess, clears the marker.
                guard let session = self?.chatSession.client?.session else { return }
                let stopLine = AgentInputLine(kind: .stop, text: "")
                try? SessionInputLog.append(stopLine, to: session)
            },
            chatSession: chatSession
        )
    }

    private func makeRecordingView(state: AppState, recording: RecordingInfo) -> RecordingPanelView {
        currentContent = .recording(RecordingContent(slug: recording.slug))
        // Cache the recording info BEFORE shelling out: `flow42 stop`
        // is fire-and-forget and the daemon finalises in the
        // background. We need dir + slug to fire the post-record
        // deep link once the daemon writes meta.yaml.
        let cachedDir = recording.dir
        let cachedSlug = recording.slug
        return RecordingPanelView(
            recording: recording,
            model: timelineModel,    // shared event-tail; updates live
            style: .floating,
            onPrimaryAction: { [weak self] in self?.hideFloating() },
            onStop: { [weak self] in
                self?.runFlow42(["stop"])
                self?.handOffRecordingAfterFinalize(
                    dir: cachedDir, slug: cachedSlug
                )
            }
        )
    }

    /// Wait for the recorder daemon to write `meta.yaml` (i.e. finish
    /// finalising) then fire the post-record deep link so Flow42App's
    /// RecordingHandoffView can spin up the flow-creator chat. We poll
    /// in a detached task — the floating panel's Stop closure is on
    /// the main actor and shouldn't block. `flow42 stop` is async
    /// fire-and-forget; the daemon does whisper transcription + event
    /// finalisation which can take 1–60s, so we retry for ~90s.
    nonisolated private func handOffRecordingAfterFinalize(dir: String, slug: String) {
        FileHandle.standardError.write(Data(
            "[Flow42Menu] handoff: starting poll for meta.yaml in \(dir)\n".utf8
        ))
        Task.detached {
            let metaPath = (dir as NSString).appendingPathComponent("meta.yaml")
            let warningPath = (dir as NSString).appendingPathComponent("recorder-warning.json")
            let deadline = Date().addingTimeInterval(90)
            var pollCount = 0
            while Date() < deadline {
                pollCount += 1
                if FileManager.default.fileExists(atPath: metaPath) {
                    FileHandle.standardError.write(Data(
                        "[Flow42Menu] handoff: meta.yaml landed after \(pollCount) polls — posting deep link\n".utf8
                    ))
                    Flow42DeepLink.postOpenRecording(dir: dir, slug: slug)
                    await Self.bringFlow42AppForwardForRecording(dir: dir, slug: slug)
                    return
                }
                if FileManager.default.fileExists(atPath: warningPath) {
                    // Recorder reported a fatal error; surface in
                    // stderr but don't try to launch the handoff —
                    // there's no usable recording to structure.
                    FileHandle.standardError.write(Data(
                        "[Flow42Menu] handoff: aborted — recorder-warning.json present in \(dir)\n".utf8
                    ))
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }
            FileHandle.standardError.write(Data(
                "[Flow42Menu] handoff: timed out after 90s waiting for meta.yaml in \(dir)\n".utf8
            ))
        }
    }

    /// Activate Flow42App if running, else spawn it. Re-posts the
    /// recording deep link after a grace window so the freshly-
    /// launched app's observer is subscribed in time.
    nonisolated private static func bringFlow42AppForwardForRecording(dir: String, slug: String) async {
        let runningApps = await MainActor.run { NSWorkspace.shared.runningApplications }
        let alreadyUp = runningApps.contains { app in
            app.localizedName == "Flow42App" || app.bundleIdentifier?.contains("flow42") == true
        }
        if alreadyUp {
            await MainActor.run {
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName == "Flow42App"
                }) {
                    app.activate()
                }
            }
            return
        }
        guard let binary = Self.resolveFlow42AppBinary() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        try? task.run()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        Flow42DeepLink.postOpenRecording(dir: dir, slug: slug)
    }

    /// Locate Flow42App next to the running menu binary. Mirrors the
    /// search pattern used elsewhere in Flow42Menu for the CLI binary.
    nonisolated private static func resolveFlow42AppBinary() -> String? {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            for variant in ["debug", "release"] {
                let cand = dir
                    .appendingPathComponent(".build")
                    .appendingPathComponent(variant)
                    .appendingPathComponent("Flow42App")
                    .path
                if fm.isExecutableFile(atPath: cand) { return cand }
            }
            let sibling = dir.appendingPathComponent("Flow42App").path
            if fm.isExecutableFile(atPath: sibling) { return sibling }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // (Chat-only mode for the floating panel was removed — autonomous
    // chat now lives in Flow42App's main window. The PlayPanelView's
    // `isChatOnlyMode` branch is unreachable from this controller; it
    // stays in PlayPanelView for now as dead code we'll prune in a
    // follow-up.)

    // MARK: - Hide

    private func hide(animated: Bool) {
        guard window.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.window.orderOut(nil) }
            }
        } else {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    // MARK: - Phase resolution

    private func resolvePhase(for play: PlayInfo) -> PhaseCache {
        let key = "\(play.id):\(play.position.phaseIndex)"
        if let cached = phaseCache, cached.key == key { return cached }

        // Read flow.yaml. On any failure, fall back to an empty cache so
        // the view degrades gracefully (it shows the position + an empty
        // intent + a "missing screenshot" placeholder).
        let phase: PhaseReader.Phase
        let params: [String: String]
        do {
            let result = try PhaseReader.phaseAt(
                flowDir: play.flowDir,
                index: play.position.phaseIndex,
                stepIndex: play.position.stepIndex
            )
            phase = result.phase
            params = result.params
        } catch {
            let empty = PhaseCache(
                key: key, intent: "", params: [:],
                stepTexts: [], stepScreenshots: []
            )
            phaseCache = empty
            return empty
        }

        // Pull the GUI path's steps. A non-gui-only phase (no gui block)
        // gets one synthetic step described by the phase intent.
        var stepTexts: [String] = []
        var stepShots: [String?] = []
        if let gui = phase.paths.first(where: { ($0["kind"] as? String) == "gui" }),
           let steps = gui["steps"] as? [[String: Any]] {
            for step in steps {
                let raw = (step["text"] as? String) ?? ""
                // Show only the first line on the panel — the rest is
                // brittleness guidance, lives in `flow42 view`.
                let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
                stepTexts.append(firstLine)

                if let rel = step["screenshot"] as? String, !rel.isEmpty {
                    let abs = (play.flowDir as NSString).appendingPathComponent(rel)
                    stepShots.append(abs)
                } else {
                    stepShots.append(nil)
                }
            }
        }

        let cache = PhaseCache(
            key: key,
            intent: phase.intent,
            params: params,
            stepTexts: stepTexts,
            stepScreenshots: stepShots
        )
        phaseCache = cache
        return cache
    }

    // MARK: - Shell-out

    private func runFlow42(_ args: [String]) {
        guard let path = Flow42CLI.binaryPath() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    /// Run multiple flow42 invocations one-after-another off the main
    /// thread, waiting for each to exit before starting the next.
    /// Concurrent invocations race on `~/.flow42/state.json` (last writer
    /// wins, so the earlier mutation gets clobbered) — use this whenever
    /// the second command depends on the first having committed.
    nonisolated private func runFlow42Sequence(_ commands: [[String]]) {
        guard let path = Flow42CLI.binaryPath() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for args in commands {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = args
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Screen change

    @objc private func screensChanged() {
        // Display config changed (monitor plugged/unplugged, resolution
        // change, etc). The user's previous position may now be off-screen,
        // so re-anchor to the default for safety.
        let intrinsic = hostingView?.fittingSize.height ?? 480
        let height = max(360, min(intrinsic, 700))
        window.anchorDefault(toHeight: height)
    }
}
