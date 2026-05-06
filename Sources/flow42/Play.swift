// Play.swift - `flow42 play [start] | end | current | next | pause | resume |
//                            wait | show | list | log` CLI.
//
// One namespace, one mental model: a play is a flow execution. Start one
// before issuing any `flow42 do *` calls; end it when finished. The agent's
// canonical loop:
//
//   flow42 play <flow-dir> --by claude --label "..."
//   loop:
//     flow42 play current   → returns the current phase
//     try paths cheapest-first via flow42 do *
//     if success:  flow42 play next   → advance, loop
//     if stuck:    flow42 play pause --reason "..."
//                  flow42 play wait   → blocks until user clicks Resume
//                  retry the phase
//   flow42 play end --reason completed
//
// Singleton invariant: only one session (recording OR play) is active at a
// time. `flow42 play` while a recording is active fails; `flow42 play`
// while another play is active fails. Both errors point at `flow42 stop`.

import Flow42Core
import Foundation

enum Play {

    // MARK: - Top-level dispatch

    static func run(args: [String]) {
        // Bare `flow42 play <flow-dir> [...]` is sugar for `start <flow-dir>`.
        // Anything else (`end`, `current`, `next`, ...) is a subcommand.
        guard let first = args.first else {
            printUsage()
            exit(2)
        }
        let knownSubcommands: Set<String> = [
            "start", "end", "current", "next", "pause", "resume",
            "wait", "show", "list", "log",
            "next-step", "prev-step", "set-step",
            "help", "-h", "--help",
        ]
        if !knownSubcommands.contains(first) {
            // Treat first arg as a flow dir; sugar for `start`.
            runStart(args: args)
            return
        }
        switch first {
        case "start":   runStart(args: Array(args.dropFirst()))
        case "end":     runEnd(args: Array(args.dropFirst()))
        case "current": runCurrent(args: Array(args.dropFirst()))
        case "next":    runNext(args: Array(args.dropFirst()))
        case "pause":   runPause(args: Array(args.dropFirst()))
        case "resume":  runResume(args: Array(args.dropFirst()))
        case "wait":    runWait(args: Array(args.dropFirst()))
        case "show":    runShow(args: Array(args.dropFirst()))
        case "list":    runList(args: Array(args.dropFirst()))
        case "log":     runLog(args: Array(args.dropFirst()))
        case "next-step": runNextStep(args: Array(args.dropFirst()))
        case "prev-step": runPrevStep(args: Array(args.dropFirst()))
        case "set-step":  runSetStep(args: Array(args.dropFirst()))
        default:
            printUsage()
            exit(0)
        }
    }

    // MARK: - start

    private static func runStart(args: [String]) {
        // First positional = flow dir. Flags: --watch, --by, --label.
        var flowDir: String? = nil
        var watch = false
        var by: String? = nil
        var label: String? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--watch": watch = true
            case "--by":    if i + 1 < args.count { by = args[i + 1]; i += 1 }
            case "--label": if i + 1 < args.count { label = args[i + 1]; i += 1 }
            case "--help", "-h":
                printUsage(); return
            default:
                if !a.hasPrefix("-") && flowDir == nil { flowDir = a }
            }
            i += 1
        }
        guard let flowDir else {
            emitJSON([
                "success": false,
                "error": "flow42 play start requires a flow directory",
            ])
            exit(2)
        }
        let dir = expandTilde(flowDir)

        // Singleton guard.
        if let err = StateFile.ensureNothingActive(operation: "flow42 play") {
            emitJSON(["success": false, "error": err])
            exit(1)
        }

        // Validate the flow dir has flow.yaml.
        let flow: PhaseReader.Flow
        do {
            flow = try PhaseReader.load(flowDir: dir)
        } catch {
            emitJSON([
                "success": false,
                "error": "could not load flow: \(error)",
                "flow_dir": dir,
            ])
            exit(1)
        }
        guard !flow.phases.isEmpty else {
            emitJSON([
                "success": false,
                "error": "flow has no phases — nothing to play",
                "flow_dir": dir,
            ])
            exit(1)
        }

        // Build initial position from phase 0.
        let firstStepCount = (flow.phases[0].paths.first { ($0["kind"] as? String) == "gui" }
            .flatMap { $0["steps"] as? [[String: Any]] }?.count) ?? 1
        let position = PlayInfo.Position(
            phaseIndex: 0,
            phaseName: flow.phases[0].name,
            stepIndex: 0,
            totalPhases: flow.phases.count,
            totalStepsInPhase: firstStepCount
        )

        let state: PlayInfo.State = watch ? .watching : .driving
        let startedBy = by ?? "agent"

        let created: (id: String, info: PlayInfo)
        do {
            created = try PlayStore.create(
                flowDir: dir,
                flowName: flow.name,
                state: state,
                startedBy: startedBy,
                label: label,
                pid: Int(getpid()),
                position: position
            )
        } catch {
            emitJSON([
                "success": false,
                "error": "could not create play directory: \(error.localizedDescription)",
            ])
            exit(1)
        }

        // Publish to state.json.
        do {
            try StateFile.write(AppState(play: created.info))
        } catch {
            FileHandle.standardError.write(Data(
                "warning: could not write state.json: \(error.localizedDescription)\n".utf8
            ))
        }

        // Return the first phase right away so the agent can start working
        // without an extra `play current` round trip.
        let payload: [String: Any] = [
            "success": true,
            "play_id": created.id,
            "flow": flow.name,
            "state": state.rawValue,
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "log_path": PlayStore.logPath(flowDir: dir, playId: created.id),
            "position": positionDict(position),
            "phase": phaseDict(flow.phases[0]),
            "params": paramsDict(flow.params),
        ]
        emitJSON(payload)
    }

    // MARK: - end

    private static func runEnd(args: [String]) {
        let flags = parseSimple(args)
        let reason = flags.string("reason") ?? "completed"
        guard let play = StateFile.read().play else {
            emitJSON(["success": true, "note": "no active play"])
            return
        }
        endActive(reason: reason, play: play)
    }

    /// Internal helper used by `runEnd` and by `Stop.run`.
    static func endActive(reason: String, play: PlayInfo) {
        try? PlayStore.end(
            flowDir: play.flowDir, playId: play.id,
            info: play, exitReason: reason
        )
        try? StateFile.clearToIdle()
        emitJSON([
            "success": true,
            "play_id": play.id,
            "exit_reason": reason,
        ])
    }

    // MARK: - current

    private static func runCurrent(args: [String]) {
        guard let play = StateFile.read().play else {
            emitJSON([
                "success": false,
                "error": "no active play",
                "suggestion": "run `flow42 play <flow-dir>` first",
            ])
            exit(1)
        }
        emitPhase(play: play)
    }

    // MARK: - next

    private static func runNext(args: [String]) {
        guard let play = StateFile.read().play else {
            emitJSON([
                "success": false,
                "error": "no active play",
            ])
            exit(1)
        }
        let nextIdx = play.position.phaseIndex + 1
        let flow: PhaseReader.Flow
        do {
            flow = try PhaseReader.load(flowDir: play.flowDir)
        } catch {
            emitJSON([
                "success": false,
                "error": "could not load flow: \(error)",
            ])
            exit(1)
        }
        if nextIdx >= flow.phases.count {
            // Done — return the done signal but DON'T auto-end the play.
            // The agent calls `flow42 play end` explicitly so any
            // last-minute log events still go to this play's log.
            emitJSON([
                "success": true,
                "done": true,
                "note": "no more phases — call `flow42 play end --reason completed` to close out",
            ])
            return
        }
        let phase = flow.phases[nextIdx]
        let stepCount = (phase.paths.first { ($0["kind"] as? String) == "gui" }
            .flatMap { $0["steps"] as? [[String: Any]] }?.count) ?? 1
        let newPos = PlayInfo.Position(
            phaseIndex: nextIdx,
            phaseName: phase.name,
            stepIndex: 0,
            totalPhases: flow.phases.count,
            totalStepsInPhase: stepCount
        )
        let updated: PlayInfo
        do {
            updated = try PlayStore.updatePosition(
                flowDir: play.flowDir, playId: play.id,
                info: play, newPosition: newPos
            )
        } catch {
            emitJSON([
                "success": false,
                "error": "could not write play.yaml: \(error.localizedDescription)",
            ])
            exit(1)
        }
        try? StateFile.write(AppState(play: updated))
        emitJSON([
            "success": true,
            "position": positionDict(newPos),
            "phase": phaseDict(phase),
            "params": paramsDict(flow.params),
        ])
    }

    // MARK: - step navigation (Guide-me mode + floating-panel transport)
    //
    // `flow42 play next` advances PHASES (the agent's primary navigation
    // unit). These three verbs advance STEPS within the current phase,
    // for human-driven guided playback. The model already carries
    // `stepIndex` (PlayInfo.Position.stepIndex); these are the only code
    // paths that mutate it.

    /// Advance one step. If we're on the last step of the phase, falls
    /// through to `runNext()` to roll the phase. The agent should not
    /// call this — the floating panel + Flow42App's Guide-me view do.
    private static func runNextStep(args: [String]) {
        guard let play = StateFile.read().play else {
            emitJSON(["success": false, "error": "no active play"])
            exit(1)
        }
        let pos = play.position
        // Last step in this phase → roll the phase.
        if pos.stepIndex >= pos.totalStepsInPhase - 1 {
            runNext(args: args)
            return
        }
        let newPos = PlayInfo.Position(
            phaseIndex: pos.phaseIndex,
            phaseName: pos.phaseName,
            stepIndex: pos.stepIndex + 1,
            totalPhases: pos.totalPhases,
            totalStepsInPhase: pos.totalStepsInPhase
        )
        commitPositionAndEmit(play: play, newPos: newPos)
    }

    /// Step back one. If we're at step 0, jumps to the previous phase's
    /// last step (loading the prev phase to learn its step count). If
    /// already at phase 0 / step 0, no-op with `success: true`.
    private static func runPrevStep(args: [String]) {
        guard let play = StateFile.read().play else {
            emitJSON(["success": false, "error": "no active play"])
            exit(1)
        }
        let pos = play.position
        if pos.stepIndex > 0 {
            let newPos = PlayInfo.Position(
                phaseIndex: pos.phaseIndex,
                phaseName: pos.phaseName,
                stepIndex: pos.stepIndex - 1,
                totalPhases: pos.totalPhases,
                totalStepsInPhase: pos.totalStepsInPhase
            )
            commitPositionAndEmit(play: play, newPos: newPos)
            return
        }
        // At step 0 — try to roll back to the previous phase's last step.
        let prevIdx = pos.phaseIndex - 1
        if prevIdx < 0 {
            // Already at the very start — no-op.
            emitJSON([
                "success": true,
                "noop": true,
                "note": "already at the first step of the first phase",
                "position": positionDict(pos),
            ])
            return
        }
        let flow: PhaseReader.Flow
        do {
            flow = try PhaseReader.load(flowDir: play.flowDir)
        } catch {
            emitJSON(["success": false, "error": "could not load flow: \(error)"])
            exit(1)
        }
        let prevPhase = flow.phases[prevIdx]
        let prevStepCount = (prevPhase.paths.first { ($0["kind"] as? String) == "gui" }
            .flatMap { $0["steps"] as? [[String: Any]] }?.count) ?? 1
        let newPos = PlayInfo.Position(
            phaseIndex: prevIdx,
            phaseName: prevPhase.name,
            stepIndex: max(0, prevStepCount - 1),
            totalPhases: flow.phases.count,
            totalStepsInPhase: prevStepCount
        )
        commitPositionAndEmit(play: play, newPos: newPos)
    }

    /// Direct jump to a specific step within the current phase.
    /// `--index N` is clamped to [0, totalStepsInPhase - 1]. Used by the
    /// floating panel's list-mode "scrub to step" affordance.
    private static func runSetStep(args: [String]) {
        let flags = parseSimple(args)
        guard let idxStr = flags.string("index"),
              let idx = Int(idxStr) else {
            emitJSON([
                "success": false,
                "error": "flow42 play set-step requires --index <N>",
            ])
            exit(2)
        }
        guard let play = StateFile.read().play else {
            emitJSON(["success": false, "error": "no active play"])
            exit(1)
        }
        let pos = play.position
        let clamped = max(0, min(idx, max(0, pos.totalStepsInPhase - 1)))
        let newPos = PlayInfo.Position(
            phaseIndex: pos.phaseIndex,
            phaseName: pos.phaseName,
            stepIndex: clamped,
            totalPhases: pos.totalPhases,
            totalStepsInPhase: pos.totalStepsInPhase
        )
        commitPositionAndEmit(play: play, newPos: newPos)
    }

    /// Common write path for the three step verbs above. Persists the
    /// new position to play.yaml + state.json, appends a `position` event
    /// to log.jsonl, then emits the new phase content (same shape as
    /// `flow42 play current`) so callers can render immediately without
    /// a follow-up read.
    private static func commitPositionAndEmit(play: PlayInfo, newPos: PlayInfo.Position) {
        let updated: PlayInfo
        do {
            updated = try PlayStore.updatePosition(
                flowDir: play.flowDir, playId: play.id,
                info: play, newPosition: newPos
            )
        } catch {
            emitJSON([
                "success": false,
                "error": "could not write play.yaml: \(error.localizedDescription)",
            ])
            exit(1)
        }
        try? StateFile.write(AppState(play: updated))
        emitPhase(play: updated)
    }

    // MARK: - pause / resume / wait

    private static func runPause(args: [String]) {
        let flags = parseSimple(args)
        guard let reason = flags.string("reason"), !reason.isEmpty else {
            emitJSON([
                "success": false,
                "error": "flow42 play pause requires --reason \"<one line>\"",
            ])
            exit(2)
        }
        guard let play = StateFile.read().play else {
            emitJSON(["success": false, "error": "no active play"])
            exit(1)
        }
        let pause = PlayInfo.PauseInfo(
            reason: reason,
            pausedAt: ISO8601DateFormatter().string(from: Date()),
            pausedBy: .agent
        )
        let updated: PlayInfo
        do {
            updated = try PlayStore.updatePause(
                flowDir: play.flowDir, playId: play.id,
                info: play, pause: pause
            )
        } catch {
            emitJSON([
                "success": false,
                "error": "could not write play.yaml: \(error.localizedDescription)",
            ])
            exit(1)
        }
        try? StateFile.write(AppState(play: updated))
        emitJSON([
            "success": true,
            "state": "watching",
            "pause": [
                "reason": pause.reason,
                "paused_at": pause.pausedAt,
                "paused_by": pause.pausedBy.rawValue,
            ] as [String: Any],
        ])
    }

    private static func runResume(args: [String]) {
        guard let play = StateFile.read().play else {
            emitJSON(["success": false, "error": "no active play"])
            exit(1)
        }
        guard play.pause != nil else {
            emitJSON(["success": true, "note": "play was not paused"])
            return
        }
        let updated: PlayInfo
        do {
            updated = try PlayStore.updatePause(
                flowDir: play.flowDir, playId: play.id,
                info: play, pause: nil
            )
        } catch {
            emitJSON([
                "success": false,
                "error": "could not write play.yaml: \(error.localizedDescription)",
            ])
            exit(1)
        }
        try? StateFile.write(AppState(play: updated))
        emitJSON(["success": true, "state": "driving"])
    }

    /// Block until the play is no longer paused (state == driving) or until
    /// it ends. Polls state.json every 250 ms.
    private static func runWait(args: [String]) {
        let flags = parseSimple(args)
        let timeout = flags.int("timeout").map(TimeInterval.init)
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            let state = StateFile.read()
            guard let play = state.play else {
                emitJSON([
                    "success": true,
                    "state": "ended",
                    "exit_reason": "user_stopped",
                ])
                return
            }
            if play.pause == nil, play.state == .driving {
                emitJSON(["success": true, "state": "driving"])
                return
            }
            if let deadline, Date() >= deadline {
                emitJSON([
                    "success": false,
                    "error": "timeout",
                ])
                exit(1)
            }
            usleep(250_000)
        }
    }

    // MARK: - show / list / log

    private static func runShow(args: [String]) {
        let id = args.first
        let play = StateFile.read().play
        if let id {
            // Look up by id — need flow_dir. If state.play matches, use
            // its flow_dir; otherwise scan all flows for a matching id.
            // (List operation; rare, OK to be O(n).)
            if let p = play, p.id == id {
                printShow(flowDir: p.flowDir, playId: id)
                return
            }
            emitJSON([
                "success": false,
                "error": "no active play with id \(id); pass via active play or use `flow42 play list <flow-dir>`",
            ])
            exit(1)
        }
        guard let p = play else {
            emitJSON(["success": false, "error": "no active play"])
            exit(1)
        }
        printShow(flowDir: p.flowDir, playId: p.id)
    }

    private static func printShow(flowDir: String, playId: String) {
        let yaml = (try? String(
            contentsOf: URL(fileURLWithPath: PlayStore.playYamlPath(
                flowDir: flowDir, playId: playId
            )), encoding: .utf8
        )) ?? "(missing)"
        let logPath = PlayStore.logPath(flowDir: flowDir, playId: playId)
        let logTail = (try? String(
            contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8
        ))?.split(separator: "\n").suffix(50).joined(separator: "\n") ?? "(empty)"

        print("=== play.yaml ===")
        print(yaml)
        print("\n=== log.jsonl (last 50 lines) ===")
        print(logTail)
    }

    private static func runList(args: [String]) {
        guard let flowDir = args.first.map(expandTilde) else {
            emitJSON([
                "success": false,
                "error": "flow42 play list requires a flow directory",
            ])
            exit(2)
        }
        let ids = PlayStore.list(flowDir: flowDir)
        emitJSON([
            "success": true,
            "flow_dir": flowDir,
            "plays": ids,
        ])
    }

    private static func runLog(args: [String]) {
        guard let eventType = args.first else {
            emitJSON([
                "success": false,
                "error": "flow42 play log requires an event type",
            ])
            exit(2)
        }
        let flags = parseSimple(Array(args.dropFirst()))
        guard let play = StateFile.read().play else {
            emitJSON(["success": false, "error": "no active play"])
            exit(1)
        }
        var event: [String: Any] = [
            "type": eventType,
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        // Copy through every --key value pair the user passed.
        for (k, v) in flags.allString { event[k] = v }
        do {
            try PlayStore.appendLog(
                flowDir: play.flowDir, playId: play.id, event: event
            )
            emitJSON(["success": true, "logged": event])
        } catch {
            emitJSON([
                "success": false,
                "error": "log failed: \(error.localizedDescription)",
            ])
            exit(1)
        }
    }

    // MARK: - Phase / param helpers shared by start, current, next

    private static func emitPhase(play: PlayInfo) {
        do {
            let result = try PhaseReader.phaseAt(
                flowDir: play.flowDir,
                index: play.position.phaseIndex,
                stepIndex: play.position.stepIndex
            )
            emitJSON([
                "success": true,
                "position": positionDict(result.position),
                "phase": phaseDict(result.phase),
                "params": result.params,
            ])
        } catch {
            emitJSON([
                "success": false,
                "error": "could not read phase: \(error)",
            ])
            exit(1)
        }
    }

    private static func phaseDict(_ phase: PhaseReader.Phase) -> [String: Any] {
        var dict: [String: Any] = [
            "name": phase.name,
            "intent": phase.intent,
            "paths": phase.paths,
        ]
        if let p = phase.precondition { dict["precondition"] = p }
        if let p = phase.postcondition { dict["postcondition"] = p }
        if let n = phase.note { dict["note"] = n }
        return dict
    }

    private static func positionDict(_ p: PlayInfo.Position) -> [String: Any] {
        [
            "phase_index": p.phaseIndex,
            "phase_name": p.phaseName,
            "step_index": p.stepIndex,
            "total_phases": p.totalPhases,
            "total_steps_in_phase": p.totalStepsInPhase,
        ]
    }

    private static func paramsDict(
        _ params: [(name: String, description: String, type: String, example: String)]
    ) -> [String: String] {
        var out: [String: String] = [:]
        for p in params { out[p.name] = p.example }
        return out
    }

    // MARK: - Misc

    private static func expandTilde(_ p: String) -> String {
        p.hasPrefix("~") ? NSString(string: p).expandingTildeInPath : p
    }

    private static func printUsage() {
        let msg = """
        Usage:
          flow42 play <flow-dir> [--watch] [--by <agent>] [--label "..."]
                                    Open a play (default: driving). Sugar for
                                    `flow42 play start <flow-dir>`.
          flow42 play start <flow-dir> [--watch] [--by <agent>] [--label "..."]
          flow42 play end [--reason completed|user_stopped|agent_stopped]
          flow42 play current        Print the current phase only (the agent's
                                     primary read surface — never read flow.yaml
                                     directly during a play).
          flow42 play next           Advance to the next phase. Returns the new
                                     phase, or {done: true} if no phases remain.
          flow42 play next-step      Advance one STEP within the current phase.
                                     Rolls to the next phase at the last step.
                                     Used by Guide-me mode + the floating
                                     panel's transport buttons (not by agents).
          flow42 play prev-step      Step back one. Falls back to the previous
                                     phase's last step at step 0.
          flow42 play set-step --index N
                                     Direct jump to step N within the current
                                     phase (clamped to range).
          flow42 play pause --reason "<one line>"
                                     Hand off to the user. The play flips to
                                     watching and the floating window shows
                                     the reason + a Resume button.
          flow42 play resume         Flip back to driving.
          flow42 play wait [--timeout SECS]
                                     Block until the play is no longer paused
                                     or until it ends.
          flow42 play show [<id>]    Print play.yaml + log tail.
          flow42 play list <flow-dir>
          flow42 play log <event_type> [--key value ...]

        Singleton invariant: only one session (recording OR play) is active at
        a time. Use `flow42 stop` to end whichever is active.
        """
        print(msg)
    }
}

// MARK: - CliFlags helper

private extension CliFlags {
    /// Iterate every --key value pair the user passed (string-typed).
    /// Used by `flow42 play log` to forward arbitrary key/value pairs into
    /// the appended event without a fixed schema.
    var allString: [(String, String)] {
        Array(map.map { ($0.key, $0.value) })
    }
}
