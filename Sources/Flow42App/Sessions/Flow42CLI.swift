// Flow42CLI.swift - Locate the `flow42` binary at runtime.
//
// Mirrors Flow42Menu's helper of the same name (which lives there
// because the menu app needed it first; not exported, hence the small
// duplication here).
//
// Search order:
//   1. Sibling of the running executable — covers the dev workflow
//      (Flow42App and flow42 both built into .build/.../debug/).
//   2. PATH (with the macOS-typical install dirs that GUI apps don't
//      inherit from launchd).

import Foundation

enum Flow42CLI {
    static func binaryPath() -> String? {
        // Sibling to our own binary in dev builds.
        let exe = ProcessInfo.processInfo.arguments.first
            ?? Bundle.main.bundleURL.appendingPathComponent("flow42").path
        let dir = (exe as NSString).deletingLastPathComponent
        let sibling = (dir as NSString).appendingPathComponent("flow42")
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }

        // PATH fallback. Augmented with the install dirs GUI-launched apps
        // don't see by default (launchd doesn't read shell profiles).
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for extra in [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            "\(NSHomeDirectory())/.local/bin",
        ] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        for d in dirs {
            let candidate = (d as NSString).appendingPathComponent("flow42")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
