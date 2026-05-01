// TimelineView.swift - The popover root. Branches on the current state.json
// mode and renders a different surface for each:
//
//   .idle        → IdleSurface       start a recording, browse past ones
//   .recording   → RecordingSurface  live event tree + Stop button
//   .autonomous  → AutonomousSurface minimal status (deferred)
//
// AnnotationsStrip is shared at the top across all three modes — annotations
// are useful in any state.

import AppKit
import Flow42Core
import SwiftUI

struct TimelineView: View {

    @ObservedObject var stateClient: StateClient
    @ObservedObject var model: TimelineModel
    @ObservedObject var recordingsModel: RecordingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            modeSurface
        }
        .frame(width: 380, height: 520, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 10, height: 10)
            Text(stateClient.state.mode.rawValue.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let label = stateClient.state.label, !label.isEmpty {
                Text("· \(label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if stateClient.state.mode == .recording {
                Text("\(model.events.count) events")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Mode dispatch

    @ViewBuilder
    private var modeSurface: some View {
        switch stateClient.state.mode {
        case .idle:
            IdleSurface(recordings: recordingsModel)
        case .recording:
            RecordingSurface(state: stateClient.state, model: model)
        case .autonomous:
            AutonomousSurface(state: stateClient.state)
        }
    }

    private var badgeColor: Color {
        switch stateClient.state.mode {
        case .idle: return .secondary
        case .recording: return Color(red: 0xFF/255, green: 0x3E/255, blue: 0xCB/255)
        case .autonomous: return Color(red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255)
        }
    }
}

// MARK: - Idle surface

private struct IdleSurface: View {
    @ObservedObject var recordings: RecordingsModel
    @State private var description: String = ""
    @State private var startError: String? = nil
    @State private var starting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            startForm
            Divider()
            recordingsList
        }
    }

    private var startForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New recording")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("What are you teaching?", text: $description)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { startRecording() }
                Button {
                    startRecording()
                } label: {
                    HStack(spacing: 6) {
                        if starting {
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "record.circle.fill")
                        }
                        Text(starting ? "Starting…" : "Start")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(starting)
                .keyboardShortcut(.defaultAction)
            }
            if let err = startError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent recordings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !recordings.recordings.isEmpty {
                    Text("· \(recordings.recordings.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    recordings.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if recordings.recordings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(recordings.recordings) { rec in
                            RecordingRow(recording: rec)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No recordings yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Type a description above and hit Start.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func startRecording() {
        startError = nil
        starting = true
        var args = ["record", "start"]
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            args += ["--description", trimmed]
        }
        // Off the main actor so the popover stays responsive while the
        // daemon spawns, even though `record start` typically returns in
        // <500ms (it's `record stop` that's expensive). Same shape as
        // the stop handler for consistency.
        Task { @MainActor in
            let result = await Flow42CLI.runAsync(args, timeout: 10)
            starting = false
            if let result, (result["success"] as? Bool) == true {
                description = ""
                // state.json watcher will swap us into RecordingSurface
                // in a tick.
            } else {
                let err = (result?["error"] as? String) ?? "could not start recording"
                startError = err
            }
        }
    }
}

private struct RecordingRow: View {
    let recording: RecordingSummary
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(recording.caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if !recording.relativeWhen.isEmpty {
                        Text("· \(recording.relativeWhen)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            NSWorkspace.shared.open(URL(fileURLWithPath: recording.dir))
        }
        .contextMenu {
            Button("Reveal in Finder") {
                let target = (recording.dir as NSString).appendingPathComponent("events.jsonl")
                let url = FileManager.default.fileExists(atPath: target)
                    ? URL(fileURLWithPath: target)
                    : URL(fileURLWithPath: recording.dir)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Copy slug") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recording.id, forType: .string)
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recording.dir, forType: .string)
            }
        }
        .help(recording.dir)
    }
}

// MARK: - Recording surface

private struct RecordingSurface: View {
    let state: AppState
    @ObservedObject var model: TimelineModel
    @State private var stopping = false
    @State private var stopError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stopBar
            Divider()
            if model.events.isEmpty {
                waitingState
            } else {
                eventList
            }
        }
    }

    private var stopBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stopping ? "Finalizing…" : "Recording in progress")
                    .font(.system(size: 12, weight: .semibold))
                if stopping {
                    Text("Transcribing narration, sorting events…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let slug = state.recording?.slug {
                    Text(slug)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(role: .destructive) {
                stop()
            } label: {
                HStack(spacing: 6) {
                    if stopping {
                        ProgressView()
                            .controlSize(.small)
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: "stop.circle.fill")
                    }
                    Text(stopping ? "Stopping…" : "Stop")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(stopping)
            .keyboardShortcut("s", modifiers: [.command])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if let err = stopError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
        }
    }

    private func stop() {
        stopping = true
        stopError = nil
        // `flow42 record stop` blocks on whisper transcription + the
        // EventsFinalizer sort/renumber pass — that can be 1–30s on a
        // long recording. We MUST NOT run it on the main actor or the
        // popover freezes (animations, the timeline tailer, even the
        // window close hotkey). Spawn it on a detached task and hop
        // back to the main actor only to flip the state flags.
        Task { @MainActor in
            let result = await Flow42CLI.runAsync(["record", "stop"], timeout: 65)
            stopping = false
            if let result, (result["success"] as? Bool) == true {
                // state.json watcher will swap us back to IdleSurface.
            } else {
                stopError = (result?["error"] as? String) ?? "stop failed"
            }
        }
    }

    private var waitingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().scaleEffect(0.8)
            Text("Waiting for the first action…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var eventList: some View {
        // `List` is backed by NSTableView and properly virtualizes — offscreen
        // rows are NOT measured. The previous `LazyVStack` inside `ScrollView`
        // still re-measured every visible row's intrinsic size on every event
        // append, which monopolised the main run loop and made the
        // Cmd+Shift+A hotkey appear unresponsive. Auto-scroll is unanimated
        // because the `withAnimation` was forcing an extra layout pass per
        // event during fast recordings.
        ScrollViewReader { proxy in
            List {
                ForEach(model.events) { event in
                    EventRow(event: event, anchor: model.events.first?.timestampMs)
                        .id(event.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.events.count) { _, _ in
                if let last = model.events.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Autonomous surface (placeholder; deferred)

private struct AutonomousSurface: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color(red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255))
            Text("Agent is driving")
                .font(.system(size: 13, weight: .medium))
            if let label = state.autonomous?.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Text("Try not to touch the screen until the agent finishes.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Event row (shared by RecordingSurface)

private struct EventRow: View {
    let event: TimelineEvent
    let anchor: Int64?
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeOffsetLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .leading)
                .padding(.top, 2)

            verbBadge
                .padding(.top, 2)

            if let path = event.screenshotPath {
                EventThumbnail(path: path)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(.system(size: 12))
                    .lineLimit(2)
                if let target = event.target, !target.isEmpty {
                    Text(target)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 1)

            if hovered, let cmd = event.replicate {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy replicate command")
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) {
            if let path = event.screenshotPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
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
            // Same Tailwind blue-500 used for the overlay rect.
            return Color(red: 59/255, green: 130/255, blue: 246/255)
        case "urlChange", "newTab", "tabSwitch": return .teal
        default: return .gray
        }
    }
}

/// Lazily loads and renders a 48×32 thumbnail next to an event row.
/// Lives inside a LazyVStack so the load only happens for visible rows.
/// Failure (file gone, format weird) collapses the view silently.
private struct EventThumbnail: View {
    let path: String
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .help("Double-click to open")
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 48, height: 32)
            }
        }
        .onAppear {
            if image == nil {
                image = NSImage(contentsOfFile: path)
            }
        }
    }
}
