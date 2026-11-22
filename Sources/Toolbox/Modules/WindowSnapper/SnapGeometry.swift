import AppKit
import CoreGraphics
import Foundation

extension DragModifierChoice {
    func matches(cgFlags: CGEventFlags) -> Bool {
        switch self {
        case .none:
            return false
        case .shift:
            return cgFlags.contains(.maskShift)
        case .option:
            return cgFlags.contains(.maskAlternate)
        case .controlOption:
            return cgFlags.contains(.maskControl) && cgFlags.contains(.maskAlternate)
        case .optionCommand:
            return cgFlags.contains(.maskAlternate) && cgFlags.contains(.maskCommand)
        }
    }

    func matches(nsFlags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .none:
            return false
        case .shift:
            return nsFlags.contains(.shift)
        case .option:
            return nsFlags.contains(.option)
        case .controlOption:
            return nsFlags.contains(.control) && nsFlags.contains(.option)
        case .optionCommand:
            return nsFlags.contains(.option) && nsFlags.contains(.command)
        }
    }
}

struct SafeAreaInsets: Equatable, Sendable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = max(0, top)
        self.left = max(0, left)
        self.bottom = max(0, bottom)
        self.right = max(0, right)
    }

    @MainActor
    init(nsEdgeInsets: NSEdgeInsets) {
        self.init(
            top: nsEdgeInsets.top,
            left: nsEdgeInsets.left,
            bottom: nsEdgeInsets.bottom,
            right: nsEdgeInsets.right
        )
    }
}

struct ZoneMinSizeWarning: Equatable, Sendable {
    let minSize: CGSize
    let clampedFrameAX: CGRect
    let exceedsWidth: Bool
    let exceedsHeight: Bool

    var badgeText: String {
        let minW = Int(round(minSize.width))
        let minH = Int(round(minSize.height))
        if exceedsWidth && exceedsHeight {
            return "App min size \(minW)×\(minH) · won't shrink smaller"
        } else if exceedsWidth {
            return "App min width \(minW) pt · won't shrink narrower"
        } else {
            return "App min height \(minH) pt · won't shrink shorter"
        }
    }
}

enum StageManagerStripEdge: String, Equatable, Sendable {
    case left
    case right
}

struct SequoiaTilingConflictStatus: Equatable, Sendable {
    let isEdgeDragTilingEnabled: Bool
    let isTopEdgeTilingEnabled: Bool
    let isOptionKeyTilingEnabled: Bool

    var hasConflictWithToolboxDrag: Bool {
        isEdgeDragTilingEnabled || isTopEdgeTilingEnabled || isOptionKeyTilingEnabled
    }

    var activeSettingLabels: [String] {
        var labels: [String] = []
        if isEdgeDragTilingEnabled {
            labels.append("Drag windows to left or right edge of screen to tile")
        }
        if isTopEdgeTilingEnabled {
            labels.append("Drag windows to menu bar to fill screen")
        }
        if isOptionKeyTilingEnabled {
            labels.append("Hold ⌥ key while dragging windows to tile")
        }
        return labels
    }
}

struct GridCellCoord: Equatable, Hashable, Sendable {
    let col: Int
    let row: Int
}

struct GridSpan: Codable, Equatable, Hashable, Sendable {
    var startCol: Int
    var endCol: Int
    var startRow: Int
    var endRow: Int

    var normalized: GridSpan {
        GridSpan(
            startCol: min(startCol, endCol),
            endCol: max(startCol, endCol),
            startRow: min(startRow, endRow),
            endRow: max(startRow, endRow)
        )
    }

    var zoneID: String {
        let s = normalized
        if s.startCol == s.endCol && s.startRow == s.endRow {
            return "cell:\(s.startCol):\(s.startRow)"
        }
        return "span:\(s.startCol):\(s.endCol):\(s.startRow):\(s.endRow)"
    }

    static func parse(zoneID: String) -> GridSpan? {
        let parts = zoneID.split(separator: ":")
        if parts.count == 3, parts[0] == "cell",
           let col = Int(parts[1]), let row = Int(parts[2]) {
            return GridSpan(startCol: col, endCol: col, startRow: row, endRow: row)
        }
        if parts.count == 5, parts[0] == "span",
           let sc = Int(parts[1]), let ec = Int(parts[2]),
           let sr = Int(parts[3]), let er = Int(parts[4]) {
            return GridSpan(startCol: sc, endCol: ec, startRow: sr, endRow: er).normalized
        }
        return nil
    }
}

struct ResolvedZone: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let badgeNumber: Int
    let normalizedRect: NormalizedRect
    let frameInAX: CGRect
    let frameInAppKit: CGRect
    let gridCoord: GridCellCoord?
    let shortcut: ShortcutSpec
}

enum SnapDirectionAction: String, Equatable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf

    var baseTitle: String {
        switch self {
        case .leftHalf: return "Left"
        case .rightHalf: return "Right"
        case .topHalf: return "Top"
        case .bottomHalf: return "Bottom"
        }
    }

    func fractionName(for stepIndex: Int) -> String {
        switch stepIndex % 3 {
        case 1: return "\(baseTitle) Two-Thirds"
        case 2: return "\(baseTitle) Third"
        default: return "\(baseTitle) Half"
        }
    }

    func normalizedRect(forStep stepIndex: Int) -> NormalizedRect {
        let fraction: Double = {
            switch stepIndex % 3 {
            case 1: return 2.0 / 3.0
            case 2: return 1.0 / 3.0
            default: return 0.5
            }
        }()
        switch self {
        case .leftHalf:
            return NormalizedRect(x: 0.0, y: 0.0, width: fraction, height: 1.0)
        case .rightHalf:
            return NormalizedRect(x: 1.0 - fraction, y: 0.0, width: fraction, height: 1.0)
        case .topHalf:
            return NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: fraction)
        case .bottomHalf:
            return NormalizedRect(x: 0.0, y: 1.0 - fraction, width: 1.0, height: fraction)
        }
    }
}

struct DragZoneHit: Equatable, Sendable {
    let zone: ResolvedZone
    let isSpanning: Bool
}

enum SnapGeometry {
    static let seamSpanProximityPoints: CGFloat = 12

    // MARK: - Coordinate Conversion (Primary Screen Height Invariant)

    static func appKitToAX(_ appKitRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: appKitRect.origin.x,
            y: primaryScreenHeight - (appKitRect.origin.y + appKitRect.height),
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    static func axToAppKit(_ axRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: primaryScreenHeight - (axRect.origin.y + axRect.height),
            width: axRect.width,
            height: axRect.height
        )
    }

    static func appKitPointToAX(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func axPointToAppKit(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    // MARK: - Animation Interpolation

    static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        let inv = 1 - clamped
        return 1 - inv * inv * inv
    }

    static func interpolatedRect(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        let p = easeOutCubic(progress)
        return CGRect(
            x: round(start.origin.x + (end.origin.x - start.origin.x) * p),
            y: round(start.origin.y + (end.origin.y - start.origin.y) * p),
            width: max(40, round(start.width + (end.width - start.width) * p)),
            height: max(40, round(start.height + (end.height - start.height) * p))
        )
    }

    static func interpolatedSize(from start: CGSize, to end: CGSize, progress: CGFloat) -> CGSize {
        let p = easeOutCubic(progress)
        return CGSize(
            width: max(40, round(start.width + (end.width - start.width) * p)),
            height: max(40, round(start.height + (end.height - start.height) * p))
        )
    }

    // MARK: - Usable Display Rect (Menu Bar, Dock, Notch & Stage Manager)

    static func isStageManagerStripVisible(windowManagerDefaults: [String: Any]?) -> Bool {
        guard let windowManagerDefaults else { return false }
        let globallyEnabled = (windowManagerDefaults["GloballyEnabled"] as? Bool) ?? false
        let autoHide = (windowManagerDefaults["AutoHide"] as? Bool) ?? false
        return globallyEnabled && !autoHide
    }

    static func stageManagerStripEdge(dockDefaults: [String: Any]?) -> StageManagerStripEdge {
        let orientation = (dockDefaults?["orientation"] as? String)?.lowercased()
        return orientation == "left" ? .right : .left
    }

    static func currentStageManagerState() -> (stripVisible: Bool, edge: StageManagerStripEdge) {
        let wmDefaults = UserDefaults(suiteName: "com.apple.WindowManager")?.dictionaryRepresentation()
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")?.dictionaryRepresentation()
        return (
            isStageManagerStripVisible(windowManagerDefaults: wmDefaults),
            stageManagerStripEdge(dockDefaults: dockDefaults)
        )
    }

    private static func defaultsBool(_ dict: [String: Any]?, key: String, defaultValue: Bool) -> Bool {
        guard let raw = dict?[key] else { return defaultValue }
        if let boolVal = raw as? Bool { return boolVal }
        if let numVal = raw as? NSNumber { return numVal.boolValue }
        return defaultValue
    }

    static func evaluateSequoiaTilingConflict(
        windowManagerDefaults: [String: Any]?,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> SequoiaTilingConflictStatus {
        guard macOSMajorVersion >= 15 else {
            return SequoiaTilingConflictStatus(
                isEdgeDragTilingEnabled: false,
                isTopEdgeTilingEnabled: false,
                isOptionKeyTilingEnabled: false
            )
        }
        let edgeDrag = defaultsBool(windowManagerDefaults, key: "EnableTilingByEdgeDrag", defaultValue: true)
        let topEdgeDrag = defaultsBool(windowManagerDefaults, key: "EnableTopTilingByEdgeDrag", defaultValue: true)
        let optionAccelerator = defaultsBool(windowManagerDefaults, key: "EnableTilingOptionAccelerator", defaultValue: true)
        return SequoiaTilingConflictStatus(
            isEdgeDragTilingEnabled: edgeDrag,
            isTopEdgeTilingEnabled: topEdgeDrag,
            isOptionKeyTilingEnabled: optionAccelerator
        )
    }

    static func currentSequoiaTilingConflict() -> SequoiaTilingConflictStatus {
        let appID = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(appID)
        var snapshot: [String: Any] = [:]
        for key in ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"] {
            if let val = CFPreferencesCopyAppValue(key as CFString, appID) {
                snapshot[key] = val
            }
        }
        if snapshot.isEmpty,
           let fallback = UserDefaults(suiteName: "com.apple.WindowManager")?.dictionaryRepresentation() {
            return evaluateSequoiaTilingConflict(windowManagerDefaults: fallback)
        }
        return evaluateSequoiaTilingConflict(windowManagerDefaults: snapshot)
    }

    static func usableAppKitRect(
        screenFrame: CGRect? = nil,
        visibleFrame: CGRect,
        safeAreaInsets: SafeAreaInsets = SafeAreaInsets(),
        stageManagerActive: Bool = false,
        stageManagerEdge: StageManagerStripEdge = .left,
        stageManagerReservePoints: CGFloat = 78
    ) -> CGRect {
        var rect: CGRect
        if let frame = screenFrame {
            let hardwareSafe = CGRect(
                x: frame.minX + safeAreaInsets.left,
                y: frame.minY + safeAreaInsets.bottom,
                width: max(0, frame.width - safeAreaInsets.left - safeAreaInsets.right),
                height: max(0, frame.height - safeAreaInsets.top - safeAreaInsets.bottom)
            )
            let intersected = visibleFrame.intersection(hardwareSafe)
            rect = intersected.isNull ? visibleFrame : intersected
        } else {
            rect = CGRect(
                x: visibleFrame.minX + safeAreaInsets.left,
                y: visibleFrame.minY + safeAreaInsets.bottom,
                width: max(0, visibleFrame.width - safeAreaInsets.left - safeAreaInsets.right),
                height: max(0, visibleFrame.height - safeAreaInsets.top - safeAreaInsets.bottom)
            )
        }

        if stageManagerActive {
            let reserve = min(max(0, stageManagerReservePoints), max(0, rect.width - 200))
            if stageManagerEdge == .left {
                rect.origin.x += reserve
                rect.size.width = max(0, rect.width - reserve)
            } else {
                rect.size.width = max(0, rect.width - reserve)
            }
        }
        return rect
    }

    static func usableAXRect(
        screenFrame: CGRect? = nil,
        visibleFrame: CGRect,
        primaryScreenHeight: CGFloat,
        safeAreaInsets: SafeAreaInsets = SafeAreaInsets(),
        stageManagerActive: Bool = false,
        stageManagerEdge: StageManagerStripEdge = .left,
        stageManagerReservePoints: CGFloat = 78
    ) -> CGRect {
        let appKit = usableAppKitRect(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            safeAreaInsets: safeAreaInsets,
            stageManagerActive: stageManagerActive,
            stageManagerEdge: stageManagerEdge,
            stageManagerReservePoints: stageManagerReservePoints
        )
        return appKitToAX(appKit, primaryScreenHeight: primaryScreenHeight)
    }

    // MARK: - Outer Margin & Inner Gap Division Math

    static func divideAxis(
        origin: CGFloat,
        totalSpan: CGFloat,
        weights: [Double],
        outerMargin: CGFloat,
        innerGap: CGFloat
    ) -> [(offset: CGFloat, span: CGFloat)] {
        let safeWeights = (weights.isEmpty ? [1.0] : weights).map { max(0.05, $0) }
        let n = safeWeights.count
        let clampedOuter = max(0, outerMargin)
        let clampedInner = max(0, innerGap)
        let totalInnerGaps = CGFloat(max(0, n - 1)) * clampedInner
        let availableSpan = max(0, totalSpan - 2 * clampedOuter - totalInnerGaps)
        let totalWeight = safeWeights.reduce(0, +)

        var results: [(offset: CGFloat, span: CGFloat)] = []
        results.reserveCapacity(n)

        var cumulativeWeight: Double = 0
        var prevRoundedEnd: CGFloat = 0
        let totalRoundedSpan = round(availableSpan)

        for index in 0..<n {
            cumulativeWeight += safeWeights[index]
            let rawEnd = availableSpan * CGFloat(cumulativeWeight / totalWeight)
            let nextRoundedEnd = (index == n - 1) ? totalRoundedSpan : round(rawEnd)
            let span = max(0, nextRoundedEnd - prevRoundedEnd)
            let offset = round(origin + clampedOuter + prevRoundedEnd + CGFloat(index) * clampedInner)
            results.append((offset: offset, span: span))
            prevRoundedEnd = nextRoundedEnd
        }

        return results
    }

    static func applyGaps(
        to normalized: NormalizedRect,
        in usableAXRect: CGRect,
        outerMargin: CGFloat,
        innerGap: CGFloat
    ) -> CGRect {
        let n = normalized.clamped
        let rawLeft = usableAXRect.minX + CGFloat(n.x) * usableAXRect.width
        let rawRight = usableAXRect.minX + CGFloat(n.maxX) * usableAXRect.width
        let rawTop = usableAXRect.minY + CGFloat(n.y) * usableAXRect.height
        let rawBottom = usableAXRect.minY + CGFloat(n.maxY) * usableAXRect.height

        let eps = 0.001
        let leftInset = (n.x <= eps) ? outerMargin : innerGap / 2.0
        let rightInset = (n.maxX >= 1.0 - eps) ? outerMargin : innerGap / 2.0
        let topInset = (n.y <= eps) ? outerMargin : innerGap / 2.0
        let bottomInset = (n.maxY >= 1.0 - eps) ? outerMargin : innerGap / 2.0

        let minX = round(rawLeft + leftInset)
        let maxX = round(rawRight - rightInset)
        let minY = round(rawTop + topInset)
        let maxY = round(rawBottom - bottomInset)

        return CGRect(
            x: minX,
            y: minY,
            width: max(40, maxX - minX),
            height: max(40, maxY - minY)
        )
    }

    static func resolveDivisionZones(
        division: DisplayDivision,
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        outerMargin: CGFloat,
        innerGap: CGFloat
    ) -> [ResolvedZone] {
        let cols = divideAxis(
            origin: usableAXRect.minX,
            totalSpan: usableAXRect.width,
            weights: division.columnWeights,
            outerMargin: outerMargin,
            innerGap: innerGap
        )
        let rows = divideAxis(
            origin: usableAXRect.minY,
            totalSpan: usableAXRect.height,
            weights: division.rowWeights,
            outerMargin: outerMargin,
            innerGap: innerGap
        )

        let totalColWeight = division.columnWeights.map { max(0.05, $0) }.reduce(0, +)
        let totalRowWeight = division.rowWeights.map { max(0.05, $0) }.reduce(0, +)

        var colNormStarts: [Double] = []
        var colNormWidths: [Double] = []
        var accW = 0.0
        for w in division.columnWeights.map({ max(0.05, $0) }) {
            let nw = w / totalColWeight
            colNormStarts.append(accW)
            colNormWidths.append(nw)
            accW += nw
        }

        var rowNormStarts: [Double] = []
        var rowNormHeights: [Double] = []
        var accH = 0.0
        for h in division.rowWeights.map({ max(0.05, $0) }) {
            let nh = h / totalRowWeight
            rowNormStarts.append(accH)
            rowNormHeights.append(nh)
            accH += nh
        }

        var zones: [ResolvedZone] = []
        var badge = 1
        for rowIdx in 0..<rows.count {
            for colIdx in 0..<cols.count {
                let axFrame = CGRect(
                    x: cols[colIdx].offset,
                    y: rows[rowIdx].offset,
                    width: cols[colIdx].span,
                    height: rows[rowIdx].span
                )
                let norm = NormalizedRect(
                    x: colNormStarts[colIdx],
                    y: rowNormStarts[rowIdx],
                    width: colNormWidths[colIdx],
                    height: rowNormHeights[rowIdx]
                )
                let label: String = {
                    if rows.count == 1 && cols.count == 1 {
                        return "Maximized"
                    }
                    if rows.count == 1 && cols.count == 2 {
                        return colIdx == 0 ? "Left" : "Right"
                    }
                    if rows.count == 1 && cols.count == 3 {
                        return ["Left", "Center", "Right"][colIdx]
                    }
                    if rows.count == 2 && cols.count == 1 {
                        return rowIdx == 0 ? "Top" : "Bottom"
                    }
                    return "Zone \(badge)"
                }()
                zones.append(ResolvedZone(
                    id: "cell:\(colIdx):\(rowIdx)",
                    name: label,
                    badgeNumber: badge,
                    normalizedRect: norm,
                    frameInAX: axFrame,
                    frameInAppKit: axToAppKit(axFrame, primaryScreenHeight: primaryScreenHeight),
                    gridCoord: GridCellCoord(col: colIdx, row: rowIdx),
                    shortcut: .none
                ))
                badge += 1
            }
        }
        return zones
    }

    static func resolveZones(
        layout: DisplayLayoutConfig?,
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        gaps: GapConfig
    ) -> [ResolvedZone] {
        let division = layout?.division ?? DisplayDivision()
        let outer = CGFloat(layout?.outerMarginPoints ?? gaps.outerMarginPoints)
        let inner = CGFloat(layout?.innerGapPoints ?? gaps.innerGapPoints)

        var zones: [ResolvedZone]
        if layout?.presetKind == .leftMainRightStack,
           division.columnWeights.count >= 2,
           division.rowWeights.count >= 2,
           let leftMain = resolveSpannedZone(
               span: GridSpan(startCol: 0, endCol: 0, startRow: 0, endRow: 1),
               division: division,
               usableAXRect: usableAXRect,
               primaryScreenHeight: primaryScreenHeight,
               outerMargin: outer,
               innerGap: inner
           ) {
            let baseCells = resolveDivisionZones(
                division: division,
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                outerMargin: outer,
                innerGap: inner
            )
            var composite: [ResolvedZone] = [
                ResolvedZone(
                    id: "cell:0:0",
                    name: "Left Main",
                    badgeNumber: 1,
                    normalizedRect: leftMain.normalizedRect,
                    frameInAX: leftMain.frameInAX,
                    frameInAppKit: leftMain.frameInAppKit,
                    gridCoord: GridCellCoord(col: 0, row: 0),
                    shortcut: .none
                )
            ]
            if let topRight = baseCells.first(where: { $0.gridCoord == GridCellCoord(col: 1, row: 0) }) {
                composite.append(ResolvedZone(
                    id: "cell:1:0",
                    name: "Top Right",
                    badgeNumber: 2,
                    normalizedRect: topRight.normalizedRect,
                    frameInAX: topRight.frameInAX,
                    frameInAppKit: topRight.frameInAppKit,
                    gridCoord: GridCellCoord(col: 1, row: 0),
                    shortcut: .none
                ))
            }
            if let bottomRight = baseCells.first(where: { $0.gridCoord == GridCellCoord(col: 1, row: 1) }) {
                composite.append(ResolvedZone(
                    id: "cell:1:1",
                    name: "Bottom Right",
                    badgeNumber: 3,
                    normalizedRect: bottomRight.normalizedRect,
                    frameInAX: bottomRight.frameInAX,
                    frameInAppKit: bottomRight.frameInAppKit,
                    gridCoord: GridCellCoord(col: 1, row: 1),
                    shortcut: .none
                ))
            }
            zones = composite
        } else if layout?.presetKind == .leftStackRightMain,
                  division.columnWeights.count >= 2,
                  division.rowWeights.count >= 2,
                  let rightMain = resolveSpannedZone(
                      span: GridSpan(startCol: 1, endCol: 1, startRow: 0, endRow: 1),
                      division: division,
                      usableAXRect: usableAXRect,
                      primaryScreenHeight: primaryScreenHeight,
                      outerMargin: outer,
                      innerGap: inner
                  ) {
            let baseCells = resolveDivisionZones(
                division: division,
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                outerMargin: outer,
                innerGap: inner
            )
            var composite: [ResolvedZone] = []
            if let topLeft = baseCells.first(where: { $0.gridCoord == GridCellCoord(col: 0, row: 0) }) {
                composite.append(ResolvedZone(
                    id: "cell:0:0",
                    name: "Top Left",
                    badgeNumber: 1,
                    normalizedRect: topLeft.normalizedRect,
                    frameInAX: topLeft.frameInAX,
                    frameInAppKit: topLeft.frameInAppKit,
                    gridCoord: GridCellCoord(col: 0, row: 0),
                    shortcut: .none
                ))
            }
            if let bottomLeft = baseCells.first(where: { $0.gridCoord == GridCellCoord(col: 0, row: 1) }) {
                composite.append(ResolvedZone(
                    id: "cell:0:1",
                    name: "Bottom Left",
                    badgeNumber: 2,
                    normalizedRect: bottomLeft.normalizedRect,
                    frameInAX: bottomLeft.frameInAX,
                    frameInAppKit: bottomLeft.frameInAppKit,
                    gridCoord: GridCellCoord(col: 0, row: 1),
                    shortcut: .none
                ))
            }
            composite.append(ResolvedZone(
                id: "cell:1:0",
                name: "Right Main",
                badgeNumber: 3,
                normalizedRect: rightMain.normalizedRect,
                frameInAX: rightMain.frameInAX,
                frameInAppKit: rightMain.frameInAppKit,
                gridCoord: GridCellCoord(col: 1, row: 0),
                shortcut: .none
            ))
            zones = composite
        } else {
            zones = resolveDivisionZones(
                division: division,
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                outerMargin: outer,
                innerGap: inner
            )
        }

        var nextBadge = zones.count + 1
        for custom in layout?.customZones ?? [] {
            let axFrame = applyGaps(
                to: custom.normalizedRect,
                in: usableAXRect,
                outerMargin: outer,
                innerGap: inner
            )
            zones.append(ResolvedZone(
                id: custom.id,
                name: custom.name,
                badgeNumber: nextBadge,
                normalizedRect: custom.normalizedRect,
                frameInAX: axFrame,
                frameInAppKit: axToAppKit(axFrame, primaryScreenHeight: primaryScreenHeight),
                gridCoord: nil,
                shortcut: custom.shortcut
            ))
            nextBadge += 1
        }
        return zones
    }

    static func resolveTemplateZones(
        preset: DisplayPresetKind,
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        gaps: GapConfig,
        layoutOverride: DisplayLayoutConfig? = nil
    ) -> [ResolvedZone] {
        let effectivePreset: DisplayPresetKind = (preset == .custom) ? .halves : preset
        let syntheticLayout = DisplayLayoutConfig(
            display: layoutOverride?.display ?? DisplaySignature(),
            presetID: effectivePreset.rawValue,
            division: effectivePreset.defaultDivision,
            customZones: [],
            outerMarginPoints: layoutOverride?.outerMarginPoints,
            innerGapPoints: layoutOverride?.innerGapPoints
        )
        return resolveZones(
            layout: syntheticLayout,
            usableAXRect: usableAXRect,
            primaryScreenHeight: primaryScreenHeight,
            gaps: gaps
        )
    }

    static func resolveSpannedZone(
        span: GridSpan,
        division: DisplayDivision,
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        outerMargin: CGFloat,
        innerGap: CGFloat
    ) -> ResolvedZone? {
        let cells = resolveDivisionZones(
            division: division,
            usableAXRect: usableAXRect,
            primaryScreenHeight: primaryScreenHeight,
            outerMargin: outerMargin,
            innerGap: innerGap
        )
        let s = span.normalized
        let maxCol = max(0, division.columnWeights.count - 1)
        let maxRow = max(0, division.rowWeights.count - 1)
        let clampedSpan = GridSpan(
            startCol: min(max(s.startCol, 0), maxCol),
            endCol: min(max(s.endCol, 0), maxCol),
            startRow: min(max(s.startRow, 0), maxRow),
            endRow: min(max(s.endRow, 0), maxRow)
        )

        let selected = cells.filter { zone in
            guard let coord = zone.gridCoord else { return false }
            return coord.col >= clampedSpan.startCol && coord.col <= clampedSpan.endCol
                && coord.row >= clampedSpan.startRow && coord.row <= clampedSpan.endRow
        }
        guard let first = selected.first else { return nil }

        var unionAX = first.frameInAX
        var minNX = first.normalizedRect.x
        var minNY = first.normalizedRect.y
        var maxNX = first.normalizedRect.maxX
        var maxNY = first.normalizedRect.maxY

        for z in selected.dropFirst() {
            unionAX = unionAX.union(z.frameInAX)
            minNX = min(minNX, z.normalizedRect.x)
            minNY = min(minNY, z.normalizedRect.y)
            maxNX = max(maxNX, z.normalizedRect.maxX)
            maxNY = max(maxNY, z.normalizedRect.maxY)
        }

        let norm = NormalizedRect(x: minNX, y: minNY, width: maxNX - minNX, height: maxNY - minNY)
        let name = selected.count == 1
            ? first.name
            : "Span \(first.badgeNumber)–\(selected.last?.badgeNumber ?? first.badgeNumber)"

        return ResolvedZone(
            id: clampedSpan.zoneID,
            name: name,
            badgeNumber: first.badgeNumber,
            normalizedRect: norm,
            frameInAX: unionAX,
            frameInAppKit: axToAppKit(unionAX, primaryScreenHeight: primaryScreenHeight),
            gridCoord: selected.count == 1 ? first.gridCoord : nil,
            shortcut: .none
        )
    }

    static func resolveUniversalOrBuiltInZone(
        id: String,
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        gaps: GapConfig,
        layoutOverride: DisplayLayoutConfig? = nil,
        centerWidthFraction: Double = 0.70,
        centerHeightFraction: Double = 0.80
    ) -> ResolvedZone? {
        let outer = CGFloat(layoutOverride?.outerMarginPoints ?? gaps.outerMarginPoints)
        let inner = CGFloat(layoutOverride?.innerGapPoints ?? gaps.innerGapPoints)

        if id == "universal:maximize" {
            let ax = applyGaps(to: .full, in: usableAXRect, outerMargin: 0, innerGap: 0)
            return ResolvedZone(
                id: id,
                name: "Maximize",
                badgeNumber: 0,
                normalizedRect: .full,
                frameInAX: ax,
                frameInAppKit: axToAppKit(ax, primaryScreenHeight: primaryScreenHeight),
                gridCoord: nil,
                shortcut: .none
            )
        }

        if id == "universal:center" {
            let cw = min(max(centerWidthFraction, 0.25), 0.98)
            let ch = min(max(centerHeightFraction, 0.25), 0.98)
            let norm = NormalizedRect(x: (1.0 - cw) / 2.0, y: (1.0 - ch) / 2.0, width: cw, height: ch)
            let ax = CGRect(
                x: round(usableAXRect.minX + CGFloat(norm.x) * usableAXRect.width),
                y: round(usableAXRect.minY + CGFloat(norm.y) * usableAXRect.height),
                width: round(CGFloat(norm.width) * usableAXRect.width),
                height: round(CGFloat(norm.height) * usableAXRect.height)
            )
            return ResolvedZone(
                id: id,
                name: "Center",
                badgeNumber: 0,
                normalizedRect: norm,
                frameInAX: ax,
                frameInAppKit: axToAppKit(ax, primaryScreenHeight: primaryScreenHeight),
                gridCoord: nil,
                shortcut: .none
            )
        }

        let builtInMap: [String: (String, NormalizedRect)] = [
            "preset:left_half": ("Left Half", .leftHalf),
            "preset:right_half": ("Right Half", .rightHalf),
            "preset:top_half": ("Top Half", .topHalf),
            "preset:bottom_half": ("Bottom Half", .bottomHalf),
            "preset:top_left": ("Top Left", .topLeft),
            "preset:top_right": ("Top Right", .topRight),
            "preset:bottom_left": ("Bottom Left", .bottomLeft),
            "preset:bottom_right": ("Bottom Right", .bottomRight)
        ]
        if let (label, norm) = builtInMap[id] {
            let ax = applyGaps(to: norm, in: usableAXRect, outerMargin: outer, innerGap: inner)
            return ResolvedZone(
                id: id,
                name: label,
                badgeNumber: 0,
                normalizedRect: norm,
                frameInAX: ax,
                frameInAppKit: axToAppKit(ax, primaryScreenHeight: primaryScreenHeight),
                gridCoord: nil,
                shortcut: .none
            )
        }

        let zones = resolveZones(
            layout: layoutOverride,
            usableAXRect: usableAXRect,
            primaryScreenHeight: primaryScreenHeight,
            gaps: gaps
        )
        if let direct = zones.first(where: { $0.id == id }) {
            return direct
        }

        if let span = GridSpan.parse(zoneID: id) {
            return resolveSpannedZone(
                span: span,
                division: layoutOverride?.division ?? DisplayDivision(),
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                outerMargin: outer,
                innerGap: inner
            )
        }

        return nil
    }

    // MARK: - Minimum-Size Clamping

    static func clampFrameForMinimumSize(
        targetFrame: CGRect,
        actualSize: CGSize,
        usableRect: CGRect,
        outerMargin: CGFloat = 0
    ) -> CGRect {
        let safeOuter = max(0, outerMargin)
        let allowed = CGRect(
            x: usableRect.minX + safeOuter,
            y: usableRect.minY + safeOuter,
            width: max(40, usableRect.width - 2 * safeOuter),
            height: max(40, usableRect.height - 2 * safeOuter)
        )

        let width = max(targetFrame.width, actualSize.width)
        let height = max(targetFrame.height, actualSize.height)

        var x = targetFrame.origin.x
        var y = targetFrame.origin.y

        if x + width > allowed.maxX {
            x = allowed.maxX - width
        }
        if x < allowed.minX {
            x = allowed.minX
        }

        if y + height > allowed.maxY {
            y = allowed.maxY - height
        }
        if y < allowed.minY {
            y = allowed.minY
        }

        return CGRect(x: round(x), y: round(y), width: round(width), height: round(height))
    }

    static func evaluateMinSizeFit(
        targetFrameAX: CGRect,
        minSize: CGSize?,
        usableAXRect: CGRect
    ) -> ZoneMinSizeWarning? {
        guard let minSize, (minSize.width > 1 || minSize.height > 1) else {
            return nil
        }
        let exceedsWidth = minSize.width > targetFrameAX.width + 2.0
        let exceedsHeight = minSize.height > targetFrameAX.height + 2.0
        guard exceedsWidth || exceedsHeight else {
            return nil
        }
        let clampedActualSize = CGSize(
            width: max(targetFrameAX.width, minSize.width),
            height: max(targetFrameAX.height, minSize.height)
        )
        let clamped = clampFrameForMinimumSize(
            targetFrame: targetFrameAX,
            actualSize: clampedActualSize,
            usableRect: usableAXRect
        )
        return ZoneMinSizeWarning(
            minSize: minSize,
            clampedFrameAX: clamped,
            exceedsWidth: exceedsWidth,
            exceedsHeight: exceedsHeight
        )
    }

    // MARK: - Drag Hit-Testing

    static func hitTestEdgeOrCorner(
        pointerAX: CGPoint,
        screenFrameAX: CGRect,
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        dragConfig: DragSnapConfig,
        gaps: GapConfig,
        layout: DisplayLayoutConfig?
    ) -> ResolvedZone? {
        guard screenFrameAX.contains(pointerAX) else { return nil }

        let edgeBand = max(1, CGFloat(dragConfig.edgeProximityPoints))
        let cornerBand = max(edgeBand, CGFloat(dragConfig.cornerBandPoints))
        let outer = CGFloat(layout?.outerMarginPoints ?? gaps.outerMarginPoints)
        let inner = CGFloat(layout?.innerGapPoints ?? gaps.innerGapPoints)

        let distLeft = pointerAX.x - screenFrameAX.minX
        let distRight = screenFrameAX.maxX - pointerAX.x
        let distTop = pointerAX.y - screenFrameAX.minY
        let distBottom = screenFrameAX.maxY - pointerAX.y

        let leftInset = max(0, usableAXRect.minX - screenFrameAX.minX)
        let rightInset = max(0, screenFrameAX.maxX - usableAXRect.maxX)
        let topInset = max(0, usableAXRect.minY - screenFrameAX.minY)
        let bottomInset = max(0, screenFrameAX.maxY - usableAXRect.maxY)

        let nearLeft = distLeft <= max(edgeBand, leftInset + edgeBand)
        let nearRight = distRight <= max(edgeBand, rightInset + edgeBand)
        let nearTop = distTop <= max(edgeBand, topInset + edgeBand)
        let nearBottom = distBottom <= max(edgeBand, bottomInset + edgeBand)

        let inCornerTop = distTop <= max(cornerBand, topInset + cornerBand)
        let inCornerBottom = distBottom <= max(cornerBand, bottomInset + cornerBand)
        let inCornerLeft = distLeft <= max(cornerBand, leftInset + cornerBand)
        let inCornerRight = distRight <= max(cornerBand, rightInset + cornerBand)

        if (nearLeft || nearTop) && inCornerLeft && inCornerTop {
            return resolveUniversalOrBuiltInZone(
                id: "preset:top_left",
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                gaps: gaps,
                layoutOverride: layout
            )
        }
        if (nearRight || nearTop) && inCornerRight && inCornerTop {
            return resolveUniversalOrBuiltInZone(
                id: "preset:top_right",
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                gaps: gaps,
                layoutOverride: layout
            )
        }
        if (nearLeft || nearBottom) && inCornerLeft && inCornerBottom {
            return resolveUniversalOrBuiltInZone(
                id: "preset:bottom_left",
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                gaps: gaps,
                layoutOverride: layout
            )
        }
        if (nearRight || nearBottom) && inCornerRight && inCornerBottom {
            return resolveUniversalOrBuiltInZone(
                id: "preset:bottom_right",
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                gaps: gaps,
                layoutOverride: layout
            )
        }

        let divisionZones = resolveDivisionZones(
            division: layout?.division ?? DisplayDivision(),
            usableAXRect: usableAXRect,
            primaryScreenHeight: primaryScreenHeight,
            outerMargin: outer,
            innerGap: inner
        )

        if nearLeft {
            if layout?.presetKind == .leftMainRightStack,
               let leftMain = resolveZones(
                   layout: layout,
                   usableAXRect: usableAXRect,
                   primaryScreenHeight: primaryScreenHeight,
                   gaps: gaps
               ).first(where: { $0.id == "cell:0:0" }) {
                return leftMain
            }
            let colCount = layout?.division.columnWeights.count ?? 2
            let rowCount = layout?.division.rowWeights.count ?? 1
            if colCount > 1,
               rowCount == 1,
               let firstCol = divisionZones.first(where: { $0.gridCoord?.col == 0 }) {
                return firstCol
            }
            return resolveUniversalOrBuiltInZone(
                id: "preset:left_half",
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                gaps: gaps,
                layoutOverride: layout
            )
        }
        if nearRight {
            if layout?.presetKind == .leftStackRightMain,
               let rightMain = resolveZones(
                   layout: layout,
                   usableAXRect: usableAXRect,
                   primaryScreenHeight: primaryScreenHeight,
                   gaps: gaps
               ).first(where: { $0.id == "cell:1:0" }) {
                return rightMain
            }
            let colCount = layout?.division.columnWeights.count ?? 2
            let rowCount = layout?.division.rowWeights.count ?? 1
            let lastColIdx = max(0, colCount - 1)
            if colCount > 1,
               rowCount == 1,
               let lastCol = divisionZones.first(where: { $0.gridCoord?.col == lastColIdx }) {
                return lastCol
            }
            return resolveUniversalOrBuiltInZone(
                id: "preset:right_half",
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                gaps: gaps,
                layoutOverride: layout
            )
        }
        if nearTop {
            return resolveUniversalOrBuiltInZone(
                id: "universal:maximize",
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                gaps: gaps,
                layoutOverride: layout
            )
        }
        if nearBottom {
            return nil
        }
        return nil
    }

    static func hitTestGridOrSpan(
        pointerAX: CGPoint,
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        layout: DisplayLayoutConfig?,
        gaps: GapConfig,
        seamRadius: CGFloat = seamSpanProximityPoints
    ) -> DragZoneHit? {
        let division = layout?.division ?? DisplayDivision()
        let outer = CGFloat(layout?.outerMarginPoints ?? gaps.outerMarginPoints)
        let inner = CGFloat(layout?.innerGapPoints ?? gaps.innerGapPoints)
        let allZones = resolveZones(
            layout: layout,
            usableAXRect: usableAXRect,
            primaryScreenHeight: primaryScreenHeight,
            gaps: gaps
        )
        let divisionCells = allZones.filter { $0.gridCoord != nil }

        // Check explicit custom zones first when inside them
        for custom in allZones where custom.gridCoord == nil {
            if custom.frameInAX.contains(pointerAX) {
                return DragZoneHit(zone: custom, isSpanning: false)
            }
        }

        // Find hovered grid cell or closest cell inside usable rect
        let hoveredCell: ResolvedZone? = divisionCells.first(where: { $0.frameInAX.contains(pointerAX) }) ?? {
            guard usableAXRect.insetBy(dx: -24, dy: -24).contains(pointerAX) else { return nil }
            return divisionCells.min { lhs, rhs in
                let d1 = hypot(pointerAX.x - lhs.frameInAX.midX, pointerAX.y - lhs.frameInAX.midY)
                let d2 = hypot(pointerAX.x - rhs.frameInAX.midX, pointerAX.y - rhs.frameInAX.midY)
                return d1 < d2
            }
        }()

        guard let hovered = hoveredCell, let hoveredCoord = hovered.gridCoord else {
            return nil
        }

        if layout?.presetKind == .leftMainRightStack || layout?.presetKind == .leftStackRightMain {
            return DragZoneHit(zone: hovered, isSpanning: false)
        }

        // Automatic seam-proximity spanning (hovering within `seamRadius` of an interior divider)
        var minCol = hoveredCoord.col
        var maxCol = hoveredCoord.col
        var minRow = hoveredCoord.row
        var maxRow = hoveredCoord.row
        let colCount = division.columnWeights.count
        let rowCount = division.rowWeights.count

        if hoveredCoord.col > 0 && abs(pointerAX.x - hovered.frameInAX.minX) <= seamRadius {
            minCol -= 1
        } else if hoveredCoord.col < colCount - 1 && abs(hovered.frameInAX.maxX - pointerAX.x) <= seamRadius {
            maxCol += 1
        }
        if hoveredCoord.row > 0 && abs(pointerAX.y - hovered.frameInAX.minY) <= seamRadius {
            minRow -= 1
        } else if hoveredCoord.row < rowCount - 1 && abs(hovered.frameInAX.maxY - pointerAX.y) <= seamRadius {
            maxRow += 1
        }

        if minCol != maxCol || minRow != maxRow {
            let span = GridSpan(startCol: minCol, endCol: maxCol, startRow: minRow, endRow: maxRow)
            if let spanned = resolveSpannedZone(
                span: span,
                division: division,
                usableAXRect: usableAXRect,
                primaryScreenHeight: primaryScreenHeight,
                outerMargin: outer,
                innerGap: inner
            ) {
                return DragZoneHit(zone: spanned, isSpanning: true)
            }
        }

        return DragZoneHit(zone: hovered, isSpanning: false)
    }

    static func normalizedRect(forAXFrame frame: CGRect, inUsableAXRect usable: CGRect) -> NormalizedRect {
        guard usable.width > 1, usable.height > 1 else { return .full }
        return NormalizedRect(
            x: Double((frame.minX - usable.minX) / usable.width),
            y: Double((frame.minY - usable.minY) / usable.height),
            width: Double(frame.width / usable.width),
            height: Double(frame.height / usable.height)
        ).clamped
    }

    static func closestZoneID(
        forAXFrame frame: CGRect,
        in zones: [ResolvedZone],
        tolerancePoints: CGFloat = 32
    ) -> String? {
        var bestZone: ResolvedZone?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for zone in zones {
            let dx = abs(frame.minX - zone.frameInAX.minX) + abs(frame.maxX - zone.frameInAX.maxX)
            let dy = abs(frame.minY - zone.frameInAX.minY) + abs(frame.maxY - zone.frameInAX.maxY)
            let dist = dx + dy
            if dist <= tolerancePoints * 4 && dist < bestDistance {
                bestDistance = dist
                bestZone = zone
            }
        }
        return bestZone?.id
    }

    // MARK: - Trigger Area Flash Geometry

    /// Perimeter magnetic pull strips along the Left, Right, and Top active edges (bottom edge is inert),
    /// inset from corners so adjacent strips never overlap and corner quadrants stay visually distinct.
    static func edgePullFlashRectsAX(
        usableAX: CGRect,
        edgeProximityPoints: CGFloat,
        cornerBandPoints: CGFloat = 48
    ) -> [CGRect] {
        guard usableAX.width > 48, usableAX.height > 48 else { return [] }
        let visualBand = max(4, min(edgeProximityPoints, min(usableAX.width, usableAX.height) / 4))
        let cornerInset = max(visualBand + 8, min(cornerBandPoints, min(usableAX.width, usableAX.height) / 3))
        let verticalSpan = max(16, usableAX.height - 2 * cornerInset)
        let horizontalSpan = max(16, usableAX.width - 2 * cornerInset)
        return [
            CGRect(x: usableAX.minX, y: usableAX.minY + cornerInset, width: visualBand, height: verticalSpan),
            CGRect(x: usableAX.maxX - visualBand, y: usableAX.minY + cornerInset, width: visualBand, height: verticalSpan),
            CGRect(x: usableAX.minX + cornerInset, y: usableAX.minY, width: horizontalSpan, height: visualBand)
        ]
    }

    /// Four corner quadrant target squares at Top-Left, Top-Right, Bottom-Left, and Bottom-Right.
    static func cornerBandFlashRectsAX(usableAX: CGRect, cornerBandPoints: CGFloat) -> [CGRect] {
        guard usableAX.width > 32, usableAX.height > 32 else { return [] }
        let band = max(16, min(cornerBandPoints, min(usableAX.width, usableAX.height) / 3))
        return [
            CGRect(x: usableAX.minX, y: usableAX.minY, width: band, height: band),
            CGRect(x: usableAX.maxX - band, y: usableAX.minY, width: band, height: band),
            CGRect(x: usableAX.minX, y: usableAX.maxY - band, width: band, height: band),
            CGRect(x: usableAX.maxX - band, y: usableAX.maxY - band, width: band, height: band)
        ]
    }

    /// Balanced two-tile (Left / Right) layout at 1:1 scale used to preview
    /// uniform Tile Spacing (outer margins + inner gap) and Outline Thickness on screen.
    static func stylePreviewZonesAX(
        usableAXRect: CGRect,
        primaryScreenHeight: CGFloat,
        gaps: GapConfig
    ) -> [ResolvedZone] {
        resolveTemplateZones(
            preset: .halves,
            usableAXRect: usableAXRect,
            primaryScreenHeight: primaryScreenHeight,
            gaps: gaps,
            layoutOverride: nil
        )
    }
}
