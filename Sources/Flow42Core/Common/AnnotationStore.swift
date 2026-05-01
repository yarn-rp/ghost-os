// AnnotationStore.swift - Reads/writes annotation directories.
//
// Every annotation produced by the Flow42 menu app's "Circle to Search"
// overlay lands at:
//
//   ~/.openclaw/flow42/annotations/<ISO-timestamp>/
//     meta.json    — rect (display + global coords), display ID, app, window,
//                    note text, optional lasso path, timestamp
//     region.png   — screenshot of the bounding rect
//     ax.json      — accessibility-tree subtree filtered to elements whose
//                    frame intersects the bounding rect
//
// This module is the read side: list, load latest, prune. The menu app does
// the actual writes (it owns the screen-capture path); we expose a single
// `write` helper here for future agent-driven writes if needed.

import Foundation

public struct AnnotationMeta: Sendable, Codable {
    public let id: String  // the directory name, e.g. "2026-04-30T17-32-04Z"
    public let createdAt: String  // ISO 8601
    public let app: String?
    public let bundleId: String?
    public let windowTitle: String?
    public let note: String?
    public let displayId: Int?
    public let rect: Rect
    public let lassoPath: [Point]?  // if user drew a freeform shape

    public struct Rect: Sendable, Codable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let coordSpace: String  // "global" | "display"

        public init(x: Double, y: Double, width: Double, height: Double, coordSpace: String) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.coordSpace = coordSpace
        }
    }

    public struct Point: Sendable, Codable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public init(
        id: String,
        createdAt: String,
        app: String?,
        bundleId: String?,
        windowTitle: String?,
        note: String?,
        displayId: Int?,
        rect: Rect,
        lassoPath: [Point]?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.app = app
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.note = note
        self.displayId = displayId
        self.rect = rect
        self.lassoPath = lassoPath
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case app
        case bundleId = "bundle_id"
        case windowTitle = "window_title"
        case note
        case displayId = "display_id"
        case rect
        case lassoPath = "lasso_path"
    }
}

public enum AnnotationStore {

    public static func rootDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent("annotations")
            .path
    }

    /// List annotation directory names, newest-first. Returns an empty array
    /// when the directory is missing.
    public static func listIds() -> [String] {
        let root = rootDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        // Directory names are ISO 8601 timestamps with `:` replaced by `-` so
        // lexical descending order matches reverse-chronological order.
        return entries
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)
    }

    /// Load the meta.json for an annotation by id (the directory name).
    public static func loadMeta(id: String) -> AnnotationMeta? {
        let metaPath = pathForMeta(id: id)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(AnnotationMeta.self, from: data)
    }

    /// Resolve the latest annotation id, or nil when none exist.
    public static func latestId() -> String? {
        listIds().first
    }

    /// Absolute paths inside an annotation directory.
    public static func pathForMeta(id: String) -> String {
        return (annotationDir(id: id) as NSString).appendingPathComponent("meta.json")
    }
    public static func pathForRegion(id: String) -> String {
        return (annotationDir(id: id) as NSString).appendingPathComponent("region.png")
    }
    public static func pathForAX(id: String) -> String {
        return (annotationDir(id: id) as NSString).appendingPathComponent("ax.json")
    }
    public static func pathForVision(id: String) -> String {
        return (annotationDir(id: id) as NSString).appendingPathComponent("vision.json")
    }

    public static func annotationDir(id: String) -> String {
        return (rootDir() as NSString).appendingPathComponent(id)
    }

    /// Generate a fresh id (used by the writer, exposed here so producers and
    /// readers stay in lockstep on the format).
    public static func newId(at date: Date = Date()) -> String {
        // ISO 8601 with `:` -> `-` so it's a legal directory name and
        // lexical-sorted-descending = chronological-newest-first.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }

    /// Create the directory + write meta.json. Callers separately write
    /// region.png and ax.json into the same directory.
    @discardableResult
    public static func writeMeta(_ meta: AnnotationMeta) throws -> String {
        let dir = annotationDir(id: meta.id)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(meta)
        let metaPath = pathForMeta(id: meta.id)
        try data.write(to: URL(fileURLWithPath: metaPath))
        return dir
    }

    /// Bulk delete annotations older than `olderThan` seconds.
    /// Returns the number of directories removed.
    @discardableResult
    public static func clear(olderThanSeconds: TimeInterval? = nil) -> Int {
        let cutoff = olderThanSeconds.map { Date().addingTimeInterval(-$0) }
        var removed = 0
        for id in listIds() {
            let dir = annotationDir(id: id)
            if let cutoff,
               let attrs = try? FileManager.default.attributesOfItem(atPath: dir),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > cutoff {
                continue
            }
            if (try? FileManager.default.removeItem(atPath: dir)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
