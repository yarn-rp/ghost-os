// StateClient.swift - FSEvents watcher on ~/.openclaw/flow42/state.json.
//
// Publishes the current AppMode as an `AsyncStream`. Survives the file being
// deleted and recreated (re-arms the watcher on the parent directory once the
// file goes away). The CLI is the only writer; this client is read-only.

import Combine
import Dispatch
import Flow42Core
import Foundation

@MainActor
final class StateClient: ObservableObject {

    @Published private(set) var state: AppState = StateFile.read()

    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var fileFD: CInt = -1
    private var dirFD: CInt = -1

    init() {
        attachFileWatcher()
        attachDirWatcher()
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        if fileFD >= 0 { close(fileFD) }
        if dirFD >= 0 { close(dirFD) }
    }

    /// Re-read state.json and notify subscribers.
    private func reload() {
        let next = StateFile.read()
        if next.mode != state.mode || next.label != state.label || next.since != state.since {
            state = next
        }
    }

    private func attachFileWatcher() {
        let path = StateFile.path()
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
                // Wait for the parent-dir watcher to re-create.
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
        let dir = (StateFile.path() as NSString).deletingLastPathComponent
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
            // The state file may have just been (re)created. Try to re-arm
            // the file-level watcher.
            if self.fileSource == nil,
               FileManager.default.fileExists(atPath: StateFile.path()) {
                self.attachFileWatcher()
            }
            self.reload()
        }
        source.resume()
        dirSource = source
    }
}
