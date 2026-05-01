// Structure.swift - `flow42 structure <flow-dir>` — prepare a recording
// for the agent's three-pass structuring flow.
//
// We don't drive Claude Code from inside flow42 — the agent loop lives
// elsewhere (Claude Code today, the future Flow app's terminal-mode session
// later). This subcommand exists so the user has a single ergonomic entry
// point that:
//
//   1. Validates the recording dir has the v2 layout (events.jsonl + steps/).
//   2. Re-seeds the structuring prompts into <dir>/.agent/ in case they
//      drifted since `flow42 record start` (e.g. user upgraded flow42).
//   3. Prints a paste-ready instruction the user hands to Claude Code:
//      "structure ~/.flow42/flows/<name>", with a hint to read .agent/.
//
// When the Flow app lands, this same command becomes the in-app "structure
// recording" button — the app reads the same .agent/ prompts and pipes the
// recording dir to its account-linked Claude / Codex session.

import Flow42Core
import Foundation

enum Structure {

    static func run(args: [String]) {
        var dirArg: String? = nil
        var jsonOnly = false
        for a in args {
            switch a {
            case "--json": jsonOnly = true
            case "--help", "-h": printUsage(); return
            default:
                if !a.hasPrefix("-") && dirArg == nil { dirArg = a }
            }
        }

        guard let dirArg else {
            printUsage()
            FileHandle.standardError.write(Data("flow42 structure: missing flow directory\n".utf8))
            exit(2)
        }

        let dir = expandPath(dirArg)

        // 1. Sanity-check the v2 layout.
        let eventsJsonl = (dir as NSString).appendingPathComponent("events.jsonl")
        let stepsDir = (dir as NSString).appendingPathComponent("steps")
        guard FileManager.default.fileExists(atPath: eventsJsonl) else {
            FileHandle.standardError.write(Data(
                "flow42 structure: \(dir) has no events.jsonl. Is this a v2 recording?\n".utf8
            ))
            exit(1)
        }
        var isStepsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stepsDir, isDirectory: &isStepsDir),
              isStepsDir.boolValue
        else {
            FileHandle.standardError.write(Data(
                "flow42 structure: \(dir) has no steps/ directory.\n".utf8
            ))
            exit(1)
        }

        // 2. Re-seed prompts. The recorder seeds these on `record start` but
        // a flow42 upgrade between recording and structuring would leave the
        // user with stale prompts — re-seeding here is cheap insurance.
        let seeded: [String]
        do {
            seeded = try SeedPrompts.seed(into: dir)
        } catch {
            FileHandle.standardError.write(Data(
                "flow42 structure: could not seed prompts: \(error.localizedDescription)\n".utf8
            ))
            exit(1)
        }

        // 3. Surface the next-step instruction.
        let stepCount = (try? FileManager.default.contentsOfDirectory(atPath: stepsDir))?.count ?? 0
        let lineCount = countJsonlLines(at: eventsJsonl)

        if jsonOnly {
            let payload: [String: Any] = [
                "flow_dir": dir,
                "events_count": lineCount,
                "steps_count": stepCount,
                "seeded": seeded,
                "next_step": "Open Claude Code in the recording dir and ask it to read .agent/clarify-prompt.md.",
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print("flow42 structure prepared \(dir)")
        print("  events.jsonl: \(lineCount) lines")
        print("  steps/:       \(stepCount) folders")
        print("  prompts:      \(seeded.count) seeded into .agent/")
        print("")
        print("Three-pass structuring (run in Claude Code):")
        print("  1. Phase detection — read events.jsonl, draft phases.")
        print("  2. Assemble GUI path — walk step folders, keep the recording faithful.")
        print("  3. Headless alternatives — propose coarse swaps (shell > osascript > MCP).")
        print("")
        print("Next: open Claude Code in this directory and say:")
        print("    structure this recording — read .agent/clarify-prompt.md, then write flow.yaml")
        print("")
        print("After the agent writes flow.yaml:")
        print("    flow42 view \(dirArg)            # human-readable markdown")
        print("    flow42 view \(dirArg) --path osascript > replay.scpt")
    }

    private static func countJsonlLines(at path: String) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let s = String(data: data, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static func expandPath(_ p: String) -> String {
        if p.hasPrefix("~") { return NSString(string: p).expandingTildeInPath }
        return p
    }

    private static func printUsage() {
        let msg = """
        Usage: flow42 structure <flow-dir> [--json]

        Prepare a recorded flow for the agent's three-pass structuring run.

        What it does:
          1. Validates the recording has the v2 layout (events.jsonl + steps/).
          2. Re-seeds .agent/ prompts (in case flow42 was upgraded since
             the recording was made).
          3. Prints a paste-ready instruction for Claude Code.

        flow42 does NOT run the agent itself — it sets up the inputs.
        Open Claude Code in the recording dir to drive the structuring.

        Options:
          --json     Emit a one-shot JSON status (no advisory prose). Useful
                     for the future Flow app's status pane.
          --help     Print this help and exit.
        """
        print(msg)
    }
}
