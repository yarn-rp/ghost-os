// AnnotationsModel.swift - Read-side observer for the annotations directory.
//
// Loads the most recent N annotation entries (id + meta), re-loads when an
// annotation is created (broadcast as a Distributed Notification by
// AnnotationController) or when the popover opens. Used by AnnotationsStrip.

import AppKit
import Combine
import Flow42Core
import Foundation

struct AnnotationEntry: Identifiable {
    let id: String
    let meta: AnnotationMeta?
    let regionPath: String

    var imageThumbnail: NSImage? {
        guard FileManager.default.fileExists(atPath: regionPath) else { return nil }
        return NSImage(contentsOfFile: regionPath)
    }

    /// Best-effort caption: app name + relative time.
    var caption: String {
        let app = meta?.app ?? "—"
        let when = relativeTime
        return "\(app) · \(when)"
    }

    private var relativeTime: String {
        guard let createdAt = meta?.createdAt,
              let date = ISO8601DateFormatter.full.date(from: createdAt)
                ?? ISO8601DateFormatter().date(from: createdAt)
        else { return "" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}

private extension ISO8601DateFormatter {
    static let full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

@MainActor
final class AnnotationsModel: ObservableObject {

    @Published private(set) var entries: [AnnotationEntry] = []

    /// Maximum entries surfaced in the strip. The dir can hold many more —
    /// `flow42 annotations list` is the source of truth for the full set.
    private let maxEntries = 12

    private var observer: Any?

    init() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.web42.flow42.annotation.created"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop back onto the main actor explicitly — the observer block
            // is nominally MainActor via .main queue, but Swift 6 wants the
            // hop in writing.
            Task { @MainActor in self?.reload() }
        }
    }

    // Note: no deinit observer cleanup. The model lives for the whole app
    // lifetime (owned by MenuController), and Swift 6's nonisolated-deinit
    // rules conflict with `Any?` notification tokens. Process exit handles it.

    func reload() {
        let ids = AnnotationStore.listIds().prefix(maxEntries)
        entries = ids.map { id in
            AnnotationEntry(
                id: id,
                meta: AnnotationStore.loadMeta(id: id),
                regionPath: AnnotationStore.pathForRegion(id: id)
            )
        }
    }
}
