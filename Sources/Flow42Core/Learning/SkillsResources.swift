// SkillsResources.swift - Public access to the bundled flow42-cli and
// flow-creator skill packs. Used by `flow42 install-skills` to drop
// SKILL.md + <skill-name>.md pairs into the agent's skills directory.

import Foundation

public enum SkillsResources {

    public struct InstallError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Names of the skills shipped inside the binary.
    /// Order is roughly the workflow order: reference first, recorder, then creator.
    public static let bundledSkills = ["flow42-cli", "flow-recorder", "flow-creator"]

    /// Resolve the bundled skill directory at `Resources/skills/<name>/`.
    /// Returns nil if the resource isn't available (build issue).
    public static func bundledSkillURL(named name: String) -> URL? {
        guard let root = Bundle.module.resourceURL?
            .appendingPathComponent("skills")
            .appendingPathComponent(name) else { return nil }
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    /// Copy one skill's directory (SKILL.md + companion .md) into
    /// `target/<name>/`. Throws if the destination exists and `update`
    /// is false. Returns the list of file names written.
    @discardableResult
    public static func install(
        named name: String,
        into target: URL,
        update: Bool
    ) throws -> [String] {
        guard let src = bundledSkillURL(named: name) else {
            throw InstallError(message: "bundled skill '\(name)' is missing — rebuild flow42")
        }
        let dest = target.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        var written: [String] = []
        let files = try FileManager.default.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil
        )
        for file in files {
            let destFile = dest.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: destFile.path) {
                if !update {
                    throw InstallError(
                        message: "\(destFile.path) already exists; pass --update to overwrite"
                    )
                }
                try FileManager.default.removeItem(at: destFile)
            }
            try FileManager.default.copyItem(at: file, to: destFile)
            written.append(destFile.lastPathComponent)
        }
        return written
    }
}
