// EdgeGlowWindow.swift - Borderless transparent overlay window per NSScreen.
//
// One of these covers each screen; together they are the canvas the edge-glow
// gradient is painted into. Properties:
//
//   * .statusBar window level    — above normal app windows, below menu bar
//   * transparent background     — only the gradient is visible
//   * ignoresMouseEvents = true  — the user can click straight through
//   * canJoinAllSpaces           — visible regardless of the current Space
//   * stationary                 — doesn't move during Mission Control
//   * fullScreenAuxiliary        — shows over fullscreen apps
//   * ignoresCycle               — Cmd-` doesn't focus it
//   * not on the Dock / not in Cmd-Tab — accessory app + non-activating panel

import AppKit
import Flow42Core
import SwiftUI

@MainActor
final class EdgeGlowWindow: NSPanel {

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        // Don't show up in recordings, screenshots, or window-list
        // captures. The recorder uses CGWindowListCreateImage and
        // honours `sharingType = .none` — same exclusion knob 1Password
        // and other privacy-sensitive apps use. The user sees the glow
        // on screen; the camera lens of the recorder doesn't.
        self.sharingType = .none
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        self.ignoresMouseEvents = true
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.setFrame(screen.frame, display: false)
    }

    /// NSPanel returns false here by default; we override so SwiftUI hosting
    /// view layout is happy. The window itself never accepts focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
