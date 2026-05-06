// GuideMeWindow.swift - The standalone walkthrough window for Guide-me
// mode. Opens when the user clicks "Guide me" on a flow detail page.
//
// Big screenshot, step text, Prev / Next / Stop. Bottom-right of the
// active screen, sized comfortably for reading. Subscribes to StateClient
// so the displayed step updates instantly when the user uses the
// floating panel's transport buttons OR our Prev/Next.
//
// Closes itself when the play ends (state goes idle).

import AppKit
import Combine
import Flow42Core
import SwiftUI
import Yams

@MainActor
final class GuideMeWindow {

    private var window: NSWindow?
    private var subscription: AnyCancellable?
    private let runner = GuideMeRunner()
    private let stateClient = StateClient()

    static let shared = GuideMeWindow()

    /// Open the walkthrough for `flow`. Starts the play, then shows the
    /// window. Throws on launch failure (caller surfaces to the user).
    func open(flow: FlowSummary) throws {
        try runner.start(flow: flow)

        // Build the window if it doesn't already exist.
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Guide me"
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = false
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }

        // Re-host content each time so the bound flow is fresh.
        let view = GuideMeView(
            flow: flow,
            runner: runner,
            stateClient: stateClient,
            onClose: { [weak self] in self?.close() }
        )
        window?.contentView = NSHostingView(rootView: view)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Auto-close when the play ends underneath us.
        subscription = stateClient.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if state.play == nil {
                    self?.close()
                }
            }
    }

    func close() {
        subscription?.cancel()
        subscription = nil
        window?.orderOut(nil)
    }
}

// MARK: - View

private struct GuideMeView: View {
    let flow: FlowSummary
    let runner: GuideMeRunner
    @ObservedObject var stateClient: StateClient
    let onClose: () -> Void

    private var play: PlayInfo? { stateClient.state.play }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
            }

            Divider()

            transport
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GUIDE ME")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(flow.displayName)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if let resolved = currentStep {
            VStack(alignment: .leading, spacing: 16) {
                phaseChip(resolved.phaseName, phaseIndex: resolved.phaseIndex, total: resolved.totalPhases)
                stepHeading(stepIndex: resolved.stepIndex, total: resolved.totalStepsInPhase)
                if !resolved.stepText.isEmpty {
                    Text(resolved.stepText)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let img = resolved.screenshot {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                }
            }
        } else {
            ProgressView("Loading step…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        }
    }

    private func phaseChip(_ name: String, phaseIndex: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            Text("Phase \(phaseIndex + 1) of \(total)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(name.replacingOccurrences(of: "_", with: " "))
                .font(.system(size: 13, weight: .medium))
        }
    }

    private func stepHeading(stepIndex: Int, total: Int) -> some View {
        Text("Step \(stepIndex + 1) of \(total)")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 16) {
            Button {
                _ = runner.prevStep()
            } label: {
                Label("Previous", systemImage: "backward.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!canGoPrev)

            Spacer()

            Button {
                onClose()
                _ = runner.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()

            Button {
                _ = runner.nextStep()
            } label: {
                Label("Next", systemImage: "forward.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(play == nil)
        }
    }

    private var canGoPrev: Bool {
        guard let pos = play?.position else { return false }
        return !(pos.phaseIndex == 0 && pos.stepIndex == 0)
    }

    // MARK: - Resolve current step

    private struct Resolved {
        let phaseIndex: Int
        let phaseName: String
        let stepIndex: Int
        let totalPhases: Int
        let totalStepsInPhase: Int
        let stepText: String
        let screenshot: NSImage?
    }

    private var currentStep: Resolved? {
        guard let play else { return nil }
        // Pull the phase + step text + screenshot from flow.yaml. We
        // re-read here rather than caching because flow.yaml changes are
        // rare and re-read cost is negligible at human-tick rate.
        let phase = readPhase(at: play.position.phaseIndex, in: play.flowDir)
        let stepData = readStep(phase: phase, at: play.position.stepIndex)
        let screenshot = stepData.screenshotPath.flatMap { rel -> NSImage? in
            let abs = (play.flowDir as NSString).appendingPathComponent(rel)
            return NSImage(contentsOfFile: abs)
        }
        return Resolved(
            phaseIndex: play.position.phaseIndex,
            phaseName: play.position.phaseName,
            stepIndex: play.position.stepIndex,
            totalPhases: play.position.totalPhases,
            totalStepsInPhase: play.position.totalStepsInPhase,
            stepText: stepData.text,
            screenshot: screenshot
        )
    }

    private func readPhase(at index: Int, in dir: String) -> [String: Any]? {
        let yamlPath = (dir as NSString).appendingPathComponent("flow.yaml")
        guard let data = try? String(contentsOfFile: yamlPath, encoding: .utf8),
              let parsed = try? Yams.load(yaml: data) as? [String: Any],
              let phases = parsed["phases"] as? [[String: Any]],
              index >= 0, index < phases.count else { return nil }
        return phases[index]
    }

    private func readStep(phase: [String: Any]?, at index: Int) -> (text: String, screenshotPath: String?) {
        guard let phase,
              let paths = phase["paths"] as? [[String: Any]],
              let gui = paths.first(where: { ($0["kind"] as? String) == "gui" }),
              let steps = gui["steps"] as? [[String: Any]],
              index >= 0, index < steps.count else {
            return ("", nil)
        }
        let step = steps[index]
        let text = (step["text"] as? String) ?? ""
        let shot = (step["screenshot"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (text, shot)
    }
}

