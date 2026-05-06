// AgentLatestClient.swift - FSEvents watcher on ~/.flow42/agent-latest.json.
//
// Same construction as StateClient — file-level + dir-level dispatch
// sources so we survive the file being deleted/recreated. Publishes the
// current AgentLatestSnapshot via Combine `@Published` so SwiftUI views
// in Flow42Menu's PlayPanel just bind to it.
//
// Also exposes the full transcript log (read-on-demand via
// `AgentTranscriptLog.readAll()`) so the chat-mode swap can render the
// whole conversation; we don't keep that in memory continuously
// because the panel's compact mode only ever needs the latest event.

import Combine
import Dispatch
import Foundation

@MainActor
public final class AgentLatestClient: ObservableObject {

    @Published public private(set) var snapshot: AgentLatestSnapshot = AgentLatestFile.read()

    /// Bumped every time the underlying file changes. Chat-mode views
    /// observe this to know when to re-tail agent-transcript.jsonl.
    /// Cheap to bind to from SwiftUI (Int comparisons).
    @Published public private(set) var revision: Int = 0

    /// The full transcript, post-coalescing. Lives here (not as @State
    /// inside ChatTimeline) so the chat keeps its content across view
    /// rebuilds — clicking the input field, focus changes, AnyView re-
    /// wraps from the controller's `apply()`, etc. otherwise reset
    /// view-local @State and the chat would visibly clear.
    @Published public private(set) var transcript: [TranscriptEvent] = []

    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var fileFD: CInt = -1
    private var dirFD: CInt = -1

    public init() {
        attachFileWatcher()
        attachDirWatcher()
        // Seed from disk so the transcript is non-empty immediately
        // when the view first binds (vs flashing through an empty
        // state for the first FSEvents tick).
        Task { await self.refreshTranscript() }
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        if fileFD >= 0 { close(fileFD) }
        if dirFD >= 0 { close(dirFD) }
    }

    // (`readFullTranscript()` removed — the transcript is now a
    // @Published property kept up-to-date by the FSEvents handler. View
    // code observes `transcript` directly instead of pulling on demand.)

    // MARK: - Watchers

    private func reload() {
        let next = AgentLatestFile.read()
        if next != snapshot {
            snapshot = next
        }
        revision &+= 1 // always bump — chat-mode tails on every change
        // Refresh the full transcript too. Off the main actor so a
        // long log doesn't hitch the FSEvents handler (we're already
        // on .main here from the DispatchSource queue).
        Task { await self.refreshTranscript() }
    }

    /// Re-read the JSONL log and apply chat-friendly coalescing —
    /// adjacent `assistantText` chunks (the agent SDK streams its
    /// response in many small notifications) collapse into one bubble
    /// so the rendered chat reads as discrete turns rather than a
    /// stream of fragments.
    private func refreshTranscript() async {
        let raw = await Task.detached(priority: .userInitiated) {
            AgentTranscriptLog.readAll()
        }.value
        self.transcript = Self.coalesce(raw)
    }

    /// Pure function — exposed `internal` for testing. Walks the input
    /// in order and merges runs of consecutive `assistantText` events
    /// into a single event whose text is the chunks joined with no
    /// separator (the agent's chunk boundaries don't carry whitespace,
    /// so concatenation is the right join). Other event kinds pass
    /// through unchanged.
    static func coalesce(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        var out: [TranscriptEvent] = []
        for event in events {
            if case .assistantText(let text) = event.kind,
               let last = out.last,
               case .assistantText(let prevText) = last.kind {
                // Merge into the previous bubble. We KEEP the previous
                // event's id + timestamp — that way SwiftUI's ForEach
                // sees a stable identity across re-tails (the bubble
                // grows in place rather than reordering).
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
        let path = AgentLatestFile.path()
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
        let dir = (AgentLatestFile.path() as NSString).deletingLastPathComponent
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
            // The latest file may have just been (re)created. Re-arm the
            // file-level watcher.
            if self.fileSource == nil,
               FileManager.default.fileExists(atPath: AgentLatestFile.path()) {
                self.attachFileWatcher()
            }
            self.reload()
        }
        source.resume()
        dirSource = source
    }
}
