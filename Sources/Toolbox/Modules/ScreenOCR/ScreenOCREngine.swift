import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One recognized text line, as extracted from a Vision text observation.
struct RecognizedTextLine: Equatable, Sendable {
    var text: String
    /// Normalized Vision bounding-box origin Y (0 = bottom of image, 1 = top).
    var normalizedY: CGFloat
    /// Normalized Vision bounding-box origin X (0 = left, 1 = right).
    var normalizedX: CGFloat
    var confidence: Float
}

/// Result of running the on-device engine over one captured image.
struct OCRResult: Equatable, Sendable {
    var text: String
    var qrPayloads: [String]

    /// Count of non-empty lines in `text` (0 when `text` is empty).
    var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        return text.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }.count
    }

    var isEmpty: Bool {
        text.trimmed.isEmpty && qrPayloads.isEmpty
    }

    /// Final clipboard payload produced by `ScreenOCREngine.combinedOutput`.
    var clipboardString: String {
        ScreenOCREngine.combinedOutput(text: text, qrPayloads: qrPayloads)
    }

    /// Short human summary for the HUD toast:
    /// "Copied 1 line" / "Copied N lines" when text is present,
    /// "Copied 1 QR code" / "Copied N QR codes" when only QR payloads were found.
    var toastSummary: String {
        if !text.trimmed.isEmpty {
            let count = lineCount
            return count == 1 ? "Copied 1 line" : "Copied \(count) lines"
        }
        let count = qrPayloads.count
        return count == 1 ? "Copied 1 QR code" : "Copied \(count) QR codes"
    }
}

/// Outcome of loading the file written by `screencapture -i <path>`.
struct CapturedImageLoad: Equatable {
    enum Kind: Equatable {
        /// The file does not exist (the user pressed Esc while selecting).
        case cancelled
        /// The file exists but could not be decoded.
        case failed
        /// The PNG decoded cleanly into a `CGImage`.
        case loaded
    }

    var kind: Kind
    var image: CGImage?
    var failureMessage: String?
}

/// `CGImage` is immutable but not annotated `Sendable`; box it so it can cross into
/// `Task.detached` / `@Sendable` contexts cleanly under Swift 6 strict concurrency.
struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Stateless on-device OCR engine (Apple Vision + ImageIO).
/// All APIs used here are macOS 10.15+ except the `automaticallyDetectsLanguage`
/// property (macOS 14+), which is guarded explicitly for backwards compatibility.
/// Nothing ever leaves the device.
enum ScreenOCREngine {
    /// Below this height Vision accuracy degrades quickly, so the image is upscaled 2x.
    static let smallRegionHeightThreshold: Int = 32
    /// Two lines whose normalized Y origins are closer than this are treated as one visual row.
    static let sameRowYtolerance: CGFloat = 0.02

    /// Very small regions (e.g. a user selecting a tiny UI label) recognize much better
    /// upscaled: when the image is below the height threshold, re-render it at 2x into a
    /// fresh sRGB 8-bit bitmap context and return the enlarged `CGImage`.
    static func prepareImage(_ image: CGImage) -> CGImage {
        guard image.height < smallRegionHeightThreshold else { return image }

        let width = image.width * 2
        let height = image.height * 2
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        context.interpolationQuality = .high
        context.scaleBy(x: 2, y: 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// Pure extraction: takes the best candidate of a Vision text observation, splits its
    /// string on newlines, and returns one `RecognizedTextLine` per non-empty line.
    /// All lines inherit the observation's bounding-box origin and confidence.
    static func lines(from observation: VNRecognizedTextObservation) -> [RecognizedTextLine] {
        guard let candidate = observation.topCandidates(1).first else { return [] }
        let originY = observation.boundingBox.origin.y
        let originX = observation.boundingBox.origin.x
        let confidence = candidate.confidence

        return candidate.string
            .components(separatedBy: "\n")
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .map {
                RecognizedTextLine(
                    text: $0,
                    normalizedY: originY,
                    normalizedX: originX,
                    confidence: confidence
                )
            }
    }

    /// Pure formatting: orders lines into visual rows (grouped when their normalized Y
    /// origins are within `sameRowYtolerance`), sorts rows top-to-bottom and columns
    /// within a row left-to-right, joins columns with a single space, and joins rows with
    /// "\n" when `preserveLineBreaks` is true (or a single space when false).
    static func formattedText(from lines: [RecognizedTextLine], preserveLineBreaks: Bool) -> String {
        let sorted = lines.sorted {
            if abs($0.normalizedY - $1.normalizedY) < sameRowYtolerance {
                return $0.normalizedX < $1.normalizedX
            }
            return $0.normalizedY > $1.normalizedY  // Vision origin is bottom-left: larger Y = higher on screen
        }

        var rows: [[RecognizedTextLine]] = []
        for line in sorted {
            if let last = rows.last, abs(last[0].normalizedY - line.normalizedY) < sameRowYtolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        let joined = rows.map { row in
            row.map(\.text).joined(separator: " ")
        }

        return joined
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: preserveLineBreaks ? "\n" : " ")
    }

    /// Pure combination of recognized text and decoded QR/barcode payloads:
    /// payloads are deduplicated (order-preserving, dropping empty strings); when both
    /// text and payloads are present they are joined with "\n", otherwise whichever is
    /// present wins.
    static func combinedOutput(text: String, qrPayloads: [String]) -> String {
        let cleanText = text.trimmed
        var seen = Set<String>()
        let cleanPayloads = qrPayloads
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        if !cleanText.isEmpty && !cleanPayloads.isEmpty {
            return (cleanText + "\n" + cleanPayloads.joined(separator: "\n"))
        }
        if !cleanText.isEmpty {
            return cleanText
        }
        return cleanPayloads.joined(separator: "\n")
    }

    /// Runs `VNRecognizeTextRequest` (plus `VNDetectBarcodesRequest` when `detectBarcodes`
    /// is true) over `image` in a single `VNImageRequestHandler` pass.
    /// Safe to call off the main thread. Returns an `OCRResult` (possibly empty).
    static func recognize(
        in image: CGImage,
        recognitionLevel: OCRRecognitionLevel,
        preserveLineBreaks: Bool,
        detectBarcodes: Bool
    ) -> OCRResult {
        let textRequest = VNRecognizeTextRequest()
        // Set via implicit member syntax: the nested enum's spelling moved in the modern
        // Vision SDK interface, but the legacy 10.15+ property is unchanged.
        switch recognitionLevel {
        case .accurate: textRequest.recognitionLevel = .accurate
        case .fast: textRequest.recognitionLevel = .fast
        }
        textRequest.usesLanguageCorrection = true
        // `automaticallyDetectsLanguage` only exists on macOS 14+. The rest of the engine
        // works back to macOS 10.15, so guard this single property explicitly.
        if #available(macOS 14.0, *) {
            textRequest.automaticallyDetectsLanguage = true
        }
        var requestList: [VNRequest] = [textRequest]
        var barcodeRequest: VNDetectBarcodesRequest?
        if detectBarcodes {
            let request = VNDetectBarcodesRequest()
            barcodeRequest = request
            requestList.append(request)
        }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform(requestList)

        var allLines: [RecognizedTextLine] = []
        for observation in (textRequest.results ?? []) {
            allLines.append(contentsOf: lines(from: observation))
        }

        var payloads: [String] = []
        if let barcodeRequest {
            for barcode in (barcodeRequest.results ?? []) {
                if let payload = barcode.payloadStringValue, !payload.isEmpty {
                    payloads.append(payload)
                }
            }
        }

        return OCRResult(
            text: formattedText(from: allLines, preserveLineBreaks: preserveLineBreaks),
            qrPayloads: payloads
        )
    }

    /// Loads the PNG file written by `/usr/sbin/screencapture -i <path>` via ImageIO.
    /// - File does not exist (user pressed Esc) -> `kind == .cancelled`.
    /// - File exists but is unreadable or decodes to nothing -> `kind == .failed`.
    /// - Success -> `kind == .loaded` with the image.
    static func loadCapturedImage(at url: URL) -> CapturedImageLoad {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return CapturedImageLoad(kind: .cancelled, image: nil, failureMessage: nil)
        }

        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        guard let source,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return CapturedImageLoad(
                kind: .failed,
                image: nil,
                failureMessage: "Capture file could not be decoded as an image"
            )
        }
        return CapturedImageLoad(kind: .loaded, image: image, failureMessage: nil)
    }

    /// Convenience: loads `url` and runs recognition; returns `nil` when the capture was
    /// cancelled (no file) or failed to load.
    static func recognizeFile(
        at url: URL,
        recognitionLevel: OCRRecognitionLevel,
        preserveLineBreaks: Bool,
        detectBarcodes: Bool
    ) -> OCRResult? {
        let load = loadCapturedImage(at: url)
        guard let image = load.image else { return nil }
        return recognize(
            in: image,
            recognitionLevel: recognitionLevel,
            preserveLineBreaks: preserveLineBreaks,
            detectBarcodes: detectBarcodes
        )
    }
}
