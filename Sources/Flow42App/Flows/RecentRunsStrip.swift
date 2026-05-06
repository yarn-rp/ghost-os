// RecentRunsStrip.swift - Bottom-of-FlowDetailView block listing the
// last N plays. Each row shows the run's status glyph, relative time,
// and a small detail line (started_by · duration · stop reason).
//
// Empty state is a single quiet line ("Hasn't been run yet") instead
// of a full empty-state component — keeps the page from over-rotating
// on absent data.

import Flow42Core
import SwiftUI

struct RecentRunsStrip: View {
    let runs: [PlayHistoryEntry]

    @State private var selectedRunId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Recent runs")
                Spacer()
                if !runs.isEmpty {
                    Text("\(runs.count)")
                        .font(.system(size: DT.f10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardSurface()
    }

    @ViewBuilder
    private var content: some View {
        if runs.isEmpty {
            Text("Hasn't been run yet — be the first.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .padding(.vertical, DT.s4)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.element.id) { idx, run in
                    VStack(spacing: 0) {
                        runRow(run)
                        if selectedRunId == run.id {
                            RunStepsView(run: run)
                                .padding(.top, DT.s8)
                                .padding(.bottom, DT.s12)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    if idx < runs.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func runRow(_ run: PlayHistoryEntry) -> some View {
        let isOpen = selectedRunId == run.id
        return HStack(spacing: DT.s12) {
            statusGlyph(for: run)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(relativeTimeLabel(run))
                        .font(.system(size: DT.f12, weight: .medium))
                        .foregroundStyle(.primary)
                    if let by = run.startedBy {
                        Text("·")
                            .font(.system(size: DT.f11))
                            .foregroundStyle(.tertiary)
                        Text(by)
                            .font(.system(size: DT.f11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detailLine(run))
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .animation(DT.aMode, value: isOpen)
        }
        .padding(.vertical, DT.s8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DT.aMode) {
                selectedRunId = isOpen ? nil : run.id
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: run.directory)]
                )
            }
        }
    }

    private func statusGlyph(for run: PlayHistoryEntry) -> some View {
        let (symbol, color): (String, Color) = {
            switch run.exitReason {
            case .completed:    return ("checkmark.circle.fill", DT.green)
            case .userStopped, .agentStopped:
                                return ("stop.circle.fill", DT.amber)
            case .crashed:      return ("xmark.octagon.fill", DT.red)
            case .unknown,
                 .none:         return ("circle.dotted", DT.cyan)
            }
        }()
        return Image(systemName: symbol)
            .font(.system(size: DT.f13, weight: .medium))
            .foregroundStyle(color)
    }

    private func relativeTimeLabel(_ run: PlayHistoryEntry) -> String {
        guard let started = run.startedAt else { return run.id }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return rel.localizedString(for: started, relativeTo: Date())
    }

    private func detailLine(_ run: PlayHistoryEntry) -> String {
        var bits: [String] = []
        if let dur = run.duration {
            bits.append("\(Int(dur.rounded()))s")
        }
        if let reason = run.exitReason {
            bits.append(reason.rawValue.replacingOccurrences(of: "_", with: " "))
        } else if run.endedAt == nil {
            bits.append("in flight")
        }
        if let label = run.label, !label.isEmpty {
            bits.append("\"\(label)\"")
        }
        return bits.joined(separator: " · ")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: DT.f10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}
