// Record.swift - `flow42 record` CLI subcommands.
//
// Three subcommands plus an interactive bare-command fallback:
//
//   flow42 record start [--description X]   — fork a daemon, return immediately.
//   flow42 record stop                       — signal the active daemon, wait
//                                              for flow.json to be produced,
//                                              return its path.
//   flow42 record status                     — report whether a recording is
//                                              currently active.
//   flow42 record [--description X]          — interactive (TTY) mode: stay in
//                                              the foreground, type "done" to
//                                              stop. Same as the original
//                                              behaviour, kept for human use.
//
// The start/stop split exists because agents drive flow42 from non-interactive
// processes — they can't write "done\n" to stdin of a backgrounded child. With
// start/stop, the agent calls one command, does work, then calls another.
//
// Recording dir layout (v2):
//   ~/.flow42/flows/<slug>/
//     flow.json           — task metadata + serialized actions
//     screenshots/        — populated by LearningScreenshot per click
//     narration.wav       — audio captured during the recording
//     dom-events.jsonl    — extension-side captures
//     recorder.log        — daemon stdout/stderr (when run via `start`)

import Darwin
import Dispatch
import Flow42Core
import Foundation

enum Record {

    static func run(args: [String]) {
        // Bare `flow42 record` (no subverb) is an alias for `start` — that's
        // the agent-friendly path. Anything that looks like flags goes to
        // start too. Subcommands stop / status / _daemon are explicit.
        guard let first = args.first else {
            runStart(args: args)
            return
        }
        switch first {
        case "start":   runStart(args: Array(args.dropFirst()))
        case "stop":    runStop(args: Array(args.dropFirst()))
        case "status":  runStatus(args: Array(args.dropFirst()))
        case "_daemon": runDaemonEntry(args: Array(args.dropFirst()))
        case "help", "-h", "--help":
            print(usage)
            exit(0)
        default:
            // Unknown first arg, but it might just be a flag for start
            // (e.g. `flow42 record --description "X"`). Forward.
            runStart(args: args)
        }
    }

    // MARK: - start (background daemon)

    private static func runStart(args: [String]) {
        // Refuse if another recording is already active.
        if let active = ActiveRecording.read(),
           let pid = active["pid"] as? Int,
           kill(pid_t(pid), 0) == 0 {
            emitJSON([
                "success": false,
                "error": "another recording is already active",
                "active": active,
                "suggestion": "run `flow42 record stop` first",
            ])
            exit(1)
        }

        let description = parseFlag(args, "--description", "-d")
        let slug = makeSlug()
        let dir = recipesRoot().appendingPathComponent(slug).path

        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        } catch {
            emitJSON([
                "success": false,
                "error": "failed to create \(dir): \(error.localizedDescription)",
            ])
            exit(1)
        }
        try? SeedPrompts.seed(into: dir)

        // Spawn a child `flow42 _daemon …` process. Parent waits for the
        // active marker to appear (proves the daemon actually started), then
        // prints + exits. The child re-runs flow42 with `_daemon` and goes
        // through the daemonization path below.
        let exePath = currentExecutablePath()
        var argv = ["record", "_daemon", "--slug", slug, "--dir", dir]
        if let description { argv += ["--description", description] }

        // Browser-mode flag: --browser-mode native | extension | auto.
        // Propagated to the daemon via an env var so EventHandlers reads it
        // at session start. CLI flag overrides $FLOW42_BROWSER_MODE; both
        // override the on-disk config at ~/.flow42/browser-mode.
        let cliBrowserMode = parseFlag(args, "--browser-mode", "-b")

        let logPath = (dir as NSString).appendingPathComponent("recorder.log")
        FileManager.default.createFile(atPath: logPath, contents: nil)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: exePath)
        task.arguments = argv
        if let cliBrowserMode {
            var env = ProcessInfo.processInfo.environment
            env["FLOW42_BROWSER_MODE"] = cliBrowserMode
            task.environment = env
        }
        if let logHandle = FileHandle(forWritingAtPath: logPath) {
            task.standardOutput = logHandle
            task.standardError = logHandle
        }
        if let nullHandle = FileHandle(forReadingAtPath: "/dev/null") {
            task.standardInput = nullHandle
        }

        do {
            try task.run()
        } catch {
            emitJSON([
                "success": false,
                "error": "spawn failed: \(error.localizedDescription)",
            ])
            exit(1)
        }
        let childPid = Int(task.processIdentifier)

        // Wait briefly for the daemon to write the active marker.
        let deadline = Date().addingTimeInterval(5)
        var ok = false
        while Date() < deadline {
            if let active = ActiveRecording.read(),
               let activePid = active["pid"] as? Int, activePid == childPid {
                ok = true
                break
            }
            usleep(50_000)
        }
        var payload: [String: Any] = [
            "success": ok,
            "path": dir,
            "slug": slug,
            "pid": childPid,
            "log": logPath,
            "stop_command": "flow42 record stop",
        ]
        if let description { payload["task_description"] = description }
        if !ok { payload["note"] = "daemon did not write active marker within 5s — check recorder.log" }
        emitJSON(payload)
        exit(ok ? 0 : 1)
    }

    /// Hidden subcommand entry point — invoked by `runStart` via Process().
    /// We're already a child of the spawning flow42; daemonize via setsid +
    /// chdir, then run the recorder loop until SIGTERM.
    private static func runDaemonEntry(args: [String]) {
        guard let slug = parseFlag(args, "--slug", "-s"),
              let dir = parseFlag(args, "--dir", "-D")
        else {
            FileHandle.standardError.write(Data("daemon: missing --slug/--dir\n".utf8))
            exit(2)
        }
        let description = parseFlag(args, "--description", "-d")
        _ = setsid()
        chdir("/")
        runDaemonLoop(slug: slug, dir: dir, description: description)
    }

    /// Inside the forked child. Starts the recorder + audio, waits for
    /// SIGTERM/SIGINT, then finalises and exits.
    private static func runDaemonLoop(slug: String, dir: String, description: String?) {
        let recorder = LearningRecorder.shared
        if let err = recorder.start(taskDescription: description, recordingDir: dir) {
            FileHandle.standardError.write(Data(
                "recorder.start failed: \(err.localizedDescription) — \(err.suggestion)\n".utf8
            ))
            exit(1)
        }

        try? ActiveRecording.set(slug: slug, dir: dir, pid: Int(getpid()))

        // Announce mode=recording so the menu bar app lights up the magenta
        // edge glow. Best-effort — failure to write state.json must not abort
        // the recording itself.
        _ = try? StateFile.write(AppState(
            mode: .recording,
            label: description,
            recording: AppState.RecordingInfo(slug: slug, dir: dir, pid: Int(getpid()))
        ))

        let micErr = AudioRecorder.shared.start(recordingDir: dir)
        if let micErr {
            FileHandle.standardError.write(Data(
                "Mic OFF (\(micErr.localizedDescription))\n".utf8
            ))
        } else {
            FileHandle.standardError.write(Data(
                "Mic ON  → narration.wav (transcribed via whisper-cli on stop)\n".utf8
            ))
        }

        // Wait for stop signal. We use a marker file (`.stop-requested` in
        // the recording dir) instead of POSIX signals because Swift on macOS
        // makes signal-source-based async waiting fragile in CLI processes.
        // `flow42 record stop` writes this file; we poll for it.
        let stopMarker = (dir as NSString).appendingPathComponent(".stop-requested")
        while !FileManager.default.fileExists(atPath: stopMarker) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? FileManager.default.removeItem(atPath: stopMarker)

        // Finalise.
        ActiveRecording.clear()
        try? StateFile.clearToIdle()
        let wavURL = AudioRecorder.shared.stop()
        let result = finalize(slug: slug, dir: dir, wavURL: wavURL)
        // Stash the final result in the daemon log; useful for forensics.
        FileHandle.standardError.write(Data("daemon stop: \(result)\n".utf8))
        exit(0)
    }

    // MARK: - stop

    private static func runStop(args: [String]) {
        guard let active = ActiveRecording.read() else {
            emitJSON([
                "success": false,
                "error": "no active recording",
                "suggestion": "run `flow42 record start` first",
            ])
            exit(1)
        }
        guard let pidInt = active["pid"] as? Int else {
            emitJSON([
                "success": false,
                "error": "active marker has no pid (was the recording started in interactive mode?)",
            ])
            exit(1)
        }
        let dir = (active["dir"] as? String) ?? ""
        let slug = (active["slug"] as? String) ?? ""

        // Verify the daemon is still alive.
        let pid = pid_t(pidInt)
        if kill(pid, 0) != 0 {
            ActiveRecording.clear()
            emitJSON([
                "success": false,
                "error": "recorder pid \(pidInt) is not running (already dead?)",
                "suggestion": "active marker cleared",
            ])
            exit(1)
        }

        // Write the stop marker. The daemon polls for it.
        let stopMarker = (dir as NSString).appendingPathComponent(".stop-requested")
        FileManager.default.createFile(atPath: stopMarker, contents: Data())

        // Poll for flow.json to appear. Whisper transcription can take ~1-3s
        // per 10s of audio; cap at 60s overall.
        let flowPath = (dir as NSString).appendingPathComponent("flow.json")
        let deadline = Date().addingTimeInterval(60)
        var written = false
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: flowPath) {
                written = true
                break
            }
            usleep(200_000)
        }

        if written,
           let data = try? Data(contentsOf: URL(fileURLWithPath: flowPath)),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            emitJSON([
                "success": true,
                "path": dir,
                "slug": json["slug"] as? String ?? slug,
                "action_count": json["action_count"] ?? 0,
                "duration_seconds": json["duration_seconds"] ?? 0,
            ])
        } else {
            emitJSON([
                "success": false,
                "error": "flow.json was not produced within 60s",
                "path": dir,
                "log": "\(dir)/recorder.log",
            ])
            exit(1)
        }
    }

    // MARK: - status

    private static func runStatus(args: [String]) {
        guard let active = ActiveRecording.read() else {
            emitJSON(["success": true, "active": false])
            return
        }
        var alive = false
        if let pid = active["pid"] as? Int {
            alive = (kill(pid_t(pid), 0) == 0)
        }
        emitJSON([
            "success": true,
            "active": alive,
            "marker": active,
            "stale": !alive,
        ])
    }

    // MARK: - finalise (used by daemon)

    /// Stops the recorder, transcribes narration, merges sources, writes
    /// flow.json. Returns a small dict suitable for printing to stdout.
    @discardableResult
    private static func finalize(slug: String, dir: String, wavURL: URL?) -> [String: Any] {
        let recorder = LearningRecorder.shared
        switch recorder.stop() {
        case .failure(let error):
            FileHandle.standardError.write(Data(
                "warning: \(error.localizedDescription)\n".utf8
            ))
            // Even on failure, write an empty flow.json so the stop command
            // can find SOMETHING and report cleanly. An empty recording
            // is still a recording.
            let payload: [String: Any] = [
                "schema_version": 1,
                "platform": "mac",
                "slug": slug,
                "task_description": "",
                "recorded_at": ISO8601DateFormatter().string(from: Date()),
                "duration_seconds": 0,
                "action_count": 0,
                "apps": [],
                "urls": [],
                "actions": [],
                "warning": error.localizedDescription,
            ]
            // Best-effort: drop the warning in the recording dir so the
            // user can find it without having to read the daemon log.
            // events.jsonl + steps/ may already exist from a partial
            // recording; we don't touch them.
            let warningPath = (dir as NSString).appendingPathComponent("recorder-warning.json")
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) {
                try? data.write(to: URL(fileURLWithPath: warningPath))
            }
            return [
                "success": true,
                "path": dir,
                "slug": slug,
                "action_count": 0,
                "warning": error.localizedDescription,
            ]
        case .success(let (session, actions)):
            let duration = Date().timeIntervalSince(session.startTime)

            // Narration is only available now (whisper runs at stop time).
            // Each segment becomes its own step folder so it shows up in
            // the timeline interleaved with native + extension events,
            // and the full transcript is written to audio/narration.txt
            // for the agent's Pass 1 to read.
            var narrationCount = 0
            if let wavURL,
               FileManager.default.fileExists(atPath: wavURL.path),
               let size = try? wavURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 1024 {
                FileHandle.standardError.write(Data("Transcribing narration…\n".utf8))
                do {
                    let segments = try NarrationTranscriber.transcribe(wavURL: wavURL)
                    let startMs = Int64(session.startTime.timeIntervalSince1970 * 1000)
                    var transcriptLines: [String] = []
                    for seg in segments {
                        let stepIndex = StepFolderWriter.highestExistingIndex(in: dir) + 1
                        let timestampMs = startMs + Int64(seg.startMs)
                        let meta: [String: Any] = [
                            "action_type": "narration",
                            "source": "narration",
                            "text": seg.text,
                            "duration_ms": seg.endMs - seg.startMs,
                            "timestamp_ms": timestampMs,
                        ]
                        if let outcome = StepFolderWriter.writeNewStep(
                            recordingDir: dir,
                            stepIndex: stepIndex,
                            actionType: "narration",
                            meta: meta,
                            screenshotSourceAbs: nil,
                            annotatedScreenshotSourceAbs: nil
                        ) {
                            let entry: [String: Any] = [
                                "idx": outcome.stepIndex,
                                "step_dir": outcome.stepDirRelative,
                                "action_type": "narration",
                                "app": "",
                                "summary": "narration: \(seg.text.prefix(80))",
                                "timestamp_ms": timestampMs,
                                "source": "narration",
                            ]
                            EventsJSONLWriter.append(to: dir, entry: entry)
                            narrationCount += 1
                        }
                        // Plain-text transcript line for audio/narration.txt.
                        // Format: "[+SS.mss] text" so the agent reading it
                        // gets the timing alongside the words.
                        let offsetSec = Double(seg.startMs) / 1000.0
                        transcriptLines.append(String(
                            format: "[+%05.2f] %@", offsetSec, seg.text as CVarArg
                        ))
                    }
                    if !transcriptLines.isEmpty {
                        let audioDir = (dir as NSString).appendingPathComponent("audio")
                        try? FileManager.default.createDirectory(
                            atPath: audioDir, withIntermediateDirectories: true
                        )
                        let txtPath = (audioDir as NSString)
                            .appendingPathComponent("narration.txt")
                        try? transcriptLines.joined(separator: "\n")
                            .write(toFile: txtPath, atomically: true, encoding: .utf8)
                    }
                    FileHandle.standardError.write(Data(
                        "Narration: \(segments.count) segment\(segments.count == 1 ? "" : "s")\n".utf8
                    ))
                } catch {
                    FileHandle.standardError.write(Data(
                        "warning: narration transcription failed: \(error.localizedDescription)\n".utf8
                    ))
                }
            }

            let actionCount = actions.count + narrationCount

            // Top-level meta.yaml — session metadata the menu app's
            // recordings list and the agent's structuring pass both
            // read. Replaces the flow.json header from the v1 layout.
            let isoDate = ISO8601DateFormatter()
            isoDate.formatOptions = [.withInternetDateTime]
            let metaDict: [String: Any] = [
                "schema_version": 2,
                "name": slug,
                "task_description": session.taskDescription ?? "",
                "recorded_at": isoDate.string(from: session.startTime),
                "duration_seconds": Int(duration),
                "action_count": actionCount,
                "apps": Array(session.apps).sorted(),
                "urls": session.urls,
                "finalized": true,
            ]
            let metaPath = (dir as NSString).appendingPathComponent("meta.yaml")
            try? YAMLEmit.mapping(metaDict)
                .write(toFile: metaPath, atomically: true, encoding: .utf8)

            return [
                "success": true,
                "path": dir,
                "slug": slug,
                "action_count": actionCount,
                "duration_seconds": Int(duration),
            ]
        }
    }

    // MARK: - Helpers

    private static let usage = """
    Usage:
      flow42 record [--description X]   Start a backgrounded recorder daemon
                                         (alias for `flow42 record start`)
      flow42 record stop                 Stop the active recorder, write flow.json
      flow42 record status               Report whether a recording is active

    Examples:
      flow42 record --description "save url to notes"
      # ... do stuff ...
      flow42 record stop
    """

    private static func emitJSON(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.withoutEscapingSlashes, .sortedKeys]
        ),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private static func parseFlag(_ args: [String], _ long: String, _ short: String) -> String? {
        var i = 0
        while i < args.count {
            if args[i] == long || args[i] == short {
                if i + 1 < args.count { return args[i + 1] }
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func recipesRoot() -> URL {
        URL(fileURLWithPath: Flow42Paths.flowsRoot())
    }

    /// Resolve the absolute path of the running flow42 binary (so we can
    /// re-exec it via Process()).
    private static func currentExecutablePath() -> String {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buf.deallocate() }
        guard _NSGetExecutablePath(buf, &size) == 0 else {
            return CommandLine.arguments[0]
        }
        let raw = String(cString: buf)
        return (URL(fileURLWithPath: raw).resolvingSymlinksInPath()).path
    }

    private static func makeSlug() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "recording-" + fmt.string(from: Date())
    }
}
