import AppKit
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
            // Prefix-identifiable API & cloud keys
            (.apiKey, #"\b(?:sk-proj-|sk-ant-|sk-live-|sk-test-|sk_live_|sk_test_|pk_live_|rk_live_|whsec_|sk-)[A-Za-z0-9_\-]{16,}\b"#, 0, false),
            (.apiKey, #"\bAIza[0-9A-Za-z_\-]{30,}\b|\bxox[baprs]-[0-9A-Za-z\-]{10,}\b|\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}\b"#, 0, false),
            (.apiKey, #"\b(?:hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{20,}|pypi-[A-Za-z0-9_\-]{20,}|glpat-[A-Za-z0-9_\-]{16,}|dop_v1_[a-f0-9]{32,}|sbp_[A-Za-z0-9]{20,}|lin_api_[A-Za-z0-9]{20,}|re_[A-Za-z0-9_]{16,}|xkeysib-[a-f0-9]{32,})\b"#, 0, false),
            (.githubToken, #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, 0, false),
            (.awsKey, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, 0, false),
            (.jwt, #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, 0, false),
            (.bearerToken, #"(?i)\bBearer\s+([A-Za-z0-9\-._~+/]{16,}=*)"#, 1, false),
            // Generic key/token/secret-prefixed identifiers joined with '_' or '-' (e.g. SubscriptionKey_K6DYNDNLJC.p8 -> redacts only the key ID)
            (.secretCode, #"(?i)\b(?:subscription|auth|api|access|secret|private|signing|master|client|webhook|encryption|recovery|backup)[_-]?(?:key|token|secret|id)[_-]([A-Za-z0-9]{6,40})\b"#, 1, false),
            // Custom key / certificate / keystore filenames (e.g. acme_prod_signing.p12, server.key, vault.kdbx -> redacts whole filename)
            (.secretCode, #"(?i)\b[A-Za-z0-9][A-Za-z0-9._\-]{1,80}\.(?:p8|p12|pfx|pem|key|ppk|jks|keystore|kdbx|mobileprovision)\b"#, 0, false),
            // Embedded URL credentials (e.g. postgres://user:pass@host)
            (.secretCode, #"\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s:@]+:([^\s/@]{4,64})@"#, 1, false),
            // Env-style uppercase/snake secret assignments (e.g. API_SECRET_KEY="...")
            (.secretCode, #"(?i)\b[A-Z0-9_]*(?:API_?KEY|SECRET|TOKEN|PASS(?:WORD|WD)?|PWD|PRIVATE_?KEY|KEY_?ID|ISSUER_?ID|SIGNING_?KEY|AUTH_?KEY|ACCESS_?KEY|CREDENTIAL|WEBHOOK|BEARER|OTP|PIN)[A-Z0-9_]*\s*[:=]\s*["']?([^\s,;()\[\]{}"']{4,80})["']?"#, 1, false),
            // Context-labeled codes/passwords/PINs/OTPs/tokens (tolerates OCR diacritic/dot artifacts like Kçob.-ueah-...)
            (.secretCode, #"(?i)\b(?:(?:your\s+)?(?:verification|security|recovery|backup|invite|access|auth|login|one[- ]?time|2fa|mfa|reset|activation|promo|secret|license|pass)\s+)?(?:code|passcode|password|passwd|pwd|pin|otp|secret|token|api[-_\s]?key|private[-_\s]?key|client[-_\s]?secret)\s*(?:is\s*:?|:|=)\s*([^\s,;()\[\]{}"']{4,64})"#, 1, false),
            // Standalone segmented recovery / product / license codes (e.g. kcob-ueah-rzlo-nwmu-fyfn or ABCD1-EFGH2-IJKL3)
            (.secretCode, #"\b[\p{L}\p{N}]{4}\.?(?:-[\p{L}\p{N}]{4}\.?){3,5}\b|\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){2,4}\b"#, 0, false),
            // Standalone high-entropy unlabelled token strings (gated strictly by Shannon entropy + mixed alphanumerics)
            (.secretCode, #"\b[A-Za-z0-9_\-]{24,64}\b"#, 0, false),
            (.creditCard, #"\b(?:\d[ -]*?){13,19}\b"#, 0, true),
            (.email, #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, 0, false),
            (.phone, #"(?:(?:\+\d{1,3}[\s.-]?)?\(\d{3}\)[\s.-]?\d{3}[\s.-]?\d{4}|(?:\+\d{1,3}[\s.-])\d{3}[\s.-]\d{3}[\s.-]\d{4}|\b\d{3}[-.\s]\d{3}[-.\s]\d{4}\b)"#, 0, false)
        ]
        return definitions.compactMap { category, pattern, group, luhn in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return PatternRule(category: category, regex: regex, captureGroup: group, requiresLuhn: luhn)
        }
    }()

    private static let nonSecretStatusWords: Set<String> = [
        "required", "invalid", "expired", "missing", "none", "null", "true", "false",
        "empty", "hidden", "redacted", "enabled", "disabled", "valid", "error",
        "failed", "success", "pending", "active", "inactive", "public", "private",
        "default", "example", "unknown", "blank", "open", "closed", "clean", "ready",
        "here", "below", "above", "sent", "text", "string", "value", "number", "status"
    ]

    private static func isLikelySecretCodeValue(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        guard trimmed.count >= 4 else { return false }
        let lower = trimmed.lowercased()
        let hasDigitsOrSeparators = trimmed.contains(where: { $0.isNumber || $0 == "-" || $0 == "_" })
        if !hasDigitsOrSeparators && nonSecretStatusWords.contains(lower) {
            return false
        }
        return trimmed.contains(where: { $0.isLetter || $0.isNumber })
    }

    private static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in s { counts[ch, default: 0] += 1 }
        let len = Double(s.count)
        return counts.values.reduce(0.0) { acc, count in
            let p = Double(count) / len
            return acc - p * log2(p)
        }
    }

    private static func isHighEntropyKeyToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        guard trimmed.count >= 6, trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let hasDigit = trimmed.contains(where: \.isNumber)
        let isAllCapsKeyID = trimmed.allSatisfy({ !$0.isLowercase }) && trimmed.contains(where: \.isLetter)
        if hasDigit && trimmed.contains(where: \.isLetter) {
            return shannonEntropy(trimmed) >= 2.2
        }
        if isAllCapsKeyID && trimmed.count >= 8 {
            return shannonEntropy(trimmed) >= 2.8
        }
        return false
    }

    private static func isStandaloneHighEntropySecret(_ token: String) -> Bool {
        guard token.count >= 24,
              token.contains(where: \.isNumber),
              token.contains(where: \.isLetter) else {
            return false
        }
        // Skip ISO dates/timestamps like 2026-11-27T21:52:56Z or YYYY-MM-DD-HHMMSS
        if token.hasPrefix("20") && token.contains("-") {
            let dashParts = token.split(separator: "-")
            if dashParts.count >= 3, dashParts.prefix(3).allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                return false
            }
        }
        // Skip hyphenated lowercase English slugs that happen to include a trailing digit/v2
        let dashSegments = token.split(separator: "-")
        if dashSegments.count >= 3 {
            let englishLikeSegments = dashSegments.filter { seg in
                seg.count >= 4 && seg.allSatisfy(\.isLowercase)
            }
            if englishLikeSegments.count >= 2 {
                return false
            }
        }
        let entropy = shannonEntropy(token)
        let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let isLongHex = token.count >= 32 && token.unicodeScalars.allSatisfy { hexSet.contains($0) }
        return isLongHex ? entropy >= 3.3 : entropy >= 3.5
    }

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
        case .secretCode:
            if trimmed.count > 10 {
                return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
            } else if trimmed.count > 5 {
                return "\(trimmed.prefix(2))••••"
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
                      let rawSwiftRange = Range(targetNSRange, in: text) else {
                    continue
                }

                var trimmedEnd = rawSwiftRange.upperBound
                if trimmedEnd == text.endIndex || text[trimmedEnd].isWhitespace {
                    while trimmedEnd > rawSwiftRange.lowerBound {
                        let prev = text.index(before: trimmedEnd)
                        if ".,;:!?".contains(text[prev]) {
                            trimmedEnd = prev
                        } else {
                            break
                        }
                    }
                }
                let swiftRange = rawSwiftRange.lowerBound..<trimmedEnd
                guard !swiftRange.isEmpty else { continue }
                let trimmedNSRange = NSRange(swiftRange, in: text)

                // Avoid overlapping lower-priority matches (e.g., JWT containing email-like tokens or phone digits inside card)
                if accepted.contains(where: { NSIntersectionRange($0.nsRange, trimmedNSRange).length > 0 }) {
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
                if rule.category == .secretCode {
                    if rule.regex.pattern.contains("_{6,40}") || rule.regex.pattern.contains("[_-]([A-Za-z0-9]{6,40})") {
                        guard isHighEntropyKeyToken(rawValue) else { continue }
                    } else if rule.regex.pattern == #"\b[A-Za-z0-9_\-]{24,64}\b"# {
                        guard isStandaloneHighEntropySecret(rawValue) else { continue }
                    } else if !isLikelySecretCodeValue(rawValue) {
                        continue
                    }
                }

                let match = SensitiveTextMatch(
                    category: rule.category,
                    range: swiftRange,
                    rawValue: rawValue,
                    maskedSnippet: maskSnippet(rawValue, category: rule.category)
                )
                accepted.append((trimmedNSRange, match))
            }
        }

        return accepted
            .sorted { $0.nsRange.location < $1.nsRange.location }
            .map(\.match)
    }

    private static func prepareImageForScan(_ image: CGImage) -> CGImage {
        if image.height < ScreenOCREngine.smallRegionHeightThreshold {
            return ScreenOCREngine.prepareImage(image)
        }
        guard image.height < 96,
              image.width > 0,
              image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: image.width * 2,
                height: image.height * 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: 2, y: 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    private static func enclosingNonWhitespaceRange(around range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var start = range.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev].isWhitespace { break }
            start = prev
        }
        var end = range.upperBound
        while end < text.endIndex {
            if text[end].isWhitespace { break }
            end = text.index(after: end)
        }
        return start..<end
    }

    private static func resolveNormalizedBoundingBox(
        for matchRange: Range<String.Index>,
        wordRange: Range<String.Index>,
        in text: String,
        top: VNRecognizedText
    ) -> CGRect? {
        guard let rawBox = (try? top.boundingBox(for: matchRange))?.boundingBox else {
            return nil
        }
        guard matchRange != wordRange,
              let wordBox = (try? top.boundingBox(for: wordRange))?.boundingBox,
              abs(rawBox.minX - wordBox.minX) < 0.015,
              abs(rawBox.maxX - wordBox.maxX) < 0.015 else {
            return rawBox
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .medium)]
        let fullWord = String(text[wordRange]) as NSString
        let prefix = String(text[wordRange.lowerBound..<matchRange.lowerBound]) as NSString
        let prefixPlusMatch = String(text[wordRange.lowerBound..<matchRange.upperBound]) as NSString

        let totalWidth = fullWord.size(withAttributes: attrs).width
        guard totalWidth > 0 else { return rawBox }

        let startFrac = min(max(prefix.size(withAttributes: attrs).width / totalWidth, 0), 1)
        let endFrac = min(max(prefixPlusMatch.size(withAttributes: attrs).width / totalWidth, startFrac), 1)
        return CGRect(
            x: wordBox.minX + wordBox.width * startFrac,
            y: wordBox.minY,
            width: max(0.005, wordBox.width * (endFrac - startFrac)),
            height: wordBox.height
        )
    }

    /// Scans `image` off the main thread using Apple Vision and returns native-pixel bounding rects.
    static func scanImage(_ image: CGImage) -> [AutoRedactCandidate] {
        let prepared = prepareImageForScan(image)
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
                let wordRange = enclosingNonWhitespaceRange(around: match.range, in: text)
                guard let normalizedBox = resolveNormalizedBoundingBox(
                    for: match.range,
                    wordRange: wordRange,
                    in: text,
                    top: top
                ) else {
                    continue
                }

                let rawPixelRect = CGRect(
                    x: normalizedBox.minX * CGFloat(prepared.width) * scaleBack,
                    y: (1.0 - normalizedBox.maxY) * CGFloat(prepared.height) * scaleBack,
                    width: normalizedBox.width * CGFloat(prepared.width) * scaleBack,
                    height: normalizedBox.height * CGFloat(prepared.height) * scaleBack
                )
                let horizontalPad: CGFloat = (match.range == wordRange) ? -5 : -2
                let padded = rawPixelRect.insetBy(dx: horizontalPad, dy: -4).integral.intersection(imageBounds)
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
