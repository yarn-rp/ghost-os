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
// The recording-active state lives in ~/.openclaw/flow42/active-recording.json
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
                let payload: [String: Any] = [
                    "type": "active-recording",
                    "recording": ActiveRecording.read() as Any? ?? NSNull(),
                ]
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

    private static func handleDomEvent(_ frame: [String: Any]) {
        guard let recordingSlug = frame["recording"] as? String else { return }
        guard let event = frame["event"] else { return }

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
        let line = "[flow42-host] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
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
    public static func set(slug: String, dir: String) throws {
        let url = markerURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body: [String: Any] = ["slug": slug, "dir": dir]
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent("active-recording.json")
    }
}
