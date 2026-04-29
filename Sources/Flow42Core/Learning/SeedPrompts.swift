// SeedPrompts.swift - Public helper for writing bundled clarify/generate
// prompt markdown into a recording's `.agent/` folder.
//
// The prompts are .md files under Sources/Flow42Core/Resources/prompts/
// shipped via SwiftPM resources. We never overwrite an existing prompt —
// users may have edited theirs in-place and we should respect that.

import Foundation

public enum SeedPrompts {

    /// Drop `clarify-prompt.md` and `generate-prompt-<provider>.md` into
    /// `<recordingDir>/.agent/`. Returns the list of files actually written
    /// (skipping any that already existed). Throws on disk errors.
    @discardableResult
    public static func seed(
        into recordingDir: String,
        provider: String = "openclaw"
    ) throws -> [String] {
        let agentDir = (recordingDir as NSString).appendingPathComponent(".agent")
        try FileManager.default.createDirectory(
            atPath: agentDir,
            withIntermediateDirectories: true
        )

        var written: [String] = []
        let candidates: [(resource: String, filename: String)] = [
            ("clarify-prompt", "clarify-prompt.md"),
            ("generate-prompt-\(provider)", "generate-prompt-\(provider).md"),
        ]

        for (resource, filename) in candidates {
            let dest = (agentDir as NSString).appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest) { continue }
            guard let content = loadPrompt(named: resource) else {
                throw NSError(
                    domain: "flow42",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Bundled prompt resource '\(resource).md' missing — rebuild flow42."]
                )
            }
            try content.write(toFile: dest, atomically: true, encoding: .utf8)
            written.append(filename)
        }
        return written
    }

    /// Read a bundled prompt by basename (without `.md`). Returns nil if the
    /// resource isn't present in the bundle (will only happen if Package.swift
    /// resources are out of sync with what's on disk).
    private static func loadPrompt(named name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "md",
            subdirectory: "prompts"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
