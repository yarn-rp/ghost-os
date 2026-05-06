// Stop.swift - Universal `flow42 stop`.
//
// The singleton invariant says exactly one session is active at a time, so
// `stop` doesn't need to disambiguate. It looks at state.json and:
//   - if a recording is active, sends a stop signal (same path as
//     `flow42 record stop`, but without re-implementing the daemon
//     wait — we just write the .stop-requested marker and let the
//     daemon clean up + flip state.json to idle on its own).
//   - if a play is active, ends it with reason=user_stopped (Play.runEnd).
//   - if neither is active, no-op success.
//
// Both the floating window's Stop button and the top pill's Stop button
// shell out to this command.

import Flow42Core
import Foundation

enum Stop {

    static func run(args: [String]) {
        let state = StateFile.read()

        if let recording = state.recording {
            // Mirror Record.runStop's stop-marker write (without the
            // 60s wait — `flow42 stop` is fire-and-forget; the daemon
            // does its own finalize and writes meta.yaml on exit).
            let marker = (recording.dir as NSString)
                .appendingPathComponent(".stop-requested")
            FileManager.default.createFile(atPath: marker, contents: Data())
            emitJSON([
                "success": true,
                "stopped": "recording",
                "slug": recording.slug,
                "dir": recording.dir,
                "note": "stop signaled; recorder is finalising in the background",
            ])
            return
        }

        if let play = state.play {
            // Reuse Play.runEnd semantics by writing directly through the
            // Play module. The Play subcommand handles log + state cleanup.
            Play.endActive(reason: "user_stopped", play: play)
            return
        }

        // Idle.
        emitJSON([
            "success": true,
            "note": "nothing to stop (state is idle)",
        ])
    }
}
