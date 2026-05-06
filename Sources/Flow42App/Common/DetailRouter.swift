// DetailRouter.swift - Strongly-typed navigator for the main window's
// detail pane.
//
// SwiftUI's NavigationStack inside NavigationSplitView's detail
// column doesn't ship a slide animation on macOS — pushes cross-fade
// or hard-cut depending on the OS version. We replace it with our
// own small router so the detail pane behaves like Mail / Notes:
// pushed views slide in from the right, swipes / back-button slides
// them back out.
//
// Pushes and pops are wrapped in `withAnimation` here; the
// `DetailPane` view picks up the state change and runs the explicit
// `.transition(.move(edge: .trailing))` modifier on each route's
// container.

import Combine
import Foundation
import SwiftUI

/// One frame of the detail-pane navigation. Add a case here to
/// support a new pushed destination.
enum DetailRoute: Equatable, Hashable {
    case flow(FlowSummary)
    case recordingHandoff(RecordingHandoff)
    /// Autonomous-run chat surface — replaces the floating panel's old
    /// "chat-only" mode. Pushed when the agent posts a fresh
    /// TranscriptEvent and no recording or play is active.
    case autonomousRun
}

@MainActor
final class DetailRouter: ObservableObject {
    @Published var stack: [DetailRoute] = []

    /// Push a new route onto the stack with a slide animation.
    func push(_ route: DetailRoute) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            stack.append(route)
        }
    }

    /// Pop the top route off with the same slide animation in
    /// reverse. No-op when the stack is empty.
    func pop() {
        guard !stack.isEmpty else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            _ = stack.removeLast()
        }
    }

    /// Clear the stack — used when the active project changes (the
    /// previously pushed flow no longer belongs to the visible
    /// project).
    func reset() {
        guard !stack.isEmpty else { return }
        stack.removeAll()
    }
}
