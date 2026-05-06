// FlowsListView.swift - Browse a project's flows.
//
// Layout: page header (project name + record button) over a 3-column
// grid of screenshot-forward cards. Cards lead with the recorded
// thumbnail (16:10) so the page reads visually first — the user
// recognises the flow they want by what it LOOKS like, not by reading
// titles in a list.
//
// Hover lifts the card (1.01 scale + orange-tinted shadow + border)
// to bring the brand palette to the foreground without making it
// loud at rest.

import AppKit
import Flow42Core
import SwiftUI

struct FlowsListView: View {
    let project: Flow42Project
    /// Which collection(s) to render. `.all` shows two sections (flows
    /// then drafts); `.flows` and `.drafts` scope the page to one
    /// collection. Driven by the sidebar's tree navigation.
    let filter: ProjectFilter
    @EnvironmentObject private var router: DetailRouter
    @StateObject private var repo: FlowsRepository

    @State private var startingRecording: Bool = false
    @State private var recordingError: String?

    /// Exactly three columns per row. Each tile expands evenly within
    /// the available width while the card itself enforces a 1:1 shape.
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: DT.s16, alignment: .top),
        GridItem(.flexible(), spacing: DT.s16, alignment: .top),
        GridItem(.flexible(), spacing: DT.s16, alignment: .top),
    ]

    init(project: Flow42Project, filter: ProjectFilter = .all) {
        self.project = project
        self.filter = filter
        _repo = StateObject(wrappedValue: FlowsRepository(flowsRoot: project.flowsRoot))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                    .padding(.horizontal, DT.s32)
                    .padding(.top, DT.s32)
                    .padding(.bottom, DT.s20)

                // Hairline below the header — solid magenta at low
                // opacity. Magenta is the dominant brand accent.
                DT.magenta.opacity(0.25)
                    .frame(height: 1)
                    .padding(.horizontal, DT.s32)

                if repo.flows.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    sections
                        .padding(.horizontal, DT.s32)
                        .padding(.top, DT.s24)
                        .padding(.bottom, DT.s32)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Vibrancy-aware content background — gives the page proper
        // material depth that complements the sidebar's `.sidebar`
        // material instead of fighting it with a flat color.
        .background(AppBackdrop())
        .navigationTitle("")
        // `navigationDestination` is registered on the NavigationStack
        // root in AppShell so deep-link pushes from outside this view
        // resolve too. We don't redeclare it here.
    }

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: DT.s16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: project.builtin ? "house.fill" : "folder.fill")
                        .font(.system(size: DT.f12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(projectPathLabel)
                        .font(.system(size: DT.f11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if filter != .all {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(filter == .flows ? "Flows" : "Drafts")
                            .font(.system(size: DT.f11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(pageTitle)
                    .font(.system(size: DT.f30, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            recordButton
        }
    }

    /// Page title swaps to the section name when the filter scopes to
    /// one collection — keeps the header focused on the user's intent
    /// (they navigated specifically to "Flows" or "Drafts" of <project>).
    private var pageTitle: String {
        switch filter {
        case .all: return project.name
        case .flows: return "Flows"
        case .drafts: return "Drafts"
        }
    }

    private var projectPathLabel: String {
        (project.path as NSString).abbreviatingWithTildeInPath
    }

    private var subtitle: String {
        let f = structuredFlows.count
        let d = draftFlows.count
        switch filter {
        case .all:
            if f == 0 && d == 0 { return "No flows recorded yet" }
            return "\(plural(f, "flow", "flows")) · \(plural(d, "draft", "drafts"))"
        case .flows:
            return f == 0 ? "No structured flows yet" : plural(f, "flow", "flows")
        case .drafts:
            return d == 0 ? "No drafts waiting" : plural(d, "draft", "drafts")
        }
    }

    private func plural(_ n: Int, _ singular: String, _ plural: String) -> String {
        n == 1 ? "1 \(singular)" : "\(n) \(plural)"
    }

    /// Structured flows only — those with a `flow.yaml`.
    private var structuredFlows: [FlowSummary] {
        repo.flows.filter { $0.state == .structured }
    }

    /// Drafts — recordings without a `flow.yaml`.
    private var draftFlows: [FlowSummary] {
        repo.flows.filter { $0.state == .unstructured }
    }

    /// Record button — solid magenta. Magenta is the canonical brand
    /// color for recording across the whole app (edge glow, floating
    /// panel, status overlays); the button matches. Click spawns
    /// `flow42 record start` exactly the same way the menu-bar app's
    /// "New recording" flow does, so the daemon, edge glow, and state
    /// transitions are identical regardless of which surface kicked
    /// it off.
    private var recordButton: some View {
        Button(action: startRecording) {
            HStack(spacing: 6) {
                if startingRecording {
                    // Inherits the button's magenta tint from
                    // `.glassProminentCapsule` — no explicit color
                    // override.
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: DT.f13, weight: .semibold))
                }
                Text(startingRecording ? "Starting…" : "Record")
                    .font(.system(size: DT.f13, weight: .semibold))
            }
        }
        .glassProminentCapsule(tint: DT.magenta)
        .disabled(startingRecording)
        .help("Record a new flow (⌘R)")
        .keyboardShortcut("r", modifiers: [.command])
        .alert(
            "Could not start recording",
            isPresented: .constant(recordingError != nil),
            actions: {
                Button("OK") { recordingError = nil }
            },
            message: { Text(recordingError ?? "") }
        )
    }

    private func startRecording() {
        guard !startingRecording else { return }
        startingRecording = true
        Task { @MainActor in
            // Same arg shape as Flow42Menu's startRecording — keeps the
            // recorder daemon path identical regardless of which surface
            // launched it. Description is empty here; the user can edit
            // the recording's flow.yaml afterwards.
            // --force: pressing the Record button is the user's
                // "replace whatever's there" intent. Stale recorder
                // daemons or play markers shouldn't block a fresh start.
            let result = await CLIRunner.runAsync(
                ["record", "start", "--force"], timeout: 15
            )
            startingRecording = false
            if let result, (result["success"] as? Bool) == true {
                // The state.json watcher will pick up the new recording
                // and the menu app's edge glow will engage automatically.
                // Nothing more to do here — the recording lives in the
                // CLI/menu surface for the duration of capture.
                return
            }
            let err = (result?["error"] as? String) ?? "could not start recording. Make sure the flow42 CLI is on your PATH or bundled."
            recordingError = err
        }
    }

    // MARK: - Sections

    /// Two collections rendered as separate labelled grids. Order is
    /// always Flows-on-top, Drafts-below, regardless of recording
    /// timestamps; the visual hierarchy tells the user "polished
    /// flows first, drafts waiting for processing below". Filter
    /// trims whichever section is out of scope for the current
    /// destination.
    @ViewBuilder
    private var sections: some View {
        VStack(alignment: .leading, spacing: DT.s32) {
            if filter != .drafts && !structuredFlows.isEmpty {
                section(
                    title: "Flows",
                    subtitle: plural(structuredFlows.count, "structured flow", "structured flows"),
                    items: structuredFlows,
                    accessory: nil
                )
            }
            if filter != .flows && !draftFlows.isEmpty {
                section(
                    title: "Drafts",
                    subtitle: plural(draftFlows.count, "recording awaiting structure", "recordings awaiting structure"),
                    items: draftFlows,
                    accessory: AnyView(deleteAllDraftsButton)
                )
            }
            // Friendly empty state when the filter scope is empty but
            // the project has content in the other section.
            if filter == .flows && structuredFlows.isEmpty {
                filterEmptyState(
                    icon: "rectangle.stack",
                    title: "No structured flows yet",
                    body: "Recordings need to be processed before they show up here. Check the Drafts list to structure one."
                )
            }
            if filter == .drafts && draftFlows.isEmpty {
                filterEmptyState(
                    icon: "waveform.path.badge.plus",
                    title: "No drafts waiting",
                    body: "Drafts appear here right after you stop a recording. Hit Record above to capture a new one."
                )
            }
        }
    }

    private func section(
        title: String, subtitle: String,
        items: [FlowSummary], accessory: AnyView?
    ) -> some View {
        VStack(alignment: .leading, spacing: DT.s16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: DT.f10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.system(size: DT.f12))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: DT.s8)
                if let accessory { accessory }
            }
            grid(items: items)
        }
    }

    /// "Delete all" pill that lives in the Drafts section header. Trashes
    /// every unstructured flow after a confirmation NSAlert — Trashing
    /// rather than rm-rf'ing means the user can recover from a misclick
    /// via the Finder.
    private var deleteAllDraftsButton: some View {
        Button(role: .destructive, action: confirmDeleteAllDrafts) {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: DT.f11, weight: .medium))
                Text("Delete all drafts")
                    .font(.system(size: DT.f12, weight: .medium))
            }
            .padding(.horizontal, DT.s8)
            .padding(.vertical, 4)
            .foregroundStyle(DT.red)
        }
        .buttonStyle(.plain)
        .help("Move every draft in this space to the Trash")
    }

    private func confirmDeleteAllDrafts() {
        let n = draftFlows.count
        guard n > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(n) draft\(n == 1 ? "" : "s")?"
        alert.informativeText = "Drafts will be moved to the Trash. You can recover them from there if needed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            repo.deleteAllDrafts()
        }
    }

    fileprivate func confirmDeleteDraft(_ summary: FlowSummary) {
        let alert = NSAlert()
        alert.messageText = "Delete \(summary.displayName)?"
        alert.informativeText = "The recording directory will be moved to the Trash. You can recover it from there if needed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            repo.deleteFlow(summary)
        }
    }

    private func grid(items: [FlowSummary]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: DT.s16) {
            ForEach(items) { summary in
                Button {
                    if summary.state == .unstructured {
                        router.push(.recordingHandoff(RecordingHandoff(
                            dir: summary.directory,
                            slug: summary.id
                        )))
                    } else {
                        router.push(.flow(summary))
                    }
                } label: {
                    FlowCard(summary: summary)
                }
                .buttonStyle(.plain)
                .contextMenu { cardContextMenu(for: summary) }
            }
        }
    }

    /// Right-click menu shared by every card. Drafts get a Delete
    /// option (Trashes the recording dir) — structured flows don't,
    /// since deleting a long-lived flow is a heavier decision than
    /// can fit in a context menu.
    @ViewBuilder
    private func cardContextMenu(for summary: FlowSummary) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: summary.directory)]
            )
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        if summary.state == .unstructured {
            Divider()
            Button(role: .destructive) {
                confirmDeleteDraft(summary)
            } label: {
                Label("Delete draft…", systemImage: "trash")
            }
        }
    }

    private func filterEmptyState(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: DT.s12) {
            Image(systemName: icon)
                .font(.system(size: DT.f17, weight: .light))
                .foregroundStyle(DT.magenta.opacity(0.7))
                .frame(width: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: DT.f13, weight: .semibold))
                Text(body)
                    .font(.system(size: DT.f12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DT.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DT.s16) {
            // Solid magenta disc behind the glyph — the dominant brand
            // mark. The "no flows yet" empty state is a great place to
            // anchor brand presence.
            ZStack {
                Circle()
                    .fill(DT.magenta.opacity(0.12))
                    .frame(width: 110, height: 110)
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DT.magenta)
            }
            VStack(spacing: 6) {
                Text("No flows in the \(project.name) space yet")
                    .font(.system(size: DT.f17, weight: .semibold))
                Text("Record your first flow with `flow42 record start` — the recording shows up here when you stop it.")
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button("Reveal flows folder in Finder") {
                try? FileManager.default.createDirectory(
                    atPath: project.flowsRoot,
                    withIntermediateDirectories: true
                )
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: project.flowsRoot)]
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, DT.s8)
        }
        .padding(.horizontal, DT.s40)
        .padding(.vertical, DT.s40)
    }
}

// MARK: - Card

/// Square card with a screenshot on top and a dedicated content band at
/// the bottom. The image fills its region and crops only inside the
/// rounded tile.
private struct FlowCard: View {
    let summary: FlowSummary
    @State private var hovered: Bool = false
    private let contentHeight: CGFloat = 104

    var body: some View {
        GeometryReader { proxy in
            let imageHeight = max(0, proxy.size.height - contentHeight)

            VStack(alignment: .leading, spacing: 0) {
                heroImage
                    .frame(maxWidth: .infinity)
                    .frame(height: imageHeight)

                textBlock
                    .frame(height: contentHeight)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // Solid card surface on purpose — this view shows up in a
        // grid of 20+ tiles and `.glassEffect()` on each one made
        // scrolling jank under the compositor. Glass stays on the
        // top-level page cards (overview / events / runs) where the
        // count is small.
        .background(
            RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous)
                .fill(DT.surface)
        )
        .overlay(
            // Unstructured recordings get a dashed magenta border to
            // signal "draft — needs structuring". Structured flows
            // get a quiet hairline that pops magenta on hover.
            Group {
                if summary.state == .unstructured {
                    RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous)
                        .strokeBorder(
                            DT.magenta.opacity(hovered ? 0.85 : 0.55),
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                        )
                } else {
                    RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous)
                        .strokeBorder(
                            hovered ? DT.magenta.opacity(0.45) : .primary.opacity(0.06),
                            lineWidth: hovered ? 1 : 0.5
                        )
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous))
        .shadow(
            color: hovered ? DT.magenta.opacity(0.25) : .black.opacity(0.06),
            radius: hovered ? 16 : 6,
            x: 0,
            y: hovered ? 8 : 3
        )
        .scaleEffect(hovered ? 1.01 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(DT.aHover, value: hovered)
    }

    // MARK: - Hero image

    @ViewBuilder
    private var heroImage: some View {
        ZStack(alignment: .topTrailing) {
            // The screenshot fills the full square tile. Overspill from
            // non-square assets is clipped by the card mask so only the
            // edges crop.
            if let path = summary.heroThumbnailPath,
               let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    // Unstructured recordings render slightly desaturated
                    // so the eye reads them as "still raw" without the
                    // image being unrecognisable.
                    .saturation(summary.state == .unstructured ? 0.35 : 1.0)
                    .opacity(summary.state == .unstructured ? 0.78 : 1.0)
            } else {
                // No screenshot: solid magenta-tinted placeholder.
                DT.magenta.opacity(0.18)
                    .overlay(
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(DT.magenta.opacity(0.7))
                    )
            }

            // Top-right corner pill differs by state — phase count for
            // structured flows, a "DRAFT" indicator for unstructured
            // recordings. Inset enough from the rounded corner so the
            // pill doesn't get clipped by the card's clip-shape mask.
            if summary.state == .unstructured {
                draftBadge.padding(DT.s12)
            } else {
                phaseBadge.padding(DT.s12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var phaseBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "list.number")
                .font(.system(size: 9, weight: .semibold))
            Text("\(summary.phaseCount)")
                .font(.system(size: DT.f11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassPillSurface()
    }

    /// "Draft" indicator for unstructured recordings. Magenta-tinted
    /// Liquid Glass so the brand colour pulls the eye AND the pill
    /// reads as a real material rather than a flat fill — one per
    /// draft card in the grid, so the cost is bounded by how many
    /// drafts the user has, which is small in practice.
    private var draftBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.badge.plus")
                .font(.system(size: 9, weight: .semibold))
            Text("DRAFT")
                .font(.system(size: DT.f10, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassShowcasePillSurface(tint: DT.magenta)
    }

    // MARK: - Text block

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.displayName)
                .font(.system(size: DT.f14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let task = summary.taskDescription, !task.isEmpty {
                Text(task)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                    .lineLimit(2)
            }

            metaRow
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DT.surface.opacity(0.96))
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let dur = summary.durationSeconds {
                metaPill(symbol: "stopwatch", text: "\(dur)s")
            }
            if let date = summary.recordedAt {
                metaPill(symbol: "clock", text: friendlyDate(date))
            }
            if summary.state == .unstructured {
                metaPill(symbol: "sparkles", text: "Process")
                    .foregroundStyle(DT.magenta)
            }
            Spacer(minLength: 0)
        }
    }

    private func metaPill(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: DT.f11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .glassPillSurface()
    }

    private func friendlyDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Native vibrancy background

/// Wraps `NSVisualEffectView` so SwiftUI views can use proper macOS
/// materials as backgrounds. Defaults to `.contentBackground` — the
/// material macOS uses for the main content area of split-view apps
/// (Mail, Notes, Calendar). The sidebar uses `.sidebar` for contrast.
struct NativeBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// App-wide content backdrop. Pulls from `DT.backdrop` (Flow42Core)
/// so the SAME color paints the page in both Flow42App AND
/// Flow42Core's chat. Adaptive: near-black in dark mode, off-white
/// in light mode.
struct AppBackdrop: View {
    var body: some View {
        DT.backdrop.ignoresSafeArea()
    }
}
