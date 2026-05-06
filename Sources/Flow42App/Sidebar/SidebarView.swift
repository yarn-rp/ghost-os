// SidebarView.swift - Project-driven left rail.
//
// Layout (top → bottom):
//   PROJECTS section header (small caps)
//   ├ Personal (pinned, builtin)
//   ├ <user projects, ordered by addedAt newest-first>
//   ├ + Add project…           (folder picker / drag target)
//   spacer
//   ──────                     (divider)
//   ⚙ Settings                 (anchored bottom via safeAreaInset)
//
// Active state is a 4pt accent bar at the LEFT edge + 6% accent fill
// (subtle, per the macOS-design-skill — not a loud accent block). Hover
// gives 3% extra fill.
//
// Drag-and-drop: dropping a folder onto the `+ Add project…` row (or
// anywhere on the sidebar — the Add row catches it) calls
// `ProjectStore.addProject(at:)` and switches active.

import AppKit
import Flow42Core
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Binding var selection: AppDestination?
    @EnvironmentObject private var projectStore: ProjectStore

    @State private var dropHovering: Bool = false

    /// Which spaces the user has expanded in the tree. Independent of
    /// selection so multiple spaces can be open at once — clicking
    /// one row doesn't collapse the others. Persists for the lifetime
    /// of this view; on a fresh launch only the active space starts
    /// expanded (seeded in `onAppear`).
    @State private var expandedIds: Set<String> = []

    var body: some View {
        // NavigationSplitView's sidebar column already renders an
        // NSVisualEffectView with `.sidebar` material under our
        // SwiftUI content. Adding our OWN VibrancyBackground on top of
        // that doubled the vibrancy and read as a muddy grey — the
        // user explicitly flagged this. Now we just lay content on the
        // system sidebar surface and let it provide the material. Any
        // tinting we want goes ON TOP via subtle .background fills,
        // not by replacing the system layer.
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Spaces")
                .padding(.horizontal, DT.s12)
                .padding(.top, DT.s12)
                .padding(.bottom, DT.s4)

            ForEach(projectStore.projects) { project in
                ProjectRow(
                    project: project,
                    isActive: isProjectActive(project),
                    isExpanded: expandedIds.contains(project.id),
                    activeFilter: activeFilter(for: project),
                    onSelect: { selectAndExpand(project) },
                    onToggleExpand: { toggleExpand(project) },
                    onSelectFilter: { f in selectChild(project, filter: f) },
                    onRemove: project.pinned ? nil : { remove(project) },
                    onRevealInFinder: { revealInFinder(project) }
                )
            }

            AddProjectButton(onAdd: { addProjectViaPicker() })
                .padding(.top, DT.s4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Flow42")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Settings stays anchored at the bottom regardless of how
            // many projects the user adds. Single hairline divider on
            // top — no duplicate vibrancy material.
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                SettingsRow(
                    isActive: selection == .settings,
                    onSelect: { selection = .settings }
                )
                .padding(.bottom, DT.s4)
            }
        }
        // Whole sidebar accepts folder drops as a friendly fallback if
        // the user releases anywhere over it (not just the Add row).
        .onDrop(of: [.fileURL], isTargeted: $dropHovering) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            // Seed the active space as expanded so the user lands on
            // a populated tree on first paint. Other spaces stay
            // collapsed until they're tapped.
            if case .project(let id, _) = selection {
                expandedIds.insert(id)
            } else {
                expandedIds.insert(projectStore.activeProject.id)
            }
        }
        .onChange(of: selection) { _, newSelection in
            // Deep-links from the menu app or programmatic selection
            // changes (e.g. command palette) should open the tree
            // branch they target so the user can see where they are.
            if case .project(let id, _) = newSelection {
                withAnimation(Self.treeAnimation) {
                    expandedIds.insert(id)
                }
            }
        }
    }

    // MARK: - Header

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: DT.f10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    /// True when this project owns the current selection (regardless
    /// of which sub-filter is active). Used to expand the tree.
    private func isProjectActive(_ project: Flow42Project) -> Bool {
        if case .project(let id, _) = selection { return id == project.id }
        return false
    }

    /// The active sub-filter when this project is selected, or nil
    /// when a different project is active.
    private func activeFilter(for project: Flow42Project) -> ProjectFilter? {
        if case .project(let id, let filter) = selection, id == project.id {
            return filter
        }
        return nil
    }

    private func select(_ project: Flow42Project, filter: ProjectFilter) {
        selection = .project(id: project.id, filter: filter)
        projectStore.selectProject(project)
    }

    /// One animation curve for every expand / collapse to keep the
    /// tree's motion language coherent. Spring instead of easeInOut
    /// gives a touch of natural overshoot without feeling cartoony.
    private static let treeAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Tap on the parent row — selects with `.all` AND opens the
    /// space's branch. We only insert here (never remove) so opening
    /// a different space leaves the previously-expanded ones alone.
    private func selectAndExpand(_ project: Flow42Project) {
        select(project, filter: .all)
        withAnimation(Self.treeAnimation) {
            expandedIds.insert(project.id)
        }
    }

    /// Tap on a child row — selects that filter + ensures the parent
    /// is expanded (so deep-link / shortcut routing animates open
    /// the tree branch automatically).
    private func selectChild(_ project: Flow42Project, filter: ProjectFilter) {
        select(project, filter: filter)
        withAnimation(Self.treeAnimation) {
            expandedIds.insert(project.id)
        }
    }

    /// Tap on the chevron — toggles expansion without changing
    /// selection. Closing animates the children sliding up + fading
    /// out via the `.transition` modifier on the children block,
    /// driven by this `withAnimation` context.
    private func toggleExpand(_ project: Flow42Project) {
        withAnimation(Self.treeAnimation) {
            if expandedIds.contains(project.id) {
                expandedIds.remove(project.id)
            } else {
                expandedIds.insert(project.id)
            }
        }
    }

    private func remove(_ project: Flow42Project) {
        // Confirm via NSAlert — same destructive-action treatment we
        // use elsewhere. Removing doesn't touch the folder on disk;
        // the alert copy explains that.
        let alert = NSAlert()
        alert.messageText = "Remove the \"\(project.name)\" space from your sidebar?"
        alert.informativeText = "The folder on disk stays intact — you can add the space back any time. This only removes it from your sidebar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let removeBtn = alert.addButton(withTitle: "Remove")
        if #available(macOS 11.0, *) {
            removeBtn.hasDestructiveAction = true
        }
        alert.buttons[0].keyEquivalent = "\r" // Cancel default
        if alert.runModal() == .alertSecondButtonReturn {
            projectStore.removeProject(project)
            // If we just removed the active project, the store flipped
            // active to whatever's left; sync the sidebar selection.
            selection = .project(id: projectStore.activeProject.id, filter: .all)
        }
    }

    private func revealInFinder(_ project: Flow42Project) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: project.path)]
        )
    }

    // MARK: - Add via NSOpenPanel

    private func addProjectViaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a folder for the new space"
        panel.message = "Flow42 will create a `.flow42/` directory in this folder to store the space's flows."
        panel.prompt = "Add Space"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try projectStore.addProject(at: url.path)
            // Sidebar reflects the new active project automatically
            // via the .onChange(of: activeProjectId) in AppShell.
        } catch ProjectStore.AddError.alreadyAdded(let existingId) {
            // Idempotent re-add: ProjectStore already switched active.
            selection = .project(id: existingId, filter: .all)
        } catch {
            presentAddError(error)
        }
    }

    // MARK: - Drop target

    /// Drop a folder anywhere on the sidebar → add it as a project.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                if let str = item as? String { return URL(string: str) }
                if let nsurl = item as? NSURL { return nsurl as URL }
                return nil
            }()
            guard let url else { return }
            // Folder check — we only add directories.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return }
            DispatchQueue.main.async {
                do {
                    _ = try self.projectStore.addProject(at: url.path)
                } catch ProjectStore.AddError.alreadyAdded(let existingId) {
                    self.selection = .project(id: existingId, filter: .all)
                } catch {
                    self.presentAddError(error)
                }
            }
        }
        return true
    }

    private func presentAddError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't add the space"
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Project row

private struct ProjectRow: View {
    let project: Flow42Project
    /// True whenever this project owns the current selection
    /// (regardless of filter). Drives the active-row styling on the
    /// parent.
    let isActive: Bool
    /// True when the user has expanded this space's tree branch.
    /// Independent of selection — multiple spaces can be expanded at
    /// once.
    let isExpanded: Bool
    /// The active sub-filter when this project is selected. Nil =>
    /// another project is active. `.all` => project root is selected;
    /// no child highlighted. `.flows` / `.drafts` => the matching
    /// child gets the accent.
    let activeFilter: ProjectFilter?
    /// Tap on the parent row body — selects the project with `.all`
    /// filter AND expands the tree.
    let onSelect: () -> Void
    /// Tap on the chevron — toggles expansion without changing
    /// selection. Used to collapse a space the user no longer wants
    /// to scan.
    let onToggleExpand: () -> Void
    /// Tap on a child row — selects the project with the given filter.
    let onSelectFilter: (ProjectFilter) -> Void
    /// Nil → row's context menu doesn't offer Remove (used for Personal).
    let onRemove: (() -> Void)?
    let onRevealInFinder: () -> Void

    @State private var hovered: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            parentRow
            // Children animate in from the top with a fade so the
            // expand reads as a real tree-open rather than a hard
            // cut. The animation curve comes from the
            // `withAnimation { … }` wrapper at the mutation site in
            // SidebarView — no `.animation(_:value:)` modifier here
            // because that would compete with `withAnimation`'s
            // context and silently swallow the removal transition.
            if isExpanded {
                VStack(spacing: 0) {
                    ChildRow(
                        label: "Flows",
                        icon: "rectangle.stack.fill",
                        isActive: isActive && activeFilter == .flows,
                        onSelect: { onSelectFilter(.flows) }
                    )
                    ChildRow(
                        label: "Drafts",
                        icon: "waveform.path.badge.plus",
                        isActive: isActive && activeFilter == .drafts,
                        onSelect: { onSelectFilter(.drafts) }
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var parentRow: some View {
        HStack(spacing: DT.s8) {
            // 4pt accent bar at the LEFT edge — the active-state
            // signal. Only fires when the PROJECT ROOT is selected
            // (.all). When a child filter is active, the accent
            // moves to the child row instead.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isActive && activeFilter == .all ? DT.magenta : Color.clear)
                .frame(width: 3, height: 18)

            // Disclosure chevron — its own click target so the user
            // can collapse a space without changing the selection.
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 18)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse" : "Expand")

            // The rest of the row (icon + name) is the select-target.
            Button(action: onSelect) {
                HStack(spacing: DT.s8) {
                    Image(systemName: project.builtin ? "house.fill" : "folder.fill")
                        .font(.system(size: DT.f13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)

                    Text(project.name)
                        .font(.system(size: DT.f13, weight: isActive && activeFilter == .all ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, DT.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(DT.aHover, value: hovered)
        .animation(DT.aMode, value: activeFilter)
        .contextMenu {
            Button("Reveal in Finder", action: onRevealInFinder)
            Button("Open .flow42 in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: project.dotFlow42Path)]
                )
            }
            if let onRemove {
                Divider()
                Button("Remove from Sidebar", role: .destructive, action: onRemove)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive && activeFilter == .all {
            RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                .fill(DT.magenta.opacity(0.12))
                .padding(.vertical, 1)
        } else if hovered {
            RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                .fill(.primary.opacity(0.05))
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }
}

/// One nested row under an expanded project. Same accent-bar
/// treatment as the parent so the active state reads consistently.
private struct ChildRow: View {
    let label: String
    let icon: String
    let isActive: Bool
    let onSelect: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DT.s8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isActive ? DT.magenta : Color.clear)
                    .frame(width: 3, height: 16)
                // Indent under the parent's chevron + folder gutter so
                // the tree structure is visually obvious.
                Color.clear.frame(width: 18, height: 1)
                Image(systemName: icon)
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                Text(label)
                    .font(.system(size: DT.f12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, DT.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Group {
                    if isActive {
                        RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                            .fill(DT.magenta.opacity(0.12))
                            .padding(.vertical, 1)
                    } else if hovered {
                        RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                            .fill(.primary.opacity(0.05))
                            .padding(.vertical, 1)
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DT.aHover, value: hovered)
        .animation(DT.aMode, value: isActive)
    }
}

// MARK: - Add project row

private struct AddProjectButton: View {
    let onAdd: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: DT.s8) {
                Color.clear.frame(width: 3, height: 18) // align with accent-bar gutter
                Image(systemName: "plus.circle")
                    .font(.system(size: DT.f13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text("Add space…")
                    .font(.system(size: DT.f13))
                    .foregroundStyle(hovered ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, DT.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.05) : Color.clear)
                    .padding(.vertical, 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1.0 : 0.9)
        .onHover { hovered = $0 }
        .animation(DT.aHover, value: hovered)
        .help("Open a folder and create a `.flow42/` space there")
    }
}

// MARK: - Settings row

private struct SettingsRow: View {
    let isActive: Bool
    let onSelect: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DT.s8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isActive ? DT.magenta : Color.clear)
                    .frame(width: 3, height: 18)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: DT.f13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text("Settings")
                    .font(.system(size: DT.f13, weight: isActive ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, DT.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                    .fill(rowBg)
                    .padding(.vertical, 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DT.aHover, value: hovered)
        .animation(DT.aMode, value: isActive)
    }

    private var rowBg: Color {
        if isActive { return DT.magenta.opacity(0.12) }
        if hovered { return .primary.opacity(0.05) }
        return .clear
    }
}

// (VibrancyBackground removed — the system NavigationSplitView already
// provides the sidebar's `.sidebar` material. Wrapping our own
// NSVisualEffectView on top doubled the vibrancy and read as muddy
// grey. Let the system layer do its job.)
