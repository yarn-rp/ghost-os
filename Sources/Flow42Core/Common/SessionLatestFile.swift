// SessionLatestFile.swift - Latest-event snapshot scoped to one
// `ChatSession`. Same single-record JSON store the global
// `AgentLatestFile` was, but written under
// `<session.directory>/latest.json` so each session has its own
// FSEvents-watched feed.
//
// Atomic write-to-temp + rename so readers never see a partial file.

import Foundation

public nonisolated enum SessionLatestFile {

    @discardableResult
    public static func write(
        _ snapshot: AgentLatestSnapshot, to session: ChatSession
    ) throws -> Int {
        let p = session.latestPath
        try FileManager.default.createDirectory(
            atPath: session.directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let tmp = p + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmp))
        if rename(tmp, p) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(
                domain: "Flow42SessionLatestFile",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "rename failed: \(String(cString: strerror(errno)))"]
            )
        }
        return data.count
    }

    public static func read(from session: ChatSession) -> AgentLatestSnapshot {
        guard FileManager.default.fileExists(atPath: session.latestPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: session.latestPath))
        else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AgentLatestSnapshot.self, from: data)) ?? .empty
    }

    public static func clear(_ session: ChatSession) throws {
        try write(.empty, to: session)
    }
}
