import AppKit
import CoreGraphics
import Foundation
import SwiftUI

enum ScreenshotTool: String, CaseIterable, Identifiable, Sendable {
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

enum AutoRedactCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiKey = "api_key"
    case githubToken = "github_token"
    case awsKey = "aws_key"
    case bearerToken = "bearer_token"
    case jwt = "jwt"
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
        case .creditCard: return "Card Number"
        case .email: return "Email"
        case .phone: return "Phone"
        }
    }

    var symbolName: String {
        switch self {
        case .apiKey, .githubToken, .awsKey, .bearerToken, .jwt:
            return "key.fill"
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
        redactStyle: RedactStyle = .solidBlack,
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
        self.autoRedactCategory = autoRedactCategory
        self.maskedSnippet = maskedSnippet
        self.confidence = confidence
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
            let radius = Self.stepRadius(for: strokeWidth)
            return CGRect(
                x: startPoint.x - radius,
                y: startPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        case .text:
            return Self.textBounds(text: text, origin: startPoint, strokeWidth: strokeWidth)
        }
    }

    static func stepRadius(for strokeWidth: CGFloat) -> CGFloat {
        max(15, 13 + strokeWidth * 1.2)
    }

    static func textFontSize(for strokeWidth: CGFloat) -> CGFloat {
        max(16, 15 + strokeWidth * 2.2)
    }

    static func textBounds(text: String, origin: CGPoint, strokeWidth: CGFloat) -> CGRect {
        let fontSize = textFontSize(for: strokeWidth)
        let lines = (text.isEmpty ? "Label" : text).components(separatedBy: "\n")
        let maxChars = max(4, lines.map(\.count).max() ?? 4)
        let estWidth = max(72, CGFloat(maxChars) * fontSize * 0.62 + 24)
        let estHeight = max(fontSize * 1.45, CGFloat(lines.count) * fontSize * 1.28 + 14)
        return CGRect(x: origin.x, y: origin.y, width: estWidth, height: estHeight)
    }

    func contains(pixelPoint: CGPoint, tolerance: CGFloat = 10, directEditMode: Bool = false) -> Bool {
        switch kind {
        case .arrow:
            return Self.distanceFromPoint(pixelPoint, toSegmentStart: startPoint, end: endPoint) <= max(tolerance, strokeWidth * 2.5)
        case .highlighter:
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
            if rx <= edgeTol || ry <= edgeTol {
                return true
            }
            let innerNorm = hypot(dx / max(1, rx - edgeTol), dy / max(1, ry - edgeTol))
            return innerNorm >= 1.0
        case .redact:
            let pad: CGFloat = directEditMode ? 1.5 : min(tolerance, 5)
            return rect.insetBy(dx: -pad, dy: -pad).contains(pixelPoint)
        case .step:
            return hypot(pixelPoint.x - startPoint.x, pixelPoint.y - startPoint.y) <= Self.stepRadius(for: strokeWidth) + min(tolerance, 6)
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
        case .custom(let factor): return min(max(factor, 0.15), 4.0)
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
    @Published var selectedColor: AnnotationColor = .red
    @Published var strokeWidth: CGFloat = 4
    @Published var redactStyle: RedactStyle
    @Published var selectedAnnotationID: UUID? = nil
    @Published var zoomMode: CanvasZoomMode = .fit
    @Published var panOffset: CGSize = .zero
    @Published private(set) var reviewItems: [AutoRedactReviewItem] = []
    @Published var isRunningAutoRedact: Bool = false
    @Published var isRunningOCR: Bool = false
    @Published private(set) var hasUnexportedChanges: Bool = false
    @Published private(set) var nextStepNumber: Int = 1
    @Published var editingTextAnnotationID: UUID? = nil

    private struct EditorExportState: Equatable {
        let annotations: [AnnotationItem]
        let cropRect: CGRect?
    }

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var lastExportedState = EditorExportState(annotations: [], cropRect: nil)
    private var textEditBaselineAnnotations: [AnnotationItem]? = nil

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(image: CGImage, defaultRedactStyle: RedactStyle = .solidBlack) {
        self.baseImage = image
        self.imagePixelSize = CGSize(width: image.width, height: image.height)
        self.redactStyle = defaultRedactStyle
    }

    private func syncUnexportedChanges() {
        hasUnexportedChanges = EditorExportState(annotations: annotations, cropRect: cropRect) != lastExportedState
    }

    private func currentSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            annotations: annotations,
            cropRect: cropRect,
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
        let item = AnnotationItem(
            kind: .step,
            startPoint: pixelPoint,
            color: selectedColor,
            strokeWidth: strokeWidth,
            stepNumber: nextStepNumber
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
        textEditBaselineAnnotations = annotations
        selectedAnnotationID = id
        editingTextAnnotationID = id
    }

    @discardableResult
    func beginTextCallout(at pixelPoint: CGPoint, initialText: String = "Note") -> AnnotationItem {
        finishTextEditing()
        recordUndoCheckpoint()
        let item = AnnotationItem(
            kind: .text,
            startPoint: pixelPoint,
            color: selectedColor,
            strokeWidth: strokeWidth,
            text: initialText
        )
        annotations.append(item)
        textEditBaselineAnnotations = nil
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
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
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

    func applyAutoRedactSuggestions(_ candidates: [AutoRedactCandidate]) {
        guard !candidates.isEmpty else { return }
        recordUndoCheckpoint()
        var newReviewItems: [AutoRedactReviewItem] = []
        for candidate in candidates {
            let item = AnnotationItem(
                kind: .redact,
                rect: candidate.rect,
                color: .black,
                strokeWidth: strokeWidth,
                redactStyle: redactStyle,
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

    func updateRedactStyleForExistingSelectionOrTool(_ style: RedactStyle) {
        redactStyle = style
        if let id = selectedAnnotationID,
           let idx = annotations.firstIndex(where: { $0.id == id && $0.kind == .redact }),
           annotations[idx].redactStyle != style {
            recordUndoCheckpoint()
            annotations[idx].redactStyle = style
            syncUnexportedChanges()
        }
    }

    func updateColorForExistingSelectionOrTool(_ color: AnnotationColor) {
        selectedColor = color
        if let id = selectedAnnotationID,
           let idx = annotations.firstIndex(where: { $0.id == id && $0.kind != .redact }),
           annotations[idx].color != color {
            recordUndoCheckpoint()
            annotations[idx].color = color
            syncUnexportedChanges()
        }
    }

    func updateStrokeWidthForExistingSelectionOrTool(_ width: CGFloat) {
        let normalized = max(1, width)
        strokeWidth = normalized
        if let id = selectedAnnotationID,
           let idx = annotations.firstIndex(where: { $0.id == id && $0.kind != .redact }),
           abs(annotations[idx].strokeWidth - normalized) > 0.1 {
            recordUndoCheckpoint()
            annotations[idx].strokeWidth = normalized
            syncUnexportedChanges()
        }
    }

    func markExported() {
        lastExportedState = EditorExportState(annotations: annotations, cropRect: cropRect)
        hasUnexportedChanges = false
    }

    func selectTool(_ tool: ScreenshotTool) {
        finishTextEditing()
        selectedAnnotationID = nil
        activeTool = tool
    }

    func adjustZoom(by delta: CGFloat, fitScale: CGFloat) {
        let current = zoomMode.scaleFactor(fitScale: fitScale)
        let target = min(max(current + delta, 0.2), 4.0)
        zoomMode = .custom(target)
    }

    func resetZoom() {
        zoomMode = .fit
        panOffset = .zero
    }

    func hitTestAnnotation(at pixelPoint: CGPoint, tolerance: CGFloat = 10, directEditMode: Bool = false) -> AnnotationItem? {
        for item in annotations.reversed() {
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
        lastExportedState = EditorExportState(annotations: [], cropRect: nil)
        hasUnexportedChanges = false
    }
}
