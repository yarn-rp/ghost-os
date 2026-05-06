// FlowMarkdownRenderer.swift - Render flow.yaml as a human-friendly Markdown
// story (or a runnable script for a single path kind).
//
// Lives in Flow42Core because two surfaces consume the output:
//
//   1. `flow42 view <flow-dir>` — the CLI verb (Sources/flow42/View.swift)
//      writes this to stdout / `--output`.
//   2. Flow42App's FlowDetailView — the SwiftUI window app renders the same
//      Markdown as a Medium-style story page.
//
// Single source of truth: the same string the user reads in the app is the
// content the agent gets when a per-flow skill is installed at
// `~/.claude/skills/flow-<slug>/SKILL.md`. No drift between "story view"
// and "skill content".
//
// Pure function: takes a flow directory + optional path kind, returns a
// String. No I/O beyond reading flow.yaml; no side effects.

import Foundation
import Yams

/// Pure-function renderer. `nonisolated` so it can be called from any
/// actor (the SwiftUI side runs it off the main actor inside a
/// `Task.detached` to avoid blocking the UI on large flows).
public nonisolated enum FlowMarkdownRenderer {

    public enum RendererError: Error, CustomStringConvertible {
        case missingFlowYaml(path: String)
        case unreadableFlowYaml(path: String, underlying: Error)
        case invalidYaml(path: String, underlying: Error)
        case malformedTopLevel

        public var description: String {
            switch self {
            case .missingFlowYaml(let path):
                return "no flow.yaml at \(path) (run `flow42 structure` to generate one)"
            case .unreadableFlowYaml(let path, let err):
                return "could not read \(path): \(err.localizedDescription)"
            case .invalidYaml(let path, let err):
                return "invalid YAML at \(path): \(err.localizedDescription)"
            case .malformedTopLevel:
                return "flow.yaml top-level must be a mapping"
            }
        }
    }

    /// Render a flow.yaml as Markdown.
    /// - Parameters:
    ///   - flowDir: Absolute path to the flow directory containing flow.yaml.
    ///   - pathKind: nil → human-friendly view (default).
    ///               "osascript" / "shell" / "mcp" / etc → script-only view
    ///               that emits just commands of the given kind across all
    ///               phases, intended for piping into a runnable script.
    /// - Returns: The Markdown string.
    public static func render(flowDir: String, pathKind: String? = nil) throws -> String {
        let flowYamlPath = (flowDir as NSString).appendingPathComponent("flow.yaml")
        guard FileManager.default.fileExists(atPath: flowYamlPath) else {
            throw RendererError.missingFlowYaml(path: flowYamlPath)
        }
        let yamlString: String
        do {
            yamlString = try String(contentsOf: URL(fileURLWithPath: flowYamlPath), encoding: .utf8)
        } catch {
            throw RendererError.unreadableFlowYaml(path: flowYamlPath, underlying: error)
        }
        let parsed: Any?
        do {
            parsed = try Yams.load(yaml: yamlString)
        } catch {
            throw RendererError.invalidYaml(path: flowYamlPath, underlying: error)
        }
        guard let flow = parsed as? [String: Any] else {
            throw RendererError.malformedTopLevel
        }
        if let pathKind {
            return renderScriptOnly(flow: flow, kind: pathKind)
        }
        return renderHumanView(flow: flow, dir: flowDir)
    }

    // MARK: - Human-friendly view

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

        // Params table — shown right after the metadata. Each phase's prose
        // and step text references these by ${name}; the table tells the
        // reader what those placeholders stand for and what was used in the
        // original recording.
        if let params = flow["params"] as? [[String: Any]], !params.isEmpty {
            out += "## Parameters\n\n"
            out += "| Name | Type | Description | Recorded value |\n"
            out += "|---|---|---|---|\n"
            for p in params {
                let n = (p["name"] as? String) ?? ""
                let t = (p["type"] as? String) ?? "string"
                let d = (p["description"] as? String) ?? ""
                let e = (p["example"] as? String) ?? ""
                out += "| `\(n)` | `\(t)` | \(escapeCell(d)) | `\(escapeCell(e))` |\n"
            }
            out += "\n"
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

        // Phase-level note: render as a 📝 blockquote callout so it reads as
        // guidance, not as the phase's main intent. Multi-line notes survive
        // by quoting each line with `>`.
        if let note = phase["note"] as? String {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out += "> 📝 **Note**\n>\n"
                for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
                    out += "> \(String(line))\n"
                }
                out += "\n"
            }
        }

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
            // text may be one line (the common case) or a short paragraph
            // when the step needs brittleness / autocomplete / alt-name
            // guidance. Either way the first line gets the `**N.**` marker;
            // subsequent lines render as a normal indented paragraph so the
            // markdown stays readable.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let first = lines.first {
                out += "**\(n).** \(first)\n"
                for extra in lines.dropFirst() where !extra.isEmpty {
                    out += "    \(extra)\n"
                }
                out += "\n"
            }
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

    // MARK: - Script-only view

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
            // Find the first path of the requested kind. If none exists for
            // this phase, leave a comment marker so the user / agent sees the
            // gap rather than silently skipping.
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

    /// Pipe-character + newline escaping for markdown table cells.
    /// Keeps multi-line strings on one logical row; pipe chars would
    /// break the table layout.
    private static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "|", with: "\\|")
    }
}
