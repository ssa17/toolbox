import CoreGraphics
import Foundation

enum TopEdgePanelSlotKind: Equatable, Hashable, Sendable {
    case template(DisplayPresetKind)
    case maximize

    var id: String {
        switch self {
        case .template(let preset):
            return "template:\(preset.rawValue)"
        case .maximize:
            return "universal:maximize"
        }
    }

    var label: String {
        switch self {
        case .template(let preset):
            return preset.label
        case .maximize:
            return "Maximize"
        }
    }

    var subtitleBadge: String {
        switch self {
        case .template(let preset):
            return preset.shortBadge
        case .maximize:
            return "Fill Screen"
        }
    }
}

struct TopEdgePanelSlotItem: Equatable, Identifiable, Sendable {
    /// 0...2 sit left of Maximize, 3 is Maximize, 4...6 sit right of Maximize.
    let slotIndex: Int
    let kind: TopEdgePanelSlotKind

    var id: String { "\(slotIndex):\(kind.id)" }
}

struct TopEdgePickerCellFrame: Equatable, Identifiable, Sendable {
    let cellIndex: Int
    let normalizedRect: NormalizedRect
    let frameAX: CGRect

    var id: Int { cellIndex }
}

struct TopEdgePickerSlotFrame: Equatable, Identifiable, Sendable {
    let item: TopEdgePanelSlotItem
    let frameAX: CGRect
    let cells: [TopEdgePickerCellFrame]

    var id: String { item.id }
}

struct TopEdgePickerHit: Equatable, Sendable {
    let slotKind: TopEdgePanelSlotKind
    let cellIndex: Int
}

struct TopEdgePickerLayout: Equatable, Sendable {
    let pickerFrameAX: CGRect
    let slots: [TopEdgePickerSlotFrame]
    let leftDividerX: CGFloat?
    let rightDividerX: CGFloat?

    var maximizeSlot: TopEdgePickerSlotFrame? {
        slots.first { $0.item.kind == .maximize }
    }
}

struct TopEdgeTemplateSnapContext: Equatable, Sendable {
    let template: DisplayPresetKind
    let allCells: [ResolvedZone]
    let snappedCellID: String
}

struct VisibleWindowFootprint: Equatable, Sendable {
    let windowNumber: Int
    let ownerPID: pid_t
    let boundsAX: CGRect
}

enum TopEdgePanelGeometry {
    static let templateSlotWidth: CGFloat = 104
    static let maximizeSlotWidth: CGFloat = 78
    static let minTemplateSlotWidth: CGFloat = 56
    static let minMaximizeSlotWidth: CGFloat = 46
    static let slotHeight: CGFloat = 62
    static let slotSpacing: CGFloat = 10
    static let dividerGap: CGFloat = 16
    static let padH: CGFloat = 14
    static let padV: CGFloat = 12
    static let pickerTopOffset: CGFloat = 10
    static let slotInnerPadding: CGFloat = 5
    static let miniCellGap: CGFloat = 1.75

    /// Produces the ordered visible slots (`0...2` left, `3` Maximize, `4...6` right), omitting `None` slots.
    static func visibleSlots(for config: TopEdgePanelConfig) -> [TopEdgePanelSlotItem] {
        let normalized = TopEdgePanelConfig.normalizedSlots(config.slots)
        var result: [TopEdgePanelSlotItem] = []

        for idx in 0..<3 {
            if let preset = normalized[idx] {
                result.append(TopEdgePanelSlotItem(slotIndex: idx, kind: .template(preset)))
            }
        }
        result.append(TopEdgePanelSlotItem(slotIndex: 3, kind: .maximize))
        for idx in 3..<TopEdgePanelConfig.slotCount {
            if let preset = normalized[idx] {
                result.append(TopEdgePanelSlotItem(slotIndex: idx + 1, kind: .template(preset)))
            }
        }
        return result
    }

    static func pickerLayout(
        for display: ConnectedDisplay,
        slots: [TopEdgePanelSlotItem]
    ) -> TopEdgePickerLayout {
        let leftItems = slots.filter { $0.slotIndex < 3 }
        let rightItems = slots.filter { $0.slotIndex > 3 }
        let maxItem = slots.first { $0.kind == .maximize } ?? TopEdgePanelSlotItem(slotIndex: 3, kind: .maximize)

        let leftInnerGaps = CGFloat(max(0, leftItems.count - 1)) * slotSpacing
        let rightInnerGaps = CGFloat(max(0, rightItems.count - 1)) * slotSpacing
        let dividerTotal: CGFloat = (leftItems.isEmpty ? 0 : dividerGap) + (rightItems.isEmpty ? 0 : dividerGap)
        let fixedWidth = padH * 2 + leftInnerGaps + rightInnerGaps + dividerTotal

        let maxRatio = maximizeSlotWidth / templateSlotWidth
        let templateCount = leftItems.count + rightItems.count
        let totalWeight = CGFloat(templateCount) + maxRatio

        let availableWidth = max(180, display.usableAX.width - 32)
        let widthForTotalPill = floor((availableWidth - fixedWidth) / max(0.5, totalWeight))

        let maxSideCount = max(leftItems.count, rightItems.count)
        let maxHalfFixed = padH + (maxSideCount > 0 ? dividerGap + CGFloat(max(0, maxSideCount - 1)) * slotSpacing : 0)
        let widthForSymmetricCenter = floor(((availableWidth / 2.0) - maxHalfFixed) / (CGFloat(maxSideCount) + 0.5 * maxRatio))

        let resolvedTemplateW = min(
            templateSlotWidth,
            max(minTemplateSlotWidth, min(widthForTotalPill, max(minTemplateSlotWidth, widthForSymmetricCenter)))
        )
        let resolvedMaximizeW = min(
            maximizeSlotWidth,
            max(minMaximizeSlotWidth, round(resolvedTemplateW * maxRatio))
        )

        let leftSpan = leftItems.isEmpty
            ? 0
            : CGFloat(leftItems.count) * resolvedTemplateW + leftInnerGaps + dividerGap
        let rightSpan = rightItems.isEmpty
            ? 0
            : dividerGap + CGFloat(rightItems.count) * resolvedTemplateW + rightInnerGaps
        let totalWidth = round(padH * 2 + leftSpan + resolvedMaximizeW + rightSpan)
        let totalHeight = round(padV * 2 + slotHeight)

        // Position Maximize's horizontal midpoint at usableAX.midX whenever display width allows.
        let maxCenterOffsetInPill = padH + leftSpan + resolvedMaximizeW / 2.0
        let desiredOriginX = round(display.usableAX.midX - maxCenterOffsetInPill)
        let minAllowedX = display.usableAX.minX + 16
        let maxAllowedX = max(minAllowedX, display.usableAX.maxX - totalWidth - 16)
        let originX = min(max(desiredOriginX, minAllowedX), maxAllowedX)
        let originY = round(display.usableAX.minY + pickerTopOffset)

        let pickerFrame = CGRect(x: originX, y: originY, width: totalWidth, height: totalHeight)
        let slotY = round(originY + padV)

        var cursorX = originX + padH
        var builtSlots: [TopEdgePickerSlotFrame] = []

        for (i, item) in leftItems.enumerated() {
            let rect = CGRect(x: round(cursorX), y: slotY, width: resolvedTemplateW, height: slotHeight)
            builtSlots.append(TopEdgePickerSlotFrame(
                item: item,
                frameAX: rect,
                cells: buildCells(for: item.kind, inSlotFrameAX: rect)
            ))
            cursorX += resolvedTemplateW
            if i < leftItems.count - 1 {
                cursorX += slotSpacing
            }
        }

        let leftDividerX: CGFloat?
        if !leftItems.isEmpty {
            leftDividerX = round(cursorX + dividerGap / 2.0)
            cursorX += dividerGap
        } else {
            leftDividerX = nil
        }

        let maxRect = CGRect(x: round(cursorX), y: slotY, width: resolvedMaximizeW, height: slotHeight)
        builtSlots.append(TopEdgePickerSlotFrame(
            item: maxItem,
            frameAX: maxRect,
            cells: buildCells(for: maxItem.kind, inSlotFrameAX: maxRect)
        ))
        cursorX += resolvedMaximizeW

        let rightDividerX: CGFloat?
        if !rightItems.isEmpty {
            rightDividerX = round(cursorX + dividerGap / 2.0)
            cursorX += dividerGap
        } else {
            rightDividerX = nil
        }

        for (i, item) in rightItems.enumerated() {
            let rect = CGRect(x: round(cursorX), y: slotY, width: resolvedTemplateW, height: slotHeight)
            builtSlots.append(TopEdgePickerSlotFrame(
                item: item,
                frameAX: rect,
                cells: buildCells(for: item.kind, inSlotFrameAX: rect)
            ))
            cursorX += resolvedTemplateW
            if i < rightItems.count - 1 {
                cursorX += slotSpacing
            }
        }

        return TopEdgePickerLayout(
            pickerFrameAX: pickerFrame,
            slots: builtSlots,
            leftDividerX: leftDividerX,
            rightDividerX: rightDividerX
        )
    }

    private static func buildCells(
        for kind: TopEdgePanelSlotKind,
        inSlotFrameAX slotRect: CGRect
    ) -> [TopEdgePickerCellFrame] {
        let inner = slotRect.insetBy(dx: slotInnerPadding, dy: slotInnerPadding)
        let innerW = max(8, inner.width)
        let innerH = max(8, inner.height)

        switch kind {
        case .maximize:
            return [TopEdgePickerCellFrame(cellIndex: 0, normalizedRect: .full, frameAX: inner)]

        case .template(let preset):
            return preset.templatePreviewRects.enumerated().map { idx, rawRect in
                let nr = rawRect.clamped
                let cellX = inner.minX + CGFloat(nr.x) * innerW + miniCellGap
                let cellY = inner.minY + CGFloat(nr.y) * innerH + miniCellGap
                let cellW = max(4, CGFloat(nr.width) * innerW - miniCellGap * 2)
                let cellH = max(4, CGFloat(nr.height) * innerH - miniCellGap * 2)
                return TopEdgePickerCellFrame(
                    cellIndex: idx,
                    normalizedRect: nr,
                    frameAX: CGRect(x: cellX, y: cellY, width: cellW, height: cellH)
                )
            }
        }
    }

    static func triggerZoneHorizontalBounds(
        for display: ConnectedDisplay,
        layout: TopEdgePickerLayout,
        cornerBandPoints: CGFloat,
        triggerWidth: TopEdgeTriggerWidth = .matchPanel
    ) -> (minX: CGFloat, maxX: CGFloat) {
        let centerX = layout.maximizeSlot?.frameAX.midX ?? display.usableAX.midX
        var minX: CGFloat
        var maxX: CGFloat

        switch triggerWidth {
        case .compact:
            let w = max(180, round(layout.pickerFrameAX.width * 0.45))
            minX = centerX - w / 2.0
            maxX = centerX + w / 2.0
        case .matchPanel:
            minX = layout.pickerFrameAX.minX - 24
            maxX = layout.pickerFrameAX.maxX + 24
        case .wide:
            let w = max(layout.pickerFrameAX.width + 160, round(display.usableAX.width * 0.80))
            minX = centerX - w / 2.0
            maxX = centerX + w / 2.0
        }

        let safeCornerLeft = display.usableAX.minX + cornerBandPoints
        let safeCornerRight = display.usableAX.maxX - cornerBandPoints
        if safeCornerRight - safeCornerLeft >= 96 {
            minX = max(minX, safeCornerLeft)
            maxX = min(maxX, safeCornerRight)
        }

        return (minX, maxX)
    }

    /// Returns the AX rectangle below the menu bar where dragging triggers the Top Edge Panel.
    static func triggerZoneRectAX(
        for display: ConnectedDisplay,
        layout: TopEdgePickerLayout,
        triggerDistancePoints: CGFloat,
        cornerBandPoints: CGFloat,
        triggerWidth: TopEdgeTriggerWidth = .matchPanel
    ) -> CGRect {
        let bounds = triggerZoneHorizontalBounds(
            for: display,
            layout: layout,
            cornerBandPoints: cornerBandPoints,
            triggerWidth: triggerWidth
        )
        return CGRect(
            x: bounds.minX,
            y: display.usableAX.minY,
            width: max(40, bounds.maxX - bounds.minX),
            height: max(4, triggerDistancePoints)
        )
    }

    static func isPointerInTriggerZone(
        pointerAX: CGPoint,
        display: ConnectedDisplay,
        layout: TopEdgePickerLayout,
        triggerDistancePoints: CGFloat,
        cornerBandPoints: CGFloat,
        triggerWidth: TopEdgeTriggerWidth = .matchPanel
    ) -> Bool {
        let triggerBand = max(2, triggerDistancePoints)
        let minY = display.frameAX.minY
        let maxY = display.usableAX.minY + triggerBand
        guard pointerAX.y >= minY && pointerAX.y <= maxY else {
            return false
        }

        let bounds = triggerZoneHorizontalBounds(
            for: display,
            layout: layout,
            cornerBandPoints: cornerBandPoints,
            triggerWidth: triggerWidth
        )
        return pointerAX.x >= bounds.minX && pointerAX.x <= bounds.maxX
    }

    static func isPointerInPickerKeepAliveZone(
        pointerAX: CGPoint,
        display: ConnectedDisplay,
        layout: TopEdgePickerLayout
    ) -> Bool {
        let keepAlive = CGRect(
            x: layout.pickerFrameAX.minX - 24,
            y: display.frameAX.minY,
            width: layout.pickerFrameAX.width + 48,
            height: (layout.pickerFrameAX.maxY + 20) - display.frameAX.minY
        )
        return keepAlive.contains(pointerAX)
    }

    /// Hit-tests directly against each slot's individual mini-cells inside the Top Edge Panel.
    static func hitTestPickerCell(
        pointerAX: CGPoint,
        in layout: TopEdgePickerLayout
    ) -> TopEdgePickerHit? {
        let matchedSlot = layout.slots.first(where: { $0.frameAX.contains(pointerAX) })
            ?? layout.slots.first(where: { $0.frameAX.insetBy(dx: -2, dy: -3).contains(pointerAX) })
        guard let slot = matchedSlot else { return nil }

        if slot.item.kind == .maximize {
            return TopEdgePickerHit(slotKind: .maximize, cellIndex: 0)
        }

        if let directCell = slot.cells.first(where: { $0.frameAX.contains(pointerAX) }) {
            return TopEdgePickerHit(slotKind: slot.item.kind, cellIndex: directCell.cellIndex)
        }

        if let nearestCell = slot.cells.min(by: { lhs, rhs in
            distance(from: pointerAX, to: lhs.frameAX) < distance(from: pointerAX, to: rhs.frameAX)
        }) {
            return TopEdgePickerHit(slotKind: slot.item.kind, cellIndex: nearestCell.cellIndex)
        }

        return TopEdgePickerHit(slotKind: slot.item.kind, cellIndex: 0)
    }

    // MARK: - Cell Occupancy Detection (Skip Already-Occupied Split Cells)

    static func occupyingWindowNumber(
        forCellAX cellAX: CGRect,
        visibleWindowsFrontToBack: [VisibleWindowFootprint],
        excludingWindowNumbers: Set<Int>
    ) -> Int? {
        let cellArea = max(1, cellAX.width * cellAX.height)

        for win in visibleWindowsFrontToBack {
            if excludingWindowNumbers.contains(win.windowNumber) {
                continue
            }

            let inter = cellAX.intersection(win.boundsAX)
            let interArea = inter.isNull ? 0 : (inter.width * inter.height)
            guard interArea > 0 else { continue }

            let winArea = max(1, win.boundsAX.width * win.boundsAX.height)
            let unionArea = max(1, cellArea + winArea - interArea)
            let iou = interArea / unionArea

            let alignedOrigin = abs(win.boundsAX.minX - cellAX.minX) <= 36
                && abs(win.boundsAX.minY - cellAX.minY) <= 36
            let alignedSize = abs(win.boundsAX.width - cellAX.width) <= 72
                && abs(win.boundsAX.height - cellAX.height) <= 72

            if iou >= 0.78 && alignedOrigin && alignedSize {
                return win.windowNumber
            }

            // A non-matching window visibly covering most of the cell hides whatever might be underneath.
            if (interArea / cellArea) >= 0.60 {
                return nil
            }
        }

        return nil
    }

    static func unoccupiedRemainingCells(
        allCells: [ResolvedZone],
        snappedCellID: String,
        snappedWindowNumber: Int?,
        visibleWindowsFrontToBack: [VisibleWindowFootprint]
    ) -> (unoccupiedCells: [ResolvedZone], occupiedWindowNumbers: Set<Int>) {
        var excluding: Set<Int> = []
        if let snappedWindowNumber {
            excluding.insert(snappedWindowNumber)
        }

        var unoccupied: [ResolvedZone] = []
        var occupiedWinNums: Set<Int> = []

        for cell in allCells where cell.id != snappedCellID {
            if let blockerWinNum = occupyingWindowNumber(
                forCellAX: cell.frameInAX,
                visibleWindowsFrontToBack: visibleWindowsFrontToBack,
                excludingWindowNumbers: excluding
            ) {
                occupiedWinNums.insert(blockerWinNum)
            } else {
                unoccupied.append(cell)
            }
        }

        return (unoccupiedCells: unoccupied, occupiedWindowNumbers: occupiedWinNums)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat = {
            if point.x < rect.minX { return rect.minX - point.x }
            if point.x > rect.maxX { return point.x - rect.maxX }
            return 0
        }()
        let dy: CGFloat = {
            if point.y < rect.minY { return rect.minY - point.y }
            if point.y > rect.maxY { return point.y - rect.maxY }
            return 0
        }()
        return hypot(dx, dy)
    }
}

// MARK: - App Card Candidates & Footprint-Scaled Layout (Pure)

struct AppCardCandidate: Equatable, Identifiable, Sendable {
    let id: String
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let windowNumber: Int?
    let windowFrameAX: CGRect
    let isMinimized: Bool
    let zOrderRank: Int

    init(
        id: String? = nil,
        pid: pid_t,
        bundleIdentifier: String,
        appName: String,
        windowTitle: String,
        windowNumber: Int?,
        windowFrameAX: CGRect,
        isMinimized: Bool,
        zOrderRank: Int
    ) {
        self.id = id ?? Self.makeID(pid: pid, windowNumber: windowNumber, title: windowTitle, frameAX: windowFrameAX)
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowNumber = windowNumber
        self.windowFrameAX = windowFrameAX
        self.isMinimized = isMinimized
        self.zOrderRank = zOrderRank
    }

    static func makeID(pid: pid_t, windowNumber: Int?, title: String, frameAX: CGRect) -> String {
        if let windowNumber {
            return "win:\(windowNumber)"
        }
        return "pid:\(pid):\(title):\(Int(round(frameAX.minX)))x\(Int(round(frameAX.minY)))x\(Int(round(frameAX.width)))x\(Int(round(frameAX.height)))"
    }

    var footprintArea: CGFloat {
        max(1, windowFrameAX.width) * max(1, windowFrameAX.height)
    }
}

struct AppCardLayoutItem: Equatable, Identifiable, Sendable {
    var id: String { candidate.id }
    let candidate: AppCardCandidate
    let size: CGSize

    var area: CGFloat {
        size.width * size.height
    }
}

struct AppCardLayoutRow: Equatable, Identifiable, Sendable {
    let id: Int
    let items: [AppCardLayoutItem]
}

enum AppCardLayoutEngine {
    /// Filters out Toolbox/ignored apps and already-snapped windows while keeping distinct windows of the same app.
    static func dedupeAndFilterCandidates(
        _ raw: [AppCardCandidate],
        excludingPIDs: Set<pid_t>,
        excludingWindowNumbers: Set<Int> = [],
        excludingCandidateIDs: Set<String> = [],
        ignoredBundleIDs: Set<String> = []
    ) -> [AppCardCandidate] {
        let loweredIgnored = Set(ignoredBundleIDs.map { $0.lowercased() })
        var bestByKey: [String: AppCardCandidate] = [:]

        for candidate in raw {
            guard !excludingPIDs.contains(candidate.pid) else { continue }
            if let winNum = candidate.windowNumber, excludingWindowNumbers.contains(winNum) {
                continue
            }
            if excludingCandidateIDs.contains(candidate.id) {
                continue
            }
            let lowerBundle = candidate.bundleIdentifier.lowercased()
            if !lowerBundle.isEmpty && loweredIgnored.contains(lowerBundle) {
                continue
            }

            let dedupeKey = candidate.windowNumber.map { "win:\($0)" } ?? candidate.id
            if let existing = bestByKey[dedupeKey] {
                if isPreferred(candidate, over: existing) {
                    bestByKey[dedupeKey] = candidate
                }
            } else {
                bestByKey[dedupeKey] = candidate
            }
        }

        return bestByKey.values.sorted { lhs, rhs in
            if lhs.footprintArea != rhs.footprintArea {
                return lhs.footprintArea > rhs.footprintArea
            }
            if lhs.zOrderRank != rhs.zOrderRank {
                return lhs.zOrderRank < rhs.zOrderRank
            }
            let appCmp = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if appCmp != .orderedSame {
                return appCmp == .orderedAscending
            }
            return lhs.windowTitle.localizedCaseInsensitiveCompare(rhs.windowTitle) == .orderedAscending
        }
    }

    private static func isPreferred(_ candidate: AppCardCandidate, over existing: AppCardCandidate) -> Bool {
        if candidate.isMinimized != existing.isMinimized {
            return !candidate.isMinimized
        }
        if candidate.footprintArea != existing.footprintArea {
            return candidate.footprintArea > existing.footprintArea
        }
        return candidate.zOrderRank < existing.zOrderRank
    }

    static func cardSizes(
        for candidates: [AppCardCandidate],
        in paneContentSize: CGSize
    ) -> [AppCardLayoutItem] {
        guard !candidates.isEmpty else { return [] }

        let usableW = max(120, paneContentSize.width)
        let usableH = max(100, paneContentSize.height)

        let maxCardW = min(260, max(108, floor(usableW * (candidates.count <= 2 ? 0.68 : 0.48))))
        let minCardW = min(maxCardW, max(96, min(132, floor(usableW * 0.26))))
        let maxCardH = min(176, max(78, floor(usableH * (candidates.count <= 2 ? 0.50 : 0.38))))
        let minCardH = min(maxCardH, max(70, min(94, floor(usableH * 0.20))))

        let maxLinear = max(1, candidates.map { sqrt($0.footprintArea) }.max() ?? 1)

        var items: [AppCardLayoutItem] = []
        items.reserveCapacity(candidates.count)

        for candidate in candidates {
            let linearRatio = sqrt(candidate.footprintArea) / maxLinear
            let t: CGFloat
            if candidates.count == 1 {
                t = 0.85
            } else {
                t = min(max((linearRatio - 0.30) / 0.70, 0.0), 1.0)
            }

            let rawW = minCardW + (maxCardW - minCardW) * t
            let rawH = minCardH + (maxCardH - minCardH) * t

            let naturalAspect = min(max(candidate.windowFrameAX.width / max(1, candidate.windowFrameAX.height), 0.90), 1.65)
            let aspectFactor = max(0.80, 1.0 + (naturalAspect - 1.25) * 0.14)
            let aspectScale = sqrt(aspectFactor)
            let adjustedW = min(usableW, round(min(max(rawW * aspectScale, minCardW), maxCardW)))
            let adjustedH = round(min(max(rawH / aspectScale, minCardH), maxCardH))

            items.append(AppCardLayoutItem(
                candidate: candidate,
                size: CGSize(width: adjustedW, height: adjustedH)
            ))
        }

        return items
    }

    static func layoutRows(
        for candidates: [AppCardCandidate],
        in paneContentSize: CGSize,
        spacing: CGFloat = 12
    ) -> [AppCardLayoutRow] {
        let sized = cardSizes(for: candidates, in: paneContentSize)
        guard !sized.isEmpty else { return [] }

        let maxRowWidth = max(120, paneContentSize.width)
        var rows: [AppCardLayoutRow] = []
        var currentRow: [AppCardLayoutItem] = []
        var currentWidth: CGFloat = 0

        for item in sized {
            let nextWidth = currentRow.isEmpty
                ? item.size.width
                : (currentWidth + spacing + item.size.width)
            if !currentRow.isEmpty && nextWidth > maxRowWidth {
                rows.append(AppCardLayoutRow(id: rows.count, items: currentRow))
                currentRow = [item]
                currentWidth = item.size.width
            } else {
                currentRow.append(item)
                currentWidth = nextWidth
            }
        }
        if !currentRow.isEmpty {
            rows.append(AppCardLayoutRow(id: rows.count, items: currentRow))
        }
        return rows
    }
}
