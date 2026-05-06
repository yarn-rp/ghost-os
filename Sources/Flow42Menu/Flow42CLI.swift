// Flow42CLI.swift - Locate and invoke the bundled `flow42` CLI binary.
//
// Resolution order:
//   1. Inside Flow42.app:  Contents/Resources/bin/flow42
//   2. Dev build:          .build/debug/flow42 walked up from this binary
//   3. PATH:                command -v flow42
//   4. Common Homebrew:    /usr/local/bin/flow42, /opt/homebrew/bin/flow42

import AppKit
import Foundation

enum Flow42CLI {

    /// Resolve the absolute path to the `flow42` binary, or nil if we can't
    /// find it anywhere reasonable.
    nonisolated static func binaryPath() -> String? {
        let fm = FileManager.default

        // 1. Bundled inside the .app
        if let bundleResources = Bundle.main.resourceURL {
            let candidate = bundleResources
                .appendingPathComponent("bin")
                .appendingPathComponent("flow42")
                .path
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }

        // 2. Walk up from the running menu binary to find a sibling .build
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            for variant in ["debug", "release"] {
                let candidate = dir
                    .appendingPathComponent(".build")
                    .appendingPathComponent(variant)
                    .appendingPathComponent("flow42")
                    .path
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
            // Also check siblings in the same .build dir
            let sibling = dir.appendingPathComponent("flow42").path
            if fm.isExecutableFile(atPath: sibling) { return sibling }
            dir = dir.deletingLastPathComponent()
        }

        // 3. PATH
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v flow42"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        if (try? task.run()) != nil {
            task.waitUntilExit()
            if task.terminationStatus == 0,
               let data = try? out.fileHandleForReading.readToEnd(),
               let path = String(data: data ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 4. Common Homebrew fallbacks
        for cand in ["/usr/local/bin/flow42", "/opt/homebrew/bin/flow42"] {
            if fm.isExecutableFile(atPath: cand) { return cand }
        }

        return nil
    }

    /// Run `flow42 <args>` and return the parsed JSON line on success.
    /// Errors land on stderr; nil return = command failed.
    ///
    /// SYNCHRONOUS — busy-waits the calling thread. Acceptable for short
    /// commands (`flow42 record start`, `flow42 mode set`, etc.) but NOT
    /// for `flow42 record stop`, which can block 1–60s on whisper
    /// transcription. UI handlers should use `runAsync` instead so the
    /// main run loop stays free.
    @discardableResult
    nonisolated static func run(_ args: [String], timeout: TimeInterval = 10) -> [String: Any]? {
        guard let path = binaryPath() else {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] flow42 binary not found on PATH or in bundle\n".utf8
            ))
            return nil
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] failed to spawn flow42: \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
        // Best-effort timeout — kill if it goes long.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            return nil
        }

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let line = outStr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        guard let lineData = line.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
        else { return nil }
        return dict
    }

    /// Async variant: spawn `flow42 <args>` and await its termination on a
    /// background queue (`Process.terminationHandler`), without ever
    /// blocking the calling thread. Use this from any UI handler — it
    /// keeps the popover live (animations, scrolling, the timeline
    /// tailer) while a long stop / finalize is running.
    ///
    /// Timeout: scheduled as a separate task; on expiry we send SIGTERM
    /// and the terminationHandler still fires (with a non-zero exit
    /// status) so the continuation always resolves exactly once.
    nonisolated static func runAsync(
        _ args: [String],
        timeout: TimeInterval = 65
    ) async -> [String: Any]? {
        guard let path = binaryPath() else {
            FileHandle.standardError.write(Data(
                "[Flow42Menu] flow42 binary not found on PATH or in bundle\n".utf8
            ))
            return nil
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        // Box for the resume side so the timeout task can mark "fired"
        // and the terminationHandler can dedupe. CheckedContinuation
        // already traps double-resume in debug; this is the belt.
        final class ResumeGate: @unchecked Sendable {
            private var fired = false
            private let lock = NSLock()
            func tryFire() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if fired { return false }
                fired = true
                return true
            }
        }
        let gate = ResumeGate()

        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            task.terminationHandler = { _ in
                guard gate.tryFire() else { return }
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let line = outStr
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .last
                    .map(String.init) ?? ""
                let dict: [String: Any]? = line.data(using: .utf8).flatMap {
                    (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                }
                cont.resume(returning: dict)
            }

            do {
                try task.run()
            } catch {
                guard gate.tryFire() else { return }
                FileHandle.standardError.write(Data(
                    "[Flow42Menu] failed to spawn flow42: \(error.localizedDescription)\n".utf8
                ))
                cont.resume(returning: nil)
                return
            }

            // Best-effort timeout. If it fires first, terminate the
            // child; the terminationHandler then resolves the
            // continuation with whatever (likely partial) output is on
            // stdout. The gate prevents a duplicate resume.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if task.isRunning {
                    task.terminate()
                }
            }
        }
    }
}
