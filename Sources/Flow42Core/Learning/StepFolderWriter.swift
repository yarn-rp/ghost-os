// StepFolderWriter.swift - Write one self-contained step folder.
//
// v2 layout: every captured event is its own folder under `steps/NNNN-action/`.
// Each folder is atomic: it carries its own meta.yaml, its own screenshot
// (raw + annotated), and any per-event sidecars (ax.json, vision.json).
//
// Why folders rather than a flat array:
//   - The structuring agent reads only what it needs. Pass 1 scans
//     events.jsonl (cheap, lightweight). Pass 2/3 dive into step folders
//     for full detail.
//   - The future Flow Viewer app can edit individual steps without parsing
//     the whole flow.json blob.
//   - Adding new sidecars later (e.g. dom-snapshot.html, region-vision.png)
//     doesn't require schema changes — just drop a file in the folder.
//
// Crash safety:
//   - We write the screenshot first (atomic move), then meta.yaml last.
//     If we crash in the middle, the events.jsonl tailer doesn't see the
//     half-written step (we append to events.jsonl AFTER meta.yaml lands).
//   - Folder name includes the action_type so partially-written folders
//     are at least debuggable.

import Foundation

public enum StepFolderWriter {

    /// Result of a successful write. The relative step path ("steps/0001-click")
    /// is what the caller threads into events.jsonl and is what the agent
    /// later references from `flow.yaml` step entries.
    public struct Outcome: Sendable {
        public let stepIndex: Int
        public let stepDirRelative: String
        public let stepDirAbsolute: String
        /// Relative paths the meta.yaml ended up referencing — caller may
        /// want them for the events.jsonl line too.
        public let screenshotRelative: String?
        public let annotatedScreenshotRelative: String?
    }

    // MARK: - Public API

    /// Write a brand-new step folder. Returns nil on I/O failure.
    /// `meta` should be the per-step dict produced by
    /// `LearningDispatch.serializeStepMeta`. The screenshot path arguments
    /// are absolute paths to staging files (typically under `screenshots/`)
    /// that this writer MOVES into the step folder. Pass nil for actions
    /// where no screenshot was captured.
    public nonisolated static func writeNewStep(
        recordingDir: String,
        stepIndex: Int,
        actionType: String,
        meta: [String: Any],
        screenshotSourceAbs: String?,
        annotatedScreenshotSourceAbs: String?,
        sidecars: [String: Data] = [:]
    ) -> Outcome? {
        let folderName = makeFolderName(index: stepIndex, actionType: actionType)
        let stepsRoot = (recordingDir as NSString).appendingPathComponent("steps")
        let absDir = (stepsRoot as NSString).appendingPathComponent(folderName)
        let relDir = "steps/\(folderName)"

        do {
            try FileManager.default.createDirectory(
                atPath: absDir, withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(Data(
                "[StepFolderWriter] mkdir failed: \(error.localizedDescription)\n".utf8
            ))
            return nil
        }

        var resolvedMeta = meta
        let screenshotRel = move(
            from: screenshotSourceAbs,
            into: absDir,
            named: "screenshot.jpg",
            relPrefix: relDir
        )
        if let screenshotRel { resolvedMeta["screenshot"] = screenshotRel }
        else { resolvedMeta.removeValue(forKey: "screenshot") }

        let annotatedRel = move(
            from: annotatedScreenshotSourceAbs,
            into: absDir,
            named: "annotated.jpg",
            relPrefix: relDir
        )
        if let annotatedRel { resolvedMeta["annotated_screenshot"] = annotatedRel }
        else { resolvedMeta.removeValue(forKey: "annotated_screenshot") }

        // Sidecars (ax.json, vision.json, etc.) are written as-is. Caller
        // controls the keys; we only care that they're valid filenames.
        for (name, data) in sidecars {
            let path = (absDir as NSString).appendingPathComponent(name)
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            // Record the relative path in meta so consumers can find it.
            // Using the file's stem as the meta key is dumb-but-fine for v2
            // (e.g. ax.json → ax_path).
            let stem = (name as NSString).deletingPathExtension
            resolvedMeta["\(stem)_path"] = "\(relDir)/\(name)"
        }

        // meta.yaml LAST — only after everything else lands. The events.jsonl
        // tailer sees a step folder appear with all its content already on
        // disk; partial states are not visible.
        if !writeMetaYaml(at: absDir, dict: resolvedMeta) { return nil }

        return Outcome(
            stepIndex: stepIndex,
            stepDirRelative: relDir,
            stepDirAbsolute: absDir,
            screenshotRelative: screenshotRel,
            annotatedScreenshotRelative: annotatedRel
        )
    }

    /// Rewrite an existing step folder's meta.yaml in place. Used for the
    /// typeText coalescing path: when the recorder folds a new keystroke
    /// into the previous typeText action, the step folder doesn't need a
    /// new index — just an updated meta. Screenshot stays as-is (the first
    /// shot of the burst is the most informative).
    public nonisolated static func updateStepMeta(
        recordingDir: String,
        stepDirRelative: String,
        meta: [String: Any]
    ) -> Bool {
        let absDir = (recordingDir as NSString).appendingPathComponent(stepDirRelative)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absDir, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        return writeMetaYaml(at: absDir, dict: meta)
    }

    /// Scan an existing recording's `steps/` directory for the highest
    /// step index in use. Used at session resume / mid-recording crash
    /// recovery to pick up where we left off.
    public nonisolated static func highestExistingIndex(in recordingDir: String) -> Int {
        let stepsRoot = (recordingDir as NSString).appendingPathComponent("steps")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stepsRoot)
        else { return 0 }
        var max = 0
        for entry in entries {
            // Folder name is "NNNN-actiontype". Take the leading digits.
            let digits = entry.prefix(while: { $0.isNumber })
            if let n = Int(digits), n > max { max = n }
        }
        return max
    }

    // MARK: - Internals

    private nonisolated static func makeFolderName(index: Int, actionType: String) -> String {
        let safeType = sanitizeForFilename(actionType)
        return String(format: "%04d-%@", index, safeType as CVarArg)
    }

    /// Filenames are POSIX-flexible but we keep the action_type slug short
    /// and ASCII-only. Anything weird gets replaced with `_`.
    private nonisolated static func sanitizeForFilename(_ s: String) -> String {
        var out = ""
        for c in s {
            if c.isLetter || c.isNumber || c == "-" || c == "_" {
                out.append(c)
            } else {
                out.append("_")
            }
        }
        return out.isEmpty ? "unknown" : out
    }

    /// Copy a staged file into the step folder. We COPY (not move) during
    /// Phase A so the legacy `screenshots/step-NNN.jpg` files stay in
    /// place for the dual-written flow.json to reference. Phase C will
    /// switch to move semantics when flow.json goes away.
    /// Returns the relative path callers should write into meta, or nil
    /// when the source doesn't exist.
    private nonisolated static func move(
        from sourceAbs: String?,
        into destDir: String,
        named name: String,
        relPrefix: String
    ) -> String? {
        guard let sourceAbs, FileManager.default.fileExists(atPath: sourceAbs)
        else { return nil }
        let destAbs = (destDir as NSString).appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(atPath: destAbs)
            try FileManager.default.copyItem(atPath: sourceAbs, toPath: destAbs)
            return "\(relPrefix)/\(name)"
        } catch {
            FileHandle.standardError.write(Data(
                "[StepFolderWriter] copy failed for \(name): \(error.localizedDescription)\n".utf8
            ))
            return nil
        }
    }

    private nonisolated static func writeMetaYaml(at absDir: String, dict: [String: Any]) -> Bool {
        let path = (absDir as NSString).appendingPathComponent("meta.yaml")
        let yaml = YAMLEmit.mapping(dict)
        let tmp = path + ".tmp"
        do {
            try yaml.write(toFile: tmp, atomically: false, encoding: .utf8)
            if rename(tmp, path) != 0 {
                try? FileManager.default.removeItem(atPath: tmp)
                return false
            }
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "[StepFolderWriter] meta.yaml write failed: \(error.localizedDescription)\n".utf8
            ))
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
    }
}
