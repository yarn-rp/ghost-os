// FlowHero.swift - Fixed-height top banner for a flow detail page.
//
// Banner height = 1/3 of the main screen's height. The image is fit by
// HEIGHT (aspect-fit) so the screenshot is fully visible, never cropped.
// Letterbox space on either side is filled with a blurred copy of the
// image so the banner reads as one cinematic surface rather than a card
// floating in a void. The text stack sits on top of the image at the
// BOTTOM of the container, anchored under a darkening gradient so it
// stays legible no matter what's behind it.

import AppKit
import Flow42Core
import SwiftUI

struct FlowHero: View {
    let flow: PhaseReader.Flow
    let summary: FlowSummary
    let runCount: Int
    let onRunAutonomously: () -> Void
    let onGuideMe: () -> Void

    /// 1/3 of the main display's height. Computed at view init so it
    /// stays stable while this detail page is on-screen; if the user
    /// drags the window between displays the next push of the page
    /// recomputes against the new main display.
    private var heroHeight: CGFloat {
        let screenH = NSScreen.main?.frame.height ?? 1000
        return floor(screenH / 3)
    }

    var body: some View {
        // Both layers are FORCED to the same fixed height as the outer
        // banner. The image's natural aspect ratio is no longer allowed
        // to push the container taller; it's bounded by `heroHeight`
        // and fits inside (by height) leaving letterbox space that the
        // blurred fill underneath covers. The foreground also takes
        // the full height so its `bottomLeading` alignment anchors to
        // the OUTER container's bottom rather than to the image's.
        ZStack(alignment: .bottomLeading) {
            backdrop
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
            foreground
                .padding(.horizontal, DT.s32)
                .padding(.bottom, DT.s24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: heroHeight, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipped()
        .overlay(alignment: .bottom) {
            // Neutral hairline below the hero — the detail page no
            // longer carries a brand-accent stripe; only the run /
            // guide CTAs are coloured.
            Color.primary.opacity(0.08)
                .frame(height: 1)
        }
    }

    // MARK: - Backdrop
    //
    // Three layers, bottom-up:
    //   1. Blurred copy of the image, aspect-fill — fills any letterbox
    //      gap when the image's aspect doesn't match the banner's, and
    //      tints surrounding chrome with the dominant colours.
    //   2. Crisp image, aspect-fit by HEIGHT — guaranteed fully visible.
    //   3. Vertical + leading darkening gradients keep bottom-left text
    //      readable on top of arbitrary content.

    @ViewBuilder
    private var backdrop: some View {
        if let path = summary.heroThumbnailPath,
           let img = NSImage(contentsOfFile: path) {
            ZStack {
                // 1. Blurred fill (letterbox + colour field). Fills the
                //    full banner so any letterbox the aspect-fit image
                //    leaves at the sides is covered.
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 50, opaque: true)
                    .brightness(-0.18)
                    .clipped()

                // 2. Crisp image, FIT BY HEIGHT. We hard-constrain the
                //    height to the banner's height; width is whatever
                //    the image's aspect ratio yields. Centered in the
                //    container so letterbox is symmetric on either side.
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: heroHeight)
                    .frame(maxWidth: .infinity, alignment: .center)

                // 3. Darken bottom for text legibility
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.0),  location: 0.0),
                        .init(color: Color.black.opacity(0.25), location: 0.5),
                        .init(color: Color.black.opacity(0.80), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.40), location: 0.0),
                        .init(color: Color.black.opacity(0.0),  location: 0.55),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        } else {
            // No image: neutral grey backdrop so the hero still has
            // presence without claiming brand accent.
            Color.primary.opacity(0.10)
        }
    }

    // MARK: - Foreground

    private var foreground: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            Text("FLOW")
                .font(.system(size: DT.f10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.6))

            Text(flow.name)
                .font(.system(size: DT.f30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let task = flow.taskDescription, !task.isEmpty {
                Text(task)
                    .font(.system(size: DT.f14))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 580, alignment: .leading)
            }

            byline
                .padding(.top, DT.s4)

            ctas
                .padding(.top, DT.s8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Byline pills

    private var byline: some View {
        HStack(spacing: DT.s8) {
            if let date = flow.recordedAt {
                bylinePill(symbol: "clock", text: friendlyDate(date))
            }
            if let dur = flow.durationSeconds {
                bylinePill(symbol: "stopwatch", text: "\(dur)s")
            }
            bylinePill(
                symbol: "list.number",
                text: "\(flow.phases.count) phase\(flow.phases.count == 1 ? "" : "s")"
            )
            if runCount > 0 {
                bylinePill(symbol: "repeat", text: "ran \(runCount)×")
            }
        }
    }

    private func bylinePill(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: DT.f11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // 4 pills max on the hero — small enough budget to spend
        // real glass here. Tinted with the OS accent so they don't
        // read as fully see-through over the screenshot backdrop.
        .glassShowcasePillSurface(tint: .black.opacity(0.35))
    }

    // MARK: - CTAs

    private var ctas: some View {
        HStack(spacing: DT.s8) {
            primaryCTA
            secondaryCTA
        }
    }

    /// Run autonomously — Liquid-Glass prominent button tinted
    /// orange on macOS 26+. Orange matches the driving-state edge
    /// glow + floating panel pill via `DT.orange` (same hex as
    /// `OrbStateTokens.driving.mid`). Older macOS falls back to a
    /// solid orange capsule with shadow.
    private var primaryCTA: some View {
        Button(action: onRunAutonomously) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: DT.f13, weight: .semibold))
                Text("Run autonomously")
                    .font(.system(size: DT.f13, weight: .semibold))
            }
        }
        .glassProminentCapsule(tint: DT.orange)
        .keyboardShortcut(.return, modifiers: [.command])
        .help("Run this flow autonomously with the connected agent (⌘⏎)")
    }

    /// Guide me — Liquid-Glass subtle button tinted cyan on
    /// macOS 26+. Cyan matches the watching-state edge glow / floating
    /// panel chrome, signalling "you'll be the one acting". Older
    /// macOS falls back to an outline cyan capsule.
    private var secondaryCTA: some View {
        Button(action: onGuideMe) {
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: DT.f13, weight: .semibold))
                Text("Guide me")
                    .font(.system(size: DT.f13, weight: .semibold))
            }
        }
        .glassSubtleCapsule(tint: DT.cyan)
        .help("Walk through the flow step-by-step yourself")
    }

    // MARK: - Date helper

    private func friendlyDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let date = f.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
