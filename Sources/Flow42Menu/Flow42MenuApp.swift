// Flow42MenuApp.swift - @main entry point for the Flow42 menu bar app.
//
// LSUIElement bundle (no Dock icon, no main menu). Boots the four long-lived
// objects:
//
//   StateClient          watches ~/.flow42/state.json
//   EdgeGlowController   per-screen overlay windows for the magenta/orange glow
//   MenuController       status item + popover
//
// The annotation hotkey controller (Cmd+Shift+A) is added in a follow-up
// commit; left as a TODO so the bundle compiles and runs end-to-end with just
// the glow + status item today.

import AppKit
import Flow42Core
import SwiftUI

@main
@MainActor
struct Flow42MenuApp {
    static func main() {
        SingleInstance.acquireOrExit()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // LSUIElement-equivalent at runtime
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var stateClient: StateClient!
    private var edgeGlow: EdgeGlowController!
    private var menu: MenuController!
    private var annotation: AnnotationController!
    private var subscription: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First-launch nicety: when running from an .app bundle, opt the
        // user into launch-at-login automatically. Skipped silently for
        // `swift run` dev workflows. The user can flip it via the menu.
        LaunchAtLogin.ensureRegisteredOnFirstLaunch()

        let client = StateClient()
        let glow = EdgeGlowController()
        let menu = MenuController(stateClient: client)
        let annotation = AnnotationController()

        self.stateClient = client
        self.edgeGlow = glow
        self.menu = menu
        self.annotation = annotation

        // Bridge state changes → edge glow.
        let cancellable = client.$state.sink { [weak self] state in
            self?.edgeGlow.apply(mode: state.mode)
        }
        self.subscription = cancellable

        // Apply the initial mode immediately so a pre-set state.json shows up
        // without waiting for a change.
        edgeGlow.apply(mode: client.state.mode, animated: false)
    }
}
