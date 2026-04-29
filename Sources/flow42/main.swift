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
      mcp       Start the MCP server (used by Claude Code)
      setup     Interactive setup wizard (first-time configuration)
      doctor    Diagnose issues and suggest fixes
      status    Quick health check
      record    Record a flow to ~/.openclaw/flow42/recipes/
      version   Print version

    Get started:
      flow42 setup     Configure permissions and MCP
      flow42 doctor    Check if everything is working

    Flow42 gives AI agents eyes and hands on macOS.
    """)
}
