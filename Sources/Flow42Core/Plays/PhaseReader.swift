// PhaseReader.swift - Parses <flow-dir>/flow.yaml and serves single phases.
//
// `flow42 play current` and the menu app's PlayPanel both want the same
// thing: "give me phase N, with params resolved." This is the only reader
// for flow.yaml in the codebase — agents are explicitly forbidden from
// reading flow.yaml directly during a play (they go through `play current`
// so the on-screen panel and the agent's view agree on which phase is
// active).
//
// Yams is the parser. We don't validate the schema beyond what's needed to
// extract a phase — invalid flow.yaml is the agent's bug, not ours.

import Foundation
import Yams

public enum PhaseReader {

    public struct Phase: Sendable {
        public let name: String
        public let intent: String
        public let precondition: String?
        public let postcondition: String?
        public let note: String?
        public let paths: [[String: Any]]

        public init(
            name: String, intent: String,
            precondition: String?, postcondition: String?,
            note: String?, paths: [[String: Any]]
        ) {
            self.name = name
            self.intent = intent
            self.precondition = precondition
            self.postcondition = postcondition
            self.note = note
            self.paths = paths
        }

        // The phase is `Sendable` even though `paths` is `[[String: Any]]`
        // because the agent's CLI immediately serialises it back to JSON for
        // emission — the structured form never leaves the originating actor.
        // Mark as `@unchecked Sendable`-via-extension below if Swift 6.2's
        // strict concurrency complains.
    }

    public struct Flow: Sendable {
        public let name: String
        public let taskDescription: String?
        public let recordedAt: String?
        public let durationSeconds: Int?
        public let params: [(name: String, description: String, type: String, example: String)]
        public let phases: [Phase]
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case fileMissing(String)
        case unreadable(String)
        case invalidYaml(String)
        case malformed(String)
        case phaseOutOfRange(Int, Int)

        public var description: String {
            switch self {
            case .fileMissing(let p): return "flow.yaml not found at \(p)"
            case .unreadable(let p):  return "could not read flow.yaml at \(p)"
            case .invalidYaml(let m): return "flow.yaml is not valid YAML: \(m)"
            case .malformed(let m):   return "flow.yaml is malformed: \(m)"
            case .phaseOutOfRange(let i, let total):
                return "phase index \(i) out of range (flow has \(total) phases)"
            }
        }
    }

    /// Load and parse a flow's flow.yaml. Throws on missing / invalid file.
    public static func load(flowDir: String) throws -> Flow {
        let path = (flowDir as NSString).appendingPathComponent("flow.yaml")
        guard FileManager.default.fileExists(atPath: path) else {
            throw Error.fileMissing(path)
        }
        guard let text = try? String(
            contentsOf: URL(fileURLWithPath: path), encoding: .utf8
        ) else {
            throw Error.unreadable(path)
        }
        let parsed: Any?
        do {
            parsed = try Yams.load(yaml: text)
        } catch {
            throw Error.invalidYaml(error.localizedDescription)
        }
        guard let dict = parsed as? [String: Any] else {
            throw Error.malformed("top-level must be a mapping")
        }

        let name = (dict["name"] as? String) ?? ""
        let taskDescription = dict["task_description"] as? String
        let recordedAt = dict["recorded_at"] as? String
        let durationSeconds = dict["duration_seconds"] as? Int

        var params: [(name: String, description: String, type: String, example: String)] = []
        if let paramsRaw = dict["params"] as? [[String: Any]] {
            for p in paramsRaw {
                params.append((
                    name: (p["name"] as? String) ?? "",
                    description: (p["description"] as? String) ?? "",
                    type: (p["type"] as? String) ?? "string",
                    example: (p["example"] as? String) ?? ""
                ))
            }
        }

        var phases: [Phase] = []
        if let phasesRaw = dict["phases"] as? [[String: Any]] {
            for p in phasesRaw {
                phases.append(Phase(
                    name: (p["name"] as? String) ?? "",
                    intent: (p["intent"] as? String) ?? "",
                    precondition: p["precondition"] as? String,
                    postcondition: p["postcondition"] as? String,
                    note: p["note"] as? String,
                    paths: (p["paths"] as? [[String: Any]]) ?? []
                ))
            }
        }

        return Flow(
            name: name,
            taskDescription: taskDescription,
            recordedAt: recordedAt,
            durationSeconds: durationSeconds,
            params: params,
            phases: phases
        )
    }

    /// Return the phase at `index`, plus the resolved params dict and the
    /// position summary suitable for `flow42 play current` JSON output.
    public static func phaseAt(
        flowDir: String,
        index: Int,
        stepIndex: Int = 0
    ) throws -> (
        phase: Phase,
        params: [String: String],
        position: PlayInfo.Position
    ) {
        let flow = try load(flowDir: flowDir)
        guard index >= 0, index < flow.phases.count else {
            throw Error.phaseOutOfRange(index, flow.phases.count)
        }
        let phase = flow.phases[index]
        var params: [String: String] = [:]
        for p in flow.params {
            params[p.name] = p.example
        }
        // Step count for the current phase: count `gui` steps if a gui
        // path exists; otherwise 1 (a non-gui phase has no per-step nav).
        let totalSteps = (phase.paths.first { ($0["kind"] as? String) == "gui" }
            .flatMap { $0["steps"] as? [[String: Any]] }?.count) ?? 1
        let position = PlayInfo.Position(
            phaseIndex: index,
            phaseName: phase.name,
            stepIndex: max(0, min(stepIndex, totalSteps - 1)),
            totalPhases: flow.phases.count,
            totalStepsInPhase: totalSteps
        )
        return (phase, params, position)
    }
}

// MARK: - Sendable opt-in for Phase (paths is [[String: Any]])

extension PhaseReader.Phase: @unchecked Sendable {}
