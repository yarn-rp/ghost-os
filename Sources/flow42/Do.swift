// Do.swift - `flow42 do <verb> [flags…]` driving-layer CLI.
//
// One verb per recorded action — click, type, press, hotkey, scroll, hover,
// long-press, drag, window, app-switch, focus, navigate. Mnemonic: "tell
// flow42 to **do** X." Flag names mirror the recorder's `replicate_argv`
// so a recording's command drops directly into argv with zero translation.
//
// Hard gate: every `flow42 do *` invocation requires an active *driving*
// play (state.play != nil && play.state == .driving && play.pause == nil).
// Without one, the dispatch fails with a JSON error pointing at
// `flow42 play`. The skill teaches agents to open a play before issuing
// any do commands; humans can pass `--force` for ad-hoc debugging.
//
// Every do call appends a `do` event to the active play's log.jsonl
// before dispatch and a `do_result` event after, so a later
// `flow42 play show <id>` can replay the whole trace.
//
// Native targets (default) call Flow42Core.Actions.* in process.
// Browser targets (--target browser) shell out to the browser-driver.

import AppKit
import Darwin
import Flow42Core
import Foundation

enum DoCmd {

    static func run(args: [String]) {
        guard let verb = args.first else {
            usage()
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let flags = parseSimple(rest)

        // Gate. Help / usage skip the gate; everything else requires an
        // active driving play (or --force).
        if verb != "help", verb != "-h", verb != "--help" {
            if let gateError = requireDrivingPlay(force: flags.bool("force")) {
                emitJSON(gateError)
                exit(1)
            }
        }

        // Log the do event before dispatch. Result event is logged after
        // by the helper that wraps the dispatch.
        let activePlay = StateFile.read().play
        if let play = activePlay, play.pause == nil {
            try? PlayStore.appendLog(
                flowDir: play.flowDir, playId: play.id,
                event: [
                    "type": "do",
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "verb": verb,
                    "args": rest,
                ]
            )
        }

        switch verb {
        case "click":      runClick(flags)
        case "type":       runType(flags)
        case "press":      runPress(flags)
        case "hotkey":     runHotkey(flags)
        case "scroll":     runScroll(flags)
        case "hover":      runHover(flags)
        case "long-press": runLongPress(flags)
        case "drag":       runDrag(flags)
        case "window":     runWindow(flags)
        case "app-switch": runAppSwitch(flags)
        case "focus":      runFocus(flags)
        case "navigate":   runBrowserOnly(verb, flags)
        case "help", "-h", "--help":
            usage()
            exit(0)
        default:
            fputs("error: unknown verb '\(verb)'\n\n", stderr)
            usage()
            exit(2)
        }
    }

    // MARK: - Verbs

    private static func runClick(_ f: CliFlags) {
        if isBrowserTarget(f) { return runBrowser("click", f) }
        let x = f.double("x")
        let y = f.double("y")
        guard x != nil, y != nil else {
            return fail("click (native) requires --x and --y")
        }
        // Pipe through optional fingerprint flags so the AX validation tier
        // in Actions.click() can compare what's under the recorded coord
        // at replay time vs. what the recorder captured. Empty / missing
        // values short-circuit the validation cleanly.
        //
        // run-step-dir falls back to the active play's next step dir so
        // every replay automatically writes per-step screenshots without
        // the agent having to wire the flag through itself.
        let stepDir = f.string("run-step-dir") ?? nextActivePlayStepDir()
        let result = Actions.click(
            query: nil, role: nil, domId: nil,
            appName: f.string("app"),
            x: x, y: y,
            button: f.string("button") ?? "left",
            count: f.int("count") ?? 1,
            expectedRole: f.string("expected-role"),
            expectedName: f.string("expected-name"),
            expectedDomId: f.string("expected-dom-id"),
            runStepDir: stepDir
        )
        emit(result, flags: f)
    }

    /// Derive the step directory for the active driving play, if any.
    /// Counts existing children of `<play-dir>/steps/` and returns the next
    /// numbered slot. Returns nil when no play is active so the
    /// screenshot-capture path stays opt-in for direct CLI use.
    private static func nextActivePlayStepDir() -> String? {
        guard let play = StateFile.read().play, play.pause == nil else { return nil }
        let playDir = PlayStore.playDir(flowDir: play.flowDir, playId: play.id)
        let stepsRoot = (playDir as NSString).appendingPathComponent("steps")
        try? FileManager.default.createDirectory(
            atPath: stepsRoot, withIntermediateDirectories: true
        )
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: stepsRoot)) ?? []
        let nextIdx = existing.count + 1
        let stepDir = (stepsRoot as NSString).appendingPathComponent(
            String(format: "%04d", nextIdx)
        )
        try? FileManager.default.createDirectory(
            atPath: stepDir, withIntermediateDirectories: true
        )
        return stepDir
    }

    private static func runType(_ f: CliFlags) {
        if isBrowserTarget(f) { return runBrowser("type", f) }
        guard let text = f.string("text") else {
            return fail("type requires --text")
        }
        let result = Actions.typeText(
            text: text,
            into: f.string("into"),
            domId: f.string("dom-id"),
            appName: f.string("app"),
            clear: f.bool("clear")
        )
        emit(result, flags: f)
    }

    private static func runPress(_ f: CliFlags) {
        if isBrowserTarget(f) { return runBrowser("press", f) }
        guard let key = f.string("key") else {
            return fail("press requires --key")
        }
        let modifiers = f.list("modifiers")
        let result = Actions.pressKey(
            key: key,
            modifiers: modifiers.isEmpty ? nil : modifiers,
            appName: f.string("app")
        )
        emit(result, flags: f)
    }

    private static func runHotkey(_ f: CliFlags) {
        let keys = f.list("keys")
        guard !keys.isEmpty else {
            return fail("hotkey requires --keys (comma-separated, e.g. cmd,shift,t)")
        }
        let result = Actions.hotkey(keys: keys, appName: f.string("app"))
        emit(result, flags: f)
    }

    private static func runScroll(_ f: CliFlags) {
        if isBrowserTarget(f) { return runBrowser("scroll", f) }
        guard let direction = f.string("direction") else {
            return fail("scroll requires --direction (up|down|left|right)")
        }
        let result = Actions.scroll(
            direction: direction,
            amount: f.int("amount"),
            appName: f.string("app"),
            x: f.double("x"),
            y: f.double("y")
        )
        emit(result, flags: f)
    }

    private static func runHover(_ f: CliFlags) {
        if isBrowserTarget(f) { return runBrowser("hover", f) }
        let result = Actions.hover(
            query: f.string("query"),
            role: f.string("role"),
            domId: f.string("dom-id"),
            appName: f.string("app"),
            x: f.double("x"),
            y: f.double("y")
        )
        emit(result, flags: f)
    }

    private static func runLongPress(_ f: CliFlags) {
        if isBrowserTarget(f) { return runBrowser("long-press", f) }
        let result = Actions.longPress(
            query: f.string("query"),
            role: f.string("role"),
            domId: f.string("dom-id"),
            appName: f.string("app"),
            x: f.double("x"),
            y: f.double("y"),
            duration: f.double("duration"),
            button: f.string("button")
        )
        emit(result, flags: f)
    }

    private static func runDrag(_ f: CliFlags) {
        if isBrowserTarget(f) { return runBrowser("drag", f) }
        guard let toX = f.double("to-x"), let toY = f.double("to-y") else {
            return fail("drag requires --to-x and --to-y")
        }
        let result = Actions.drag(
            query: f.string("query"),
            role: f.string("role"),
            domId: f.string("dom-id"),
            appName: f.string("app"),
            fromX: f.double("from-x"),
            fromY: f.double("from-y"),
            toX: toX,
            toY: toY,
            duration: f.double("duration"),
            holdDuration: f.double("hold-duration")
        )
        emit(result, flags: f)
    }

    private static func runWindow(_ f: CliFlags) {
        guard let action = f.string("action") else {
            return fail("window requires --action (list|minimize|maximize|close|move|resize)")
        }
        guard let appName = f.string("app") else {
            return fail("window requires --app")
        }
        let result = Actions.manageWindow(
            action: action,
            appName: appName,
            windowTitle: f.string("window-title"),
            x: f.double("x"), y: f.double("y"),
            width: f.double("width"), height: f.double("height")
        )
        emit(result, flags: f)
    }

    private static func runAppSwitch(_ f: CliFlags) {
        guard let to = f.string("to") else {
            return fail("app-switch requires --to (bundle id or app name)")
        }
        if let app = resolveApp(to) {
            _ = app.activate()
            Thread.sleep(forTimeInterval: 0.4)
            emitJSON(["success": true, "data": ["app": app.localizedName ?? to, "bundle_id": app.bundleIdentifier ?? ""]])
            return
        }
        let result = FocusManager.focus(appName: to)
        emit(result, flags: f)
    }

    private static func runFocus(_ f: CliFlags) {
        guard let app = f.string("app") else {
            return fail("focus requires --app")
        }
        let result = FocusManager.focus(appName: app)
        emit(result, flags: f)
    }

    private static func runBrowserOnly(_ verb: String, _ f: CliFlags) {
        runBrowser(verb, f)
    }

    /// Dispatch a browser-target verb to the browser-driver subprocess.
    private static func runBrowser(_ verb: String, _ f: CliFlags) {
        BrowserDriver.dispatch(verb: verb, flags: f)
    }

    // MARK: - Helpers

    private static func isBrowserTarget(_ f: CliFlags) -> Bool {
        if let t = f.string("target") { return t == "browser" }
        // Inferred: presence of --locator or --tab implies browser target.
        return f.string("locator") != nil || f.string("tab") != nil
    }

    private static func resolveApp(_ ident: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let byBundle = apps.first(where: { $0.bundleIdentifier == ident }) {
            return byBundle
        }
        return apps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(ident) == true
        })
    }

    /// Emit the action layer's result, applying strict-mode policy at the
    /// CLI boundary so silent successes never leave this process.
    ///
    /// Strict mode is ON by default. The action layer already returns
    /// `success: false` for `.coordinatesOnly` and `.recovered` (see
    /// `Actions.click`); we honour those here.  For `.unverified` (verbs
    /// that couldn't even attempt verification) we ALSO downgrade to
    /// failure unless the caller passes `--accept-recovery` — the user
    /// asked for hard failures whenever something isn't proven, not just
    /// "matched is success and the rest is whatever the action layer
    /// happened to set."
    ///
    /// `--accept-recovery` is the single human escape hatch: pass it
    /// explicitly to accept `.recovered` and `.unverified` as success
    /// (the click did happen — caller is opting into best-effort). It
    /// never accepts `.coordinatesOnly`, because that's the case where
    /// we actively detected a mismatch and fired anyway.
    private static func emit(_ result: ToolResult, flags: CliFlags = CliFlags()) {
        var success = result.success
        var error = result.error
        let acceptRecovery = flags.bool("accept-recovery")

        if let grounding = result.grounding {
            switch grounding {
            case .matched:
                break  // strictest tier — already success.
            case .recovered:
                if acceptRecovery {
                    success = true
                    if error == nil {
                        error = "warning: action recovered via \(grounding.wireValue) — recording is drifting"
                    }
                } else {
                    success = false
                    if error == nil {
                        error = "action grounded via \(grounding.wireValue), not the recorded path; pass --accept-recovery if intentional"
                    }
                }
            case .unverified:
                if acceptRecovery {
                    // explicit opt-in.
                } else {
                    success = false
                    if error == nil {
                        error = "action completed but no verification was possible (no recorded fingerprint or verifier not yet implemented for this verb); pass --accept-recovery to override"
                    }
                }
            case .coordinatesOnly:
                // Always failure. The caller HAS no opt-out for this —
                // we detected a mismatch and fired anyway, which is
                // exactly the silent-lie the user wants gone.
                success = false
                if error == nil {
                    error = "action fired at recorded coordinates without grounding; refusing to claim success"
                }
            }
        }
        // No grounding attached → verb hasn't been audited under
        // strict mode yet (browser-target verbs, type/press/scroll/etc.
        // wait for the §0 Verification module). Pass through unchanged
        // so existing flows don't break in the same commit that adds
        // strict mode to click. Each audit will start setting grounding
        // and naturally flip into the policy above.

        var dict: [String: Any] = ["success": success]
        if let data = result.data { dict["data"] = data }
        if let err = error { dict["error"] = err }
        if let sug = result.suggestion { dict["suggestion"] = sug }
        if let grounding = result.grounding { dict["grounding"] = grounding.wireValue }
        logDoResult(dict)
        emitJSON(dict)
        if !success { exit(1) }
    }

    private static func fail(_ msg: String) {
        let dict: [String: Any] = ["success": false, "error": msg]
        logDoResult(dict)
        emitJSON(dict)
        exit(2)
    }

    /// Append a `do_result` event to the active play's log.jsonl. Best-
    /// effort — failure to log doesn't block emit. Captures success +
    /// (when present) error + verified so a later `flow42 play show`
    /// reproduces the trace.
    private static func logDoResult(_ result: [String: Any]) {
        guard let play = StateFile.read().play, play.pause == nil else { return }
        var event: [String: Any] = [
            "type": "do_result",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "success": (result["success"] as? Bool) ?? false,
        ]
        if let err = result["error"] as? String { event["error"] = err }
        if let verified = result["verified"] as? Bool { event["verified"] = verified }
        try? PlayStore.appendLog(
            flowDir: play.flowDir, playId: play.id, event: event
        )
    }

    /// Gate: returns nil if a driving play is active OR --force is passed.
    /// Otherwise returns a JSON dict the caller emits as the failure result.
    private static func requireDrivingPlay(force: Bool) -> [String: Any]? {
        if force { return nil }
        let state = StateFile.read()
        guard let play = state.play else {
            return [
                "success": false,
                "error": "flow42 do requires an active driving play",
                "suggestion": "run `flow42 play <flow-dir> --by <agent> --label \"<task>\"` first; close with `flow42 play end` or `flow42 stop` when done",
            ]
        }
        if play.pause != nil {
            return [
                "success": false,
                "error": "flow42 do refused: play is paused (\(play.pause!.reason))",
                "suggestion": "the user is in control while paused. Run `flow42 play resume` (or wait for the user to click Resume) before issuing more do commands.",
            ]
        }
        if play.state != .driving {
            return [
                "success": false,
                "error": "flow42 do requires a driving play (current state: \(play.state.rawValue))",
                "suggestion": "run `flow42 play resume` to flip back to driving, or end the watching play and start a new driving one.",
            ]
        }
        return nil
    }

    private static func usage() {
        let text = """
        Usage: flow42 do <verb> [flags…]

        Issue a unit action against the screen during an active driving play.
        Requires `flow42 play <flow-dir>` first; pass --force to bypass the
        gate (humans only — agents go through the play lifecycle).

        Verbs:
          click       --x N --y N [--button left|right|middle] [--count N] [--app NAME]
                      [--expected-role ROLE --expected-name NAME --expected-dom-id ID]
                      [--run-step-dir PATH]
          type        --text T [--app NAME] [--into FIELD] [--dom-id ID] [--clear]
          press       --key K [--modifiers cmd,shift,…] [--app NAME]
          hotkey      --keys cmd,shift,t [--app NAME]
          scroll      --direction up|down|left|right [--amount N] [--x N --y N] [--app NAME]
          hover       --x N --y N [--query Q] [--app NAME]
          long-press  --x N --y N [--duration S] [--button left|right] [--app NAME]
          drag        --to-x N --to-y N [--from-x N --from-y N | --query Q] [--app NAME]
          window      --action list|minimize|maximize|close|move|resize --app NAME
                      [--window-title T] [--x N --y N --width W --height H]
          app-switch  --to BUNDLE_ID_OR_NAME
          focus       --app NAME
          navigate    --url URL [--tab N]          (browser-only)

        Browser target: pass --target browser, or supply --locator/--tab to
        infer it. Requires Chrome started with `flow42 chrome-launch` (one-time
        setup that opens Chrome with the local debug endpoint enabled).
        """
        print(text)
    }
}


