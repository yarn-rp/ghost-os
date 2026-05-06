// AgentInputClient.swift - Flow42App-side reader of ~/.flow42/agent-
// input.jsonl. Watches the file via DispatchSource; on each new line
// (the menu app's chat input field appended), decodes a UUID-keyed
// AgentInputLine and calls a forwarding closure (typically
// `ACPClient.sendUserPrompt`).
//
// Dedupe: we keep a Set<UUID> of already-processed line ids so a
// re-tail (e.g. after the file is reset) never replays. Reset clears
// the set, so the runner's "fresh run" lifecycle works correctly.

import Combine
import Dispatch
import Flow42Core
import Foundation

@MainActor
final class AgentInputClient {

    /// Called once per new line, on the main actor. Typically this is
    /// `{ try? await self.client?.sendUserPrompt($0.text) }` plumbed
    /// from AutonomousRunner.
    private let onLine: (AgentInputLine) -> Void

    /// The session whose `input.jsonl` we're tailing. Per-session
    /// pipes mean two recordings' chats can run concurrently without
    /// collision (though for now the runner is single-instance, so
    /// only one client is alive at a time).
    private let session: ChatSession

    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var fileFD: CInt = -1
    private var dirFD: CInt = -1

    /// Ids of lines we've already forwarded — keeps dedupe across
    /// re-tails when the file is recreated.
    private var seenIds: Set<UUID> = []

    init(session: ChatSession, onLine: @escaping (AgentInputLine) -> Void) {
        self.session = session
        self.onLine = onLine
        attachFileWatcher()
        attachDirWatcher()
        // Drain any lines already on disk at start time. They were
        // either seen by a previous client (in which case we don't
        // want to replay) or new — but at runner-spawn time the
        // session's input.jsonl is brand new, so this loop is
        // typically empty. Treat anything found as already-seen so
        // we don't replay old prompts.
        for line in SessionInputLog.readAll(from: session) {
            seenIds.insert(line.id)
        }
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        if fileFD >= 0 { close(fileFD) }
        if dirFD >= 0 { close(dirFD) }
    }

    // MARK: - Drain

    private func drainNewLines() {
        let lines = SessionInputLog.readAll(from: session)
        for line in lines where !seenIds.contains(line.id) {
            seenIds.insert(line.id)
            onLine(line)
        }
    }

    // MARK: - Watchers (mirror AgentLatestClient's pattern)

    private func attachFileWatcher() {
        let path = session.inputPath
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
                self.drainNewLines()
            } else {
                self.drainNewLines()
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
            if self.fileSource == nil,
               FileManager.default.fileExists(atPath: self.session.inputPath) {
                self.attachFileWatcher()
            }
            self.drainNewLines()
        }
        source.resume()
        dirSource = source
    }
}
