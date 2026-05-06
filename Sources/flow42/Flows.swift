// Flows.swift - `flow42 flows` CLI subcommand
//
// Walks ~/.flow42/flows/ and reports each recording's slug,
// last-modified time, action count (from flow.json if it exists), and
// which artifacts have been generated. Prints a human table by default
// or strict JSON with `--json`.

import Flow42Core
import Foundation

enum Flows {

    static func run(args: [String]) {
        let json = args.contains("--json")
        let root = recipesRoot()
        let entries = scan(at: root)

        if json {
            printJSON(entries: entries)
        } else {
            printTable(root: root, entries: entries)
        }
    }

    // MARK: - Output

    private static func printTable(root: URL, entries: [Entry]) {
        if entries.isEmpty {
            print("No recordings found in \(root.path)/")
            print("Run `flow42 record` to create one.")
            return
        }
        print("Recordings under \(root.path):")
        print("")
        print("  SLUG                                    ACTIONS  HUMAN  SKILL  RECORDED")
        for e in entries {
            let slug = e.slug.padding(toLength: 38, withPad: " ", startingAt: 0)
            let actions = String(format: "%6d ", e.actionCount ?? 0)
            let human = e.hasHumanGuide ? "  ✓  " : "  -  "
            let skill = e.hasSkill ? "  ✓  " : "  -  "
            let date = e.modified.map { dateFmt.string(from: $0) } ?? "?"
            print("  \(slug)\(actions) \(human) \(skill)  \(date)")
        }
        print("")
        print("Tip: pass --json for machine-readable output.")
    }

    private static func printJSON(entries: [Entry]) {
        let payload = entries.map { e -> [String: Any] in
            var d: [String: Any] = [
                "slug": e.slug,
                "path": e.path,
                "has_human_guide": e.hasHumanGuide,
                "has_skill": e.hasSkill,
            ]
            if let n = e.actionCount { d["action_count"] = n }
            if let m = e.modified { d["modified"] = ISO8601DateFormatter().string(from: m) }
            if let p = e.platform { d["platform"] = p }
            if let t = e.taskDescription { d["task_description"] = t }
            return d
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let str = String(data: data, encoding: .utf8) else {
            print("[]")
            return
        }
        print(str)
    }

    // MARK: - Scanning

    private struct Entry {
        let slug: String
        let path: String
        let modified: Date?
        let actionCount: Int?
        let hasHumanGuide: Bool
        let hasSkill: Bool
        let platform: String?
        let taskDescription: String?
    }

    private static func scan(at root: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }

        var out: [Entry] = []
        for name in names {
            if name.hasPrefix(".") { continue }
            let dir = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(makeEntry(slug: name, dir: dir))
        }
        // Sort newest-first.
        out.sort { (a, b) in
            switch (a.modified, b.modified) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.slug > b.slug
            }
        }
        return out
    }

    private static func makeEntry(slug: String, dir: URL) -> Entry {
        let fm = FileManager.default
        let flowJsonPath = dir.appendingPathComponent("flow.json").path
        let modified = (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate]) as? Date

        var actionCount: Int?
        var platform: String?
        var taskDescription: String?
        if let data = fm.contents(atPath: flowJsonPath),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            actionCount = parsed["action_count"] as? Int
            platform = parsed["platform"] as? String
            taskDescription = parsed["task_description"] as? String
        }

        let hasHumanGuide = fm.fileExists(atPath: dir.appendingPathComponent("humanGuide.md").path)
        let hasSkill = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .contains(where: { $0.hasSuffix(".skill.md") }) ?? false

        return Entry(
            slug: slug,
            path: dir.path,
            modified: modified,
            actionCount: actionCount,
            hasHumanGuide: hasHumanGuide,
            hasSkill: hasSkill,
            platform: platform,
            taskDescription: taskDescription
        )
    }

    // MARK: - Helpers

    private static func recipesRoot() -> URL {
        URL(fileURLWithPath: Flow42Paths.flowsRoot())
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
