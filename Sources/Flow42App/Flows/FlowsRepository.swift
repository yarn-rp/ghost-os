// FlowsRepository.swift - Reads ~/.flow42/flows/ and yields summaries
// suitable for the Flows list. Watches the dir via DispatchSource so
// recordings the user makes (or that finish via the CLI) appear in the
// list within a frame or two without manual refresh.

import Flow42Core
import Foundation
import SwiftUI
import Yams

/// One row's worth of data for the Flows list. Hashable so it can be a
/// NavigationLink value into FlowDetailView.
struct FlowSummary: Identifiable, Equatable, Hashable {
    /// Whether the flow has been processed (`flow.yaml` present) or is
    /// just a captured recording awaiting structuring (`events.jsonl` +
    /// `steps/` + `meta.yaml` only). The grid uses this to differentiate
    /// the cards visually and route taps either to the regular
    /// FlowDetailView or to the RecordingHandoffView.
    enum State: Equatable, Hashable {
        case structured
        case unstructured
    }

    /// Directory leaf — the slug. Used as the stable identity.
    let id: String

    /// Display name from `flow.yaml::name` (structured) or
    /// `meta.yaml::name` / slug fallback (unstructured).
    let displayName: String

    /// Absolute path to the flow directory.
    let directory: String

    /// `recorded_at` as ISO 8601 (raw — the view formats).
    let recordedAt: String?

    /// Total seconds of the underlying recording, if known.
    let durationSeconds: Int?

    /// Number of phases authored in flow.yaml. Always 0 for unstructured.
    let phaseCount: Int

    /// Absolute path to the hero thumbnail (first GUI step's screenshot)
    /// when one exists. Nil otherwise — the view falls back to a placeholder.
    let heroThumbnailPath: String?

    /// `task_description` from flow.yaml — the one-line pitch for the row.
    let taskDescription: String?

    /// Structured vs. unstructured. Defaults to `.structured` so existing
    /// callers don't need to opt in.
    let state: State

    init(
        id: String,
        displayName: String,
        directory: String,
        recordedAt: String?,
        durationSeconds: Int?,
        phaseCount: Int,
        heroThumbnailPath: String?,
        taskDescription: String?,
        state: State = .structured
    ) {
        self.id = id
        self.displayName = displayName
        self.directory = directory
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.phaseCount = phaseCount
        self.heroThumbnailPath = heroThumbnailPath
        self.taskDescription = taskDescription
        self.state = state
    }
}

/// FSEvents-style live store of flow summaries. Observed from SwiftUI as
/// `@StateObject` / `@ObservedObject`; the published array swaps wholesale
/// when a rescan completes (cheap — there are tens of flows, not thousands).
@MainActor
final class FlowsRepository: ObservableObject {

    @Published private(set) var flows: [FlowSummary] = []
    @Published private(set) var lastError: String?

    /// Absolute path to the directory we scan. Each project owns its
    /// own; switching active project in the sidebar = swap repository
    /// instances, not mutate this.
    private let flowsRoot: String

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchedDirFd: Int32 = -1

    /// Default initializer (back-compat) scans `~/.flow42/flows/`.
    convenience init() {
        self.init(flowsRoot: Flow42Paths.flowsRoot())
    }

    /// Project-scoped initializer. Pass `Flow42Project.flowsRoot` to
    /// scan that project's `.flow42/flows/`.
    init(flowsRoot: String) {
        self.flowsRoot = flowsRoot
        rescan()
        startWatching()
    }

    deinit {
        watchSource?.cancel()
        if watchedDirFd >= 0 { close(watchedDirFd) }
    }

    /// Move the given flow's directory to the user's Trash. Used by
    /// the Drafts section's per-card delete + delete-all affordances.
    /// Trashing (rather than rm -rf) lets the user recover from a
    /// mis-click via the Finder; we re-scan immediately so the UI
    /// reflects the change without waiting for the FSEvents watcher.
    @discardableResult
    func deleteFlow(_ summary: FlowSummary) -> Bool {
        let url = URL(fileURLWithPath: summary.directory)
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            rescan()
            return true
        } catch {
            self.lastError = "Couldn't move \(summary.displayName) to the Trash: \(error.localizedDescription)"
            return false
        }
    }

    /// Trash every unstructured (draft) flow in this repository. Used
    /// by the "Delete all drafts" action — confirmation lives in the
    /// view layer; this method assumes the user already confirmed.
    /// Returns the count actually moved (some may fail individually).
    @discardableResult
    func deleteAllDrafts() -> Int {
        let drafts = flows.filter { $0.state == .unstructured }
        var moved = 0
        for draft in drafts {
            let url = URL(fileURLWithPath: draft.directory)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
            } catch {
                self.lastError = "Couldn't move \(draft.displayName) to the Trash: \(error.localizedDescription)"
            }
        }
        rescan()
        return moved
    }

    /// Walk the configured flows root and rebuild `flows`. Called once
    /// at init and whenever the watch source fires.
    func rescan() {
        let root = flowsRoot
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else {
            // No flows dir yet (fresh install). Empty list, no error.
            self.flows = []
            return
        }

        var summaries: [FlowSummary] = []
        for slug in entries {
            let dir = (root as NSString).appendingPathComponent(slug)
            // Ignore non-directory entries.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let flowYaml = (dir as NSString).appendingPathComponent("flow.yaml")
            let metaYaml = (dir as NSString).appendingPathComponent("meta.yaml")
            if fm.fileExists(atPath: flowYaml) {
                // Structured: parse the full flow.yaml.
                if let s = parse(slug: slug, dir: dir, flowYamlPath: flowYaml) {
                    summaries.append(s)
                }
            } else if fm.fileExists(atPath: metaYaml) {
                // Unstructured but finalised: a recording the user hasn't
                // yet handed off to flow-creator. Surface it in the same
                // grid with a different visual state — clicking it opens
                // the RecordingHandoffView so they can trigger the
                // processing flow manually.
                if let s = parseUnstructured(slug: slug, dir: dir, metaYamlPath: metaYaml) {
                    summaries.append(s)
                }
            }
            // Otherwise the dir is incomplete (recording in progress, or
            // a finalize crash before meta.yaml). Skipping is correct;
            // the live recording is rendered by the floating panel, not
            // this list.
        }
        // Newest first by recorded_at; flows without a date sink to the bottom.
        summaries.sort { (a, b) in
            switch (a.recordedAt, b.recordedAt) {
            case let (.some(l), .some(r)): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.displayName < b.displayName
            }
        }
        self.flows = summaries
    }

    // MARK: - Parse

    private func parse(slug: String, dir: String, flowYamlPath: String) -> FlowSummary? {
        guard let yamlString = try? String(
            contentsOf: URL(fileURLWithPath: flowYamlPath), encoding: .utf8
        ),
              let parsed = try? Yams.load(yaml: yamlString) as? [String: Any] else {
            return nil
        }
        let displayName = (parsed["name"] as? String) ?? slug
        let recordedAt = parsed["recorded_at"] as? String
        let durationSeconds = parsed["duration_seconds"] as? Int
        let taskDescription = (parsed["task_description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phases = (parsed["phases"] as? [[String: Any]]) ?? []
        let phaseCount = phases.count

        let heroPath = firstGuiStepScreenshot(phases: phases, in: dir)

        return FlowSummary(
            id: slug,
            displayName: displayName,
            directory: dir,
            recordedAt: recordedAt,
            durationSeconds: durationSeconds,
            phaseCount: phaseCount,
            heroThumbnailPath: heroPath,
            taskDescription: taskDescription?.isEmpty == false ? taskDescription : nil
        )
    }

    /// Parse an unstructured recording — `meta.yaml` only, no
    /// `flow.yaml` yet. The card uses these fields to render the
    /// "draft" state and the navigation tap routes to the
    /// RecordingHandoffView keyed by directory.
    private func parseUnstructured(
        slug: String, dir: String, metaYamlPath: String
    ) -> FlowSummary? {
        guard let yamlString = try? String(
            contentsOf: URL(fileURLWithPath: metaYamlPath), encoding: .utf8
        ),
              let parsed = try? Yams.load(yaml: yamlString) as? [String: Any] else {
            return nil
        }
        let displayName = (parsed["name"] as? String) ?? slug
        let recordedAt = parsed["recorded_at"] as? String
        let durationSeconds = parsed["duration_seconds"] as? Int
        let taskDescription = (parsed["task_description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let heroPath = firstStepFolderScreenshot(in: dir)
        return FlowSummary(
            id: slug,
            displayName: displayName,
            directory: dir,
            recordedAt: recordedAt,
            durationSeconds: durationSeconds,
            phaseCount: 0,
            heroThumbnailPath: heroPath,
            taskDescription: taskDescription?.isEmpty == false ? taskDescription : nil,
            state: .unstructured
        )
    }

    /// Find the first step folder's `screenshot.jpg` for use as the
    /// unstructured-recording hero thumbnail. Step folders are ordered
    /// `0001-…`, `0002-…`, etc. — alphabetic sort matches step order.
    private func firstStepFolderScreenshot(in dir: String) -> String? {
        let stepsRoot = (dir as NSString).appendingPathComponent("steps")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stepsRoot)
        else { return nil }
        for stepDir in entries.sorted() {
            let candidate = (stepsRoot as NSString)
                .appendingPathComponent(stepDir)
                .appending("/screenshot.jpg")
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// One-shot summary loader keyed by an absolute directory path.
    /// Used by deep-link navigation (Flow42Menu → Flow42App) so the
    /// app can build a FlowSummary for a flow that lives outside the
    /// currently-active project's flowsRoot. The slug is derived from
    /// the directory's last component to keep `id` stable.
    static func loadSummary(directory: String) -> FlowSummary? {
        let yaml = (directory as NSString).appendingPathComponent("flow.yaml")
        guard FileManager.default.fileExists(atPath: yaml) else { return nil }
        // Reuse the instance parser via a throwaway instance — avoids
        // duplicating yaml-shape knowledge in two places.
        let throwaway = FlowsRepository(flowsRoot: "/__deeplink__")
        let slug = (directory as NSString).lastPathComponent
        return throwaway.parse(slug: slug, dir: directory, flowYamlPath: yaml)
    }

    private func firstGuiStepScreenshot(phases: [[String: Any]], in dir: String) -> String? {
        for phase in phases {
            guard let paths = phase["paths"] as? [[String: Any]] else { continue }
            guard let gui = paths.first(where: { ($0["kind"] as? String) == "gui" }) else { continue }
            guard let steps = gui["steps"] as? [[String: Any]] else { continue }
            for step in steps {
                if let rel = step["screenshot"] as? String, !rel.isEmpty {
                    let abs = (dir as NSString).appendingPathComponent(rel)
                    if FileManager.default.fileExists(atPath: abs) { return abs }
                }
            }
        }
        return nil
    }

    // MARK: - Live watch

    /// DispatchSource on the flows dir — fires on .write events (a new
    /// recording finished, a flow.yaml was added, etc.). Coarse-grained;
    /// we just rescan on any change.
    private func startWatching() {
        let root = flowsRoot
        // Ensure the dir exists so open() doesn't fail on a fresh install.
        try? FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true
        )
        let fd = open(root, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDirFd = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.rescan()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedDirFd, fd >= 0 {
                close(fd)
                self?.watchedDirFd = -1
            }
        }
        source.resume()
        watchSource = source
    }
}
