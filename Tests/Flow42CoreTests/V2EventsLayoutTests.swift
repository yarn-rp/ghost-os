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
}
