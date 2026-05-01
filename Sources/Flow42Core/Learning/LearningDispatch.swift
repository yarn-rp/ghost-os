// LearningDispatch.swift - MCP tool handlers for learning mode
//
// Bridges MCPDispatch to LearningRecorder.
// Handles parameter extraction, error formatting, and JSON serialization.

import Foundation

/// MCP tool handlers for flow42_learn_start, flow42_learn_stop, flow42_learn_status.
public enum LearningDispatch {

    // MARK: - flow42_learn_start

    public static func learnStart(args: [String: Any]) -> ToolResult {
        let taskDescription = args["task_description"] as? String
        let recorder = LearningRecorder.shared

        if let error = recorder.start(taskDescription: taskDescription) {
            return ToolResult(
                success: false,
                error: error.localizedDescription,
                suggestion: error.suggestion
            )
        }

        return ToolResult(
            success: true,
            data: [
                "status": "recording",
                "message": "Recording started. The user can now perform the task. Call flow42_learn_stop when done.",
            ]
        )
    }

    // MARK: - flow42_learn_stop

    public static func learnStop(args: [String: Any]) -> ToolResult {
        let recorder = LearningRecorder.shared

        switch recorder.stop() {
        case .failure(let error):
            return ToolResult(
                success: false,
                error: error.localizedDescription,
                suggestion: error.suggestion
            )
        case .success(let (session, actions)):
            let duration = Date().timeIntervalSince(session.startTime)
            let serializedActions = actions.map { serializeAction($0) }

            return ToolResult(
                success: true,
                data: [
                    "task_description": session.taskDescription ?? "",
                    "duration_seconds": Int(duration),
                    "action_count": actions.count,
                    "apps": Array(session.apps),
                    "urls": session.urls,
                    "actions": serializedActions,
                ]
            )
        }
    }

    // MARK: - flow42_learn_status

    public static func learnStatus(args: [String: Any]) -> ToolResult {
        let (recording, count, duration, app) = LearningRecorder.shared.status()
        var data: [String: Any] = [
            "recording": recording,
            "action_count": count,
            "duration_seconds": Int(duration),
        ]
        if let app { data["current_app"] = app }
        return ToolResult(success: true, data: data)
    }

    // MARK: - Serialization

    /// The action_type slug (`click`, `typeText`, `keyPress`, …) used both
    /// as a meta.yaml field and as the suffix in the v2 step folder name
    /// (`steps/0007-typeText/`). Pure mapping over the enum, no AX or app
    /// context needed.
    public nonisolated static func actionTypeSlug(_ action: ObservedActionType) -> String {
        switch action {
        case .click:        return "click"
        case .typeText:     return "typeText"
        case .keyPress:     return "keyPress"
        case .hotkey:       return "hotkey"
        case .appSwitch:    return "appSwitch"
        case .scroll:       return "scroll"
        case .secureField:  return "secureField"
        case .narration:    return "narration"
        case .urlChange:    return "urlChange"
        case .newTab:       return "newTab"
        case .tabSwitch:    return "tabSwitch"
        }
    }

    /// One-line human-readable summary for the events.jsonl `summary` field.
    /// Same vocabulary the menu timeline + the agent's Pass 1 parse, so we
    /// avoid duplicating per-action-type prose between writer and reader.
    public nonisolated static func oneLineSummary(_ action: ObservedAction) -> String {
        switch action.action {
        case .click(let x, let y, let button, let count):
            let verb = count >= 2 ? "double-click" : "\(button) click"
            if let name = action.elementContext?.computedName,
               !name.isEmpty {
                return "\(verb) '\(name)'"
            }
            return "\(verb) @ (\(Int(x)), \(Int(y)))"
        case .typeText(let text):
            return "type \"\(truncate(text, max: 60))\""
        case .keyPress(_, let keyName, let mods):
            return mods.isEmpty
                ? "press \(keyName)"
                : "press \(mods.joined(separator: "+"))+\(keyName)"
        case .hotkey(let mods, let keyName):
            return "hotkey \(mods.joined(separator: "+"))+\(keyName)"
        case .appSwitch(let toApp, _):
            return "switch to \(toApp)"
        case .scroll(let dx, let dy, _, _):
            return "scroll dx=\(dx) dy=\(dy)"
        case .secureField:
            return "secure field input"
        case .narration(let text):
            return "narration: \(truncate(text, max: 80))"
        case .urlChange(let url):
            return "navigate → \(truncate(url, max: 60))"
        case .newTab(let url):
            return "new tab → \(truncate(url, max: 60))"
        case .tabSwitch(_, let title):
            return "switch tab → \(truncate(title, max: 60))"
        }
    }

    /// Full per-step dict for `meta.yaml`. This is the rich detail the
    /// structuring agent reads in Pass 2 (denoise) / Pass 3 (find headless
    /// alternatives). Same shape as the v1 flow.json action entry plus an
    /// explicit `timestamp_ms` (callers compute it from session anchor +
    /// action.timestamp).
    ///
    /// Differs from serializeAction in two ways: drops keys whose values
    /// are NSNull or empty strings (so the meta.yaml doesn't carry
    /// `url: null` / `window: null` lines for the common no-URL non-
    /// browser click), and prunes empty fields off the inner `element`
    /// dict (computed_name: "", title: "" — clutter the recorder doesn't
    /// have evidence for).
    public nonisolated static func serializeStepMeta(
        _ action: ObservedAction,
        timestampMs: Int64
    ) -> [String: Any] {
        var dict = serializeAction(action)
        dict["timestamp_ms"] = timestampMs
        return prune(dict)
    }

    /// Recursively drop keys whose values are NSNull or empty strings.
    /// Inner dictionaries get pruned too (and dropped if they end up
    /// empty); arrays are walked but element-level pruning is left to
    /// the caller — we don't know enough about each item to prune blindly.
    private nonisolated static func prune(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if v is NSNull { continue }
            if let s = v as? String, s.isEmpty { continue }
            if let nested = v as? [String: Any] {
                let pruned = prune(nested)
                if !pruned.isEmpty { out[k] = pruned }
                continue
            }
            out[k] = v
        }
        return out
    }

    /// Lightweight events.jsonl line. Just enough for the timeline to
    /// render a row + the agent's Pass 1 to detect phases. Pass 1 ignores
    /// `replicate` and `target` — those are here so the menu timeline
    /// can render copy buttons and per-row detail without loading every
    /// step's meta.yaml. Anything richer (full element subtree, AX paths,
    /// etc.) lives in meta.yaml; consumers walk into the step folder
    /// when they need it.
    public nonisolated static func serializeIndexEntry(
        _ action: ObservedAction,
        stepIndex: Int,
        stepDirRelative: String,
        timestampMs: Int64,
        source: String = "native"
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "idx": stepIndex,
            "step_dir": stepDirRelative,
            "action_type": actionTypeSlug(action.action),
            "app": action.appName,
            "summary": oneLineSummary(action),
            "timestamp_ms": timestampMs,
            "source": source,
        ]
        if let url = action.url, !url.isEmpty {
            dict["url"] = url
        }
        if let built = ReplicateCommand.native(action) {
            dict["replicate"] = built.shellString
        }
        if let target = inlineTarget(action) {
            dict["target"] = target
        }
        return dict
    }

    /// One-line "what does this event point at" string for the timeline
    /// row's secondary line. Browser events: the URL. Native clicks /
    /// types: the element's locator or computed_name + role. Nil when
    /// nothing useful is available.
    private nonisolated static func inlineTarget(_ action: ObservedAction) -> String? {
        if let name = action.elementContext?.computedName, !name.isEmpty {
            let role = action.elementContext?.role ?? ""
            return role.isEmpty ? "'\(name)'" : "'\(name)' (\(role))"
        }
        if let title = action.elementContext?.title, !title.isEmpty {
            return "'\(title)'"
        }
        if let url = action.url, !url.isEmpty {
            return url
        }
        return nil
    }

    private nonisolated static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }

    public nonisolated static func serializeAction(_ action: ObservedAction) -> [String: Any] {
        var dict: [String: Any] = [
            "timestamp": action.timestamp,
            "app": action.appName,
            "bundle_id": action.appBundleId,
        ]
        if let built = ReplicateCommand.native(action) {
            dict["replicate"] = built.shellString
            dict["replicate_argv"] = built.argv
        }
        dict["window"] = action.windowTitle ?? NSNull()
        dict["url"] = action.url ?? NSNull()
        dict["element"] = action.elementContext.map { serializeElement($0) } ?? NSNull()
        dict["screenshot"] = action.screenshotPath ?? NSNull()
        dict["annotated_screenshot"] = action.annotatedScreenshotPath ?? NSNull()

        switch action.action {
        case .click(let x, let y, let button, let count):
            dict["action_type"] = "click"
            dict["x"] = x; dict["y"] = y
            dict["button"] = button; dict["count"] = count
        case .typeText(let text):
            dict["action_type"] = "typeText"
            dict["text"] = text
        case .keyPress(let keyCode, let keyName, let modifiers):
            dict["action_type"] = "keyPress"
            dict["key_code"] = keyCode; dict["key_name"] = keyName
            dict["modifiers"] = modifiers
        case .hotkey(let modifiers, let keyName):
            dict["action_type"] = "hotkey"
            dict["modifiers"] = modifiers; dict["key_name"] = keyName
        case .appSwitch(let toApp, let toBundleId):
            dict["action_type"] = "appSwitch"
            dict["to_app"] = toApp; dict["to_bundle_id"] = toBundleId
        case .scroll(let dx, let dy, let x, let y):
            dict["action_type"] = "scroll"
            dict["delta_x"] = dx; dict["delta_y"] = dy
            dict["x"] = x; dict["y"] = y
        case .secureField:
            dict["action_type"] = "secureField"
        case .narration(let text):
            dict["action_type"] = "narration"
            dict["text"] = text
        case .urlChange(let url):
            dict["action_type"] = "urlChange"
            dict["url"] = url
        case .newTab(let url):
            dict["action_type"] = "newTab"
            dict["url"] = url
        case .tabSwitch(let url, let title):
            dict["action_type"] = "tabSwitch"
            dict["url"] = url
            dict["title"] = title
        }

        return dict
    }

    private nonisolated static func serializeElement(_ e: ElementContext) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let v = e.role { dict["role"] = v }
        if let v = e.title { dict["title"] = v }
        if let v = e.identifier { dict["identifier"] = v }
        if let v = e.domId { dict["dom_id"] = v }
        if let v = e.domClasses { dict["dom_classes"] = v }
        if let v = e.computedName { dict["computed_name"] = v }
        if let v = e.parentRole { dict["parent_role"] = v }
        return dict
    }
}
