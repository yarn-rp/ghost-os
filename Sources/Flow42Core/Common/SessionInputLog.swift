// SessionInputLog.swift - User → agent input pipe scoped to a
// `ChatSession`. Replaces the global `AgentInputLog` —
// `<session.directory>/input.jsonl` so each session has its own
// pipe.
//
// Reuses the same `AgentInputLine` shape (kind + text + timestamp +
// id) that the original log used, so the runner-side tail logic
// doesn't change beyond which path it watches.

import Foundation

public nonisolated enum SessionInputLog {

    public static func append(_ line: AgentInputLine, to session: ChatSession) throws {
        try FileManager.default.createDirectory(
            atPath: session.directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(line)
        data.append(0x0A)

        let url = URL(fileURLWithPath: session.inputPath)
        if !FileManager.default.fileExists(atPath: session.inputPath) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func readAll(from session: ChatSession) -> [AgentInputLine] {
        guard FileManager.default.fileExists(atPath: session.inputPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: session.inputPath)),
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
