// Annotations.swift - `flow42 annotations list/show/clear` CLI subcommand.
//
// Annotations are produced by the Flow42 menu app's "Circle to Search" overlay
// (Cmd+Shift+A). Each one is a directory under ~/.openclaw/flow42/annotations/
// containing meta.json + region.png + ax.json. This subcommand exposes them
// so an agent can read context the user pinned visually.
//
// Subcommands:
//   list             newest-first directory ids; --json for full meta dump
//   show <id|latest> meta.json + base64 region.png (or --output for raw bytes)
//   clear            delete all (or --older-than 7d for selective)

import Flow42Core
import Foundation

enum Annotations {

    static func run(args: [String]) {
        guard let sub = args.first else {
            printUsage()
            exit(1)
        }
        switch sub {
        case "list":
            runList(args: Array(args.dropFirst()))
        case "show":
            runShow(args: Array(args.dropFirst()))
        case "clear":
            runClear(args: Array(args.dropFirst()))
        case "help", "-h", "--help":
            printUsage()
        default:
            FileHandle.standardError.write(Data("unknown subcommand: \(sub)\n".utf8))
            printUsage()
            exit(1)
        }
    }

    private static func runList(args: [String]) {
        let f = parseSimple(args)
        let asJson = f.bool("json")
        let ids = AnnotationStore.listIds()
        if asJson {
            var entries: [[String: Any]] = []
            for id in ids {
                if let meta = AnnotationStore.loadMeta(id: id),
                   let data = try? JSONEncoder().encode(meta),
                   let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    entries.append(dict)
                } else {
                    entries.append(["id": id, "meta_missing": true])
                }
            }
            emitJSON([
                "success": true,
                "count": ids.count,
                "annotations": entries,
                "root": AnnotationStore.rootDir(),
            ])
        } else {
            emitJSON([
                "success": true,
                "count": ids.count,
                "ids": ids,
                "root": AnnotationStore.rootDir(),
            ])
        }
    }

    private static func runShow(args: [String]) {
        let f = parseSimple(args)
        let positional = args.first { !$0.hasPrefix("--") } ?? "latest"
        let id: String? = (positional == "latest")
            ? AnnotationStore.latestId()
            : positional

        guard let id else {
            emitJSON([
                "success": false,
                "error": "no annotations exist",
                "suggestion": "press Cmd+Shift+A in the Flow42 menu app to capture one",
            ])
            exit(1)
        }
        guard let meta = AnnotationStore.loadMeta(id: id) else {
            emitJSON([
                "success": false,
                "error": "no meta.json for annotation \(id)",
                "path": AnnotationStore.annotationDir(id: id),
            ])
            exit(1)
        }

        // Optional: write region.png to --output instead of base64-embedding.
        let outputPath = f.string("output")
        let regionPath = AnnotationStore.pathForRegion(id: id)
        if let outputPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: regionPath)) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }

        var dict: [String: Any] = ["success": true]
        if let metaData = try? JSONEncoder().encode(meta),
           let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] {
            dict["meta"] = metaDict
        }
        dict["dir"] = AnnotationStore.annotationDir(id: id)
        dict["region_path"] = regionPath
        if outputPath == nil,
           let data = try? Data(contentsOf: URL(fileURLWithPath: regionPath)) {
            dict["region_base64"] = data.base64EncodedString()
        }
        let axPath = AnnotationStore.pathForAX(id: id)
        if FileManager.default.fileExists(atPath: axPath) {
            dict["ax_path"] = axPath
        }
        let visionPath = AnnotationStore.pathForVision(id: id)
        if FileManager.default.fileExists(atPath: visionPath) {
            dict["vision_path"] = visionPath
            // Inline a tiny preview so callers don't need a second read.
            // Full file is at vision_path.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: visionPath)),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let ocr = parsed["ocr"] as? [String: Any] {
                var preview: [String: Any] = [:]
                if let count = ocr["block_count"] { preview["block_count"] = count }
                if let full = ocr["full_text"] as? String {
                    // Cap at 1 KB so we don't bloat the JSON line.
                    preview["full_text_preview"] = String(full.prefix(1000))
                }
                dict["vision"] = preview
            }
        }
        emitJSON(dict)
    }

    private static func runClear(args: [String]) {
        let f = parseSimple(args)
        // Accepts --older-than as a number (seconds) or a duration like "7d".
        var olderThan: TimeInterval? = nil
        if let raw = f.string("older-than") {
            olderThan = parseDuration(raw)
        }
        let removed = AnnotationStore.clear(olderThanSeconds: olderThan)
        emitJSON([
            "success": true,
            "removed": removed,
            "remaining": AnnotationStore.listIds().count,
        ])
    }

    /// Parse "7d" / "12h" / "30m" / "120" (seconds) into a `TimeInterval`.
    private static func parseDuration(_ raw: String) -> TimeInterval? {
        if let secs = Double(raw) { return secs }
        guard let last = raw.last else { return nil }
        let prefix = String(raw.dropLast())
        guard let n = Double(prefix) else { return nil }
        switch last {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return nil
        }
    }

    private static func printUsage() {
        let usage = """
        Usage:
          flow42 annotations list [--json]
          flow42 annotations show <id|latest> [--output PATH]
          flow42 annotations clear [--older-than 7d]

        Annotations are captured via Cmd+Shift+A in the Flow42 menu bar app.
        Each annotation is a directory containing:
          meta.json   rect, app, window, note text, optional lasso path
          region.png  screenshot of the bounding rectangle
          ax.json     accessibility-tree subtree under the rect
        """
        print(usage)
    }
}
