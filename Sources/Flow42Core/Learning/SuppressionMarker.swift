// SuppressionMarker.swift - Cross-process flag that pauses event capture.
//
// File presence at ~/.openclaw/flow42/.suppress-events tells the recorder
// daemon to drop every native event. Used right now by the Flow42 menu app's
// annotation overlay: while the user is dragging a rectangle, the Cmd+Shift+A
// keystroke and the mouse-down/up that define the rect would otherwise be
// recorded as native events alongside the eventual `highlight` event. They're
// recording mechanics, not the flow.
//
// File-based instead of an in-memory flag because the recorder daemon and the
// menu app are separate processes. Cheap: stat() of a known path is a few
// microseconds, fine to check per CGEvent.

import Foundation

public enum SuppressionMarker {

    /// Resolved path — computed nonisolated so the recorder thread can read
    /// it without an actor hop on every event.
    public nonisolated static func path() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent(".suppress-events")
            .path
    }

    /// Cheap presence check. FileManager.fileExists is a stat under the hood
    /// — a few microseconds, well within budget for the per-event check.
    public nonisolated static func exists() -> Bool {
        FileManager.default.fileExists(atPath: path())
    }

    /// Create the marker file (touch + mkdir parents). Best-effort.
    public nonisolated static func arm() {
        let p = path()
        let dir = (p as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: p, contents: Data())
    }

    /// Remove the marker file. Best-effort; missing-file is fine.
    public nonisolated static func disarm() {
        try? FileManager.default.removeItem(atPath: path())
    }
}
