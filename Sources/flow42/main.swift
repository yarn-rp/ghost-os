// main.swift - Flow42 v2 CLI entry point
//
// Thin CLI:
//   flow42 mcp       Start the MCP server (used by Claude Code)
//   flow42 setup     Interactive setup wizard
//   flow42 doctor    Diagnose issues and suggest fixes
//   flow42 status    Quick health check
//   flow42 record    Record a user-driven flow to ~/.flow42/flows/
//   flow42 version   Print version

import AppKit
import ApplicationServices
import Foundation
import Flow42Core

// Force CoreGraphics server connection initialization.
// ScreenCaptureKit requires a CG connection to the window server.
_ = CGMainDisplayID()

let args = CommandLine.arguments.dropFirst()
// Chrome launches native-messaging hosts with argv[1] = the extension origin
// (e.g. "chrome-extension://abcd.../"). Route those invocations to the
// native-host loop instead of treating the origin as an unknown subcommand.
if let first = args.first, first.hasPrefix("chrome-extension://") {
    NativeHost.run()
    exit(0)
}
let command = args.first ?? "help"

// Make sure the menu app + main app are alive before any command that
// drives a session. The menu owns the edge glow, the floating timeline,
// and the recorder daemon's UI affordances; the main app owns the deep-
// link receiver and the chat handoff. A CLI invocation that touches
// state without these visible companions is a regression — the user
// loses the recording indicator, the stop button, and the auto-handoff
// chat that completes the loop.
let needsCompanions: Set<String> = [
    "record", "play", "do", "stop", "snapshot", "wait",
]
if needsCompanions.contains(command) {
    ensureCompanionApps()
}

switch command {
case "mcp":
    let server = MCPServer()
    server.run()

case "setup":
    let wizard = SetupWizard()
    wizard.run()

case "doctor":
    var doctor = Doctor()
    doctor.run()

case "status":
    printStatus()

case "record":
    Record.run(args: Array(args.dropFirst()))

case "flows":
    Flows.run(args: Array(args.dropFirst()))

case "play":
    Play.run(args: Array(args.dropFirst()))

case "do":
    DoCmd.run(args: Array(args.dropFirst()))

case "stop":
    Stop.run(args: Array(args.dropFirst()))

case "snapshot":
    Snapshot.run(args: Array(args.dropFirst()))

case "tree":
    Tree.run(args: Array(args.dropFirst()))

case "state":
    State.run(args: Array(args.dropFirst()))

case "find":
    Find.run(args: Array(args.dropFirst()))

case "inspect":
    Inspect.run(args: Array(args.dropFirst()))

case "element-at":
    ElementAt.run(args: Array(args.dropFirst()))

case "read":
    Read.run(args: Array(args.dropFirst()))

case "annotate":
    AnnotateCmd.run(args: Array(args.dropFirst()))

case "wait":
    Wait.run(args: Array(args.dropFirst()))

case "chrome-launch":
    ChromeLaunch.run(args: Array(args.dropFirst()))

case "setup-browser":
    SetupBrowser.run(args: Array(args.dropFirst()))

case "native-host":
    NativeHost.run()

case "annotations":
    Annotations.run(args: Array(args.dropFirst()))

case "view":
    View.run(args: Array(args.dropFirst()))

case "structure":
    Structure.run(args: Array(args.dropFirst()))

case "install":
    Install.run(args: Array(args.dropFirst()))

case "install-skills":
    InstallSkills.run(args: Array(args.dropFirst()))

case "version", "--version", "-v":
    print("Flow42 v\(Flow42Core.version)")

case "help", "--help", "-h":
    printUsage()

default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}

// MARK: - Companion app launching

/// Best-effort launch of `Flow42Menu` and `Flow42App` if they aren't
/// already running. Resolves the binaries relative to the running
/// `flow42` executable so a development build (.build/debug/flow42)
/// finds the sibling debug binaries, and an installed build
/// (/usr/local/bin/flow42 or a homebrew prefix) finds installed
/// siblings. Failure to launch is silent — the CLI command still
/// proceeds; the user just loses the visual chrome and we'll surface
/// that absence later via the `flow42 doctor` path.
func ensureCompanionApps() {
    let exePath = resolvedExecutablePath()
    let exeDir = (exePath as NSString).deletingLastPathComponent
    launchSiblingIfNotRunning(name: "Flow42Menu", siblingDir: exeDir)
    launchSiblingIfNotRunning(name: "Flow42App", siblingDir: exeDir)
}

/// Resolved absolute path of the running flow42 binary, with symlinks
/// followed. Mirrors the helper Record.swift uses for daemon re-exec
/// so we don't drift from "where am I really?" semantics.
private func resolvedExecutablePath() -> String {
    var size = UInt32(0)
    _ = _NSGetExecutablePath(nil, &size)
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
    defer { buf.deallocate() }
    guard _NSGetExecutablePath(buf, &size) == 0 else {
        return CommandLine.arguments[0]
    }
    return URL(fileURLWithPath: String(cString: buf))
        .resolvingSymlinksInPath().path
}

/// Spawn `<siblingDir>/<name>` as a detached process if no process with
/// that name is currently running. Process matching is by basename of
/// the executable path because that's what `NSRunningApplication` and
/// `pgrep -f` agree on across debug and installed builds.
private func launchSiblingIfNotRunning(name: String, siblingDir: String) {
    if isProcessRunning(named: name) { return }
    let candidate = (siblingDir as NSString).appendingPathComponent(name)
    guard FileManager.default.isExecutableFile(atPath: candidate) else {
        // No sibling at this path — running from a partial install or
        // an unfamiliar layout. Stay silent; the user can launch the
        // app manually.
        return
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: candidate)
    task.arguments = []
    // Detach from this process group: when the CLI exits, the apps
    // keep running. Standard streams go to /dev/null so the apps don't
    // accidentally write into the CLI's stdout (which would corrupt
    // any JSON output downstream).
    if let nullR = FileHandle(forReadingAtPath: "/dev/null") {
        task.standardInput = nullR
    }
    if let nullW = FileHandle(forWritingAtPath: "/dev/null") {
        task.standardOutput = nullW
        task.standardError = nullW
    }
    do {
        try task.run()
        // Give the menu/app a brief moment to claim its UI scene before
        // the calling command starts emitting state changes. ~250ms is
        // enough for AppKit to stand up the menu bar item without
        // making the CLI feel sluggish.
        usleep(250_000)
    } catch {
        // Swallow — companion launch is best-effort. A missing menu
        // doesn't block recording; the user will notice and can
        // launch manually.
    }
}

/// Is there a running process whose executable basename matches `name`?
/// Uses `NSRunningApplication.runningApplications(withBundleIdentifier:)`
/// when possible (fast and exact) and falls back to scanning every
/// running application's executable URL for the basename.
private func isProcessRunning(named name: String) -> Bool {
    for app in NSWorkspace.shared.runningApplications {
        if let url = app.executableURL,
           url.lastPathComponent == name {
            return true
        }
    }
    return false
}

// MARK: - Status

func printStatus() {
    print("Flow42 v\(Flow42Core.version)")
    print("")

    let hasAX = AXIsProcessTrusted()
    print("Accessibility: \(hasAX ? "granted" : "NOT GRANTED")")
    if !hasAX {
        print("  Run: flow42 setup")
    }

    let hasScreenRecording = ScreenCapture.hasPermission()
    print("Screen Recording: \(hasScreenRecording ? "granted" : "not granted")")

    let recipes = RecipeStore.listRecipes()
    print("Recipes: \(recipes.count) installed")

    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    print("Running apps: \(apps.count)")

    print("")
    print(hasAX ? "Status: Ready" : "Status: Run `flow42 setup` first")
}

// MARK: - Usage

func printUsage() {
    print("""
    Flow42 v\(Flow42Core.version) - Accessibility-tree MCP server for AI agents

    Usage: flow42 <command>

    Commands:
      mcp            Start the MCP server (used by Claude Code)
      setup          Interactive setup wizard (first-time configuration)
      doctor         Diagnose issues and suggest fixes
      status         Quick health check
      record         Record a flow to ~/.flow42/flows/
      flows          List recordings in ~/.flow42/flows/
      play           Open / advance / pause / end a play of a recorded flow
                     (start | end | current | next | pause | resume | wait |
                     show | list | log)
      do             Execute one unit action during an active driving play
                     (click, type, press, hotkey, scroll, hover, long-press,
                     drag, window, focus, app-switch, navigate). Replaces
                     the previous `act` namespace.
      stop           End whichever session (recording or play) is active
      snapshot       Capture an image of the current screen / page
      tree           Dump the accessibility hierarchy of the current screen / page
      state          List running apps with windows, positions, sizes
      find           Search elements by name / role / DOM id / class
      inspect        Full metadata for one element (--query | --dom-id)
      element-at     Identify the element at screen coords (--x --y)
      read           Extract text content from an app or element subtree
      annotate       Set-of-Marks labeled screenshot
      wait           Poll for a condition with timeout (urlContains, elementExists, …)
      annotations    List/show/clear annotations captured via Cmd+Shift+A
      structure      Prepare a recording for the agent's three-pass structuring
      view           Render a recorded flow.yaml as markdown (human or
                     headless-script audience)
      chrome-launch  Launch Chrome with the local debug endpoint enabled
      setup-browser  One-shot wizard: launch Chrome, auto-load extension, register
                     native-messaging manifest, verify the round-trip
      install        Register the Chrome native-messaging manifest
      install-skills Install flow42-cli + flow-creator into ~/.claude/skills/
      native-host    Run as a Chrome native-messaging host (called by Chrome)
      version        Print version

    Get started:
      flow42 setup     Configure permissions and MCP
      flow42 doctor    Check if everything is working

    Flow42 gives AI agents eyes and hands on macOS.
    """)
}
