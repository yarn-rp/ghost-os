// FlowParamsCard.swift - Notion-style "what this flow needs from you"
// section.
//
// Reads as documentation, not as a card with stats. One light-tinted
// callout per param with a quiet vertical accent bar. Body sentence
// reads like a tutorial line ("`song_query` is the song you want to
// play. For example, `la flaca`.").
//
// When there are no params, we say so in plain English instead of
// rendering an empty box.

import Flow42Core
import SwiftUI

struct FlowParamsCard: View {
    let flow: PhaseReader.Flow

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Before you run it")
                    .font(.system(size: DT.f17, weight: .semibold))
                Text(introCopy)
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !flow.params.isEmpty {
                VStack(spacing: DT.s8) {
                    ForEach(Array(flow.params.enumerated()), id: \.offset) { _, param in
                        ParamCallout(param: param)
                    }
                }
                .padding(.top, DT.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var introCopy: String {
        if flow.params.isEmpty {
            return "This flow runs without any input — just hit \"Run autonomously\" above and the agent will take it from there."
        }
        let count = flow.params.count
        let what = count == 1 ? "one detail" : "\(count) details"
        return "The flow needs \(what) from you before it can run. The agent will ask in chat once you start, but you can preview them here."
    }
}

// MARK: - One param's callout

private struct ParamCallout: View {
    let param: (name: String, description: String, type: String, example: String)

    var body: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            // Neutral vertical bar — keeps the Notion-callout shape
            // without claiming brand accent. Detail page is now
            // CTA-only for accent colours.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.primary.opacity(0.18))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(param.name)
                        .font(.system(size: DT.f13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    typePill(param.type)
                    Spacer(minLength: 0)
                }
                Text(.init(prose))
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(DT.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Stitches description + example into one tutorial-style sentence.
    /// Markdown-aware so backticks render as inline code.
    private var prose: String {
        var bits: [String] = []
        let trimmed = param.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            bits.append(trimmed)
        } else {
            bits.append("Used by the flow at runtime.")
        }
        if !param.example.isEmpty {
            bits.append("For example, `\(param.example)`.")
        }
        return bits.joined(separator: " ")
    }

    private func typePill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DT.f10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.primary.opacity(0.06)))
    }
}
