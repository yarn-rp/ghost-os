// ScreenshotCapture.swift - Per-event screenshot capture for the learning recorder.
//
// Runs on the learning thread (nonisolated) and uses CGWindowListCreateImage,
// which is thread-safe and synchronous. Distinct from the MainActor-bound
// Screenshot/ScreenCapture used by the MCP server's `flow42_screenshot` tool.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated public enum LearningScreenshot {

    /// Capture the frontmost window of the given pid, encode JPEG, write to
    /// `<recordingDir>/screenshots/step-NNN.jpg`. Returns the path relative
    /// to the recording dir on success, nil on any failure (we never throw —
    /// a missed screenshot must not break recording).
    public static func capture(
        pid: pid_t,
        stepIndex: Int,
        recordingDir: String,
        annotated: Bool = false,
        clickPoint: CGPoint? = nil
    ) -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        // Find the topmost on-screen window owned by `pid`.
        guard let windowID = topmostWindowID(forPid: pid) else { return nil }

        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming]
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            imageOptions
        ) else { return nil }

        let finalImage: CGImage
        if annotated, let pt = clickPoint {
            finalImage = drawClickMarker(on: cgImage, at: pt) ?? cgImage
        } else {
            finalImage = cgImage
        }

        // Resize to keep files small (max width 1280px).
        let resized = resize(finalImage, maxWidth: 1280) ?? finalImage

        let suffix = annotated ? ".annotated.jpg" : ".jpg"
        let filename = String(format: "step-%03d%@", stepIndex, suffix)
        let relPath = "screenshots/\(filename)"
        let absPath = (recordingDir as NSString).appendingPathComponent(relPath)

        // Ensure the screenshots dir exists.
        let screenshotsDir = (absPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: screenshotsDir,
            withIntermediateDirectories: true
        )

        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: absPath) as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.7]
        CGImageDestinationAddImage(dest, resized, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return relPath
    }

    // MARK: - Helpers

    private static func topmostWindowID(forPid pid: pid_t) -> CGWindowID? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
            as? [[CFString: Any]] else { return nil }
        for info in list {
            guard let ownerPid = info[kCGWindowOwnerPID] as? pid_t, ownerPid == pid else { continue }
            // Skip menu bar / tiny windows.
            if let bounds = info[kCGWindowBounds] as? [String: Any],
               let h = bounds["Height"] as? Double, h < 50 { continue }
            if let layer = info[kCGWindowLayer] as? Int, layer != 0 { continue }
            if let id = info[kCGWindowNumber] as? CGWindowID { return id }
        }
        return nil
    }

    private static func resize(_ image: CGImage, maxWidth: Int) -> CGImage? {
        if image.width <= maxWidth { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let newW = maxWidth
        let newH = Int(Double(image.height) * scale)
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    private static func drawClickMarker(on image: CGImage, at point: CGPoint) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CG's coordinate space has origin at bottom-left; click point is
        // window-local from CGEvent (top-left). We don't have the window's
        // origin here so we draw at point.y from the top.
        let cx = point.x
        let cy = Double(h) - point.y
        ctx.setStrokeColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.95)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: cx - 22, y: cy - 22, width: 44, height: 44))
        ctx.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: cx - 22, y: cy - 22, width: 44, height: 44))
        return ctx.makeImage()
    }
}
