// HighlightRequest.swift - One-shot trigger from the menu app to the
// Chrome extension's highlight mode.
//
// When the user presses Cmd+Shift+A while Chrome is frontmost in extension
// or auto mode, we want the extension's hover-and-click highlight UX (which
// produces a Playwright locator) instead of the macOS region overlay (which
// produces a screenshot + AX subtree).
//
// Process boundary: the menu app and the native messaging host run in
// separate processes. The host is invoked once per extension connection,
// not per request. We bridge via a marker file:
//
//   1. Menu app writes ~/.openclaw/flow42/highlight-pending
//   2. Host, on the extension's next `active-recording` poll, checks for
//      the marker; if present it signals `highlight_request: true` in the
//      reply and removes the marker (one-shot semantics).
//   3. Background script forwards RECORDER_ENTER_HIGHLIGHT_MODE to every
//      recording tab.
//
// Latency: bounded by the extension's poll interval (currently 2s). Good
// enough for an annotation hotkey; if it bites, we'll add an FSEvents
// watcher to the host so it pushes immediately.

import Foundation

public enum HighlightRequest {

    public nonisolated static func path() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent("highlight-pending")
            .path
    }

    public nonisolated static func exists() -> Bool {
        FileManager.default.fileExists(atPath: path())
    }
    public nonisolated static func arm() {
        writeMarker(at: path())
    }
    public nonisolated static func consume() -> Bool {
        consumeMarker(at: path())
    }
}

/// Companion to HighlightRequest — tells the extension to leave highlight
/// mode (e.g. when the user switches apps mid-annotation; the menu app
/// hands the gesture off to the macOS overlay). Same marker-file plumbing.
public enum HighlightExit {

    public nonisolated static func path() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent("highlight-exit")
            .path
    }

    public nonisolated static func arm() {
        writeMarker(at: path())
    }
    public nonisolated static func consume() -> Bool {
        consumeMarker(at: path())
    }
}

// MARK: - Shared marker-file primitives

private nonisolated func writeMarker(at p: String) {
    let dir = (p as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: p, contents: Data())
}

private nonisolated func consumeMarker(at p: String) -> Bool {
    if !FileManager.default.fileExists(atPath: p) { return false }
    try? FileManager.default.removeItem(atPath: p)
    return true
}
