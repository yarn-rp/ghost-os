// PlayId.swift - Stable, sortable, human-readable play ids.
//
// Format: YYYYMMDD-HHMMSS-<state>-<by>
//   20260502-143022-driving-claude
//
// The leading timestamp ensures lexicographic = chronological sort. The state
// + by suffix makes ids self-describing in the file system.

import Foundation

public enum PlayId {
    public static func generate(state: PlayInfo.State, startedBy: String) -> String {
        let now = Date()
        let cal = Calendar(identifier: .iso8601)
        let comp = cal.dateComponents(
            in: TimeZone.current, from: now
        )
        let ts = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            comp.year ?? 0, comp.month ?? 0, comp.day ?? 0,
            comp.hour ?? 0, comp.minute ?? 0, comp.second ?? 0
        )
        let safeBy = startedBy
            .lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return "\(ts)-\(state.rawValue)-\(safeBy)"
    }
}
