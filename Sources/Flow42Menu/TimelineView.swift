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
    @ObservedObject var panelController: PlayPanelController

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
            Text(stateClient.state.derivedState.rawValue.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let label = stateClient.state.play?.label, !label.isEmpty {
                Text("· \(label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if stateClient.state.derivedState == .recording {
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
        switch stateClient.state.derivedState {
        case .idle:
            IdleSurface(recordings: recordingsModel)
        case .recording, .driving, .watching:
            // For ANY non-idle state, the popover's content depends on
            // whether the floating window is currently shown:
            //   visible → small status header only (the floating window
            //             carries the full UI)
            //   hidden  → full panel content + an "Open Floating" button,
            //             so the popover IS the active UI
            if panelController.isFloatingVisible {
                FloatingVisibleStatus(state: stateClient.state)
            } else if let content = panelController.currentContent {
                FloatingHiddenSurface(
                    state: stateClient.state,
                    content: content,
                    timelineModel: panelController.timelineModel,
                    chatSession: panelController.chatSession,
                    onOpenFloating: { panelController.showFloating() },
                    onStop: { runStopFromPopover() }
                )
            } else {
                // No resolved content yet (rare race; first state tick).
                FloatingVisibleStatus(state: stateClient.state)
            }
        }
    }

    /// Shell out `flow42 stop` from the popover's Stop button. The Stop
    /// closure is wired through here rather than directly into the panel
    /// view because we want a single source of truth for "how the menu
    /// app's Swift code shells out to flow42."
    private func runStopFromPopover() {
        guard let path = Flow42CLI.binaryPath() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["stop"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    private var badgeColor: Color {
        switch stateClient.state.derivedState {
        case .idle: return .secondary
        case .recording: return Color(red: 0xFF/255, green: 0x3E/255, blue: 0xCB/255)
        case .driving:   return Color(red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255)
        case .watching:  return Color(red: 0x3D/255, green: 0xB6/255, blue: 0xFF/255)
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
        // Always force from the UI: the user pressing "Start recording"
        // IS their "replace anything stale" intent. The CLI's strict
        // singleton check is for human shells, not the menu.
        var args = ["record", "start", "--force"]
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

/// Locate the Flow42App binary so the menu can launch it on demand
/// when the user clicks a recording. Mirrors `Flow42CLI.binaryPath`'s
/// search order but targets the GUI binary instead of the CLI. Same
/// rationale: bundle path first, then dev .build dir, then the running
/// menu's siblings.
private func flow42AppBinaryPath() -> String? {
    let fm = FileManager.default

    // 1. Inside Flow42.app bundle (Contents/MacOS/Flow42App).
    if let exec = Bundle.main.bundlePath as String?,
       (exec as NSString).pathExtension == "app" {
        let cand = (exec as NSString).appendingPathComponent("Contents/MacOS/Flow42App")
        if fm.isExecutableFile(atPath: cand) { return cand }
    }
    // 2. Walk up from the running menu binary to find a sibling .build.
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<6 {
        for variant in ["debug", "release"] {
            let cand = dir
                .appendingPathComponent(".build")
                .appendingPathComponent(variant)
                .appendingPathComponent("Flow42App")
                .path
            if fm.isExecutableFile(atPath: cand) { return cand }
        }
        let sibling = dir.appendingPathComponent("Flow42App").path
        if fm.isExecutableFile(atPath: sibling) { return sibling }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

/// If Flow42App is already running (process alive with our binary path),
/// just bring it to front. Otherwise spawn it. After a brief delay the
/// deep-link notification is reposted so the freshly-launched app picks
/// it up after its delegate has subscribed.
private func ensureFlow42AppRunningAndRepostDeepLink(dir: String) {
    let runningApps = NSWorkspace.shared.runningApplications
    let alreadyUp = runningApps.contains { app in
        app.localizedName == "Flow42App" || app.bundleIdentifier?.contains("flow42") == true
    }
    if alreadyUp {
        // Activate so the window comes forward; the in-process listener
        // already received the notification we posted.
        if let app = runningApps.first(where: {
            $0.localizedName == "Flow42App"
        }) {
            app.activate()
        }
        return
    }

    guard let binary = flow42AppBinaryPath() else {
        FileHandle.standardError.write(Data(
            "[Flow42Menu] Flow42App binary not found; cannot deep-link.\n".utf8
        ))
        return
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: binary)
    do {
        try task.run()
    } catch {
        FileHandle.standardError.write(Data(
            "[Flow42Menu] failed to launch Flow42App: \(error)\n".utf8
        ))
        return
    }
    // Re-post the deep link a moment later so the app has time to
    // subscribe its DistributedNotificationCenter observer before the
    // notification fires.
    Task.detached {
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s
        Flow42DeepLink.postOpenFlow(dir: dir)
    }
}

/// Sibling of `ensureFlow42AppRunningAndRepostDeepLink` for fresh
/// recordings (no `flow.yaml` yet). Same launch + activate + re-post
/// pattern, only the notification posted after the cold-start grace
/// window changes.
private func ensureFlow42AppRunningAndRepostRecording(dir: String, slug: String) {
    let runningApps = NSWorkspace.shared.runningApplications
    let alreadyUp = runningApps.contains { app in
        app.localizedName == "Flow42App" || app.bundleIdentifier?.contains("flow42") == true
    }
    if alreadyUp {
        if let app = runningApps.first(where: { $0.localizedName == "Flow42App" }) {
            app.activate()
        }
        return
    }
    guard let binary = flow42AppBinaryPath() else {
        FileHandle.standardError.write(Data(
            "[Flow42Menu] Flow42App binary not found; cannot hand off recording.\n".utf8
        ))
        return
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: binary)
    do {
        try task.run()
    } catch {
        FileHandle.standardError.write(Data(
            "[Flow42Menu] failed to launch Flow42App: \(error)\n".utf8
        ))
        return
    }
    Task.detached {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        Flow42DeepLink.postOpenRecording(dir: dir, slug: slug)
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
            // Open the flow inside Flow42App rather than dumping the
            // user into Finder. Strategy: post a distributed
            // notification with the flow path; if the main app is
            // running it'll catch it and navigate. If not, launch the
            // app and re-post once it's up so the deep link still
            // resolves on the same click.
            Flow42DeepLink.postOpenFlow(dir: recording.dir)
            ensureFlow42AppRunningAndRepostDeepLink(dir: recording.dir)
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
                // state.json watcher swaps the menu surface back to
                // IdleSurface. We additionally hand the freshly-
                // captured recording off to Flow42App so an autonomous
                // chat can run the flow-creator skill on it without
                // any further user action.
                if let dir = result["path"] as? String, !dir.isEmpty {
                    let slug = (result["slug"] as? String) ?? ""
                    Flow42DeepLink.postOpenRecording(dir: dir, slug: slug)
                    // Bring the main app forward (or launch it cold
                    // and re-post once it's up so the deep link
                    // resolves on the same click).
                    ensureFlow42AppRunningAndRepostRecording(dir: dir, slug: slug)
                }
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

// MARK: - Driving / watching surfaces (popover content for active plays)
//
// The popover renders one of two surfaces depending on whether the
// floating window is currently shown:
//
//   FloatingVisibleStatus  — a small status header ONLY. The floating
//                            window carries the full UI; the popover just
//                            confirms what's happening so the user knows
//                            why the menu bar icon changed colour.
//
//   FloatingHiddenSurface  — the full panel content + an "Open Floating"
//                            button. With the floating window closed, the
//                            popover is the only on-screen UI for the
//                            session, so it has to be self-sufficient.
//
// Shared helpers for both surfaces (color tokens, header copy) live in
// this private extension so we don't duplicate them.

/// Tokens + copy shared between the surfaces. Handles all four derived
/// states (recording, driving, watching, idle).
private enum DrivingSurfaceTokens {
    static let orange  = Color(red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255)
    static let blue    = Color(red: 0x3D/255, green: 0xB6/255, blue: 0xFF/255)
    static let magenta = Color(red: 0xFF/255, green: 0x3E/255, blue: 0xCB/255)

    static func accent(for state: AppState) -> Color {
        if state.recording != nil { return magenta }
        if state.play?.pause != nil { return blue }
        if state.play?.state == .watching { return blue }
        return orange
    }

    static func headerText(for state: AppState) -> String {
        if state.recording != nil { return "Recording in progress" }
        if state.play?.pause != nil { return "Paused — agent needs help" }
        if state.play?.state == .watching { return "You're driving (agent is watching)" }
        return "Agent is driving"
    }

    static func headerIcon(for state: AppState) -> String {
        if state.recording != nil { return "record.circle.fill" }
        if state.play?.pause != nil { return "exclamationmark.triangle.fill" }
        if state.play?.state == .watching { return "eye.circle.fill" }
        return "bolt.circle.fill"
    }
}

// MARK: - Floating-visible status (small header only)

/// Rendered in the popover when the floating window is on screen. Just a
/// confirmation strip — the floating window has all the controls.
private struct FloatingVisibleStatus: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: DrivingSurfaceTokens.headerIcon(for: state))
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(DrivingSurfaceTokens.accent(for: state))
                VStack(alignment: .leading, spacing: 2) {
                    Text(DrivingSurfaceTokens.headerText(for: state))
                        .font(.system(size: 14, weight: .semibold))
                    if let label = state.play?.label, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer()
            Text("The floating window has the full controls.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Floating-hidden surface (full content; "Open Floating" + Stop)

/// Rendered in the popover when the floating window has been dismissed.
/// Renders the SAME panel view (PlayPanelView for plays, RecordingPanelView
/// for recordings) the floating window uses, in `.popover` style (no
/// glass, no shadow — the popover provides those).
private struct FloatingHiddenSurface: View {
    let state: AppState
    let content: PlayPanelController.SessionContent
    let timelineModel: TimelineModel
    /// Same shared chat-session box PlayPanelController owns. The
    /// popover's PlayPanelView reads it so the chat bubble + chat-
    /// mode swap work here too — both surfaces stay perfectly in
    /// sync.
    @ObservedObject var chatSession: SessionClientBox
    let onOpenFloating: () -> Void
    let onStop: () -> Void

    @ViewBuilder
    var body: some View {
        switch content {
        case .play(let pc):
            PlayPanelView(
                state: state,
                intent: pc.intent,
                stepText: pc.stepText,
                stepScreenshotPath: pc.stepScreenshotPath,
                params: pc.params,
                style: .popover,
                onPause: { runFlow42(["play", "pause", "--reason", "user paused via menu bar popover"]) },
                onResume: { runFlow42(["play", "resume"]) },
                onResumeAndAdvance: {
                    // Sequential — concurrent invocations race on
                    // state.json's atomic writer.
                    runFlow42Sequence([["play", "next"], ["play", "resume"]])
                },
                onNextStep: { runFlow42(["play", "next-step"]) },
                onPrevStep: { runFlow42(["play", "prev-step"]) },
                onPrimaryAction: onOpenFloating,
                onStop: onStop,
                chatSession: chatSession
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .recording:
            if let recording = state.recording {
                RecordingPanelView(
                    recording: recording,
                    model: timelineModel,
                    style: .popover,
                    onPrimaryAction: onOpenFloating,
                    onStop: onStop
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func runFlow42(_ args: [String]) {
        guard let path = Flow42CLI.binaryPath() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    /// Run flow42 invocations sequentially off the main thread, waiting
    /// for each to exit before starting the next. Required whenever the
    /// second command depends on the first having committed to state.json
    /// (concurrent writers race and one mutation gets clobbered).
    private func runFlow42Sequence(_ commands: [[String]]) {
        guard let path = Flow42CLI.binaryPath() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for args in commands {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = args
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                } catch {
                    return
                }
            }
        }
    }
}

// MARK: - Event row (shared by RecordingSurface)

struct EventRow: View {
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
struct EventThumbnail: View {
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
