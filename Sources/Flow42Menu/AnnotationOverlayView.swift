// AnnotationOverlayView.swift - Visual feedback for the Cmd+Shift+A region
// selector. The window is click-through (`ignoresMouseEvents = true`); all
// drag state comes from `AnnotationController`'s global NSEvent monitor.
//
// Visual style mirrors the Chrome extension's "highlight mode":
//   border  : 2px solid #3b82f6  (Tailwind blue-500)
//   fill    : rgba(59, 130, 246, 0.1)
//   label   : white text on #3b82f6, monospace
//
// Plus a cursor companion tag that follows the mouse so the user always
// sees they're in capture mode.

import AppKit
import SwiftUI

/// Tailwind blue-500 — the Chrome extension's highlight color.
private let highlightBlue = Color(red: 59/255, green: 130/255, blue: 246/255)
private let highlightFill = highlightBlue.opacity(0.1)

struct AnnotationOverlayView: View {
    @ObservedObject var controller: AnnotationController

    var body: some View {
        ZStack {
            // Fully transparent base.
            Color.clear

            if let rect = controller.dragRectLocal,
               rect.width > 1, rect.height > 1 {
                rectFillAndBorder(rect)
                sizeReadout(rect)
            } else {
                hintPill
            }

            if let p = controller.cursorLocal {
                cursorCompanion(at: p)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Selection rect

    private func rectFillAndBorder(_ rect: CGRect) -> some View {
        ZStack {
            // 10% fill — Chrome extension recipe verbatim.
            Rectangle()
                .fill(highlightFill)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            // 2px solid blue border.
            Rectangle()
                .strokeBorder(highlightBlue, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func sizeReadout(_ rect: CGRect) -> some View {
        let w = Int(rect.width.rounded())
        let h = Int(rect.height.rounded())
        let belowY = rect.maxY + 14
        let aboveY = rect.minY - 14
        let y = (belowY + 8 < controller.activeScreenSize.height) ? belowY : aboveY
        return Text("\(w) × \(h)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(highlightBlue)
            )
            .position(x: rect.midX, y: y)
    }

    // MARK: - Hint pill

    private var hintPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 13, weight: .semibold))
            Text("Drag a rectangle around what you want the agent to see")
                .font(.system(size: 13, weight: .medium))
            Text("·")
                .foregroundStyle(.white.opacity(0.55))
            Text("Esc to cancel")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(highlightBlue)
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .position(x: controller.activeScreenSize.width / 2, y: 64)
    }

    // MARK: - Cursor companion

    /// Small label that follows the mouse while annotation mode is armed.
    /// Communicates "you're in capture mode" without needing a custom system
    /// cursor (which requires private API). Hidden once the user starts a
    /// drag — the size readout takes over from there.
    private func cursorCompanion(at p: CGPoint) -> some View {
        // Only show before drag has started — once dragging, the rect's
        // size readout is enough.
        Group {
            if controller.dragRectLocal == nil {
                Text("annotating")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(highlightBlue)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    // Offset below-right of the cursor, like a tooltip.
                    .position(x: p.x + 18, y: p.y + 18)
                    .allowsHitTesting(false)
            }
        }
    }
}
