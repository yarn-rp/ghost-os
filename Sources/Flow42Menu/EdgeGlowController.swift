// EdgeGlowController.swift - Owns one EdgeGlowWindow per NSScreen and swaps
// the SwiftUI content when the mode changes.
//
// Responsibilities:
//   - On launch / display change: create one window per attached screen.
//   - On mode change: update each hosted EdgeGlowView with the new mode and
//     animate window opacity (fade in/out) so transitions feel smooth.

import AppKit
import Flow42Core
import SwiftUI

@MainActor
final class EdgeGlowController {

    private var windows: [EdgeGlowWindow] = []
    private var hostingViews: [NSHostingView<EdgeGlowView>] = []
    private var currentState: DerivedState = .idle

    init() {
        rebuildWindowsForScreens()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        apply(state: .idle, animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Drive a new mode. Idle hides the windows entirely; non-idle modes show
    /// them and update the hosted view's mode binding.
    func apply(state: DerivedState, animated: Bool = true) {
        currentState = state
        for (i, window) in windows.enumerated() {
            // Replace contents so the SwiftUI view re-evaluates with the new
            // mode (the simplest path that doesn't require `@Published` state
            // bridges between AppKit and SwiftUI).
            let newHost = NSHostingView(rootView: EdgeGlowView(state: state))
            newHost.frame = window.contentView?.bounds ?? .zero
            newHost.autoresizingMask = [.width, .height]
            window.contentView = newHost
            if i < hostingViews.count {
                hostingViews[i] = newHost
            } else {
                hostingViews.append(newHost)
            }

            if state == .idle {
                if animated {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.4
                        window.animator().alphaValue = 0
                    } completionHandler: { [weak self] in
                        // Only hide if we're STILL idle by the time the
                        // fade-out completes. Without this guard, a
                        // rapid idle → recording transition (which is
                        // exactly what `flow42 record start` produces)
                        // hits this completion AFTER the new
                        // recording's `orderFrontRegardless` and yanks
                        // the window back off-screen — that was the
                        // edge-glow-during-recording regression.
                        Task { @MainActor in
                            guard self?.currentState == .idle else { return }
                            window.orderOut(nil)
                        }
                    }
                } else {
                    window.alphaValue = 0
                    window.orderOut(nil)
                }
            } else {
                window.alphaValue = animated ? 0 : 1
                window.orderFrontRegardless()
                if animated {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.4
                        window.animator().alphaValue = 1
                    }
                }
            }
        }
    }

    @objc private func screensChanged() {
        rebuildWindowsForScreens()
        apply(state: currentState, animated: false)
    }

    private func rebuildWindowsForScreens() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        hostingViews.removeAll()

        for screen in NSScreen.screens {
            let window = EdgeGlowWindow(screen: screen)
            let host = NSHostingView(rootView: EdgeGlowView(state: currentState))
            host.frame = window.contentLayoutRect
            host.autoresizingMask = [.width, .height]
            window.contentView = host
            window.alphaValue = 0
            windows.append(window)
            hostingViews.append(host)
        }
    }
}
