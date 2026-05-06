// CLIRunner.swift - Locate and invoke the bundled `flow42` CLI binary
// from the main Flow42App. Mirrors Flow42Menu/Flow42CLI.swift exactly so
// both surfaces talk to the same daemon via the same arg shapes.
//
// This is intentionally a tiny duplicate rather than a shared module:
// dragging the menu's CLI dispatcher into Flow42Core would force Core to
// take an AppKit dependency and pull the menu's process-management
// quirks into every consumer (CLI, MCP server). Two ~100-line files are
// cheaper than the entanglement.

import AppKit
import Foundation

enum CLIRunner {

    /// Resolve the absolute path to the `flow42` binary, or nil if we
    /// can't find it anywhere reasonable. Search order:
    ///   1. Bundled inside Flow42.app:  Contents/Resources/bin/flow42
    ///   2. Dev build:                  walk up from this binary to .build/<variant>/flow42
    ///   3. PATH:                       command -v flow42
    ///   4. Common Homebrew:            /usr/local/bin/flow42, /opt/homebrew/bin/flow42
    nonisolated static func binaryPath() -> String? {
        let fm = FileManager.default

        if let bundleResources = Bundle.main.resourceURL {
            let candidate = bundleResources
                .appendingPathComponent("bin")
                .appendingPathComponent("flow42")
                .path
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }

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
            let sibling = dir.appendingPathComponent("flow42").path
            if fm.isExecutableFile(atPath: sibling) { return sibling }
            dir = dir.deletingLastPathComponent()
        }

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

        for cand in ["/usr/local/bin/flow42", "/opt/homebrew/bin/flow42"] {
            if fm.isExecutableFile(atPath: cand) { return cand }
        }

        return nil
    }

    /// Spawn `flow42 <args>` and resolve when the child exits. Never
    /// blocks the caller's thread. Returns the parsed last JSON line on
    /// stdout, or nil on spawn / parse / timeout failure.
    nonisolated static func runAsync(
        _ args: [String],
        timeout: TimeInterval = 30
    ) async -> [String: Any]? {
        guard let path = binaryPath() else {
            FileHandle.standardError.write(Data(
                "[Flow42App] flow42 binary not found on PATH or in bundle\n".utf8
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

        final class Gate: @unchecked Sendable {
            private var fired = false
            private let lock = NSLock()
            func tryFire() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if fired { return false }
                fired = true
                return true
            }
        }
        let gate = Gate()

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
                cont.resume(returning: nil)
                return
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if task.isRunning { task.terminate() }
            }
        }
    }
}
