// EventHandlers.swift - Per-event-type handling with AX enrichment
//
// Called from LearningRecorder.handleEvent() on the learning thread.
// All AX calls use the raw C API (AXUIElementCopyElementAtPosition,
// AXUIElementCopyAttributeValue) to avoid @MainActor isolation.

import ApplicationServices
import AppKit
import Foundation

/// Handles individual CGEvent types during learning.
/// nonisolated because all methods run on the learning thread.
nonisolated enum EventHandlers {

    // MARK: - Key Down

    static func handleKeyDown(_ event: CGEvent, recorder: LearningRecorder) {
        // When Chrome is frontmost, defer to the extension only for in-page
        // typing. Browser-chrome typing (URL bar, omnibox, Find in Page, etc.)
        // is invisible to the extension, so native must capture it. Also
        // capture any modifier-bearing hotkey unconditionally — Cmd-T,
        // Cmd-L, Cmd-W, Cmd-R, Cmd-Shift-T, etc. are browser actions, not
        // page input, even when the focused element is a DOM node.
        if isDomSidecarFocused() {
            let flags = event.flags
            let hasBrowserMod = flags.contains(.maskCommand)
                || flags.contains(.maskControl)
                || flags.contains(.maskAlternate)
            if !hasBrowserMod && isFocusedInWebArea() { return }
        }

        // Never record password keystrokes
        if isSecureFieldFocused() {
            recorder.flushPendingKeystrokesOnLearningThread()
            let (app, bid) = currentAppInfo()
            recorder.appendAction(ObservedAction(
                timestamp: mach_absolute_time(), action: .secureField,
                appName: app, appBundleId: bid,
                windowTitle: nil, url: nil, elementContext: nil
            ))
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("cmd") }
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskAlternate) { mods.append("option") }
        if flags.contains(.maskControl) { mods.append("control") }

        let chars = keyChars(from: event)

        // Text-edit gestures: Backspace and Option+Delete are part of the
        // typing motion, not standalone keypresses. They silently mutate the
        // active typing buffer (or the previous typeText action when the
        // target is unchanged). When neither applies, fall through and emit
        // a keyPress / hotkey as before — the user opted to keep them
        // visible so an agent can decide if they were mistakes.
        // Three flavors of "delete backward" — only meaningful when the
        // focused element is a text-bearing role (otherwise Backspace might
        // mean "remove a list item", "discard a draft", etc., which we keep
        // visible). Within a text field they're parts of the typing motion,
        // not standalone events.
        let target = focusedFieldContext()
        let inTextField = isTextBearingRole(target?.role)

        let isPlainBackspace      = mods.isEmpty           && keyCode == 51
        let isOptionBackspace     = mods == ["option"]     && keyCode == 51 // word
        let isCmdBackspace        = mods == ["cmd"]        && keyCode == 51 // line

        if inTextField, (isPlainBackspace || isOptionBackspace || isCmdBackspace) {
            let (app, bid) = currentAppInfo()
            let consumed: Bool
            if isPlainBackspace {
                consumed = recorder.handleBackspaceIfTextEdit(
                    currentApp: app, currentBundleId: bid, currentTarget: target
                )
            } else if isOptionBackspace {
                consumed = recorder.handleWordDeleteIfTextEdit(
                    currentApp: app, currentBundleId: bid, currentTarget: target
                )
            } else {
                consumed = recorder.handleLineDeleteIfTextEdit(
                    currentApp: app, currentBundleId: bid, currentTarget: target
                )
            }
            if consumed { return }
        }

        // Shift alone with a printable character is just punctuation /
        // capitalization — `chars` already reflects the shifted character
        // ("!" for Shift+1, "H" for Shift+H). Only Cmd / Option / Control
        // turn a printable into a real hotkey. Without this, typing a
        // capital letter or any !/@/#/$/% would land in flow.json as a
        // hotkey instead of as text.
        let nonShiftMods = mods.filter { $0 != "shift" }

        if let chars, nonShiftMods.isEmpty {
            // Coalesce character keys into pending buffer
            recorder.withLock { session in
                guard session != nil else { return }
                if recorder.pendingKeystrokes.isEmpty {
                    recorder.pendingKeystrokeElement = focusedFieldContext()
                    recorder.pendingKeystrokeTimestamp = mach_absolute_time()
                    let (app, bid) = currentAppInfo()
                    recorder.pendingKeystrokeApp = app
                    recorder.pendingKeystrokeBundleId = bid
                    recorder.pendingKeystrokeWindow = currentWindowTitle()
                    recorder.pendingKeystrokeUrl = currentURL()
                }
                recorder.pendingKeystrokes.append(chars)
            }
            recorder.scheduleKeystrokeFlushTimer()
        } else {
            // Non-character key or modifier combo: flush pending, record discrete action
            recorder.flushPendingKeystrokesOnLearningThread()
            let keyName = keyNameForCode(keyCode)
            let (app, bid) = currentAppInfo()
            let actionType: ObservedActionType = !mods.isEmpty
                ? .hotkey(modifiers: mods, keyName: keyName)
                : .keyPress(keyCode: keyCode, keyName: keyName, modifiers: [])

            // Screenshot the visually frontmost window before the keystroke
            // takes effect (same convention as handleMouseDown).
            var rawPath: String?
            if let slot = recorder.nextScreenshotSlot() {
                rawPath = LearningScreenshot.capture(
                    stepIndex: slot.stepIndex,
                    recordingDir: slot.recordingDir
                )
            }

            recorder.appendAction(ObservedAction(
                timestamp: mach_absolute_time(), action: actionType,
                appName: app, appBundleId: bid,
                windowTitle: currentWindowTitle(), url: nil, elementContext: nil,
                screenshotPath: rawPath
            ))
        }
    }

    // MARK: - Mouse Down

    static func handleMouseDown(_ type: CGEventType, _ event: CGEvent, recorder: LearningRecorder) {
        // Defer in-page clicks to the extension; capture clicks on Chrome's
        // own UI (URL bar, tabs, three-dot menu, bookmarks bar, etc.).
        if isDomSidecarFocused() && isPointInWebArea(at: event.location) { return }

        recorder.flushPendingKeystrokesOnLearningThread()
        recorder.flushPendingScrollOnLearningThread()

        let loc = event.location
        let button: String = (type == .leftMouseDown) ? "left" : "right"
        let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
        let (app, bid) = currentAppInfo()
        // Snap a screenshot of whatever's visually frontmost before the click
        // lands. Capturing by topmost on-screen window (not by pid) avoids
        // flaky frontmost-app detection — NSWorkspace can return Universal
        // Control, the recorder's parent terminal, etc. instead of the app
        // the user is actually clicking in.
        var rawPath: String?
        var annotatedPath: String?
        if let slot = recorder.nextScreenshotSlot() {
            rawPath = LearningScreenshot.capture(
                stepIndex: slot.stepIndex,
                recordingDir: slot.recordingDir
            )
            annotatedPath = LearningScreenshot.capture(
                stepIndex: slot.stepIndex,
                recordingDir: slot.recordingDir,
                annotated: true,
                clickPoint: loc
            )
        }

        recorder.appendAction(ObservedAction(
            timestamp: mach_absolute_time(),
            action: .click(x: Double(loc.x), y: Double(loc.y), button: button, count: clicks),
            appName: app, appBundleId: bid,
            windowTitle: currentWindowTitle(), url: currentURL(),
            elementContext: enrichClick(at: loc),
            screenshotPath: rawPath,
            annotatedScreenshotPath: annotatedPath
        ))
    }

    // MARK: - Scroll

    static func handleScroll(_ event: CGEvent, recorder: LearningRecorder) {
        // In-page scroll → extension handles. Scroll on Chrome chrome (rare
        // but possible — e.g. tab strip overflow) → native captures.
        if isDomSidecarFocused() && isPointInWebArea(at: event.location) { return }

        let dy = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let dx = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        guard dx != 0 || dy != 0 else { return }

        recorder.flushPendingKeystrokesOnLearningThread()
        let loc = event.location
        let (app, bid) = currentAppInfo()

        recorder.withLock { session in
            guard session != nil else { return }
            if recorder.pendingScrollDeltaX == 0 && recorder.pendingScrollDeltaY == 0 {
                recorder.pendingScrollTimestamp = mach_absolute_time()
                recorder.pendingScrollApp = app
                recorder.pendingScrollBundleId = bid
                recorder.pendingScrollX = Double(loc.x)
                recorder.pendingScrollY = Double(loc.y)
            }
            recorder.pendingScrollDeltaX += dx
            recorder.pendingScrollDeltaY += dy
        }
        recorder.scheduleScrollFlushTimer()
    }

    // MARK: - AX Enrichment

    /// Hit-test at click point to identify the element.
    private static func enrichClick(at location: CGPoint) -> ElementContext? {
        let sys = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(sys, Float(location.x), Float(location.y), &element)
        guard err == .success, let el = element else { return nil }

        let role = axAttr(el, kAXRoleAttribute) as? String
        let title = (axAttr(el, kAXTitleAttribute) as? String).map { String($0.prefix(200)) }
        let ident = (axAttr(el, kAXIdentifierAttribute) as? String).map { String($0.prefix(200)) }
        let domId = axAttr(el, "AXDOMIdentifier") as? String
        let domClasses: String? = {
            guard let v = axAttr(el, "AXDOMClassList") else { return nil }
            if let s = v as? String { return s }
            if let a = v as? [String] { return a.joined(separator: " ") }
            return nil
        }()
        let desc = (axAttr(el, kAXDescriptionAttribute) as? String).map { String($0.prefix(200)) }
        var parentRole: String?
        if let pv = axAttr(el, kAXParentAttribute) {
            // CF types: AXUIElement downcast always succeeds (CFTypeRef bridging)
            parentRole = axAttr(pv as! AXUIElement, kAXRoleAttribute) as? String
        }
        return ElementContext(role: role, title: title, identifier: ident,
            domId: domId, domClasses: domClasses,
            computedName: title ?? desc, parentRole: parentRole)
    }

    /// Get AX context for the currently focused element (typing context).
    private static func focusedFieldContext() -> ElementContext? {
        guard let app = FrontmostApp.effective() else { return nil }
        let appEl = AXUIElementCreateApplication(app.pid)
        guard let fv = axAttr(appEl, kAXFocusedUIElementAttribute) else { return nil }
        let el = fv as! AXUIElement  // CF type: downcast always succeeds
        let role = axAttr(el, kAXRoleAttribute) as? String
        let title = (axAttr(el, kAXTitleAttribute) as? String).map { String($0.prefix(200)) }
        let desc = (axAttr(el, kAXDescriptionAttribute) as? String).map { String($0.prefix(200)) }
        let domId = axAttr(el, "AXDOMIdentifier") as? String
        let ident = (axAttr(el, kAXIdentifierAttribute) as? String).map { String($0.prefix(200)) }
        return ElementContext(role: role, title: title, identifier: ident,
            domId: domId, domClasses: nil, computedName: title ?? desc, parentRole: nil)
    }

    // MARK: - DOM Sidecar Detection

    /// True when the Chrome extension is the authoritative source of in-page
    /// events. Native handlers should bail without appending an action — but
    /// only for in-page targets; browser-chrome targets (URL bar, settings,
    /// tab strip) are still captured natively.
    ///
    /// Disabled entirely when the user has set BrowserMode to `.native` —
    /// in that mode native captures everything in Chrome too, even in-page
    /// content. That's the "drop the extension entirely" experiment.
    static func isDomSidecarFocused() -> Bool {
        if BrowserMode.current() == .native { return false }
        guard let app = FrontmostApp.effective() else { return false }
        return LearningConstants.domSidecarBundleIds.contains(app.bundleId)
    }

    /// Walks up to 25 parents looking for an `AXWebArea` ancestor. Returns
    /// true if `el` is inside a web page's rendered content. Used to tell
    /// "click on a webpage button" (extension owns it) from "click on the
    /// URL bar / Settings menu / tab strip" (native owns it).
    private static func isElementInWebArea(_ el: AXUIElement) -> Bool {
        var current: AXUIElement = el
        for _ in 0..<25 {
            if let role = axAttr(current, kAXRoleAttribute) as? String, role == "AXWebArea" {
                return true
            }
            guard let parent = axAttr(current, kAXParentAttribute) else { return false }
            current = parent as! AXUIElement      // CF type: cast always succeeds
        }
        return false
    }

    /// Returns true if the AX hit-test at `location` lands inside a web area.
    static func isPointInWebArea(at location: CGPoint) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(sys, Float(location.x), Float(location.y), &element)
        guard err == .success, let el = element else { return false }
        return isElementInWebArea(el)
    }

    /// Returns true if the currently-focused element of the frontmost app
    /// is inside a web area (i.e. typing into a page input vs the URL bar).
    static func isFocusedInWebArea() -> Bool {
        guard let app = FrontmostApp.effective() else { return false }
        let appEl = AXUIElementCreateApplication(app.pid)
        guard let fv = axAttr(appEl, kAXFocusedUIElementAttribute) else { return false }
        let el = fv as! AXUIElement                 // CF type: cast always succeeds
        return isElementInWebArea(el)
    }

    // MARK: - Secure Field Detection

    /// Three-tier check: (1) AXSecureTextField role, (2) subrole,
    /// (3) name heuristics for Chrome which renders password fields as AXTextField.
    private static func isSecureFieldFocused() -> Bool {
        guard let app = FrontmostApp.effective() else { return false }
        let appEl = AXUIElementCreateApplication(app.pid)
        guard let fv = axAttr(appEl, kAXFocusedUIElementAttribute) else { return false }
        let focused = fv as! AXUIElement  // CF type: downcast always succeeds

        let role = axAttr(focused, kAXRoleAttribute) as? String
        if role == "AXSecureTextField" { return true }
        let subrole = axAttr(focused, kAXSubroleAttribute) as? String
        if subrole == "AXSecureTextField" { return true }

        let title = (axAttr(focused, kAXTitleAttribute) as? String ?? "").lowercased()
        let desc = (axAttr(focused, kAXDescriptionAttribute) as? String ?? "").lowercased()
        let id = (axAttr(focused, kAXIdentifierAttribute) as? String ?? "").lowercased()
        return LearningConstants.sensitiveFieldPatterns.contains { p in
            title.contains(p) || desc.contains(p) || id.contains(p)
        }
    }

    // MARK: - Helpers

    private static func axAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func currentAppInfo() -> (name: String, bundleId: String) {
        FrontmostApp.nameAndBundle()
    }

    static func currentWindowTitle() -> String? {
        guard let app = FrontmostApp.effective() else { return nil }
        let appEl = AXUIElementCreateApplication(app.pid)
        guard let wv = axAttr(appEl, kAXFocusedWindowAttribute) else { return nil }
        let win = wv as! AXUIElement  // CF type: downcast always succeeds
        return (axAttr(win, kAXTitleAttribute) as? String).map { String($0.prefix(200)) }
    }

    static func currentURL() -> String? {
        guard let app = FrontmostApp.effective() else { return nil }
        let browsers: Set<String> = [
            "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
            "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac",
        ]
        guard browsers.contains(app.bundleId) else { return nil }
        let appEl = AXUIElementCreateApplication(app.pid)
        guard let wv = axAttr(appEl, kAXFocusedWindowAttribute) else { return nil }
        let win = wv as! AXUIElement  // CF type: downcast always succeeds
        return findURLField(in: win, depth: 0)
    }

    private static func findURLField(in el: AXUIElement, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        let role = axAttr(el, kAXRoleAttribute) as? String
        if role == "AXTextField" || role == "AXComboBox" {
            let desc = (axAttr(el, kAXDescriptionAttribute) as? String ?? "").lowercased()
            if desc.contains("address") || desc.contains("url") || desc.contains("search or enter") {
                return axAttr(el, kAXValueAttribute) as? String
            }
        }
        guard let children = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let url = findURLField(in: child, depth: depth + 1) { return url }
        }
        return nil
    }

    /// Roles where edit-style hotkeys (Backspace, Option+Delete, Cmd+Delete,
    /// Shift+letter, etc.) are part of the typing motion rather than a
    /// standalone command. AXSecureTextField is intentionally excluded —
    /// we never inspect those.
    static func isTextBearingRole(_ role: String?) -> Bool {
        guard let role else { return false }
        switch role {
        case "AXTextArea", "AXTextField", "AXTextView", "AXComboBox": return true
        default: return false
        }
    }

    /// Read the AXValue of the currently focused element when it's a text-
    /// bearing role. Returns nil if no focus, role mismatch, AX unavailable,
    /// or the value can't be cast to a String. Used by the recorder to
    /// snapshot the field's actual content after an edit-hotkey instead of
    /// trying to simulate the edit locally.
    static func readFocusedTextFieldValue() -> String? {
        guard let app = FrontmostApp.effective() else { return nil }
        let appEl = AXUIElementCreateApplication(app.pid)
        guard let fv = axAttr(appEl, kAXFocusedUIElementAttribute) else { return nil }
        let el = fv as! AXUIElement   // CF cast: always succeeds
        let role = axAttr(el, kAXRoleAttribute) as? String
        guard isTextBearingRole(role) else { return nil }
        // Typed accessor first (works for native cocoa text fields),
        // raw attribute fallback for Chromium/Electron AX trees.
        if let s = axAttr(el, kAXValueAttribute) as? String { return s }
        return nil
    }

    private static func keyChars(from event: CGEvent) -> String? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        guard let chars = nsEvent.characters, !chars.isEmpty else { return nil }
        if chars.unicodeScalars.allSatisfy({ $0.value < 32 || $0.value == 127 }) { return nil }
        return chars
    }

    static func keyNameForCode(_ code: Int) -> String {
        switch code {
        case 36: "return"; case 48: "tab"; case 49: "space"; case 51: "delete"
        case 53: "escape"; case 123: "left"; case 124: "right"; case 125: "down"
        case 126: "up"; case 115: "home"; case 119: "end"; case 116: "pageup"
        case 121: "pagedown"; case 117: "forwarddelete"
        case 122: "f1"; case 120: "f2"; case 99: "f3"; case 118: "f4"
        case 96: "f5"; case 97: "f6"; case 98: "f7"; case 100: "f8"
        case 101: "f9"; case 109: "f10"; case 103: "f11"; case 111: "f12"
        default: "key\(code)"
        }
    }
}
