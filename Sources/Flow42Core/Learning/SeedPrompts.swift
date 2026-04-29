// SeedPrompts.swift - Public helper for writing bundled clarify/generate
// prompt markdown into a recording's `.agent/` folder.
//
// The prompts are .md files under Sources/Flow42Core/Resources/prompts/
// shipped via SwiftPM resources. We never overwrite an existing prompt —
// users may have edited theirs in-place and we should respect that.
//
// One prompt pair, agent-agnostic. The execution layer (flow42 / Ghost OS
// MCP runtime, shell, AppleScript, etc.) is implied by the .skill.md
// shortcut-first preference, not by the prompt filename.

import Foundation

public enum SeedPrompts {

    /// Drop `clarify-prompt.md` and `generate-prompt.md` into
    /// `<recordingDir>/.agent/`. Returns the list of files actually written
    /// (skipping any that already existed). Throws on disk errors.
    @discardableResult
    public static func seed(into recordingDir: String) throws -> [String] {
        let agentDir = (recordingDir as NSString).appendingPathComponent(".agent")
        try FileManager.default.createDirectory(
            atPath: agentDir,
            withIntermediateDirectories: true
        )

        var written: [String] = []
        for resource in ["clarify-prompt", "generate-prompt"] {
            let filename = "\(resource).md"
            let dest = (agentDir as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest) { continue }
            guard let content = loadPrompt(named: resource) else {
                throw NSError(
                    domain: "flow42",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Bundled prompt resource '\(filename)' missing — rebuild flow42."]
                )
            }
            try content.write(toFile: dest, atomically: true, encoding: .utf8)
            written.append(filename)
        }
        return written
    }

    private static func loadPrompt(named name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "md",
            subdirectory: "prompts"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
