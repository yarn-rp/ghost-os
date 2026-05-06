// DetailPane.swift - The main window's right pane, rendered as a
// slide-stack of routes on top of a static root view.
//
// Why this isn't NavigationStack: SwiftUI's NavigationStack inside
// NavigationSplitView's detail column on macOS doesn't ship the
// horizontal-slide push transition users expect from Mail / Notes.
// Replacing it with a hand-rolled stack gives us:
//
//   - Reliable `.move(edge: .trailing)` transitions on push and pop
//   - A built-in back chevron at the top-left of every pushed frame
//   - Explicit control over the back-swipe gesture (handled in
//     AppShell via `BackSwipeGesture`)
//
// The root view (typically the flows list) stays mounted underneath
// while pushed routes slide over it. Each pushed route gets an
// opaque background so the root doesn't bleed through during the
// transition.

import Flow42Core
import SwiftUI

struct DetailPane<Root: View>: View {
    @ObservedObject var router: DetailRouter
    let rootContent: () -> Root

    var body: some View {
        ZStack(alignment: .topLeading) {
            rootContent()
            ForEach(Array(router.stack.enumerated()), id: \.offset) { idx, route in
                routeView(for: route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DT.backdrop)
                    .overlay(alignment: .topLeading) {
                        backChevron
                            .padding(.top, DT.s12)
                            .padding(.leading, DT.s16)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
                    .zIndex(Double(idx + 1))
            }
        }
        // Animate the ZStack diff when the stack changes so the
        // transitions above actually fire.
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: router.stack)
    }

    @ViewBuilder
    private func routeView(for route: DetailRoute) -> some View {
        switch route {
        case .flow(let summary):
            FlowDetailView(flow: summary)
        case .recordingHandoff(let handoff):
            RecordingHandoffView(handoff: handoff)
        case .autonomousRun:
            // The autonomous-run chat reads from the shared
            // AgentLatestClient injected via the environment by
            // AppShell. Held there as a @StateObject so revisions
            // don't reset on every push.
            AutonomousRunRoute()
        }
    }

    /// Floating back button — the equivalent of NavigationStack's
    /// system chevron. Sits over the route's content at top-left so
    /// it's always reachable regardless of the route's own layout.
    private var backChevron: some View {
        Button(action: { router.pop() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .glassIconButton()
        .help("Back")
        .keyboardShortcut("[", modifiers: [.command])
    }
}
