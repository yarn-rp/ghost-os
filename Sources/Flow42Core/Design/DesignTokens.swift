// DesignTokens.swift - The single source of truth for spacing, radii,
// typography, animations, and color across both apps.
//
// Lives in Flow42Core because both Flow42Menu (the floating panel +
// recording overlays) and Flow42App (the main window) consume them.
// One place to edit the visual language.
//
// Naming: short for legibility at call sites — `DT.s12`, `DT.rCard`,
// `DT.aMode`. Long names like `Tokens.spacingMedium` get noisy.
//
// Light/dark colors: each color is built from hand-tuned light + dark
// hex pairs via `NSColor(name:dynamicProvider:)`. We do NOT directly
// invert RGB values for dark mode — accents stay the same hue, only
// luminance shifts to keep them readable in both contexts.

import AppKit
import SwiftUI

public enum DT {

    // MARK: - Spacing (4-pt grid)

    public static let s4: CGFloat = 4    // tight icon gaps
    public static let s8: CGFloat = 8    // chip / compact row gaps
    public static let s12: CGFloat = 12  // row internal padding
    public static let s16: CGFloat = 16  // group spacing
    public static let s20: CGFloat = 20  // panel edge padding
    public static let s24: CGFloat = 24  // section internal
    public static let s32: CGFloat = 32  // header → content
    public static let s40: CGFloat = 40  // major sections

    // MARK: - Corner radii
    //
    // 10/8/6/4 hierarchy from the macOS-design discipline:
    // windows/panels > cards > buttons > inputs.

    public static let rWindow: CGFloat = 10
    public static let rPanel: CGFloat = 12   // glass panels feel slightly softer
    public static let rCard: CGFloat = 8
    public static let rButton: CGFloat = 6
    public static let rInput: CGFloat = 4
    public static let rPill: CGFloat = 999   // capsule

    // MARK: - Type scale

    public static let f9: CGFloat = 9     // micro-eyebrow / count badges
    public static let f10: CGFloat = 10   // eyebrow
    public static let f11: CGFloat = 11   // caption
    public static let f12: CGFloat = 12   // small body
    public static let f13: CGFloat = 13   // body
    public static let f14: CGFloat = 14   // body emphasis
    public static let f15: CGFloat = 15   // subtitle
    public static let f17: CGFloat = 17   // section title
    public static let f22: CGFloat = 22   // page title
    public static let f30: CGFloat = 30   // display
    public static let f32: CGFloat = 32   // hero

    // MARK: - Animation curves

    /// Hover, press, light feedback. Snappy, not springy.
    public static let aHover = Animation.easeOut(duration: 0.12)
    /// Mode swaps: panel chat-only ↔ compact, card expand, segmented
    /// control crossfade. The "default" curve.
    public static let aMode = Animation.easeInOut(duration: 0.18)
    /// Larger entrances: window appears, dock slides in, palette opens.
    public static let aEntrance = Animation.easeInOut(duration: 0.24)

    // MARK: - Brand palette
    //
    // The THREE canonical Flow42 colors are the ones the edge-glow
    // overlay uses to signal session state. Treat them as the app's
    // primary palette; reach for them before any system gray. Each one
    // ties to a specific user mental model:
    //
    //   ORANGE   — driving (agent in control of the screen)
    //   MAGENTA  — recording (we're capturing user actions)
    //   CYAN     — watching (user is in control / guide-me mode)
    //
    // Each brand color has three gradient stops (`core` / `mid` /
    // `edge`) so we can build proper depth — light center, mid body,
    // dark fringe — instead of flat fills. Use the `Gradient(stops:)`
    // helpers below to build glowing pills, hero backdrops, etc.

    /// MAGENTA — the dominant Flow42 brand color. Matches the violet
    /// shade of the edge-glow overlay + the recording panel's accent.
    /// Reach for this BEFORE orange or cyan in any default-accent
    /// situation; the others are situational (orange = driving / agent
    /// active, cyan = watching / user-driven).
    public static let magenta = adaptive(light: 0x7C3AED, dark: 0x9D6BFF)
    /// Orange — driving / agent in control. Used when the agent is
    /// actively touching the screen.
    public static let orange  = adaptive(light: 0xFF8A3D, dark: 0xFFA060)
    /// Cyan — watching / guide-me / user-in-control. Calm interaction.
    public static let cyan    = adaptive(light: 0x3DB6FF, dark: 0x66C8FF)

    // Brand gradient stops (core / mid / edge) — same triplet pattern
    // OrbStateTokens already uses for the menu-bar orb, lifted into the
    // shared design system so both apps draw on the same well.

    public static let magentaCore = adaptive(light: 0xC4B5FD, dark: 0xD8C7FF)
    public static let magentaMid  = magenta
    public static let magentaEdge = adaptive(light: 0x4C1D95, dark: 0x5B21B6)

    public static let orangeCore = adaptive(light: 0xFFD4A8, dark: 0xFFE3C2)
    public static let orangeMid  = orange
    public static let orangeEdge = adaptive(light: 0x7C2D12, dark: 0x9A3A18)

    public static let cyanCore   = adaptive(light: 0xA8E7FF, dark: 0xC2EEFF)
    public static let cyanMid    = cyan
    public static let cyanEdge   = adaptive(light: 0x12527C, dark: 0x1A6796)

    // MARK: - Brand gradients
    //
    // Linear-gradient helpers for the three brand colors. Pass these
    // straight to `.fill(DT.orangeGradient)` etc. The default angle is
    // top-leading → bottom-trailing which feels like light coming from
    // the top-left (matches macOS native conventions).

    public static let orangeGradient = LinearGradient(
        colors: [orangeCore, orangeMid],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let cyanGradient = LinearGradient(
        colors: [cyanCore, cyanMid],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let magentaGradient = LinearGradient(
        colors: [magentaCore, magentaMid],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Three-color sweep across the brand palette (orange → magenta →
    /// cyan). Used for hero backdrops + the app's "everything-at-once"
    /// brand moments (loading-from-empty, splash, the command palette
    /// header).
    public static let brandSweep = LinearGradient(
        colors: [orange, magenta, cyan],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Status palette (sparingly — reserve real estate for brand)

    public static let green   = adaptive(light: 0x36C85B, dark: 0x4CDB73)
    public static let red     = adaptive(light: 0xFF5C5C, dark: 0xFF7A7A)
    public static let amber   = adaptive(light: 0xFFB640, dark: 0xFFC766)

    // Aliases for compatibility — the chat code already uses these
    // names. Maps onto the brand palette where it makes sense.
    public static let blue    = cyan        // chat user bubbles, watching state
    public static let purple  = magenta     // tool calls (lean into magenta)

    // MARK: - Surface palette
    //
    // Darker than macOS defaults in dark mode — the app is meant to
    // feel cinematic / Cursor-Linear-Arc-like rather than pale grey.
    // Three tiers so cards still read as elevated against the page.

    /// L0 — page backdrop. Near-black in dark mode with a faint cool
    /// cast so it doesn't go fully neutral. Light mode keeps a clean
    /// off-white so vibrancy still works behind the chrome.
    public static let backdrop = adaptive(light: 0xF5F5F7, dark: 0x09090B)
    /// L1 — card / surface above the page. ~RGB 26 in dark mode so
    /// cards have a clear elevation read against the backdrop without
    /// looking grey.
    public static let surface  = adaptive(light: 0xFFFFFF, dark: 0x1A1A1D)
    /// L2 — popover / interactive surface (input fields, raised
    /// menus). Slightly lifted above L1.
    public static let elevated = adaptive(light: 0xFFFFFF, dark: 0x222226)

    // MARK: - Helpers

    /// Builds a SwiftUI `Color` that resolves to the right hex per the
    /// current system appearance. Uses NSColor's name-based dynamic
    /// provider so the choice happens at draw-time, not init-time —
    /// users toggling Dark Mode mid-session see colors update without
    /// us having to rebuild views.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

// MARK: - NSColor hex helper

private extension NSColor {
    /// `0xRRGGBB` → NSColor (sRGB, alpha 1).
    convenience init(rgb hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
