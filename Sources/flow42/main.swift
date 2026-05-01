// main.swift - Flow42 v2 CLI entry point
//
// Thin CLI:
//   flow42 mcp       Start the MCP server (used by Claude Code)
//   flow42 setup     Interactive setup wizard
//   flow42 doctor    Diagnose issues and suggest fixes
//   flow42 status    Quick health check
//   flow42 record    Record a user-driven flow to ~/.openclaw/flow42/recipes/
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

case "act":
    Act.run(args: Array(args.dropFirst()))

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

case "mode":
    Mode.run(args: Array(args.dropFirst()))

case "annotations":
    Annotations.run(args: Array(args.dropFirst()))

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
      record         Record a flow to ~/.openclaw/flow42/recipes/
      flows          List recordings in ~/.openclaw/flow42/recipes/
      act            Execute one action (click, type, press, hotkey, scroll,
                     hover, long-press, drag, window, focus, app-switch, navigate)
      snapshot       Capture an image of the current screen / page
      tree           Dump the accessibility hierarchy of the current screen / page
      state          List running apps with windows, positions, sizes
      find           Search elements by name / role / DOM id / class
      inspect        Full metadata for one element (--query | --dom-id)
      element-at     Identify the element at screen coords (--x --y)
      read           Extract text content from an app or element subtree
      annotate       Set-of-Marks labeled screenshot
      wait           Poll for a condition with timeout (urlContains, elementExists, …)
      mode           Get/set the menu app's mode (idle | recording | autonomous)
      annotations    List/show/clear annotations captured via Cmd+Shift+A
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
