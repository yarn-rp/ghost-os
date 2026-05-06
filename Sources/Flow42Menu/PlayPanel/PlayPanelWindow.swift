// PlayPanelWindow.swift - Borderless rounded window for the bottom-right
// play status panel.
//
// Anchored to NSScreen.main's bottom-right with a 16-pt inset. Window level
// is .statusBar so it floats above normal app windows but below the menu
// bar. canJoinAllSpaces means it stays put when the user switches Spaces.

import AppKit

final class PlayPanelWindow: NSPanel {

    /// `.nonactivatingPanel` makes us a great floater (no Dock-icon
    /// flashing, no app-activation steal on every click) but it also
    /// makes the window non-key by default — which means text fields
    /// inside can't accept keyboard input. We override to opt back in:
    /// the chat input field needs to be the first responder while the
    /// panel is in chat-only or chat-mode swap. macOS still won't yank
    /// focus from the user's frontmost app — this just lets US become
    /// key when the user actively clicks our text field.
    override var canBecomeKey: Bool { true }
    /// `canBecomeMain` stays false — we don't want to be the "main
    /// window" of the menu app (we're an accessory overlay).
    override var canBecomeMain: Bool { false }

    /// Width of the SwiftUI panel content. The window itself is wider so the
    /// SwiftUI shadow has room to render outside the panel's rounded edge.
    /// Without that bleed room, NSWindow clips the shadow.
    static let contentWidth: CGFloat = 400
    private static let shadowBleed: CGFloat = 40

    /// Total window width = panel width + shadow bleed on each side.
    private static let windowWidth: CGFloat = contentWidth + (shadowBleed * 2)

    convenience init() {
        let initial = NSRect(x: 0, y: 0, width: PlayPanelWindow.windowWidth, height: 200)
        self.init(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Hide from recordings + screenshots + Cmd+Shift+3/4/5. The
        // recording's per-step screenshots should reflect the user's
        // app, not Flow42's chrome. `sharingType = .none` works for
        // CGWindowListCreateImage (recorder), SCStream, and system
        // screenshots in one knob.
        self.sharingType = .none
        // No window-level shadow — SwiftUI's `.shadow(...)` on the rounded
        // panel handles it. Stacking both leaves the window's rectangular
        // silhouette visible behind the rounded glass card.
        self.hasShadow = false
        // Drag from anywhere on the panel that isn't a button. The user
        // wants to nudge the panel around when it's covering something.
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        // Buttons on the panel need clicks; do NOT ignore mouse events.
    }

    /// First-show anchor: position to the bottom-right of NSScreen.main.
    /// Right + bottom inset is a fixed 56 pt — feels right across screen
    /// sizes and avoids the "panel hugging the corner on small displays /
    /// drifting too far inward on big ones" problem of a proportional
    /// inset.
    func anchorDefault(toHeight contentHeight: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let inset: CGFloat = 56
        let totalHeight = contentHeight + (PlayPanelWindow.shadowBleed * 2)

        // Right edge: visible card ends `inset` from screen edge. The
        // window extends another `shadowBleed` past that to host the
        // shadow, so we offset the window further right.
        let panelRight = visible.maxX - inset
        let windowX = panelRight + PlayPanelWindow.shadowBleed - PlayPanelWindow.windowWidth
        // Bottom edge: same idea, panel sits `inset` above screen.
        let panelBottom = visible.minY + inset
        let windowY = panelBottom - PlayPanelWindow.shadowBleed

        setFrame(
            NSRect(
                x: windowX,
                y: windowY,
                width: PlayPanelWindow.windowWidth,
                height: totalHeight
            ),
            display: true,
            animate: false
        )
    }

    /// Resize without moving: preserve the user's chosen position by
    /// keeping the window's bottom-left corner pinned to where it
    /// currently sits. Used on every state update *after* the first
    /// anchor so pause/play/advance doesn't snap the panel back to the
    /// default corner.
    func resize(toHeight contentHeight: CGFloat) {
        let totalHeight = contentHeight + (PlayPanelWindow.shadowBleed * 2)
        let current = self.frame
        // Keep `minY` (the bottom edge) — content "grows upward" when the
        // pause callout appears. Feels less jumpy than top-anchoring when
        // the user has dragged the panel into the middle of the screen.
        setFrame(
            NSRect(
                x: current.minX,
                y: current.minY,
                width: current.width,
                height: totalHeight
            ),
            display: true,
            animate: false
        )
    }
}
