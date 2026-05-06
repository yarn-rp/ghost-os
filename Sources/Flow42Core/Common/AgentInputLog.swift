// AgentInputLog.swift - User-typed messages flowing FROM Flow42Menu's
// chat input field TO Flow42App's ACP session.
//
// Path: ~/.flow42/agent-input.jsonl. Append-only JSONL, one object per
// line. Truncated at the start of every autonomous run.
//
// Cross-process model: Flow42Menu owns the chat input UI; Flow42App
// owns the ACP subprocess. Direct in-process communication isn't
// possible (separate binaries), so we use the same FSEvents-watched
// JSONL pattern that already carries agent → menu events
// (agent-transcript.jsonl). This is the reverse direction.
//
// Why JSONL and not a socket / XPC: zero new infrastructure, matches
// the existing patterns (state.json, agent-latest.json, agent-
// transcript.jsonl), survives either process crashing without
// reconnection logic, easy to debug by `tail -f`-ing the file.

import Foundation

public nonisolated struct AgentInputLine: Sendable, Codable, Equatable, Identifiable {

    /// What kind of cross-process signal this line carries. Most lines
    /// are plain user prompts; the special `.stop` kind tells the
    /// runner to terminate the ACP session (used by Flow42Menu's chat-
    /// only mode Stop button — there's no `state.play` to clear via
    /// `flow42 stop` in that mode, so we need a dedicated signal).
    public enum Kind: String, Sendable, Codable, Equatable {
        case prompt   // default — text is a user prompt to forward
        case stop     // terminate the run; text is unused
    }

    /// Stable id so the reader can dedupe across re-tails — if Flow42App
    /// restarts mid-run we don't want it to re-process every line.
    public let id: UUID
    /// Optional kind discriminator; absent in old files = .prompt.
    public let kind: Kind
    /// What the user typed (for `.prompt`); ignored for `.stop`.
    public let text: String
    /// ISO8601 of when the menu wrote it.
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        kind: Kind = .prompt,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, timestamp
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        // Tolerant of older files that didn't have `kind`.
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .prompt
        self.text = try c.decode(String.self, forKey: .text)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
    }
}

public nonisolated enum AgentInputLog {

    public static func path() -> String {
        Flow42Paths.agentInputLog()
    }

    /// Truncate the log. Called by AutonomousRunner at the start of each
    /// run so a stale "yes" from a previous session doesn't get fed to
    /// the new one.
    public static func reset() throws {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try Data().write(to: URL(fileURLWithPath: p))
    }

    /// Append one user message as a single JSON line. O_APPEND open is
    /// atomic across writers under POSIX so concurrent appenders won't
    /// interleave bytes (only one writer in practice today, but the
    /// guarantee is free).
    public static func append(_ line: AgentInputLine) throws {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(line)
        data.append(0x0A)

        let url = URL(fileURLWithPath: p)
        if !FileManager.default.fileExists(atPath: p) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Read all lines as a flat array. Lines that fail to decode are
    /// skipped (corruption shouldn't block the rest).
    public static func readAll() -> [AgentInputLine] {
        let p = path()
        guard FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [AgentInputLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = raw.data(using: .utf8),
               let line = try? decoder.decode(AgentInputLine.self, from: lineData) {
                out.append(line)
            }
        }
        return out
    }
}
