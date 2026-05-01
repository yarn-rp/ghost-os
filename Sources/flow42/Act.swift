// Act.swift - `flow42 act <verb> [flags…]` driving-layer CLI.
//
// One verb per recorded action. Flag names mirror the field names in
// flow.json so a recording's `replicate_argv` value drops directly into
// argv with zero translation. This is the deterministic execution surface
// agents call once per skill step when a shortcut path isn't available.
//
// Native targets (default) call Flow42Core.Actions.* directly in process.
// Browser targets (--target browser) route through a Unix socket to the
// running native-host (phase 4 — not implemented yet; will print a clear
// error message until then).

import AppKit
import Darwin
import Flow42Core
import Foundation

enum Act {

    static func run(args: [String]) {
        guard let verb = args.first else {
            usage()
            exit(2)
        }
        let rest = Array(args.dropFirst())
        let flags = parseSimple(rest)

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
        let result = Actions.click(
            query: nil, role: nil, domId: nil,
            appName: f.string("app"),
            x: x, y: y,
            button: f.string("button") ?? "left",
            count: f.int("count") ?? 1
        )
        emit(result)
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
        emit(result)
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
        emit(result)
    }

    private static func runHotkey(_ f: CliFlags) {
        let keys = f.list("keys")
        guard !keys.isEmpty else {
            return fail("hotkey requires --keys (comma-separated, e.g. cmd,shift,t)")
        }
        let result = Actions.hotkey(keys: keys, appName: f.string("app"))
        emit(result)
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
        emit(result)
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
        emit(result)
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
        emit(result)
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
        emit(result)
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
        emit(result)
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
        emit(result)
    }

    private static func runFocus(_ f: CliFlags) {
        guard let app = f.string("app") else {
            return fail("focus requires --app")
        }
        let result = FocusManager.focus(appName: app)
        emit(result)
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

    private static func emit(_ result: ToolResult) {
        var dict: [String: Any] = ["success": result.success]
        if let data = result.data { dict["data"] = data }
        if let err = result.error { dict["error"] = err }
        if let sug = result.suggestion { dict["suggestion"] = sug }
        emitJSON(dict)
        if !result.success { exit(1) }
    }

    private static func fail(_ msg: String) {
        emitJSON(["success": false, "error": msg])
        exit(2)
    }

    private static func usage() {
        let text = """
        Usage: flow42 act <verb> [flags…]

        Verbs:
          click       --x N --y N [--button left|right|middle] [--count N] [--app NAME]
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


