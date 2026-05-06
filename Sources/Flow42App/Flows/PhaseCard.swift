// PhaseCard.swift - Notion-tutorial-style phase block.
//
// No bordered box, no drop shadow. Just typography + a magenta
// numbered badge in the gutter, like a Notion documentation page.
// Each phase reads as a tutorial section with a clear heading,
// intent paragraph, optional path-selector pill row, and the body
// (numbered steps with screenshots OR a copyable command block for
// headless paths).

import Flow42Core
import SwiftUI

struct PhaseCard: View {
    let phaseIndex: Int
    let phase: PhaseReader.Phase
    let flowDir: String

    @State private var selectedPathIndex: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            heading
            if !phase.intent.isEmpty {
                Text(phase.intent)
                    .font(.system(size: DT.f15))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, DT.s4)
            }
            if phase.paths.count > 1 {
                PathSelector(
                    paths: phase.paths,
                    selectedIndex: $selectedPathIndex
                )
                .padding(.bottom, DT.s4)
            }
            pathBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Heading

    private var heading: some View {
        HStack(alignment: .center, spacing: DT.s12) {
            phaseBadge
            Text(displayName(phase.name))
                .font(.system(size: DT.f22, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phaseBadge: some View {
        Text("\(phaseIndex + 1)")
            .font(.system(size: DT.f13, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(.primary.opacity(0.08)))
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func displayName(_ snake: String) -> String {
        snake.split(separator: "_").map { word -> String in
            guard let first = word.first else { return String(word) }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - Path body

    @ViewBuilder
    private var pathBody: some View {
        let safeIndex = min(selectedPathIndex, max(0, phase.paths.count - 1))
        if phase.paths.isEmpty {
            Text("This phase has no paths recorded.")
                .font(.system(size: DT.f13))
                .foregroundStyle(.tertiary)
                .padding(.vertical, DT.s4)
        } else {
            let path = phase.paths[safeIndex]
            PathBody(path: path, flowDir: flowDir)
                .id(safeIndex)
                .transition(.opacity)
                .animation(DT.aMode, value: safeIndex)
        }
    }
}

// MARK: - Path body

private struct PathBody: View {
    let path: [String: Any]
    let flowDir: String

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s16) {
            if let desc = path["description"] as? String, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if (path["kind"] as? String) == "gui",
               let steps = path["steps"] as? [[String: Any]] {
                guiSteps(steps)
            } else if let command = path["command"] as? String, !command.isEmpty {
                commandBlock(command, kind: path["kind"] as? String ?? "shell")
            }
        }
    }

    // MARK: - GUI steps (Notion-style numbered list)

    private func guiSteps(_ steps: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: DT.s20) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                stepRow(index: idx, step: step)
            }
        }
    }

    private func stepRow(index: Int, step: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            HStack(alignment: .top, spacing: DT.s12) {
                stepBadge(index)
                if let text = step["text"] as? String {
                    Text(text)
                        .font(.system(size: DT.f14))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let shot = step["screenshot"] as? String, !shot.isEmpty {
                stepImage(shot)
                    .padding(.leading, 38) // align under step text gutter
            }
        }
    }

    private func stepBadge(_ index: Int) -> some View {
        Text("\(index + 1)")
            .font(.system(size: DT.f11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(.primary.opacity(0.06))
                    .overlay(
                        Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    )
            )
    }

    private func stepImage(_ relPath: String) -> some View {
        let abs = (flowDir as NSString).appendingPathComponent(relPath)
        let img = NSImage(contentsOfFile: abs)
        return Group {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 540)
                    .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            } else {
                RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                    .fill(.primary.opacity(0.04))
                    .frame(height: 100)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
    }

    // MARK: - Command block (shell / osascript / etc.)

    private func commandBlock(_ command: String, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(kind.uppercased())
                    .font(.system(size: DT.f9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc").font(.system(size: 9, weight: .semibold))
                        Text("Copy").font(.system(size: DT.f10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy command to clipboard")
            }
            .padding(.horizontal, DT.s12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(.system(size: DT.f12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(DT.s12)
                    .textSelection(.enabled)
            }
        }
        .glassCardSurface(cornerRadius: DT.rCard)
    }
}
