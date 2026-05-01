// NativeHost.swift - Chrome native-messaging host loop.
//
// Chrome launches `flow42 native-host` when the extension calls
// chrome.runtime.connectNative('com.web42.flow42'). We read length-prefixed
// JSON frames from stdin and respond on stdout. Diagnostic logging goes to
// stderr (Chrome discards it; the install command can wire stderr to a log
// file via a shell shim if you want visibility).
//
// V1 message types (extension <-> host):
//   ext -> host: { type: "hello" }
//                  → host responds { type: "hello-ack", version: "..." }
//   ext -> host: { type: "active-recording" }
//                  → host responds { type: "active-recording", recording: {...} | null }
//   ext -> host: { type: "dom-event", recording: "<slug>", event: {...} }
//                  → host appends to <recording-dir>/dom-events.jsonl,
//                    no response needed (fire-and-forget).
//
// The recording-active state lives in ~/.flow42/active-recording.json
// (written by `flow42 record` on start, removed on stop). This file is the
// only IPC surface between the recorder process and the native-host process.

import Foundation

public enum NativeHost {

    public static func run() {
        log("native host started, pid \(getpid())")

        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput

        while let frame = Framing.read(stdin) {
            let type = (frame["type"] as? String) ?? ""
            switch type {
            case "hello":
                Framing.write(stdout, [
                    "type": "hello-ack",
                    "version": Flow42Core.version,
                ])
            case "active-recording":
                var payload: [String: Any] = [
                    "type": "active-recording",
                    "recording": ActiveRecording.read() as Any? ?? NSNull(),
                    // Hint the extension so it can short-circuit without
                    // sending dom-events at all when native mode is active.
                    "browser_mode": BrowserMode.current().rawValue,
                ]
                // One-shot highlight-mode trigger from the menu app's
                // Cmd+Shift+A handler when Chrome is frontmost. Consume()
                // checks + removes the marker atomically so the next poll
                // doesn't re-trigger.
                if HighlightRequest.consume() {
                    payload["highlight_request"] = true
                }
                if HighlightExit.consume() {
                    payload["highlight_exit"] = true
                }
                Framing.write(stdout, payload)
            case "dom-event":
                handleDomEvent(frame)
            default:
                Framing.write(stdout, [
                    "type": "error",
                    "message": "unknown frame type: \(type)",
                ])
            }
        }

        log("stdin closed, exiting")
    }

    // MARK: - DOM event handler

    private static var domScreenshotCounter = 0

    private static func handleDomEvent(_ frame: [String: Any]) {
        guard let recordingSlug = frame["recording"] as? String else { return }
        guard var event = frame["event"] as? [String: Any] else { return }

        // Native browser-mode: the user opted out of the extension entirely.
        // Drop the frame BEFORE we touch the recording dir so dom-events.jsonl
        // is never created. The extension should also stop sending these
        // (we surface browser_mode in the active-recording reply), but this
        // is the authoritative gate either way.
        if BrowserMode.current() == .native {
            log("dom-event dropped: BrowserMode=native, ignoring extension")
            return
        }

        // Resolve the recording dir from the active-recording marker. We
        // refuse to write to arbitrary slugs even if the extension asks —
        // the slug must match the currently-active recording, otherwise we
        // drop the frame on the floor (helps if the extension's state is
        // stale from a previous session).
        guard let active = ActiveRecording.read(),
              let activeSlug = active["slug"] as? String,
              activeSlug == recordingSlug,
              let dir = active["dir"] as? String else {
            log("dom-event for inactive recording '\(recordingSlug)', dropping")
            return
        }

        // If the extension included a JPEG, write it to disk and replace the
        // base64 blob with a relative path. Keeps dom-events.jsonl small.
        if let b64 = event["screenshot_jpeg_base64"] as? String,
           let data = Data(base64Encoded: b64) {
            domScreenshotCounter += 1
            let filename = String(format: "dom-%03d.jpg", domScreenshotCounter)
            let shotDir = (dir as NSString).appendingPathComponent("screenshots")
            try? FileManager.default.createDirectory(
                atPath: shotDir, withIntermediateDirectories: true
            )
            let shotPath = (shotDir as NSString).appendingPathComponent(filename)
            do {
                try data.write(to: URL(fileURLWithPath: shotPath))
                event["screenshot"] = "screenshots/\(filename)"
            } catch {
                log("failed to write \(filename): \(error)")
            }
        }
        event.removeValue(forKey: "screenshot_jpeg_base64")

        guard let line = try? JSONSerialization.data(
            withJSONObject: event,
            options: [.withoutEscapingSlashes]
        ) else { return }

        let path = (dir as NSString).appendingPathComponent("dom-events.jsonl")
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data([0x0a]))
            try? handle.close()
        } else {
            // First write — file doesn't exist yet.
            try? (line + Data([0x0a])).write(to: url, options: [])
        }

        // v2 step-folder + events.jsonl write. Phase A keeps dom-events.jsonl
        // around (above) so FlowJSONWriter's fold-into-flow.json still works
        // for the menu timeline; Phase B switches the timeline to events.jsonl
        // and Phase C drops the dom-events.jsonl tee.
        writeExtensionStepFolder(recordingDir: dir, event: event)
    }

    /// Mirror an extension dom-event into a v2 step folder.
    /// Step index race: same shape as the annotation controller path —
    /// scan steps/ for highest, take +1. The recorder daemon allocates
    /// indices in its own process; if one of its appendActions and one
    /// of these extension events land on the same millisecond, both will
    /// pick the same index and one will end up sharing a folder with the
    /// other. Acceptable for Phase A (the dom-events.jsonl tee guarantees
    /// flow.json sees both events regardless); Phase B will move allocation
    /// behind a single owner.
    private static func writeExtensionStepFolder(
        recordingDir: String,
        event: [String: Any]
    ) {
        let actionType = (event["action_type"] as? String) ?? "extensionEvent"
        let stepIndex = StepFolderWriter.highestExistingIndex(in: recordingDir) + 1
        // Fall back to wall-clock if the extension didn't tag one. The
        // recorder's serializeIndexEntry path sorts by timestamp_ms at view
        // time, so giving up here would mis-order the timeline. The
        // extension uses `Date.now()` (Int64 ms since epoch) when it tags.
        let extensionTs = (event["timestamp_ms"] as? Int64)
            ?? (event["timestamp_ms"] as? Int).map(Int64.init)
            ?? Int64((event["timestamp_ms"] as? Double) ?? 0)
        let timestampMs = extensionTs > 0
            ? extensionTs
            : Int64(Date().timeIntervalSince1970 * 1000)

        // Lift the screenshot from the event payload into the step folder.
        // We don't move — copy via the staged source — so the legacy
        // dom-events.jsonl + flow.json fold can still resolve it at the
        // original `screenshots/dom-NNN.jpg` path.
        let screenshotAbs: String? = {
            guard let rel = event["screenshot"] as? String, !rel.isEmpty
            else { return nil }
            return (recordingDir as NSString).appendingPathComponent(rel)
        }()

        // The meta.yaml is the event payload itself, plus a `source` tag and
        // a `timestamp_ms` if the extension didn't supply one. We pass it
        // through; StepFolderWriter rewrites the `screenshot` field to the
        // step-folder-relative path of the copied file.
        var meta = event
        meta["source"] = "extension"
        meta["timestamp_ms"] = timestampMs

        let outcome = StepFolderWriter.writeNewStep(
            recordingDir: recordingDir,
            stepIndex: stepIndex,
            actionType: actionType,
            meta: meta,
            screenshotSourceAbs: screenshotAbs,
            annotatedScreenshotSourceAbs: nil
        )

        guard let outcome else { return }

        // events.jsonl summary line. Same shape as the native recorder's
        // serializeIndexEntry output; consumers shouldn't have to know the
        // source to render a row.
        let app = (event["app"] as? String) ?? ""
        let url = (event["url"] as? String) ?? ""
        let summary: String = {
            if let locator = (event["element"] as? [String: Any])?["locator"] as? String,
               !locator.isEmpty {
                return "\(actionType) \(locator)"
            }
            return actionType
        }()
        var entry: [String: Any] = [
            "idx": outcome.stepIndex,
            "step_dir": outcome.stepDirRelative,
            "action_type": actionType,
            "app": app,
            "summary": summary,
            "timestamp_ms": timestampMs,
            "source": "extension",
        ]
        if !url.isEmpty { entry["url"] = url }
        EventsJSONLWriter.append(to: recordingDir, entry: entry)
    }

    private static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [flow42-host pid=\(getpid())] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)

        // Chrome discards the host's stderr, so also append to a file the
        // user (or this debugger) can tail. ~/.flow42/native-host.log
        // grows append-only across all native-host invocations.
        let dir = URL(fileURLWithPath: Flow42Paths.root())
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let logPath = dir.appendingPathComponent("native-host.log").path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

// MARK: - Active-recording marker

public enum ActiveRecording {

    /// Read the active-recording marker, if any. Returns nil if no recording
    /// is currently active.
    public static func read() -> [String: Any]? {
        let url = markerURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Write the marker — called by `flow42 record` on start.
    /// `pid` is the recorder process id; `flow42 record stop` sends SIGTERM
    /// to that pid to trigger a clean shutdown.
    public static func set(slug: String, dir: String, pid: Int? = nil) throws {
        let url = markerURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var body: [String: Any] = ["slug": slug, "dir": dir]
        if let pid { body["pid"] = pid }
        let data = try JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted]
        )
        try data.write(to: url)
    }

    /// Clear the marker — called by `flow42 record` on stop.
    public static func clear() {
        try? FileManager.default.removeItem(at: markerURL())
    }

    private static func markerURL() -> URL {
        URL(fileURLWithPath: Flow42Paths.activeRecordingFile())
    }
}
