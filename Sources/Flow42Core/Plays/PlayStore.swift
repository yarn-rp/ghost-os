// PlayStore.swift - On-disk owner of <flow-dir>/plays/<id>/.
//
// Two artifacts per play:
//   play.yaml    — current state (snapshot, rewritten on each update)
//   log.jsonl    — append-only event stream
//
// PlayStore is a stateless façade — every method takes a flowDir + playId and
// touches the right files. Callers don't keep a long-lived handle. This makes
// the Play CLI's verbs (start, pause, resume, etc.) trivially independent
// processes — none of them needs to coordinate with another via memory.
//
// Atomicity:
//   - play.yaml uses YAMLEmit + write-tmp + rename (same shape as meta.yaml).
//   - log.jsonl uses appendLine() — open(O_APPEND), write, close. POSIX
//     guarantees small writes (<= PIPE_BUF) are atomic, which is plenty
//     for our ~300 byte JSON lines.

import Foundation

public enum PlayStore {

    // MARK: - Path helpers

    public static func playsRoot(flowDir: String) -> String {
        (flowDir as NSString).appendingPathComponent("plays")
    }

    public static func playDir(flowDir: String, playId: String) -> String {
        (playsRoot(flowDir: flowDir) as NSString).appendingPathComponent(playId)
    }

    public static func playYamlPath(flowDir: String, playId: String) -> String {
        (playDir(flowDir: flowDir, playId: playId) as NSString)
            .appendingPathComponent("play.yaml")
    }

    public static func logPath(flowDir: String, playId: String) -> String {
        (playDir(flowDir: flowDir, playId: playId) as NSString)
            .appendingPathComponent("log.jsonl")
    }

    // MARK: - Lifecycle

    /// Create a fresh play directory. Writes the initial play.yaml + an
    /// empty log.jsonl, then appends a `play_start` event. Returns the
    /// `PlayInfo` that should be persisted into state.json.
    public static func create(
        flowDir: String,
        flowName: String,
        state: PlayInfo.State,
        startedBy: String,
        label: String?,
        pid: Int,
        position: PlayInfo.Position
    ) throws -> (id: String, info: PlayInfo) {
        let id = PlayId.generate(state: state, startedBy: startedBy)
        let dir = playDir(flowDir: flowDir, playId: id)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let info = PlayInfo(
            id: id,
            flowDir: flowDir,
            flowName: flowName,
            state: state,
            startedBy: startedBy,
            label: label,
            pid: pid,
            position: position,
            pause: nil
        )

        try writeYaml(flowDir: flowDir, playId: id, info: info, ended: nil)

        try appendLog(flowDir: flowDir, playId: id, event: [
            "type": "play_start",
            "ts": isoNow(),
            "state": state.rawValue,
            "by": startedBy,
            "label": label ?? "",
        ])

        return (id, info)
    }

    /// Update the position cursor. Rewrites play.yaml and appends a
    /// `position` event.
    public static func updatePosition(
        flowDir: String,
        playId: String,
        info: PlayInfo,
        newPosition: PlayInfo.Position
    ) throws -> PlayInfo {
        let updated = info.with(position: newPosition)
        try writeYaml(flowDir: flowDir, playId: playId, info: updated, ended: nil)
        try appendLog(flowDir: flowDir, playId: playId, event: [
            "type": "position",
            "ts": isoNow(),
            "phase_index": newPosition.phaseIndex,
            "phase_name": newPosition.phaseName,
            "step_index": newPosition.stepIndex,
        ])
        return updated
    }

    /// Set or clear the pause block. Rewrites play.yaml and appends a
    /// `pause` (when setting) or `resume` (when clearing) event.
    public static func updatePause(
        flowDir: String,
        playId: String,
        info: PlayInfo,
        pause: PlayInfo.PauseInfo?
    ) throws -> PlayInfo {
        let updated = info.with(pause: pause)
        try writeYaml(flowDir: flowDir, playId: playId, info: updated, ended: nil)
        if let pause {
            try appendLog(flowDir: flowDir, playId: playId, event: [
                "type": "pause",
                "ts": isoNow(),
                "paused_by": pause.pausedBy.rawValue,
                "reason": pause.reason,
            ])
        } else {
            try appendLog(flowDir: flowDir, playId: playId, event: [
                "type": "resume",
                "ts": isoNow(),
            ])
        }
        return updated
    }

    /// Close out the play. Writes ended_at + exit_reason to play.yaml,
    /// appends a `play_end` event.
    public static func end(
        flowDir: String,
        playId: String,
        info: PlayInfo,
        exitReason: String
    ) throws {
        let endedAt = isoNow()
        try writeYaml(
            flowDir: flowDir, playId: playId, info: info,
            ended: (endedAt, exitReason)
        )
        try appendLog(flowDir: flowDir, playId: playId, event: [
            "type": "play_end",
            "ts": endedAt,
            "exit_reason": exitReason,
        ])
    }

    /// Append a free-form event to log.jsonl. Used by `flow42 play log` and
    /// internally for `do` / `do_result` events emitted by the gate.
    public static func appendLog(
        flowDir: String,
        playId: String,
        event: [String: Any]
    ) throws {
        let path = logPath(flowDir: flowDir, playId: playId)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: event,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        var line = data
        line.append(0x0A)  // '\n'
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw NSError(
                domain: "PlayStore", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "open(\(path)): \(String(cString: strerror(errno)))"]
            )
        }
        defer { close(fd) }
        _ = line.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return write(fd, base, line.count)
        }
    }

    // MARK: - Read

    public static func read(flowDir: String, playId: String) -> [String: Any]? {
        // We read play.yaml as text; full Yams parsing happens at the CLI
        // layer (`flow42 play show`) which is the only consumer that needs
        // the structured form. The store itself only needs the raw text.
        let path = playYamlPath(flowDir: flowDir, playId: playId)
        guard let text = try? String(
            contentsOf: URL(fileURLWithPath: path), encoding: .utf8
        ) else { return nil }
        return ["raw_yaml": text]
    }

    /// List all play ids in `<flow-dir>/plays/`, newest first (lex sort
    /// reversed, since ids are timestamp-prefixed).
    public static func list(flowDir: String) -> [String] {
        let root = playsRoot(flowDir: flowDir)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)
    }

    // MARK: - Internals

    private static func writeYaml(
        flowDir: String,
        playId: String,
        info: PlayInfo,
        ended: (at: String, reason: String)?
    ) throws {
        var dict: [String: Any] = [
            "id": info.id,
            "flow": info.flowName,
            "state": info.state.rawValue,
            "started_by": info.startedBy,
            "started_at": startedAtFromId(info.id),
            "pid": info.pid,
            "position": [
                "phase_index": info.position.phaseIndex,
                "phase_name": info.position.phaseName,
                "step_index": info.position.stepIndex,
                "total_phases": info.position.totalPhases,
                "total_steps_in_phase": info.position.totalStepsInPhase,
            ] as [String: Any],
        ]
        if let label = info.label { dict["label"] = label }
        if let ended {
            dict["ended_at"] = ended.at
            dict["exit_reason"] = ended.reason
        }
        if let pause = info.pause {
            dict["pause"] = [
                "reason": pause.reason,
                "paused_at": pause.pausedAt,
                "paused_by": pause.pausedBy.rawValue,
            ] as [String: Any]
        }

        let yaml = YAMLEmit.mapping(dict)
        let path = playYamlPath(flowDir: flowDir, playId: playId)
        let tmp = path + ".tmp.\(getpid())"
        try yaml.write(toFile: tmp, atomically: false, encoding: .utf8)
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(
                domain: "PlayStore", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "rename(\(tmp), \(path)): \(String(cString: strerror(errno)))"]
            )
        }
    }

    /// Recover the `started_at` timestamp from the id (which is itself a
    /// timestamp) so we don't need to keep it in PlayInfo.
    private static func startedAtFromId(_ id: String) -> String {
        // id format: YYYYMMDD-HHMMSS-<state>-<by>
        let parts = id.split(separator: "-")
        guard parts.count >= 2 else { return isoNow() }
        let date = String(parts[0])      // YYYYMMDD
        let time = String(parts[1])      // HHMMSS
        guard date.count == 8, time.count == 6 else { return isoNow() }
        let yyyy = date.prefix(4)
        let mm = date.dropFirst(4).prefix(2)
        let dd = date.dropFirst(6).prefix(2)
        let hh = time.prefix(2)
        let mi = time.dropFirst(2).prefix(2)
        let ss = time.dropFirst(4).prefix(2)
        return "\(yyyy)-\(mm)-\(dd)T\(hh):\(mi):\(ss)Z"
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

// MARK: - PlayInfo immutable updaters

private extension PlayInfo {
    func with(position: PlayInfo.Position) -> PlayInfo {
        PlayInfo(
            id: id, flowDir: flowDir, flowName: flowName, state: state,
            startedBy: startedBy, label: label, pid: pid,
            position: position, pause: pause
        )
    }
    func with(pause: PlayInfo.PauseInfo?) -> PlayInfo {
        PlayInfo(
            id: id, flowDir: flowDir, flowName: flowName, state: state,
            startedBy: startedBy, label: label, pid: pid,
            position: position, pause: pause
        )
    }
    func with(state: PlayInfo.State) -> PlayInfo {
        PlayInfo(
            id: id, flowDir: flowDir, flowName: flowName, state: state,
            startedBy: startedBy, label: label, pid: pid,
            position: position, pause: pause
        )
    }
}
