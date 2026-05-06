// SessionTranscriptLog.swift - Append-only JSONL log of every
// TranscriptEvent for one `ChatSession`. Replaces the global
// `AgentTranscriptLog` — every session has its own
// `<session.directory>/transcript.jsonl` so two recordings' chats
// can never overwrite each other.
//
// O_APPEND open is atomic across writers under POSIX, so concurrent
// appenders won't interleave bytes (we have one writer in practice).

import Foundation

public nonisolated enum SessionTranscriptLog {

    public static func append(_ event: TranscriptEvent, to session: ChatSession) throws {
        try FileManager.default.createDirectory(
            atPath: session.directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A) // newline

        let url = URL(fileURLWithPath: session.transcriptPath)
        if !FileManager.default.fileExists(atPath: session.transcriptPath) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func readAll(from session: ChatSession) -> [TranscriptEvent] {
        guard FileManager.default.fileExists(atPath: session.transcriptPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: session.transcriptPath)),
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
