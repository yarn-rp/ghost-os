// SessionClient.swift - FSEvents-backed observable for one
// `ChatSession`. Watches the session's `latest.json` for change
// notifications and re-tails `transcript.jsonl` whenever the file
// bumps. Replaces the global `AgentLatestClient`.
//
// Same construction pattern: file-level + dir-level dispatch
// sources so we survive the file being deleted/recreated mid-run.
// The wrapped session is exposed publicly so consumers can render
// session-specific chrome (provider name, started_at, etc.).

import Combine
import Dispatch
import Foundation

@MainActor
public final class SessionClient: ObservableObject {

    /// The session this client is bound to. Immutable for the
    /// client's lifetime — callers create a new client when they
    /// want to observe a different session.
    public let session: ChatSession

    @Published public private(set) var snapshot: AgentLatestSnapshot
    /// Bumped on every observed change; cheap for SwiftUI to observe.
    @Published public private(set) var revision: Int = 0
    /// Coalesced full transcript (consecutive `assistantText` chunks
    /// merged into one bubble — same shape the legacy
    /// `AgentLatestClient` exposed).
    @Published public private(set) var transcript: [TranscriptEvent] = []

    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var fileFD: CInt = -1
    private var dirFD: CInt = -1

    public init(session: ChatSession) {
        self.session = session
        self.snapshot = SessionLatestFile.read(from: session)
        attachFileWatcher()
        attachDirWatcher()
        // Seed the transcript synchronously off-main so the first
        // render isn't an empty flash before FSEvents catches up.
        Task { await self.refreshTranscript() }
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        if fileFD >= 0 { close(fileFD) }
        if dirFD >= 0 { close(dirFD) }
    }

    // MARK: - Watchers

    private func reload() {
        let next = SessionLatestFile.read(from: session)
        if next != snapshot {
            snapshot = next
        }
        revision &+= 1
        Task { await self.refreshTranscript() }
    }

    private func refreshTranscript() async {
        let captured = session
        let raw = await Task.detached(priority: .userInitiated) {
            SessionTranscriptLog.readAll(from: captured)
        }.value
        self.transcript = Self.coalesce(raw)
    }

    /// Walk `events` in order; runs of consecutive `assistantText`
    /// chunks (the agent SDK streams its replies in many small
    /// notifications) collapse into one bubble so the rendered chat
    /// reads as discrete turns. The merged bubble keeps the FIRST
    /// chunk's id + timestamp so SwiftUI's ForEach sees a stable
    /// identity — the bubble grows in place rather than reordering.
    static func coalesce(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        var out: [TranscriptEvent] = []
        for event in events {
            if case .assistantText(let text) = event.kind,
               let last = out.last,
               case .assistantText(let prevText) = last.kind {
                out[out.count - 1] = TranscriptEvent(
                    id: last.id,
                    kind: .assistantText(prevText + text),
                    timestamp: last.timestamp
                )
            } else {
                out.append(event)
            }
        }
        return out
    }

    private func attachFileWatcher() {
        let path = session.latestPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let fd = open(path, O_EVTONLY)
        if fd < 0 { return }
        fileFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) {
                source.cancel()
                self.fileSource = nil
                if self.fileFD >= 0 { close(self.fileFD); self.fileFD = -1 }
                self.reload()
            } else {
                self.reload()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileFD >= 0 { close(self.fileFD); self.fileFD = -1 }
        }
        source.resume()
        fileSource = source
    }

    private func attachDirWatcher() {
        let dir = session.directory
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let fd = open(dir, O_EVTONLY)
        if fd < 0 { return }
        dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The latest file may have been (re)created. Re-arm the
            // file-level watcher.
            if self.fileSource == nil,
               FileManager.default.fileExists(atPath: self.session.latestPath) {
                self.attachFileWatcher()
            }
            self.reload()
        }
        source.resume()
        dirSource = source
    }
}
