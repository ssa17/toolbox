import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotRenderer {
    private static let sharedCIContext = CIContext()
    private static let softwareCIContext = CIContext(options: [
        .useSoftwareRenderer: true
    ])

    /// Renders `baseImage` with all `annotations` and optional `cropRect` into a new
    /// full-resolution `CGImage`. All redactions are irreversibly flattened into the pixels.
    static func render(
        baseImage: CGImage,
        annotations: [AnnotationItem],
        cropRect: CGRect? = nil
    ) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let canvasSize = CGSize(width: width, height: height)
        ctx.interpolationQuality = .high
        ctx.draw(baseImage, in: CGRect(origin: .zero, size: canvasSize))

        // Draw redactions first against the base screenshot, then non-redact annotations on top,
        // matching the editor canvas WYSIWYG stack.
        for item in annotations where item.kind == .redact {
            drawRedaction(item, in: ctx, canvasSize: canvasSize)
        }
        for item in annotations where item.kind != .redact {
            switch item.kind {
            case .redact:
                break
            case .highlighter:
                drawHighlighter(item, in: ctx, canvasHeight: canvasSize.height)
            case .rectangle:
                drawRectangle(item, in: ctx, canvasHeight: canvasSize.height)
            case .ellipse:
                drawEllipse(item, in: ctx, canvasHeight: canvasSize.height)
            case .arrow:
                drawArrow(item, in: ctx, canvasHeight: canvasSize.height)
            case .text:
                drawTextCallout(item, in: ctx, canvasHeight: canvasSize.height)
            case .step:
                drawStepBadge(item, in: ctx, canvasHeight: canvasSize.height)
            }
        }

        guard let full = ctx.makeImage() else { return nil }
        guard let cropRect else { return full }

        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clamped = cropRect.standardized.integral.intersection(imageBounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
            return full
        }
        return full.cropping(to: clamped) ?? full
    }

    /// Pre-bakes `.blur` and `.pixelate` redaction items into the base image for smooth interactive canvas rendering.
    static func renderBaseWithFilteredRedactions(
        baseImage: CGImage,
        annotations: [AnnotationItem]
    ) -> CGImage? {
        let filteredItems = annotations.filter { $0.kind == .redact && $0.redactStyle != .solidBlack }
        guard !filteredItems.isEmpty else { return baseImage }
        return render(baseImage: baseImage, annotations: filteredItems, cropRect: nil)
    }

    // MARK: - Coordinate Conversion (Top-Left Pixel Space → Bottom-Left CGContext Space)

    static func cgPoint(fromTopLeft point: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: canvasHeight - point.y)
    }

    static func cgRect(fromTopLeft rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        let std = rect.standardized
        return CGRect(
            x: std.minX,
            y: canvasHeight - std.maxY,
            width: std.width,
            height: std.height
        )
    }

    // MARK: - Primitive Drawing

    private static func drawRedaction(_ item: AnnotationItem, in ctx: CGContext, canvasSize: CGSize) {
        let imageBounds = CGRect(origin: .zero, size: canvasSize)
        let cgTarget = cgRect(fromTopLeft: item.rect, canvasHeight: canvasSize.height)
            .integral
            .intersection(imageBounds)
        guard !cgTarget.isNull, cgTarget.width >= 1, cgTarget.height >= 1 else { return }

        switch item.redactStyle {
        case .solidBlack:
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0))
            ctx.fill(cgTarget)
            ctx.restoreGState()

        case .blur:
            let minBoxDim = min(cgTarget.width, cgTarget.height)
            let blurRadius = max(10.0, min(24.0, minBoxDim * 0.28))
            drawFilteredRegion(in: ctx, cgTarget: cgTarget, fallbackBlockSize: max(8, Int(blurRadius * 0.55))) { clampedSource in
                clampedSource.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: blurRadius
                ])
            }

        case .pixelate:
            let minBoxDim = min(cgTarget.width, cgTarget.height)
            let blockScale = max(6.0, min(14.0, minBoxDim * 0.16))
            drawFilteredRegion(in: ctx, cgTarget: cgTarget, fallbackBlockSize: max(6, Int(blockScale.rounded()))) { clampedSource in
                // Slight pre-blur inside the clamped crop so thin Retina strokes blend
                // cleanly into fine mosaic cells instead of dropping pixels.
                let preBlurred = clampedSource.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: blockScale * 0.22
                ]).cropped(to: cgTarget).clampedToExtent()

                guard let filter = CIFilter(name: "CIPixellate") else { return nil }
                filter.setValue(preBlurred, forKey: kCIInputImageKey)
                filter.setValue(blockScale, forKey: kCIInputScaleKey)
                filter.setValue(CIVector(x: cgTarget.midX, y: cgTarget.midY), forKey: kCIInputCenterKey)
                return filter.outputImage
            }
        }
    }

    private static func drawFilteredRegion(
        in ctx: CGContext,
        cgTarget: CGRect,
        fallbackBlockSize: Int,
        transform: (CIImage) -> CIImage?
    ) {
        guard let snapshot = ctx.makeImage() else { return }
        // Crop to cgTarget BEFORE filtering and clamp within the cropped region so
        // adjacent unredacted pixels never bleed across the redaction boundary.
        let clampedSource = CIImage(cgImage: snapshot)
            .cropped(to: cgTarget)
            .clampedToExtent()

        let resolvedTile: CGImage?
        if let outputCI = transform(clampedSource)?.cropped(to: cgTarget) {
            resolvedTile = sharedCIContext.createCGImage(outputCI, from: cgTarget)
                ?? softwareCIContext.createCGImage(outputCI, from: cgTarget)
        } else {
            resolvedTile = nil
        }

        if let tile = resolvedTile ?? makeCPUMosaicTile(from: snapshot, cgTarget: cgTarget, blockSize: fallbackBlockSize) {
            ctx.saveGState()
            ctx.clip(to: cgTarget)
            ctx.setBlendMode(.copy)
            ctx.draw(tile, in: cgTarget)
            ctx.restoreGState()
        } else {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0))
            ctx.fill(cgTarget)
            ctx.restoreGState()
        }
    }

    private static func makeCPUMosaicTile(
        from snapshot: CGImage,
        cgTarget: CGRect,
        blockSize: Int
    ) -> CGImage? {
        let w = max(1, Int(cgTarget.width.rounded()))
        let h = max(1, Int(cgTarget.height.rounded()))
        let topLeftCrop = CGRect(
            x: cgTarget.minX,
            y: CGFloat(snapshot.height) - cgTarget.maxY,
            width: CGFloat(w),
            height: CGFloat(h)
        ).integral.intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        guard let cropped = snapshot.cropping(to: topLeftCrop),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let regionCtx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        regionCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = regionCtx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let cell = max(4, blockSize)
        var by = 0
        while by < h {
            let yEnd = min(h, by + cell)
            var bx = 0
            while bx < w {
                let xEnd = min(w, bx + cell)
                var sumR = 0, sumG = 0, sumB = 0, sumA = 0, count = 0
                for py in by..<yEnd {
                    let rowOffset = py * w * 4
                    for px in bx..<xEnd {
                        let idx = rowOffset + px * 4
                        sumR += Int(ptr[idx])
                        sumG += Int(ptr[idx + 1])
                        sumB += Int(ptr[idx + 2])
                        sumA += Int(ptr[idx + 3])
                        count += 1
                    }
                }
                if count > 0 {
                    let avgR = UInt8(clamping: sumR / count)
                    let avgG = UInt8(clamping: sumG / count)
                    let avgB = UInt8(clamping: sumB / count)
                    let avgA = UInt8(clamping: sumA / count)
                    for py in by..<yEnd {
                        let rowOffset = py * w * 4
                        for px in bx..<xEnd {
                            let idx = rowOffset + px * 4
                            ptr[idx] = avgR
                            ptr[idx + 1] = avgG
                            ptr[idx + 2] = avgB
                            ptr[idx + 3] = avgA
                        }
                    }
                }
                bx += cell
            }
            by += cell
        }
        return regionCtx.makeImage()
    }

    private static func drawHighlighter(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        guard !item.points.isEmpty else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let strokeColor = item.color.cgColor.copy(alpha: 0.42) ?? item.color.cgColor
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(max(12, item.strokeWidth * 4.2))
        ctx.beginPath()
        let first = cgPoint(fromTopLeft: item.points[0], canvasHeight: canvasHeight)
        ctx.move(to: first)
        if item.points.count == 1 {
            ctx.addLine(to: CGPoint(x: first.x + 0.5, y: first.y + 0.5))
        } else {
            for pt in item.points.dropFirst() {
                ctx.addLine(to: cgPoint(fromTopLeft: pt, canvasHeight: canvasHeight))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawRectangle(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let target = cgRect(fromTopLeft: item.rect, canvasHeight: canvasHeight)
        guard target.width >= 1, target.height >= 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setLineWidth(item.strokeWidth)
        ctx.setLineJoin(.round)
        let path = CGPath(roundedRect: target, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawEllipse(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let target = cgRect(fromTopLeft: item.rect, canvasHeight: canvasHeight)
        guard target.width >= 1, target.height >= 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setLineWidth(item.strokeWidth)
        ctx.strokeEllipse(in: target)
        ctx.restoreGState()
    }

    private static func drawArrow(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let start = cgPoint(fromTopLeft: item.startPoint, canvasHeight: canvasHeight)
        let end = cgPoint(fromTopLeft: item.endPoint, canvasHeight: canvasHeight)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 2 else { return }

        let headLength = max(14, item.strokeWidth * 4.0)
        let headAngle: CGFloat = .pi / 6.5
        let angle = atan2(dy, dx)

        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * (headLength * 0.65),
            y: end.y - sin(angle) * (headLength * 0.65)
        )
        let leftWing = CGPoint(
            x: end.x - cos(angle - headAngle) * headLength,
            y: end.y - sin(angle - headAngle) * headLength
        )
        let rightWing = CGPoint(
            x: end.x - cos(angle + headAngle) * headLength,
            y: end.y - sin(angle + headAngle) * headLength
        )

        ctx.saveGState()
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        ctx.setLineWidth(item.strokeWidth)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        ctx.beginPath()
        ctx.move(to: end)
        ctx.addLine(to: leftWing)
        ctx.addLine(to: rightWing)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawStepBadge(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let center = cgPoint(fromTopLeft: item.startPoint, canvasHeight: canvasHeight)
        let radius = AnnotationItem.stepRadius(for: item.strokeWidth)
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.setFillColor(item.color.cgColor)
        ctx.fillEllipse(in: circleRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
        ctx.setLineWidth(max(2, item.strokeWidth * 0.55))
        ctx.strokeEllipse(in: circleRect)
        ctx.restoreGState()

        let textColor: NSColor = item.color == .white || item.color == .yellow ? .black : .white
        let font = NSFont.systemFont(ofSize: radius * 1.05, weight: .bold)
        let label = "\(item.stepNumber)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let size = label.size(withAttributes: attrs)
        drawWithAppKit(in: ctx) {
            label.draw(
                at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                withAttributes: attrs
            )
        }
    }

    private static func drawTextCallout(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let content = item.text.trimmingCharacters(in: .newlines)
        guard !content.isEmpty else { return }

        let fontSize = AnnotationItem.textFontSize(for: item.strokeWidth)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.color.nsColor
        ]
        let nsText = content as NSString
        let measured = nsText.boundingRect(
            with: NSSize(width: 2000, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        let padX: CGFloat = 10
        let padY: CGFloat = 6
        let topLeftPill = CGRect(
            x: item.startPoint.x,
            y: item.startPoint.y,
            width: ceil(measured.width) + padX * 2,
            height: ceil(measured.height) + padY * 2
        )
        let cgPill = cgRect(fromTopLeft: topLeftPill, canvasHeight: canvasHeight)

        let backdropColor: CGColor = item.color == .black
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
            : CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.86)

        ctx.saveGState()
        ctx.setFillColor(backdropColor)
        let pillPath = CGPath(roundedRect: cgPill, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.setStrokeColor(item.color.cgColor.copy(alpha: 0.55) ?? item.color.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(pillPath)
        ctx.strokePath()
        ctx.restoreGState()

        drawWithAppKit(in: ctx) {
            nsText.draw(
                in: NSRect(
                    x: cgPill.minX + padX,
                    y: cgPill.minY + padY,
                    width: ceil(measured.width),
                    height: ceil(measured.height)
                ),
                withAttributes: attrs
            )
        }
    }

    private static func drawWithAppKit(in ctx: CGContext, _ block: () -> Void) {
        let prev = NSGraphicsContext.current
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        block()
        NSGraphicsContext.current = prev
    }

    // MARK: - Encoding & Export

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Composites onto an opaque white sRGB surface (`noneSkipLast`) before JPEG encoding
    /// so transparent edges or regions never turn black.
    static func encodeJPEG(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let opaqueCtx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        opaqueCtx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        opaqueCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        opaqueCtx.interpolationQuality = .high
        opaqueCtx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let flattenedOpaque = opaqueCtx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let clampedQuality = QuickScreenshotConfig.clampedJPEGQuality(quality)
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: clampedQuality
        ]
        CGImageDestinationAddImage(dest, flattenedOpaque, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    @discardableResult
    static func copyToPasteboard(_ image: CGImage, pasteboard: NSPasteboard = .general) -> Bool {
        guard let pngData = encodePNG(image) else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        let tiffData = rep.tiffRepresentation

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let tiffData {
            item.setData(tiffData, forType: .tiff)
        }
        return pasteboard.writeObjects([item])
    }

    static func defaultFilename(format: ScreenshotSaveFormat, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Quick Screenshot \(formatter.string(from: now)).\(format.fileExtension)"
    }

    static func saveToDirectory(
        _ image: CGImage,
        format: ScreenshotSaveFormat,
        jpegQuality: Double,
        directoryPath: String,
        filename: String? = nil
    ) -> Result<URL, Error> {
        let expanded = (directoryPath as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: expanded, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let baseName = filename ?? defaultFilename(format: format)
            let destination = uniqueFileURL(in: dirURL, preferredFilename: baseName)
            try writeImage(image, to: destination, format: format, jpegQuality: jpegQuality)
            return .success(destination)
        } catch {
            return .failure(error)
        }
    }

    static func writeImage(
        _ image: CGImage,
        to url: URL,
        format: ScreenshotSaveFormat,
        jpegQuality: Double
    ) throws {
        let data: Data?
        switch format {
        case .png:
            data = encodePNG(image)
        case .jpeg:
            data = encodeJPEG(image, quality: jpegQuality)
        }
        guard let data else {
            throw NSError(
                domain: "Toolbox.QuickScreenshot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode screenshot as \(format.label)."]
            )
        }
        try data.write(to: url, options: .atomic)
    }

    private static func uniqueFileURL(in dirURL: URL, preferredFilename: String) -> URL {
        let fm = FileManager.default
        let initial = dirURL.appendingPathComponent(preferredFilename)
        if !fm.fileExists(atPath: initial.path) {
            return initial
        }
        let stem = (preferredFilename as NSString).deletingPathExtension
        let ext = (preferredFilename as NSString).pathExtension
        for idx in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(idx)" : "\(stem) \(idx).\(ext)"
            let candidate = dirURL.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dirURL.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }
}
