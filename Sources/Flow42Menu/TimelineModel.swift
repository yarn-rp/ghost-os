// TimelineModel.swift - Tail the active recording's events.jsonl.
//
// v2 layout: events.jsonl is the authoritative live stream — one
// append-only line per step. Coalesced edits (typeText keeps
// growing, backspace shrinks) emit a fresh line; the menu timeline
// dedupes on `step_dir` so the most recent line wins. The full
// per-step detail lives in `<step_dir>/meta.yaml` but we don't load
// it here: events.jsonl carries enough for the row UX (summary,
// target, replicate, screenshot path).
//
// File watching is FSEvents on the parent directory because the
// recorder may create the file lazily on its first append.

import Combine
import Dispatch
import Flow42Core
import Foundation

struct TimelineEvent: Identifiable {
    let id: String           // stable across reparses (timestamp + action_type)
    let actionType: String
    let summary: String
    let target: String?
    let timestampMs: Int64?
    let replicate: String?
    let screenshotPath: String?
    let raw: [String: Any]
}

@MainActor
final class TimelineModel: ObservableObject {

    @Published private(set) var events: [TimelineEvent] = []
    @Published private(set) var isLive: Bool = false
    @Published private(set) var sourcePath: String? = nil

    /// Recording dir for the events currently being tailed.
    private(set) var recordingDir: String? = nil

    /// Hard cap on rendered events. The recorder can emit hundreds in a long
    /// session and SwiftUI's text-sizing cost is linear in the row count even
    /// with `List` virtualization (the model still drives diffing). Trim to
    /// the most recent N before we hand the array to the view layer.
    static let maxRenderedEvents = 500

    private let stateClient: StateClient
    private var stateCancellable: AnyCancellable?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var fileFD: CInt = -1
    private var dirFD: CInt = -1
    /// Coalesce bursts of FS writes into one reload. The daemon rewrites
    /// flow.json atomically per action; without this we'd reparse + republish
    /// for every keystroke during a fast typing recording, starving the main
    /// run loop (and the Cmd+Shift+A hotkey) on SwiftUI layout.
    private var reloadDebounce: DispatchWorkItem?

    init(stateClient: StateClient) {
        self.stateClient = stateClient
        stateCancellable = stateClient.$state.sink { [weak self] state in
            self?.retarget(for: state)
        }
        retarget(for: stateClient.state)
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        // reloadDebounce is intentionally not cancelled here — DispatchWorkItem
        // is not Sendable so we can't touch it from a nonisolated deinit. The
        // captured `[weak self]` makes the work a no-op once we're gone.
        if fileFD >= 0 { close(fileFD) }
        if dirFD >= 0 { close(dirFD) }
    }

    private func retarget(for state: AppState) {
        // Tear down existing watchers.
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil
        if fileFD >= 0 { close(fileFD); fileFD = -1 }
        if dirFD >= 0 { close(dirFD); dirFD = -1 }

        guard state.mode == .recording,
              let dir = state.recording?.dir else {
            isLive = false
            sourcePath = nil
            recordingDir = nil
            events = []
            return
        }

        let path = (dir as NSString).appendingPathComponent("events.jsonl")
        sourcePath = path
        recordingDir = dir
        events = []
        isLive = true

        // Read whatever's already there. The daemon may have written
        // several actions before the popover opened.
        reload()

        // Watch the parent dir so we re-arm when events.jsonl is created
        // (the recorder creates the file lazily on its first append, and
        // an FD-on-the-file watch wouldn't fire for that initial create).
        let dirFD = open(dir, O_EVTONLY)
        if dirFD >= 0 {
            self.dirFD = dirFD
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFD,
                eventMask: [.write, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.scheduleReload()
            }
            source.resume()
            self.dirSource = source
        }
    }

    /// Coalesce FS-event bursts into a single reload ~33 ms later. Each call
    /// resets the debounce. We use main queue so reload() stays @MainActor-safe.
    private func scheduleReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33), execute: work)
    }

    /// Re-parse events.jsonl from scratch and replace `events`. We dedup
    /// on `step_dir` (last write wins) so coalesce + backspace edits — which
    /// append fresh lines for the same step — don't show as duplicates.
    /// Cheap because:
    ///   - events.jsonl is ~hundreds of bytes per line, capped at our 500-
    ///     event render window so we only parse the tail.
    ///   - SwiftUI's List virtualization means rebuilding the array doesn't
    ///     re-measure offscreen rows.
    private func reload() {
        guard let path = sourcePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8)
        else { return }

        // Walk all lines first, dedup on step_dir keeping the LAST entry
        // (the recorder appends a new line on every coalesce / backspace
        // update). Then keep only the most recent N for the render window.
        var byDir: [String: [String: Any]] = [:]
        var order: [String] = []   // first-seen order; last-write keeps key
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let lineData = raw.data(using: .utf8),
                let dict = (try? JSONSerialization.jsonObject(with: lineData))
                    as? [String: Any],
                let stepDir = dict["step_dir"] as? String
            else { continue }
            if byDir[stepDir] == nil { order.append(stepDir) }
            byDir[stepDir] = dict
        }

        // Sort by timestamp_ms when we have it (extension events from the
        // native host can land out-of-order with native CGEvent-tap ones
        // because they're in different processes).
        let merged: [[String: Any]] = order.compactMap { byDir[$0] }
            .sorted { a, b in
                let ax = (a["timestamp_ms"] as? Int64)
                    ?? (a["timestamp_ms"] as? Int).map(Int64.init)
                    ?? Int64.max
                let bx = (b["timestamp_ms"] as? Int64)
                    ?? (b["timestamp_ms"] as? Int).map(Int64.init)
                    ?? Int64.max
                return ax < bx
            }

        let total = merged.count
        let startIndex = max(0, total - Self.maxRenderedEvents)
        var built: [TimelineEvent] = []
        built.reserveCapacity(total - startIndex)
        for index in startIndex..<total {
            built.append(TimelineEvent.from(
                indexEntry: merged[index],
                recordingDir: recordingDir,
                fallbackIndex: index
            ))
        }
        if built.count != events.count
            || built.last?.id != events.last?.id
            || built.first?.id != events.first?.id
        {
            events = built
        }
    }
}

extension TimelineEvent {
    /// Build a TimelineEvent from one events.jsonl line. The recorder
    /// pre-computed `summary`, `target`, and `replicate` for the timeline
    /// row's UX, so this is just a typed-projection — no per-action_type
    /// branching. `fallbackIndex` keeps SwiftUI ids stable when two lines
    /// happen to share a timestamp_ms.
    ///
    /// Screenshot path is computed from `step_dir`: annotated.jpg if it
    /// exists (clicks, highlights, drags), screenshot.jpg otherwise. The
    /// EventThumbnail view checks file existence before drawing.
    static func from(
        indexEntry: [String: Any],
        recordingDir: String?,
        fallbackIndex: Int
    ) -> TimelineEvent {
        let actionType = (indexEntry["action_type"] as? String) ?? "unknown"
        let stepDir = (indexEntry["step_dir"] as? String) ?? ""
        let timestampMs = indexEntry["timestamp_ms"] as? Int64
            ?? (indexEntry["timestamp_ms"] as? Int).map(Int64.init)

        let summary = (indexEntry["summary"] as? String) ?? actionType
        let target = indexEntry["target"] as? String
        let replicate = indexEntry["replicate"] as? String

        let screenshotPath: String? = {
            guard !stepDir.isEmpty, let recordingDir else { return nil }
            let absStep = (recordingDir as NSString).appendingPathComponent(stepDir)
            // Prefer annotated.jpg (with click marker / drag rect), fall
            // back to the raw screenshot for keystrokes / hotkeys.
            let annotated = (absStep as NSString).appendingPathComponent("annotated.jpg")
            if FileManager.default.fileExists(atPath: annotated) { return annotated }
            // Highlight steps store their image as region.png.
            let region = (absStep as NSString).appendingPathComponent("region.png")
            if FileManager.default.fileExists(atPath: region) { return region }
            let raw = (absStep as NSString).appendingPathComponent("screenshot.jpg")
            if FileManager.default.fileExists(atPath: raw) { return raw }
            return nil
        }()

        // Stable id even when two events share a millisecond. step_dir
        // is unique within a session; tag with fallbackIndex so the
        // SwiftUI diff stays stable across reloads.
        let id = stepDir.isEmpty
            ? "\(timestampMs ?? 0)-\(actionType)-\(fallbackIndex)"
            : stepDir

        return TimelineEvent(
            id: id,
            actionType: actionType,
            summary: summary,
            target: target,
            timestampMs: timestampMs,
            replicate: replicate,
            screenshotPath: screenshotPath,
            raw: indexEntry
        )
    }
}
