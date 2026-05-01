// View.swift - `flow42 view <flow-dir>` — deterministic markdown renderer.
//
// Reads the agent-authored flow.yaml and emits a markdown view to stdout (or
// `--output`). NO LLM at render time: a phase's first path is always the
// canonical GUI replay, subsequent paths are coarser headless swaps; we just
// walk and stringify.
//
// Two render modes via `--path`:
//   default        Lead with the GUI path: text + screenshots, drop the
//                  replicate command into a collapsible details block.
//                  Headless alternatives are listed below the GUI steps as
//                  "if you'd rather, …" sections.
//   <kind>         Pull only the path of that kind (e.g. `--path osascript`)
//                  and emit a runnable script with phase intents as comments.
//                  Useful for handing the agent a single end-to-end script.
//
// flow.yaml itself is parsed by Yams. We never write YAML here — the renderer
// only reads. The recorder writes per-step meta.yaml via Flow42Core/YAMLEmit;
// flow.yaml is written by the agent.

import Flow42Core
import Foundation
import Yams

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
        let flowYamlPath = (dir as NSString).appendingPathComponent("flow.yaml")
        guard FileManager.default.fileExists(atPath: flowYamlPath) else {
            FileHandle.standardError.write(Data(
                "flow42 view: no flow.yaml at \(flowYamlPath)\nRun `flow42 structure \(dirArg)` first to generate one.\n".utf8
            ))
            exit(1)
        }

        let yamlString: String
        do {
            yamlString = try String(contentsOf: URL(fileURLWithPath: flowYamlPath), encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("flow42 view: could not read flow.yaml: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let parsed: Any?
        do {
            parsed = try Yams.load(yaml: yamlString)
        } catch {
            FileHandle.standardError.write(Data("flow42 view: invalid YAML: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        guard let flow = parsed as? [String: Any] else {
            FileHandle.standardError.write(Data("flow42 view: flow.yaml top-level must be a mapping\n".utf8))
            exit(1)
        }

        let markdown = render(flow: flow, dir: dir, pathKind: pathKind)

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

    // MARK: - Render

    /// Top-level renderer. Branches on `pathKind`: nil → human-friendly view
    /// with GUI steps + alternatives; "osascript"/"shell"/etc → runnable
    /// script of just that kind across all phases.
    private static func render(flow: [String: Any], dir: String, pathKind: String?) -> String {
        if let pathKind {
            return renderScriptOnly(flow: flow, kind: pathKind)
        }
        return renderHumanView(flow: flow, dir: dir)
    }

    /// Default view. Reads top-down, leads with the GUI path, demotes
    /// alternatives to "or, headless:" subsections per phase.
    private static func renderHumanView(flow: [String: Any], dir: String) -> String {
        var out = ""

        let name = (flow["name"] as? String) ?? "(unnamed)"
        let task = (flow["task_description"] as? String) ?? ""
        out += "# \(name)\n\n"
        if !task.isEmpty {
            out += "> \(task)\n\n"
        }
        if let recordedAt = flow["recorded_at"] as? String {
            out += "_Recorded \(recordedAt)_"
            if let dur = flow["duration_seconds"] as? Int {
                out += " · \(dur)s"
            }
            out += "\n\n"
        }

        let phases = (flow["phases"] as? [[String: Any]]) ?? []
        for (i, phase) in phases.enumerated() {
            out += renderPhase(phase, ordinal: i + 1)
        }
        return out
    }

    private static func renderPhase(_ phase: [String: Any], ordinal: Int) -> String {
        var out = ""
        let phaseName = (phase["name"] as? String) ?? "phase_\(ordinal)"
        let intent = (phase["intent"] as? String) ?? ""
        out += "## \(ordinal). \(phaseName.replacingOccurrences(of: "_", with: " "))\n\n"
        if !intent.isEmpty { out += "**\(intent)**\n\n" }

        if let pre = phase["precondition"] as? String, !pre.isEmpty {
            out += "_Precondition_: \(pre)\n\n"
        }
        if let post = phase["postcondition"] as? String, !post.isEmpty {
            out += "_Postcondition_: \(post)\n\n"
        }

        let paths = (phase["paths"] as? [[String: Any]]) ?? []
        guard !paths.isEmpty else {
            out += "_(No paths recorded for this phase.)_\n\n"
            return out
        }

        // First path: GUI by convention. Lead with it.
        let primary = paths[0]
        out += renderGuiPath(primary)

        // Subsequent paths: cheaper alternatives. List them under
        // "Headless alternatives" with their descriptions + commands.
        let alternatives = Array(paths.dropFirst())
        if !alternatives.isEmpty {
            out += "**Or, headless:**\n\n"
            for alt in alternatives {
                out += renderAlternativePath(alt)
            }
        }

        return out
    }

    private static func renderGuiPath(_ path: [String: Any]) -> String {
        var out = ""
        if let desc = path["description"] as? String, !desc.isEmpty {
            out += "\(desc)\n\n"
        }
        let steps = (path["steps"] as? [[String: Any]]) ?? []
        for (i, step) in steps.enumerated() {
            let n = i + 1
            let text = (step["text"] as? String) ?? "_(step \(n))_"
            out += "**\(n).** \(text)\n\n"
            if let shot = step["screenshot"] as? String, !shot.isEmpty {
                out += "![step \(n)](\(shot))\n\n"
            }
            if let replicate = step["replicate"] as? String, !replicate.isEmpty {
                out += "<details><summary>Headless replay</summary>\n\n"
                out += "```sh\n\(replicate)\n```\n\n"
                out += "</details>\n\n"
            }
        }
        return out
    }

    private static func renderAlternativePath(_ path: [String: Any]) -> String {
        var out = ""
        let kind = (path["kind"] as? String) ?? "alt"
        let desc = (path["description"] as? String) ?? ""
        let cmd = (path["command"] as? String) ?? ""
        out += "- **\(kind)**"
        if !desc.isEmpty { out += " — \(desc)" }
        out += "\n\n"
        if !cmd.isEmpty {
            out += "  ```\(kind == "osascript" ? "applescript" : "sh")\n"
            // Indent the command 2 spaces so it stays inside the bullet.
            for line in cmd.split(separator: "\n", omittingEmptySubsequences: false) {
                out += "  \(String(line))\n"
            }
            out += "  ```\n\n"
        }
        return out
    }

    /// Script-only view: emit the chosen path's commands across all phases,
    /// concatenated in order. Phase intents become comments. Useful for
    /// `flow42 view <dir> --path osascript > replay.scpt`.
    private static func renderScriptOnly(flow: [String: Any], kind: String) -> String {
        var out = ""
        let commentMarker: String = {
            switch kind {
            case "osascript", "applescript": return "--"
            default: return "#"  // shell-style for shell, mcp, cli, etc.
            }
        }()

        let phases = (flow["phases"] as? [[String: Any]]) ?? []
        var emitted = 0
        for (i, phase) in phases.enumerated() {
            let phaseName = (phase["name"] as? String) ?? "phase_\(i + 1)"
            let intent = (phase["intent"] as? String) ?? ""
            let paths = (phase["paths"] as? [[String: Any]]) ?? []
            // Find the first path of the requested kind. If none exists
            // for this phase, leave a comment marker so the user / agent
            // sees the gap rather than silently skipping.
            let match = paths.first { ($0["kind"] as? String) == kind }
            out += "\(commentMarker) \(i + 1). \(phaseName)\n"
            if !intent.isEmpty { out += "\(commentMarker)    \(intent)\n" }
            if let match {
                if let cmd = match["command"] as? String, !cmd.isEmpty {
                    out += cmd
                    if !cmd.hasSuffix("\n") { out += "\n" }
                    emitted += 1
                } else {
                    out += "\(commentMarker)    (path of kind '\(kind)' had no command)\n"
                }
            } else {
                out += "\(commentMarker)    [no '\(kind)' path for this phase — fall back to GUI replay]\n"
            }
            out += "\n"
        }
        if emitted == 0 {
            out += "\(commentMarker) (no phases had a '\(kind)' alternative — all are GUI-only)\n"
        }
        return out
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
