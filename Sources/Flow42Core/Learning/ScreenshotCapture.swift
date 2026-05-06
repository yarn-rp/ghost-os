// ScreenshotCapture.swift - Per-event screenshot capture for the learning recorder.
//
// Runs on the learning thread (nonisolated) and uses CGWindowListCreateImage,
// which is thread-safe and synchronous. Distinct from the MainActor-bound
// Screenshot/ScreenCapture used by the MCP server's `flow42_screenshot` tool.
//
// IMPORTANT: we capture the FULL MAIN DISPLAY (not a single window crop) so
// the screenshot's pixel space matches the global CG coordinate space the
// click events are recorded in. Window-only crops introduce a window-origin
// offset that the marker drawer never had, so the red circle would land in
// the wrong spot whenever the captured window was not at (0, 0). Full-screen
// capture also matches what the agent perceives at replay time.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated public enum LearningScreenshot {

    /// Capture the full main display, encode JPEG, write to
    /// `<recordingDir>/screenshots/step-NNN.jpg`. Returns the path relative
    /// to the recording dir on success, nil on any failure (we never throw —
    /// a missed screenshot must not break recording).
    ///
    /// `clickPoint` is the global CG event location (top-left origin, Y-down).
    /// The marker is drawn in image pixel space at (point.x - display.minX,
    /// image.height - (point.y - display.minY)), which matches a 1x nominal
    /// resolution capture of the same display.
    public static func capture(
        stepIndex: Int,
        recordingDir: String,
        annotated: Bool = false,
        clickPoint: CGPoint? = nil
    ) -> String? {
        let label = annotated ? "annotated" : "raw"
        debugLog("capture[\(label)] step=\(stepIndex) ENTER")
        // Screen Recording permission is the #1 reason a recording ends
        // up with empty step folders. Surface it loudly to stderr +
        // the recorder.log on the FIRST step where capture fails so the
        // user / agent doesn't have to wonder why screenshots are
        // missing afterwards. Subsequent calls during the same session
        // suppress the warning to avoid log spam.
        guard CGPreflightScreenCaptureAccess() else {
            debugLog("capture[\(label)] step=\(stepIndex) ABORT: no screen-recording permission")
            warnNoScreenRecordingPermissionOnce(recordingDir: recordingDir)
            return nil
        }

        let displayId = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayId)
        debugLog("capture[\(label)] step=\(stepIndex) display=\(displayId) bounds=\(displayBounds)")

        // .nominalResolution returns the image at 1x (logical points), so
        // the image's pixel dims line up with CGEvent coordinates without
        // any retina scale fixup.
        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        debugLog("capture[\(label)] step=\(stepIndex) calling CGWindowListCreateImage")
        guard let cgImage = CGWindowListCreateImage(
            displayBounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            imageOptions
        ) else {
            debugLog("capture[\(label)] step=\(stepIndex) CGWindowListCreateImage returned nil")
            return nil
        }
        debugLog("capture[\(label)] step=\(stepIndex) CGWindowListCreateImage OK \(cgImage.width)x\(cgImage.height)")

        let finalImage: CGImage
        if annotated, let pt = clickPoint {
            // Translate a global click point to the captured display's
            // pixel space before drawing.
            let local = CGPoint(
                x: pt.x - displayBounds.origin.x,
                y: pt.y - displayBounds.origin.y
            )
            finalImage = drawClickMarker(on: cgImage, at: local) ?? cgImage
        } else {
            finalImage = cgImage
        }

        // Resize to keep files small (max width 1920px — bumped from 1280
        // because full-display captures have more headroom and we want to
        // preserve enough detail for the agent to read text in the frame).
        let resized = resize(finalImage, maxWidth: 1920) ?? finalImage

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
        guard CGImageDestinationFinalize(dest) else {
            debugLog("capture[\(label)] step=\(stepIndex) finalize failed")
            return nil
        }
        debugLog("capture[\(label)] step=\(stepIndex) EXIT path=\(relPath)")
        return relPath
    }

    /// Same capture used at replay time. Identical pipeline to the recorder
    /// so a recording-time screenshot and a replay-time screenshot of the
    /// same workflow read as visually similar frames. `clickPoint` is the
    /// global coordinate the executor is about to act on.
    public static func captureForReplay(
        stepDir: String,
        annotated: Bool = false,
        clickPoint: CGPoint? = nil
    ) -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        let displayId = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayId)
        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let cgImage = CGWindowListCreateImage(
            displayBounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            imageOptions
        ) else { return nil }

        let finalImage: CGImage
        if annotated, let pt = clickPoint {
            let local = CGPoint(
                x: pt.x - displayBounds.origin.x,
                y: pt.y - displayBounds.origin.y
            )
            finalImage = drawClickMarker(on: cgImage, at: local) ?? cgImage
        } else {
            finalImage = cgImage
        }
        let resized = resize(finalImage, maxWidth: 1920) ?? finalImage

        let filename = annotated ? "annotated.jpg" : "screenshot.jpg"
        let absPath = (stepDir as NSString).appendingPathComponent(filename)
        try? FileManager.default.createDirectory(
            atPath: stepDir,
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
        return absPath
    }

    // MARK: - Helpers

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

    /// Draw a red+white click marker onto `image` at `point`. `point` must
    /// be in display-local pixel space (caller subtracts the display
    /// origin). CG's coord space is bottom-left so we flip Y inside.
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
        let cx = point.x
        let cy = Double(h) - point.y  // CG origin is bottom-left
        // Outer red ring.
        ctx.setStrokeColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.95)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: cx - 22, y: cy - 22, width: 44, height: 44))
        // Inner white ring.
        ctx.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: cx - 22, y: cy - 22, width: 44, height: 44))
        // Center dot for unambiguous "this exact pixel" marker.
        ctx.setFillColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.95)
        ctx.fillEllipse(in: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6))
        return ctx.makeImage()
    }
}

// MARK: - Diagnostic logging
//
// Same shape as `learningLog` (timestamped stderr line) but local to
// ScreenshotCapture so we don't drag the LearningTypes module into
// every callsite. Always-on while we troubleshoot; cheap.

nonisolated private func debugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] [DEBUG] ScreenshotCapture: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

// MARK: - Permission warning (one per recording dir)

/// Track which recording dirs we've already warned for. The recorder
/// captures dozens to hundreds of screenshots per session — without this
/// dedupe, a missing permission would write the same warning every time.
nonisolated(unsafe) private let warnedDirsLock = NSLock()
nonisolated(unsafe) private var warnedDirs = Set<String>()

nonisolated private func warnNoScreenRecordingPermissionOnce(recordingDir: String) {
    warnedDirsLock.lock()
    let alreadyWarned = warnedDirs.contains(recordingDir)
    if !alreadyWarned { warnedDirs.insert(recordingDir) }
    warnedDirsLock.unlock()
    guard !alreadyWarned else { return }

    let msg = """
    [WARN] Screen Recording permission is NOT granted to this binary. \
    Step folders will be written without screenshots. \
    Fix: System Settings > Privacy & Security > Screen Recording > \
    enable for this binary, then quit + restart it.
    """
    FileHandle.standardError.write(Data((msg + "\n").utf8))

    // Also append to the recording's own log so the user sees it when
    // they later inspect what went wrong.
    let logPath = (recordingDir as NSString).appendingPathComponent("recorder.log")
    if let data = (msg + "\n").data(using: .utf8),
       let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
