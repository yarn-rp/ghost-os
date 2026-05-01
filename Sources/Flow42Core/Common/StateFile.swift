// StateFile.swift - Shared `~/.flow42/state.json` reader/writer.
//
// This file is the single source of truth for the menu bar app's "what is
// flow42 doing right now?" view. The CLI writes; the menu app reads.
//
// Modes (only three are valid):
//   - idle         no recording, no agent driving
//   - recording    `flow42 record start` is alive in a daemon
//   - autonomous   an agent has called `flow42 mode set autonomous`
//
// Annotation is NOT a mode here — it has its own dedicated overlay UI in the
// menu app and does not need a state.json transition.
//
// Writes are atomic (write-to-temp + rename) so a reader never sees a half-
// written file. The schema is versioned so future readers can detect drift.

import Foundation

public enum AppMode: String, Sendable, Codable {
    case idle
    case recording
    case autonomous
}

public struct AppState: Sendable, Codable {
    public let schemaVersion: Int
    public let mode: AppMode
    public let since: String  // ISO 8601
    public let label: String?
    public let recording: RecordingInfo?
    public let autonomous: AutonomousInfo?

    public struct RecordingInfo: Sendable, Codable {
        public let slug: String
        public let dir: String
        public let pid: Int

        public init(slug: String, dir: String, pid: Int) {
            self.slug = slug
            self.dir = dir
            self.pid = pid
        }
    }

    public struct AutonomousInfo: Sendable, Codable {
        public let label: String
        public let startedBy: String

        public init(label: String, startedBy: String = "agent") {
            self.label = label
            self.startedBy = startedBy
        }

        enum CodingKeys: String, CodingKey {
            case label
            case startedBy = "started_by"
        }
    }

    public init(
        mode: AppMode,
        label: String? = nil,
        recording: RecordingInfo? = nil,
        autonomous: AutonomousInfo? = nil,
        at date: Date = Date()
    ) {
        self.schemaVersion = 1
        self.mode = mode
        self.since = ISO8601DateFormatter().string(from: date)
        self.label = label
        self.recording = recording
        self.autonomous = autonomous
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case mode
        case since
        case label
        case recording
        case autonomous
    }
}

public enum StateFile {

    /// Path to the state file. Public so the menu app can watch it via
    /// FSEvents.
    public static func path() -> String {
        Flow42Paths.stateFile()
    }

    /// Read the current state. Returns idle when the file is missing or
    /// unparseable (treating absence as the canonical "nothing happening"
    /// signal — preferable to a "broken state file" error in a watcher).
    public static func read() -> AppState {
        let p = path()
        guard FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            return AppState(mode: .idle)
        }
        return state
    }

    /// Atomically write a new state. Returns the bytes written, or throws on
    /// I/O failure. Never partially writes — the file either reflects the new
    /// state or remains unchanged.
    @discardableResult
    public static func write(_ state: AppState) throws -> Int {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)

        let tmpPath = p + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        // Posix rename is atomic on the same filesystem.
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

    /// Convenience: revert to idle. No-op if already idle.
    public static func clearToIdle() throws {
        try write(AppState(mode: .idle))
    }

    /// Convert the current state to a `[String: Any]` dictionary, suitable for
    /// `flow42 mode get` JSON output.
    public static func readAsDict() -> [String: Any] {
        let state = read()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return ["mode": "idle", "schema_version": 1]
        }
        return dict
    }
}
