// Flow42Paths.swift - One source of truth for every path flow42 owns.
//
// Pre-v2 we sprinkled `~/.openclaw/flow42/...` literals across a dozen files;
// each call site spelled out its own `homeDirectoryForCurrentUser` +
// `.appendingPathComponent` chain. Renaming the parent dir to `~/.flow42/`
// (and `recipes/` → `flows/`) made it obvious that needed to live in one
// place.
//
// The contract: never compute a flow42 path inline in caller code. Either
// extend this enum with a named accessor, or take a path string from the
// caller (the recorder gets `recordingDir` injected at start time, etc.).
// `~/.openclaw/...` literals must not reappear.

import Foundation

public enum Flow42Paths {

    /// Root directory for everything flow42 owns on disk. Replaces the
    /// pre-v2 `~/.openclaw/flow42/`.
    public nonisolated static func root() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".flow42")
            .path
    }

    /// Parent directory for recorded flows. Replaces the pre-v2
    /// `~/.openclaw/flow42/recipes/`. A flow is one recorded session;
    /// the directory inside is the canonical home of its `meta.yaml`,
    /// `events.jsonl`, `steps/`, and (after structuring) `flow.yaml`.
    public nonisolated static func flowsRoot() -> String {
        (root() as NSString).appendingPathComponent("flows")
    }

    /// Directory for a specific flow by name. Slug/name is the leaf.
    public nonisolated static func flow(_ name: String) -> String {
        (flowsRoot() as NSString).appendingPathComponent(name)
    }

    /// `state.json` — the menu bar app's "what is flow42 doing right now?"
    /// view. Watched via FSEvents by `StateClient`.
    public nonisolated static func stateFile() -> String {
        (root() as NSString).appendingPathComponent("state.json")
    }

    /// `active-recording.json` — small marker the native messaging host
    /// (and other helpers) read to learn whether a recording is running
    /// and where its directory is.
    public nonisolated static func activeRecordingFile() -> String {
        (root() as NSString).appendingPathComponent("active-recording.json")
    }

    /// `browser-mode` — single-line file persisting the user's Chromium
    /// extension preference (`auto` / `extension` / `native`).
    public nonisolated static func browserModeFile() -> String {
        (root() as NSString).appendingPathComponent("browser-mode")
    }

    /// `.suppress-events` — marker the recorder checks before emitting an
    /// event; the menu app sets it during the annotation gesture so the
    /// recorder doesn't capture the Cmd+Shift+A keystroke or the rectangle
    /// drag's clicks as part of the recording.
    public nonisolated static func suppressEventsFile() -> String {
        (root() as NSString).appendingPathComponent(".suppress-events")
    }

    /// `menu.pid` — written at menu app launch for the single-instance lock.
    public nonisolated static func menuPidFile() -> String {
        (root() as NSString).appendingPathComponent("menu.pid")
    }

    /// `highlight-pending` — one-shot marker the menu app writes to ask
    /// the Chrome extension to enter highlight mode (the `Cmd+Shift+A` →
    /// extension handoff). Polled by `NativeHost` on each `active-recording`
    /// reply and consumed (deleted) when read.
    public nonisolated static func highlightPendingFile() -> String {
        (root() as NSString).appendingPathComponent("highlight-pending")
    }

    /// `highlight-exit` — the inverse: the menu app sets this to ask the
    /// extension to drop highlight mode (e.g. user pressed Esc, or
    /// switched to a non-Chromium app mid-annotation).
    public nonisolated static func highlightExitFile() -> String {
        (root() as NSString).appendingPathComponent("highlight-exit")
    }

    /// `models/` — directory for downloaded ML models (whisper, etc.).
    public nonisolated static func modelsDir() -> String {
        (root() as NSString).appendingPathComponent("models")
    }

    /// `logs/` — directory for daemon log output. Pre-v2 was
    /// `~/.openclaw/flow42/logs/`.
    public nonisolated static func logsDir() -> String {
        (root() as NSString).appendingPathComponent("logs")
    }

    /// `annotations/` — pre-v2 standalone annotations dir. Kept as an
    /// accessor for the (now slated for removal) `AnnotationStore` so the
    /// rename ships cleanly even though v2 folds annotations into the
    /// owning recording's `steps/` tree.
    public nonisolated static func legacyAnnotationsDir() -> String {
        (root() as NSString).appendingPathComponent("annotations")
    }
}
