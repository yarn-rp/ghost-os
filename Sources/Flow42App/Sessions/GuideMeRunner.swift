// GuideMeRunner.swift - Orchestrate "Guide me" walkthrough mode.
//
// Behaviour:
//   1. Singleton check (no other recording / play active).
//   2. `flow42 play <dir> --watch --label "<name> (guided)"` — opens the
//      play in cyan watching mode. The menu app's overlays + floating
//      panel appear automatically (existing wiring).
//   3. The main app's UI surfaces a guided walkthrough panel: large
//      screenshot, step text, Prev / Next / Stop. Next calls
//      `flow42 play next-step` (the verb we just shipped); Prev calls
//      `flow42 play prev-step`. State updates flow back via StateClient
//      → both the floating panel and our walkthrough re-render in
//      lockstep.
//   4. Stop calls `flow42 stop` and dismisses the walkthrough.
//
// No agent, no skill injection. Pure user-driven playback. Once we have
// agent-assist for guided mode (v2), this becomes the surface where the
// agent can chime in with hints — same UI, more help.

import AppKit
import Flow42Core
import Foundation

@MainActor
final class GuideMeRunner {

    enum LaunchError: Error, CustomStringConvertible {
        case anotherSessionActive(detail: String)
        case playStartFailed(detail: String)

        var description: String {
            switch self {
            case .anotherSessionActive(let d):
                return "Another flow42 session is already active. \(d)"
            case .playStartFailed(let d):
                return "Couldn't start the guided play: \(d)"
            }
        }
    }

    /// Start a guided play. Returns the play_id on success.
    @discardableResult
    func start(flow: FlowSummary) throws -> String {
        let state = StateFile.read()
        if let recording = state.recording {
            throw LaunchError.anotherSessionActive(
                detail: "Recording '\(recording.slug)' is in progress."
            )
        }
        if let play = state.play {
            throw LaunchError.anotherSessionActive(
                detail: "Play '\(play.id)' is already active."
            )
        }
        return try shellPlayStart(flow: flow)
    }

    /// Advance one step. No-op (silently returns false) if there's no
    /// active play — the StateClient will reflect the truth either way.
    @discardableResult
    func nextStep() -> Bool {
        runFlow42(args: ["play", "next-step"])
    }

    /// Step back one. No-op at the very first step.
    @discardableResult
    func prevStep() -> Bool {
        runFlow42(args: ["play", "prev-step"])
    }

    /// End the walkthrough. Same `flow42 stop` the menu's universal stop
    /// uses — agnostic to whether a recording or a play is active.
    @discardableResult
    func stop() -> Bool {
        runFlow42(args: ["stop"])
    }

    // MARK: - Shell-out

    private func shellPlayStart(flow: FlowSummary) throws -> String {
        guard let cli = Flow42CLI.binaryPath() else {
            throw LaunchError.playStartFailed(detail: "could not locate flow42 binary")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cli)
        task.arguments = [
            "play", flow.directory,
            "--watch",
            "--by", "user",
            "--label", "\(flow.displayName) (guided)",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
        } catch {
            throw LaunchError.playStartFailed(detail: "\(error)")
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let err = (try? stderr.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? (try? stdout.fileHandleForReading.readToEnd())
                    .flatMap { String(data: $0, encoding: .utf8) }
                ?? "unknown error"
            throw LaunchError.playStartFailed(detail: err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        if let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
           let id = json["play_id"] as? String {
            return id
        }
        return StateFile.read().play?.id ?? "unknown"
    }

    @discardableResult
    private func runFlow42(args: [String]) -> Bool {
        guard let cli = Flow42CLI.binaryPath() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cli)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
