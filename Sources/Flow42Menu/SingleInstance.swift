// SingleInstance.swift - Refuse to run a second Flow42Menu process.
//
// macOS doesn't enforce single-instance for executables run via `swift run` —
// each invocation is a brand-new process and each registers its own NSStatusItem,
// hence the "multiple bars" effect.
//
// Strategy: write our pid to ~/.flow42/menu.pid at launch. On startup
// check whether that file exists, parse the pid, and `kill -0` it. If the
// existing process is alive, log + exit. Stale pid files are overwritten.

import AppKit
import Flow42Core
import Foundation

@MainActor
enum SingleInstance {

    /// Acquire the single-instance lock or exit the process.
    static func acquireOrExit() {
        let path = pidPath()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        if let existing = readPid(path: path),
           existing != Int(getpid()),
           kill(pid_t(existing), 0) == 0 {
            FileHandle.standardError.write(Data(
                "Flow42Menu already running (pid \(existing)); exiting.\n".utf8
            ))
            exit(0)
        }

        // Stale file or no file — claim it.
        let myPid = String(getpid())
        try? myPid.write(toFile: path, atomically: true, encoding: .utf8)

        // Best-effort cleanup on exit.
        atexit {
            let p = pidPathStatic()
            if let s = try? String(contentsOfFile: p, encoding: .utf8),
               let pidVal = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
               pidVal == Int(getpid()) {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
    }

    private static func readPid(path: String) -> Int? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func pidPath() -> String {
        pidPathStatic()
    }
}

/// Reachable from `atexit` (which can't capture `Self.`).
private func pidPathStatic() -> String {
    Flow42Paths.menuPidFile()
}
