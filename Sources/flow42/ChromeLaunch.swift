// ChromeLaunch.swift - `flow42 chrome-launch` helper.
//
// Launches Google Chrome with a local debug endpoint enabled so that
// `flow42 act --target browser <verb>` can attach.
//
// IMPORTANT: Chrome 136+ silently disables --remote-debugging-port when
// --user-data-dir points at the default profile (a security hardening
// against malicious extensions snooping over CDP). We work around this
// by ALWAYS using a dedicated user-data-dir at
// ~/Library/Application Support/flow42-chrome/. That profile is separate
// from the user's normal Chrome — they install the flow42 DOM-sidecar
// extension into it once, log into whatever sites they need, and leave
// it. Subsequent `flow42 chrome-launch` invocations reuse the same dir.

import AppKit
import Foundation

enum ChromeLaunch {

    static let defaultPort = 9222
    static let chromeApp = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    /// Deterministic extension id derived from the `key` field embedded in
    /// public/manifest.json. As long as that key field is unchanged, every
    /// install of the unpacked extension gets this same id — meaning the
    /// native-messaging manifest stays valid forever.
    static let extensionId = "hhlhfpnngoonnimpgbccgcogcanibkkg"

    static func run(args: [String]) {
        let port = parseInt(args, "--port") ?? defaultPort
        let userDataDir = parseString(args, "--user-data-dir")
            ?? defaultUserDataDir()
        let extensionPath = parseString(args, "--load-extension")
            ?? repoExtensionDist()

        guard FileManager.default.isExecutableFile(atPath: chromeApp) else {
            fputs("error: Google Chrome not found at \(chromeApp)\n", stderr)
            exit(1)
        }

        try? FileManager.default.createDirectory(
            atPath: userDataDir, withIntermediateDirectories: true
        )

        let task = Process()
        task.executableURL = URL(fileURLWithPath: chromeApp)
        var argv = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(userDataDir)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        // Auto-load our extension at launch. Chrome 138+ requires an
        // explicit feature toggle to allow --load-extension, otherwise the
        // flag is silently ignored.
        if FileManager.default.fileExists(atPath: extensionPath) {
            argv.append("--load-extension=\(extensionPath)")
            argv.append("--disable-features=DisableLoadExtensionCommandLineSwitch")
        }
        task.arguments = argv
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            print("Chrome launched on port \(port).")
            print("Profile: \(userDataDir)")
            if FileManager.default.fileExists(atPath: extensionPath) {
                print("Extension auto-loaded from: \(extensionPath)")
                print("Extension ID: \(extensionId) (deterministic; pinned via manifest key)")
            } else {
                print("⚠️  Extension dist/ not found at \(extensionPath) — load it manually via chrome://extensions.")
            }
        } catch {
            fputs("error: failed to launch Chrome: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func defaultUserDataDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("flow42-chrome")
            .path
    }

    static func repoExtensionDist() -> String {
        // Best-effort: walk up from the binary to find a sibling dist/.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<8 {
            for parent in [dir.deletingLastPathComponent(), dir] {
                let candidate = parent.appendingPathComponent("dist")
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate.path
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return "<repo>/dist"
    }

    private static func parseInt(_ args: [String], _ flag: String) -> Int? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }
    private static func parseString(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
