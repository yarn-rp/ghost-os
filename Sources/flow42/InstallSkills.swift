// InstallSkills.swift - `flow42 install-skills [--target DIR] [--update]`
//
// Drops the bundled flow42-cli and flow-creator skills into the agent's
// skills directory. Default target is ~/.claude/skills/. Each skill goes
// in its own subdirectory containing SKILL.md (agent file) and a
// kebab-case companion .md (human file).
//
// --update overwrites existing files. Without it, the command refuses to
// overwrite — protects user edits.

import Flow42Core
import Foundation

enum InstallSkills {

    static func run(args: [String]) {
        let f = parseSimple(args)
        let target = (f.string("target")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            ?? defaultTarget()
        let update = f.bool("update")

        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            emitJSON([
                "success": false,
                "error": "could not create target directory \(target.path): \(error.localizedDescription)",
            ])
            exit(1)
        }

        var installed: [[String: Any]] = []
        for name in SkillsResources.bundledSkills {
            do {
                let files = try SkillsResources.install(named: name, into: target, update: update)
                installed.append([
                    "name": name,
                    "path": target.appendingPathComponent(name).path,
                    "files": files,
                    "version": Flow42Core.version,
                ])
            } catch {
                emitJSON([
                    "success": false,
                    "skill": name,
                    "error": error.localizedDescription,
                ])
                exit(1)
            }
        }
        writeManifest(installed: installed)
        emitJSON([
            "success": true,
            "target": target.path,
            "installed": installed,
        ])
    }

    private static func defaultTarget() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
    }

    private static func writeManifest(installed: [[String: Any]]) {
        let dir = URL(fileURLWithPath: Flow42Paths.root())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("installed-skills.json")
        let body: [String: Any] = [
            "flow42_version": Flow42Core.version,
            "installed_at": ISO8601DateFormatter().string(from: Date()),
            "skills": installed,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? data.write(to: manifestURL)
        }
    }
}
