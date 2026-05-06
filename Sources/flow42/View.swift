// View.swift - `flow42 view <flow-dir>` — thin CLI wrapper around the
// shared FlowMarkdownRenderer in Flow42Core.
//
// The actual rendering logic lives in Flow42Core/Plays/FlowMarkdownRenderer.swift
// so Flow42App can call the same code to render flow detail pages —
// keeping the story view (what the user reads in the app) and the skill
// content (what gets written to ~/.claude/skills/flow-<slug>/SKILL.md) as
// the SAME string. No drift, one renderer.
//
// Two render modes via `--path`:
//   default        Lead with the GUI path: text + screenshots, drop the
//                  replicate command into a collapsible details block.
//                  Headless alternatives are listed below as "or, headless:"
//                  sections.
//   <kind>         Pull only the path of that kind (e.g. `--path osascript`)
//                  and emit a runnable script with phase intents as comments.
//                  Useful for handing the agent a single end-to-end script.

import Flow42Core
import Foundation

enum View {

    static func run(args: [String]) {
        var dirArg: String? = nil
        var pathKind: String? = nil
        var outputPath: String? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--path", "-p":
                if i + 1 < args.count { pathKind = args[i + 1]; i += 1 }
            case "--output", "-o":
                if i + 1 < args.count { outputPath = args[i + 1]; i += 1 }
            case "--help", "-h":
                printUsage(); return
            default:
                if !a.hasPrefix("-") && dirArg == nil { dirArg = a }
            }
            i += 1
        }

        guard let dirArg else {
            printUsage()
            FileHandle.standardError.write(Data("flow42 view: missing flow directory\n".utf8))
            exit(2)
        }

        let dir = expandPath(dirArg)
        let markdown: String
        do {
            markdown = try FlowMarkdownRenderer.render(flowDir: dir, pathKind: pathKind)
        } catch {
            FileHandle.standardError.write(Data("flow42 view: \(error)\n".utf8))
            exit(1)
        }

        if let outputPath {
            do {
                try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
                print("wrote \(outputPath) (\(markdown.count) bytes)")
            } catch {
                FileHandle.standardError.write(Data("flow42 view: write failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        } else {
            print(markdown)
        }
    }

    // MARK: - Helpers

    private static func expandPath(_ p: String) -> String {
        if p.hasPrefix("~") { return NSString(string: p).expandingTildeInPath }
        return p
    }

    private static func printUsage() {
        let msg = """
        Usage: flow42 view <flow-dir> [--path <kind>] [--output <file>]

        Render a recorded flow's flow.yaml as markdown.

        Arguments:
          <flow-dir>           Path to the flow directory. Tilde-expanded.

        Options:
          --path, -p <kind>    Emit only the chosen path kind across all
                               phases (osascript, shell, mcp, cli, …).
                               Output is a runnable script with phase
                               intents as comments. Default: render the
                               full human view.
          --output, -o <file>  Write to <file> instead of stdout.
          --help, -h           Print this help and exit.

        Examples:
          flow42 view ~/.flow42/flows/send-status-email-to-team
          flow42 view ./recording-20260501-153011 --path osascript -o replay.scpt
        """
        print(msg)
    }
}
