// RecordingPanelView.swift - Floating-panel layout for the `recording`
// state. Mirrors PlayPanelView's structure: shows ONE event at a time
// (the most recent by default), with media-player-style transport for
// scrubbing through the captured event history. The screenshot is the
// dominant visual element — same treatment as the play panel's step
// screenshot.
//
// Auto-follows the latest event by default; manually clicking ◀ / ▶
// pins the browse position. A small "Latest →" pill returns to follow
// mode.
//
// Same `.floating` / `.popover` style switch as PlayPanelView so the
// menu bar popover can render the same view without glass + shadow.
//
// Accent color is `0x7C3AED` (violet) — matches the edge glow's `mid`
// color from OrbStateTokens. (The bright pink `0xFF3ECB` is the `core`
// color; using it made the panel and the edge glow look like different
// colors.)

import AppKit
import Flow42Core
import SwiftUI

// MARK: - Tokens

private enum RecordingTokens {
    static let width: CGFloat = 400
    static let outerCornerRadius: CGFloat = 20
    static let innerSpacing: CGFloat = 14
    static let edgePadding: CGFloat = 18
    static let screenshotCorner: CGFloat = 10

    /// Matches OrbStateTokens.recording.mid — the dominant visible color
    /// of the recording edge glow.
    static let violet = Color(red: 0x7C/255, green: 0x3A/255, blue: 0xED/255)
}

// MARK: - RecordingPanelView

struct RecordingPanelView: View {
    let recording: RecordingInfo
    @ObservedObject var model: TimelineModel
    let style: PlayPanelStyle

    let onPrimaryAction: () -> Void   // close-floating / open-floating
    let onStop: () -> Void

    /// Index of the event being shown. `nil` = follow the latest.
    /// User-initiated prev/next sets a concrete value; clicking the
    /// "Jump to latest" pill clears it.
    @State private var pinnedIndex: Int? = nil

    /// When true, the panel body swaps to a scrollable list of all
    /// captured events. Tapping an event pins to that index and returns
    /// to the main (single-event) view.
    @State private var showingList: Bool = false

    private var accent: Color { RecordingTokens.violet }

    /// The event currently displayed. Latest if not pinned, otherwise
    /// the pinned index clamped to bounds.
    private var displayedEvent: TimelineEvent? {
        guard !model.events.isEmpty else { return nil }
        if let idx = pinnedIndex {
            return model.events[max(0, min(idx, model.events.count - 1))]
        }
        return model.events.last
    }

    private var displayedIndex: Int {
        guard !model.events.isEmpty else { return 0 }
        if let idx = pinnedIndex { return max(0, min(idx, model.events.count - 1)) }
        return model.events.count - 1
    }

    private var isFollowingLatest: Bool { pinnedIndex == nil }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if showingList {
                    listMode
                        .padding(.horizontal, RecordingTokens.edgePadding)
                        .padding(.top, RecordingTokens.edgePadding)
                        .padding(.bottom, RecordingTokens.edgePadding - 4)
                } else {
                    content
                        .padding(.horizontal, RecordingTokens.edgePadding)
                        .padding(.top, RecordingTokens.edgePadding)
                        .padding(.bottom, 10)

                    transport
                        .padding(.horizontal, RecordingTokens.edgePadding)
                        .padding(.bottom, RecordingTokens.edgePadding - 4)
                }
            }

            topRightButtons
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
        .frame(width: RecordingTokens.width)
        .modifier(RecordingChromeIfFloating(style: style, cornerRadius: RecordingTokens.outerCornerRadius))
        .animation(.easeInOut(duration: 0.18), value: showingList)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: RecordingTokens.innerSpacing) {
            recordingHeader

            if let event = displayedEvent {
                eventMetadata(event)
                screenshot(for: event)
                if !isFollowingLatest {
                    backToLatestPill
                }
            } else {
                waitingForFirstEvent
            }
        }
    }

    // MARK: - Header (REC eyebrow + slug)

    private var recordingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    // Subtle "live" pulse when recording is actively
                    // following the latest event.
                    .opacity(isFollowingLatest ? 1.0 : 0.45)
                Text("RECORDING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(accent)
            }
            Text(displaySlug)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 26) // top-right buttons
        }
    }

    // MARK: - Event metadata (timestamp + verb + summary + target)

    private func eventMetadata(_ event: TimelineEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // EVENT N OF M eyebrow + verb badge
            HStack(spacing: 8) {
                Text("EVENT \(displayedIndex + 1) OF \(model.events.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                verbBadge(for: event)
                if let ts = event.timestampMs, let anchor = model.events.first?.timestampMs {
                    let delta = max(0, ts - anchor)
                    Text(String(format: "+%.1fs", Double(delta) / 1000.0))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            // Summary line
            Text(event.summary)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let target = event.target, !target.isEmpty {
                Text(target)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Screenshot

    @ViewBuilder
    private func screenshot(for event: TimelineEvent) -> some View {
        if let path = event.screenshotPath, let img = NSImage(contentsOfFile: path) {
            Button(action: { ScreenshotPreview.show(img) }) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: RecordingTokens.screenshotCorner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RecordingTokens.screenshotCorner, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .help("Click to preview at full size — Esc or Space to close")
        } else if event.actionType == "narration" {
            // Narration events don't have a screenshot. Show the
            // transcribed text as a quoted block instead.
            VStack(alignment: .leading, spacing: 4) {
                Text("TRANSCRIPT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(event.summary.replacingOccurrences(of: "narration: ", with: ""))
                    .font(.system(size: 13))
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.08))
            )
        } else {
            // Skeleton — race with the recorder writing the file.
            RoundedRectangle(cornerRadius: RecordingTokens.screenshotCorner, style: .continuous)
                .fill(.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: RecordingTokens.screenshotCorner, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                )
                .frame(height: 120)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                )
        }
    }

    // MARK: - Waiting state

    private var waitingForFirstEvent: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(0.8)
            Text("Waiting for the first action…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    // MARK: - "Back to latest" pill

    private var backToLatestPill: some View {
        HStack {
            Button(action: { pinnedIndex = nil }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11))
                    Text("Jump to latest")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(accent.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(accent.opacity(0.30), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Transport (prev — STOP — next, media-player layout)

    private var transport: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.35)
                .padding(.bottom, 12)

            HStack(spacing: 22) {
                Spacer()
                navButton(symbol: "backward.fill", enabled: canGoPrev, action: goPrev)
                ArmedStopButtonLarge(
                    confirmTitle: "Stop the recording?",
                    confirmMessage: stopConfirmMessage,
                    onStop: onStop,
                    accent: accent
                )
                navButton(symbol: "forward.fill", enabled: canGoNext, action: goNext)
                Spacer()
            }
        }
    }

    private var canGoPrev: Bool { displayedIndex > 0 && !model.events.isEmpty }
    private var canGoNext: Bool { displayedIndex < model.events.count - 1 }

    private func goPrev() {
        guard canGoPrev else { return }
        pinnedIndex = displayedIndex - 1
    }

    private func goNext() {
        guard canGoNext else { return }
        let next = displayedIndex + 1
        // If we're stepping forward to the latest, drop back into
        // follow-mode so subsequent recorded events keep updating.
        if next >= model.events.count - 1 {
            pinnedIndex = nil
        } else {
            pinnedIndex = next
        }
    }

    private func navButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled ? .primary : .tertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.45)
    }

    // MARK: - Top-right buttons (list-toggle + minimize/expand)

    @ViewBuilder
    private var topRightButtons: some View {
        HStack(spacing: 8) {
            // List / back-to-main toggle
            Button(action: { showingList.toggle() }) {
                Image(systemName: showingList
                      ? "chevron.left.circle.fill"
                      : "list.bullet.rectangle.portrait")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showingList
                  ? "Back to the main view."
                  : "View all captured events. Tap one to focus it here.")

            // Minimize / expand the floating window. Recording continues
            // either way; this is just "abort showing the floating".
            Button(action: onPrimaryAction) {
                Image(systemName: primaryActionIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primaryActionTooltip)
        }
    }

    // MARK: - List mode

    private var listMode: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header — REC + count, no big title (stays compact).
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                    Text("RECORDING · \(model.events.count) EVENT\(model.events.count == 1 ? "" : "S")")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(accent)
                }
                Text("Tap an event to focus it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.trailing, 50) // room for the top-right buttons
            }

            Divider().opacity(0.35)

            // Scrollable event list.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.events.enumerated()), id: \.element.id) { idx, event in
                            EventListRow(
                                event: event,
                                index: idx,
                                anchor: model.events.first?.timestampMs,
                                isCurrent: idx == displayedIndex,
                                accent: accent
                            ) {
                                // Pin and return to the main view.
                                pinnedIndex = idx
                                showingList = false
                            }
                            .id(event.id)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(height: 360)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let event = displayedEvent {
                        proxy.scrollTo(event.id, anchor: .center)
                    }
                }
            }
        }
    }

    private var primaryActionIcon: String {
        switch style {
        case .floating: return "rectangle.compress.vertical"
        case .popover:  return "macwindow.on.rectangle"
        }
    }
    private var primaryActionTooltip: String {
        switch style {
        case .floating: return "Hide the floating window — recording keeps running. Reopen from the menu bar."
        case .popover:  return "Open the floating window — show the panel anywhere on screen."
        }
    }

    // MARK: - Verb badge (mirrors EventRow's palette)

    private func verbBadge(for event: TimelineEvent) -> some View {
        let color = badgeColor(for: event.actionType)
        return Text(badgeLabel(for: event.actionType))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }

    private func badgeLabel(for type: String) -> String {
        switch type {
        case "click": return "CLICK"
        case "typeText": return "TYPE"
        case "keyPress": return "KEY"
        case "hotkey": return "HOTKEY"
        case "scroll": return "SCROLL"
        case "appSwitch": return "APP"
        case "narration": return "NARR"
        case "highlight": return "HILITE"
        case "urlChange": return "GOTO"
        case "newTab": return "NEWTAB"
        case "tabSwitch": return "TABSW"
        default: return type.uppercased()
        }
    }

    private func badgeColor(for type: String) -> Color {
        switch type {
        case "click": return .blue
        case "typeText": return .green
        case "keyPress", "hotkey": return .purple
        case "scroll": return .orange
        case "appSwitch": return .pink
        case "narration": return .cyan
        case "highlight":
            return Color(red: 59/255, green: 130/255, blue: 246/255)
        case "urlChange", "newTab", "tabSwitch": return .teal
        default: return .gray
        }
    }

    // MARK: - Helpers

    private var displaySlug: String {
        let slug = recording.slug
        if slug.hasPrefix("recording-") {
            return "Recording · \(slug.dropFirst("recording-".count))"
        }
        return slug
    }

    private var stopConfirmMessage: String {
        let n = model.events.count
        return "Stops the recording and finalises it on disk (transcribes narration, sorts events, writes meta.yaml). " +
        "Captured so far: \(n) event\(n == 1 ? "" : "s")."
    }
}

// MARK: - Compact list row (one per event in list mode)

/// Tap-to-focus row used by `RecordingPanelView`'s list mode. Shows the
/// timestamp, verb badge, summary, and a small chevron-right affordance
/// to communicate "click me to open this event in the main view."
private struct EventListRow: View {
    let event: TimelineEvent
    let index: Int
    let anchor: Int64?
    let isCurrent: Bool
    let accent: Color
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 10) {
                Text(timeOffsetLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 50, alignment: .leading)

                verbBadge

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let target = event.target, !target.isEmpty {
                        Text(target)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isCurrent ? accent.opacity(0.45) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var rowBackground: Color {
        if isCurrent { return accent.opacity(0.12) }
        if hovered   { return Color.primary.opacity(0.06) }
        return Color.primary.opacity(0.025)
    }

    private var timeOffsetLabel: String {
        guard let ts = event.timestampMs, let anchor else { return "—" }
        let delta = ts - anchor
        if delta < 0 { return "—" }
        return String(format: "+%05.2fs", Double(delta) / 1000.0)
    }

    private var verbBadge: some View {
        let color = badgeColor(for: event.actionType)
        return Text(badgeLabel(for: event.actionType))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
            .frame(width: 56, alignment: .leading)
    }

    private func badgeLabel(for type: String) -> String {
        switch type {
        case "click": return "CLICK"
        case "typeText": return "TYPE"
        case "keyPress": return "KEY"
        case "hotkey": return "HOTKEY"
        case "scroll": return "SCROLL"
        case "appSwitch": return "APP"
        case "narration": return "NARR"
        case "highlight": return "HILITE"
        case "urlChange": return "GOTO"
        case "newTab": return "NEWTAB"
        case "tabSwitch": return "TABSW"
        default: return type.uppercased()
        }
    }

    private func badgeColor(for type: String) -> Color {
        switch type {
        case "click": return .blue
        case "typeText": return .green
        case "keyPress", "hotkey": return .purple
        case "scroll": return .orange
        case "appSwitch": return .pink
        case "narration": return .cyan
        case "highlight":
            return Color(red: 59/255, green: 130/255, blue: 246/255)
        case "urlChange", "newTab", "tabSwitch": return .teal
        default: return .gray
        }
    }
}

// MARK: - Larger destructive Stop pill (recording transport row)

private struct ArmedStopButtonLarge: View {
    let confirmTitle: String
    let confirmMessage: String
    let onStop: () -> Void
    let accent: Color

    var body: some View {
        Button(action: confirmAndMaybeStop) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(accent)
            )
            .shadow(color: accent.opacity(0.35), radius: 8, x: 0, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop the recording — opens a confirmation.")
    }

    private func confirmAndMaybeStop() {
        let alert = NSAlert()
        alert.messageText = confirmTitle
        alert.informativeText = confirmMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let stopButton = alert.addButton(withTitle: "Stop recording")
        if #available(macOS 11.0, *) {
            stopButton.hasDestructiveAction = true
        }
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        if alert.runModal() == .alertSecondButtonReturn {
            onStop()
        }
    }
}

// MARK: - Conditional chrome (matches PlayPanelView's pattern)

private struct RecordingChromeIfFloating: ViewModifier {
    let style: PlayPanelStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch style {
        case .floating:
            applyGlass(content)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
        case .popover:
            content
        }
    }

    @ViewBuilder
    private func applyGlass(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
    }
}
