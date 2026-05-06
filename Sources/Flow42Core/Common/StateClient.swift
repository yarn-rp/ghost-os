// StateClient.swift - FSEvents watcher on ~/.flow42/state.json.
//
// Publishes the current `AppState` via Combine `@Published`. Survives the
// file being deleted and recreated (re-arms the watcher on the parent
// directory once the file goes away). The CLI is the only writer; this
// client is read-only.
//
// Lives in Flow42Core because both Flow42Menu (overlays) and Flow42App
// (main window) need it — anywhere we render UI that reflects "what is
// flow42 doing right now", we instantiate a StateClient and bind to its
// `state` property.

import Combine
import Dispatch
import Foundation

@MainActor
public final class StateClient: ObservableObject {

    @Published public private(set) var state: AppState = StateFile.read()

    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var fileFD: CInt = -1
    private var dirFD: CInt = -1

    public init() {
        attachFileWatcher()
        attachDirWatcher()
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
        if fileFD >= 0 { close(fileFD) }
        if dirFD >= 0 { close(dirFD) }
    }

    /// Re-read state.json and notify subscribers. AppState is Equatable, so
    /// we just compare the whole struct — covers any field change.
    private func reload() {
        let next = StateFile.read()
        if next != state {
            Log.info("[StateClient] state changed → derived=\(next.derivedState.rawValue) recording=\(next.recording != nil) play=\(next.play != nil)")
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
