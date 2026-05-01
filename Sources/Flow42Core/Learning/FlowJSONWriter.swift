// FlowJSONWriter.swift - Serialize a LearningSession into <dir>/flow.json.
//
// flow.json is the canonical artifact AND the live stream the menu bar
// popover tails. Rewritten atomically on every action append by the
// recorder, so the popover sees state grow in real time. Finalize replaces
// the file once more after stop with narration + dom-events folded in.
//
// External writers (Flow42Menu's annotation hotkey, the Chrome extension)
// emit to sidecar files: external-events.jsonl, dom-events.jsonl. We read
// those on every rewrite so highlight events show up promptly without
// requiring IPC to the daemon.

import Foundation

public enum FlowJSONWriter {

    /// Write flow.json for a snapshot of the recording. Called from the
    /// learning thread on every action append AND from finalize at stop
    /// time (the latter passes `narrationDicts` and `final = true` to
    /// finalize sorting + add the closing seal).
    public nonisolated static func write(
        session: LearningSession,
        slug: String,
        dir: String,
        narrationDicts: [[String: Any]] = [],
        final: Bool = false
    ) {
        let duration = Date().timeIntervalSince(session.startTime)

        // Native actions from the in-memory session.
        var merged: [[String: Any]] = session.actions.map { action in
            var dict = LearningDispatch.serializeAction(action)
            dict["timestamp_ms"] = machToWallClockMs(
                action.timestamp,
                startMach: session.startMach,
                startWallClock: session.startTime
            )
            dict["source"] = "native"
            return dict
        }

        // Narration is only available after stop (whisper transcription) —
        // pass it in via narrationDicts at finalize.
        merged.append(contentsOf: narrationDicts)

        // External events from the menu app (annotation highlights).
        appendJSONLFile(
            at: (dir as NSString).appendingPathComponent("external-events.jsonl"),
            defaultSource: "external",
            into: &merged
        )

        // DOM events from the Chrome extension's native messaging host.
        // Skipped entirely under BrowserMode.native — the user opted out of
        // the extension; merging its events would produce the very duplicate
        // entries (extension + native both seeing the same click) that
        // native-mode is meant to prevent.
        if BrowserMode.current() != .native {
            appendJSONLFile(
                at: (dir as NSString).appendingPathComponent("dom-events.jsonl"),
                defaultSource: "extension",
                into: &merged
            )
        }

        // Sort by timestamp_ms when we have one. During incremental writes
        // this keeps the popover ordered; at finalize it's mandatory.
        merged.sort { lhs, rhs in
            let l = (lhs["timestamp_ms"] as? Int64) ?? Int64.max
            let r = (rhs["timestamp_ms"] as? Int64) ?? Int64.max
            return l < r
        }

        let payload: [String: Any] = [
            "schema_version": 1,
            "platform": "mac",
            "slug": slug,
            "task_description": session.taskDescription ?? "",
            "recorded_at": ISO8601DateFormatter().string(from: session.startTime),
            "duration_seconds": Int(duration),
            "action_count": merged.count,
            "apps": Array(session.apps),
            "urls": session.urls,
            "actions": merged,
            "finalized": final,
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }

        let flowPath = (dir as NSString).appendingPathComponent("flow.json")
        let tmpPath = flowPath + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
            // POSIX rename is atomic on the same FS — readers either see the
            // old or the new flow.json, never a half-written one.
            if rename(tmpPath, flowPath) != 0 {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
        } catch {
            // Best-effort write. If disk is full, recording continues in
            // memory; the next append will retry.
        }
    }

    /// Read a JSON-lines file (one event per line) and append entries into
    /// `merged`. `defaultSource` is set when an event doesn't carry its own.
    /// Missing file → no-op. Malformed lines → skipped silently.
    private nonisolated static func appendJSONLFile(
        at path: String,
        defaultSource: String,
        into merged: inout [[String: Any]]
    ) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  var event = (try? JSONSerialization.jsonObject(with: lineData))
                    as? [String: Any] else { continue }
            if event["source"] == nil { event["source"] = defaultSource }
            merged.append(event)
        }
    }
}
