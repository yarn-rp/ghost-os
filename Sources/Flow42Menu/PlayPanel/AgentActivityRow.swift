// AgentActivityRow.swift - The compact "what is the agent doing right
// now?" bubble that lives between the step caption and the transport
// bar in PlayPanelView.
//
// Renders ONE TranscriptEvent — the latest one — with a kind-specific
// icon + tint + body. Click → flip the parent panel into chat mode
// (see PlayPanelView.swift's `showingChat` state).
//
// Designed for skim-reading: max ~3 lines, monospace for tool calls,
// ellipsis truncation. The user is supposed to glance and trust; the
// chat-mode swap is for when they want the full story.

import Flow42Core
import SwiftUI

struct AgentActivityRow: View {
    let event: TranscriptEvent
    let onOpenChat: () -> Void

    var body: some View {
        Button(action: onOpenChat) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(roleLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(accent)
                    Text(bodyText)
                        .font(useMonospace
                              ? .system(size: 11, design: .monospaced)
                              : .system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                // Subtle chevron so the affordance reads. Not too loud
                // — the bubble itself is clickable, the chevron just
                // tells you where the click lands.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Tap to open the full conversation")
        .id(event.id) // animate when the latest event changes
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Variants per kind

    /// Per-kind tokens. Returned from a single switch so the visual
    /// language stays in one place (vs scattered across icon/accent/role
    /// computed properties).
    private struct Tokens {
        let icon: String
        let role: String
        let accent: Color
        let mono: Bool
    }

    private var tokens: Tokens {
        switch event.kind {
        case .assistantText:
            return Tokens(icon: "sparkles", role: "Claude",
                          accent: PanelTokens.orange, mono: false)
        case .toolCall:
            return Tokens(icon: "wrench.and.screwdriver",
                          role: "Tool call",
                          accent: Color(red: 0xB0/255, green: 0x6F/255, blue: 0xFF/255),
                          mono: true)
        case .toolResult(_, let isError):
            return Tokens(icon: isError ? "xmark.octagon" : "checkmark.circle",
                          role: isError ? "Tool error" : "Tool result",
                          accent: isError
                            ? Color(red: 0xFF/255, green: 0x5C/255, blue: 0x5C/255)
                            : Color(red: 0x36/255, green: 0xC8/255, blue: 0x5B/255),
                          mono: false)
        case .userMessage:
            return Tokens(icon: "person.fill", role: "You",
                          accent: PanelTokens.blue, mono: false)
        case .systemInfo:
            return Tokens(icon: "info.circle", role: "Session",
                          accent: .secondary, mono: false)
        case .finalResult:
            return Tokens(icon: "flag.checkered", role: "Done",
                          accent: Color(red: 0x36/255, green: 0xC8/255, blue: 0x5B/255),
                          mono: false)
        case .error:
            return Tokens(icon: "exclamationmark.triangle.fill",
                          role: "Error",
                          accent: Color(red: 0xFF/255, green: 0x5C/255, blue: 0x5C/255),
                          mono: false)
        case .raw:
            return Tokens(icon: "ellipsis.bubble", role: "Note",
                          accent: .secondary, mono: false)
        }
    }

    private var icon: String { tokens.icon }
    private var roleLabel: String { tokens.role }
    private var accent: Color { tokens.accent }
    private var useMonospace: Bool { tokens.mono }

    // MARK: - Body text per kind

    private var bodyText: String {
        switch event.kind {
        case .assistantText(let text):
            return collapse(text)
        case .toolCall(_, let summary):
            return collapse(summary)
        case .toolResult(let summary, _):
            return collapse(summary)
        case .userMessage(let text):
            return collapse(text)
        case .systemInfo(let text):
            return collapse(text)
        case .finalResult(let text, let durationMs, let costUSD):
            var bits: [String] = []
            if !text.isEmpty { bits.append(text) }
            if let d = durationMs { bits.append("\(d / 1000)s") }
            if let c = costUSD { bits.append(String(format: "$%.4f", c)) }
            return collapse(bits.joined(separator: " · "))
        case .error(let text):
            return collapse(text)
        case .raw(let text):
            return collapse(text)
        }
    }

    /// Whitespace cleanup — agent output often has leading newlines or
    /// indent. Bubble layout assumes one logical line so it doesn't
    /// stretch the panel vertically.
    private func collapse(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .split(separator: "\n", omittingEmptySubsequences: true)
         .joined(separator: " ")
    }
}
