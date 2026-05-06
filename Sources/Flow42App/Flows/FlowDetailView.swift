// FlowDetailView.swift - The Medium-style detail page for one flow.
//
// Composition (top to bottom):
//   FlowHero           — cinematic blurred-screenshot banner with title + CTAs
//   At-a-glance row    — stats card (left) + params card (right)
//   Phases             — one PhaseCard per phase, each with PathSelector
//   Recent runs strip  — last N plays from PlayHistoryReader
//   Footer             — small action links (Reveal in Finder, Open flow.yaml)
//
// FlowDetailView itself is thin: it loads the parsed flow + play
// history once, owns the AutonomousRunner + ProviderConfigStore for
// the CTAs, and composes the children. Each section is its own
// component.

import AppKit
import Flow42Core
import SwiftUI

struct FlowDetailView: View {
    let flow: FlowSummary

    @StateObject private var providerStore = ProviderConfigStore()
    @StateObject private var autonomousRunner = AutonomousRunner()

    @State private var loadedFlow: PhaseReader.Flow?
    @State private var loadError: String?
    @State private var playHistory: [PlayHistoryEntry] = []

    var body: some View {
        ScrollView {
            content
        }
        .background(AppBackdrop())
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: flow.directory)]
                    )
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
        .task(id: flow.id) {
            await load()
        }
    }

    // MARK: - Composed body

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorState(err)
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(DT.s32)
        } else if let parsed = loadedFlow {
            VStack(spacing: 0) {
                FlowHero(
                    flow: parsed,
                    summary: flow,
                    runCount: playHistory.count,
                    onRunAutonomously: runAutonomously,
                    onGuideMe: guideMe
                )
                pageBody(parsed)
                    .frame(maxWidth: 880)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DT.s32)
                    .padding(.vertical, DT.s32)
            }
        } else {
            loadingState
                .frame(height: 360)
        }
    }

    @ViewBuilder
    private func pageBody(_ parsed: PhaseReader.Flow) -> some View {
        VStack(alignment: .leading, spacing: DT.s40) {
            FlowParamsCard(flow: parsed)
            phaseList(parsed)
            RecentRunsStrip(runs: playHistory)
            footer
        }
    }

    private func phaseList(_ parsed: PhaseReader.Flow) -> some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            Text("How it runs")
                .font(.system(size: DT.f17, weight: .semibold))
            Text("Each phase below is one chunk of work. The agent does them in order; if a phase has alternative paths (e.g. a shell command that does the same thing) you'll see them as tabs.")
                .font(.system(size: DT.f13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, DT.s8)
            VStack(alignment: .leading, spacing: DT.s40) {
                ForEach(Array(parsed.phases.enumerated()), id: \.offset) { idx, phase in
                    PhaseCard(
                        phaseIndex: idx,
                        phase: phase,
                        flowDir: flow.directory
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DT.s16) {
            footerLink("Reveal in Finder", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: flow.directory)]
                )
            }
            footerLink("Open flow.yaml", icon: "doc.text") {
                let yaml = (flow.directory as NSString).appendingPathComponent("flow.yaml")
                NSWorkspace.shared.open(URL(fileURLWithPath: yaml))
            }
            Spacer()
        }
        .padding(.top, DT.s8)
    }

    private func footerLink(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(label).font(.system(size: DT.f11, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading / error

    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(DT.amber)
            Text("Couldn't render this flow")
                .font(.system(size: DT.f17, weight: .semibold))
            Text(message)
                .font(.system(size: DT.f12, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: flow.directory)]
                )
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Load

    private func load() async {
        let dir = flow.directory
        // PhaseReader is main-actor isolated (its `Phase.paths` carries
        // `Any` which can't cross actor boundaries). flow.yaml is
        // small + parses fast, so calling it directly on the main
        // actor is fine — this is a once-on-page-appear cost.
        do {
            loadedFlow = try PhaseReader.load(flowDir: dir)
            loadError = nil
        } catch {
            loadedFlow = nil
            loadError = "\(error)"
        }
        // PlayHistoryReader is `nonisolated`; safe to detach.
        let history = await Task.detached(priority: .userInitiated) {
            PlayHistoryReader.read(flowDir: dir, limit: 6)
        }.value
        self.playHistory = history
    }

    // MARK: - CTAs

    private func runAutonomously() {
        do {
            // Spawn the agent + create a per-(flow, provider) chat
            // session. The runner writes an `active-chat-session.json`
            // marker; Flow42Menu's PlayPanelController watches it and
            // hosts the chat in the SAME floating window that already
            // shows recording / driving / watching state. One floating
            // surface, one mental model.
            try autonomousRunner.start(
                flow: flow,
                provider: providerStore.selected
            )
        } catch {
            presentError(title: "Couldn't start the run", error: error)
        }
    }

    private func guideMe() {
        do {
            try GuideMeWindow.shared.open(flow: flow)
        } catch {
            presentError(title: "Couldn't start guided mode", error: error)
        }
    }

    private func presentError(title: String, error: any Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
