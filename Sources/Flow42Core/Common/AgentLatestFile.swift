// AgentLatestFile.swift - The "what is the agent saying right now?" file.
//
// Single-record store at ~/.flow42/agent-latest.json. Flow42App writes
// it on every TranscriptEvent it receives from the ACP adapter; Flow42-
// Menu's floating panel watches it via FSEvents and re-renders the
// agent-activity bubble.
//
// Atomic (write-to-temp + rename) so the menu app never sees a partial
// write. Schema-versioned for future drift. Distinct from
// AgentTranscriptLog (the full append-only log) — readers that only
// need the latest event don't have to scan a growing JSONL file.

import Foundation

// MARK: - Schema

public nonisolated struct AgentLatestSnapshot: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    /// The play this event belongs to. Used by the menu app to ignore
    /// stale events from a previous run that hadn't been cleared yet.
    public let playId: String?
    public let event: TranscriptEvent?

    public init(playId: String?, event: TranscriptEvent?) {
        self.schemaVersion = 1
        self.playId = playId
        self.event = event
    }

    public static let empty = AgentLatestSnapshot(playId: nil, event: nil)

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case playId = "play_id"
        case event
    }
}

// MARK: - Reader / writer

/// Pure-function store, `nonisolated` so it can be written from any
/// actor (AutonomousRunner pushes from the main actor; AgentLatestClient
/// reads from a DispatchSource queue).
public nonisolated enum AgentLatestFile {

    public static func path() -> String {
        Flow42Paths.agentLatestFile()
    }

    /// Returns an empty snapshot when the file is missing or unparseable
    /// — absence is the canonical "no agent talking" signal.
    public static func read() -> AgentLatestSnapshot {
        let p = path()
        guard FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let snap = try? jsonDecoder().decode(AgentLatestSnapshot.self, from: data)
        else {
            return .empty
        }
        return snap
    }

    @discardableResult
    public static func write(_ snapshot: AgentLatestSnapshot) throws -> Int {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let encoder = jsonEncoder()
        let data = try encoder.encode(snapshot)

        let tmpPath = p + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        if rename(tmpPath, p) != 0 {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw NSError(
                domain: "Flow42AgentLatestFile",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(errno)))"]
            )
        }
        return data.count
    }

    /// Reset to the empty snapshot — used when a new autonomous run
    /// starts so the panel doesn't briefly flash the previous run's
    /// last event.
    public static func clear() throws {
        try write(.empty)
    }

    // MARK: - JSON config

    private static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
