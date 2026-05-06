// Structure.swift - `flow42 structure <flow-dir>` — paste-ready instruction
// for the agent's four-pass structuring flow.
//
// We don't drive Claude Code from inside flow42 — the agent loop lives
// elsewhere (Claude Code today, the future Flow app's terminal-mode session
// later). This subcommand exists so the user has a single ergonomic entry
// point that:
//
//   1. Validates the recording dir has the canonical layout
//      (events.jsonl + steps/).
//   2. Prints a paste-ready instruction the user hands to Claude Code:
//      "structure ~/.flow42/flows/<name>" — the flow-creator skill takes
//      it from there.
//
// The skill (Sources/Flow42Core/Resources/skills/flow-creator/SKILL.md) is
// self-contained — it owns the workflow, schema rules, and subagent
// fan-out templates. Nothing gets seeded into the recording dir.

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

        // Sanity-check the canonical layout.
        let eventsJsonl = (dir as NSString).appendingPathComponent("events.jsonl")
        let stepsDir = (dir as NSString).appendingPathComponent("steps")
        guard FileManager.default.fileExists(atPath: eventsJsonl) else {
            FileHandle.standardError.write(Data(
                "flow42 structure: \(dir) has no events.jsonl. Is this a flow42 recording?\n".utf8
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

        let stepCount = (try? FileManager.default.contentsOfDirectory(atPath: stepsDir))?.count ?? 0
        let lineCount = countJsonlLines(at: eventsJsonl)
        let flowYaml = (dir as NSString).appendingPathComponent("flow.yaml")
        let alreadyStructured = FileManager.default.fileExists(atPath: flowYaml)

        if jsonOnly {
            let payload: [String: Any] = [
                "flow_dir": dir,
                "events_count": lineCount,
                "steps_count": stepCount,
                "flow_yaml_exists": alreadyStructured,
                "next_step": "Open Claude Code in the recording dir and invoke the flow-creator skill.",
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

        print("flow42 structure: \(dir)")
        print("  events.jsonl: \(lineCount) lines")
        print("  steps/:       \(stepCount) folders")
        if alreadyStructured {
            print("  flow.yaml:    already exists (re-running will refine, not overwrite blindly)")
        } else {
            print("  flow.yaml:    not yet written")
        }
        print("")
        print("Four-pass structuring (run in Claude Code):")
        print("  1. Phase detection — read events.jsonl, draft phases.")
        print("  2. Param detection — find the inputs the flow needs to be re-run with different values.")
        print("  3. Strip noise + assemble GUI paths — fan out one subagent per phase.")
        print("  4. Headless alternatives — propose coarse swaps where genuinely cheaper.")
        print("")
        print("Next: open Claude Code with this directory in scope and say:")
        print("    structure this recording at \(dirArg)")
        print("")
        print("The flow-creator skill takes it from there. After it writes flow.yaml:")
        print("    flow42 view \(dirArg)                          # human-readable markdown")
        print("    flow42 view \(dirArg) --path osascript         # runnable script")
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

        Validate a recording and print a paste-ready instruction for the
        agent's four-pass structuring run.

        flow42 does NOT run the agent itself — it sets up the inputs.
        Open Claude Code in the recording dir to drive the structuring;
        the flow-creator skill owns the workflow.

        Options:
          --json     Emit a one-shot JSON status (no advisory prose). Useful
                     for the future Flow app's status pane.
          --help     Print this help and exit.
        """
        print(msg)
    }
}
