// OrbStateTokens.swift - Swift port of davos `orb_state_tokens.dart`.
//
// Same hex values, same intensity/pulse/movement scalars. Flow42 only uses
// three of the five davos states:
//
//   davos `idle`      → flow42 `.idle`        (no glow drawn)
//   davos `listening` → flow42 `.recording`   (magenta — "we're capturing")
//   davos `speaking`  → flow42 `.autonomous`  (orange  — "agent is driving")
//
// We intentionally don't expose `thinking` or `error` here; the menu app's
// rotation is just two visible states + idle. Annotations have their own
// dedicated overlay UI and don't repurpose the edge glow.

import Flow42Core
import SwiftUI

struct OrbStateTokens {
    let core: Color
    let mid: Color
    let edge: Color
    let intensity: Double
    let pulse: Double
    let movement: Double

    /// Map an `AppMode` from the shared state file to its glow tokens.
    /// Returns `nil` for `.idle` so callers can early-out without drawing.
    static func tokens(for mode: AppMode) -> OrbStateTokens? {
        switch mode {
        case .idle:
            return nil
        case .recording:
            // davos `listening`: magenta / violet
            return OrbStateTokens(
                core: Color(red: 0xFF/255, green: 0x3E/255, blue: 0xCB/255),
                mid:  Color(red: 0x7C/255, green: 0x3A/255, blue: 0xED/255),
                edge: Color(red: 0x1E/255, green: 0x1B/255, blue: 0x4B/255),
                intensity: 0.35,
                pulse: 1.1,
                movement: 0.9
            )
        case .autonomous:
            // davos `speaking`: orange
            return OrbStateTokens(
                core: Color(red: 0xFF/255, green: 0xD4/255, blue: 0xA8/255),
                mid:  Color(red: 0xFF/255, green: 0x8A/255, blue: 0x3D/255),
                edge: Color(red: 0x7C/255, green: 0x2D/255, blue: 0x12/255),
                intensity: 1.0,
                pulse: 2.0,
                movement: 1.5
            )
        }
    }
}

/// Linear-interpolate two `Color`s in sRGB space. Mirrors davos' `lerpHex`.
func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let clamped = max(0.0, min(1.0, t))
    let aN = NSColor(a).usingColorSpace(.sRGB) ?? NSColor.black
    let bN = NSColor(b).usingColorSpace(.sRGB) ?? NSColor.black
    let r = aN.redComponent + (bN.redComponent - aN.redComponent) * CGFloat(clamped)
    let g = aN.greenComponent + (bN.greenComponent - aN.greenComponent) * CGFloat(clamped)
    let bl = aN.blueComponent + (bN.blueComponent - aN.blueComponent) * CGFloat(clamped)
    let al = aN.alphaComponent + (bN.alphaComponent - aN.alphaComponent) * CGFloat(clamped)
    return Color(.sRGB, red: r, green: g, blue: bl, opacity: al)
}
