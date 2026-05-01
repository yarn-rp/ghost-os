// TimelineModel.swift - Tail the active recording's flow.json.
//
// flow.json is the single source of truth: the recorder daemon rewrites it
// atomically on every captured action. We watch the file via FSEvents,
// re-parse the actions array on every change, and replace our @Published
// list. SwiftUI handles the diff cheaply because TimelineEvent is
// Identifiable and the LazyVStack only materializes visible rows.

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

        let path = (dir as NSString).appendingPathComponent("flow.json")
        sourcePath = path
        recordingDir = dir
        events = []
        isLive = true

        // Read whatever's already there. The daemon may have written
        // several actions before the popover opened.
        reload()

        // Watch the parent dir so we re-arm when flow.json is created (the
        // daemon rewrites it via tmp+rename, which means the file object's
        // identity changes).
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

    /// Re-parse flow.json from scratch and replace `events`. Cheap because
    /// the file is small (kilobytes per recording) and SwiftUI only diffs
    /// what's needed.
    private func reload() {
        guard let path = sourcePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let actions = parsed["actions"] as? [[String: Any]]
        else { return }

        // Only build the tail we'll actually render. Saves allocations and
        // (more importantly) keeps SwiftUI's identifier diff bounded when a
        // long recording grows past the cap.
        let total = actions.count
        let startIndex = max(0, total - Self.maxRenderedEvents)
        var built: [TimelineEvent] = []
        built.reserveCapacity(total - startIndex)
        for index in startIndex..<total {
            built.append(TimelineEvent.from(dict: actions[index], recordingDir: recordingDir, index: index))
        }
        // Only publish if we actually saw a change.
        if built.count != events.count
            || built.last?.id != events.last?.id
            || built.first?.id != events.first?.id
        {
            events = built
        }
    }
}

extension TimelineEvent {
    /// Build a TimelineEvent from one entry in flow.json's actions array.
    /// `index` makes the id stable across re-parses even when two events
    /// share a timestamp_ms.
    static func from(dict: [String: Any], recordingDir: String?, index: Int) -> TimelineEvent {
        let rawActionType = (dict["action_type"] as? String) ?? "unknown"
        let timestampMs = dict["timestamp_ms"] as? Int64
            ?? (dict["timestamp_ms"] as? Int).map(Int64.init)

        // The extension folds all browser navigation events into one
        // `appSwitch` with a `nav_kind` field. From a viewer's perspective
        // those are different things — render them with their nav_kind
        // badges + summaries instead of generic APP.
        let actionType: String = {
            if rawActionType == "appSwitch", let navKind = dict["nav_kind"] as? String {
                switch navKind {
                case "goto":      return "urlChange"
                case "newTab":    return "newTab"
                case "tabSwitch": return "tabSwitch"
                default:          return rawActionType
                }
            }
            return rawActionType
        }()

        var summary = actionType
        var target: String?

        switch actionType {
        case "click":
            let count = (dict["count"] as? Int) ?? 1
            let button = (dict["button"] as? String) ?? "left"
            let element = dict["element"] as? [String: Any]
            let verb = count >= 2 ? "double-click" : "\(button) click"

            // Prefer info-rich identifiers in this order:
            //   1. Playwright locator (extension)        — "getByRole('button', { name: 'Save' })"
            //   2. computed_name + role (native AX)       — "'Save' button"
            //   3. title + role                           — "'Save' button"
            //   4. dom_id                                 — "#submit-btn"
            //   5. coordinates                            — "(720, 144)"
            if let locator = nonEmpty(element?["locator"] as? String) {
                summary = "\(verb) \(locator)"
            } else if let name = nonEmpty(element?["computed_name"] as? String)
                ?? nonEmpty(element?["title"] as? String) {
                let role = simplifyRole(element?["role"] as? String)
                summary = role.isEmpty
                    ? "\(verb) '\(truncate(name, max: 50))'"
                    : "\(verb) '\(truncate(name, max: 40))' \(role)"
            } else if let domId = nonEmpty(element?["dom_id"] as? String) {
                summary = "\(verb) #\(domId)"
            } else {
                let x = dict["x"] as? Double ?? 0
                let y = dict["y"] as? Double ?? 0
                summary = "\(verb) @ (\(Int(x)), \(Int(y)))"
            }

            // Target line: URL for browser clicks, app name otherwise.
            if let url = nonEmpty(dict["url"] as? String) {
                target = truncate(url, max: 70)
            } else if let app = nonEmpty(dict["app"] as? String) {
                target = app
            }
        case "typeText":
            let text = (dict["text"] as? String) ?? ""
            summary = "type \"\(truncate(text, max: 40))\""
            // Surface which field was typed into when we have it.
            let element = dict["element"] as? [String: Any]
            if let locator = nonEmpty(element?["locator"] as? String) {
                target = locator
            } else if let name = nonEmpty(element?["computed_name"] as? String)
                ?? nonEmpty(element?["title"] as? String) {
                let role = simplifyRole(element?["role"] as? String)
                target = role.isEmpty ? "into '\(name)'" : "into '\(name)' \(role)"
            } else if let url = nonEmpty(dict["url"] as? String) {
                target = truncate(url, max: 70)
            }
        case "keyPress":
            let name = dict["key_name"] as? String ?? "?"
            let mods = (dict["modifiers"] as? [String])?.joined(separator: "+") ?? ""
            summary = mods.isEmpty ? "press \(name)" : "press \(mods)+\(name)"
            // For extension keypresses, surface the field that received it
            // (Enter pressed in a search box reads better than just "press Enter").
            let element = dict["element"] as? [String: Any]
            if let locator = nonEmpty(element?["locator"] as? String) {
                target = locator
            } else if let n = nonEmpty(element?["computed_name"] as? String)
                ?? nonEmpty(element?["title"] as? String) {
                target = "in '\(n)'"
            } else if let url = nonEmpty(dict["url"] as? String) {
                target = truncate(url, max: 70)
            }
        case "hotkey":
            let name = dict["key_name"] as? String ?? "?"
            let mods = (dict["modifiers"] as? [String])?.joined(separator: "+") ?? ""
            summary = "hotkey \(mods)+\(name)"
        case "appSwitch":
            // Pure app switch (Cmd+Tab to a different app) — extension nav
            // events are remapped above to urlChange / newTab / tabSwitch.
            let toApp = dict["to_app"] as? String ?? "?"
            summary = "switch to \(toApp)"
            target = toApp
        case "scroll":
            let dx = dict["delta_x"] as? Int ?? 0
            let dy = dict["delta_y"] as? Int ?? 0
            summary = "scroll dx=\(dx) dy=\(dy)"
        case "narration":
            let text = (dict["text"] as? String) ?? ""
            summary = "🎙  \(truncate(text, max: 80))"
        case "highlight":
            let w = Int((dict["width"] as? Double) ?? 0)
            let h = Int((dict["height"] as? Double) ?? 0)
            let app = dict["app"] as? String ?? ""
            // Browser highlights from the extension carry a Playwright
            // locator; surface that in the headline. Native macOS
            // highlights use the rect dimensions.
            let element = dict["element"] as? [String: Any]
            if let locator = nonEmpty(element?["locator"] as? String) {
                summary = "highlight \(locator)"
            } else {
                summary = "highlight \(w)×\(h)" + (app.isEmpty ? "" : " in \(app)")
            }
            // Target line = the most-readable text we have for this region.
            // Both paths now populate one of these fields:
            //   text_content  — extension: innerText  / native: AX text join
            //   ocr_text      — native: full OCR transcript
            // Prefer the structural one; fall back to OCR; last resort the
            // count of AX elements.
            let textContent = nonEmpty(dict["text_content"] as? String)
                ?? nonEmpty(dict["ocr_text"] as? String)
            if let textContent {
                target = truncate(
                    textContent.replacingOccurrences(of: "\n", with: " · "),
                    max: 100
                )
            } else if let n = dict["ax_element_count"] as? Int {
                target = "\(n) AX element\(n == 1 ? "" : "s")"
            }
        case "urlChange":
            // Extension uses `to_url`, native uses `url`.
            let url = nonEmpty(dict["to_url"] as? String)
                ?? nonEmpty(dict["url"] as? String) ?? ""
            summary = "navigate → \(truncate(url, max: 70))"
            target = nonEmpty(dict["window"] as? String)
        case "newTab":
            let url = nonEmpty(dict["to_url"] as? String)
                ?? nonEmpty(dict["url"] as? String) ?? ""
            summary = "new tab → \(truncate(url, max: 70))"
            if let tabIdx = dict["tab_index"] as? Int {
                target = "tab #\(tabIdx)"
            }
        case "tabSwitch":
            let url = nonEmpty(dict["to_url"] as? String)
                ?? nonEmpty(dict["url"] as? String) ?? ""
            let title = nonEmpty(dict["title"] as? String)
                ?? nonEmpty(dict["window"] as? String) ?? ""
            summary = "switch tab → \(truncate(title.isEmpty ? url : title, max: 70))"
            target = title.isEmpty ? nil : truncate(url, max: 70)
        default:
            break
        }

        // Resolve a screenshot path. Native events emit relative paths
        // ("screenshots/step-001.annotated.jpg"); highlights emit absolute.
        var screenshotPath: String? = nil
        let candidates = [
            dict["annotated_screenshot"] as? String,
            dict["screenshot"] as? String,
        ]
        for raw in candidates {
            guard let raw, !raw.isEmpty else { continue }
            if raw.hasPrefix("/") {
                screenshotPath = raw
            } else if let recordingDir {
                screenshotPath = (recordingDir as NSString).appendingPathComponent(raw)
            }
            if screenshotPath != nil { break }
        }

        let id = "\(timestampMs ?? 0)-\(actionType)-\(index)"

        return TimelineEvent(
            id: id,
            actionType: actionType,
            summary: summary,
            target: target,
            timestampMs: timestampMs,
            replicate: dict["replicate"] as? String,
            screenshotPath: screenshotPath,
            raw: dict
        )
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Convert AX role names to short human labels for inline use.
    /// "AXButton" → "button", "AXTextField" → "text field", etc.
    /// Returns "" for roles that don't add useful information ("AXGroup",
    /// "AXGenericElement", "browser") so the caller can omit the role
    /// suffix entirely.
    private static func simplifyRole(_ role: String?) -> String {
        guard let role, !role.isEmpty else { return "" }
        switch role {
        case "AXButton": return "button"
        case "AXLink": return "link"
        case "AXTextField", "AXTextArea": return "text field"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXMenuItem": return "menu item"
        case "AXMenuButton": return "menu"
        case "AXImage": return "image"
        case "AXStaticText", "AXHeading": return "text"
        case "AXComboBox": return "combobox"
        case "AXPopUpButton": return "dropdown"
        case "AXTab": return "tab"
        case "AXTable", "AXOutline": return "table"
        case "AXSlider": return "slider"
        case "AXToolbar": return "toolbar"
        case "AXGroup", "AXGenericElement", "browser", "AXScrollArea":
            return ""    // not informative — caller should skip the suffix
        default:
            // Unknown — strip AX prefix if present, lowercase first letter.
            let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            return stripped.lowercased()
        }
    }
}
