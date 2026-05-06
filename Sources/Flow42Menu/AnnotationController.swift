// AnnotationController.swift - Cmd+Shift+A region selector.
//
// While armed, an active CGEvent tap (defaultTap, head-insert) intercepts
// mouse events session-wide and returns nil to swallow them. The underlying
// app never sees the click, drag, or right-click — so dragging across a
// window edge no longer resizes the window, dragging over text no longer
// selects it, etc. The visual feedback overlay stays click-through (so the
// rect outline isn't itself a target).
//
// Esc is also routed through the tap — independent of which window is key —
// so the user can always cancel.
//
// Flow:
//   1. Hotkey → arm(): snapshot frontmost, push crosshair, install monitors,
//      open click-through overlay window on the screen the cursor is on.
//   2. mouseDown sets the start; drag updates the end; mouseUp commits.
//   3. commit(): tear down monitors + overlay, then async-capture pixels +
//      AX subtree and write to ~/.flow42/annotations/<id>/.
//   4. Esc anywhere cancels.

import AppKit
import Carbon.HIToolbox
import Combine
import Flow42Core
import Foundation
import ScreenCaptureKit
import SwiftUI

@MainActor
final class AnnotationController: ObservableObject {

    /// Drag rect expressed in the active screen's local SwiftUI coordinate
    /// space (origin top-left, Y down). Nil while no drag is in progress.
    /// The overlay view observes this directly.
    @Published private(set) var dragRectLocal: CGRect?
    @Published private(set) var armed: Bool = false
    /// Active screen — published so the overlay can size hint pills correctly.
    @Published private(set) var activeScreenSize: CGSize = .zero
    /// Live cursor position in local SwiftUI coords (top-left origin) for
    /// the active screen, so the overlay can render a "you're in capture
    /// mode" tag that follows the mouse.
    @Published private(set) var cursorLocal: CGPoint?

    private var hotkeyId: UInt32?

    // CGEvent tap that swallows mouse events session-wide while armed.
    // Without this, drags on a window edge resize the window, drags over
    // text select it, right-clicks open context menus, etc.
    fileprivate var eventTap: CFMachPort?
    fileprivate var eventTapSource: CFRunLoopSource?

    /// Observer for cross-app focus changes while annotation is armed.
    /// Routes the gesture to the right path (extension highlight in
    /// Chromium browsers, macOS region overlay everywhere else) whenever
    /// the user switches apps mid-annotation.
    private var appActivationObserver: Any?

    private var overlayWindow: NSWindow?
    private var startPointGlobal: CGPoint?
    private var currentPointGlobal: CGPoint?
    private var activeScreen: NSScreen?
    private var previousFrontmost: NSRunningApplication?

    init() {
        registerHotkey()
    }

    /// Briefly post a system Notification (Notification Center banner) so a
    /// user who pressed Cmd+Shift+A outside a recording understands why
    /// nothing happened. Best-effort — if the user has notifications muted,
    /// the stderr log is still there.
    private func flashMenuIcon() {
        let center = NSWorkspace.shared.notificationCenter
        center.post(
            name: Notification.Name("com.web42.flow42.menu.toast"),
            object: "Start a recording first to annotate"
        )
    }

    private func registerHotkey() {
        hotkeyId = HotkeyRegistrar.shared.register(
            keyCode: kVK_ANSI_A,
            modifiers: [.command, .shift]
        ) { [weak self] in
            self?.toggle()
        }
        if hotkeyId == nil {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] Cmd+Shift+A could not be registered\n".utf8
            ))
        }
    }

    private func toggle() {
        if armed {
            cancel()
        } else {
            arm()
        }
    }

    private func arm() {
        FileHandle.standardError.write(Data(
            "[Flow42Menu] Cmd+Shift+A pressed (armed=\(armed), overlayWindow=\(overlayWindow != nil))\n".utf8
        ))
        // Annotations are events that belong to a recording — they're not a
        // standalone capture mode. If there's no active recording, refuse
        // and tell the user via stderr (also surfaced in the menu icon
        // tooltip change).
        guard ActiveRecording.read() != nil else {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] Cmd+Shift+A ignored — start a recording first (popover → New recording → Start, or `flow42 record start`)\n".utf8
            ))
            // Subtle audible / visual hint that the keystroke landed but did
            // nothing actionable. NSSound.beep is reserved by accessibility,
            // so we only flash the menu icon briefly.
            flashMenuIcon()
            return
        }

        // The annotation gesture is now armed. We route to the path that
        // matches the CURRENTLY frontmost app — and we keep doing that as
        // the user switches apps mid-gesture, so a session that started
        // in Chrome can finish with a macOS region drag in Notes (or vice
        // versa). Subscribed observers fire `routeForCurrentFrontmost`
        // again whenever NSWorkspace tells us focus moved.
        previousFrontmost = NSWorkspace.shared.frontmostApplication
        armed = true
        subscribeAppActivation()
        let route = routeForCurrentFrontmost()

        // The extension path is fire-and-forget from the menu app's
        // perspective: we wrote the marker file, the extension owns the
        // rest of the gesture (click-to-pick), and there's nothing
        // local to maintain — no overlay window, no event tap, no
        // active drag state. If we leave `armed = true` here, the very
        // next Cmd+Shift+A in Chrome routes through `toggle()` to
        // `cancel()` instead of `arm()`, so every other press becomes a
        // no-op. Disarm immediately so each press is a fresh arm.
        if route == .extension {
            armed = false
            unsubscribeAppActivation()
        }
    }

    private enum AnnotationRoute { case `extension`, native }

    /// Decide which path the annotation gesture should take based on the
    /// currently frontmost app + the user's BrowserMode preference, and
    /// (re)configure things accordingly. Idempotent — safe to call on every
    /// app-switch notification.
    @discardableResult
    private func routeForCurrentFrontmost() -> AnnotationRoute {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isChromium = frontmost?.bundleIdentifier
            .map(LearningConstants.domSidecarBundleIds.contains) ?? false
        let useExtension = isChromium && BrowserMode.current() != .native

        if useExtension {
            // Hand the gesture to the extension; tear down any native UI
            // we had up.
            tearDownNativeOverlay()
            HighlightRequest.arm()
            FileHandle.standardError.write(Data(
                "[Flow42Menu] annotation route → extension highlight (Chrome frontmost)\n".utf8
            ))
            return .extension
        } else {
            // Tell the extension to drop highlight mode (no-op if it
            // wasn't active), then bring up the native overlay.
            HighlightExit.arm()
            presentNativeOverlay()
            FileHandle.standardError.write(Data(
                "[Flow42Menu] annotation route → native overlay (\(frontmost?.localizedName ?? "?") frontmost)\n".utf8
            ))
            return .native
        }
    }

    private func presentNativeOverlay() {
        // Idempotent: if the overlay is already up, do nothing.
        if overlayWindow != nil { return }

        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        activeScreen = screen
        activeScreenSize = screen.frame.size

        startPointGlobal = nil
        currentPointGlobal = nil
        dragRectLocal = nil

        // Suppress native event capture in the recorder daemon while we're
        // armed — the Cmd+Shift+A keystroke and the rectangle-drag clicks
        // are mechanics, not flow.
        SuppressionMarker.arm()

        presentOverlay(on: screen)
        NSCursor.crosshair.push()
        installEventTap()
        updateCursor(global: NSEvent.mouseLocation)
    }

    /// Tear down the native side without disarming the gesture state.
    /// Used when switching from native → extension mid-gesture.
    private func tearDownNativeOverlay() {
        if let window = overlayWindow {
            window.orderOut(nil)
            window.close()
            overlayWindow = nil
        }
        if eventTap != nil {
            removeEventTap()
        }
        if activeScreen != nil {
            NSCursor.pop()
            activeScreen = nil
        }
        SuppressionMarker.disarm()
        startPointGlobal = nil
        currentPointGlobal = nil
        dragRectLocal = nil
        cursorLocal = nil
    }

    // MARK: - App-switch tracking

    private func subscribeAppActivation() {
        if appActivationObserver != nil { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAppActivation() }
        }
    }

    private func unsubscribeAppActivation() {
        if let obs = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appActivationObserver = nil
        }
    }

    private func handleAppActivation() {
        guard armed else { return }
        routeForCurrentFrontmost()
    }

    fileprivate func cancel() {
        teardown()
        FileHandle.standardError.write(Data(
            "[Flow42Menu] annotation cancelled\n".utf8
        ))
    }

    private func teardown() {
        armed = false
        startPointGlobal = nil
        currentPointGlobal = nil
        dragRectLocal = nil
        cursorLocal = nil
        SuppressionMarker.disarm()
        removeEventTap()
        if let window = overlayWindow {
            window.orderOut(nil)
            window.close()
            overlayWindow = nil
        }
        activeScreen = nil
        NSCursor.pop()

        // Cross-app routing cleanup: stop listening for app switches and
        // make sure the extension drops highlight mode if it had it on.
        // Cheap no-op when neither was set.
        unsubscribeAppActivation()
        HighlightExit.arm()
    }

    // MARK: - CGEvent tap

    private func installEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,        // active mode: callback can swallow
            eventsOfInterest: mask,
            callback: annotationEventTapCallback,
            userInfo: userInfo
        ) else {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] CGEvent tap creation failed — Accessibility permission?\n".utf8
            ))
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            eventTapSource = nil
        }
        eventTap = nil
    }

    /// Convert a CGEvent location (origin top-left of primary, Y down) to
    /// AppKit global coords (origin bottom-left of primary, Y up). Same
    /// convention as `NSEvent.mouseLocation`.
    fileprivate static func cgToAppKit(_ p: CGPoint) -> CGPoint {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let h = primary?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    /// Called from the CGEvent tap callback (already on main runloop).
    fileprivate func handleTappedMouse(type: CGEventType, location: CGPoint) {
        guard armed else { return }
        let p = Self.cgToAppKit(location)
        switch type {
        case .leftMouseDown:
            startPointGlobal = p
            currentPointGlobal = p
            updateCursor(global: p)
            updateDragRect()
        case .leftMouseDragged:
            currentPointGlobal = p
            updateCursor(global: p)
            updateDragRect()
        case .leftMouseUp:
            currentPointGlobal = p
            updateCursor(global: p)
            updateDragRect()
            commit()
        case .mouseMoved:
            updateCursor(global: p)
        default:
            break
        }
    }

    private func updateCursor(global p: CGPoint) {
        guard let screen = activeScreen else {
            cursorLocal = nil
            return
        }
        cursorLocal = CGPoint(
            x: p.x - screen.frame.minX,
            y: screen.frame.maxY - p.y
        )
    }

    private func updateDragRect() {
        guard let s = startPointGlobal,
              let c = currentPointGlobal,
              let screen = activeScreen else {
            dragRectLocal = nil
            return
        }
        let globalRect = CGRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
        // Convert to the overlay's local SwiftUI coords (origin top-left of
        // the screen's window, Y increasing downward).
        dragRectLocal = CGRect(
            x: globalRect.minX - screen.frame.minX,
            y: screen.frame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func commit() {
        guard let s = startPointGlobal, let c = currentPointGlobal else {
            teardown(); return
        }
        let globalRect = CGRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
        let frontApp = previousFrontmost
        let screen = activeScreen

        teardown()  // remove monitors + overlay before async work

        if globalRect.width < 4 || globalRect.height < 4 {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] annotation skipped — drag too small\n".utf8
            ))
            return
        }

        Task {
            await self.captureAndWrite(
                globalRect: globalRect,
                screen: screen,
                frontApp: frontApp
            )
        }
    }

    // MARK: - Overlay

    private func presentOverlay(on screen: NSScreen) {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true   // CRITICAL — lets clicks pass through
        // Hide from recordings + screenshots — same exclusion the
        // floating panel and edge glow use. Annotations are visual
        // chrome the user sees on top of their app, but the recorder's
        // per-step screenshots should show the underlying app, not
        // our crosshair / drag rect.
        panel.sharingType = .none

        let host = NSHostingView(rootView: AnnotationOverlayView(controller: self))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        overlayWindow = panel
    }

    // MARK: - Capture + write

    private func captureAndWrite(
        globalRect: CGRect,
        screen: NSScreen?,
        frontApp: NSRunningApplication?
    ) async {
        // Highlights live alongside the recording's other event artifacts
        // — no more standalone ~/.flow42/annotations/<id>/ folder.
        // We need the active recording's directory; arm() already verified
        // one is in progress.
        guard let active = ActiveRecording.read(),
              let recordingDir = active["dir"] as? String else {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] annotation save aborted — no active recording dir\n".utf8
            ))
            return
        }
        let shotsDir = (recordingDir as NSString).appendingPathComponent("screenshots")
        try? FileManager.default.createDirectory(
            atPath: shotsDir, withIntermediateDirectories: true
        )
        // Pick a slot number that doesn't collide with existing highlights.
        let slotIndex = nextHighlightSlot(in: shotsDir)
        let baseName = String(format: "highlight-%03d", slotIndex)
        // The staging filenames live under screenshots/ briefly while we
        // capture the region image and run AX + OCR; writeHighlightStepFolder
        // promotes them into the canonical step folder afterward.
        let regionAbs = (shotsDir as NSString).appendingPathComponent("\(baseName).png")
        let axAbs     = (shotsDir as NSString).appendingPathComponent("\(baseName).ax.json")
        let visionAbs = (shotsDir as NSString).appendingPathComponent("\(baseName).vision.json")

        let probe = CGPoint(x: globalRect.midX, y: globalRect.midY)
        let resolvedScreen = screen
            ?? NSScreen.screens.first { $0.frame.contains(probe) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let resolvedScreen else { return }

        let localRect = CGRect(
            x: globalRect.origin.x - resolvedScreen.frame.origin.x,
            y: globalRect.origin.y - resolvedScreen.frame.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )

        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? resolvedScreen.frame.height
        let axRect = CGRect(
            x: globalRect.origin.x,
            y: primaryHeight - globalRect.origin.y - globalRect.height,
            width: globalRect.width,
            height: globalRect.height
        )

        let displayId = resolvedScreen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID ?? CGMainDisplayID()

        let captureImage = await captureRegionImage(
            displayId: displayId,
            sourceRectInDisplayPoints: localRect,
            screenScale: resolvedScreen.backingScaleFactor
        )
        var captured = false
        if let img = captureImage {
            captured = writePNG(cgImage: img, to: regionAbs)
        }

        // OCR the captured image off-thread. Cheap (Vision is on-device,
        // sub-second for typical screenshot regions) and the agent gets a
        // signal that AX won't always provide.
        var ocrBlockCount = 0
        var ocrFullText: String? = nil
        if let img = captureImage {
            let task = Task.detached(priority: .userInitiated) {
                RegionVision.analyze(cgImage: img)
            }
            if let result = await task.value {
                ocrBlockCount = result.blocks.count
                ocrFullText = result.fullText
                let payload = RegionVision.toJSON(result)
                if let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                ) {
                    try? data.write(to: URL(fileURLWithPath: visionAbs))
                }
            }
        }

        let elements = RegionAX.extract(rect: axRect, pid: frontApp?.processIdentifier)
        let axPayload: [String: Any] = [
            "rect_ax": [
                "x": Double(axRect.origin.x),
                "y": Double(axRect.origin.y),
                "width": Double(axRect.width),
                "height": Double(axRect.height),
            ],
            "app": frontApp?.localizedName ?? NSNull(),
            "bundle_id": frontApp?.bundleIdentifier ?? NSNull(),
            "element_count": elements.count,
            "elements": elements,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: axPayload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? data.write(to: URL(fileURLWithPath: axAbs))
        }

        // Write a self-contained step folder under steps/NNNN-highlight/
        // with the region image, AX subtree, and vision sidecar moved in.
        // events.jsonl gets a one-line summary the menu timeline and the
        // structuring agent's Pass 1 will read.
        //
        // The step's meta.yaml is enriched with two text representations
        // of the captured region so an agent never has to read the
        // sidecar files for the common case:
        //   - ocr_text:     full OCR transcript from the screenshot pixels
        //                   (Vision framework). Useful for canvas-rendered
        //                   text, screenshots-of-screenshots, etc.
        //   - text_content: text drawn from the AX subtree — element names,
        //                   labels, values. Useful for structured grounding.
        writeHighlightStepFolder(
            to: recordingDir,
            rect: globalRect,
            regionAbs: regionAbs,
            axAbs: axAbs,
            visionAbs: visionAbs,
            ocrText: ocrFullText,
            textContent: Self.flattenAXText(elements),
            axElementCount: elements.count,
            appName: frontApp?.localizedName,
            bundleId: frontApp?.bundleIdentifier
        )

        FileHandle.standardError.write(Data(
            "[Flow42Menu] highlight \(baseName) — region:\(captured ? "ok" : "FAILED"), ax:\(elements.count), ocr:\(ocrBlockCount), app:\(frontApp?.localizedName ?? "?")\n".utf8
        ))
    }

    /// Find the next unused highlight slot (NNN) in the recording's
    /// screenshots dir. Avoids overwriting an earlier highlight if the
    /// user takes several in one session.
    private nonisolated func nextHighlightSlot(in shotsDir: String) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: shotsDir)
        else { return 1 }
        var max = 0
        for entry in entries {
            // highlight-NNN.png / .ax.json / .vision.json
            guard entry.hasPrefix("highlight-") else { continue }
            let stripped = entry.dropFirst("highlight-".count)
            // Take the numeric portion before the first '.'
            let n = stripped.prefix(while: { $0.isNumber })
            if let value = Int(n), value > max { max = value }
        }
        return max + 1
    }

    private func captureRegionImage(
        displayId: CGDirectDisplayID,
        sourceRectInDisplayPoints: CGRect,
        screenScale: CGFloat
    ) async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayId })
                ?? content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = sourceRectInDisplayPoints
            let pixelW = Int((sourceRectInDisplayPoints.width * screenScale).rounded())
            let pixelH = Int((sourceRectInDisplayPoints.height * screenScale).rounded())
            cfg.width = max(1, pixelW)
            cfg.height = max(1, pixelH)
            cfg.scalesToFit = true
            cfg.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: cfg
            )
        } catch {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] capture failed: \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
    }

    /// v2 path: write a self-contained step folder for this highlight.
    /// Region PNG, AX subtree, and vision sidecar are MOVED into
    /// `steps/NNNN-highlight/` (the legacy Phase-A `screenshots/highlight-NNN.*`
    /// staging files have already been written by the caller; this method
    /// promotes them into the canonical step layout). The events.jsonl
    /// line gets `source: "annotation"` so consumers can tell native
    /// CGEvent-tap events apart from menu-app-sourced ones.
    ///
    /// Step index race: the recorder daemon and the menu app both allocate
    /// step indices independently; we reduce the collision window by
    /// scanning `steps/` right before the write. If two writers somehow
    /// pick the same index, StepFolderWriter's `mkdir -p` is idempotent
    /// and the second writer's content lands in the first writer's folder
    /// — annoying but not data loss. Phase B will replace this with a
    /// single allocator on the daemon side.
    private func writeHighlightStepFolder(
        to recordingDir: String,
        rect: CGRect,
        regionAbs: String,
        axAbs: String,
        visionAbs: String,
        ocrText: String?,
        textContent: String?,
        axElementCount: Int,
        appName: String?,
        bundleId: String?
    ) {
        let stepIndex = StepFolderWriter.highestExistingIndex(in: recordingDir) + 1
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Per-step meta carries the same fields the legacy external-events
        // line did, plus the rect coordinates and (optionally) the inline
        // text representations. StepFolderWriter rewrites `screenshot`,
        // `ax_path`, and `vision_path` to point at the destination
        // filenames inside the step folder.
        var meta: [String: Any] = [
            "action_type": "highlight",
            "source": "annotation",
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.width),
            "height": Double(rect.height),
            "ax_element_count": axElementCount,
            "app": appName ?? "",
            "bundle_id": bundleId ?? "",
            "timestamp_ms": timestampMs,
        ]
        if let ocrText, !ocrText.isEmpty { meta["ocr_text"] = ocrText }
        if let textContent, !textContent.isEmpty { meta["text_content"] = textContent }

        // Sidecars: ax.json + vision.json get loaded into memory and
        // re-emitted by StepFolderWriter inside the step folder. We
        // remove the staging originals after so the screenshots/ dir
        // doesn't accumulate orphans across a session.
        var sidecars: [String: Data] = [:]
        if let axData = try? Data(contentsOf: URL(fileURLWithPath: axAbs)) {
            sidecars["ax.json"] = axData
        }
        if FileManager.default.fileExists(atPath: visionAbs),
           let visionData = try? Data(contentsOf: URL(fileURLWithPath: visionAbs)) {
            sidecars["vision.json"] = visionData
        }
        // Clean up the staging copies — region.png is moved by
        // StepFolderWriter, ax + vision JSONs are not (they were read
        // as Data above), so we delete them by hand.
        try? FileManager.default.removeItem(atPath: axAbs)
        try? FileManager.default.removeItem(atPath: visionAbs)

        let outcome = StepFolderWriter.writeNewStep(
            recordingDir: recordingDir,
            stepIndex: stepIndex,
            actionType: "highlight",
            meta: meta,
            screenshotSourceAbs: regionAbs,
            annotatedScreenshotSourceAbs: nil,         // no marker — the
                                                       // region itself is
                                                       // the visual.
            sidecars: sidecars,
            screenshotDestName: "region.png"
        )

        guard let outcome else { return }

        // events.jsonl line. We hand-build it (rather than going through
        // LearningDispatch.serializeIndexEntry, which expects an
        // ObservedAction) because annotations don't have one of those —
        // they live in a different process entirely.
        let summary = "highlight \(Int(rect.width))×\(Int(rect.height))"
            + (appName.map { " in \($0)" } ?? "")
        let entry: [String: Any] = [
            "idx": outcome.stepIndex,
            "step_dir": outcome.stepDirRelative,
            "action_type": "highlight",
            "app": appName ?? "",
            "summary": summary,
            "timestamp_ms": timestampMs,
            "source": "annotation",
        ]
        EventsJSONLWriter.append(to: recordingDir, entry: entry)
    }

    /// Concatenate the readable text out of an AX subtree dump. Walks the
    /// elements (already in roughly reading order — DFS pre-order) and
    /// joins their `name` and `value` fields, skipping role placeholders.
    /// The result is a plain-text "what the AX tree says under this rect"
    /// string — the structural counterpart to the OCR transcript.
    fileprivate nonisolated static func flattenAXText(_ elements: [[String: Any]]) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for el in elements {
            // Prefer the visible label.
            let candidates: [String] = [
                el["name"] as? String,
                el["text"] as? String,
                el["value"] as? String,
            ].compactMap { s in
                guard let s, !s.isEmpty else { return nil }
                return s
            }
            for raw in candidates {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // Cheap dedup: AX trees often repeat the same label across
                // a parent + child (e.g. button name on the AXButton AND on
                // an inner AXStaticText).
                if seen.contains(trimmed) { continue }
                seen.insert(trimmed)
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func writePNG(cgImage: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, cgImage, nil)
        return CGImageDestinationFinalize(dest)
    }
}

// MARK: - CGEvent tap callback (file scope)

/// Called by Quartz Event Services on the runloop where we registered the
/// tap (the main runloop, in our case). Two responsibilities:
///   1. Update the controller's drag/cursor state. We dispatch to main async
///      because @Published mutations + window calls must happen on a
///      MainActor; doing them inline could deadlock or hit isolation errors.
///   2. Decide whether to forward or swallow the event. Returning nil
///      swallows — that's the whole point: macOS itself never sees the
///      mouse-down so it can't start a window resize or text selection.
///
/// We swallow: every left/right/other mouse-down, mouse-up, and drag, plus
/// Esc keystrokes. We forward: mouseMoved (so cursor shape can still update
/// over text fields, etc.) and any other key event.
private nonisolated func annotationEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<AnnotationController>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable on tap timeouts (system disables us if our callback runs long).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            if let tap = controller.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    let location = event.location

    if type == .keyDown {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if keycode == 53 {                     // Esc
            Task { @MainActor in controller.cancel() }
            return nil                          // swallow Esc
        }
        return Unmanaged.passUnretained(event)  // forward other keys
    }

    // Drag/mouse state updates run on main; the tap returns immediately.
    Task { @MainActor in controller.handleTappedMouse(type: type, location: location) }

    switch type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
         .rightMouseDown, .rightMouseUp, .rightMouseDragged,
         .otherMouseDown, .otherMouseUp:
        return nil                              // swallow click / drag
    default:
        return Unmanaged.passUnretained(event)  // forward mouseMoved etc.
    }
}
