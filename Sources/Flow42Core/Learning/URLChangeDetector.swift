// URLChangeDetector.swift - Synthesize browser navigation events natively.
//
// In BrowserMode.native we don't get DOM-level events from the extension,
// so navigation has to be inferred from AX. On every CGEvent this module
// snapshots three signals from the focused browser:
//   - URL bar value
//   - tab count (number of AXRadioButton children of the AXTabGroup)
//   - focused window title (== active tab's page title in Chrome/Safari)
//
// And emits one of:
//   .newTab(url)              when tab count grew
//   .urlChange(url)           when URL changed within the same tab
//   .tabSwitch(url, title)    when window title changed but URL didn't
//                             (rare — most tab switches also change URL)
//                             or when URL changed AND tab count is unchanged
//                             AND we have signal that this isn't a within-tab
//                             nav (heuristic: page title match against an
//                             earlier tab snapshot)
//
// One event covers any cause of navigation: address-bar typing, link click,
// history back/forward, in-page push-state, JavaScript redirect, Cmd+T,
// Cmd+1/2, swipe-back. Replay translates each to its closest CLI primitive.
//
// Disabled in BrowserMode.auto and .extension — the extension owns these
// signals there. We don't want duplicate events.

import AppKit
import ApplicationServices
import Foundation

nonisolated enum URLChangeDetector {

    /// Per-call state: the last-seen browser context (URL, tab count,
    /// window title, app bundle id). Caller owns persistence across CGEvents.
    struct LastSeen {
        var url: String = ""
        var bundleId: String = ""
        var tabCount: Int = 0
        var windowTitle: String = ""
    }

    /// Inspect the frontmost browser; emit synthesized navigation events
    /// when its context has changed since `last`. Returns true if any event
    /// was appended.
    @discardableResult
    static func checkAndRecord(
        recorder: LearningRecorder,
        last: inout LastSeen
    ) -> Bool {
        guard BrowserMode.current() == .native else { return false }
        guard let app = FrontmostApp.effective(),
              isBrowserBundleId(app.bundleId) else { return false }

        guard let snap = snapshot(pid: app.pid) else { return false }
        // First sighting — seed without emitting; otherwise we'd emit a
        // goto/newTab for whatever the user already had open when recording
        // started.
        if last.bundleId.isEmpty || last.url.isEmpty {
            last.url = snap.url
            last.bundleId = app.bundleId
            last.tabCount = snap.tabCount
            last.windowTitle = snap.windowTitle
            return false
        }

        var emitted = false

        // newTab — tab count grew.
        if snap.tabCount > last.tabCount {
            recorder.flushPendingKeystrokesOnLearningThread()
            recorder.flushPendingScrollOnLearningThread()
            recorder.appendAction(ObservedAction(
                timestamp: mach_absolute_time(),
                action: .newTab(url: snap.url),
                appName: app.name,
                appBundleId: app.bundleId,
                windowTitle: snap.windowTitle,
                url: snap.url,
                elementContext: nil
            ))
            emitted = true
            learningLog("DEBUG", "Learning: newTab \(snap.url)")
        } else if snap.tabCount < last.tabCount {
            // Tab closed; no event for it (matches extension behavior).
            // Closing the active tab also changes which tab is focused —
            // that's a tabSwitch handled by the URL/title comparison below.
        }

        // urlChange / tabSwitch — distinguish via tab count + title.
        if snap.url != last.url, !shouldIgnoreURL(snap.url) {
            // If tab count changed AND URL changed, the newTab event above
            // already covers this. Skip duplicating.
            if snap.tabCount == last.tabCount {
                // Same tab count; URL changed. Could be an in-tab nav OR a
                // tab switch. We can't tell from URL alone (think Cmd+1 to
                // an already-loaded tab — URL changes, no count change).
                // Heuristic: window title matches snap.url's domain →
                // probably a tab switch, otherwise a nav. For now emit
                // urlChange — that's the strictly more general signal and
                // it correctly carries the new URL. tabSwitch would be a
                // refinement we add when we can distinguish.
                recorder.flushPendingKeystrokesOnLearningThread()
                recorder.flushPendingScrollOnLearningThread()
                recorder.appendAction(ObservedAction(
                    timestamp: mach_absolute_time(),
                    action: .urlChange(url: snap.url),
                    appName: app.name,
                    appBundleId: app.bundleId,
                    windowTitle: snap.windowTitle,
                    url: snap.url,
                    elementContext: nil
                ))
                emitted = true
                learningLog("DEBUG", "Learning: urlChange \(last.url) -> \(snap.url)")
            }
        } else if snap.windowTitle != last.windowTitle,
                  snap.tabCount == last.tabCount,
                  !snap.windowTitle.isEmpty {
            // Same URL, same tab count, but title changed → either a
            // tab switch to a different tab that happens to be on the
            // same URL, or the page title updated dynamically. Emit
            // tabSwitch only when it really looks like a switch — for
            // now we suppress this case (titles update on most pages).
        }

        last.url = snap.url
        last.bundleId = app.bundleId
        last.tabCount = snap.tabCount
        last.windowTitle = snap.windowTitle
        return emitted
    }

    // MARK: - Snapshot

    private struct Snapshot {
        let url: String
        let tabCount: Int
        let windowTitle: String
    }

    private static func snapshot(pid: pid_t) -> Snapshot? {
        let appEl = AXUIElementCreateApplication(pid)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appEl, kAXFocusedWindowAttribute as CFString, &win
        ) == .success, let winEl = win else { return nil }
        let window = winEl as! AXUIElement

        let url = findURLField(in: window, depth: 0) ?? ""
        let tabCount = countTabs(in: window, depth: 0) ?? 0

        var titleVal: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleVal)
        let title = (titleVal as? String) ?? ""

        return Snapshot(url: url, tabCount: tabCount, windowTitle: title)
    }

    // MARK: - URL field walker

    private static func findURLField(in el: AXUIElement, depth: Int) -> String? {
        guard depth < 7 else { return nil }
        var roleVal: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleVal)
        let role = roleVal as? String
        if role == "AXTextField" || role == "AXComboBox" {
            var descVal: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
            let desc = ((descVal as? String) ?? "").lowercased()
            if desc.contains("address")
                || desc.contains("url")
                || desc.contains("search or enter") {
                var v: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
                if let s = v as? String, !s.isEmpty { return s }
            }
        }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
        guard let kids = children as? [AXUIElement] else { return nil }
        for child in kids {
            if let url = findURLField(in: child, depth: depth + 1) { return url }
        }
        return nil
    }

    // MARK: - Tab counting

    /// Walk the window tree looking for the tab strip. In Chromium
    /// browsers + Safari + Arc this is an `AXTabGroup` whose children are
    /// `AXRadioButton`s, one per tab. We count the radio buttons.
    private static func countTabs(in el: AXUIElement, depth: Int) -> Int? {
        guard depth < 8 else { return nil }
        var roleVal: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleVal)
        if (roleVal as? String) == "AXTabGroup" {
            var children: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            if let kids = children as? [AXUIElement] {
                let tabs = kids.filter { isTabRadioButton($0) }
                if !tabs.isEmpty { return tabs.count }
            }
        }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
        guard let kids = children as? [AXUIElement] else { return nil }
        for child in kids {
            if let n = countTabs(in: child, depth: depth + 1), n > 0 {
                return n
            }
        }
        return 0
    }

    private static func isTabRadioButton(_ el: AXUIElement) -> Bool {
        var roleVal: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleVal)
        return (roleVal as? String) == "AXRadioButton"
    }

    // MARK: - Helpers

    private static let browserBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "company.thebrowser.Browser",      // Arc
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
    ]

    private static func isBrowserBundleId(_ id: String) -> Bool {
        browserBundleIds.contains(id)
    }

    private static func shouldIgnoreURL(_ url: String) -> Bool {
        if url == "about:blank" { return true }
        if url.hasPrefix("chrome://newtab") { return true }
        return false
    }
}
