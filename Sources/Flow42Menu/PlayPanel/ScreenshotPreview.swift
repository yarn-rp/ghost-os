// ScreenshotPreview.swift - Finder-spacebar-style transient preview for the
// step screenshot. Click the image in the play panel; a borderless window
// fades in, sized to the image (capped at 80% of the screen). Click
// anywhere on the preview, or press Escape, or press Space — the window
// fades out.
//
// We deliberately don't reach for QLPreviewPanel here: it expects to live
// in the responder chain of the key window, and our PlayPanelWindow is a
// `.statusBar`-level non-activating panel. Mixing the two leads to flaky
// dismissal. A small custom overlay is simpler and behaves predictably.

import AppKit
import SwiftUI

@MainActor
enum ScreenshotPreview {

    /// Show the image at full size, centered, with a transient fade-in.
    /// Calling again while a preview is already on screen swaps to the new
    /// image without rebuilding the window.
    static func show(_ image: NSImage) {
        let panel = sharedPanel
        panel.present(image: image)
    }

    static func dismiss() {
        sharedPanel.dismissAnimated()
    }

    private static let sharedPanel: ScreenshotPreviewWindow = {
        ScreenshotPreviewWindow()
    }()
}

// MARK: - Window

@MainActor
private final class ScreenshotPreviewWindow: NSPanel {

    private var hostingView: NSHostingView<ScreenshotPreviewView>?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .modalPanel                  // above the play panel
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.hasShadow = false                    // SwiftUI handles it
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isMovableByWindowBackground = false
    }

    /// Become key when shown so we can intercept Escape / Space without
    /// stealing focus from the user's actual app for too long.
    override var canBecomeKey: Bool { true }

    func present(image: NSImage) {
        // Build the SwiftUI view.
        let view = ScreenshotPreviewView(
            image: image,
            onDismiss: { [weak self] in self?.dismissAnimated() }
        )

        if let host = hostingView {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.autoresizingMask = [.width, .height]
            self.contentView = host
            hostingView = host
        }

        // Size + position. Cap at 85% of the active screen, preserve
        // aspect.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenSize = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxW = screenSize.width * 0.85
        let maxH = screenSize.height * 0.85
        let imgSize = image.size
        let scale = min(maxW / imgSize.width, maxH / imgSize.height, 1.0)
        let displaySize = CGSize(
            width: imgSize.width * scale,
            height: imgSize.height * scale
        )
        // Add padding for the SwiftUI shadow + caption strip.
        let frame = NSRect(
            x: 0, y: 0,
            width: displaySize.width + 60,
            height: displaySize.height + 60
        )
        if let visible = screen?.visibleFrame {
            let centered = NSRect(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2,
                width: frame.width,
                height: frame.height
            )
            self.setFrame(centered, display: false)
        } else {
            self.setFrame(frame, display: false)
        }

        self.alphaValue = 0
        self.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1
        }
    }

    func dismissAnimated() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        }
    }

    // Escape and Space dismiss — same as Finder's Quick Look.
    override func keyDown(with event: NSEvent) {
        // 53 = Escape, 49 = Space.
        if event.keyCode == 53 || event.keyCode == 49 {
            dismissAnimated()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - SwiftUI content

private struct ScreenshotPreviewView: View {
    let image: NSImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Full-window click target so clicking the dim area dismisses.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 30, x: 0, y: 12)
                .padding(30)
                // Tapping the image itself also dismisses (matches Quick Look).
                .onTapGesture { onDismiss() }
        }
        // Hint banner so the user knows how to close it (matches macOS
        // standard-issue Quick Look conventions).
        .overlay(alignment: .bottom) {
            Text("Press Space or Esc to close")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(.black.opacity(0.55))
                )
                .padding(.bottom, 18)
        }
    }
}
