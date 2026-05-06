// PerFlowSkillWriter.swift - Materialise a per-flow skill at
// `~/.claude/skills/flow-<slug>/SKILL.md`.
//
// The mental model the user described: "we inject the skill to the agent,
// just like install-skills does." When the user clicks Run autonomously,
// the agent picks up TWO layers of injected knowledge:
//
//   1. Baseline skills — flow42-cli, flow-creator, flow-recorder
//      (already installed by `flow42 install-skills`). Teach the agent
//      how to use the flow42 CLI in general.
//   2. Per-flow skill — NEW. Each recorded flow becomes its own skill
//      whose content is the same Markdown `flow42 view` produces.
//
// Because the SKILL.md content IS the story view, there's only one source
// of truth. What the user reads in Flow42App is what the agent reads when
// it follows the skill — they can't drift apart.
//
// The skill is regenerated lazily: if it's missing, write it; if it
// exists, leave it alone. The user can `flow42 install-skills --update`
// (or delete + re-run autonomously) to refresh.

import Flow42Core
import Foundation

enum PerFlowSkillWriter {

    /// Skill name on disk. Prefixed with `flow-` so it sorts together
    /// with other flow skills and doesn't collide with the baseline
    /// flow42-cli / flow-recorder / flow-creator entries.
    static func skillName(forFlowSlug slug: String) -> String {
        "flow-\(slug)"
    }

    /// Absolute path the skill lives at — `~/.claude/skills/flow-<slug>/`.
    static func skillDirectory(forFlowSlug slug: String) -> URL {
        skillsRoot().appendingPathComponent(skillName(forFlowSlug: slug))
    }

    /// Generate (or regenerate) the per-flow skill. Returns the path of
    /// the SKILL.md that was written.
    /// - Parameters:
    ///   - flow: The flow to install.
    ///   - overwrite: If true, replace an existing SKILL.md. Default false.
    @discardableResult
    static func install(flow: FlowSummary, overwrite: Bool = false) throws -> URL {
        let dir = skillDirectory(forFlowSlug: flow.id)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        let skillFile = dir.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: skillFile.path), !overwrite {
            return skillFile
        }

        let body = try renderSkillBody(flow: flow)
        try body.write(to: skillFile, atomically: true, encoding: .utf8)
        return skillFile
    }

    /// Convenience: only install if missing. Returns the skill URL either
    /// way (already-existing or newly-written) so callers can reference it.
    @discardableResult
    static func installIfMissing(flow: FlowSummary) throws -> URL {
        let dir = skillDirectory(forFlowSlug: flow.id)
        let skillFile = dir.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: skillFile.path) {
            return skillFile
        }
        return try install(flow: flow, overwrite: false)
    }

    /// Has a per-flow skill already been generated?
    static func isInstalled(flow: FlowSummary) -> Bool {
        let path = skillDirectory(forFlowSlug: flow.id)
            .appendingPathComponent("SKILL.md").path
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Render

    /// The skill body. Front-matter (`name`, `description`) followed by
    /// the same Markdown the user reads in Flow42App's story view. The
    /// description is what Claude's skill resolver uses to decide whether
    /// to load the skill — short and intent-focused works best.
    private static func renderSkillBody(flow: FlowSummary) throws -> String {
        let storyMarkdown = try FlowMarkdownRenderer.render(flowDir: flow.directory)

        let description = (flow.taskDescription ?? "Run the recorded flow `\(flow.displayName)`.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Single-line for the YAML front-matter description field.
            .replacingOccurrences(of: "\n", with: " ")

        var out = ""
        out += "---\n"
        out += "name: \(skillName(forFlowSlug: flow.id))\n"
        out += "description: |\n  \(description)\n"
        out += "---\n\n"

        // The "how to run" section. Two contexts to support:
        //
        //   1. Flow42App's autonomous run: spawned with prompt
        //      "Run the <skill> skill". Clear intent — execute now.
        //   2. Standalone use: user typed something like "tell me about
        //      the X flow" or "use the X skill to do Y" in their own
        //      terminal. May or may not want execution.
        //
        // The instructions are framed as conditional ("when the user
        // asks for it") so the agent doesn't auto-fire on any mention.
        // Step 2 also tolerates a pre-started play — Flow42App doesn't
        // pre-start today, but if a future revision does, the skill
        // stays correct: the singleton-active error becomes a fall-
        // through to step 4 instead of an exception.
        let dirEscaped = flow.directory.replacingOccurrences(of: "\"", with: "\\\"")
        let hasParams = (flow.taskDescription != nil) // params get listed in the body table; we hint at them here
        out += "## How to run this flow when the user asks for it\n\n"
        out += "Only execute this section when the user's intent is to RUN the flow (e.g. \"run it\", \"play this flow\", \"execute X\", or you were spawned with \"Run the … skill\"). If they're asking what it does or how it works, just answer from the body above; don't touch the screen.\n\n"
        out += "When you're running it:\n\n"
        out += "1. **Collect parameters from the user via chat.** The parameters table in the body lists what the flow needs. For each one, ASK the user for their value — don't assume; the recorded example values are reference only.\n\n"
        if !hasParams {
            // (We can't reliably detect "no params" here without re-
            // parsing flow.yaml; the body table will be empty in that
            // case and the agent will skip step 1 naturally. We still
            // want a confirm step so the agent doesn't dive in unannounced.)
        }
        out += "   No parameters? Just confirm the user is ready: *\"I'll run the `\(flow.displayName)` flow now. Ready?\"*\n\n"
        out += "2. **Start the play yourself** (no other code starts it):\n\n"
        out += "       flow42 play \(dirEscaped) --by claude --label \"\(flow.displayName)\"\n\n"
        out += "   If a play is already active when you try this, it means the user's environment pre-started one for you — skip ahead to step 4 and use the existing session.\n\n"
        out += "3. **Substitute user-provided values into every `flow42 do *` command.** When you see `${alias}` in a step's text or `replicate` field, replace it with the value the user gave you. The recorded `replicate` is a TEMPLATE, not a final command — running it verbatim will use the recording's example values, which is almost never what the user wants.\n\n"
        out += "4. **Run the canonical loop:**\n\n"
        out += "       flow42 play current\n       try the GUI path's steps via flow42 do *  (with substituted params)\n       flow42 play next\n       on stuck → flow42 play pause --reason \"…\"; flow42 play wait\n\n"
        out += "5. **End:**\n\n"
        out += "       flow42 play end --reason completed\n\n"
        out += "The body below is the same content the human sees when they open this flow in Flow42 — phase intents, parameter table, ordered steps with screenshots, and headless alternatives. Treat it as your script.\n\n"
        out += "---\n\n"

        // Story body. Strip the redundant top-level `# <name>` since the
        // skill resolver already keys on the front-matter `name` field.
        out += stripLeadingH1(storyMarkdown)
        return out
    }

    /// Drop the first H1 line so the rendered story doesn't double up
    /// with the skill's front-matter `name`. The renderer always emits
    /// `# <name>\n\n` first.
    private static func stripLeadingH1(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            // Also drop the immediately-following blank line.
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Paths

    private static func skillsRoot() -> URL {
        // Mirrors InstallSkills.defaultTarget — `~/.claude/skills/`.
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
    }
}
