// ChatSession.swift - One conversation between the user and an AI
// provider, scoped to a recording (or a play).
//
// Layout on disk:
//
//   <ownerDir>/                              # recording dir or play dir
//     chat/
//       sessions/
//         <id>/                              # one folder per session
//           meta.json                        # session metadata
//           transcript.jsonl                 # append-only event log
//           input.jsonl                      # user → agent input pipe
//           latest.json                      # latest event snapshot (FSEvents-watched)
//
// The id is `<utc-iso>-<provider-id>` so listing the sessions/ folder
// gives a chronological history per provider. A recording can have
// multiple sessions (the user switched providers, or restarted the
// chat) — at most one is `active` at a time.
//
// Plays use the SAME structure rooted at the play directory. Anything
// that has a "place on disk" can host a chat.

import Foundation

public nonisolated struct ChatSession: Sendable, Codable, Equatable, Identifiable {

    public enum Status: String, Sendable, Codable, Equatable {
        /// The agent subprocess is currently alive and writing into
        /// this session. At most one `active` session per owner dir
        /// is the invariant — readers should sweep stale `.active`
        /// rows on launch (we tear down on navigation but might miss
        /// the meta update on a hard crash).
        case active
        /// The agent finished cleanly OR the user navigated away. The
        /// transcript is final; sending another message starts a NEW
        /// session.
        case ended
        /// The agent process was killed without a clean tear-down (app
        /// crashed, OOM). Transcript may be partial.
        case failed
    }

    public let id: String
    /// Absolute path to the directory this session belongs to (a
    /// recording dir for a flow-creator chat, a play dir for an
    /// autonomous-run chat).
    public let ownerDir: String
    /// Provider id from `ProviderDefinition.id` — e.g.
    /// "claude-haiku-4-5", "gpt-4o", "codex". Used for the directory
    /// name suffix and for re-resolving the provider on resume.
    public let provider: String
    public let startedAt: String   // ISO 8601
    public var endedAt: String?
    public var status: Status

    public init(
        id: String,
        ownerDir: String,
        provider: String,
        startedAt: String,
        endedAt: String? = nil,
        status: Status = .active
    ) {
        self.id = id
        self.ownerDir = ownerDir
        self.provider = provider
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, provider
        case ownerDir = "owner_dir"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case status
    }

    // MARK: - Paths

    public var directory: String {
        (ownerDir as NSString).appendingPathComponent("chat/sessions/\(id)")
    }
    public var metaPath: String {
        (directory as NSString).appendingPathComponent("meta.json")
    }
    public var transcriptPath: String {
        (directory as NSString).appendingPathComponent("transcript.jsonl")
    }
    public var inputPath: String {
        (directory as NSString).appendingPathComponent("input.jsonl")
    }
    public var latestPath: String {
        (directory as NSString).appendingPathComponent("latest.json")
    }

    // MARK: - Factory

    /// Create a fresh session for `(ownerDir, provider)`. Creates the
    /// session directory, writes initial meta.json with `status: active`,
    /// and returns the resolved struct ready for the runner to use.
    public static func create(
        ownerDir: String,
        provider: String,
        at date: Date = Date()
    ) throws -> ChatSession {
        let stamp = isoStamp(date)
        let safeProvider = provider.replacingOccurrences(of: "/", with: "_")
        let id = "\(stamp)-\(safeProvider)"
        let session = ChatSession(
            id: id,
            ownerDir: ownerDir,
            provider: provider,
            startedAt: ISO8601DateFormatter().string(from: date),
            status: .active
        )
        try FileManager.default.createDirectory(
            atPath: session.directory, withIntermediateDirectories: true
        )
        try session.persistMeta()
        return session
    }

    // MARK: - Listing / loading

    /// All sessions for `ownerDir`, newest first.
    public static func list(ownerDir: String) -> [ChatSession] {
        let root = (ownerDir as NSString).appendingPathComponent("chat/sessions")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries.compactMap { entry -> ChatSession? in
            let dir = (root as NSString).appendingPathComponent(entry)
            return load(directory: dir)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public static func load(directory: String) -> ChatSession? {
        let metaPath = (directory as NSString).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)) else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(ChatSession.self, from: data)
    }

    /// Most-recent active session for an owner. If multiple `.active`
    /// rows exist (stale from a crash), the newest wins and the older
    /// ones are reconciled to `.failed` so the on-disk truth matches
    /// the singleton invariant.
    public static func reconcileAndFindActive(ownerDir: String) -> ChatSession? {
        var sessions = list(ownerDir: ownerDir)
        let actives = sessions.indices.filter { sessions[$0].status == .active }
        guard !actives.isEmpty else { return nil }
        // Newest active wins; older actives are stale.
        let keep = actives.first!  // sorted newest first
        for idx in actives.dropFirst() {
            var stale = sessions[idx]
            stale.status = .failed
            stale.endedAt = ISO8601DateFormatter().string(from: Date())
            try? stale.persistMeta()
            sessions[idx] = stale
        }
        return sessions[keep]
    }

    // MARK: - Mutators

    /// Mark this session ended at `date`. Writes back to meta.json.
    public func markEnded(at date: Date = Date()) throws -> ChatSession {
        var copy = self
        copy.status = .ended
        copy.endedAt = ISO8601DateFormatter().string(from: date)
        try copy.persistMeta()
        return copy
    }

    /// Mark this session failed (process died without a clean stop).
    public func markFailed(at date: Date = Date()) throws -> ChatSession {
        var copy = self
        copy.status = .failed
        copy.endedAt = ISO8601DateFormatter().string(from: date)
        try copy.persistMeta()
        return copy
    }

    private func persistMeta() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: metaPath), options: .atomic)
    }

    // MARK: - Helpers

    /// "20260505-114405" — sortable, human-readable, filesystem-safe.
    private static func isoStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
