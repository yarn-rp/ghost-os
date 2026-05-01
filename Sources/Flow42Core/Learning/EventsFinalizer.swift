// EventsFinalizer.swift - Sort + renumber pass at the end of recording.
//
// During a live recording, step folders + events.jsonl entries are
// allocated in append order, which == capture order for native + extension
// events. Narration is the exception: whisper transcribes the WAV at
// finalize, so each segment shows up in the index AFTER every native /
// extension event — even though its timestamp_ms is mid-recording.
//
// Result before this pass: a recording that started with two narration
// segments + a click ends up with folders ordered "0001-click,
// 0002-narration, 0003-narration" instead of the captured "narration,
// narration, click."
//
// We fix it once, at finalize, by:
//   1. Parsing events.jsonl, deduping on step_dir (last-write-wins for
//      coalesce / backspace updates), and sorting the survivors by
//      timestamp_ms.
//   2. Walking the sorted list and computing each step's new four-digit
//      folder name (preserving the action_type suffix).
//   3. Two-phase renaming the folders on disk: stage everything to a
//      `.tmp-<old>` name first, then move each temp into its final name,
//      so swaps (where two folders trade slots) don't collide with each
//      other mid-rename.
//   4. Rewriting each renamed folder's meta.yaml to update path fields
//      that embed the step_dir (`screenshot`, `annotated_screenshot`,
//      `ax_path`, etc). We do this as a plain string substitution
//      instead of a YAML round-trip to avoid pulling Yams into the
//      recording hot path.
//   5. Rewriting events.jsonl atomically (write-tmp + rename) with the
//      sorted, renumbered entries.
//
// Idempotent: running on an already-sorted recording is a no-op (every
// computed newName equals oldName, so the rename plan is empty and the
// rewritten events.jsonl is byte-identical).

import Foundation

public enum EventsFinalizer {

    /// Sort + renumber. Best-effort — any I/O failure is logged to stderr
    /// and swallowed; the recording stays in append order rather than
    /// failing finalize entirely.
    public nonisolated static func sortAndRenumber(in recordingDir: String) {
        let eventsPath = (recordingDir as NSString).appendingPathComponent("events.jsonl")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: eventsPath)),
              let text = String(data: data, encoding: .utf8)
        else { return }

        // 1. Parse + dedup on step_dir (last-write-wins).
        var byDir: [String: [String: Any]] = [:]
        var firstSeenOrder: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let lineData = raw.data(using: .utf8),
                let dict = (try? JSONSerialization.jsonObject(with: lineData))
                    as? [String: Any],
                let dir = dict["step_dir"] as? String
            else { continue }
            if byDir[dir] == nil { firstSeenOrder.append(dir) }
            byDir[dir] = dict
        }
        guard !byDir.isEmpty else { return }

        // 2. Sort by timestamp_ms. Entries without a timestamp pin to
        //    the end (Int64.max) so they don't shuffle valid entries.
        let sorted = byDir.values.sorted { a, b in
            let ax = timestampMs(a)
            let bx = timestampMs(b)
            if ax == bx {
                // Stable tiebreak: preserve first-seen order in events.jsonl.
                let aDir = (a["step_dir"] as? String) ?? ""
                let bDir = (b["step_dir"] as? String) ?? ""
                let ai = firstSeenOrder.firstIndex(of: aDir) ?? Int.max
                let bi = firstSeenOrder.firstIndex(of: bDir) ?? Int.max
                return ai < bi
            }
            return ax < bx
        }

        // 3. Build the rename plan + the new events.jsonl payload.
        var renames: [(oldDir: String, newDir: String)] = []
        var newEntries: [[String: Any]] = []
        newEntries.reserveCapacity(sorted.count)
        for (i, entry) in sorted.enumerated() {
            let newIdx = i + 1
            let oldStepDir = (entry["step_dir"] as? String) ?? ""
            let suffix = stepDirSuffix(oldStepDir)
            let newName = String(format: "%04d-%@", newIdx, suffix as CVarArg)
            let newStepDir = "steps/\(newName)"

            var newEntry = entry
            newEntry["idx"] = newIdx
            newEntry["step_dir"] = newStepDir
            newEntries.append(newEntry)

            if oldStepDir != newStepDir {
                renames.append((oldDir: oldStepDir, newDir: newStepDir))
            }
        }

        // 4. Two-phase rename so swaps don't collide. We also rewrite
        //    the affected meta.yaml's path fields in the temp phase
        //    (after the move-to-temp, before the move-to-final), since
        //    the file's parent dir hasn't changed in absolute terms yet.
        let stepsRoot = (recordingDir as NSString).appendingPathComponent("steps")
        if !renames.isEmpty {
            var stagedTmps: [(tempAbs: String, finalAbs: String, oldRel: String, newRel: String)] = []
            for r in renames {
                let oldName = (r.oldDir as NSString).lastPathComponent
                let oldAbs = (recordingDir as NSString).appendingPathComponent(r.oldDir)
                let tmpAbs = (stepsRoot as NSString).appendingPathComponent(".tmp-\(oldName)")
                let finalAbs = (recordingDir as NSString).appendingPathComponent(r.newDir)
                if rename(oldAbs, tmpAbs) == 0 {
                    stagedTmps.append((tmpAbs, finalAbs, r.oldDir, r.newDir))
                } else {
                    FileHandle.standardError.write(Data(
                        "[EventsFinalizer] could not stage \(oldAbs): \(String(cString: strerror(errno)))\n".utf8
                    ))
                }
            }
            for s in stagedTmps {
                rewriteMetaYAML(at: s.tempAbs, oldStepDir: s.oldRel, newStepDir: s.newRel)
                if rename(s.tempAbs, s.finalAbs) != 0 {
                    FileHandle.standardError.write(Data(
                        "[EventsFinalizer] could not finalise rename \(s.tempAbs) -> \(s.finalAbs): \(String(cString: strerror(errno)))\n".utf8
                    ))
                }
            }
        }

        // 5. Rewrite events.jsonl atomically.
        var output = ""
        for entry in newEntries {
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: entry,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                ),
                let line = String(data: data, encoding: .utf8)
            else { continue }
            output += line
            output += "\n"
        }
        let tmpPath = eventsPath + ".tmp"
        do {
            try output.write(toFile: tmpPath, atomically: false, encoding: .utf8)
            if rename(tmpPath, eventsPath) != 0 {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[EventsFinalizer] events.jsonl rewrite failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    // MARK: - Helpers

    private nonisolated static func timestampMs(_ entry: [String: Any]) -> Int64 {
        if let n = entry["timestamp_ms"] as? Int64 { return n }
        if let n = entry["timestamp_ms"] as? Int { return Int64(n) }
        if let d = entry["timestamp_ms"] as? Double { return Int64(d) }
        return Int64.max
    }

    /// Extract the action-type suffix from a step_dir like
    /// `steps/0007-click` → `click`. Folders that somehow don't follow
    /// the convention fall back to `unknown` so the new name is still
    /// well-formed.
    private nonisolated static func stepDirSuffix(_ stepDir: String) -> String {
        let last = (stepDir as NSString).lastPathComponent
        guard let dashIdx = last.firstIndex(of: "-") else { return "unknown" }
        let suffix = String(last[last.index(after: dashIdx)...])
        return suffix.isEmpty ? "unknown" : suffix
    }

    /// Rewrite occurrences of the old step_dir prefix in the folder's
    /// meta.yaml. We use string substitution rather than a YAML round-
    /// trip because the recorder process doesn't link Yams. The fields
    /// affected are: `screenshot`, `annotated_screenshot`, `ax_path`,
    /// `vision_path`, `region_path`. They all embed the step_dir as a
    /// path prefix, so a single string replace covers every case.
    private nonisolated static func rewriteMetaYAML(
        at folderAbs: String,
        oldStepDir: String,
        newStepDir: String
    ) {
        let metaPath = (folderAbs as NSString).appendingPathComponent("meta.yaml")
        guard FileManager.default.fileExists(atPath: metaPath),
              var text = try? String(contentsOf: URL(fileURLWithPath: metaPath), encoding: .utf8)
        else { return }
        // Replace `oldStepDir/` (with trailing slash) so we never match a
        // bare prefix that happens to be a substring of an unrelated path.
        text = text.replacingOccurrences(of: "\(oldStepDir)/", with: "\(newStepDir)/")
        try? text.write(toFile: metaPath, atomically: true, encoding: .utf8)
    }
}
