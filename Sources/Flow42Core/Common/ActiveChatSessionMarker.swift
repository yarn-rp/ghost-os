// ActiveChatSessionMarker.swift - Cross-process pointer at
// `~/.flow42/active-chat-session.json` saying "the chat session
// living at <directory> is alive right now."
//
// Why: Flow42App's `AutonomousRunner` spawns ACP for a session
// rooted under `<flow-or-recording-dir>/chat/sessions/<id>/`, but
// Flow42Menu's floating panel runs in a separate process and has
// no direct handle to that session. We use the same FSEvents-
// watched JSON pattern state.json + agent-latest.json already use:
// the runner writes the marker on start, clears on stop, and the
// menu's PlayPanelController watches it to rebind its chat client.
//
// Atomic write-to-temp + rename so readers never see a partial
// file. Cleared = no active chat session.

import Foundation

public nonisolated struct ActiveChatSessionPointer: Sendable, Codable, Equatable {
    /// Absolute path to the session directory
    /// (`<owner>/chat/sessions/<id>/`).
    public let directory: String
    /// The owner dir — flow directory or recording directory. Tells
    /// the menu which higher-level surface this chat belongs to.
    public let ownerDir: String
    /// Provider id (Claude, Codex, …). Surfaced in the floating
    /// panel's chat header so the user knows what they're talking to.
    public let provider: String
    /// ISO 8601 of when the marker was written. Diagnostic only.
    public let writtenAt: String

    public init(directory: String, ownerDir: String, provider: String, at date: Date = Date()) {
        self.directory = directory
        self.ownerDir = ownerDir
        self.provider = provider
        self.writtenAt = ISO8601DateFormatter().string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case directory, ownerDir = "owner_dir", provider, writtenAt = "written_at"
    }
}

public nonisolated enum ActiveChatSessionMarker {

    public static func path() -> String {
        (Flow42Paths.root() as NSString).appendingPathComponent("active-chat-session.json")
    }

    public static func read() -> ActiveChatSessionPointer? {
        let p = path()
        guard FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p))
        else { return nil }
        return try? JSONDecoder().decode(ActiveChatSessionPointer.self, from: data)
    }

    /// Write the marker. Called by AutonomousRunner the moment it
    /// spawns a session. Atomic so the menu never sees a partial.
    @discardableResult
    public static func write(_ pointer: ActiveChatSessionPointer) throws -> Int {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(pointer)
        let tmp = p + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmp))
        if rename(tmp, p) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(
                domain: "Flow42ActiveChatSessionMarker",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "rename failed: \(String(cString: strerror(errno)))"]
            )
        }
        return data.count
    }

    /// Remove the marker. Called by AutonomousRunner on stop. Best-
    /// effort — failure to clear leaves a stale pointer that the
    /// menu's reconciliation will sweep on next read.
    public static func clear() {
        try? FileManager.default.removeItem(atPath: path())
    }
}
