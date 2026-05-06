// AudioRecorder.swift - Microphone capture for narration.
//
// Captures the default mic at 16 kHz mono PCM (signed 16-bit little-endian)
// and writes a WAV file at <recordingDir>/audio/narration.wav. Transcription is
// performed offline by `whisper-cli` after the recording stops — see
// NarrationTranscriber.swift.
//
// The reason we don't use SFSpeechRecognizer: as of macOS 26.x the framework
// silently fails to deliver results in many CLI / non-bundled contexts. We
// burned a debugging session confirming that buffers flow into the request
// and the task stays alive but results=0. Whisper is reliable, on-device,
// and produces segment-level timestamps we can interleave into flow.json.

import AVFoundation
import Foundation

nonisolated private func log(_ message: String) {
    FileHandle.standardError.write(Data("[narration] \(message)\n".utf8))
}

nonisolated public final class AudioRecorder: @unchecked Sendable {

    public enum StartError: Error, LocalizedError {
        case alreadyRecording
        case permissionPending
        case permissionDenied
        case fileError(any Error)
        case engineError(any Error)

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording:  return "audio recorder already running"
            case .permissionPending: return "microphone prompt fired — accept it, then re-record"
            case .permissionDenied:  return "microphone permission denied"
            case .fileError(let e):  return "WAV file: \(e.localizedDescription)"
            case .engineError(let e): return "audio engine: \(e.localizedDescription)"
            }
        }
    }

    public static let shared = AudioRecorder()
    private init() {}

    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private(set) public var outputURL: URL?
    private var isRunning = false
    private var bufferCount = 0
    private var lastBufferLog = Date.distantPast
    /// Built lazily inside the tap closure once we've observed the first
    /// buffer's real format. Avoids the macOS-14 "format mismatch"
    /// exception we'd raise if we tried to install the tap with a
    /// pre-computed format that diverges from the bus's hardware-
    /// canonical one.
    private var cachedConverter: AVAudioConverter?

    /// Start capturing the mic into `<recordingDir>/audio/narration.wav`. Returns
    /// nil on success.
    public func start(recordingDir: String) -> StartError? {
        if isRunning { return .alreadyRecording }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log("mic permission status=\(micStatus.rawValue)")
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log("mic permission resolved: \(granted)")
            }
            return .permissionPending
        }
        guard micStatus == .authorized else { return .permissionDenied }

        // Stage the WAV under audio/ so the recording dir's top level
        // stays readable (audio/, screenshots/, steps/ — that's the v2
        // shape).
        let audioDir = URL(fileURLWithPath: recordingDir)
            .appendingPathComponent("audio")
        try? FileManager.default.createDirectory(
            at: audioDir, withIntermediateDirectories: true
        )
        let url = audioDir.appendingPathComponent("narration.wav")
        outputURL = url

        // Whisper.cpp expects 16 kHz mono PCM signed-16-bit. We write the file
        // in that format directly so transcription doesn't have to resample.
        let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        do {
            outputFile = try AVAudioFile(
                forWriting: url,
                settings: writeFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            return .fileError(error)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        log("input format  sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")

        // Whisper wants 16 kHz mono Float32 internally; the file write target
        // is 16 kHz mono Int16. The tap delivers buffers in whatever format
        // the bus is configured for; we convert to our write format on the
        // fly. The converter is built lazily inside the tap closure based
        // on the FIRST buffer's actual format — that's the only way to
        // dodge the AVFoundation "format mismatch" exception macOS 14+
        // raises when the format we ask for doesn't match the bus's
        // hardware-canonical format. Passing `nil` to installTap below
        // tells AVAudioEngine to use the bus's actual format so we can
        // never desync.
        let convertFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!

        bufferCount = 0
        // Cache the converter once we've seen the first buffer's real
        // format. Held in a class storage so the closure can mutate it
        // across calls without paying the AVAudioConverter init cost
        // every buffer.
        cachedConverter = nil
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            // Build the converter on the first buffer once we know the
            // real input format. Subsequent buffers reuse it.
            if self.cachedConverter == nil {
                if let conv = AVAudioConverter(from: buf.format, to: convertFormat) {
                    self.cachedConverter = conv
                    log("converter initialised from \(buf.format.sampleRate)Hz/\(buf.format.channelCount)ch → 16kHz/1ch")
                } else {
                    log("AVAudioConverter init failed; cannot resample to 16 kHz")
                    return
                }
            }
            guard let conv = self.cachedConverter,
                  let outBuf = AVAudioPCMBuffer(
                    pcmFormat: convertFormat,
                    frameCapacity: AVAudioFrameCount(convertFormat.sampleRate)
                  ) else { return }
            var error: NSError?
            var fed = false
            let status = conv.convert(to: outBuf, error: &error) { _, outStatus in
                if !fed {
                    fed = true
                    outStatus.pointee = .haveData
                    return buf
                }
                outStatus.pointee = .noDataNow
                return nil
            }
            guard status != .error, outBuf.frameLength > 0 else {
                if let error { log("convert error: \(error.localizedDescription)") }
                return
            }
            do {
                try self.outputFile?.write(from: outBuf)
            } catch {
                log("file write error: \(error.localizedDescription)")
            }
            self.bufferCount += 1
            let now = Date()
            if now.timeIntervalSince(self.lastBufferLog) > 5.0 {
                self.lastBufferLog = now
                log("captured \(self.bufferCount) buffers")
            }
        }

        engine.prepare()
        do {
            try engine.start()
            log("audio engine started, writing \(url.path)")
        } catch {
            input.removeTap(onBus: 0)
            outputFile = nil
            return .engineError(error)
        }
        isRunning = true
        return nil
    }

    /// Stop capture. Returns the URL of the written WAV (may be partial if
    /// start failed mid-way). Calling stop on an idle recorder is a no-op.
    @discardableResult
    public func stop() -> URL? {
        guard isRunning else { return outputURL }
        isRunning = false
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let url = outputURL
        // Releasing the AVAudioFile flushes the WAV header.
        outputFile = nil
        log("stopped — \(bufferCount) buffers written to \(url?.lastPathComponent ?? "<none>")")
        return url
    }
}
