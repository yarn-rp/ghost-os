// PathSelector.swift - Segmented control across the available paths
// for one phase. Renders only when a phase has more than one path
// (typical: GUI + a headless alternative like shell or osascript).
//
// macOS-native segmented control would work too (Picker .segmented),
// but a custom version lets us tint the selected segment with the
// brand magenta + add per-segment icons that match the path kind.

import Flow42Core
import SwiftUI

struct PathSelector: View {
    let paths: [[String: Any]]
    @Binding var selectedIndex: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(paths.enumerated()), id: \.offset) { idx, path in
                segment(idx: idx, path: path)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                .fill(.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func segment(idx: Int, path: [String: Any]) -> some View {
        let kind = (path["kind"] as? String) ?? "alt"
        let isActive = selectedIndex == idx
        Button {
            withAnimation(DT.aMode) { selectedIndex = idx }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconFor(kind: kind))
                    .font(.system(size: 10, weight: .semibold))
                Text(labelFor(kind: kind))
                    .font(.system(size: DT.f11, weight: .semibold))
            }
            .padding(.horizontal, DT.s12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isActive ? Color.primary : .secondary)
            .modifier(PathSegmentBackground(isActive: isActive))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpFor(kind: kind, path: path))
    }

    // MARK: - Per-kind tokens

    private func iconFor(kind: String) -> String {
        switch kind {
        case "gui":           return "cursorarrow.click"
        case "shell":         return "terminal"
        case "osascript",
             "applescript":   return "applescript"
        case "mcp":           return "puzzlepiece.extension"
        case "cli":           return "chevron.left.forwardslash.chevron.right"
        default:              return "ellipsis"
        }
    }

    private func labelFor(kind: String) -> String {
        switch kind {
        case "gui":         return "GUI"
        case "shell":       return "Shell"
        case "osascript",
             "applescript": return "AppleScript"
        case "mcp":         return "MCP"
        case "cli":         return "CLI"
        default:            return kind.capitalized
        }
    }

    private func helpFor(kind: String, path: [String: Any]) -> String {
        let desc = (path["description"] as? String) ?? labelFor(kind: kind)
        return desc
    }
}

/// Active segment renders as glass on macOS 26+, falling back to a
/// neutral fill + faint border on older OSes. Inactive segments
/// stay transparent so the segmented control reads as a single
/// glass surface with one segment popping forward.
private struct PathSegmentBackground: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if !isActive {
            content
        } else if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: DT.rButton - 2, style: .continuous)
            )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: DT.rButton - 2, style: .continuous)
                        .fill(.primary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DT.rButton - 2, style: .continuous)
                        .strokeBorder(.primary.opacity(0.18), lineWidth: 0.5)
                )
        }
    }
}
