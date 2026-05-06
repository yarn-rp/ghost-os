// Flow42App.swift - @main entry for the Flow42 main window app.
//
// This is the user's everyday surface. Distinct from:
//
//   - Flow42Menu  — the menu-bar agent (LSUIElement, no Dock, overlays)
//   - flow42 CLI  — the headless verb dispatcher
//
// All three share Flow42Core. The main app is .regular (Dock icon, normal
// app menu, real window) — the menu-bar agent isn't going anywhere; this
// just adds a place to live between sessions where the user browses flows
// and starts them with a click.
//
// Boot pattern mirrors Flow42MenuApp.swift but with .regular activation
// policy. We also subscribe to the same StateClient — when the user (or
// the CLI, or the menu) starts a play/recording, the main app sees it
// instantly via FSEvents and updates its UI in lockstep with the menu's
// overlays.

import AppKit
import Flow42Core
import SwiftUI

@main
@MainActor
struct Flow42App {
    static func main() {
        let app = NSApplication.shared
        let delegate = Flow42AppDelegate()
        app.delegate = delegate
        // .regular = Dock icon, app menu, real window (vs Flow42Menu's
        // .accessory which is dockless).
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class Flow42AppDelegate: NSObject, NSApplicationDelegate {

    private var stateClient: StateClient!
    private var projectStore: ProjectStore!
    private var coordinator: AppCoordinator!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Singleton enforcement: kill any phantom recording state
        // (daemon pid is dead but state.json still claims active)
        // BEFORE the StateClient subscribes. Otherwise the first
        // FSEvents read paints us in recording mode for one frame
        // until reconcile catches up — which is exactly what the
        // user reported seeing.
        StateFile.reconcile()

        let client = StateClient()
        let projects = ProjectStore()
        let coord = AppCoordinator()
        self.stateClient = client
        self.projectStore = projects
        self.coordinator = coord

        // The single primary window. Sized to leave breathing room
        // around the sidebar + content; user can resize freely.
        let initialSize = NSSize(width: 1100, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Flow42"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.center()
        window.setFrameAutosaveName("Flow42AppMainWindow") // remember position

        // Near-black NSWindow background in dark mode (matches
        // DT.backdrop in Flow42Core). Eliminates the system grey
        // flash that would otherwise paint behind the SwiftUI
        // hierarchy during launch and view transitions. The named
        // dynamic provider re-resolves on appearance toggles so
        // light-mode users still see a clean off-white.
        window.backgroundColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor(srgbRed: 0.035, green: 0.035, blue: 0.043, alpha: 1)
                : NSColor(srgbRed: 0.96,  green: 0.96,  blue: 0.97,  alpha: 1)
        }

        // SwiftUI root. Both the StateClient (live recording / play
        // tracking via FSEvents on state.json) and the ProjectStore
        // (sidebar projects + active selection, persisted in
        // config.yaml) flow into the environment so any view can bind
        // without prop-drilling.
        window.contentView = NSHostingView(
            rootView: AppShell()
                .environmentObject(client)
                .environmentObject(projects)
                .environmentObject(coord)
        )
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quit when the last (only) window closes — standard single-window
    /// app behaviour. The menu-bar agent stays running independently.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
