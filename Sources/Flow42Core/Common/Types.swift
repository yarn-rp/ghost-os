// Types.swift - Shared types for Flow42 v2
//
// Data structures used across modules. Keep these minimal and focused.

import AXorcist
import Foundation

// MARK: - Version

public enum Flow42Core {
    public static let version = "2.2.1"
    public static let name = "flow42"
}

// MARK: - Action Grounding

/// How confident is the action layer that the action did the right thing?
///
/// Every `flow42 do *` verb attaches one of these to its `ToolResult` so
/// the CLI shell, the play loop, and the agent reading `do_result` events
/// all share the same vocabulary. The hard rule: **only `.matched` counts
/// as success in strict mode.** Everything else either fails hard at the
/// CLI exit-code level (`.coordinatesOnly`, `.unverified` for verbs that
/// couldn't even attempt verification) or is downgradeable to a warning
/// when the caller explicitly opts in (`.recovered`, `--accept-recovery`).
///
/// The shape is closed: extending requires bumping consumers (Do.swift's
/// emit, the play loop's expect evaluator, the UI confidence pill).
public enum ActionGrounding: Sendable, Equatable {
    /// Pre-action verification confirmed we operated on the recorded
    /// element. The recorded fingerprint matched the AX/DOM target at
    /// replay time. This is the only "perfect" tier.
    case matched

    /// The recorded coordinates didn't match, but a structured search
    /// (AX identifier, AX name, CDP, vision) found the element and we
    /// acted on it. Success-of-a-kind, but the recording is drifting —
    /// the play loop pauses unless `expect:` proves the phase still
    /// works, OR the caller explicitly passes `--accept-recovery`.
    case recovered(via: RecoveryPath)

    /// Every grounded path failed. We fired a raw input event at the
    /// recorded coordinate without any way to confirm we hit what the
    /// recording intended. **Always fails hard at the CLI exit level.**
    /// The play loop interprets non-zero as "consult `expect:` before
    /// advancing."
    case coordinatesOnly

    /// The verb's verifier didn't run (no fingerprint to compare
    /// against, or verification isn't applicable to this verb yet).
    /// Treated as failure in strict mode — the user wants explicit
    /// proof, not silent assumptions.
    case unverified

    public enum RecoveryPath: String, Sendable {
        case axIdentifier = "ax_identifier"
        case axName = "ax_name"
        case cdp
        case vision
    }

    /// Stable string for JSON / log emission.
    public var wireValue: String {
        switch self {
        case .matched: return "matched"
        case .recovered(let via): return "recovered:\(via.rawValue)"
        case .coordinatesOnly: return "coordinates_only"
        case .unverified: return "unverified"
        }
    }

    /// Whether this grounding tier counts as success under strict mode.
    /// Only `.matched` does. Everything else is downgradeable but never
    /// silently passes.
    public var isStrictlyVerified: Bool {
        if case .matched = self { return true }
        return false
    }
}

// MARK: - Tool Result

/// Standard result wrapper returned by all MCP tools.
public struct ToolResult: Sendable {
    public let success: Bool
    public let data: [String: Any]?
    public let error: String?
    public let suggestion: String?
    public let context: ContextInfo?
    /// Verification tier the action layer asserts (see `ActionGrounding`).
    /// Optional because not every verb has a verifier *yet* — verbs that
    /// haven't been audited under the strict-mode plan return nil and the
    /// CLI shell treats the absence as `.unverified`.
    public let grounding: ActionGrounding?

    public init(
        success: Bool,
        data: [String: Any]? = nil,
        error: String? = nil,
        suggestion: String? = nil,
        context: ContextInfo? = nil,
        grounding: ActionGrounding? = nil
    ) {
        self.success = success
        self.data = data
        self.error = error
        self.suggestion = suggestion
        self.context = context
        self.grounding = grounding
    }

    /// Convert to MCP-compatible dictionary for JSON serialization.
    public func toDict() -> [String: Any] {
        var result: [String: Any] = ["success": success]
        if let data { result["data"] = data }
        if let error { result["error"] = error }
        if let suggestion { result["suggestion"] = suggestion }
        if let context { result["context"] = context.toDict() }
        if let grounding { result["grounding"] = grounding.wireValue }
        return result
    }
}

// MARK: - Context Info

/// Lightweight context snapshot returned with tool results.
public struct ContextInfo: Sendable {
    public let app: String?
    public let window: String?
    public let focusedElement: String?
    public let url: String?

    public init(app: String? = nil, window: String? = nil, focusedElement: String? = nil, url: String? = nil) {
        self.app = app
        self.window = window
        self.focusedElement = focusedElement
        self.url = url
    }

    public func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let app { d["app"] = app }
        if let window { d["window"] = window }
        if let focusedElement { d["focused_element"] = focusedElement }
        if let url { d["url"] = url }
        return d
    }
}

// MARK: - Screenshot Result

/// Result from a screenshot capture.
public struct ScreenshotResult: Sendable {
    public let base64PNG: String
    public let width: Int
    public let height: Int
    public let windowTitle: String?
    public let mimeType: String

    /// Window frame in logical screen coordinates (points).
    /// Used by VisionPerception to map VLM coordinates back to screen space.
    public let windowX: Double
    public let windowY: Double
    public let windowWidth: Double
    public let windowHeight: Double

    public init(
        base64PNG: String,
        width: Int,
        height: Int,
        windowTitle: String? = nil,
        mimeType: String = "image/png",
        windowX: Double = 0,
        windowY: Double = 0,
        windowWidth: Double = 0,
        windowHeight: Double = 0
    ) {
        self.base64PNG = base64PNG
        self.width = width
        self.height = height
        self.windowTitle = windowTitle
        self.mimeType = mimeType
        self.windowX = windowX
        self.windowY = windowY
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }
}

// MARK: - Ghost Error

/// Errors specific to Flow42 operations.
public enum Flow42Error: Error, Sendable {
    case timeout(seconds: TimeInterval)
    case elementNotFound(description: String)
    case actionFailed(description: String)
    case appNotFound(name: String)
    case permissionDenied(String)
    case invalidParameter(String)

    public var localizedDescription: String {
        switch self {
        case let .timeout(seconds):
            "Operation timed out after \(Int(seconds)) seconds"
        case let .elementNotFound(desc):
            "Element not found: \(desc)"
        case let .actionFailed(desc):
            "Action failed: \(desc)"
        case let .appNotFound(name):
            "Application not found: \(name)"
        case let .permissionDenied(msg):
            "Permission denied: \(msg)"
        case let .invalidParameter(msg):
            "Invalid parameter: \(msg)"
        }
    }
}

// MARK: - Constants

public enum GhostConstants {
    public static let semanticDepthBudget = 25
    public static let defaultTimeoutSeconds: TimeInterval = 30
    public static let defaultPollInterval: TimeInterval = 0.5
    public static let maxSearchDepth = 100
    public static let recipesDirectory = "~/.flow42/recipes"
    public static let logsDirectory = "~/.flow42/logs"
}
