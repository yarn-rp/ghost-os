// RecordingsModel.swift - Enumerate past recordings under
// ~/.flow42/flows/ and surface them in the popover.

import AppKit
import Combine
import Flow42Core
import Foundation

struct RecordingSummary: Identifiable {
    let id: String           // slug == directory name
    let dir: String
    let taskDescription: String?
    let recordedAt: Date?
    let durationSeconds: Int?
    let actionCount: Int?
    let apps: [String]

    /// "Edited 4 files · 12s · Claude" style caption.
    var caption: String {
        var parts: [String] = []
        if let n = actionCount { parts.append("\(n) action\(n == 1 ? "" : "s")") }
        if let d = durationSeconds, d > 0 { parts.append("\(d)s") }
        if let app = apps.first { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    var title: String {
        if let t = taskDescription, !t.isEmpty { return t }
        return id
    }

    var relativeWhen: String {
        guard let recordedAt else { return "" }
        let elapsed = Date().timeIntervalSince(recordedAt)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}

@MainActor
final class RecordingsModel: ObservableObject {

    @Published private(set) var recordings: [RecordingSummary] = []

    private let maxEntries = 25

    init() { reload() }

    func reload() {
        let root = recipesRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            recordings = []
            return
        }
        let summaries = entries
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)  // newest first by name (timestamp slug)
            .prefix(maxEntries)
            .map { slug -> RecordingSummary in
                let dir = (root as NSString).appendingPathComponent(slug)
                return parse(slug: slug, dir: dir)
            }
        recordings = Array(summaries)
    }

    private func parse(slug: String, dir: String) -> RecordingSummary {
        let flowPath = (dir as NSString).appendingPathComponent("flow.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: flowPath)),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return RecordingSummary(
                id: slug, dir: dir,
                taskDescription: nil, recordedAt: nil,
                durationSeconds: nil, actionCount: nil, apps: []
            )
        }
        let taskDescription = (dict["task_description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let recordedAt = (dict["recorded_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let duration = (dict["duration_seconds"] as? Int) ?? (dict["duration_seconds"] as? Double).map(Int.init)
        let actionCount = dict["action_count"] as? Int
        let apps = (dict["apps"] as? [String]) ?? []
        return RecordingSummary(
            id: slug, dir: dir,
            taskDescription: taskDescription,
            recordedAt: recordedAt,
            durationSeconds: duration,
            actionCount: actionCount,
            apps: apps
        )
    }

    private func recipesRoot() -> String {
        Flow42Paths.flowsRoot()
    }
}
