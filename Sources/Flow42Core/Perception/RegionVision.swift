// RegionVision.swift - On-device vision analysis of a captured region.
//
// Right now this is just OCR via Apple's `Vision` framework — accurate,
// fast, no model download, works offline. The output complements the AX
// subtree:
//
//   AX gives us:        roles, names, identifiers, frames (structure)
//   Vision gives us:    literal text in pixels regardless of AX cooperation
//                       (canvas-rendered text, screenshots, syntax-highlighted
//                       code, embedded images with text, etc.)
//
// Future: VNClassifyImage for coarse scene tags, VNDetectRectangles for
// table layouts. Slot them in as additional fields here without changing
// the call sites in AnnotationController.

import CoreGraphics
import Foundation
import Vision

public enum RegionVision {

    public struct OCRBlock: Sendable {
        public let text: String
        /// Top-left-origin pixel rect within the source image.
        public let frame: CGRect
        public let confidence: Float
    }

    public struct Result: Sendable {
        public let blocks: [OCRBlock]
        public let fullText: String
        public let language: String?
        public let imagePixelSize: CGSize
    }

    /// Run OCR on the supplied CGImage. Synchronous on the calling queue;
    /// callers can wrap in `Task.detached` if they want it off the main
    /// actor. Best-effort — returns nil on framework error.
    public nonisolated static func analyze(cgImage: CGImage) -> Result? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // English by default; Vision auto-detects pretty well. Add more
        // languages if we end up shipping in non-English locales.
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            FileHandle.standardError.write(Data(
                "[RegionVision] OCR failed: \(error.localizedDescription)\n".utf8
            ))
            return nil
        }

        let observations = request.results ?? []
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)

        var blocks: [OCRBlock] = []
        var lines: [String] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            if text.isEmpty { continue }

            // VNRecognizedTextObservation.boundingBox is normalized
            // [0, 1] with origin BOTTOM-LEFT. Convert to top-left-origin
            // pixels in the source image's space — the same space callers
            // use for the captured PNG.
            let normalized = obs.boundingBox  // CGRect in [0,1]
            let pxX = normalized.origin.x * pixelSize.width
            let pxYBottom = normalized.origin.y * pixelSize.height
            let pxW = normalized.size.width * pixelSize.width
            let pxH = normalized.size.height * pixelSize.height
            let pxYTop = pixelSize.height - pxYBottom - pxH
            let frame = CGRect(x: pxX, y: pxYTop, width: pxW, height: pxH)

            blocks.append(OCRBlock(
                text: text,
                frame: frame,
                confidence: candidate.confidence
            ))
            lines.append(text)
        }

        // Sort blocks reading-order-ish: top-to-bottom, then left-to-right
        // within an approximate line band.
        blocks.sort { lhs, rhs in
            let lineEpsilon: CGFloat = 8
            if abs(lhs.frame.minY - rhs.frame.minY) > lineEpsilon {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        let sortedFullText = blocks.map { $0.text }.joined(separator: "\n")

        return Result(
            blocks: blocks,
            fullText: sortedFullText,
            language: "en-US",
            imagePixelSize: pixelSize
        )
    }

    /// Convert a `Result` into a JSON-serializable dict shape that matches
    /// the rest of the annotation payload conventions.
    public nonisolated static func toJSON(_ result: Result) -> [String: Any] {
        let blocks: [[String: Any]] = result.blocks.map { b in
            [
                "text": b.text,
                "x": Double(b.frame.origin.x),
                "y": Double(b.frame.origin.y),
                "w": Double(b.frame.width),
                "h": Double(b.frame.height),
                "confidence": Double(b.confidence),
            ]
        }
        var ocr: [String: Any] = [
            "image_pixel_size": [
                "width": Double(result.imagePixelSize.width),
                "height": Double(result.imagePixelSize.height),
            ],
            "block_count": result.blocks.count,
            "blocks": blocks,
            "full_text": result.fullText,
        ]
        if let lang = result.language { ocr["language"] = lang }
        return ["ocr": ocr]
    }
}
