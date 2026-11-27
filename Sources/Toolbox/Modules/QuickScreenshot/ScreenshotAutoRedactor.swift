import CoreGraphics
import Foundation
import Vision

struct SensitiveTextMatch: Equatable, Sendable {
    let category: AutoRedactCategory
    let range: Range<String.Index>
    let rawValue: String
    let maskedSnippet: String
}

struct AutoRedactCandidate: Equatable, Sendable {
    let category: AutoRedactCategory
    let rect: CGRect
    let maskedSnippet: String
    let confidence: Float
}

/// On-device secret/PII detector backed by Apple Vision (`VNRecognizeTextRequest`).
/// All recognition runs locally off the main thread.
enum ScreenshotAutoRedactor {
    private struct PatternRule {
        let category: AutoRedactCategory
        let regex: NSRegularExpression
        let captureGroup: Int
        let requiresLuhn: Bool
    }

    private static let rules: [PatternRule] = {
        let definitions: [(AutoRedactCategory, String, Int, Bool)] = [
            (.apiKey, #"\b(?:sk-proj-|sk-ant-|sk-live-|sk-test-|sk-)[A-Za-z0-9_\-]{16,}\b"#, 0, false),
            (.githubToken, #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, 0, false),
            (.awsKey, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, 0, false),
            (.jwt, #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, 0, false),
            (.bearerToken, #"(?i)\bBearer\s+([A-Za-z0-9\-._~+/]{16,}=*)"#, 1, false),
            (.creditCard, #"\b(?:\d[ -]*?){13,19}\b"#, 0, true),
            (.email, #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, 0, false),
            (.phone, #"(?:(?:\+\d{1,3}[\s.-]?)?\(\d{3}\)[\s.-]?\d{3}[\s.-]?\d{4}|(?:\+\d{1,3}[\s.-])\d{3}[\s.-]\d{3}[\s.-]\d{4}|\b\d{3}[-.\s]\d{3}[-.\s]\d{4}\b)"#, 0, false)
        ]
        return definitions.compactMap { category, pattern, group, luhn in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return PatternRule(category: category, regex: regex, captureGroup: group, requiresLuhn: luhn)
        }
    }()

    /// Validates a candidate payment card digit sequence via the Luhn mod-10 checksum.
    static func passesLuhnCheck(_ raw: String) -> Bool {
        let digits = raw.compactMap(\.wholeNumberValue)
        guard digits.count >= 13 && digits.count <= 19 else { return false }
        // Reject trivial all-same-digit sequences such as 0000-0000-0000-0000
        guard Set(digits).count > 1 else { return false }

        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    static func maskSnippet(_ raw: String, category: AutoRedactCategory) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch category {
        case .email:
            let parts = trimmed.split(separator: "@", maxSplits: 1)
            if parts.count == 2 {
                let user = String(parts[0])
                let lead = user.prefix(2)
                return "\(lead)•••@\(parts[1])"
            }
        case .creditCard:
            let digits = trimmed.filter(\.isNumber)
            let last4 = digits.suffix(4)
            return "•••• •••• •••• \(last4)"
        case .phone:
            let digits = trimmed.filter(\.isNumber)
            return "•••-•••-\(digits.suffix(4))"
        case .apiKey, .githubToken, .awsKey, .bearerToken, .jwt:
            if trimmed.count > 10 {
                return "\(trimmed.prefix(6))••••\(trimmed.suffix(4))"
            }
        }
        if trimmed.count > 6 {
            return "\(trimmed.prefix(2))••••\(trimmed.suffix(2))"
        }
        return "••••"
    }

    /// Pure text-level sensitive token detector (safe for fast synchronous tests).
    static func detectSensitiveMatches(in text: String) -> [SensitiveTextMatch] {
        guard !text.isEmpty else { return [] }
        let fullNSRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var accepted: [(nsRange: NSRange, match: SensitiveTextMatch)] = []

        for rule in rules {
            let hits = rule.regex.matches(in: text, options: [], range: fullNSRange)
            for hit in hits {
                let targetNSRange = hit.range(at: rule.captureGroup)
                guard targetNSRange.location != NSNotFound,
                      targetNSRange.length > 0,
                      let swiftRange = Range(targetNSRange, in: text) else {
                    continue
                }

                // Avoid overlapping lower-priority matches (e.g., JWT containing email-like tokens or phone digits inside card)
                if accepted.contains(where: { NSIntersectionRange($0.nsRange, targetNSRange).length > 0 }) {
                    continue
                }

                let rawValue = String(text[swiftRange])
                if rule.requiresLuhn && !passesLuhnCheck(rawValue) {
                    continue
                }
                if rule.category == .phone {
                    let digitCount = rawValue.filter(\.isNumber).count
                    guard digitCount >= 10 && digitCount <= 15 else { continue }
                }

                let match = SensitiveTextMatch(
                    category: rule.category,
                    range: swiftRange,
                    rawValue: rawValue,
                    maskedSnippet: maskSnippet(rawValue, category: rule.category)
                )
                accepted.append((targetNSRange, match))
            }
        }

        return accepted
            .sorted { $0.nsRange.location < $1.nsRange.location }
            .map(\.match)
    }

    /// Scans `image` off the main thread using Apple Vision and returns native-pixel bounding rects.
    static func scanImage(_ image: CGImage) -> [AutoRedactCandidate] {
        let prepared = ScreenOCREngine.prepareImage(image)
        let scaleBack: CGFloat = (prepared !== image && prepared.width > 0)
            ? CGFloat(image.width) / CGFloat(prepared.width)
            : 1.0

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 1.0 / 100.0
        if #available(macOS 14.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: prepared, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let imageBounds = CGRect(x: 0, y: 0, width: imgW, height: imgH)
        var candidates: [AutoRedactCandidate] = []

        for observation in request.results ?? [] {
            guard let top = observation.topCandidates(1).first else { continue }
            let text = top.string
            let matches = detectSensitiveMatches(in: text)
            guard !matches.isEmpty else { continue }

            for match in matches {
                guard let tokenObs = try? top.boundingBox(for: match.range) else {
                    continue
                }
                let normalizedBox = tokenObs.boundingBox

                let rawPixelRect = CGRect(
                    x: normalizedBox.minX * CGFloat(prepared.width) * scaleBack,
                    y: (1.0 - normalizedBox.maxY) * CGFloat(prepared.height) * scaleBack,
                    width: normalizedBox.width * CGFloat(prepared.width) * scaleBack,
                    height: normalizedBox.height * CGFloat(prepared.height) * scaleBack
                )
                let padded = rawPixelRect.insetBy(dx: -5, dy: -4).integral.intersection(imageBounds)
                guard !padded.isNull, padded.width >= 4, padded.height >= 4 else { continue }

                if candidates.contains(where: { existing in
                    let overlap = existing.rect.intersection(padded)
                    guard !overlap.isNull else { return false }
                    let minArea = min(existing.rect.width * existing.rect.height, padded.width * padded.height)
                    return minArea > 0 && (overlap.width * overlap.height) / minArea > 0.75
                }) {
                    continue
                }

                candidates.append(
                    AutoRedactCandidate(
                        category: match.category,
                        rect: padded,
                        maskedSnippet: match.maskedSnippet,
                        confidence: top.confidence
                    )
                )
            }
        }

        return candidates
    }
}
