// BackSwipeGesture.swift - Trackpad two-finger swipe-back for SwiftUI's
// NavigationStack on macOS.
//
// SwiftUI ships swipe-back natively on iOS but not on macOS — the
// NavigationStack push animates correctly, the gesture just doesn't
// hook up. We bridge it here with a `localEventMonitor` that catches
// the system's gesture-phase pan events. When the user does a clear
// rightward two-finger swipe with cumulative horizontal travel past a
// threshold, we call `onBack()` which the host (AppShell) wires to
// `path.removeLast()`.
//
// We use the swipe-gesture phase semantics rather than `.swipe` events
// because macOS only emits `.swipe` for 3-finger swipes by default
// (when "Swipe between pages" is set to three fingers in System
// Settings). Two-finger swipes show up as `.scrollWheel` events with
// `phase` flags — that's the standard browser back gesture too.

import AppKit
import Combine
import SwiftUI

/// View modifier that fires `onBack` when the user trackpad-swipes
/// right past a small horizontal threshold. Coalesces a single swipe
/// (begin → cancelled) into one callback so we never pop more than
/// one frame per gesture.
struct BackSwipeGesture: ViewModifier {
    let onBack: () -> Void

    func body(content: Content) -> some View {
        content.background(
            BackSwipeMonitor(onBack: onBack).frame(width: 0, height: 0)
        )
    }
}

extension View {
    /// Pop one navigation frame when the user trackpad-swipes right.
    /// Apply to the same view that owns the NavigationStack's path.
    func onSwipeBack(_ onBack: @escaping () -> Void) -> some View {
        modifier(BackSwipeGesture(onBack: onBack))
    }
}

/// Hosts a tiny zero-size NSView that installs the local event
/// monitor when it lands in the window. The monitor sees every scroll
/// event delivered to this app, decides if it's a horizontal-only
/// swipe in the back direction, and fires the callback.
private struct BackSwipeMonitor: NSViewRepresentable {
    let onBack: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(onBack: onBack)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Refresh the closure target so SwiftUI re-renders that change
        // the binding underneath get picked up.
        context.coordinator.onBack = onBack
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onBack: () -> Void = {}
        private var monitor: Any?
        // Cumulative horizontal travel across the current gesture.
        // Reset to 0 on phase=.began; checked on .ended.
        private var horizontalTravel: CGFloat = 0
        private var verticalTravel: CGFloat = 0
        private var inGesture = false

        func attach(onBack: @escaping () -> Void) {
            self.onBack = onBack
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self else { return event }
                self.handle(event)
                return event
            }
        }

        func detach() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            // Only trackpad gestures carry phase info; mouse-wheel
            // scrolls have phase == [] which we ignore for back swipe.
            let phase = event.phase
            if phase.contains(.began) {
                horizontalTravel = 0
                verticalTravel = 0
                inGesture = true
                return
            }
            if !inGesture { return }
            // Accumulate during the changed phase.
            if phase.contains(.changed) {
                horizontalTravel += event.scrollingDeltaX
                verticalTravel += abs(event.scrollingDeltaY)
                return
            }
            // On end / cancel, decide: was it a clean rightward
            // horizontal swipe?
            if phase.contains(.ended) || phase.contains(.cancelled) {
                let h = horizontalTravel
                let v = verticalTravel
                inGesture = false
                horizontalTravel = 0
                verticalTravel = 0
                // Threshold: 80pt horizontal travel, dominantly
                // horizontal (h > 1.5x v). Positive deltaX = swipe
                // right (the back direction in macOS's web-view
                // convention).
                guard phase.contains(.ended) else { return }
                if h > 80 && h > v * 1.5 {
                    DispatchQueue.main.async { [onBack = self.onBack] in
                        onBack()
                    }
                }
            }
        }
    }
}
