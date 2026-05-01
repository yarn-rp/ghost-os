// LearningTypes.swift - Data types for the self-learning system
//
// These types are the OUTPUT of recording. They are NOT recipes.
// The agent (Claude Code) converts these into Recipe JSON via flow42_recipe_save.

import Foundation

// MARK: - Learning Error

/// Errors specific to learning mode operations.
public enum LearningError: Error, Sendable {
    case inputMonitoringNotGranted
    case alreadyRecording
    case notRecording
    case tapCreationFailed
    case noActionsRecorded

    public var localizedDescription: String {
        switch self {
        case .inputMonitoringNotGranted:
            "Input Monitoring permission not granted"
        case .alreadyRecording:
            "Learning is already in progress. Call flow42_learn_stop first."
        case .notRecording:
            "No learning session is active. Call flow42_learn_start first."
        case .tapCreationFailed:
            "Failed to create CGEvent tap. Input Monitoring permission may be stale."
        case .noActionsRecorded:
            "No actions were recorded during the learning session."
        }
    }

    public var suggestion: String {
        switch self {
        case .inputMonitoringNotGranted:
            "System Settings > Privacy & Security > Input Monitoring. Add your terminal app. Then restart the MCP server."
        case .alreadyRecording:
            "Call flow42_learn_stop to end the current session, or flow42_learn_status to check."
        case .notRecording:
            "Call flow42_learn_start to begin recording."
        case .tapCreationFailed:
            "Remove and re-add your terminal app in System Settings > Privacy & Security > Input Monitoring."
        case .noActionsRecorded:
            "Make sure you performed actions (clicks, typing) while recording was active."
        }
    }
}

// MARK: - Observed Action

/// A single observed user action during learning mode.
/// Produced by the CGEvent tap + AX enrichment pipeline.
public struct ObservedAction: Sendable {
    public let timestamp: UInt64
    public let action: ObservedActionType
    public let appName: String
    public let appBundleId: String
    public let windowTitle: String?
    public let url: String?
    public let elementContext: ElementContext?
    /// Path (relative to the recording dir) of a JPG of the focused window
    /// at event time. Nil when capture is disabled or failed.
    public let screenshotPath: String?
    /// Same as `screenshotPath` but with an annotation (e.g. click marker).
    /// Nil when not yet computed.
    public let annotatedScreenshotPath: String?

    public nonisolated init(
        timestamp: UInt64,
        action: ObservedActionType,
        appName: String,
        appBundleId: String,
        windowTitle: String?,
        url: String?,
        elementContext: ElementContext?,
        screenshotPath: String? = nil,
        annotatedScreenshotPath: String? = nil
    ) {
        self.timestamp = timestamp
        self.action = action
        self.appName = appName
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.url = url
        self.elementContext = elementContext
        self.screenshotPath = screenshotPath
        self.annotatedScreenshotPath = annotatedScreenshotPath
    }
}

/// The type of observed action.
public enum ObservedActionType: Sendable {
    case click(x: Double, y: Double, button: String, count: Int)
    case typeText(text: String)
    case keyPress(keyCode: Int, keyName: String, modifiers: [String])
    case hotkey(modifiers: [String], keyName: String)
    case appSwitch(toApp: String, toBundleId: String)
    case scroll(deltaX: Int, deltaY: Int, x: Double, y: Double)
    case secureField
    /// A finalized voiceover utterance from the user's narration. Interleaved
    /// with mouse/keyboard actions in the action stream so phase-2 agents can
    /// read intent in chronological context.
    case narration(text: String)
    /// The browser's URL bar value changed — emitted by the native URL-change
    /// detector when running in BrowserMode.native (the extension owns this
    /// in extension/auto modes). One event covers any cause: address-bar
    /// typing, link click, history back/forward, in-page push-state nav,
    /// JavaScript redirect — replay translates to `flow42 act navigate`.
    case urlChange(url: String)
    /// A new browser tab was opened (native mode equivalent of the
    /// extension's `newTab` event). `url` is the URL the tab is showing
    /// at the moment of detection (often `chrome://newtab` initially,
    /// updated by a subsequent `urlChange` if the user navigates).
    case newTab(url: String)
    /// The browser's selected (focused) tab changed without a new tab
    /// being opened — the user clicked a different tab strip entry,
    /// pressed Cmd+1/2/…, or used Cmd+Shift+[/] to cycle. `url` and
    /// `title` describe the now-focused tab.
    case tabSwitch(url: String, title: String)
}

/// AX context for the element that was acted upon (e.g., clicked).
public struct ElementContext: Sendable {
    public let role: String?
    public let title: String?
    public let identifier: String?
    public let domId: String?
    public let domClasses: String?
    public let computedName: String?
    public let parentRole: String?
}

// MARK: - Learning Session

/// State of an active learning session. Held by LearningRecorder.
public struct LearningSession: Sendable {
    public let taskDescription: String?
    public let startTime: Date
    /// `mach_absolute_time()` captured at the same instant as `startTime`.
    /// Together they define the wall-clock anchor used to convert per-action
    /// mach timestamps into milliseconds-since-epoch when merging with the
    /// Chrome extension's `dom-events.jsonl` (which uses `Date.now()`).
    public let startMach: UInt64
    public var actions: [ObservedAction]
    public var apps: Set<String>
    public var urls: [String]
    /// Absolute path to the directory where this recording's screenshots
    /// (and eventually flow.json + .agent prompts) are written. Nil when
    /// screenshots are disabled (`flow42_learn_start` without a record dir).
    public let recordingDir: String?

    public nonisolated init(taskDescription: String?, recordingDir: String? = nil) {
        self.taskDescription = taskDescription
        self.startTime = Date()
        self.startMach = mach_absolute_time()
        self.actions = []
        self.apps = []
        self.urls = []
        self.recordingDir = recordingDir
    }
}

/// Convert `mach_absolute_time()` ticks into milliseconds-since-epoch using a
/// session anchor. Used at flow.json serialisation time to put native and
/// extension events on the same timeline for sorting.
public nonisolated func machToWallClockMs(
    _ mach: UInt64,
    startMach: UInt64,
    startWallClock: Date
) -> Int64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let deltaTicks = mach >= startMach
        ? mach - startMach
        : 0
    let deltaNanos = deltaTicks &* UInt64(info.numer) / UInt64(info.denom)
    let deltaMs = Int64(deltaNanos / 1_000_000)
    let startMs = Int64(startWallClock.timeIntervalSince1970 * 1000)
    return startMs + deltaMs
}

// MARK: - Learning Log

/// Thread-safe stderr logging for the learning subsystem.
/// Exists because Log (Logger.swift) inherits MainActor from the package-level
/// default isolation and cannot be called from the nonisolated learning thread.
/// Matches Log's output format for consistency in stderr.
nonisolated func learningLog(_ level: String, _ message: String) {
    // Per-call allocation is intentional: ISO8601DateFormatter is not thread-safe,
    // and this function is called from both the main thread and the learning thread.
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [\(level)] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

// MARK: - Learning Constants

nonisolated public enum LearningConstants {
    /// Keystroke coalescing: flush after this many seconds of inactivity.
    public static let keystrokeFlushTimeoutSeconds: Double = 0.5
    /// Scroll coalescing: flush after this many seconds of inactivity.
    public static let scrollFlushTimeoutSeconds: Double = 0.3
    /// Maximum recording duration (safety limit): 10 minutes.
    public static let maxRecordingDurationSeconds: Double = 600
    /// Restricted bundle IDs: pause recording in these apps.
    /// flow42's own menu bar app is excluded so that clicking Start/Stop
    /// in the popover or typing the description doesn't end up in the
    /// recording the user is producing.
    public static let restrictedBundleIds: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
        "com.web42.flow42.menu",
    ]
    /// Sensitive field name patterns (case-insensitive).
    public static let sensitiveFieldPatterns: [String] = [
        "password", "passwd", "secret", "token", "api_key", "api.key",
        "apikey", "credential", "private.key", "ssn", "social.security",
    ]
    /// Chromium-based browsers where the flow42 Chrome extension can attach
    /// and provide DOM-augmented events. We filter out native click/key/scroll
    /// events while one of these is frontmost — the extension is the source of
    /// truth for in-page actions there. App-switch events are NOT filtered;
    /// they're scaffolding markers and useful as timeline anchors.
    public static let domSidecarBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
    ]
}
