// BrowserMode.swift - Toggle between extension-mediated and pure-native
// browser handling.
//
// flow42 grew up with a hybrid model: the Chrome extension owns in-page
// events while native AX owns browser chrome. That hybrid is great when the
// extension is installed and the dedicated debug profile is up, but it adds
// real setup friction (install unpacked extension, run setup-browser, deal
// with Chrome 136+'s --remote-debugging-port hardening). For users who just
// want flow42 to work on their everyday Chrome, "native everything" is
// often good enough.
//
// This module makes the choice explicit and runtime-switchable so users can
// A/B test the two paths against their real workflows.
//
// Resolution order at process start:
//   1. $FLOW42_BROWSER_MODE                  ("native" | "extension" | "auto")
//   2. ~/.flow42/browser-mode      (same values, one line)
//   3. .auto                                 (current default — defer to
//                                              extension when both extension
//                                              and native messaging are alive)
//
// The recorder daemon snapshots this once at start; flipping the env var
// mid-recording has no effect until the next `flow42 record start`.

import Foundation

public enum BrowserMode: String, Sendable {
    /// Hybrid: extension captures in-page events, native captures browser
    /// chrome. The historical default. Same as today.
    case auto
    /// Pure native: AX-driven recording for everything inside Chrome too.
    /// No extension required, no debug port, no dedicated profile.
    case native
    /// Strictly extension-only: native ignores in-page Chrome events, even
    /// if the extension isn't reachable. Useful for testing the extension
    /// path in isolation; you'll lose events when the extension is down.
    case `extension`

    /// Read the current process's mode from env / config / default.
    public nonisolated static func current() -> BrowserMode {
        if let raw = ProcessInfo.processInfo.environment["FLOW42_BROWSER_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let mode = BrowserMode(rawValue: raw) {
            return mode
        }
        let configPath = configFilePath()
        if let data = try? String(contentsOfFile: configPath, encoding: .utf8) {
            let raw = data.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let mode = BrowserMode(rawValue: raw) {
                return mode
            }
        }
        return .auto
    }

    /// Persist a mode to disk. The next `flow42 record start` will pick it
    /// up. Best-effort; ignores I/O errors.
    public static func setPersistent(_ mode: BrowserMode) {
        let path = configFilePath()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try? mode.rawValue.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private nonisolated static func configFilePath() -> String {
        Flow42Paths.browserModeFile()
    }
}
