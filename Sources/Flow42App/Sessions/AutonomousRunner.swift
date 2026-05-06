// AutonomousRunner.swift - Orchestrate "Run autonomously" end-to-end.
//
// The user clicks Run autonomously and the rest happens invisibly:
//
//   1. Confirm a provider is configured (deep-link to Settings if not).
//   2. Confirm baseline skills are installed; if not, run `flow42 install-skills`.
//   3. Materialise the per-flow skill at `~/.claude/skills/flow-<slug>/`
//      (lazily — only writes if missing).
//   4. Shell out `flow42 play <dir> --by <provider-id>` — writes
//      state.json so the menu app's overlays appear.
//   5. Spawn `claude --print --output-format stream-json …` as a
//      managed subprocess. NO terminal, NO TUI. The agent's stream-json
//      output is parsed into TranscriptEvents and rendered in our window.
//   6. Pipe the agent's prompt: "Run the flow-<slug> flow." That's it —
//      the skill resolver picks up the per-flow skill, the baseline
//      flow42-cli skill teaches the canonical play loop, and the agent
//      drives the flow from there.
//
// State is published so SwiftUI binds directly: transcript appears live,
// status flips to .completed when the agent exits, Stop wires through
// to both `flow42 stop` and the subprocess.

import AppKit
import Combine
import Flow42Core
import Foundation

@MainActor
final class AutonomousRunner: ObservableObject {

    enum Status: Equatable {
        case idle
        case starting
        case running(playId: String)
        case completed(playId: String)
        case failed(error: String)
        case cancelled
    }

    enum LaunchError: Error, CustomStringConvertible, Equatable {
        case noProviderSelected
        case anotherSessionActive(detail: String)
        case skillInstallFailed(detail: String)
        case playStartFailed(detail: String)
        case agentSpawnFailed(detail: String)

        var description: String {
            switch self {
            case .noProviderSelected:
                return "No AI provider is selected. Open Settings to pick one."
            case .anotherSessionActive(let d):
                return "Another flow42 session is already active. \(d)"
            case .skillInstallFailed(let d):
                return "Couldn't install the per-flow skill: \(d)"
            case .playStartFailed(let d):
                return "Couldn't start the play: \(d)"
            case .agentSpawnFailed(let d):
                return "Couldn't start the agent subprocess: \(d)"
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var status: Status = .idle
    @Published private(set) var transcript: [TranscriptEvent] = []
    @Published private(set) var activeFlow: FlowSummary?
    /// The chat session this runner is currently driving (if any).
    /// Each `start*` call creates a fresh session under
    /// `<ownerDir>/chat/sessions/<id>/`; consumers that want to
    /// observe the live transcript build a `SessionClient` on top.
    @Published private(set) var activeSession: ChatSession?

    // MARK: - Internals

    private var client: ACPClient?
    private var streamTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?

    /// Watches state.json so we can react to user pause/resume that
    /// happen via the floating panel. Created on demand the first time
    /// `start()` runs; lives for the runner's whole lifetime.
    private var stateClient: StateClient?
    private var stateSubscription: AnyCancellable?

    /// Watches `~/.flow42/agent-input.jsonl` and forwards new lines as
    /// follow-up prompts to the ACP session — that's how the menu
    /// app's chat input field lands user messages on the agent.
    private var inputClient: AgentInputClient?

    /// The state.json snapshot we observed last tick. Used to detect
    /// transitions (driving → paused, paused → driving) rather than
    /// reacting on every change.
    private var lastObservedDerivedState: DerivedState = .idle

    /// True while we're shutting down on user-initiated Stop. Prevents
    /// the state observer from interpreting the play disappearing as
    /// "the agent finished naturally".
    private var isStopping: Bool = false

    // MARK: - Public API

    /// Kick off a chat session against a fresh recording (no flow.yaml
    /// yet). The agent runs the flow-creator skill on the directory so
    /// the user gets the structuring chat the moment they hit Stop in
    /// the menu. Same connection / transcript / pause-resume wiring as
    /// `start(flow:provider:)`; only the initial prompt and the
    /// "no flow.yaml yet" pre-flight differ.
    func startForRecording(
        dir: String,
        slug: String,
        provider: ProviderDefinition?
    ) throws {
        guard let provider else {
            throw LaunchError.noProviderSelected
        }
        cancelCurrentSubprocessIfAny()
        transcript = []
        activeFlow = nil  // no FlowSummary exists yet; chat surface
                          // renders its own header from `dir` + `slug`.
        status = .starting

        let state = StateFile.read()
        // A live recording at this point is unexpected (we only ever
        // hit this entry AFTER `record stop` returns). Bail loudly if
        // somehow the lock is still held so we don't double-spawn an
        // agent that fights the recorder daemon.
        if let recording = state.recording {
            status = .failed(error: "Recording '\(recording.slug)' is still active.")
            throw LaunchError.anotherSessionActive(
                detail: "Recording '\(recording.slug)' is still active."
            )
        }
        if let play = state.play {
            status = .failed(error: "Play '\(play.id)' is already active.")
            throw LaunchError.anotherSessionActive(
                detail: "Play '\(play.id)' is already active."
            )
        }

        // Baseline skills include flow-creator + flow-recorder + the
        // CLI reference. The per-flow skill is intentionally skipped —
        // there's no flow.yaml to template against yet.
        ensureBaselineSkills()

        // Reconcile any stale `.active` session on this recording (a
        // previous run that didn't get a clean stop) and end the
        // most-recent active one before creating a fresh session.
        if let stale = ChatSession.reconcileAndFindActive(ownerDir: dir) {
            _ = try? stale.markEnded()
        }
        let session: ChatSession
        do {
            session = try ChatSession.create(ownerDir: dir, provider: provider.id)
        } catch {
            status = .failed(error: "couldn't create chat session: \(error)")
            throw LaunchError.agentSpawnFailed(detail: "\(error)")
        }
        activeSession = session

        let prompt = """
        I just captured a recording at \(dir). The slug is "\(slug)". \
        Run the flow-creator skill to structure it: orient yourself \
        first by reading events.jsonl + the steps/ folder (no \
        flow.yaml yet — your job is to write the first one), then \
        ask me any clarifying questions before Pass 1. We are in a \
        chat — keep me in the loop and don't ship until I'm happy.
        """

        runChatSession(
            provider: provider,
            session: session,
            workingDirectory: dir,
            prompt: prompt
        )
    }

    /// Kick off an autonomous run for `flow`. Throws synchronously on
    /// pre-flight failures (no provider, conflicting session, …); for
    /// runtime failures observe `status` and `transcript`.
    func start(flow: FlowSummary, provider: ProviderDefinition?) throws {
        // Reset state for a fresh run.
        guard let provider else {
            throw LaunchError.noProviderSelected
        }
        cancelCurrentSubprocessIfAny()
        transcript = []
        activeFlow = flow
        status = .starting

        // Singleton check — refuse if a recording or another play is
        // already active. (We no longer pre-start a play here; that's
        // the agent's job once it has the user's params. So the only
        // conflict at this stage is something else holding the lock.)
        let state = StateFile.read()
        if let recording = state.recording {
            status = .failed(error: "Recording '\(recording.slug)' is in progress.")
            throw LaunchError.anotherSessionActive(
                detail: "Recording '\(recording.slug)' is in progress."
            )
        }
        if let play = state.play {
            status = .failed(error: "Play '\(play.id)' is already active.")
            throw LaunchError.anotherSessionActive(
                detail: "Play '\(play.id)' is already active."
            )
        }

        // Skill injection — baseline (best-effort) + per-flow (required).
        ensureBaselineSkills()
        let skillName: String
        do {
            // Overwrite every run so we always pick up renderer + skill-
            // template changes (cheap — the file is small and the
            // content is deterministic, no user edits to preserve).
            try PerFlowSkillWriter.install(flow: flow, overwrite: true)
            skillName = PerFlowSkillWriter.skillName(forFlowSlug: flow.id)
        } catch {
            status = .failed(error: "skill install failed: \(error)")
            throw LaunchError.skillInstallFailed(detail: "\(error)")
        }

        // End any stale active session for this flow and create a
        // fresh per-(flow, provider) session so the chat history
        // doesn't bleed between runs.
        if let stale = ChatSession.reconcileAndFindActive(ownerDir: flow.directory) {
            _ = try? stale.markEnded()
        }
        let session: ChatSession
        do {
            session = try ChatSession.create(
                ownerDir: flow.directory, provider: provider.id
            )
        } catch {
            status = .failed(error: "couldn't create chat session: \(error)")
            throw LaunchError.agentSpawnFailed(detail: "\(error)")
        }
        activeSession = session

        // Spawn the ACP adapter. The prompt explicitly tells the agent
        // it's in a chat with the user — so the skill's "ask for
        // params via chat first" branch fires (vs. the standalone-use
        // branch where the agent might just be answering questions
        // about the flow). We also tell the agent to start the play
        // ITSELF after collecting params; we don't pre-start it.
        let prompt = """
        Run the \(skillName) skill. The user is in a chat with you — \
        collect any required parameters from them via chat first, \
        then start the play and execute.
        """
        runChatSession(
            provider: provider,
            session: session,
            workingDirectory: flow.directory,
            prompt: prompt
        )
    }

    /// Shared connection lifecycle for both `start` and
    /// `startForRecording`. Owns the ACP client, transcript drain
    /// task, prompt task, state observer, and chat-input pipe so the
    /// chat surface looks identical regardless of which entry kicked
    /// it off.
    private func runChatSession(
        provider: ProviderDefinition,
        session: ChatSession,
        workingDirectory: String,
        prompt: String
    ) {
        // Publish a cross-process pointer so Flow42Menu's floating
        // panel can find this session and host the chat surface in
        // ITS window (we only have one floating window globally;
        // the runner doesn't host its own UI).
        try? ActiveChatSessionMarker.write(ActiveChatSessionPointer(
            directory: session.directory,
            ownerDir: session.ownerDir,
            provider: session.provider
        ))

        let acp = ACPClient()
        self.client = acp
        // No playId yet; transitions to .running with the real id once
        // the agent calls `flow42 play <flow-dir>` and state.json
        // gets a play. The status observer downstream watches for that.

        // Drain the ACP event stream into our transcript AND publish
        // to the session's per-recording files. Publish playId is
        // read live from state.json — during chat-only mode it's
        // nil; once the agent starts the play it becomes the new id.
        let eventStream = acp.events
        let capturedSession = session
        streamTask = Task { @MainActor [weak self] in
            for await event in eventStream {
                guard let self else { return }
                self.transcript.append(event)
                let currentPlayId = StateFile.read().play?.id
                self.publish(event: event, playId: currentPlayId, session: capturedSession)
                if case .finalResult = event.kind, let id = currentPlayId {
                    self.status = .completed(playId: id)
                }
            }
            if let self {
                if case .running(let id) = self.status {
                    self.status = .cancelled
                    _ = id
                } else if case .starting = self.status {
                    self.status = .cancelled
                }
            }
        }

        // Open the ACP session ONCE, then send the initial prompt. Any
        // follow-up prompts (e.g. "Continue." after a pause/resume,
        // or user typing in the chat input) reuse the same session —
        // the agent SDK keeps conversation history server-side so we
        // don't re-explain the task on every turn.
        promptTask = Task { @MainActor [weak self, provider, workingDirectory, prompt] in
            do {
                try await acp.connect(
                    provider: provider,
                    workingDirectory: workingDirectory
                )
                try await acp.sendUserPrompt(prompt)
            } catch {
                self?.status = .failed(error: "\(error)")
            }
        }

        // State observer — handles user pause/resume from the floating
        // panel by cancelling / re-prompting the agent. Also flips
        // .starting → .running once we see state.play populated.
        attachStateObserverIfNeeded()
        // Seed at .idle since no play exists yet; the observer will
        // notice the first non-idle transition.
        lastObservedDerivedState = .idle

        // Wire the chat input pipe — every line the chat surface
        // appends to this session's `input.jsonl` gets forwarded to
        // the agent as a follow-up prompt.
        attachInputClient(session: session)
    }

    /// Set up the chat→agent input forwarder for this session. Each
    /// line written to the session's input.jsonl becomes either a
    /// `sendUserPrompt` call (.prompt) or a clean shutdown (.stop).
    private func attachInputClient(session: ChatSession) {
        inputClient = AgentInputClient(session: session) { [weak self] line in
            guard let self else { return }
            switch line.kind {
            case .prompt:
                guard let client = self.client else { return }
                // Forward asynchronously so the input client's
                // synchronous handler returns immediately.
                let capturedSession = session
                Task { @MainActor in
                    do {
                        try await client.sendUserPrompt(line.text)
                    } catch {
                        // Non-fatal: surface to the transcript so the
                        // user sees their message wasn't delivered.
                        self.publish(
                            event: TranscriptEvent(kind: .error(
                                "Couldn't deliver your message: \(error)"
                            )),
                            playId: StateFile.read().play?.id,
                            session: capturedSession
                        )
                    }
                }

            case .stop:
                // User-initiated abort from the chat. Tear down the
                // agent subprocess; the session metadata gets marked
                // ended in `stop()`.
                self.stop()
            }
        }
    }

    /// User clicked Stop (or navigated away). Kill the agent + end
    /// the play + mark the session ended on disk.
    func stop() {
        isStopping = true
        cancelCurrentSubprocessIfAny()
        // End the play even if the agent exited cleanly — the agent
        // calls `flow42 play end` itself on success, but if the user
        // stops mid-run we have to do it.
        _ = runFlow42(args: ["stop"])
        if case .running(let id) = status {
            status = .cancelled
            _ = id
        }
        // Persist the session as `.ended` so the on-disk truth
        // matches "this conversation is over". Reading the recording
        // again will surface this as an archived transcript.
        if let session = activeSession {
            _ = try? session.markEnded()
        }
        activeSession = nil
        // Drop the cross-process pointer so the floating panel
        // hides its chat surface.
        ActiveChatSessionMarker.clear()
        isStopping = false
    }

    // MARK: - State observation (user pause/resume → agent control)

    /// Attach the state observer once. We instantiate StateClient lazily
    /// so the runner stays cheap until a run actually starts; once
    /// attached the subscription lives for the runner's whole lifetime.
    private func attachStateObserverIfNeeded() {
        if stateSubscription != nil { return }
        let client = stateClient ?? StateClient()
        stateClient = client
        stateSubscription = client.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleStateTransition(state.derivedState)
            }
    }

    /// React to the floating panel's pause/resume by actually steering
    /// the agent:
    ///
    ///   driving  → watching/recording  : pause — cancel the in-flight
    ///                                    turn so the agent stops mid-
    ///                                    action. Session stays alive.
    ///   watching → driving             : resume — send a follow-up
    ///                                    prompt so the agent picks up
    ///                                    from where it left off.
    ///
    /// Idle while we're shutting down on Stop is ignored — `stop()`
    /// already torn the client down and we don't want to interpret the
    /// play disappearing as "agent completed".
    private func handleStateTransition(_ next: DerivedState) {
        defer { lastObservedDerivedState = next }
        guard !isStopping else { return }
        // Only meaningful while we have a live agent session.
        guard let client = self.client else { return }
        let prev = lastObservedDerivedState
        if next == prev { return }

        // .idle → .driving = the agent just successfully called
        // `flow42 play <flow-dir>`. This is the chat-only → compact
        // transition the floating panel renders. Flip our own status
        // from .starting to .running with the freshly-assigned playId.
        if prev == .idle, next == .driving,
           let playId = StateFile.read().play?.id {
            status = .running(playId: playId)
        }

        switch (prev, next) {
        case (.driving, .watching):
            // User clicked Pause in the floating panel (or the agent
            // paused itself via `flow42 play pause`). Halt the in-flight
            // turn — the agent finishes whatever tool call it was on
            // and stops emitting further actions.
            client.cancelInFlight()

        case (.watching, .driving):
            // User clicked Resume / "Yes, let's move on". Send a
            // follow-up prompt to nudge the agent back into the loop.
            // The agent SDK keeps conversation history server-side so
            // we don't need to re-explain the task — just tell it to
            // pick up from current state.
            sendContinuePrompt()

        default:
            break
        }
    }

    private func sendContinuePrompt() {
        guard let client else { return }
        // Cancel any still-running prompt task before launching a new
        // one — we want to be the only one driving the conversation.
        promptTask?.cancel()
        promptTask = Task { @MainActor [weak self] in
            do {
                try await client.sendUserPrompt(
                    "Continue from where you left off. The user has resumed the play — call `flow42 play current` to refresh on where the play position is now and proceed."
                )
            } catch {
                self?.status = .failed(error: "\(error)")
            }
        }
    }

    // MARK: - Subprocess lifecycle

    private func cancelCurrentSubprocessIfAny() {
        client?.terminate()
        client = nil
        promptTask?.cancel()
        promptTask = nil
        streamTask?.cancel()
        streamTask = nil
        // Drop the chat-input forwarder so the next run sees a fresh
        // dedupe set (and isn't fed stale lines if the user typed
        // something just before the previous run died).
        inputClient = nil
    }

    // MARK: - Cross-process publication

    /// Push the event into the session's `latest.json` (single-record,
    /// FSEvents-watched by SessionClient) and append to its
    /// `transcript.jsonl` (full append-only log). Per-session pipes
    /// mean two recordings' chats can never overwrite each other.
    /// Failing to publish should never crash the run.
    private func publish(
        event: TranscriptEvent,
        playId: String?,
        session: ChatSession
    ) {
        try? SessionLatestFile.write(
            AgentLatestSnapshot(playId: playId, event: event),
            to: session
        )
        try? SessionTranscriptLog.append(event, to: session)
    }

    // MARK: - Baseline skills

    private func ensureBaselineSkills() {
        let manifest = Flow42Paths.root() + "/installed-skills.json"
        if FileManager.default.fileExists(atPath: manifest) { return }
        _ = runFlow42(args: ["install-skills"])
    }

    // MARK: - Play start

    private func startPlay(flow: FlowSummary, providerId: String) throws -> String {
        guard let cli = Flow42CLI.binaryPath() else {
            throw NSError(
                domain: "AutonomousRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not locate flow42 binary"]
            )
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cli)
        task.arguments = [
            "play", flow.directory,
            "--by", providerId,
            "--label", flow.displayName,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        try task.run()
        task.waitUntilExit()
        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        if task.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8)
                ?? String(data: outData, encoding: .utf8)
                ?? "unknown error"
            throw NSError(
                domain: "AutonomousRunner", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        if let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
           let id = json["play_id"] as? String {
            return id
        }
        return StateFile.read().play?.id ?? "unknown"
    }

    @discardableResult
    private func runFlow42(args: [String]) -> Bool {
        guard let cli = Flow42CLI.binaryPath() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cli)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
