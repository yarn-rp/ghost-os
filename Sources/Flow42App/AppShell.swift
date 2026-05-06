// AppShell.swift - The root SwiftUI view: sidebar nav (Projects) +
// content pane.
//
// Two top-level destinations now: per-project flows (the default), and
// Settings. Projects live in `ProjectStore`; selecting one in the
// sidebar swaps the detail pane to the project's flows list. Switching
// projects rebuilds the FlowsRepository against the active project's
// `flowsRoot` — no prop-drilling, no manual cache invalidation; the
// repository's lifetime is tied to the view's `id(activeProject.id)`.
//
// Detail-pane navigation runs through `DetailRouter` (a custom
// strongly-typed stack) rather than `NavigationStack` because the
// latter doesn't reliably slide on macOS when nested inside
// `NavigationSplitView`. See `DetailPane.swift` for the rendering
// shell + transition.

import Flow42Core
import SwiftUI

/// Filter applied to a project's flows list. `.all` shows both
/// sections (flows + drafts) on the same page; `.flows` and `.drafts`
/// scope the list to one collection at a time. The sidebar's tree
/// navigation uses these — clicking the project row selects `.all`
/// and expands its children, clicking a child selects that filter.
enum ProjectFilter: String, Equatable, Hashable, CaseIterable {
    case all
    case flows
    case drafts
}

/// Top-level destinations the sidebar offers. Driven by which row the
/// user clicked.
enum AppDestination: Equatable, Hashable {
    /// "Open this project in the flows list view." Stores the project
    /// id (not the whole struct) so transient renames don't break
    /// equality, plus the active sub-filter so the sidebar tree can
    /// route to a specific child of the project.
    case project(id: String, filter: ProjectFilter)
    case settings
}

struct AppShell: View {
    @EnvironmentObject private var stateClient: StateClient
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var coordinator: AppCoordinator

    @State private var selection: AppDestination?
    /// Detail-pane router. Held here so cross-cutting concerns (deep
    /// links, project switches) can manipulate the stack without
    /// drilling a binding through every level.
    @StateObject private var router = DetailRouter()

    // Per-recording chat sessions (Flow42Core/Common/ChatSession.swift)
    // replaced the global agent-latest pipe. Each chat lives under
    // <recording-dir>/chat/sessions/<id>/ and views build their own
    // SessionClient against the relevant directory. AppShell no
    // longer holds a global chat client.

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            DetailPane(router: router) { destinationView }
                // Trackpad two-finger swipe-right pops one frame off
                // the detail-pane stack — the macOS-native browser
                // back gesture. Only fires when there's actually
                // something to pop so a swipe on the top-level flows
                // list is harmless.
                .onSwipeBack { router.pop() }
        }
        .navigationSplitViewStyle(.balanced)
        // Paint the entire split-view shell with our near-black
        // backdrop so SwiftUI's default container greys never leak
        // through during view transitions.
        .background(AppBackdrop())
        .environmentObject(router)
        .onAppear {
            // First paint: open the active project. We can't just do
            // `@State private var selection = .project(id: ...)`
            // because the active id depends on the (environment-
            // injected) ProjectStore, which isn't available at the
            // initializer. So default it on appear.
            if selection == nil {
                selection = .project(id: projectStore.activeProject.id, filter: .all)
            }
        }
        .onChange(of: projectStore.activeProjectId) { _, newId in
            // Honour external changes (e.g. command palette, ⌘1, drag-
            // and-drop add-and-switch). Selecting a different project
            // in the sidebar updates the store, which updates this,
            // which we ignore to avoid a feedback loop.
            if case .project(let current, _) = selection, current == newId { return }
            selection = .project(id: newId, filter: .all)
            // A project switch resets the detail-pane stack: the old
            // pushed flow no longer belongs to the project that's
            // visible.
            router.reset()
        }
        .onChange(of: coordinator.pendingOpenFlowDir) { _, dir in
            guard let dir else { return }
            handleDeepLink(flowDir: dir)
            // Reset the value so the same dir can fire again later.
            coordinator.pendingOpenFlowDir = nil
        }
        .onChange(of: coordinator.pendingOpenRecording) { _, pending in
            guard let pending else { return }
            handleRecordingHandoff(dir: pending.dir, slug: pending.slug)
            coordinator.pendingOpenRecording = nil
        }
    }
    // (The auto-push to AutonomousRunRoute was removed when chat
    // moved to per-recording sessions. Every conversation now lives
    // inline on the recording-handoff or flow-detail surface; the
    // legacy `.autonomousRun` route stays in the enum for back-compat
    // but is no longer pushed automatically.)

    @ViewBuilder
    private var destinationView: some View {
        switch selection {
        case .project(let id, let filter):
            // Resolve the project AT RENDER TIME from the store so we
            // pick up renames / removals without restarting the view.
            // If the id went stale (project removed), fall through to
            // the active project as a safe fallback.
            let project = projectStore.projects.first(where: { $0.id == id })
                ?? projectStore.activeProject
            FlowsListView(project: project, filter: filter)
                // Re-instantiate on project change so the FlowsRepository
                // inside is rebuilt against the new flowsRoot. Filter
                // changes propagate through the `let filter` parameter
                // without forcing a repo rebuild.
                .id(project.id)

        case .settings:
            SettingsView()

        case .none:
            // Brief gap before onAppear seeds the selection. Should
            // never be visible to the user.
            Color.clear
        }
    }

    /// Resolve a deep-link to the right project + push the flow's
    /// detail view onto the navigation stack. Walks every project's
    /// flowsRoot looking for the one that owns this directory; if
    /// nothing matches we just bring the window forward without
    /// pushing.
    private func handleDeepLink(flowDir: String) {
        let normalized = (flowDir as NSString).standardizingPath
        // Find the project whose flowsRoot is the parent of `flowDir`.
        let owner = projectStore.projects.first { project in
            let root = (project.flowsRoot as NSString).standardizingPath
            return normalized.hasPrefix(root + "/") || normalized == root
        }
        if let owner, owner.id != projectStore.activeProjectId {
            projectStore.selectProject(owner)
            // The .onChange handler will reset `router.stack`; we
            // wait one tick before pushing so the new project's
            // FlowsListView is mounted first.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                pushFlowSummary(forDir: normalized)
            }
        } else {
            pushFlowSummary(forDir: normalized)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route a fresh-recording deep link to the RecordingHandoffView.
    /// Mirrors `handleDeepLink` (project-resolution + activate) but
    /// pushes a `RecordingHandoff` instead of a `FlowSummary`. The
    /// landing view auto-fires `AutonomousRunner.startForRecording`
    /// the moment it appears, so the agent is in chat by the time the
    /// user's eyes find the window.
    private func handleRecordingHandoff(dir: String, slug: String) {
        let normalized = (dir as NSString).standardizingPath
        let owner = projectStore.projects.first { project in
            let root = (project.flowsRoot as NSString).standardizingPath
            return normalized.hasPrefix(root + "/") || normalized == root
        }
        // Post-record auto-fire: the menu app sent us this notification
        // the moment `record stop` finalised, so the user expects the
        // chat to start immediately. The flows-list path also lands
        // here when a draft card is tapped; that route uses default
        // autoStart=false (see flowsGrid in FlowsListView).
        let handoff = RecordingHandoff(dir: normalized, slug: slug, autoStart: true)
        if let owner, owner.id != projectStore.activeProjectId {
            projectStore.selectProject(owner)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                router.push(.recordingHandoff(handoff))
            }
        } else {
            router.push(.recordingHandoff(handoff))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pushFlowSummary(forDir dir: String) {
        // Build a FlowSummary off a single read of the flow.yaml — same
        // shape FlowsRepository emits, so the destination renders
        // identically.
        guard let summary = FlowsRepository.loadSummary(directory: dir) else { return }
        router.push(.flow(summary))
    }
}
