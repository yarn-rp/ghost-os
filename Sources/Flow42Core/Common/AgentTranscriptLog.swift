// AgentTranscriptLog.swift - Append-only JSONL log of every
// TranscriptEvent from the current autonomous run.
//
// Layout: `~/.flow42/agent-transcript.jsonl`. One JSON object per line,
// no trailing comma, newline-terminated. Truncated when a new run
// starts (the previous run's events live on inside the play's own
// `<flow-dir>/plays/<id>/log.jsonl` if you need them later).
//
// Distinct from AgentLatestFile because:
//   - Latest file is single-record (~1KB), watched for re-render. Cheap.
//   - This log is append-only (potentially MBs over a long run).
//     Readers tail it — they shouldn't have to parse the whole file
//     just to see the most recent thing the agent said.
//
// Both files are written from the same call site in AutonomousRunner,
// so they stay in lockstep without callers having to think about it.

import Foundation

/// Pure-function store. `nonisolated` so callers can append from the
/// main actor while readers can pull `readAll()` off the main actor
/// (chat-mode view does this to avoid hitching the UI on a long log).
public nonisolated enum AgentTranscriptLog {

    public static func path() -> String {
        Flow42Paths.agentTranscriptLog()
    }

    /// Truncate the log. Called at the start of each autonomous run.
    public static func reset() throws {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        // Empty file (preserves any handle the menu app may have open
        // — open / close cycles can be jittery under FSEvents).
        try Data().write(to: URL(fileURLWithPath: p))
    }

    /// Append one event as a single JSON line.
    public static func append(_ event: TranscriptEvent) throws {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A) // newline

        // O_APPEND open is atomic across writers under POSIX; multiple
        // simultaneous appenders won't interleave their bytes. We also
        // don't seek before writing.
        let url = URL(fileURLWithPath: p)
        if !FileManager.default.fileExists(atPath: p) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Read the entire log as a flat `[TranscriptEvent]`. Lines that
    /// fail to decode are skipped (a corruption shouldn't prevent the
    /// rest of the chat from rendering).
    public static func readAll() -> [TranscriptEvent] {
        let p = path()
        guard FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [TranscriptEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = line.data(using: .utf8),
               let event = try? decoder.decode(TranscriptEvent.self, from: lineData) {
                out.append(event)
            }
        }
        return out
    }
}
