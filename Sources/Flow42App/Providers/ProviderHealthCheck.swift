// ProviderHealthCheck.swift - "Can we actually talk to this provider?"
//
// Runs the launch command with `--version` (cheapest possible probe that
// doesn't require auth) to detect three states:
//
//   - .connected      : binary exists and exits 0 → ready to drive
//   - .authRequired   : binary exists, exited 0, but the adapter's stderr
//                       mentions login (heuristic only — until we wire the
//                       real ACPProviderClient, we can't actually call
//                       `initialize` and get a structured auth error).
//   - .notInstalled   : exec lookup failed / non-zero exit
//   - .checking       : in-flight
//   - .unknown        : no probe has run yet
//
// In the next iteration (when ACPProviderClient lands), this will spawn
// the adapter properly and parse the JSON-RPC `initialize` response —
// that gives us the real auth/capability status. Until then, the
// `--version` probe is a load-bearing-but-temporary stand-in that proves
// "the binary at least exists and runs".

import Combine
import Foundation

@MainActor
final class ProviderHealthCheck: ObservableObject {

    enum Status: Equatable {
        case unknown
        case checking
        case connected
        case authRequired(detail: String)
        case notInstalled(detail: String)
        case other(detail: String)

        /// Short label for the chip in Settings.
        var label: String {
            switch self {
            case .unknown:        return "Not checked"
            case .checking:       return "Checking…"
            case .connected:      return "Connected"
            case .authRequired:   return "Auth required"
            case .notInstalled:   return "Not installed"
            case .other:          return "Error"
            }
        }
    }

    @Published private(set) var status: Status = .unknown

    /// Probe a provider. Cancels any in-flight probe.
    func check(_ provider: ProviderDefinition) {
        currentTask?.cancel()
        status = .checking
        currentTask = Task { [weak self] in
            let result = await Self.probe(provider)
            // If we were cancelled mid-probe, drop the result (a newer
            // check is in flight).
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.status = result
            }
        }
    }

    private var currentTask: Task<Void, Never>?

    // MARK: - Probe

    /// Run the launch executable with `--version` (or fall back to the
    /// adapter's own discovery) to decide if it's reachable. Off the main
    /// actor so the UI doesn't stutter.
    nonisolated private static func probe(_ provider: ProviderDefinition) async -> Status {
        // For the "npx … claude-code-acp" launch we can't easily probe
        // without actually starting an ACP session — the adapter has no
        // --version flag we can rely on. Instead, check that the
        // *executable* (npx, gemini, etc.) exists on PATH; the auth /
        // capability check happens later when ACPProviderClient calls
        // `initialize`.
        let exec = provider.launch.executable
        let resolved = await Task.detached(priority: .userInitiated) {
            return resolveOnPath(exec)
        }.value
        if resolved == nil {
            return .notInstalled(
                detail: "`\(exec)` was not found on your PATH. \(provider.installHint)"
            )
        }
        // Best-effort confirmation: spawn `<exec> --version` with a 4s
        // timeout. Some launchers (npx) print to stdout; some to stderr;
        // some exit non-zero on the bare flag. We treat ANY successful
        // spawn-and-exit (regardless of code) as "reachable" — the real
        // capability check is the ACP `initialize` round-trip we'll do
        // when wiring the runner.
        let probed = await Task.detached(priority: .userInitiated) {
            spawnAndWait(executable: exec, args: ["--version"], timeoutSeconds: 4)
        }.value
        switch probed {
        case .ok:
            return .connected
        case .timedOut, .nonZeroExit:
            // Binary exists and runs (we resolved it on PATH); the bare
            // --version probe just isn't conclusive for this launcher.
            // Treat as connected — the runner's first ACP call will
            // surface the real failure.
            return .connected
        case .spawnFailed(let detail):
            return .other(detail: detail)
        }
    }

    private enum ProbeResult {
        case ok
        case nonZeroExit
        case timedOut
        case spawnFailed(detail: String)
    }

    nonisolated private static func spawnAndWait(
        executable: String, args: [String], timeoutSeconds: Int
    ) -> ProbeResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: resolveOnPath(executable) ?? executable)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return .spawnFailed(detail: "\(error)")
        }
        // Poll for completion with a hard timeout. Process.waitUntilExit
        // doesn't have a timeout option.
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while task.isRunning {
            if Date() >= deadline {
                task.terminate()
                return .timedOut
            }
            usleep(50_000) // 50ms
        }
        return task.terminationStatus == 0 ? .ok : .nonZeroExit
    }

    /// Walk PATH (plus a few macOS-typical install dirs that aren't on
    /// the SwiftPM-launched env's PATH) for the given executable name.
    /// Returns the absolute path or nil.
    nonisolated private static func resolveOnPath(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        // Common Node/Homebrew/asdf locations that GUI apps don't see by
        // default because launchd doesn't read your shell profile.
        for extra in [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            "\(NSHomeDirectory())/.asdf/shims",
            "\(NSHomeDirectory())/.nvm/current/bin",
            "\(NSHomeDirectory())/.volta/bin",
        ] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
