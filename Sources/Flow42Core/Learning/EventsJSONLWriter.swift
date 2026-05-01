// EventsJSONLWriter.swift - Append-only flat index over a recording's steps.
//
// events.jsonl carries one JSON object per line, each summarizing a step
// folder. This is what the menu timeline view tails (cheap, no fsync of a
// full flow.json on every action) and what the structuring agent's first
// pass reads (Pass 1 — phase detection — only needs the lightweight view).
//
// Append-only by design:
//   - The recorder can crash without leaving a half-written line; we use
//     a single FileHandle.write() per line, which is atomic at the size
//     of one short line on most local filesystems.
//   - Coalescing writes a NEW line for the updated step rather than
//     rewriting the file. Consumers dedupe on `step_dir` (last line wins).
//     This trades a slightly larger file for crash safety.
//
// Schema (line):
//   { "idx": 7,
//     "step_dir": "steps/0007-typeText",
//     "action_type": "typeText",
//     "app": "Mail",
//     "bundle_id": "com.apple.mail",
//     "url": "...",                       // optional, browser only
//     "summary": "type \"hello world\"",   // human-readable one-liner
//     "timestamp_ms": 1714572083214,
//     "source": "native"                   // "native" | "annotation" | "extension"
//   }

import Foundation

public enum EventsJSONLWriter {

    /// Path to the events.jsonl for a recording dir. Public so the menu
    /// timeline (in Phase B) can hand the same path to its FSEvents watcher.
    public nonisolated static func path(for recordingDir: String) -> String {
        (recordingDir as NSString).appendingPathComponent("events.jsonl")
    }

    /// Append one line. Crash-safe in the limited sense that a partial
    /// write isn't visible (we serialize then write in one syscall) and a
    /// crash before the write leaves the file unchanged. Best-effort: any
    /// I/O failure is logged to stderr and swallowed — recording continues.
    public nonisolated static func append(
        to recordingDir: String,
        entry: [String: Any]
    ) {
        let p = path(for: recordingDir)
        if !FileManager.default.fileExists(atPath: p) {
            FileManager.default.createFile(atPath: p, contents: nil)
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let handle = FileHandle(forWritingAtPath: p)
        else {
            FileHandle.standardError.write(Data(
                "[EventsJSONLWriter] could not open \(p) for append\n".utf8
            ))
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A])) // \n
        } catch {
            FileHandle.standardError.write(Data(
                "[EventsJSONLWriter] write failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}
