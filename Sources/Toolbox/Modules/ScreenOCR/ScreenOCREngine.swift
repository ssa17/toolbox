import AppKit
import CoreGraphics
import CoreImage
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
    /// Normalized line height. For multi-line observations this is the box height split
    /// across the sub-lines, so the same-row tolerance tracks the real text size; 0 =
    /// unknown (falls back to the fixed `sameRowYtolerance`).
    var normalizedHeight: CGFloat = 0
    var confidence: Float
    /// True when Vision's candidate string had a blank line immediately above this one
    /// (a paragraph break inside a single observation) — used to re-emit the break.
    var hadBlankBefore: Bool = false
}

/// Result of running the on-device engine over one captured image.
struct OCRResult: Equatable, Sendable {
    var text: String
    var qrPayloads: [String]
    /// How many Vision text observations the engine received (0 = Vision saw no text at all).
    var textObservationCount: Int = 0
    /// Fraction of sampled pixels that are near-black (luminance < 16). Uniform-black
    /// captures (~100%) are the Screen Recording permission-failure signature; dark UIs
    /// (terminals, dark mode) are dark but NOT uniform, so they no longer trip this.
    var blackFraction: Double? = nil
    /// Non-nil when the Vision handler itself threw (e.g. an image format it refuses).
    /// Distinguishes "engine error" from "genuinely no text".
    var engineError: String? = nil

    /// The classic permission-failure signature: the captured region is *uniform* black.
    /// Pure image property (independent of whether text was found) — deliberately NOT an
    /// average-luminance check, because dark-themed UI (the common case in developer
    /// environments) averages near-black yet contains real text, and a luminance average
    /// false-positives exactly there.
    var looksBlank: Bool {
        (blackFraction ?? 0) > 0.99
    }

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
    /// Same-row tolerance when observation heights are unknown: two lines whose normalized
    /// Y origins are closer than this fraction of the image height are one visual row.
    static let sameRowYtolerance: CGFloat = 0.02
    /// When heights are known, the same-row tolerance is this multiple of the median line
    /// height, clamped into `sameRowToleranceMin...sameRowToleranceMax`. A fixed fraction of
    /// the *image* height would merge adjacent document lines whenever the user selects a
    /// large region (16 pt text on a full-screen capture sits ~1.5% of the height apart,
    /// below the 2% fallback), so the tolerance must scale with the text itself.
    static let sameRowToleranceFraction: CGFloat = 0.5
    static let sameRowToleranceMin: CGFloat = 0.004
    static let sameRowToleranceMax: CGFloat = 0.02

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

    /// Pure extraction: takes the best candidate of a Vision text observation and returns
    /// one `RecognizedTextLine` per visual line.
    ///
    /// Vision groups a whole paragraph into a single observation whose box spans every
    /// line, so the box is split evenly across the sub-lines: each gets its own Y (top
    /// sub-line sits at the box top) and its own height. Without this split, all sub-lines
    /// would inherit the box's top origin, collapse into one merged row, and the full-box
    /// height would inflate the line-height median used for row clustering.
    static func lines(from observation: VNRecognizedTextObservation) -> [RecognizedTextLine] {
        guard let candidate = observation.topCandidates(1).first else { return [] }
        let box = observation.boundingBox
        let confidence = candidate.confidence

        // Track blank lines inside the candidate string so paragraph breaks survive.
        var parsed: [(text: String, hadBlankBefore: Bool)] = []
        var previousWasBlank = false
        for raw in candidate.string.components(separatedBy: "\n") {
            let line = raw.trimmed
            if line.isEmpty {
                previousWasBlank = true
                continue
            }
            parsed.append((line, previousWasBlank))
            previousWasBlank = false
        }
        guard !parsed.isEmpty else { return [] }

        let lineHeight = box.height / CGFloat(parsed.count)
        return parsed.enumerated().map { index, item in
            RecognizedTextLine(
                text: item.text,
                normalizedY: box.origin.y + lineHeight * CGFloat(parsed.count - 1 - index),
                normalizedX: box.origin.x,
                normalizedHeight: lineHeight,
                confidence: confidence,
                hadBlankBefore: item.hadBlankBefore
            )
        }
    }

    /// Same-row tolerance for a set of lines: half the median observation height when any
    /// heights are known (clamped), or the fixed `sameRowYtolerance` fraction of the image
    /// height otherwise. Lines closer than this in normalized Y are one visual row.
    static func sameRowTolerance(for lines: [RecognizedTextLine]) -> CGFloat {
        let heights = lines.map(\.normalizedHeight).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return sameRowYtolerance }
        let median = heights[heights.count / 2]
        return min(max(median * sameRowToleranceFraction, sameRowToleranceMin), sameRowToleranceMax)
    }

    /// Pure formatting: sorts lines top-to-bottom (Vision origin is bottom-left, so larger
    /// Y = higher), clusters them into visual rows using `sameRowTolerance(for:)` (so the
    /// tolerance tracks the text size, not the selection size), orders columns within each
    /// row left-to-right, joins columns with a single space, and joins rows with "\n" when
    /// `preserveLineBreaks` is true (or a single space when false).
    ///
    /// Paragraph awareness (line-breaks mode only): a blank line is inserted between two
    /// rows when the vertical gap between them exceeds one median line height, or when the
    /// source text carried an explicit blank line above the row — so multi-paragraph
    /// selections keep their structure instead of becoming one dense wall of lines.
    static func formattedText(from lines: [RecognizedTextLine], preserveLineBreaks: Bool) -> String {
        let tolerance = sameRowTolerance(for: lines)
        let byRow = lines.sorted {
            if $0.normalizedY != $1.normalizedY {
                return $0.normalizedY > $1.normalizedY
            }
            return $0.normalizedX < $1.normalizedX
        }

        var rows: [[RecognizedTextLine]] = []
        for line in byRow {
            // Compare against the row's highest line (its first element) so drift cannot
            // chain: a stack of lines each just under `tolerance` apart stays separate.
            if let last = rows.last, abs(last[0].normalizedY - line.normalizedY) < tolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        // Median line height for paragraph-gap detection; 0 when heights are unknown
        // (paragraphSeparator then falls back to the textual hadBlankBefore flag only).
        let heights = lines.map(\.normalizedHeight).filter { $0 > 0 }.sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]

        var output: [String] = []
        var previousRow: [RecognizedTextLine]?
        for row in rows {
            let text = row.sorted { $0.normalizedX < $1.normalizedX }
                .map(\.text)
                .joined(separator: " ")
                .trimmed
            guard !text.isEmpty else { continue }
            if preserveLineBreaks, let previous = previousRow,
               paragraphSeparator(previous: previous, current: row, medianHeight: medianHeight) {
                output.append("")
            }
            output.append(text)
            previousRow = row
        }

        return output
            .filter { !$0.isEmpty || preserveLineBreaks }
            .joined(separator: preserveLineBreaks ? "\n" : " ")
            .trimmed
    }

    /// Decides whether a blank line belongs between two adjacent visual rows: true when
    /// the vertical gap between the rows exceeds one median line height (a paragraph's
    /// extra spacing), or when the current row's lines carried an explicit blank line in
    /// the source text. (Vision origins are box *bottoms*, so the gap is the upper row's
    /// lowest bottom minus the lower row's highest top.)
    static func paragraphSeparator(
        previous: [RecognizedTextLine],
        current: [RecognizedTextLine],
        medianHeight: CGFloat
    ) -> Bool {
        guard medianHeight > 0 else {
            return current.contains(where: \.hadBlankBefore)
        }
        let previousBottom = previous.map(\.normalizedY).min() ?? 0
        let currentTop = current.map { $0.normalizedY + $0.normalizedHeight }.max() ?? 0
        let gap = previousBottom - currentTop
        return gap > medianHeight || current.contains(where: \.hadBlankBefore)
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
        // Vision's built-in default drops text lines shorter than 1/40 of the image
        // height — on a full-screen Retina capture that's ~50 pt of text, silently
        // skipping normal 13–16 pt terminal/UI text. 1/100 keeps useful small text
        // (≈11 pt on a 2x full-screen capture) while still filtering speck noise.
        textRequest.minimumTextHeight = 1.0 / 100.0
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
        var engineError: String?
        do {
            try handler.perform(requestList)
        } catch {
            // Never swallow: a thrown perform (unusual image format/colorspace) used to
            // masquerade as "no text found". Surface it so the real failure is visible.
            engineError = error.localizedDescription
        }

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

        let text = formattedText(from: allLines, preserveLineBreaks: preserveLineBreaks)
        let hasOutput = !text.trimmed.isEmpty || !payloads.isEmpty

        return OCRResult(
            text: text,
            qrPayloads: payloads,
            textObservationCount: (textRequest.results ?? []).count,
            blackFraction: imageBlackFraction(image),
            engineError: engineError
        )
    }

    /// Fraction of sampled pixels that are near-black (luminance < 16).
    ///
    /// Permission-failure captures are *uniform* black (~1.0). A dark-themed UI averages
    /// dark but its text and edges keep the near-black fraction well below the 0.99 gate,
    /// so dark screenshots no longer get misreported as "screen might be blank".
    static func imageBlackFraction(_ image: CGImage, sampleSize: Int = 64) -> Double {
        let maxDim = max(image.width, image.height)
        guard maxDim > 0 else { return 1 }
        let scale = CGFloat(sampleSize) / CGFloat(maxDim)
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return 0
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return 0 }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var nearBlack = 0
        let count = w * h
        for i in 0..<count {
            let offset = i * 4
            let luminance = 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
            if luminance < 16 { nearBlack += 1 }
        }
        return Double(nearBlack) / Double(count)
    }

    /// Backwards-compatible convenience (uniform-black gate).
    static func imageLooksBlank(_ image: CGImage, sampleSize: Int = 64) -> Bool {
        imageBlackFraction(image, sampleSize: sampleSize) > 0.99
    }

    /// Formats a black-fraction as a human percentage ("2.4%").
    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
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

    // MARK: - Developer Self-Check Sample

    /// Text lines rendered into the developer self-check sample. `SelfTestRunner` asserts
    /// the first line round-trips, so keep it a distinctive, easily-recognized phrase.
    static let selfCheckSampleLines = [
        "Toolbox OCR self-check",
        "On-device Vision recognition",
        "Nothing leaves your Mac"
    ]

    /// QR payload encoded into the developer self-check sample; distinct from the sample's
    /// text lines so the barcode path is asserted independently of the text path.
    static let selfCheckQRPayload = "https://toolbox.dev/self-check"

    /// Renders the synthetic sample used by the Developer Tools "OCR self-check": a white
    /// bitmap with three lines of high-contrast black text and a real QR code (CoreImage
    /// `CIQRCodeGenerator`, so the barcode path is exercised end-to-end, not stubbed).
    /// Runs fine off the main thread.
    static func makeSelfCheckSample() -> CGImage? {
        let width = 900
        let height = 420
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let lineHeight: CGFloat = 56
        for (idx, line) in selfCheckSampleLines.enumerated() {
            let y = CGFloat(height) - lineHeight * CGFloat(idx + 1) + 12
            (line as NSString).draw(at: NSPoint(x: 50, y: y), withAttributes: attributes)
        }

        let qrSize: CGFloat = 160
        let margin: CGFloat = 10
        let qrRect = NSRect(
            x: CGFloat(width) - qrSize - 48 - margin,
            y: 48 - margin,
            width: qrSize + margin * 2,
            height: qrSize + margin * 2
        )
        NSColor.white.setFill()
        qrRect.fill()
        if let qr = qrCodeImage(payload: selfCheckQRPayload, targetSize: qrSize) {
            let qrNSImage = NSImage(cgImage: qr, size: qrRect.insetBy(dx: margin, dy: margin).size)
            qrNSImage.draw(in: qrRect.insetBy(dx: margin, dy: margin))
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Builds a high-contrast QR code bitmap (black modules on white, scaled to fit
    /// `targetSize`) from a UTF-8 payload via CoreImage. Returns `nil` when the payload
    /// cannot be encoded.
    static func qrCodeImage(payload: String, targetSize: CGFloat, scale: CGFloat = 8) -> CGImage? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "InputMessage")
        filter?.setValue("M", forKey: "InputCorrectionLevel")
        guard var image = filter?.outputImage else { return nil }
        let matrix = image.extent.width > 0 ? targetSize / image.extent.width : 1
        image = image.transformed(by: CGAffineTransform(scaleX: max(1, min(scale, matrix)), y: max(1, min(scale, matrix))))
        // The generator's background is not guaranteed opaque; composite over white so the
        /// quiet-zone contrast is stable for Vision.
        let white = CIImage(color: CIColor.white).cropped(to: image.extent)
        image = image.composited(over: white)
        let context = CIContext()
        return context.createCGImage(image, from: image.extent)
    }
}
