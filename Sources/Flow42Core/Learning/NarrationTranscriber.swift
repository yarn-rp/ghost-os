// NarrationTranscriber.swift - Shell out to whisper-cli to transcribe
// narration.wav after a recording stops.
//
// Why subprocess instead of embedding whisper.cpp: avoids a ~50 MB C++
// SwiftPM dep, slow rebuilds, and Swift 6.2 strict-concurrency friction
// with C bindings. Same engine, far simpler integration.
//
// Setup (per-machine, once):
//   brew install whisper-cpp
// The first transcription auto-downloads ggml-base.en.bin (~142 MB) into
// ~/.openclaw/flow42/models/.

import Foundation

nonisolated public enum NarrationTranscriber {

    public struct Segment: Sendable {
        public let startMs: Int     // ms since recording start (whisper-relative)
        public let endMs: Int
        public let text: String
    }

    public enum TranscribeError: Error, LocalizedError {
        case whisperNotFound
        case modelDownloadFailed(any Error)
        case whisperFailed(stderr: String)
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .whisperNotFound:
                return "whisper-cli not found. Install with: brew install whisper-cpp"
            case .modelDownloadFailed(let e):
                return "model download failed: \(e.localizedDescription)"
            case .whisperFailed(let s):
                return "whisper-cli failed: \(s.prefix(200))"
            case .parseFailed(let s):
                return "could not parse whisper output: \(s)"
            }
        }
    }

    /// Transcribe `wavURL` synchronously. Auto-downloads the base.en model on
    /// first use. Returns one Segment per phrase.
    public static func transcribe(wavURL: URL) throws -> [Segment] {
        guard let whisperPath = findWhisperCli() else { throw TranscribeError.whisperNotFound }
        let modelURL = try ensureModel()

        // whisper-cli writes the JSON next to the WAV with the same base name.
        let outBase = wavURL.deletingPathExtension().path

        let task = Process()
        task.executableURL = URL(fileURLWithPath: whisperPath)
        task.arguments = [
            "-m", modelURL.path,
            "-f", wavURL.path,
            "-oj",                     // JSON output
            "-of", outBase,
            "-l", "en",
            "--no-prints",
        ]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let errStr = String(data: errData ?? Data(), encoding: .utf8) ?? ""
            throw TranscribeError.whisperFailed(stderr: errStr)
        }

        let jsonURL = URL(fileURLWithPath: outBase + ".json")
        return try parseSegments(at: jsonURL)
    }

    // MARK: - Internals

    private static func findWhisperCli() -> String? {
        // Common Homebrew install paths first, then PATH.
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",         // Apple Silicon
            "/usr/local/bin/whisper-cli",            // Intel Mac
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Fallback: ask the shell.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-lc", "command -v whisper-cli"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let data = try? out.fileHandleForReading.readToEnd(),
              let path = String(data: data ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    private static func ensureModel() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let modelsDir = home
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("flow42")
            .appendingPathComponent("models")
        try FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true
        )
        let modelURL = modelsDir.appendingPathComponent("ggml-base.en.bin")
        if FileManager.default.fileExists(atPath: modelURL.path) {
            return modelURL
        }
        FileHandle.standardError.write(Data("[narration] downloading whisper base.en model (~142 MB)…\n".utf8))
        let src = URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
        )!
        do {
            let data = try Data(contentsOf: src)
            try data.write(to: modelURL)
            FileHandle.standardError.write(Data("[narration] model saved to \(modelURL.path)\n".utf8))
            return modelURL
        } catch {
            try? FileManager.default.removeItem(at: modelURL)
            throw TranscribeError.modelDownloadFailed(error)
        }
    }

    private static func parseSegments(at url: URL) throws -> [Segment] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw TranscribeError.parseFailed("could not read \(url.path): \(error.localizedDescription)") }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscribeError.parseFailed("root is not an object")
        }
        guard let raw = root["transcription"] as? [[String: Any]] else {
            throw TranscribeError.parseFailed("missing transcription[] array")
        }
        var out: [Segment] = []
        for entry in raw {
            // whisper-cli's JSON shape:
            //   { offsets: { from: <ms>, to: <ms> }, text: "..." }
            let text = (entry["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let offsets = entry["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? Int)
                ?? (offsets?["from"] as? Double).map { Int($0) }
                ?? 0
            let to = (offsets?["to"] as? Int)
                ?? (offsets?["to"] as? Double).map { Int($0) }
                ?? from
            out.append(Segment(startMs: from, endMs: to, text: text))
        }
        return out
    }
}
