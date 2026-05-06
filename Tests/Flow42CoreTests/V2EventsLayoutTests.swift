// V2EventsLayoutTests.swift - Smoke test for the v2 step-folder layout.
//
// Exercises StepFolderWriter, EventsJSONLWriter, and YAMLEmit against a
// temp directory. Catches regressions in:
//   - folder naming (NNNN-action_type, zero-padded 4 digits)
//   - meta.yaml schema (sorted keys, screenshot rewritten to step-folder rel)
//   - events.jsonl one-line-per-step append, last-line-wins on update
//   - YAML emitter determinism (same input → same bytes)

import Foundation
import Testing
@testable import Flow42Core

@Suite("V2 events layout — step folders + events.jsonl")
struct V2EventsLayoutTests {

    @Test("New step folder lands with meta.yaml + screenshots")
    func newStepFolder() throws {
        let dir = try makeTempRecording()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let raw = stageScreenshot(in: dir, name: "step-001.jpg", bytes: [0x42, 0x43, 0x44])
        let annotated = stageScreenshot(in: dir, name: "step-001.annotated.jpg", bytes: [0xAA, 0xBB])

        let outcome = StepFolderWriter.writeNewStep(
            recordingDir: dir,
            stepIndex: 1,
            actionType: "click",
            meta: [
                "action_type": "click",
                "app": "Mail",
                "x": 1340,
                "y": 1490,
                "screenshot": "screenshots/step-001.jpg",
                "annotated_screenshot": "screenshots/step-001.annotated.jpg",
            ],
            screenshotSourceAbs: raw,
            annotatedScreenshotSourceAbs: annotated
        )

        let resolved = try #require(outcome)
        #expect(resolved.stepIndex == 1)
        #expect(resolved.stepDirRelative == "steps/0001-click")
        #expect(resolved.screenshotRelative == "steps/0001-click/screenshot.jpg")
        #expect(resolved.annotatedScreenshotRelative == "steps/0001-click/annotated.jpg")

        // The folder exists with all three files.
        let stepDir = resolved.stepDirAbsolute
        #expect(FileManager.default.fileExists(atPath: "\(stepDir)/meta.yaml"))
        #expect(FileManager.default.fileExists(atPath: "\(stepDir)/screenshot.jpg"))
        #expect(FileManager.default.fileExists(atPath: "\(stepDir)/annotated.jpg"))

        // Move semantics (not copy): the staging files in screenshots/
        // are gone after writeNewStep claims them.
        #expect(!FileManager.default.fileExists(atPath: raw))
        #expect(!FileManager.default.fileExists(atPath: annotated))

        // meta.yaml's screenshot field was rewritten to the step folder's
        // canonical path (not the staging path the meta dict came in with).
        let metaText = try String(
            contentsOf: URL(fileURLWithPath: "\(stepDir)/meta.yaml"),
            encoding: .utf8
        )
        #expect(metaText.contains("screenshot: \"steps/0001-click/screenshot.jpg\""))
        #expect(metaText.contains("annotated_screenshot: \"steps/0001-click/annotated.jpg\""))
        #expect(metaText.contains("action_type: \"click\""))
    }

    @Test("highestExistingIndex finds gaps and returns max")
    func highestIndex() throws {
        let dir = try makeTempRecording()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Empty steps dir → 0
        #expect(StepFolderWriter.highestExistingIndex(in: dir) == 0)

        // Fake three folders with non-contiguous indices.
        let stepsRoot = "\(dir)/steps"
        try FileManager.default.createDirectory(atPath: stepsRoot, withIntermediateDirectories: true)
        for name in ["0001-click", "0007-typeText", "0003-keyPress"] {
            try FileManager.default.createDirectory(
                atPath: "\(stepsRoot)/\(name)",
                withIntermediateDirectories: true
            )
        }
        #expect(StepFolderWriter.highestExistingIndex(in: dir) == 7)
    }

    @Test("events.jsonl appends one line per call")
    func eventsJsonlAppend() throws {
        let dir = try makeTempRecording()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        EventsJSONLWriter.append(to: dir, entry: ["idx": 1, "summary": "first"])
        EventsJSONLWriter.append(to: dir, entry: ["idx": 2, "summary": "second"])
        EventsJSONLWriter.append(to: dir, entry: ["idx": 2, "summary": "second-updated"])

        let path = EventsJSONLWriter.path(for: dir)
        let body = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"first\""))
        #expect(lines[2].contains("\"second-updated\""))
    }

    @Test("YAMLEmit is deterministic across runs")
    func yamlDeterminism() {
        let input: [String: Any] = [
            "z": "last",
            "a": 1,
            "m": ["nested": "value", "ordered": true],
            "list": ["first", 2, false],
        ]
        let a = YAMLEmit.mapping(input)
        let b = YAMLEmit.mapping(input)
        #expect(a == b)

        // Sorted keys: 'a' before 'list' before 'm' before 'z'.
        let aPos = a.range(of: "a:")!.lowerBound
        let listPos = a.range(of: "list:")!.lowerBound
        let mPos = a.range(of: "m:")!.lowerBound
        let zPos = a.range(of: "z:")!.lowerBound
        #expect(aPos < listPos)
        #expect(listPos < mPos)
        #expect(mPos < zPos)
    }

    @Test("EventsFinalizer sorts + renumbers + renames + rewrites meta.yaml")
    func sortAndRenumber() throws {
        let dir = try makeTempRecording()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Three steps appended in this order:
        //   0001-click       at t=200
        //   0002-narration   at t=100   ← out of order
        //   0003-click       at t=300
        // After sort: narration first (t=100), then the two clicks.
        // The two clicks SWAP slots (0001-click ↔ 0002-click), which
        // exercises the two-phase rename path.
        try makeStepFolder(dir: dir, name: "0001-click", ts: 200, screenshot: "steps/0001-click/screenshot.jpg")
        try makeStepFolder(dir: dir, name: "0002-narration", ts: 100, screenshot: nil)
        try makeStepFolder(dir: dir, name: "0003-click", ts: 300, screenshot: "steps/0003-click/screenshot.jpg")

        // events.jsonl with the same three lines.
        let lines = [
            #"{"idx":1,"step_dir":"steps/0001-click","action_type":"click","timestamp_ms":200,"summary":"first click"}"#,
            #"{"idx":2,"step_dir":"steps/0002-narration","action_type":"narration","timestamp_ms":100,"summary":"narration: hello"}"#,
            #"{"idx":3,"step_dir":"steps/0003-click","action_type":"click","timestamp_ms":300,"summary":"second click"}"#,
        ]
        let eventsPath = "\(dir)/events.jsonl"
        try lines.joined(separator: "\n").write(toFile: eventsPath, atomically: true, encoding: .utf8)

        EventsFinalizer.sortAndRenumber(in: dir)

        // Folders renamed to time-order.
        #expect(FileManager.default.fileExists(atPath: "\(dir)/steps/0001-narration"))
        #expect(FileManager.default.fileExists(atPath: "\(dir)/steps/0002-click"))
        #expect(FileManager.default.fileExists(atPath: "\(dir)/steps/0003-click"))
        // The original out-of-order folder names are gone.
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/steps/0002-narration"))

        // events.jsonl is now sorted by timestamp_ms with renumbered idx
        // and rewritten step_dir paths.
        let rewritten = try String(contentsOf: URL(fileURLWithPath: eventsPath), encoding: .utf8)
        let outLines = rewritten.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(outLines.count == 3)
        #expect(outLines[0].contains("\"idx\":1") && outLines[0].contains("\"step_dir\":\"steps/0001-narration\""))
        #expect(outLines[1].contains("\"idx\":2") && outLines[1].contains("\"step_dir\":\"steps/0002-click\""))
        #expect(outLines[2].contains("\"idx\":3") && outLines[2].contains("\"step_dir\":\"steps/0003-click\""))

        // meta.yaml in the renamed click folder has its screenshot path
        // rewritten to point at the new step_dir.
        let movedClickMeta = try String(
            contentsOf: URL(fileURLWithPath: "\(dir)/steps/0002-click/meta.yaml"),
            encoding: .utf8
        )
        #expect(movedClickMeta.contains("steps/0002-click/screenshot.jpg"))
        #expect(!movedClickMeta.contains("steps/0001-click/screenshot.jpg"))
    }

    @Test("EventsFinalizer is idempotent on already-sorted recordings")
    func sortAndRenumberIdempotent() throws {
        let dir = try makeTempRecording()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try makeStepFolder(dir: dir, name: "0001-click", ts: 100, screenshot: "steps/0001-click/screenshot.jpg")
        try makeStepFolder(dir: dir, name: "0002-click", ts: 200, screenshot: "steps/0002-click/screenshot.jpg")
        let lines = [
            #"{"idx":1,"step_dir":"steps/0001-click","action_type":"click","timestamp_ms":100}"#,
            #"{"idx":2,"step_dir":"steps/0002-click","action_type":"click","timestamp_ms":200}"#,
        ].joined(separator: "\n") + "\n"
        let eventsPath = "\(dir)/events.jsonl"
        try lines.write(toFile: eventsPath, atomically: true, encoding: .utf8)

        EventsFinalizer.sortAndRenumber(in: dir)
        let firstPass = try String(contentsOf: URL(fileURLWithPath: eventsPath), encoding: .utf8)
        EventsFinalizer.sortAndRenumber(in: dir)
        let secondPass = try String(contentsOf: URL(fileURLWithPath: eventsPath), encoding: .utf8)
        #expect(firstPass == secondPass)
        #expect(FileManager.default.fileExists(atPath: "\(dir)/steps/0001-click"))
        #expect(FileManager.default.fileExists(atPath: "\(dir)/steps/0002-click"))
    }

    @Test("YAMLEmit handles strings, bools, multi-line, and null")
    func yamlBasics() {
        let yaml = YAMLEmit.mapping([
            "title": "Hello, world",
            "active": true,
            "count": 42,
            "ratio": 1.5,
            "missing": NSNull(),
            "essay": "line one\nline two",
        ])
        #expect(yaml.contains("title: \"Hello, world\""))
        #expect(yaml.contains("active: true"))
        #expect(yaml.contains("count: 42"))
        #expect(yaml.contains("missing: null"))
        // Bool isn't emitted as 1.
        #expect(!yaml.contains("active: 1"))
        // Literal block scalar for newline-bearing strings.
        #expect(yaml.contains("essay: |"))
        #expect(yaml.contains("  line one"))
        #expect(yaml.contains("  line two"))
    }

    // MARK: - Helpers

    private func makeTempRecording() throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow42-v2-test-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func stageScreenshot(in dir: String, name: String, bytes: [UInt8]) -> String {
        let shotsDir = "\(dir)/screenshots"
        try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
        let path = "\(shotsDir)/\(name)"
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
        return path
    }

    /// Materialise a step folder + meta.yaml on disk in the v2 shape.
    /// Used by the EventsFinalizer tests to seed the layout we're about
    /// to renumber.
    private func makeStepFolder(
        dir: String,
        name: String,
        ts: Int64,
        screenshot: String?
    ) throws {
        let folder = "\(dir)/steps/\(name)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var meta = "action_type: \"\(name.split(separator: "-", maxSplits: 1).last ?? "")\"\n"
        meta += "timestamp_ms: \(ts)\n"
        if let screenshot {
            meta += "screenshot: \"\(screenshot)\"\n"
            // Materialise the screenshot file too so a future test can
            // assert the file moved with the folder rename.
            let absShot = (dir as NSString).appendingPathComponent(screenshot)
            try? FileManager.default.createDirectory(
                atPath: (absShot as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: absShot, contents: Data([0x89, 0x50]))
        }
        try meta.write(toFile: "\(folder)/meta.yaml", atomically: true, encoding: .utf8)
    }
}
