// EdgeGlowView.swift - SwiftUI port of davos `JarvisEdgeWave`.
//
// Six-layer linear gradient bleeding inward from each of the four screen
// edges. Layer count, alpha decay, easing curve, and pulse cadence all match
// the original Dart implementation in
// `davos/lib/ui/orb/jarvis_edge_wave.dart`. The Canvas is driven by a
// `TimelineView(.animation)` so it redraws at the display's refresh rate and
// pauses cleanly when the mode is `.idle`.
//
// The view paints into the full window bounds. About 7% of `min(w, h)` bleeds
// inwards per layer; the inner ~93% of every screen stays untouched and
// click-through (the window itself sets `ignoresMouseEvents = true`).

import Flow42Core
import SwiftUI

private let edgeTransitionMs: Double = 1000

struct EdgeGlowView: View {
    let state: DerivedState

    var body: some View {
        // Idle is empty — no draw, no animation, no battery.
        if state == .idle {
            Color.clear
        } else {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                Canvas { context, size in
                    paintEdges(
                        context: context,
                        size: size,
                        state: state,
                        now: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
                .drawingGroup()
                .ignoresSafeArea()
            }
        }
    }

    private func paintEdges(
        context: GraphicsContext,
        size: CGSize,
        state: DerivedState,
        now: TimeInterval
    ) {
        guard let tokens = OrbStateTokens.tokens(for: state) else { return }

        let w = size.width
        let h = size.height
        let t = now  // seconds

        // Pulse cadence — driving gets the faster, deeper modulation;
        // watching pulses gentler (it's "the user is in control").
        let isFast = state == .driving
        let pulse = 1.0 + (isFast ? 0.15 : 0.06) * sin(t * (isFast ? 3.0 : 1.8))

        // Steady-state energy proxy — davos smooths toward
        // 0.2 + intensity * 0.6 over time. We approximate with the fixed
        // target since each EdgeGlowView instance is created when a mode
        // becomes active, so the smoothing is short-lived in practice.
        let energy = 0.2 + tokens.intensity * 0.6

        let isMobile = w < 768
        let glowPct = isMobile ? 0.10 : 0.07
        let glow = min(w, h) * glowPct * pulse * (0.85 + energy * 0.3)
        // Halve the overall opacity vs. davos default (0.5 + energy*0.25) so
        // the glow reads as ambient rather than an alarm. The shape of the
        // gradient is preserved.
        let baseOp = (0.5 + energy * 0.25) * 0.5

        // Six concentric layers of decaying alpha. Inner-edge alpha steps are
        // also pulled tighter (was 0.7 / 0.3 / 0.1) so the glow fades to
        // transparent earlier as it bleeds inward.
        for L in 0..<6 {
            let lp = Double(L) / 5.0
            let ls = glow * (0.5 + lp * 0.7)
            let lo = baseOp * (1 - lp * 0.5)
            let alphas = [lo, lo * 0.5, lo * 0.15, lo * 0.05, 0.0]

            let stops = stride(from: 0, through: 4, by: 1).map { i -> Gradient.Stop in
                let stopT = [0.0, 0.15, 0.4, 0.7, 1.0][i]
                return Gradient.Stop(
                    color: tokens.mid.opacity(alphas[i]),
                    location: stopT
                )
            }
            let gradient = Gradient(stops: stops)

            // top
            context.fill(
                Path(CGRect(x: 0, y: 0, width: w, height: ls)),
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: ls)
                )
            )
            // bottom
            context.fill(
                Path(CGRect(x: 0, y: h - ls, width: w, height: ls)),
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: h),
                    endPoint: CGPoint(x: 0, y: h - ls)
                )
            )
            // left
            context.fill(
                Path(CGRect(x: 0, y: 0, width: ls, height: h)),
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: ls, y: 0)
                )
            )
            // right
            context.fill(
                Path(CGRect(x: w - ls, y: 0, width: ls, height: h)),
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: w, y: 0),
                    endPoint: CGPoint(x: w - ls, y: 0)
                )
            )
        }
    }
}
