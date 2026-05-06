// RecordingEventsList.swift - Static list of events captured during a
// recording, rendered on the RecordingHandoffView.
//
// Mirrors the floating panel's event list (Flow42Menu's `EventRow`)
// but slimmed down: no live tail, no replicate-copy hover, no
// pagination — the recording is finalised by the time we get here so
// `events.jsonl` is read once and rendered as-is. Each row shows
// the verb badge, the recorder-built summary, a screenshot thumbnail
// when one exists, and the offset from the recording start.

import AppKit
import Flow42Core
import Foundation
import SwiftUI

/// Lightweight typed projection of one `events.jsonl` line. Mirrors
/// the menu's `TimelineEvent` shape but lives in Flow42App so we
/// don't drag the menu module's UI across.
struct RecordingEventEntry: Identifiable, Equatable {
    let id: String
    let actionType: String
    let summary: String
    let target: String?
    let timestampMs: Int64?
    let screenshotPath: String?
}

nonisolated enum RecordingEventsLoader {
    /// Read `<dir>/events.jsonl` and return rows in chronological
    /// order. Dedupes on `step_dir` (last-write-wins) the same way
    /// the menu's `TimelineModel` does — coalesced typeText edits
    /// emit fresh lines and we want the latest. Returns an empty
    /// array if the file is missing or empty (caller renders an
    /// empty state). Pure file I/O — safe to call off the main
    /// actor.
    static func load(dir: String) -> [RecordingEventEntry] {
        let path = (dir as NSString).appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        // Walk lines, parse, dedup on step_dir (keep last seen).
        var byKey: [String: (idx: Int, dict: [String: Any])] = [:]
        var nextIdx = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else { continue }
            let key = (dict["step_dir"] as? String) ?? "_anon-\(nextIdx)"
            byKey[key] = (idx: nextIdx, dict: dict)
            nextIdx += 1
        }
        // Re-sort by first-seen order using `idx` so the timeline
        // renders in capture order even after dedup.
        let ordered = byKey.values.sorted { $0.idx < $1.idx }
        return ordered.enumerated().map { i, pair in
            entry(from: pair.dict, dir: dir, fallbackIndex: i)
        }
    }

    private static func entry(
        from dict: [String: Any], dir: String, fallbackIndex: Int
    ) -> RecordingEventEntry {
        let actionType = (dict["action_type"] as? String) ?? "unknown"
        let stepDir = (dict["step_dir"] as? String) ?? ""
        let summary = (dict["summary"] as? String) ?? actionType
        let target = dict["target"] as? String
        let timestampMs = dict["timestamp_ms"] as? Int64
            ?? (dict["timestamp_ms"] as? Int).map(Int64.init)
        let screenshotPath: String? = {
            guard !stepDir.isEmpty else { return nil }
            let abs = (dir as NSString).appendingPathComponent(stepDir)
            // Prefer the annotated screenshot (click marker, drag
            // path) when one exists — that's what the recorder
            // writes for clicks / drags / highlights.
            let annotated = (abs as NSString).appendingPathComponent("annotated.jpg")
            if FileManager.default.fileExists(atPath: annotated) { return annotated }
            let region = (abs as NSString).appendingPathComponent("region.png")
            if FileManager.default.fileExists(atPath: region) { return region }
            let raw = (abs as NSString).appendingPathComponent("screenshot.jpg")
            if FileManager.default.fileExists(atPath: raw) { return raw }
            return nil
        }()
        let id = stepDir.isEmpty ? "row-\(fallbackIndex)" : stepDir
        return RecordingEventEntry(
            id: id,
            actionType: actionType,
            summary: summary,
            target: target,
            timestampMs: timestampMs,
            screenshotPath: screenshotPath
        )
    }
}

/// Rendered list of events captured during a recording. Pure read —
/// no FSEvents tail, no per-row interaction beyond opening the
/// thumbnail in Preview on double-click.
struct RecordingEventsList: View {
    let dir: String

    @State private var events: [RecordingEventEntry] = []
    @State private var loading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Captured events")
                Spacer()
                if !events.isEmpty {
                    Text("\(events.count)")
                        .font(.system(size: DT.f10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardSurface()
        .task(id: dir) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading events…")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.tertiary)
            }
        } else if events.isEmpty {
            Text("No events were captured in this recording.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .padding(.vertical, DT.s4)
        } else {
            VStack(spacing: 0) {
                let anchor = events.first?.timestampMs
                ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                    EventRowView(event: event, anchor: anchor)
                    if idx < events.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        let dir = self.dir
        let result = await Task.detached(priority: .userInitiated) {
            RecordingEventsLoader.load(dir: dir)
        }.value
        self.events = result
        self.loading = false
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: DT.f10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

/// One event row. Verb badge + summary + offset + optional
/// thumbnail. No hover-copy / replicate command — the floating
/// panel keeps that for live-recording use; here the user just
/// wants to scan what they captured before processing.
private struct EventRowView: View {
    let event: RecordingEventEntry
    let anchor: Int64?
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            Text(timeOffsetLabel)
                .font(.system(size: DT.f10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 2)
            verbBadge.padding(.top, 1)
            if let path = event.screenshotPath {
                Thumbnail(path: path)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(.system(size: DT.f12))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if let target = event.target, !target.isEmpty {
                    Text(target)
                        .font(.system(size: DT.f10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 1)
        }
        .padding(.horizontal, DT.s4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) {
            if let path = event.screenshotPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    private var timeOffsetLabel: String {
        guard let ts = event.timestampMs, let anchor else { return "—" }
        let delta = ts - anchor
        if delta < 0 { return "—" }
        return String(format: "+%05.2fs", Double(delta) / 1000.0)
    }

    private var verbBadge: some View {
        let color = badgeColor(for: event.actionType)
        return Text(badgeLabel(for: event.actionType))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
            .frame(width: 60, alignment: .leading)
    }

    private func badgeLabel(for type: String) -> String {
        switch type {
        case "click": return "CLICK"
        case "typeText": return "TYPE"
        case "keyPress": return "KEY"
        case "hotkey": return "HOTKEY"
        case "scroll": return "SCROLL"
        case "appSwitch": return "APP"
        case "urlChange": return "NAV"
        case "newTab": return "TAB"
        case "tabSwitch": return "TAB"
        case "narration": return "VOICE"
        case "highlight": return "HILITE"
        case "drag": return "DRAG"
        default: return type.uppercased()
        }
    }

    private func badgeColor(for type: String) -> Color {
        switch type {
        case "click", "drag": return DT.magenta
        case "typeText", "keyPress", "hotkey": return DT.cyan
        case "scroll": return DT.orange
        case "appSwitch", "urlChange", "newTab", "tabSwitch": return .secondary
        case "narration": return DT.amber
        case "highlight": return DT.amber
        default: return .secondary
        }
    }
}

private struct Thumbnail: View {
    let path: String
    var body: some View {
        if let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: DT.rInput, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DT.rInput, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: DT.rInput, style: .continuous)
                .fill(.primary.opacity(0.05))
                .frame(width: 64, height: 40)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(.tertiary)
                )
        }
    }
}
