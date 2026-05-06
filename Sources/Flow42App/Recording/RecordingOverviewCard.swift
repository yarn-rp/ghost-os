// RecordingOverviewCard.swift - Surface a recording's `meta.yaml`
// summary on the handoff page.
//
// `meta.yaml` is what the recorder writes once finalisation
// completes — duration, action count, apps the user touched, URLs
// visited (browser recordings), task description, recorded-at
// timestamp. Showing it up-top on the handoff view gives the user
// context for what they captured before they hand it off to
// flow-creator.

import AppKit
import Flow42Core
import Foundation
import SwiftUI
import Yams

nonisolated struct RecordingMetaSummary: Equatable, Sendable {
    let actionCount: Int
    let durationSeconds: Int
    let recordedAt: String?
    let taskDescription: String?
    let apps: [String]
    let urls: [String]

    static let empty = RecordingMetaSummary(
        actionCount: 0,
        durationSeconds: 0,
        recordedAt: nil,
        taskDescription: nil,
        apps: [],
        urls: []
    )
}

nonisolated enum RecordingMetaLoader {
    /// Read `<dir>/meta.yaml` and project it into a typed summary.
    /// Returns `.empty` when the file is missing or unparseable —
    /// callers can render a "metadata not yet finalised" state.
    static func load(dir: String) -> RecordingMetaSummary {
        let path = (dir as NSString).appendingPathComponent("meta.yaml")
        guard FileManager.default.fileExists(atPath: path),
              let yamlString = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8),
              let parsed = try? Yams.load(yaml: yamlString) as? [String: Any] else {
            return .empty
        }
        return RecordingMetaSummary(
            actionCount: parsed["action_count"] as? Int ?? 0,
            durationSeconds: parsed["duration_seconds"] as? Int ?? 0,
            recordedAt: parsed["recorded_at"] as? String,
            taskDescription: (parsed["task_description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            apps: (parsed["apps"] as? [String]) ?? [],
            urls: (parsed["urls"] as? [String]) ?? []
        )
    }
}

/// Compact card with the recording's high-level numbers + apps +
/// URLs. Sits above the event list on the handoff page so the user
/// gets a "what did I capture?" snapshot before scrolling through
/// every event.
struct RecordingOverviewCard: View {
    let dir: String

    @State private var meta: RecordingMetaSummary = .empty
    @State private var loading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            sectionLabel("Overview")
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading meta.yaml…")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.tertiary)
                }
            } else {
                statsRow
                if let task = meta.taskDescription, !task.isEmpty {
                    Text(task)
                        .font(.system(size: DT.f12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DT.s4)
                }
                if !meta.apps.isEmpty {
                    chipRow(label: "Apps", icon: "app", values: meta.apps, tint: DT.cyan)
                }
                if !meta.urls.isEmpty {
                    chipRow(label: "URLs", icon: "link", values: meta.urls, tint: DT.magenta)
                }
            }
        }
        .padding(DT.s20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardSurface()
        .task(id: dir) { await load() }
    }

    private var statsRow: some View {
        HStack(spacing: DT.s16) {
            stat(symbol: "stopwatch", label: "duration",
                 value: meta.durationSeconds == 0 ? "—" : "\(meta.durationSeconds)s")
            stat(symbol: "list.bullet", label: "actions",
                 value: "\(meta.actionCount)")
            stat(symbol: "calendar", label: "recorded",
                 value: friendlyDate(meta.recordedAt))
            Spacer(minLength: 0)
        }
    }

    private func stat(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: DT.f11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: DT.f13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.system(size: DT.f10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func chipRow(label: String, icon: String, values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: DT.f10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(label.uppercased())
                    .font(.system(size: DT.f10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            // Wrapping HStack via FlowLayout-style would be nicer but
            // we keep it simple with a horizontal scroll for >5 chips.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(values, id: \.self) { v in
                        chip(text: v, tint: tint)
                    }
                }
            }
        }
        .padding(.top, DT.s4)
    }

    private func chip(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: DT.f11, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }

    private func friendlyDate(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
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
            RecordingMetaLoader.load(dir: dir)
        }.value
        self.meta = result
        self.loading = false
    }
}
