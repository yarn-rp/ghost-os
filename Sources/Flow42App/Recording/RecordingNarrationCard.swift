// RecordingNarrationCard.swift - Renders the recording's full
// narration transcript when whisper transcribed it. Hidden when the
// recording has no narration (mic permission denied, AVAudioEngine
// failure, or the user just didn't talk).
//
// The transcript lives at `<dir>/audio/narration.txt`. Per-utterance
// narration events also appear inline in the events list (with their
// timestamps); this card surfaces the full text in one place so the
// user can scan it without scrolling through every step.

import AppKit
import Flow42Core
import Foundation
import SwiftUI

struct RecordingNarrationCard: View {
    let dir: String

    @State private var transcript: String = ""
    @State private var hasAudio: Bool = false
    @State private var loading: Bool = true

    var body: some View {
        Group {
            if loading {
                placeholder
            } else if !hasAudio && transcript.isEmpty {
                // No audio at all (mic disabled / permission denied)
                // — render nothing rather than an empty card.
                EmptyView()
            } else {
                content
            }
        }
        .task(id: dir) { await load() }
    }

    private var placeholder: some View {
        // Quietly indicate we're checking; don't reserve a card-shaped
        // space because most recordings won't have narration anyway.
        EmptyView()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: DT.f11, weight: .medium))
                    .foregroundStyle(.secondary)
                sectionLabel("Narration")
                Spacer()
                if hasAudio {
                    Button {
                        let wav = (dir as NSString)
                            .appendingPathComponent("audio")
                            .appending("/narration.wav")
                        if FileManager.default.fileExists(atPath: wav) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: wav))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Play audio")
                                .font(.system(size: DT.f10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open narration.wav in the default audio player")
                }
            }
            if transcript.isEmpty {
                Text("Audio captured, transcript unavailable.")
                    .font(.system(size: DT.f12))
                    .foregroundStyle(.secondary)
            } else {
                Text(transcript)
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardSurface()
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: DT.f10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }

    private func load() async {
        loading = true
        let dir = self.dir
        let result = await Task.detached(priority: .userInitiated) {
            NarrationLoader.load(dir: dir)
        }.value
        self.transcript = result.transcript
        self.hasAudio = result.hasAudio
        self.loading = false
    }
}

nonisolated enum NarrationLoader {
    struct Result {
        let transcript: String
        let hasAudio: Bool
    }

    static func load(dir: String) -> Result {
        let audioDir = (dir as NSString).appendingPathComponent("audio")
        let wav = (audioDir as NSString).appendingPathComponent("narration.wav")
        let txt = (audioDir as NSString).appendingPathComponent("narration.txt")
        let hasAudio = FileManager.default.fileExists(atPath: wav)
        let transcript: String = {
            guard FileManager.default.fileExists(atPath: txt),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: txt)),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        return Result(transcript: transcript, hasAudio: hasAudio)
    }
}
