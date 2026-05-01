// Mode.swift - `flow42 mode get/set` CLI subcommand.
//
// Atomically reads/writes ~/.flow42/state.json. The Flow42 menu bar
// app watches this file via FSEvents and updates the screen-edge glow + status
// icon based on the current mode.
//
// Three modes only:
//   idle         no recording, no agent driving
//   recording    a `flow42 record start` daemon is alive
//   autonomous   an agent has announced "I'm driving" so the user sees a
//                visible signal while the screen is being clicked/typed at
//
// `Record.swift` writes mode=recording at start and mode=idle at stop on its
// own; agents flip autonomous on/off via `flow42 mode set autonomous --label X`.

import Flow42Core
import Foundation

enum Mode {

    static func run(args: [String]) {
        guard let sub = args.first else {
            printUsage()
            exit(1)
        }
        switch sub {
        case "get":
            runGet()
        case "set":
            runSet(args: Array(args.dropFirst()))
        case "browser":
            runBrowser(args: Array(args.dropFirst()))
        case "help", "-h", "--help":
            printUsage()
        default:
            FileHandle.standardError.write(Data("unknown subcommand: \(sub)\n".utf8))
            printUsage()
            exit(1)
        }
    }

    /// `flow42 mode browser get | set <auto|native|extension>` — controls
    /// whether the recorder defers in-page Chrome events to the extension
    /// or captures everything natively. Persists to
    /// ~/.flow42/browser-mode and is read by every subsequent
    /// `flow42 record start`.
    private static func runBrowser(args: [String]) {
        guard let sub = args.first else {
            emitJSON([
                "success": true,
                "browser_mode": BrowserMode.current().rawValue,
            ])
            return
        }
        switch sub {
        case "get":
            emitJSON([
                "success": true,
                "browser_mode": BrowserMode.current().rawValue,
            ])
        case "set":
            guard let raw = args.dropFirst().first,
                  let mode = BrowserMode(rawValue: raw.lowercased()) else {
                emitJSON([
                    "success": false,
                    "error": "expected one of: auto, native, extension",
                ])
                exit(1)
            }
            BrowserMode.setPersistent(mode)
            emitJSON([
                "success": true,
                "browser_mode": mode.rawValue,
                "note": "applied to subsequent `flow42 record start` invocations",
            ])
        default:
            FileHandle.standardError.write(Data("unknown browser subcommand: \(sub)\n".utf8))
            exit(1)
        }
    }

    private static func runGet() {
        var dict: [String: Any] = ["success": true]
        dict.merge(StateFile.readAsDict()) { _, new in new }
        emitJSON(dict)
    }

    private static func runSet(args: [String]) {
        guard let modeName = args.first,
              let mode = AppMode(rawValue: modeName) else {
            emitJSON([
                "success": false,
                "error": "expected mode argument: idle | recording | autonomous",
            ])
            exit(1)
        }
        let f = parseSimple(Array(args.dropFirst()))
        let label = f.string("label")

        // For `recording` we don't have slug/dir/pid here — that's the
        // daemon's job. Allow setting `recording` with no info for parity, but
        // expect Record.swift's daemon to overwrite with full info.
        let state: AppState
        switch mode {
        case .idle:
            state = AppState(mode: .idle, label: label)
        case .recording:
            state = AppState(mode: .recording, label: label)
        case .autonomous:
            let info = AppState.AutonomousInfo(
                label: label ?? "running",
                startedBy: f.string("by") ?? "agent"
            )
            state = AppState(mode: .autonomous, label: label, autonomous: info)
        }

        do {
            try StateFile.write(state)
            var dict: [String: Any] = ["success": true]
            dict.merge(StateFile.readAsDict()) { _, new in new }
            emitJSON(dict)
        } catch {
            emitJSON([
                "success": false,
                "error": "failed to write state.json: \(error.localizedDescription)",
                "path": StateFile.path(),
            ])
            exit(1)
        }
    }

    private static func printUsage() {
        let usage = """
        Usage:
          flow42 mode get
          flow42 mode set <idle|recording|autonomous> [--label "..."] [--by agent]
          flow42 mode browser get
          flow42 mode browser set <auto|native|extension>

        The Flow42 menu bar app watches ~/.flow42/state.json and
        renders the screen-edge glow accordingly:
          recording  → magenta
          autonomous → orange
          idle       → no glow

        `mode browser` controls how Chrome is recorded:
          auto       → extension captures in-page events, native captures chrome
          native     → native captures everything (no extension required)
          extension  → strict; native ignores in-page Chrome events even when
                       the extension is unreachable
        """
        print(usage)
    }
}
