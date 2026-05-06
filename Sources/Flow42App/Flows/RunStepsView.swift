// RunStepsView.swift - Per-step thumbnails for one past play.
//
// Surfaces the screenshots the executor wrote into
// `<play-dir>/steps/NNNN/{screenshot.jpg, annotated.jpg}` so the user can
// scrub through what the agent saw and where it acted at each step. Empty
// state (the play predates the screenshot-per-step feature) is a single
// quiet line — we don't render an empty card.

import AppKit
import Flow42Core
import SwiftUI

struct RunStepsView: View {
    let run: PlayHistoryEntry

    @State private var steps: [PlayHistoryEntry.Step] = []
    @State private var loading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            if loading {
                loadingState
            } else if steps.isEmpty {
                emptyState
            } else {
                stepsList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 30)  // align under the run row's status glyph
        .task(id: run.id) {
            await load()
        }
    }

    // MARK: - States

    private var loadingState: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading steps…")
                .font(.system(size: DT.f11))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        Text("This run has no per-step screenshots.")
            .font(.system(size: DT.f11))
            .foregroundStyle(.tertiary)
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            ForEach(steps) { step in
                StepThumbRow(step: step)
            }
        }
    }

    private func load() async {
        loading = true
        let dir = run.directory
        let id = run.id
        let result = await Task.detached(priority: .userInitiated) {
            // Re-construct an entry with just the directory we need so we
            // can call steps() off-actor; the constructor is cheap.
            PlayHistoryEntry(
                id: id, directory: dir,
                exitReason: nil, startedBy: nil, label: nil, state: nil,
                startedAt: nil, endedAt: nil
            ).steps()
        }.value
        self.steps = result
        self.loading = false
    }
}

// MARK: - Per-step row

private struct StepThumbRow: View {
    let step: PlayHistoryEntry.Step

    var body: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            stepIndex
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text("Step \(step.id.trimmingCharacters(in: CharacterSet(charactersIn: "0")) .ifEmpty(step.id))")
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(detailLine)
                    .font(.system(size: DT.f10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var stepIndex: some View {
        Text(step.id)
            .font(.system(size: DT.f9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 32, alignment: .trailing)
            .padding(.top, 30)  // align with thumbnail center-ish
    }

    @ViewBuilder
    private var thumbnail: some View {
        let path = step.annotatedScreenshotPath ?? step.screenshotPath
        if let path, let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 200, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
        } else {
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .fill(.primary.opacity(0.04))
                .frame(width: 200, height: 120)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.tertiary)
                )
        }
    }

    private var detailLine: String {
        if step.annotatedScreenshotPath != nil { return "Click target marked" }
        if step.screenshotPath != nil { return "Pre-action capture" }
        return "No screenshot"
    }
}

private extension String {
    /// Returns `fallback` when self is empty, else self. Used for the
    /// "Step 1" label so we strip leading zeros without ending up with "".
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
