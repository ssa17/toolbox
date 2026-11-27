import AppKit
import CoreGraphics
import Foundation
import SwiftUI

enum ScreenshotTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case select
    case arrow
    case rectangle
    case ellipse
    case highlighter
    case text
    case step
    case redact
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rect"
        case .ellipse: return "Ellipse"
        case .highlighter: return "Highlight"
        case .text: return "Text"
        case .step: return "Number"
        case .redact: return "Redact"
        case .crop: return "Crop"
        }
    }

    var shortcutKey: String {
        switch self {
        case .select: return "S"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "E"
        case .highlighter: return "H"
        case .text: return "T"
        case .step: return "N"
        case .redact: return "X"
        case .crop: return "C"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle.fill"
        case .redact: return "eye.slash.fill"
        case .crop: return "crop"
        }
    }

    static func tool(forKeyCharacter char: String) -> ScreenshotTool? {
        switch char.lowercased() {
        case "s": return .select
        case "a": return .arrow
        case "r": return .rectangle
        case "e": return .ellipse
        case "h": return .highlighter
        case "t": return .text
        case "n": return .step
        case "x": return .redact
        case "c": return .crop
        default: return nil
        }
    }
}

enum AnnotationColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case white
    case black

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }

    var swiftUIColor: Color {
        switch self {
        case .red: return Color(red: 0.96, green: 0.27, blue: 0.25)
        case .orange: return Color(red: 1.0, green: 0.58, blue: 0.14)
        case .yellow: return Color(red: 0.98, green: 0.84, blue: 0.18)
        case .green: return Color(red: 0.22, green: 0.82, blue: 0.42)
        case .blue: return Color(red: 0.22, green: 0.56, blue: 0.98)
        case .purple: return Color(red: 0.72, green: 0.42, blue: 0.98)
        case .white: return .white
        case .black: return Color(red: 0.08, green: 0.08, blue: 0.09)
        }
    }

    var cgColor: CGColor {
        switch self {
        case .red: return CGColor(srgbRed: 0.96, green: 0.27, blue: 0.25, alpha: 1.0)
        case .orange: return CGColor(srgbRed: 1.0, green: 0.58, blue: 0.14, alpha: 1.0)
        case .yellow: return CGColor(srgbRed: 0.98, green: 0.84, blue: 0.18, alpha: 1.0)
        case .green: return CGColor(srgbRed: 0.22, green: 0.82, blue: 0.42, alpha: 1.0)
        case .blue: return CGColor(srgbRed: 0.22, green: 0.56, blue: 0.98, alpha: 1.0)
        case .purple: return CGColor(srgbRed: 0.72, green: 0.42, blue: 0.98, alpha: 1.0)
        case .white: return CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        case .black: return CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        }
    }

    var nsColor: NSColor {
        NSColor(cgColor: cgColor) ?? .systemRed
    }
}

extension RedactSolidColor {
    var swiftUIColor: Color {
        switch self {
        case .black: return .black
        case .white: return .white
        case .slate: return Color(red: 0.14, green: 0.16, blue: 0.20)
        }
    }
}

extension BeautifyBackdrop {
    var swiftUIGradient: LinearGradient {
        let stops = gradientRGBStops
        return LinearGradient(
            colors: [
                Color(red: stops.start.0, green: stops.start.1, blue: stops.start.2),
                Color(red: stops.end.0, green: stops.end.1, blue: stops.end.2)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AutoRedactCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiKey = "api_key"
    case githubToken = "github_token"
    case awsKey = "aws_key"
    case bearerToken = "bearer_token"
    case jwt = "jwt"
    case secretCode = "secret_code"
    case creditCard = "credit_card"
    case email = "email"
    case phone = "phone"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiKey: return "API Key"
        case .githubToken: return "GitHub Token"
        case .awsKey: return "AWS Key"
        case .bearerToken: return "Bearer Token"
        case .jwt: return "JWT"
        case .secretCode: return "Secret / Code"
        case .creditCard: return "Card Number"
        case .email: return "Email"
        case .phone: return "Phone"
        }
    }

    var symbolName: String {
        switch self {
        case .apiKey, .githubToken, .awsKey, .bearerToken, .jwt:
            return "key.fill"
        case .secretCode:
            return "lock.shield.fill"
        case .creditCard:
            return "creditcard.fill"
        case .email:
            return "envelope.fill"
        case .phone:
            return "phone.fill"
        }
    }
}

struct AutoRedactReviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let annotationID: UUID
    let category: AutoRedactCategory
    let maskedSnippet: String
    let confidence: Float
    var rect: CGRect

    init(
        id: UUID = UUID(),
        annotationID: UUID,
        category: AutoRedactCategory,
        maskedSnippet: String,
        confidence: Float,
        rect: CGRect
    ) {
        self.id = id
        self.annotationID = annotationID
        self.category = category
        self.maskedSnippet = maskedSnippet
        self.confidence = confidence
        self.rect = rect
    }
}

enum AnnotationKind: String, Codable, Equatable, Sendable {
    case arrow
    case rectangle
    case ellipse
    case highlighter
    case text
    case step
    case redact
}

/// Unified text callout metrics shared across hit-testing, canvas preview, and CoreGraphics export.
struct TextCalloutLayout: Equatable {
    let content: String
    let font: NSFont
    let textSize: CGSize
    let padX: CGFloat
    let padY: CGFloat
    let pillRect: CGRect
}

/// Vector/redaction annotation stored in **native `CGImage` pixel coordinates** (top-left origin).
struct AnnotationItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: AnnotationKind
    var startPoint: CGPoint
    var endPoint: CGPoint
    var rect: CGRect
    var points: [CGPoint]
    var color: AnnotationColor
    var strokeWidth: CGFloat
    var text: String
    var stepNumber: Int
    var redactStyle: RedactStyle
    var arrowStyle: ArrowStyle
    var dashStyle: StrokeDashStyle
    var fillStyle: ShapeFillStyle
    var cornerRadius: CornerRadiusPreset
    var highlighterMode: HighlighterMode
    var highlighterOpacity: HighlighterOpacity
    var textFontSize: CGFloat?
    var textBackgroundStyle: TextBackgroundStyle
    var textWeightStyle: TextWeightStyle
    var textCornerRadius: CornerRadiusPreset
    var textPaddingXRatio: CGFloat?
    var textPaddingYRatio: CGFloat?
    var stepSize: CGFloat?
    var stepStyle: StepBadgeStyle
    var redactStrength: RedactStrength
    var redactSolidColor: RedactSolidColor
    var autoRedactCategory: AutoRedactCategory?
    var maskedSnippet: String?
    var confidence: Float?

    init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        startPoint: CGPoint = .zero,
        endPoint: CGPoint = .zero,
        rect: CGRect = .zero,
        points: [CGPoint] = [],
        color: AnnotationColor = .red,
        strokeWidth: CGFloat = 4,
        text: String = "",
        stepNumber: Int = 1,
        redactStyle: RedactStyle = .pixelate,
        arrowStyle: ArrowStyle = .standard,
        dashStyle: StrokeDashStyle = .solid,
        fillStyle: ShapeFillStyle = .outline,
        cornerRadius: CornerRadiusPreset = .rounded,
        highlighterMode: HighlighterMode = .freehand,
        highlighterOpacity: HighlighterOpacity = .normal,
        textFontSize: CGFloat? = nil,
        textBackgroundStyle: TextBackgroundStyle = .filled,
        textWeightStyle: TextWeightStyle = .semibold,
        textCornerRadius: CornerRadiusPreset = .rounded,
        textPaddingXRatio: CGFloat? = nil,
        textPaddingYRatio: CGFloat? = nil,
        stepSize: CGFloat? = nil,
        stepStyle: StepBadgeStyle = .filled,
        redactStrength: RedactStrength = .medium,
        redactSolidColor: RedactSolidColor = .black,
        autoRedactCategory: AutoRedactCategory? = nil,
        maskedSnippet: String? = nil,
        confidence: Float? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.rect = rect.standardized
        self.points = points
        self.color = color
        self.strokeWidth = max(1, strokeWidth)
        self.text = text
        self.stepNumber = stepNumber
        self.redactStyle = redactStyle
        self.arrowStyle = arrowStyle
        self.dashStyle = dashStyle
        self.fillStyle = fillStyle
        self.cornerRadius = cornerRadius
        self.highlighterMode = highlighterMode
        self.highlighterOpacity = highlighterOpacity
        self.textFontSize = textFontSize
        self.textBackgroundStyle = textBackgroundStyle
        self.textWeightStyle = textWeightStyle
        self.textCornerRadius = textCornerRadius
        self.textPaddingXRatio = textPaddingXRatio
        self.textPaddingYRatio = textPaddingYRatio
        self.stepSize = stepSize
        self.stepStyle = stepStyle
        self.redactStrength = redactStrength
        self.redactSolidColor = redactSolidColor
        self.autoRedactCategory = autoRedactCategory
        self.maskedSnippet = maskedSnippet
        self.confidence = confidence
    }

    var isAutoRedacted: Bool {
        kind == .redact && autoRedactCategory != nil
    }

    var effectiveTextFontSize: CGFloat {
        textFontSize ?? Self.textFontSize(for: strokeWidth)
    }

    var effectiveStepRadius: CGFloat {
        stepSize ?? Self.stepRadius(for: strokeWidth)
    }

    var boundingRect: CGRect {
        switch kind {
        case .arrow:
            let minX = min(startPoint.x, endPoint.x)
            let maxX = max(startPoint.x, endPoint.x)
            let minY = min(startPoint.y, endPoint.y)
            let maxY = max(startPoint.y, endPoint.y)
            let pad = max(14, strokeWidth * 3)
            return CGRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
        case .rectangle, .ellipse, .redact:
            return rect.standardized
        case .highlighter:
            if highlighterMode == .box {
                return rect.standardized
            }
            guard let first = points.first else { return rect.standardized }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for pt in points.dropFirst() {
                minX = min(minX, pt.x)
                maxX = max(maxX, pt.x)
                minY = min(minY, pt.y)
                maxY = max(maxY, pt.y)
            }
            let pad = max(12, strokeWidth * 2.5)
            return CGRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
        case .step:
            let radius = effectiveStepRadius
            return CGRect(
                x: startPoint.x - radius,
                y: startPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        case .text:
            return textLayout().pillRect
        }
    }

    static func stepRadius(for strokeWidth: CGFloat) -> CGFloat {
        max(15, 13 + strokeWidth * 1.2)
    }

    static func textFontSize(for strokeWidth: CGFloat) -> CGFloat {
        max(16, 15 + strokeWidth * 2.2)
    }

    static func makeTextFont(size: CGFloat, weightStyle: TextWeightStyle) -> NSFont {
        switch weightStyle {
        case .regular: return NSFont.systemFont(ofSize: size, weight: .regular)
        case .semibold: return NSFont.systemFont(ofSize: size, weight: .bold)
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        }
    }

    static func defaultTextPaddingXRatio(backgroundStyle: TextBackgroundStyle, cornerRadius: CornerRadiusPreset) -> CGFloat {
        guard backgroundStyle != .plain else { return 0.15 }
        return cornerRadius == .large ? 0.52 : 0.42
    }

    static func minTextPaddingXRatio(backgroundStyle: TextBackgroundStyle, cornerRadius: CornerRadiusPreset) -> CGFloat {
        guard backgroundStyle != .plain else { return 0.08 }
        return cornerRadius == .large ? 0.34 : 0.18
    }

    static let maxTextPaddingXRatio: CGFloat = 3.0

    static func defaultTextPaddingYRatio(backgroundStyle: TextBackgroundStyle) -> CGFloat {
        backgroundStyle == .plain ? 0.04 : 0.12
    }

    static let minTextPaddingYRatio: CGFloat = 0.0
    static let maxTextPaddingYRatio: CGFloat = 1.4

    func textLayout() -> TextCalloutLayout {
        Self.textLayout(
            text: text,
            origin: startPoint,
            fontSize: effectiveTextFontSize,
            weightStyle: textWeightStyle,
            backgroundStyle: textBackgroundStyle,
            cornerRadius: textCornerRadius,
            paddingXRatio: textPaddingXRatio,
            paddingYRatio: textPaddingYRatio
        )
    }

    static func textLayout(
        text: String,
        origin: CGPoint,
        fontSize: CGFloat,
        weightStyle: TextWeightStyle = .semibold,
        backgroundStyle: TextBackgroundStyle = .filled,
        cornerRadius: CornerRadiusPreset = .rounded,
        paddingXRatio: CGFloat? = nil,
        paddingYRatio: CGFloat? = nil
    ) -> TextCalloutLayout {
        let trimmed = text.trimmingCharacters(in: .newlines)
        let measureSample = trimmed.isEmpty ? "Text" : trimmed
        let font = makeTextFont(size: fontSize, weightStyle: weightStyle)
        let measured = (measureSample as NSString).boundingRect(
            with: NSSize(width: 1_000_000, height: 1_000_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let textWidth = ceil(measured.width) + 2
        let textHeight = ceil(measured.height)

        let minXRatio = minTextPaddingXRatio(backgroundStyle: backgroundStyle, cornerRadius: cornerRadius)
        let rawXRatio = paddingXRatio ?? defaultTextPaddingXRatio(backgroundStyle: backgroundStyle, cornerRadius: cornerRadius)
        let clampedXRatio = min(max(rawXRatio, minXRatio), maxTextPaddingXRatio)
        let padX = max(backgroundStyle == .plain ? 2 : 4, fontSize * clampedXRatio)

        let rawYRatio = paddingYRatio ?? defaultTextPaddingYRatio(backgroundStyle: backgroundStyle)
        let clampedYRatio = min(max(rawYRatio, minTextPaddingYRatio), maxTextPaddingYRatio)
        let padY = fontSize * clampedYRatio

        let minW: CGFloat = trimmed.isEmpty ? max(84, fontSize * 3.8) : 24
        let pillWidth = max(minW, textWidth + padX * 2)
        let pillHeight = max(textHeight + padY * 2, fontSize * 1.1)

        return TextCalloutLayout(
            content: trimmed,
            font: font,
            textSize: CGSize(width: textWidth, height: textHeight),
            padX: padX,
            padY: padY,
            pillRect: CGRect(x: origin.x, y: origin.y, width: pillWidth, height: pillHeight)
        )
    }

    static func textBounds(
        text: String,
        origin: CGPoint,
        fontSize: CGFloat,
        weightStyle: TextWeightStyle = .semibold,
        backgroundStyle: TextBackgroundStyle = .filled,
        cornerRadius: CornerRadiusPreset = .rounded,
        paddingXRatio: CGFloat? = nil,
        paddingYRatio: CGFloat? = nil
    ) -> CGRect {
        textLayout(
            text: text,
            origin: origin,
            fontSize: fontSize,
            weightStyle: weightStyle,
            backgroundStyle: backgroundStyle,
            cornerRadius: cornerRadius,
            paddingXRatio: paddingXRatio,
            paddingYRatio: paddingYRatio
        ).pillRect
    }

    static func textBounds(text: String, origin: CGPoint, strokeWidth: CGFloat) -> CGRect {
        textBounds(text: text, origin: origin, fontSize: textFontSize(for: strokeWidth))
    }

    func contains(pixelPoint: CGPoint, tolerance: CGFloat = 10, directEditMode: Bool = false) -> Bool {
        switch kind {
        case .arrow:
            return Self.distanceFromPoint(pixelPoint, toSegmentStart: startPoint, end: endPoint) <= max(tolerance, strokeWidth * 2.5)
        case .highlighter:
            if highlighterMode == .box {
                let pad = min(tolerance, 5)
                return rect.standardized.insetBy(dx: -pad, dy: -pad).contains(pixelPoint)
            }
            guard !points.isEmpty else { return false }
            if points.count == 1 {
                return hypot(pixelPoint.x - points[0].x, pixelPoint.y - points[0].y) <= max(tolerance, strokeWidth * 2.5)
            }
            for i in 0..<(points.count - 1) {
                if Self.distanceFromPoint(pixelPoint, toSegmentStart: points[i], end: points[i + 1]) <= max(tolerance, strokeWidth * 2.5) {
                    return true
                }
            }
            return false
        case .rectangle:
            let edgeTol = max(tolerance, strokeWidth * 1.6)
            let outer = rect.insetBy(dx: -edgeTol, dy: -edgeTol)
            guard outer.contains(pixelPoint) else { return false }
            if fillStyle == .solid || fillStyle == .tinted || (fillStyle == .spotlight && !directEditMode) {
                return true
            }
            let inner = rect.insetBy(dx: edgeTol, dy: edgeTol)
            if inner.isNull || inner.width <= 0 || inner.height <= 0 {
                return true
            }
            return !inner.contains(pixelPoint)
        case .ellipse:
            let edgeTol = max(tolerance, strokeWidth * 1.6)
            let rx = rect.width / 2
            let ry = rect.height / 2
            let dx = pixelPoint.x - rect.midX
            let dy = pixelPoint.y - rect.midY
            let outerNorm = hypot(dx / max(1, rx + edgeTol), dy / max(1, ry + edgeTol))
            guard outerNorm <= 1.0 else { return false }
            if fillStyle == .solid || fillStyle == .tinted || (fillStyle == .spotlight && !directEditMode) {
                return true
            }
            if rx <= edgeTol || ry <= edgeTol {
                return true
            }
            let innerNorm = hypot(dx / max(1, rx - edgeTol), dy / max(1, ry - edgeTol))
            return innerNorm >= 1.0
        case .redact:
            let pad: CGFloat = directEditMode ? 1.5 : min(tolerance, 5)
            return rect.insetBy(dx: -pad, dy: -pad).contains(pixelPoint)
        case .step:
            return hypot(pixelPoint.x - startPoint.x, pixelPoint.y - startPoint.y) <= effectiveStepRadius + min(tolerance, 6)
        case .text:
            let pad = min(tolerance, 6)
            return boundingRect.insetBy(dx: -pad, dy: -pad).contains(pixelPoint)
        }
    }

    func translated(by delta: CGSize) -> AnnotationItem {
        var copy = self
        copy.startPoint = CGPoint(x: startPoint.x + delta.width, y: startPoint.y + delta.height)
        copy.endPoint = CGPoint(x: endPoint.x + delta.width, y: endPoint.y + delta.height)
        copy.rect = rect.offsetBy(dx: delta.width, dy: delta.height)
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    private static func distanceFromPoint(_ p: CGPoint, toSegmentStart a: CGPoint, end b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0.0001 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}

enum CanvasZoomMode: Equatable, Sendable {
    case fit
    case percent100
    case percent200
    case custom(CGFloat)

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .percent100: return "100%"
        case .percent200: return "200%"
        case .custom(let factor):
            return "\(Int((factor * 100).rounded()))%"
        }
    }

    func scaleFactor(fitScale: CGFloat) -> CGFloat {
        switch self {
        case .fit: return fitScale
        case .percent100: return 1.0
        case .percent200: return 2.0
        case .custom(let factor): return min(max(factor, 0.15), 6.0)
        }
    }
}

/// Converts between SwiftUI editor view coordinates (points) and native `CGImage` pixel coordinates.
struct CanvasCoordinateMapper: Equatable, Sendable {
    let imageSize: CGSize
    let renderedImageRect: CGRect

    var scaleX: CGFloat {
        guard renderedImageRect.width > 0 else { return 1 }
        return imageSize.width / renderedImageRect.width
    }

    var scaleY: CGFloat {
        guard renderedImageRect.height > 0 else { return 1 }
        return imageSize.height / renderedImageRect.height
    }

    func viewPointToImagePixel(_ viewPoint: CGPoint, clamped: Bool = true) -> CGPoint {
        guard renderedImageRect.width > 0, renderedImageRect.height > 0 else { return .zero }
        var px = (viewPoint.x - renderedImageRect.minX) * scaleX
        var py = (viewPoint.y - renderedImageRect.minY) * scaleY
        if clamped {
            px = min(max(0, px), imageSize.width)
            py = min(max(0, py), imageSize.height)
        }
        return CGPoint(x: px, y: py)
    }

    func imagePixelToViewPoint(_ pixelPoint: CGPoint) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return renderedImageRect.origin }
        let vx = renderedImageRect.minX + (pixelPoint.x / imageSize.width) * renderedImageRect.width
        let vy = renderedImageRect.minY + (pixelPoint.y / imageSize.height) * renderedImageRect.height
        return CGPoint(x: vx, y: vy)
    }

    func viewRectToImagePixel(_ viewRect: CGRect, clamped: Bool = true) -> CGRect {
        let std = viewRect.standardized
        let topLeft = viewPointToImagePixel(CGPoint(x: std.minX, y: std.minY), clamped: clamped)
        let bottomRight = viewPointToImagePixel(CGPoint(x: std.maxX, y: std.maxY), clamped: clamped)
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    func imagePixelToViewRect(_ pixelRect: CGRect) -> CGRect {
        let std = pixelRect.standardized
        let topLeft = imagePixelToViewPoint(CGPoint(x: std.minX, y: std.minY))
        let bottomRight = imagePixelToViewPoint(CGPoint(x: std.maxX, y: std.maxY))
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    static func fitScale(imageSize: CGSize, viewportSize: CGSize, padding: CGFloat = 28) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > padding * 2, viewportSize.height > padding * 2 else {
            return 1.0
        }
        let availW = max(40, viewportSize.width - padding * 2)
        let availH = max(40, viewportSize.height - padding * 2)
        return min(1.0, min(availW / imageSize.width, availH / imageSize.height))
    }

    static func computeRenderedImageRect(
        imageSize: CGSize,
        viewportSize: CGSize,
        zoomScale: CGFloat,
        panOffset: CGSize
    ) -> CGRect {
        let drawnW = max(1, imageSize.width * zoomScale)
        let drawnH = max(1, imageSize.height * zoomScale)
        let x = (viewportSize.width - drawnW) / 2 + panOffset.width
        let y = (viewportSize.height - drawnH) / 2 + panOffset.height
        return CGRect(x: x, y: y, width: drawnW, height: drawnH)
    }
}

private struct EditorSnapshot: Equatable {
    let annotations: [AnnotationItem]
    let cropRect: CGRect?
    let beautify: BeautifyConfig
    let nextStepNumber: Int
    let reviewItems: [AutoRedactReviewItem]
    let activeTool: ScreenshotTool
}

@MainActor
final class ScreenshotEditorSession: ObservableObject {
    static let maxUndoHistory = 60

    @Published private(set) var baseImage: CGImage?
    @Published private(set) var imagePixelSize: CGSize
    @Published private(set) var annotations: [AnnotationItem] = []
    @Published private(set) var cropRect: CGRect? = nil
    @Published var activeTool: ScreenshotTool = .arrow
    @Published var toolPresets: ScreenshotToolPresets
    @Published var beautify: BeautifyConfig
    @Published var selectedAnnotationID: UUID? = nil
    @Published var zoomMode: CanvasZoomMode = .fit
    @Published var panOffset: CGSize = .zero
    @Published private(set) var reviewItems: [AutoRedactReviewItem] = []
    @Published var isRunningAutoRedact: Bool = false
    @Published var isRunningOCR: Bool = false
    @Published private(set) var hasUnexportedChanges: Bool = false
    @Published private(set) var nextStepNumber: Int = 1
    @Published var editingTextAnnotationID: UUID? = nil

    var onPresetsChanged: ((ScreenshotToolPresets, ScreenshotTool) -> Void)?

    var selectedColor: AnnotationColor {
        get {
            switch activeTool {
            case .arrow: return toolPresets.arrow.color
            case .rectangle: return toolPresets.rectangle.color
            case .ellipse: return toolPresets.ellipse.color
            case .highlighter: return toolPresets.highlighter.color
            case .text: return toolPresets.text.color
            case .step: return toolPresets.step.color
            case .select, .redact, .crop: return toolPresets.arrow.color
            }
        }
        set {
            switch activeTool {
            case .arrow: toolPresets.arrow.color = newValue
            case .rectangle: toolPresets.rectangle.color = newValue
            case .ellipse: toolPresets.ellipse.color = newValue
            case .highlighter: toolPresets.highlighter.color = newValue
            case .text: toolPresets.text.color = newValue
            case .step: toolPresets.step.color = newValue
            case .select, .redact, .crop: toolPresets.arrow.color = newValue
            }
        }
    }

    var strokeWidth: CGFloat {
        get {
            switch activeTool {
            case .arrow: return toolPresets.arrow.strokeWidth
            case .rectangle: return toolPresets.rectangle.strokeWidth
            case .ellipse: return toolPresets.ellipse.strokeWidth
            case .highlighter: return toolPresets.highlighter.strokeWidth
            case .select, .text, .step, .redact, .crop: return toolPresets.arrow.strokeWidth
            }
        }
        set {
            let normalized = max(1, newValue)
            switch activeTool {
            case .arrow: toolPresets.arrow.strokeWidth = normalized
            case .rectangle: toolPresets.rectangle.strokeWidth = normalized
            case .ellipse: toolPresets.ellipse.strokeWidth = normalized
            case .highlighter: toolPresets.highlighter.strokeWidth = normalized
            case .select, .text, .step, .redact, .crop: toolPresets.arrow.strokeWidth = normalized
            }
        }
    }

    var redactStyle: RedactStyle {
        get { toolPresets.redact.style }
        set { toolPresets.redact.style = newValue }
    }

    private struct EditorExportState: Equatable {
        let annotations: [AnnotationItem]
        let cropRect: CGRect?
        let beautify: BeautifyConfig
    }

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var lastExportedState: EditorExportState
    private var textEditBaselineAnnotations: [AnnotationItem]? = nil
    private var newlyCreatedTextAnnotationID: UUID? = nil

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(image: CGImage, defaultRedactStyle: RedactStyle = .pixelate) {
        self.baseImage = image
        self.imagePixelSize = CGSize(width: image.width, height: image.height)
        var presets = ScreenshotToolPresets()
        presets.redact.style = defaultRedactStyle
        self.toolPresets = presets
        self.beautify = presets.beautify
        self.lastExportedState = EditorExportState(annotations: [], cropRect: nil, beautify: presets.beautify)
    }

    init(image: CGImage, config: QuickScreenshotConfig) {
        self.baseImage = image
        self.imagePixelSize = CGSize(width: image.width, height: image.height)
        var presets = config.toolPresets
        presets.redact.style = config.defaultRedactMode
        self.toolPresets = presets
        self.beautify = presets.beautify
        self.activeTool = config.resolvedStartingTool()
        self.lastExportedState = EditorExportState(annotations: [], cropRect: nil, beautify: presets.beautify)
    }

    private func syncUnexportedChanges() {
        hasUnexportedChanges = EditorExportState(
            annotations: annotations,
            cropRect: cropRect,
            beautify: beautify
        ) != lastExportedState
    }

    private func notifyPresetsChanged() {
        onPresetsChanged?(toolPresets, activeTool)
    }

    private func currentSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            annotations: annotations,
            cropRect: cropRect,
            beautify: beautify,
            nextStepNumber: nextStepNumber,
            reviewItems: reviewItems,
            activeTool: activeTool
        )
    }

    private func recordUndoCheckpoint() {
        undoStack.append(currentSnapshot())
        if undoStack.count > Self.maxUndoHistory {
            undoStack.removeFirst(undoStack.count - Self.maxUndoHistory)
        }
        redoStack.removeAll()
    }

    func undo() {
        finishTextEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(previous)
    }

    func redo() {
        finishTextEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(next)
    }

    private func applySnapshot(_ snapshot: EditorSnapshot) {
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
        beautify = snapshot.beautify
        toolPresets.beautify = snapshot.beautify
        nextStepNumber = snapshot.nextStepNumber
        reviewItems = snapshot.reviewItems
        activeTool = snapshot.activeTool
        if let selected = selectedAnnotationID, !annotations.contains(where: { $0.id == selected }) {
            selectedAnnotationID = nil
        }
        if let editing = editingTextAnnotationID, !annotations.contains(where: { $0.id == editing }) {
            editingTextAnnotationID = nil
        }
        syncUnexportedChanges()
    }

    @discardableResult
    func addAnnotation(_ item: AnnotationItem, selectAfterAdd: Bool = true) -> AnnotationItem {
        recordUndoCheckpoint()
        annotations.append(item)
        if selectAfterAdd {
            selectedAnnotationID = item.id
        }
        syncUnexportedChanges()
        return item
    }

    @discardableResult
    func addStepBadge(at pixelPoint: CGPoint) -> AnnotationItem {
        recordUndoCheckpoint()
        let preset = toolPresets.step
        let item = AnnotationItem(
            kind: .step,
            startPoint: pixelPoint,
            color: preset.color,
            strokeWidth: 4,
            stepNumber: nextStepNumber,
            stepSize: preset.size,
            stepStyle: preset.style
        )
        nextStepNumber += 1
        annotations.append(item)
        selectedAnnotationID = item.id
        syncUnexportedChanges()
        return item
    }

    func beginEditingTextAnnotation(id: UUID) {
        guard annotations.contains(where: { $0.id == id && $0.kind == .text }) else { return }
        if editingTextAnnotationID != id {
            finishTextEditing()
        }
        newlyCreatedTextAnnotationID = nil
        textEditBaselineAnnotations = annotations
        selectedAnnotationID = id
        editingTextAnnotationID = id
    }

    @discardableResult
    func beginTextCallout(at pixelPoint: CGPoint, initialText: String = "") -> AnnotationItem {
        finishTextEditing()
        recordUndoCheckpoint()
        let preset = toolPresets.text
        let item = AnnotationItem(
            kind: .text,
            startPoint: pixelPoint,
            color: preset.color,
            strokeWidth: 4,
            text: initialText,
            textFontSize: preset.fontSize,
            textBackgroundStyle: preset.backgroundStyle,
            textWeightStyle: preset.weightStyle,
            textCornerRadius: preset.cornerRadius
        )
        annotations.append(item)
        textEditBaselineAnnotations = nil
        newlyCreatedTextAnnotationID = item.id
        selectedAnnotationID = item.id
        editingTextAnnotationID = item.id
        syncUnexportedChanges()
        return item
    }

    func updateTextAnnotation(id: UUID, text: String) {
        guard let idx = annotations.firstIndex(where: { $0.id == id && $0.kind == .text }) else { return }
        guard annotations[idx].text != text else { return }
        annotations[idx].text = text
        syncUnexportedChanges()
    }

    func finishTextEditing() {
        let activeEditID = editingTextAnnotationID
        let createdID = newlyCreatedTextAnnotationID
        newlyCreatedTextAnnotationID = nil

        if let activeEditID,
           let idx = annotations.firstIndex(where: { $0.id == activeEditID && $0.kind == .text }),
           annotations[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editingTextAnnotationID = nil
            if createdID == activeEditID {
                textEditBaselineAnnotations = nil
                annotations.remove(at: idx)
                if selectedAnnotationID == activeEditID {
                    selectedAnnotationID = nil
                }
                if let lastSnap = undoStack.last,
                   !lastSnap.annotations.contains(where: { $0.id == activeEditID }) {
                    _ = undoStack.popLast()
                }
                syncUnexportedChanges()
                return
            } else {
                if let baseline = textEditBaselineAnnotations {
                    textEditBaselineAnnotations = nil
                    var cleaned = annotations
                    cleaned.remove(at: idx)
                    if selectedAnnotationID == activeEditID {
                        selectedAnnotationID = nil
                    }
                    commitMutationSnapshot(before: baseline, after: cleaned)
                } else {
                    deleteAnnotation(id: activeEditID)
                }
                return
            }
        }

        if let baseline = textEditBaselineAnnotations {
            textEditBaselineAnnotations = nil
            if baseline != annotations {
                commitMutationSnapshot(before: baseline, after: annotations)
            }
        }
        editingTextAnnotationID = nil
    }

    func commitMutationSnapshot(
        before snapshotAnnotations: [AnnotationItem],
        after updatedAnnotations: [AnnotationItem]
    ) {
        guard snapshotAnnotations != updatedAnnotations else { return }
        let previous = EditorSnapshot(
            annotations: snapshotAnnotations,
            cropRect: cropRect,
            beautify: beautify,
            nextStepNumber: nextStepNumber,
            reviewItems: reviewItems,
            activeTool: activeTool
        )
        undoStack.append(previous)
        if undoStack.count > Self.maxUndoHistory {
            undoStack.removeFirst(undoStack.count - Self.maxUndoHistory)
        }
        redoStack.removeAll()
        annotations = updatedAnnotations
        syncUnexportedChanges()
    }

    func updateAnnotationInPlace(_ updated: AnnotationItem) {
        guard let idx = annotations.firstIndex(where: { $0.id == updated.id }) else { return }
        annotations[idx] = updated
        if let reviewIdx = reviewItems.firstIndex(where: { $0.annotationID == updated.id }) {
            reviewItems[reviewIdx].rect = updated.rect
        }
    }

    func moveAnnotation(id: UUID, by delta: CGSize) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }),
              !annotations[idx].isAutoRedacted else { return }
        let snapshot = annotations
        var updated = annotations
        updated[idx] = updated[idx].translated(by: delta)
        commitMutationSnapshot(before: snapshot, after: updated)
    }

    func deleteAnnotation(id: UUID) {
        guard let deletedItem = annotations.first(where: { $0.id == id }) else { return }
        let deletedStep = deletedItem.kind == .step
        recordUndoCheckpoint()
        annotations.removeAll { $0.id == id }
        reviewItems.removeAll { $0.annotationID == id }
        if deletedStep {
            nextStepNumber = (annotations.filter { $0.kind == .step }.map(\.stepNumber).max() ?? 0) + 1
        }
        if selectedAnnotationID == id {
            selectedAnnotationID = nil
        }
        if editingTextAnnotationID == id {
            textEditBaselineAnnotations = nil
            editingTextAnnotationID = nil
        }
        syncUnexportedChanges()
    }

    func deleteSelected() {
        guard let selectedAnnotationID else { return }
        deleteAnnotation(id: selectedAnnotationID)
    }

    @discardableResult
    func duplicateSelected() -> AnnotationItem? {
        guard let id = selectedAnnotationID,
              let source = annotations.first(where: { $0.id == id }) else {
            return nil
        }
        recordUndoCheckpoint()
        let maxX = max(1, imagePixelSize.width)
        let maxY = max(1, imagePixelSize.height)
        let bounds = source.boundingRect
        let dx: CGFloat = (bounds.maxX + 20 <= maxX) ? 18 : -18
        let dy: CGFloat = (bounds.maxY + 20 <= maxY) ? 18 : -18
        var copy = source.translated(by: CGSize(width: dx, height: dy))
        copy = AnnotationItem(
            id: UUID(),
            kind: copy.kind,
            startPoint: copy.startPoint,
            endPoint: copy.endPoint,
            rect: copy.rect,
            points: copy.points,
            color: copy.color,
            strokeWidth: copy.strokeWidth,
            text: copy.text,
            stepNumber: copy.kind == .step ? nextStepNumber : copy.stepNumber,
            redactStyle: copy.redactStyle,
            arrowStyle: copy.arrowStyle,
            dashStyle: copy.dashStyle,
            fillStyle: copy.fillStyle,
            cornerRadius: copy.cornerRadius,
            highlighterMode: copy.highlighterMode,
            highlighterOpacity: copy.highlighterOpacity,
            textFontSize: copy.textFontSize,
            textBackgroundStyle: copy.textBackgroundStyle,
            textWeightStyle: copy.textWeightStyle,
            textCornerRadius: copy.textCornerRadius,
            textPaddingXRatio: copy.textPaddingXRatio,
            textPaddingYRatio: copy.textPaddingYRatio,
            stepSize: copy.stepSize,
            stepStyle: copy.stepStyle,
            redactStrength: copy.redactStrength,
            redactSolidColor: copy.redactSolidColor
        )
        if copy.kind == .step {
            nextStepNumber += 1
        }
        annotations.append(copy)
        selectedAnnotationID = copy.id
        syncUnexportedChanges()
        return copy
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedAnnotationID else { return }
        moveAnnotation(id: id, by: CGSize(width: dx, height: dy))
    }

    func bringSelectedToFront() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              idx < annotations.count - 1 else {
            return
        }
        recordUndoCheckpoint()
        let item = annotations.remove(at: idx)
        annotations.append(item)
        syncUnexportedChanges()
    }

    func sendSelectedToBack() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              idx > 0 else {
            return
        }
        recordUndoCheckpoint()
        let item = annotations.remove(at: idx)
        annotations.insert(item, at: 0)
        syncUnexportedChanges()
    }

    func setNextStepNumber(_ value: Int) {
        nextStepNumber = min(max(value, 1), 99)
    }

    func resetStepNumber() {
        nextStepNumber = 1
    }

    func clearAllAnnotations() {
        guard !annotations.isEmpty else { return }
        finishTextEditing()
        recordUndoCheckpoint()
        annotations.removeAll()
        reviewItems.removeAll()
        selectedAnnotationID = nil
        editingTextAnnotationID = nil
        nextStepNumber = 1
        syncUnexportedChanges()
    }

    func setCropRect(_ rect: CGRect?) {
        let normalized: CGRect?
        if let rect {
            let clamped = rect.standardized.intersection(CGRect(origin: .zero, size: imagePixelSize))
            normalized = (clamped.width >= 8 && clamped.height >= 8) ? clamped.integral : nil
        } else {
            normalized = nil
        }
        guard normalized != cropRect else { return }
        recordUndoCheckpoint()
        cropRect = normalized
        syncUnexportedChanges()
    }

    func clearCrop() {
        setCropRect(nil)
    }

    @discardableResult
    func applyAutoRedactSuggestions(_ candidates: [AutoRedactCandidate]) -> Int {
        let existingRedacts = annotations.filter { $0.kind == .redact }
        let freshCandidates = candidates.filter { candidate in
            let candidateArea = max(1, candidate.rect.width * candidate.rect.height)
            return !existingRedacts.contains { existing in
                let overlap = existing.rect.intersection(candidate.rect)
                guard !overlap.isNull else { return false }
                return (overlap.width * overlap.height) / candidateArea >= 0.50
            }
        }
        guard !freshCandidates.isEmpty else { return 0 }
        recordUndoCheckpoint()
        let preset = toolPresets.redact
        var newReviewItems: [AutoRedactReviewItem] = []
        for candidate in freshCandidates {
            let item = AnnotationItem(
                kind: .redact,
                rect: candidate.rect,
                color: .black,
                strokeWidth: 4,
                redactStyle: preset.style,
                redactStrength: preset.strength,
                redactSolidColor: preset.solidColor,
                autoRedactCategory: candidate.category,
                maskedSnippet: candidate.maskedSnippet,
                confidence: candidate.confidence
            )
            annotations.append(item)
            newReviewItems.append(
                AutoRedactReviewItem(
                    annotationID: item.id,
                    category: candidate.category,
                    maskedSnippet: candidate.maskedSnippet,
                    confidence: candidate.confidence,
                    rect: candidate.rect
                )
            )
        }
        reviewItems.append(contentsOf: newReviewItems)
        syncUnexportedChanges()
        return freshCandidates.count
    }

    func keepReviewItem(_ item: AutoRedactReviewItem) {
        reviewItems.removeAll { $0.id == item.id }
    }

    func removeReviewItem(_ item: AutoRedactReviewItem) {
        deleteAnnotation(id: item.annotationID)
    }

    func keepAllReviewItems() {
        reviewItems.removeAll()
    }

    func undoAllReviewItems() {
        guard !reviewItems.isEmpty else { return }
        let targetIDs = Set(reviewItems.map(\.annotationID))
        recordUndoCheckpoint()
        annotations.removeAll { targetIDs.contains($0.id) }
        reviewItems.removeAll()
        if let selected = selectedAnnotationID, targetIDs.contains(selected) {
            selectedAnnotationID = nil
        }
        syncUnexportedChanges()
    }

    // MARK: - Contextual & Per-Tool Mutators

    private func selectedAnnotationIndex() -> Int? {
        guard let id = selectedAnnotationID else { return nil }
        return annotations.firstIndex(where: { $0.id == id })
    }

    private func updateColorPreset(for kind: AnnotationKind, color: AnnotationColor) {
        switch kind {
        case .arrow: toolPresets.arrow.color = color
        case .rectangle: toolPresets.rectangle.color = color
        case .ellipse: toolPresets.ellipse.color = color
        case .highlighter: toolPresets.highlighter.color = color
        case .text: toolPresets.text.color = color
        case .step: toolPresets.step.color = color
        case .redact: break
        }
    }

    private func updateStrokePreset(for kind: AnnotationKind, width: CGFloat) {
        switch kind {
        case .arrow: toolPresets.arrow.strokeWidth = width
        case .rectangle: toolPresets.rectangle.strokeWidth = width
        case .ellipse: toolPresets.ellipse.strokeWidth = width
        case .highlighter: toolPresets.highlighter.strokeWidth = width
        case .text, .step, .redact: break
        }
    }

    func updateRedactStyleForExistingSelectionOrTool(_ style: RedactStyle) {
        toolPresets.redact.style = style
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .redact,
           annotations[idx].redactStyle != style {
            recordUndoCheckpoint()
            annotations[idx].redactStyle = style
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateRedactStrength(_ strength: RedactStrength) {
        toolPresets.redact.strength = strength
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .redact,
           annotations[idx].redactStrength != strength {
            recordUndoCheckpoint()
            annotations[idx].redactStrength = strength
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateRedactSolidColor(_ solidColor: RedactSolidColor) {
        toolPresets.redact.solidColor = solidColor
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .redact,
           annotations[idx].redactSolidColor != solidColor {
            recordUndoCheckpoint()
            annotations[idx].redactSolidColor = solidColor
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateColorForExistingSelectionOrTool(_ color: AnnotationColor) {
        if let idx = selectedAnnotationIndex(), annotations[idx].kind != .redact {
            let kind = annotations[idx].kind
            updateColorPreset(for: kind, color: color)
            if annotations[idx].color != color {
                recordUndoCheckpoint()
                annotations[idx].color = color
                syncUnexportedChanges()
            }
        } else {
            selectedColor = color
        }
        notifyPresetsChanged()
    }

    func updateStrokeWidthForExistingSelectionOrTool(_ width: CGFloat) {
        let normalized = max(1, width)
        if let idx = selectedAnnotationIndex(), annotations[idx].kind != .redact {
            let kind = annotations[idx].kind
            updateStrokePreset(for: kind, width: normalized)
            if abs(annotations[idx].strokeWidth - normalized) > 0.1 {
                recordUndoCheckpoint()
                annotations[idx].strokeWidth = normalized
                syncUnexportedChanges()
            }
        } else {
            strokeWidth = normalized
        }
        notifyPresetsChanged()
    }

    func updateArrowStyle(_ style: ArrowStyle) {
        toolPresets.arrow.style = style
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .arrow,
           annotations[idx].arrowStyle != style {
            recordUndoCheckpoint()
            annotations[idx].arrowStyle = style
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateDashStyle(_ dash: StrokeDashStyle) {
        let targetKind = selectedAnnotationIndex().map { annotations[$0].kind }
        switch targetKind {
        case .arrow: toolPresets.arrow.dashStyle = dash
        case .rectangle: toolPresets.rectangle.dashStyle = dash
        case .ellipse: toolPresets.ellipse.dashStyle = dash
        case nil:
            if activeTool == .arrow { toolPresets.arrow.dashStyle = dash }
            else if activeTool == .rectangle { toolPresets.rectangle.dashStyle = dash }
            else if activeTool == .ellipse { toolPresets.ellipse.dashStyle = dash }
        default: break
        }
        if let idx = selectedAnnotationIndex(),
           [.arrow, .rectangle, .ellipse].contains(annotations[idx].kind),
           annotations[idx].dashStyle != dash {
            recordUndoCheckpoint()
            annotations[idx].dashStyle = dash
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateFillStyle(_ fill: ShapeFillStyle) {
        let targetKind = selectedAnnotationIndex().map { annotations[$0].kind }
        switch targetKind {
        case .rectangle: toolPresets.rectangle.fillStyle = fill
        case .ellipse: toolPresets.ellipse.fillStyle = fill
        case nil:
            if activeTool == .rectangle { toolPresets.rectangle.fillStyle = fill }
            else if activeTool == .ellipse { toolPresets.ellipse.fillStyle = fill }
        default: break
        }
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .rectangle || annotations[idx].kind == .ellipse,
           annotations[idx].fillStyle != fill {
            recordUndoCheckpoint()
            annotations[idx].fillStyle = fill
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateCornerRadius(_ preset: CornerRadiusPreset) {
        toolPresets.rectangle.cornerRadius = preset
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .rectangle,
           annotations[idx].cornerRadius != preset {
            recordUndoCheckpoint()
            annotations[idx].cornerRadius = preset
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateHighlighterMode(_ mode: HighlighterMode) {
        toolPresets.highlighter.mode = mode
        notifyPresetsChanged()
    }

    func updateHighlighterOpacity(_ opacity: HighlighterOpacity) {
        toolPresets.highlighter.opacity = opacity
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .highlighter,
           annotations[idx].highlighterOpacity != opacity {
            recordUndoCheckpoint()
            annotations[idx].highlighterOpacity = opacity
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateTextFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 10), 120)
        toolPresets.text.fontSize = clamped
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .text,
           abs(annotations[idx].effectiveTextFontSize - clamped) > 0.1 {
            recordUndoCheckpoint()
            annotations[idx].textFontSize = clamped
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateTextBackgroundStyle(_ style: TextBackgroundStyle) {
        toolPresets.text.backgroundStyle = style
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .text,
           annotations[idx].textBackgroundStyle != style {
            recordUndoCheckpoint()
            annotations[idx].textBackgroundStyle = style
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateTextWeightStyle(_ weight: TextWeightStyle) {
        toolPresets.text.weightStyle = weight
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .text,
           annotations[idx].textWeightStyle != weight {
            recordUndoCheckpoint()
            annotations[idx].textWeightStyle = weight
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateTextCornerRadius(_ preset: CornerRadiusPreset) {
        toolPresets.text.cornerRadius = preset
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .text,
           annotations[idx].textCornerRadius != preset {
            recordUndoCheckpoint()
            annotations[idx].textCornerRadius = preset
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateStepSize(_ size: CGFloat) {
        let clamped = min(max(size, 14), 48)
        toolPresets.step.size = clamped
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .step,
           abs(annotations[idx].effectiveStepRadius - clamped) > 0.1 {
            recordUndoCheckpoint()
            annotations[idx].stepSize = clamped
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateStepStyle(_ style: StepBadgeStyle) {
        toolPresets.step.style = style
        if let idx = selectedAnnotationIndex(),
           annotations[idx].kind == .step,
           annotations[idx].stepStyle != style {
            recordUndoCheckpoint()
            annotations[idx].stepStyle = style
            syncUnexportedChanges()
        }
        notifyPresetsChanged()
    }

    func updateCropAspectRatio(_ ratio: CropAspectRatio) {
        toolPresets.crop.aspectRatio = ratio
        notifyPresetsChanged()
    }

    func updateBeautify(_ transform: (inout BeautifyConfig) -> Void) {
        var next = beautify
        transform(&next)
        next.padding = BeautifyConfig.clampedPadding(next.padding)
        next.cornerRadius = BeautifyConfig.clampedCornerRadius(next.cornerRadius)
        guard next != beautify else { return }
        recordUndoCheckpoint()
        beautify = next
        toolPresets.beautify = next
        syncUnexportedChanges()
        notifyPresetsChanged()
    }

    func markExported() {
        lastExportedState = EditorExportState(annotations: annotations, cropRect: cropRect, beautify: beautify)
        hasUnexportedChanges = false
    }

    func selectTool(_ tool: ScreenshotTool) {
        finishTextEditing()
        selectedAnnotationID = nil
        activeTool = tool
        notifyPresetsChanged()
    }

    func adjustZoom(by delta: CGFloat, fitScale: CGFloat) {
        let current = zoomMode.scaleFactor(fitScale: fitScale)
        let target = min(max(current + delta, 0.2), 6.0)
        zoomMode = .custom(target)
    }

    func setZoomAnchored(
        to targetScale: CGFloat,
        anchorViewPoint: CGPoint,
        viewportSize: CGSize,
        fitScale: CGFloat
    ) {
        let clamped = min(max(targetScale, 0.2), 6.0)
        let oldScale = zoomMode.scaleFactor(fitScale: fitScale)
        let oldRect = CanvasCoordinateMapper.computeRenderedImageRect(
            imageSize: imagePixelSize,
            viewportSize: viewportSize,
            zoomScale: oldScale,
            panOffset: panOffset
        )
        let fx = oldRect.width > 0 ? (anchorViewPoint.x - oldRect.minX) / oldRect.width : 0.5
        let fy = oldRect.height > 0 ? (anchorViewPoint.y - oldRect.minY) / oldRect.height : 0.5

        let newW = max(1, imagePixelSize.width * clamped)
        let newH = max(1, imagePixelSize.height * clamped)
        let newPanW = anchorViewPoint.x - fx * newW - (viewportSize.width - newW) / 2
        let newPanH = anchorViewPoint.y - fy * newH - (viewportSize.height - newH) / 2

        zoomMode = .custom(clamped)
        panOffset = CGSize(width: newPanW, height: newPanH)
    }

    func resetZoom() {
        zoomMode = .fit
        panOffset = .zero
    }

    func hitTestAnnotation(
        at pixelPoint: CGPoint,
        tolerance: CGFloat = 10,
        directEditMode: Bool = false,
        includeRedactions: Bool = true
    ) -> AnnotationItem? {
        for item in annotations.reversed() {
            if !includeRedactions && item.kind == .redact {
                continue
            }
            if item.contains(pixelPoint: pixelPoint, tolerance: tolerance, directEditMode: directEditMode) {
                return item
            }
        }
        return nil
    }

    func releaseImageMemory() {
        baseImage = nil
        undoStack.removeAll()
        redoStack.removeAll()
        annotations.removeAll()
        reviewItems.removeAll()
        textEditBaselineAnnotations = nil
        editingTextAnnotationID = nil
        lastExportedState = EditorExportState(annotations: [], cropRect: nil, beautify: beautify)
        hasUnexportedChanges = false
    }
}
