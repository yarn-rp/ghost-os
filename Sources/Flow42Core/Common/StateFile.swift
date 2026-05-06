// StateFile.swift - Shared `~/.flow42/state.json` reader/writer.
//
// Single source of truth for "what is flow42 doing right now?". The CLI
// writes; the menu app reads.
//
// Singleton invariant: at most ONE session (recording OR play) is active
// at any time. Both null = idle. Mutually exclusive — the writer enforces
// this; readers can rely on it.
//
// The top-level `derivedState` property collapses the (recording? play?
// play.state? play.pause?) tuple into one of {idle, recording, driving,
// watching} — that's what the menu app's edge glow + floating window
// branch on.
//
// Writes are atomic (write-to-temp + rename) so a reader never sees a
// half-written file. Schema is versioned for future drift detection.

import Foundation

// MARK: - Derived state (the four "colours")

/// Collapsed runtime state. Computed from `AppState`; this is what the menu
/// app's overlays render against.
public enum DerivedState: String, Sendable {
    case idle
    case recording      // magenta glow
    case driving        // orange glow + pill + cursor companion + floating window
    case watching       // cyan glow + floating window (user-initiated OR agent-paused)
}

// MARK: - Recording session payload

/// Active recording session — `flow42 record start` daemon is alive.
public struct RecordingInfo: Sendable, Codable, Equatable {
    public let slug: String
    public let dir: String
    public let pid: Int

    public init(slug: String, dir: String, pid: Int) {
        self.slug = slug
        self.dir = dir
        self.pid = pid
    }

    /// True iff the recorder daemon process is still alive.
    public func isAlive() -> Bool {
        pid > 0 && kill(pid_t(pid), 0) == 0
    }
}

// MARK: - Play session payload

/// Active play session — agent (or user, via watching) is executing a flow.
public struct PlayInfo: Sendable, Codable, Equatable {

    /// Driving = agent in control; watching = user in control.
    public enum State: String, Sendable, Codable {
        case driving
        case watching
    }

    /// Position cursor inside the flow. Mirrors `flow.yaml`'s phase array.
    public struct Position: Sendable, Codable, Equatable {
        public let phaseIndex: Int
        public let phaseName: String
        public let stepIndex: Int
        public let totalPhases: Int
        public let totalStepsInPhase: Int

        public init(
            phaseIndex: Int, phaseName: String,
            stepIndex: Int,
            totalPhases: Int, totalStepsInPhase: Int
        ) {
            self.phaseIndex = phaseIndex
            self.phaseName = phaseName
            self.stepIndex = stepIndex
            self.totalPhases = totalPhases
            self.totalStepsInPhase = totalStepsInPhase
        }

        enum CodingKeys: String, CodingKey {
            case phaseIndex = "phase_index"
            case phaseName = "phase_name"
            case stepIndex = "step_index"
            case totalPhases = "total_phases"
            case totalStepsInPhase = "total_steps_in_phase"
        }
    }

    /// Set when the play is paused (agent-paused = the agent asked for help;
    /// user-initiated watching uses `state == .watching` with `pause == nil`).
    public struct PauseInfo: Sendable, Codable, Equatable {
        public enum PausedBy: String, Sendable, Codable {
            case agent
            case user
        }
        public let reason: String
        public let pausedAt: String      // ISO 8601
        public let pausedBy: PausedBy

        public init(reason: String, pausedAt: String, pausedBy: PausedBy) {
            self.reason = reason
            self.pausedAt = pausedAt
            self.pausedBy = pausedBy
        }

        enum CodingKeys: String, CodingKey {
            case reason
            case pausedAt = "paused_at"
            case pausedBy = "paused_by"
        }
    }

    public let id: String
    public let flowDir: String
    public let flowName: String
    public let state: State
    public let startedBy: String
    public let label: String?
    public let pid: Int
    public let position: Position
    public let pause: PauseInfo?

    public init(
        id: String, flowDir: String, flowName: String,
        state: State, startedBy: String, label: String?,
        pid: Int, position: Position, pause: PauseInfo? = nil
    ) {
        self.id = id
        self.flowDir = flowDir
        self.flowName = flowName
        self.state = state
        self.startedBy = startedBy
        self.label = label
        self.pid = pid
        self.position = position
        self.pause = pause
    }

    /// True iff the agent process that opened this play is still alive.
    public func isAlive() -> Bool {
        pid > 0 && kill(pid_t(pid), 0) == 0
    }

    enum CodingKeys: String, CodingKey {
        case id
        case flowDir = "flow_dir"
        case flowName = "flow_name"
        case state
        case startedBy = "started_by"
        case label
        case pid
        case position
        case pause
    }
}

// MARK: - Top-level state

public struct AppState: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let since: String                 // ISO 8601
    public let recording: RecordingInfo?
    public let play: PlayInfo?

    public init(
        recording: RecordingInfo? = nil,
        play: PlayInfo? = nil,
        at date: Date = Date()
    ) {
        self.schemaVersion = 2
        self.since = ISO8601DateFormatter().string(from: date)
        self.recording = recording
        self.play = play
    }

    /// The collapsed state the menu app's overlays branch on.
    public var derivedState: DerivedState {
        if recording != nil { return .recording }
        guard let play else { return .idle }
        // A paused driving play renders as watching (user has the screen).
        if play.pause != nil { return .watching }
        switch play.state {
        case .driving:  return .driving
        case .watching: return .watching
        }
    }

    /// Convenience: are we doing anything at all?
    public var isIdle: Bool { recording == nil && play == nil }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case since
        case recording
        case play
    }
}

// MARK: - Reader / writer

public enum StateFile {

    /// Path to the state file. Public so the menu app can watch it via
    /// FSEvents.
    public static func path() -> String {
        Flow42Paths.stateFile()
    }

    /// Read the current state. Returns idle when the file is missing or
    /// unparseable — absence is the canonical "nothing happening" signal.
    ///
    /// Stale entries (recording with a dead pid) are filtered from the
    /// returned value but NOT persisted back to disk by `read`. The
    /// dedicated `reconcile()` entry point is the only writer of
    /// sanitized state — that keeps menu / app readers strictly
    /// observers and prevents a reader's pid-liveness check from
    /// racing with a daemon mid-write.
    public static func read() -> AppState {
        sanitize(readRaw())
    }

    /// Raw read with no liveness sweep. Used by the sanitizer itself
    /// and by tools that genuinely want to see what's on disk (debug,
    /// `flow42 status` if we ever want to flag stale entries
    /// explicitly).
    public static func readRaw() -> AppState {
        let p = path()
        guard FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else {
            return AppState()
        }
        return state
    }

    /// Drop any session whose owning process is gone. Called from
    /// `read()` so every consumer (menu app, CLI gates, Flow42App on
    /// launch) sees a self-healing view of the world.
    ///
    /// Only `recording` has a long-lived owning daemon to liveness-
    /// check — plays are driven by short-lived CLI invocations and
    /// have no persistent pid, so a stale play entry stays put until
    /// `flow42 stop` / `flow42 play end` clears it explicitly.
    ///
    /// Two-strikes rule: a single `kill(pid, 0)` failure isn't enough
    /// to declare the recorder dead. `execve` (which the daemon uses
    /// for TCC re-keying) reuses the same pid but has a tiny window
    /// where the process table briefly shows ESRCH. We re-check after
    /// 100ms; only if BOTH checks fail do we drop. Bogus pids
    /// (`pid <= 0`) skip the wait and drop immediately.
    private static func sanitize(_ state: AppState) -> AppState {
        guard let r = state.recording else { return state }
        if r.pid <= 0 {
            return AppState(recording: nil, play: state.play)
        }
        if r.isAlive() { return state }
        // First strike — wait briefly and re-check before condemning.
        Thread.sleep(forTimeInterval: 0.1)
        if r.isAlive() { return state }
        return AppState(recording: nil, play: state.play)
    }

    /// Atomically write a new state. Returns bytes written, or throws on I/O
    /// failure. Never partially writes.
    ///
    /// Refuses to persist a recording entry whose owning daemon pid is
    /// already dead — that's the canonical "stale state" pattern that
    /// caused phantom recording-mode renders. The caller almost
    /// certainly meant to write the daemon's own pid (which is
    /// guaranteed alive at write time), so a dead-pid write here is a
    /// bug we'd rather throw than silently persist.
    @discardableResult
    public static func write(_ state: AppState) throws -> Int {
        var sanitized = state
        if let r = sanitized.recording, !r.isAlive() {
            // Drop the dead recording but preserve any other fields.
            sanitized = AppState(recording: nil, play: sanitized.play)
        }
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sanitized)

        let tmpPath = p + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        // POSIX rename is atomic on the same filesystem.
        if rename(tmpPath, p) != 0 {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw NSError(
                domain: "Flow42StateFile",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(errno)))"]
            )
        }
        return data.count
    }

    /// Revert to idle. No-op if already idle.
    public static func clearToIdle() throws {
        try write(AppState())
    }

    /// Force-sweep stale entries and persist the cleaned result, even
    /// when nothing changed (so the on-disk file is always considered
    /// canonical after this call). Long-lived processes (Flow42App,
    /// Flow42Menu) call this in `applicationDidFinishLaunching` BEFORE
    /// any UI mounts, so the first frame can never paint a phantom
    /// recording from a prior crash. Cheap and idempotent.
    public static func reconcile() {
        let raw = readRaw()
        let sanitized = sanitize(raw)
        if sanitized != raw {
            try? write(sanitized)
        }
    }

    /// Convert the current state to a `[String: Any]` dictionary, suitable
    /// for `flow42 status` and other JSON-emitting commands.
    public static func readAsDict() -> [String: Any] {
        let state = read()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return ["schema_version": 2]
        }
        return dict
    }

    // MARK: - Singleton invariant guards

    /// Returns nil if the requested transition is allowed; returns a human-
    /// readable error string if there's already an active session of any
    /// kind. Used by `flow42 record start` and `flow42 play start` before
    /// writing.
    ///
    /// We do NOT check pid liveness here — `flow42` CLI invocations are
    /// ephemeral processes (each call dies immediately after writing state),
    /// so the stored pid is generally already dead by the time the next call
    /// reads it. The truth is "is state.play / state.recording present?"
    /// If a session got stuck, `flow42 stop` is the explicit recovery.
    /// (Liveness-based auto-clear lives in the menu app, which has a long-
    /// lived process and can sensibly track the agent's pid; that's its
    /// problem, not the CLI's.)
    public static func ensureNothingActive(operation: String) -> String? {
        let state = read()
        if let recording = state.recording {
            return "\(operation) refused: a recording is already active (slug=\(recording.slug)). Run `flow42 stop` first."
        }
        if let play = state.play {
            return "\(operation) refused: a play is already active (id=\(play.id)). Run `flow42 stop` first."
        }
        return nil
    }
}
