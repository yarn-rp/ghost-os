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
