// PlayHistoryReader.swift - Reads `<flow-dir>/plays/*/play.yaml` into a
// typed list of past plays. Used by:
//   - FlowDetailView's "Recent runs" strip — show last N plays + their
//     status + duration + cost.
//   - (eventually) AutonomousRunner / AgentLatestClient debugging /
//     re-render of a finished run's transcript on demand.
//
// Pure file I/O; no FSEvents watching. Callers re-read on appear or
// when state.json signals a play just ended. Cheap — typically a few
// dozen plays per flow at most.

import Foundation
import Yams

public nonisolated struct PlayHistoryEntry: Sendable, Codable, Equatable, Identifiable {

    public enum ExitReason: String, Sendable, Codable, Equatable {
        case completed
        case userStopped = "user_stopped"
        case agentStopped = "agent_stopped"
        case crashed
        case unknown

        public init(raw: String) {
            self = ExitReason(rawValue: raw) ?? .unknown
        }
    }

    /// Stable id — the plays/<id>/ directory name.
    public let id: String

    /// Absolute path to the play directory (so callers can open the
    /// log.jsonl on click).
    public let directory: String

    /// Whether the play actually finished. nil = still in flight (no
    /// `ended_at` in play.yaml yet).
    public let exitReason: ExitReason?

    /// `started_by` from play.yaml: typically "claude" / "user".
    public let startedBy: String?

    /// Free-form label the runner attached to this play. Often the
    /// flow's display name + a context hint.
    public let label: String?

    /// State at termination. "driving" / "watching".
    public let state: String?

    /// ISO 8601.
    public let startedAt: Date?
    public let endedAt: Date?

    /// Convenience: how long the play ran. Nil for in-flight plays.
    public var duration: TimeInterval? {
        guard let s = startedAt, let e = endedAt else { return nil }
        return e.timeIntervalSince(s)
    }

    public init(
        id: String,
        directory: String,
        exitReason: ExitReason?,
        startedBy: String?,
        label: String?,
        state: String?,
        startedAt: Date?,
        endedAt: Date?
    ) {
        self.id = id
        self.directory = directory
        self.exitReason = exitReason
        self.startedBy = startedBy
        self.label = label
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// One step the agent ran during this play. Each numbered subdirectory
    /// of `<play-dir>/steps/` corresponds to a `flow42 do …` invocation;
    /// the executor wrote `screenshot.jpg` and `annotated.jpg` into it
    /// before firing the action so the UI can show what state the agent
    /// saw and where it clicked.
    public nonisolated struct Step: Sendable, Equatable, Identifiable {
        public let id: String  // step folder name, e.g. "0001"
        public let directory: String
        public let screenshotPath: String?
        public let annotatedScreenshotPath: String?

        public init(
            id: String,
            directory: String,
            screenshotPath: String?,
            annotatedScreenshotPath: String?
        ) {
            self.id = id
            self.directory = directory
            self.screenshotPath = screenshotPath
            self.annotatedScreenshotPath = annotatedScreenshotPath
        }
    }

    /// Enumerate the per-step folders the executor wrote. Empty array if
    /// the play predates the screenshot-per-step feature or the executor
    /// failed to capture (e.g. permission revoked mid-run).
    public func steps() -> [Step] {
        let stepsRoot = (directory as NSString).appendingPathComponent("steps")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: stepsRoot) else {
            return []
        }
        var out: [Step] = []
        for name in entries.sorted() {
            let dir = (stepsRoot as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let raw = (dir as NSString).appendingPathComponent("screenshot.jpg")
            let ann = (dir as NSString).appendingPathComponent("annotated.jpg")
            out.append(Step(
                id: name,
                directory: dir,
                screenshotPath: fm.fileExists(atPath: raw) ? raw : nil,
                annotatedScreenshotPath: fm.fileExists(atPath: ann) ? ann : nil
            ))
        }
        return out
    }
}

public nonisolated enum PlayHistoryReader {

    /// Read up to `limit` past plays for a flow, sorted newest-first
    /// by `started_at`. Plays that fail to parse are skipped.
    public static func read(flowDir: String, limit: Int = 20) -> [PlayHistoryEntry] {
        let playsDir = (flowDir as NSString).appendingPathComponent("plays")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: playsDir) else {
            return []
        }

        var out: [PlayHistoryEntry] = []
        for slug in entries {
            let dir = (playsDir as NSString).appendingPathComponent(slug)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let yaml = (dir as NSString).appendingPathComponent("play.yaml")
            guard fm.fileExists(atPath: yaml) else { continue }
            if let entry = parse(slug: slug, dir: dir, yamlPath: yaml) {
                out.append(entry)
            }
        }
        out.sort { (a, b) in
            switch (a.startedAt, b.startedAt) {
            case let (.some(l), .some(r)): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.id > b.id
            }
        }
        if out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    private static func parse(
        slug: String, dir: String, yamlPath: String
    ) -> PlayHistoryEntry? {
        guard let yamlString = try? String(
            contentsOf: URL(fileURLWithPath: yamlPath), encoding: .utf8
        ),
              let parsed = try? Yams.load(yaml: yamlString) as? [String: Any]
        else { return nil }

        let f = ISO8601DateFormatter()
        let exitReason = (parsed["exit_reason"] as? String).map(PlayHistoryEntry.ExitReason.init(raw:))
        let startedAt = (parsed["started_at"] as? String).flatMap(f.date(from:))
        let endedAt = (parsed["ended_at"] as? String).flatMap(f.date(from:))

        return PlayHistoryEntry(
            id: parsed["id"] as? String ?? slug,
            directory: dir,
            exitReason: exitReason,
            startedBy: parsed["started_by"] as? String,
            label: parsed["label"] as? String,
            state: parsed["state"] as? String,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }
}
