// LearningRecorder.swift - CGEvent tap lifecycle and action recording
//
// Owns the background thread, CGEvent tap, and thread-safe action buffer.
// All methods are nonisolated because this class manages its own thread safety
// via os_unfair_lock. Uses learningLog() instead of Log because Log inherits
// MainActor from the package default and cannot be called from background threads.

import ApplicationServices
import AppKit
import Foundation

/// Records user input events during learning mode.
/// Thread-safe via os_unfair_lock. Accessed from both the main thread
/// (MCP dispatch) and the learning thread (CGEvent callback).
nonisolated public final class LearningRecorder: @unchecked Sendable {

    public static let shared = LearningRecorder()

    // MARK: - Lock-protected state

    private var lock = os_unfair_lock()
    private var session: LearningSession?
    private var eventTap: CFMachPort?
    private var learningRunLoop: CFRunLoop?
    private var learningThread: Thread?

    // Keystroke coalescing -- only access within withLock or flushPending* (caller holds lock)
    internal var pendingKeystrokes: String = ""
    internal var pendingKeystrokeTimestamp: UInt64 = 0
    internal var pendingKeystrokeApp: String = ""
    internal var pendingKeystrokeBundleId: String = ""
    internal var pendingKeystrokeWindow: String?
    internal var pendingKeystrokeUrl: String?
    internal var pendingKeystrokeElement: ElementContext?
    private var keystrokeFlushTimer: CFRunLoopTimer?

    // Max duration safety timer
    private var maxDurationTimer: CFRunLoopTimer?

    // Scroll coalescing -- only access within withLock or flushPending* (caller holds lock)
    internal var pendingScrollDeltaX: Int = 0
    internal var pendingScrollDeltaY: Int = 0
    internal var pendingScrollX: Double = 0
    internal var pendingScrollY: Double = 0
    internal var pendingScrollTimestamp: UInt64 = 0
    internal var pendingScrollApp: String = ""
    internal var pendingScrollBundleId: String = ""
    private var scrollFlushTimer: CFRunLoopTimer?

    private var lastRecordedAppName: String = ""

    /// Last-seen browser context (URL, bundle id, tab count, window title).
    /// Tracked across CGEvents so URLChangeDetector can emit a single
    /// urlChange / newTab / tabSwitch on transition.
    private var lastBrowser: URLChangeDetector.LastSeen = URLChangeDetector.LastSeen()

    /// PID of the Flow42 menu bar app, captured at record-start and used to
    /// drop click events that target the menu app's status item or popover
    /// — those are recording mechanics, not the user's flow.
    /// 0 = "menu app not running", check skipped.
    private var menuAppPid: pid_t = 0

    private init() {}

    // MARK: - Public API

    public var isRecording: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return session != nil
    }

    /// Start recording. Returns nil on success, or a LearningError.
    /// If `recordingDir` is provided, per-event screenshots will land in
    /// `<recordingDir>/screenshots/`. Pass nil to skip screenshot capture.
    public func start(taskDescription: String?, recordingDir: String? = nil) -> LearningError? {
        os_unfair_lock_lock(&lock)
        if session != nil { os_unfair_lock_unlock(&lock); return .alreadyRecording }
        session = LearningSession(taskDescription: taskDescription, recordingDir: recordingDir)
        lastRecordedAppName = ""
        lastBrowser = URLChangeDetector.LastSeen()
        // Cache the menu app's PID so the click-filter below can drop events
        // targeting our own popover / status item without a per-event lookup.
        menuAppPid = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.web42.flow42.menu"
        }?.processIdentifier ?? 0
        os_unfair_lock_unlock(&lock)
        // Clear any stale suppression marker (from a crashed prior session
        // of the menu app's annotation overlay).
        SuppressionMarker.disarm()

        // Pre-create the screenshots dir so the first capture doesn't race.
        if let dir = recordingDir {
            let shotsDir = (dir as NSString).appendingPathComponent("screenshots")
            try? FileManager.default.createDirectory(
                atPath: shotsDir,
                withIntermediateDirectories: true
            )
        }

        let thread = Thread { [weak self] in self?.runLearningThread() }
        thread.name = "flow42-learning"
        thread.qualityOfService = .userInteractive
        learningThread = thread
        thread.start()

        // Busy-wait up to 500ms for tap creation
        for _ in 0..<50 {
            Thread.sleep(forTimeInterval: 0.01)
            os_unfair_lock_lock(&lock)
            let ready = eventTap != nil
            os_unfair_lock_unlock(&lock)
            if ready { learningLog("INFO", "Learning: recording started"); return nil }
        }

        os_unfair_lock_lock(&lock)
        let failed = eventTap == nil
        if failed { session = nil }
        os_unfair_lock_unlock(&lock)
        return failed ? .inputMonitoringNotGranted : nil
    }

    /// Stop recording and return the session with its recorded actions.
    public func stop() -> Result<(LearningSession, [ObservedAction]), LearningError> {
        os_unfair_lock_lock(&lock)
        guard var cur = session else { os_unfair_lock_unlock(&lock); return .failure(.notRecording) }
        flushPendingKeystrokes(into: &cur)
        flushPendingScroll(into: &cur)
        let actions = cur.actions
        let result = cur
        session = nil
        os_unfair_lock_unlock(&lock)

        if let rl = learningRunLoop { CFRunLoopStop(rl) }
        for _ in 0..<200 {
            if learningThread?.isFinished == true { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        learningThread = nil; learningRunLoop = nil

        if actions.isEmpty { return .failure(.noActionsRecorded) }
        learningLog("INFO", "Learning: stopped, recorded \(actions.count) actions")
        return .success((result, actions))
    }

    public func status() -> (isRecording: Bool, actionCount: Int, durationSeconds: Double, currentApp: String?) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard let session else { return (false, 0, 0, nil) }
        let duration = Date().timeIntervalSince(session.startTime)
        return (true, session.actions.count, duration, lastRecordedAppName.isEmpty ? nil : lastRecordedAppName)
    }

    // MARK: - Background Thread

    private func runLearningThread() {
        var mask: CGEventMask = 0
        for t: CGEventType in [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel] {
            mask |= (1 << t.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: learningEventCallback, userInfo: userInfo
        ) else {
            learningLog("ERROR", "Learning: CGEvent tap creation failed (Input Monitoring not granted?)")
            os_unfair_lock_lock(&lock); session = nil; os_unfair_lock_unlock(&lock)
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let rl = CFRunLoopGetCurrent()!
        os_unfair_lock_lock(&lock); eventTap = tap; learningRunLoop = rl; os_unfair_lock_unlock(&lock)

        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Safety timer: auto-stop after max recording duration to prevent runaway recordings
        let maxFire = CFAbsoluteTimeGetCurrent() + LearningConstants.maxRecordingDurationSeconds
        let maxTimer = CFRunLoopTimerCreateWithHandler(nil, maxFire, 0, 0, 0) { _ in
            learningLog("WARN", "Learning: max recording duration reached (\(Int(LearningConstants.maxRecordingDurationSeconds))s), stopping event tap")
            // Stop the run loop but preserve the session so stop() can harvest the data
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopAddTimer(rl, maxTimer, .commonModes)
        os_unfair_lock_lock(&lock); maxDurationTimer = maxTimer; os_unfair_lock_unlock(&lock)

        learningLog("INFO", "Learning: CGEvent tap started on background thread")
        CFRunLoopRun()

        // Cleanup
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(rl, source, .commonModes)
        os_unfair_lock_lock(&lock)
        eventTap = nil
        invalidateTimer(&keystrokeFlushTimer)
        invalidateTimer(&scrollFlushTimer)
        invalidateTimer(&maxDurationTimer)
        os_unfair_lock_unlock(&lock)
        learningLog("INFO", "Learning: CGEvent tap stopped, thread exiting")
    }

    private func invalidateTimer(_ timer: inout CFRunLoopTimer?) {
        if let t = timer { CFRunLoopTimerInvalidate(t); timer = nil }
    }

    // MARK: - Event Handling (learning thread)

    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            os_unfair_lock_lock(&lock)
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            os_unfair_lock_unlock(&lock)
            learningLog("WARN", "Learning: event tap re-enabled after system disabled it")
            return
        }
        os_unfair_lock_lock(&lock)
        guard session != nil else { os_unfair_lock_unlock(&lock); return }
        var localLastApp = lastRecordedAppName
        var localLastBrowser = lastBrowser
        os_unfair_lock_unlock(&lock)

        AppSwitchDetector.checkAndRecord(recorder: self, lastRecordedApp: &localLastApp)
        // Synthesize browser nav events when we're in BrowserMode.native; the
        // detector self-gates on mode and on the frontmost being a known
        // browser bundle id, so this is a near-no-op outside that context.
        URLChangeDetector.checkAndRecord(
            recorder: self,
            last: &localLastBrowser
        )

        os_unfair_lock_lock(&lock)
        lastRecordedAppName = localLastApp
        lastBrowser = localLastBrowser
        os_unfair_lock_unlock(&lock)

        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           LearningConstants.restrictedBundleIds.contains(bid) { return }

        // Hardcoded filter for the Cmd+Shift+A keystroke that triggers our
        // own annotation overlay. The suppression marker (armed by the menu
        // app's AnnotationController) wins for the drag clicks but loses
        // the race for the trigger keystroke itself, so we drop it here
        // unconditionally — flow42 owns this keybinding by design.
        if type == .keyDown {
            let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            // kVK_ANSI_A = 0
            if keycode == 0
                && flags.contains(.maskCommand)
                && flags.contains(.maskShift) {
                return
            }
        }

        // Suppression marker — set by the Flow42 menu app while its
        // annotation overlay is armed. Drops the drag-clicks that define
        // the rectangle so they don't appear in the flow as native events.
        // The annotation itself goes in via external-events.jsonl as a
        // "highlight" event.
        if SuppressionMarker.exists() { return }

        // Click-target filter: clicks on the menu bar app's status item or
        // popover are recording-mechanic noise (clicking Start/Stop, opening
        // the popover) — not part of the user's actual flow. The bundle-id
        // check above doesn't catch these because .accessory apps don't
        // become frontmost when their status item is clicked.
        if menuAppPid != 0,
           (type == .leftMouseDown || type == .leftMouseUp
            || type == .rightMouseDown || type == .rightMouseUp),
           clickTargetsPID(menuAppPid, eventLocation: event.location) {
            return
        }

        switch type {
        case .keyDown: EventHandlers.handleKeyDown(event, recorder: self)
        case .leftMouseDown, .rightMouseDown: EventHandlers.handleMouseDown(type, event, recorder: self)
        case .scrollWheel: EventHandlers.handleScroll(event, recorder: self)
        default: break
        }
    }

    /// Walk top-of-z-order on-screen windows looking for the one under
    /// `eventLocation`. Return true if its owner PID matches `pid`.
    /// `kCGWindowBounds` and `CGEvent.location` are both in CG global coords
    /// (top-left origin, Y down) so we compare them directly.
    private func clickTargetsPID(_ pid: pid_t, eventLocation: CGPoint) -> Bool {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for info in windows {
            guard let pidNum = info[kCGWindowOwnerPID as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double,
                  let h = bounds["Height"] as? Double
            else { continue }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            if frame.contains(eventLocation) {
                // Z-order: first on-screen window containing the point is
                // the topmost. If THAT window is ours, the click is ours.
                return pid_t(pidNum) == pid
            }
        }
        return false
    }

    // MARK: - Action Recording

    public func appendAction(_ action: ObservedAction) {
        var snapshot: LearningSession? = nil
        os_unfair_lock_lock(&lock)

        // Same-target coalescing for typeText: when the previous action is
        // also a typeText on what looks like the SAME field and the gap is
        // under 5 minutes, merge instead of emitting a second event. This
        // collapses "type 'hello', pause, type ' world'" → one
        // typeText("hello world") action. Backspace handling is in
        // handleBackspaceIfTextEdit() — those mutate the same last action
        // in-place rather than emitting keyPress(Delete).
        let coalesced: Bool = {
            guard case .typeText(let newText) = action.action,
                  let lastIdx = session?.actions.indices.last,
                  let prev = session?.actions[lastIdx],
                  case .typeText(let prevText) = prev.action,
                  Self.sameTypingTarget(
                    prev: prev,
                    currentApp: action.appName,
                    currentBundleId: action.appBundleId,
                    currentTarget: action.elementContext
                  ),
                  Self.machDeltaToSeconds(action.timestamp &- prev.timestamp) < 300
            else { return false }

            let merged = ObservedAction(
                timestamp: prev.timestamp,            // keep original onset
                action: .typeText(text: prevText + newText),
                appName: action.appName,
                appBundleId: action.appBundleId,
                windowTitle: action.windowTitle,
                url: action.url,
                elementContext: action.elementContext,
                screenshotPath: action.screenshotPath ?? prev.screenshotPath,
                annotatedScreenshotPath: action.annotatedScreenshotPath ?? prev.annotatedScreenshotPath
            )
            session?.actions[lastIdx] = merged
            return true
        }()

        if !coalesced {
            session?.actions.append(action)
        }
        if !action.appName.isEmpty { session?.apps.insert(action.appName) }
        if let url = action.url, !url.isEmpty, !(session?.urls.contains(url) ?? false) {
            session?.urls.append(url)
        }
        snapshot = session
        os_unfair_lock_unlock(&lock)

        // flow.json is the single source of truth — rewritten on every
        // action append. Atomic (write-temp + rename) so the menu app's
        // tailer never reads a half-written file. Done outside the lock
        // because it's slow I/O and we already snapshot the session.
        if let snapshot, let dir = snapshot.recordingDir {
            FlowJSONWriter.write(session: snapshot, slug: snapshotSlug(dir: dir), dir: dir)
        }
    }

    /// The slug is encoded in the recording dir's last path component.
    /// We don't store it on the session because it never changes per session.
    private nonisolated func snapshotSlug(dir: String) -> String {
        return (dir as NSString).lastPathComponent
    }

    // MARK: - Gesture arena: backspace handling

    /// Handle a Backspace keystroke as a text-edit gesture. Returns:
    ///   - true: the keystroke was consumed (the caller must NOT emit a
    ///     keyPress event). One char was either popped from the active
    ///     pending buffer or trimmed from the previous typeText action
    ///     (which may now be empty and therefore removed from the session).
    ///   - false: there's nothing to edit. Emit the keystroke normally as a
    ///     keyPress event. This is the behavior the user opted for in the
    ///     plan: keep the press visible so an agent can later decide whether
    ///     it was a mistake or a real action (e.g. "delete a list item").
    public func handleBackspaceIfTextEdit(
        currentApp: String,
        currentBundleId: String,
        currentTarget: ElementContext?
    ) -> Bool {
        let consumed = applyImmediateTextEdit(
            currentApp: currentApp,
            currentBundleId: currentBundleId,
            currentTarget: currentTarget,
            transform: { Self.dropLastChar($0) }
        )
        if consumed {
            scheduleAXReadCorrection(
                currentApp: currentApp,
                currentBundleId: currentBundleId,
                currentTarget: currentTarget
            )
        }
        return consumed
    }

    /// Shared transform helper for backspace.
    fileprivate nonisolated static func dropLastChar(_ s: String) -> String {
        var s = s
        if !s.isEmpty { s.removeLast() }
        return s
    }

    /// Single code path for "edit hotkey arrived while focus is on a text
    /// field" — applies an immediate transform to the active buffer or the
    /// previous typeText action so the live timeline reflects the change
    /// right away. The AX-read correction (`scheduleAXReadCorrection`) then
    /// overwrites with the field's actual value ~60 ms later, so any
    /// approximation here gets corrected.
    private func applyImmediateTextEdit(
        currentApp: String,
        currentBundleId: String,
        currentTarget: ElementContext?,
        transform: @Sendable (String) -> String
    ) -> Bool {
        var snapshot: LearningSession? = nil
        var consumed = false

        os_unfair_lock_lock(&lock)

        // 1. Active typing buffer? Apply transform there.
        if !pendingKeystrokes.isEmpty {
            pendingKeystrokes = transform(pendingKeystrokes)
            os_unfair_lock_unlock(&lock)
            scheduleKeystrokeFlushTimer()
            return true
        }

        // 2. Otherwise, mutate the previous typeText if it targets the same field.
        if let lastIdx = session?.actions.indices.last,
           let prev = session?.actions[lastIdx],
           case .typeText(let prevText) = prev.action,
           !prevText.isEmpty,
           Self.sameTypingTarget(
            prev: prev,
            currentApp: currentApp,
            currentBundleId: currentBundleId,
            currentTarget: currentTarget
           ) {
            let trimmed = transform(prevText)
            if trimmed.isEmpty {
                session?.actions.remove(at: lastIdx)
            } else {
                session?.actions[lastIdx] = ObservedAction(
                    timestamp: prev.timestamp,
                    action: .typeText(text: trimmed),
                    appName: prev.appName,
                    appBundleId: prev.appBundleId,
                    windowTitle: prev.windowTitle,
                    url: prev.url,
                    elementContext: prev.elementContext,
                    screenshotPath: prev.screenshotPath,
                    annotatedScreenshotPath: prev.annotatedScreenshotPath
                )
            }
            consumed = true
            snapshot = session
        }

        os_unfair_lock_unlock(&lock)

        if consumed, let snapshot, let dir = snapshot.recordingDir {
            FlowJSONWriter.write(session: snapshot, slug: snapshotSlug(dir: dir), dir: dir)
        }
        return consumed
    }

    /// Schedule an AX-read against the currently focused field (60 ms out
    /// — the OS needs that long to finish processing the edit) and use the
    /// returned value as the authoritative text. This corrects any drift
    /// between our local approximations (single-char trim, word-trim,
    /// line-trim) and what the field actually contains. If the read fails
    /// (no AX, focus moved, value not a String) we silently keep our
    /// approximation.
    private func scheduleAXReadCorrection(
        currentApp: String,
        currentBundleId: String,
        currentTarget: ElementContext?
    ) {
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                guard let value = EventHandlers.readFocusedTextFieldValue()
                else { return }
                self.applyAXReadValue(
                    value,
                    currentApp: currentApp,
                    currentBundleId: currentBundleId,
                    currentTarget: currentTarget
                )
            }
    }

    private func applyAXReadValue(
        _ value: String,
        currentApp: String,
        currentBundleId: String,
        currentTarget: ElementContext?
    ) {
        var snapshot: LearningSession? = nil
        var sessionChanged = false

        os_unfair_lock_lock(&lock)

        // CRITICAL: these two paths are MUTUALLY EXCLUSIVE. The AX value
        // we just read is the content of whatever element is currently
        // focused. If a typing buffer is active, that buffer represents
        // typing on the current element — so the buffer's content is what
        // should change, not any previously-emitted typeText event (which
        // may have targeted a different element if focus moved between
        // events). Treating both as "the same target" — which would happen
        // when role-fallback matches in apps like Notes (two AXTextAreas
        // in one window) — would overwrite the title's event with the
        // body's text. So: buffer wins when present, prev typeText only
        // when there's no buffer.
        if !pendingKeystrokes.isEmpty {
            if pendingKeystrokes != value {
                pendingKeystrokes = value
            }
            // No session mutation; the buffer is internal state that
            // surfaces in flow.json only at flush time.
        } else if let lastIdx = session?.actions.indices.last,
                  let prev = session?.actions[lastIdx],
                  case .typeText(let prevText) = prev.action,
                  Self.sameTypingTarget(
                    prev: prev,
                    currentApp: currentApp,
                    currentBundleId: currentBundleId,
                    currentTarget: currentTarget
                  ),
                  prevText != value {
            if value.isEmpty {
                session?.actions.remove(at: lastIdx)
            } else {
                session?.actions[lastIdx] = ObservedAction(
                    timestamp: prev.timestamp,
                    action: .typeText(text: value),
                    appName: prev.appName,
                    appBundleId: prev.appBundleId,
                    windowTitle: prev.windowTitle,
                    url: prev.url,
                    elementContext: prev.elementContext,
                    screenshotPath: prev.screenshotPath,
                    annotatedScreenshotPath: prev.annotatedScreenshotPath
                )
            }
            sessionChanged = true
            snapshot = session
        }

        os_unfair_lock_unlock(&lock)

        if sessionChanged, let snapshot, let dir = snapshot.recordingDir {
            FlowJSONWriter.write(session: snapshot, slug: snapshotSlug(dir: dir), dir: dir)
        }
    }

    /// Option+Delete: drop the trailing word as the immediate approximation,
    /// then schedule an AX-read correction that overwrites with the field's
    /// actual value once the OS has processed the edit.
    public func handleWordDeleteIfTextEdit(
        currentApp: String,
        currentBundleId: String,
        currentTarget: ElementContext?
    ) -> Bool {
        let consumed = applyImmediateTextEdit(
            currentApp: currentApp,
            currentBundleId: currentBundleId,
            currentTarget: currentTarget,
            transform: { Self.dropTrailingWord($0) }
        )
        if consumed {
            scheduleAXReadCorrection(
                currentApp: currentApp,
                currentBundleId: currentBundleId,
                currentTarget: currentTarget
            )
        }
        return consumed
    }

    /// Drop trailing whitespace, then drop trailing word characters. Mirrors
    /// macOS Option+Delete in a text field: "type 'hello world '" + Opt+Del
    /// → "type 'hello '"; "type 'hello'" + Opt+Del → "type ''".
    fileprivate nonisolated static func dropTrailingWord(_ s: String) -> String {
        var s = s
        while let last = s.last, last.isWhitespace {
            s.removeLast()
        }
        while let last = s.last, !last.isWhitespace {
            s.removeLast()
        }
        return s
    }

    /// Cmd+Delete: drop the current line as the immediate approximation,
    /// then AX-read correction does the rest.
    public func handleLineDeleteIfTextEdit(
        currentApp: String,
        currentBundleId: String,
        currentTarget: ElementContext?
    ) -> Bool {
        let consumed = applyImmediateTextEdit(
            currentApp: currentApp,
            currentBundleId: currentBundleId,
            currentTarget: currentTarget,
            transform: { Self.dropTrailingLine($0) }
        )
        if consumed {
            scheduleAXReadCorrection(
                currentApp: currentApp,
                currentBundleId: currentBundleId,
                currentTarget: currentTarget
            )
        }
        return consumed
    }

    /// Drop everything from the end back to the most recent newline (or to
    /// the start of the string when there is none). Approximates macOS
    /// Cmd+Delete in a text field.
    fileprivate nonisolated static func dropTrailingLine(_ s: String) -> String {
        var s = s
        while let last = s.last, !last.isNewline {
            s.removeLast()
        }
        return s
    }

    /// Two typeText events target "the same field" only when we can prove
    /// it: same app bundle AND a non-empty STRONG identity signal that
    /// matches on both sides. Strong signals are AX identifier, DOM id,
    /// or computed name.
    ///
    /// Apps that expose these signals (most native macOS apps with proper
    /// AX, well-instrumented web pages) get coalescing.
    /// Apps that don't (Electron / Chromium-based — Claude Desktop, Slack,
    /// VS Code, Apple Notes' two AXTextAreas-with-empty-identifiers) get
    /// separate events per typing burst. That's the conservative trade-off:
    /// when in doubt, don't merge. Two events with a tiny gap between them
    /// are better than one event whose text was silently corrupted because
    /// we mistook the title field for the body.
    fileprivate nonisolated static func sameTypingTarget(
        prev: ObservedAction,
        currentApp: String,
        currentBundleId: String,
        currentTarget: ElementContext?
    ) -> Bool {
        if prev.appBundleId != currentBundleId { return false }

        let prevStrong = nonEmpty(prev.elementContext?.identifier)
            ?? nonEmpty(prev.elementContext?.domId)
            ?? nonEmpty(prev.elementContext?.computedName)
        let curStrong = nonEmpty(currentTarget?.identifier)
            ?? nonEmpty(currentTarget?.domId)
            ?? nonEmpty(currentTarget?.computedName)

        // Both sides must identify themselves with a matching strong signal.
        // Anything weaker (role-only, position guesses) can mistake one
        // text field for another and corrupt typeText events.
        guard let prevStrong, let curStrong else { return false }
        return prevStrong == curStrong
    }

    private nonisolated static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Convert a mach_absolute_time delta (host tick units) to seconds.
    fileprivate nonisolated static func machDeltaToSeconds(_ delta: UInt64) -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(delta) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000
    }

    /// Snapshot the current step index + recording dir so a caller (e.g.
    /// EventHandlers) can capture a screenshot before constructing the
    /// ObservedAction and pass the resulting path in.
    internal func nextScreenshotSlot() -> (stepIndex: Int, recordingDir: String)? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard let session, let dir = session.recordingDir else { return nil }
        return (stepIndex: session.actions.count + 1, recordingDir: dir)
    }

    // MARK: - Keystroke Coalescing

    /// Flush pending keystrokes into a typeText action. Caller must hold the lock.
    internal func flushPendingKeystrokes(
        into session: inout LearningSession,
        screenshotPath: String? = nil
    ) {
        guard !pendingKeystrokes.isEmpty else { return }
        session.actions.append(ObservedAction(
            timestamp: pendingKeystrokeTimestamp,
            action: .typeText(text: pendingKeystrokes),
            appName: pendingKeystrokeApp, appBundleId: pendingKeystrokeBundleId,
            windowTitle: pendingKeystrokeWindow, url: pendingKeystrokeUrl,
            elementContext: pendingKeystrokeElement,
            screenshotPath: screenshotPath
        ))
        pendingKeystrokes = ""; pendingKeystrokeElement = nil
        invalidateTimer(&keystrokeFlushTimer)
    }

    internal func flushPendingKeystrokesOnLearningThread() {
        // Snapshot the topmost window first (slow I/O), THEN take the lock,
        // BUILD the action under the lock, RELEASE the lock, and route the
        // action through appendAction(_:) so it gets tee'd into events.jsonl
        // (and surfaces in the menu app's live timeline). The lock-held
        // helper flushPendingKeystrokes(into:) skips the tee — it's the
        // right path only at stop() time, when finalize is about to write
        // the consolidated flow.json anyway.
        let path = captureNonClickScreenshot()
        var built: ObservedAction? = nil
        os_unfair_lock_lock(&lock)
        if session != nil, !pendingKeystrokes.isEmpty {
            built = ObservedAction(
                timestamp: pendingKeystrokeTimestamp,
                action: .typeText(text: pendingKeystrokes),
                appName: pendingKeystrokeApp,
                appBundleId: pendingKeystrokeBundleId,
                windowTitle: pendingKeystrokeWindow,
                url: pendingKeystrokeUrl,
                elementContext: pendingKeystrokeElement,
                screenshotPath: path
            )
            pendingKeystrokes = ""
            pendingKeystrokeElement = nil
            invalidateTimer(&keystrokeFlushTimer)
        }
        os_unfair_lock_unlock(&lock)
        if let built {
            appendAction(built)
        }
    }

    internal func scheduleKeystrokeFlushTimer() {
        os_unfair_lock_lock(&lock)
        invalidateTimer(&keystrokeFlushTimer)
        let fire = CFAbsoluteTimeGetCurrent() + LearningConstants.keystrokeFlushTimeoutSeconds
        let t = CFRunLoopTimerCreateWithHandler(nil, fire, 0, 0, 0) { [weak self] _ in
            self?.flushPendingKeystrokesOnLearningThread()
        }
        keystrokeFlushTimer = t
        if let rl = learningRunLoop { CFRunLoopAddTimer(rl, t, .commonModes) }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Scroll Coalescing

    /// Flush pending scroll into a single scroll action. Caller must hold the lock.
    internal func flushPendingScroll(
        into session: inout LearningSession,
        screenshotPath: String? = nil
    ) {
        guard pendingScrollDeltaX != 0 || pendingScrollDeltaY != 0 else { return }
        session.actions.append(ObservedAction(
            timestamp: pendingScrollTimestamp,
            action: .scroll(deltaX: pendingScrollDeltaX, deltaY: pendingScrollDeltaY,
                           x: pendingScrollX, y: pendingScrollY),
            appName: pendingScrollApp, appBundleId: pendingScrollBundleId,
            windowTitle: nil, url: nil, elementContext: nil,
            screenshotPath: screenshotPath
        ))
        pendingScrollDeltaX = 0; pendingScrollDeltaY = 0
        invalidateTimer(&scrollFlushTimer)
    }

    internal func flushPendingScrollOnLearningThread() {
        // Same reasoning as the keystroke variant — route through
        // appendAction(_:) so the live timeline sees coalesced scrolls.
        let path = captureNonClickScreenshot()
        var built: ObservedAction? = nil
        os_unfair_lock_lock(&lock)
        if session != nil, (pendingScrollDeltaX != 0 || pendingScrollDeltaY != 0) {
            built = ObservedAction(
                timestamp: pendingScrollTimestamp,
                action: .scroll(
                    deltaX: pendingScrollDeltaX,
                    deltaY: pendingScrollDeltaY,
                    x: pendingScrollX,
                    y: pendingScrollY
                ),
                appName: pendingScrollApp,
                appBundleId: pendingScrollBundleId,
                windowTitle: nil,
                url: nil,
                elementContext: nil,
                screenshotPath: path
            )
            pendingScrollDeltaX = 0
            pendingScrollDeltaY = 0
            invalidateTimer(&scrollFlushTimer)
        }
        os_unfair_lock_unlock(&lock)
        if let built {
            appendAction(built)
        }
    }

    /// Helper — take a single (non-annotated) screenshot of whatever's
    /// topmost on screen, slot it under the next step index. Acquires the
    /// lock briefly to read state, then releases it before doing the slow
    /// file write.
    private func captureNonClickScreenshot() -> String? {
        guard let slot = nextScreenshotSlot() else { return nil }
        return LearningScreenshot.capture(
            stepIndex: slot.stepIndex,
            recordingDir: slot.recordingDir
        )
    }

    internal func scheduleScrollFlushTimer() {
        os_unfair_lock_lock(&lock)
        invalidateTimer(&scrollFlushTimer)
        let fire = CFAbsoluteTimeGetCurrent() + LearningConstants.scrollFlushTimeoutSeconds
        let t = CFRunLoopTimerCreateWithHandler(nil, fire, 0, 0, 0) { [weak self] _ in
            self?.flushPendingScrollOnLearningThread()
        }
        scrollFlushTimer = t
        if let rl = learningRunLoop { CFRunLoopAddTimer(rl, t, .commonModes) }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Lock API

    internal func withLock<T>(_ body: (inout LearningSession?) -> T) -> T {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return body(&session)
    }
}

// MARK: - C Callback

private nonisolated func learningEventCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<LearningRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handleEvent(type, event)
    return Unmanaged.passUnretained(event)
}
