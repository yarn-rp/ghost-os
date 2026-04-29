// Record.swift - `flow42 record` CLI subcommand
//
// Drives LearningRecorder with a per-session recording directory, blocks
// until the user hits Ctrl-C, and writes flow.json to disk so an agent
// can pick the recording up.
//
// Recording dir layout:
//   ~/.openclaw/flow42/recipes/<slug>/
//     flow.json           — task metadata + serialized actions
//     screenshots/        — populated by LearningScreenshot per click

import Darwin
import Dispatch
import Flow42Core
import Foundation

enum Record {

    static func run(args: [String]) {
        let description = parseDescription(args)
        let slug = makeSlug()
        let dir = recipesRoot().appendingPathComponent(slug).path

        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("error: failed to create \(dir): \(error)\n", stderr)
            exit(1)
        }

        let recorder = LearningRecorder.shared
        if let err = recorder.start(taskDescription: description, recordingDir: dir) {
            fputs("error: \(err.localizedDescription)\n", stderr)
            fputs("       \(err.suggestion)\n", stderr)
            exit(1)
        }

        print("Recording → \(dir)")
        if let description {
            print("Task: \(description)")
        }
        print("Type `done` and press Enter to stop.")

        // Block on stdin. readLine() returns when the user hits Enter; we
        // loop until they type `done` (case-insensitive, whitespace-trimmed).
        // Empty/EOF input also stops so closing the terminal doesn't hang.
        while true {
            guard let line = readLine() else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "done" || trimmed == "stop" || trimmed == "q" || trimmed == "quit" {
                break
            }
            print("(type `done` to stop)")
        }

        // Stop, serialise, and persist.
        switch recorder.stop() {
        case .failure(let error):
            fputs("\nerror: \(error.localizedDescription)\n", stderr)
            exit(1)
        case .success(let (session, actions)):
            let duration = Date().timeIntervalSince(session.startTime)
            let payload: [String: Any] = [
                "schema_version": 1,
                "platform": "mac",
                "slug": slug,
                "task_description": session.taskDescription ?? "",
                "recorded_at": ISO8601DateFormatter().string(from: session.startTime),
                "duration_seconds": Int(duration),
                "action_count": actions.count,
                "apps": Array(session.apps),
                "urls": session.urls,
                "actions": actions.map { LearningDispatch.serializeAction($0) },
            ]

            let flowPath = (dir as NSString).appendingPathComponent("flow.json")
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                try data.write(to: URL(fileURLWithPath: flowPath))
            } catch {
                fputs("\nerror: failed to write flow.json: \(error)\n", stderr)
                exit(1)
            }

            // Stdout-friendly result for callers that pipe us.
            let result: [String: Any] = [
                "path": dir,
                "slug": slug,
                "action_count": actions.count,
            ]
            if let json = try? JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            ),
               let str = String(data: json, encoding: .utf8) {
                print("\n\(str)")
            }
        }
    }

    // MARK: - Helpers

    private static func parseDescription(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--description", "-d":
                if i + 1 < args.count {
                    return args[i + 1]
                }
                return nil
            default:
                break
            }
            i += 1
        }
        return nil
    }

    private static func recipesRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent("recipes")
    }

    private static func makeSlug() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "recording-" + fmt.string(from: Date())
    }
}
