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

    /// Renders `baseImage` with all `annotations`, optional `cropRect`, and optional `beautify` frame
    /// into a new full-resolution `CGImage`. All redactions are irreversibly flattened into the pixels.
    static func render(
        baseImage: CGImage,
        annotations: [AnnotationItem],
        cropRect: CGRect? = nil,
        beautify: BeautifyConfig? = nil
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

        // 1. Draw redactions first against the base screenshot.
        for item in annotations where item.kind == .redact {
            drawRedaction(item, in: ctx, canvasSize: canvasSize)
        }

        // 2. Spotlight dimming scrim across the screenshot, punching out spotlight shapes via even-odd fill.
        let spotlightItems = annotations.filter {
            ($0.kind == .rectangle || $0.kind == .ellipse) && $0.fillStyle == .spotlight
        }
        if !spotlightItems.isEmpty {
            drawSpotlightScrim(items: spotlightItems, in: ctx, canvasSize: canvasSize)
        }

        // 3. Draw non-redact annotations in z-order.
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
        let cropped: CGImage
        if let cropRect {
            let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
            let clamped = cropRect.standardized.integral.intersection(imageBounds)
            if !clamped.isNull, clamped.width >= 1, clamped.height >= 1 {
                cropped = full.cropping(to: clamped) ?? full
            } else {
                cropped = full
            }
        } else {
            cropped = full
        }

        if let beautify, beautify.enabled, beautify.backdrop != .none {
            return applyBeautify(to: cropped, config: beautify) ?? cropped
        }
        return cropped
    }

    /// Pre-bakes `.blur`, `.pixelate`, and `.smartErase` redaction items into the base image for smooth interactive canvas rendering.
    static func renderBaseWithFilteredRedactions(
        baseImage: CGImage,
        annotations: [AnnotationItem]
    ) -> CGImage? {
        let filteredItems = annotations.filter { $0.kind == .redact && $0.redactStyle != .solidBlack }
        guard !filteredItems.isEmpty else { return baseImage }
        return render(baseImage: baseImage, annotations: filteredItems, cropRect: nil, beautify: nil)
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
            ctx.setFillColor(item.redactSolidColor.cgColor)
            ctx.fill(cgTarget)
            ctx.restoreGState()

        case .blur:
            let minBoxDim = min(cgTarget.width, cgTarget.height)
            let blurRadius: CGFloat
            switch item.redactStrength {
            case .light: blurRadius = max(6.0, min(14.0, minBoxDim * 0.18))
            case .medium: blurRadius = max(11.0, min(26.0, minBoxDim * 0.28))
            case .strong: blurRadius = max(18.0, min(42.0, minBoxDim * 0.42))
            }
            drawFilteredRegion(in: ctx, cgTarget: cgTarget, fallbackBlockSize: max(6, Int(blurRadius * 0.55))) { clampedSource in
                clampedSource.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: blurRadius
                ])
            }

        case .pixelate:
            let minBoxDim = min(cgTarget.width, cgTarget.height)
            let blockScale: CGFloat
            switch item.redactStrength {
            case .light: blockScale = max(5.0, min(10.0, minBoxDim * 0.11))
            case .medium: blockScale = max(8.0, min(16.0, minBoxDim * 0.18))
            case .strong: blockScale = max(14.0, min(28.0, minBoxDim * 0.28))
            }
            drawFilteredRegion(in: ctx, cgTarget: cgTarget, fallbackBlockSize: max(5, Int(blockScale.rounded()))) { clampedSource in
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

        case .smartErase:
            let fillColor: CGColor
            if let snapshot = ctx.makeImage() {
                fillColor = sampleBorderFillColor(from: snapshot, topLeftTarget: item.rect, canvasSize: canvasSize)
            } else {
                fillColor = CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
            }
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.setFillColor(fillColor)
            ctx.fill(cgTarget)
            ctx.restoreGState()
        }
    }

    private static func sampleBorderFillColor(
        from snapshot: CGImage,
        topLeftTarget: CGRect,
        canvasSize: CGSize
    ) -> CGColor {
        let imageBounds = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        let inner = topLeftTarget.standardized.integral.intersection(imageBounds)
        let band: CGFloat = 3
        let outer = inner.insetBy(dx: -band, dy: -band).integral.intersection(imageBounds)
        guard !outer.isNull, outer.width >= 1, outer.height >= 1,
              let cropped = snapshot.cropping(to: outer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let sampleCtx = CGContext(
                data: nil,
                width: Int(outer.width),
                height: Int(outer.height),
                bitsPerComponent: 8,
                bytesPerRow: Int(outer.width) * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
        }

        let w = Int(outer.width)
        let h = Int(outer.height)
        sampleCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = sampleCtx.data?.assumingMemoryBound(to: UInt8.self) else {
            return CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
        }

        let relMinX = Int(inner.minX - outer.minX)
        let relMaxX = Int(inner.maxX - outer.minX)
        let relMinY = Int(inner.minY - outer.minY)
        let relMaxY = Int(inner.maxY - outer.minY)

        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []
        reds.reserveCapacity(w * 6 + h * 6)
        greens.reserveCapacity(w * 6 + h * 6)
        blues.reserveCapacity(w * 6 + h * 6)

        for py in 0..<h {
            for px in 0..<w {
                let insideTarget = (px >= relMinX && px < relMaxX && py >= relMinY && py < relMaxY)
                if insideTarget { continue }
                let idx = (py * w + px) * 4
                let a = ptr[idx + 3]
                if a < 128 { continue }
                reds.append(ptr[idx])
                greens.append(ptr[idx + 1])
                blues.append(ptr[idx + 2])
            }
        }

        guard !reds.isEmpty else {
            return CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
        }

        reds.sort()
        greens.sort()
        blues.sort()
        let mid = reds.count / 2
        return CGColor(
            srgbRed: CGFloat(reds[mid]) / 255.0,
            green: CGFloat(greens[mid]) / 255.0,
            blue: CGFloat(blues[mid]) / 255.0,
            alpha: 1.0
        )
    }

    private static func drawSpotlightScrim(
        items: [AnnotationItem],
        in ctx: CGContext,
        canvasSize: CGSize
    ) {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: canvasSize))
        for item in items {
            let target = cgRect(fromTopLeft: item.rect, canvasHeight: canvasSize.height)
            guard target.width >= 1, target.height >= 1 else { continue }
            if item.kind == .ellipse {
                path.addEllipse(in: target)
            } else {
                let r = min(item.cornerRadius.radiusValue, min(target.width, target.height) / 2)
                path.addRoundedRect(in: target, cornerWidth: r, cornerHeight: r)
            }
        }
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.56))
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
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
        let alpha = item.highlighterOpacity.alpha
        if item.highlighterMode == .box {
            let target = cgRect(fromTopLeft: item.rect, canvasHeight: canvasHeight)
            guard target.width >= 1, target.height >= 1 else { return }
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            let fillColor = item.color.cgColor.copy(alpha: alpha) ?? item.color.cgColor
            ctx.setFillColor(fillColor)
            let r = min(4.0, min(target.width, target.height) / 2)
            let path = CGPath(roundedRect: target, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
            return
        }

        guard !item.points.isEmpty else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let strokeColor = item.color.cgColor.copy(alpha: alpha) ?? item.color.cgColor
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

    private static func applyStrokeDash(for item: AnnotationItem, in ctx: CGContext) {
        if item.dashStyle == .dashed {
            ctx.setLineDash(phase: 0, lengths: [max(6, item.strokeWidth * 2.4), max(4, item.strokeWidth * 1.6)])
        }
    }

    private static func drawShapePath(_ path: CGPath, item: AnnotationItem, in ctx: CGContext) {
        ctx.saveGState()
        switch item.fillStyle {
        case .outline, .spotlight:
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setLineWidth(item.strokeWidth)
            ctx.setLineJoin(.round)
            applyStrokeDash(for: item, in: ctx)
            ctx.addPath(path)
            ctx.strokePath()
        case .tinted:
            let fill = item.color.cgColor.copy(alpha: 0.18) ?? item.color.cgColor
            ctx.setFillColor(fill)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setLineWidth(item.strokeWidth)
            ctx.setLineJoin(.round)
            applyStrokeDash(for: item, in: ctx)
            ctx.addPath(path)
            ctx.strokePath()
        case .solid:
            ctx.setFillColor(item.color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func drawRectangle(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let target = cgRect(fromTopLeft: item.rect, canvasHeight: canvasHeight)
        guard target.width >= 1, target.height >= 1 else { return }
        let radius = min(item.cornerRadius.radiusValue, min(target.width, target.height) / 2)
        let path = CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)
        drawShapePath(path, item: item, in: ctx)
    }

    private static func drawEllipse(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let target = cgRect(fromTopLeft: item.rect, canvasHeight: canvasHeight)
        guard target.width >= 1, target.height >= 1 else { return }
        let path = CGPath(ellipseIn: target, transform: nil)
        drawShapePath(path, item: item, in: ctx)
    }

    private static func drawArrow(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let start = cgPoint(fromTopLeft: item.startPoint, canvasHeight: canvasHeight)
        let end = cgPoint(fromTopLeft: item.endPoint, canvasHeight: canvasHeight)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 2 else { return }

        let angle = atan2(dy, dx)
        let headLength = max(14, item.strokeWidth * 4.0)
        let headAngle: CGFloat = .pi / 6.5

        ctx.saveGState()
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        ctx.setLineWidth(item.strokeWidth)
        ctx.setLineCap(.round)

        switch item.arrowStyle {
        case .line:
            applyStrokeDash(for: item, in: ctx)
            ctx.beginPath()
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()

        case .standard:
            let shaftEnd = CGPoint(
                x: end.x - cos(angle) * (headLength * 0.65),
                y: end.y - sin(angle) * (headLength * 0.65)
            )
            applyStrokeDash(for: item, in: ctx)
            ctx.beginPath()
            ctx.move(to: start)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()

            ctx.setLineDash(phase: 0, lengths: [])
            drawArrowHead(tip: end, angle: angle, headLength: headLength, headAngle: headAngle, in: ctx)

        case .doubleHeaded:
            let trim = min(length * 0.35, headLength * 0.65)
            let shaftStart = CGPoint(x: start.x + cos(angle) * trim, y: start.y + sin(angle) * trim)
            let shaftEnd = CGPoint(x: end.x - cos(angle) * trim, y: end.y - sin(angle) * trim)
            applyStrokeDash(for: item, in: ctx)
            ctx.beginPath()
            ctx.move(to: shaftStart)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()

            ctx.setLineDash(phase: 0, lengths: [])
            drawArrowHead(tip: end, angle: angle, headLength: headLength, headAngle: headAngle, in: ctx)
            drawArrowHead(tip: start, angle: angle + .pi, headLength: headLength, headAngle: headAngle, in: ctx)

        case .tapered:
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            let perpX = -sin(angle)
            let perpY = cos(angle)
            let tailHalf = max(1.1, item.strokeWidth * 0.32)
            let neckHalf = max(2.4, item.strokeWidth * 0.92)
            let neckDist = min(length * 0.8, headLength * 0.72)
            let neckCenter = CGPoint(x: end.x - cos(angle) * neckDist, y: end.y - sin(angle) * neckDist)
            let wingDist = min(length * 0.95, headLength * 1.08)
            let wingHalf = max(headLength * 0.52, neckHalf * 2.1)
            let wingCenter = CGPoint(x: end.x - cos(angle) * wingDist, y: end.y - sin(angle) * wingDist)

            ctx.beginPath()
            ctx.move(to: CGPoint(x: start.x + perpX * tailHalf, y: start.y + perpY * tailHalf))
            ctx.addLine(to: CGPoint(x: neckCenter.x + perpX * neckHalf, y: neckCenter.y + perpY * neckHalf))
            ctx.addLine(to: CGPoint(x: wingCenter.x + perpX * wingHalf, y: wingCenter.y + perpY * wingHalf))
            ctx.addLine(to: end)
            ctx.addLine(to: CGPoint(x: wingCenter.x - perpX * wingHalf, y: wingCenter.y - perpY * wingHalf))
            ctx.addLine(to: CGPoint(x: neckCenter.x - perpX * neckHalf, y: neckCenter.y - perpY * neckHalf))
            ctx.addLine(to: CGPoint(x: start.x - perpX * tailHalf, y: start.y - perpY * tailHalf))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func drawArrowHead(
        tip: CGPoint,
        angle: CGFloat,
        headLength: CGFloat,
        headAngle: CGFloat,
        in ctx: CGContext
    ) {
        let leftWing = CGPoint(
            x: tip.x - cos(angle - headAngle) * headLength,
            y: tip.y - sin(angle - headAngle) * headLength
        )
        let rightWing = CGPoint(
            x: tip.x - cos(angle + headAngle) * headLength,
            y: tip.y - sin(angle + headAngle) * headLength
        )
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: leftWing)
        ctx.addLine(to: rightWing)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawStepBadge(_ item: AnnotationItem, in ctx: CGContext, canvasHeight: CGFloat) {
        let center = cgPoint(fromTopLeft: item.startPoint, canvasHeight: canvasHeight)
        let radius = item.effectiveStepRadius
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        switch item.stepStyle {
        case .filled:
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
            ctx.setFillColor(item.color.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.restoreGState()

            ctx.saveGState()
            let rimColor = item.color == .white
                ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
            ctx.setStrokeColor(rimColor)
            ctx.setLineWidth(max(2, radius * 0.11))
            ctx.strokeEllipse(in: circleRect)
            ctx.restoreGState()

            let textColor: NSColor = item.color == .white || item.color == .yellow ? .black : .white
            drawStepNumberText(item.stepNumber, center: center, radius: radius, textColor: textColor, in: ctx)

        case .outlined:
            let bgColor = (item.color == .white || item.color == .yellow)
                ? CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.92)
                : CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.40))
            ctx.setFillColor(bgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setLineWidth(max(2.5, radius * 0.16))
            ctx.strokeEllipse(in: circleRect)
            ctx.restoreGState()

            drawStepNumberText(item.stepNumber, center: center, radius: radius, textColor: item.color.nsColor, in: ctx)
        }
    }

    private static func drawStepNumberText(
        _ number: Int,
        center: CGPoint,
        radius: CGFloat,
        textColor: NSColor,
        in ctx: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: radius * 1.05, weight: .bold)
        let label = "\(number)" as NSString
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
        let layout = item.textLayout()
        guard !layout.content.isEmpty else { return }

        let foregroundColor: NSColor
        if item.textBackgroundStyle == .filled {
            foregroundColor = (item.color == .white || item.color == .yellow) ? .black : .white
        } else {
            foregroundColor = item.color.nsColor
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        var attrs: [NSAttributedString.Key: Any] = [
            .font: layout.font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph
        ]
        if item.textBackgroundStyle == .plain {
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.shadowBlurRadius = 4
            shadow.shadowColor = (item.color == .black)
                ? NSColor.white.withAlphaComponent(0.85)
                : NSColor.black.withAlphaComponent(0.85)
            attrs[.shadow] = shadow
        }

        let nsText = layout.content as NSString
        let cgPill = cgRect(fromTopLeft: layout.pillRect, canvasHeight: canvasHeight)
        let corner = item.textCornerRadius.resolvedRadius(forHeight: cgPill.height)

        switch item.textBackgroundStyle {
        case .pill:
            let backdropColor: CGColor = item.color == .black
                ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
                : CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.86)
            ctx.saveGState()
            ctx.setFillColor(backdropColor)
            let pillPath = CGPath(roundedRect: cgPill, cornerWidth: corner, cornerHeight: corner, transform: nil)
            ctx.addPath(pillPath)
            ctx.fillPath()
            ctx.setStrokeColor(item.color.cgColor.copy(alpha: 0.55) ?? item.color.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(pillPath)
            ctx.strokePath()
            ctx.restoreGState()
        case .filled:
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.setFillColor(item.color.cgColor)
            let pillPath = CGPath(roundedRect: cgPill, cornerWidth: corner, cornerHeight: corner, transform: nil)
            ctx.addPath(pillPath)
            ctx.fillPath()
            ctx.restoreGState()

            if item.color == .black {
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20))
                ctx.setLineWidth(1.2)
                ctx.addPath(pillPath)
                ctx.strokePath()
                ctx.restoreGState()
            }
        case .plain:
            break
        }

        drawWithAppKit(in: ctx) {
            nsText.draw(
                in: NSRect(
                    x: cgPill.midX - layout.textSize.width / 2,
                    y: cgPill.midY - layout.textSize.height / 2,
                    width: layout.textSize.width,
                    height: layout.textSize.height
                ),
                withAttributes: attrs
            )
        }
    }

    private static func applyBeautify(to image: CGImage, config: BeautifyConfig) -> CGImage? {
        let pad = max(0, Int(config.padding.rounded()))
        let outW = image.width + pad * 2
        let outH = image.height + pad * 2
        guard outW > 0, outH > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let stops = config.backdrop.gradientRGBStops
        let startCG = CGColor(srgbRed: stops.start.0, green: stops.start.1, blue: stops.start.2, alpha: 1.0)
        let endCG = CGColor(srgbRed: stops.end.0, green: stops.end.1, blue: stops.end.2, alpha: 1.0)
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [startCG, endCG] as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(outH)),
                end: CGPoint(x: CGFloat(outW), y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            ctx.setFillColor(startCG)
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        }

        let cardRect = CGRect(x: pad, y: pad, width: image.width, height: image.height)
        let radius = min(config.cornerRadius, min(cardRect.width, cardRect.height) / 2)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if config.shadowEnabled {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -12),
                blur: 32,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.48)
            )
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0))
            ctx.addPath(cardPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: cardRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(1.5)
        ctx.addPath(cardPath)
        ctx.strokePath()
        ctx.restoreGState()

        return ctx.makeImage()
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
