import AppKit
import SwiftUI

@MainActor
private final class ZoneOnScreenEditorState: ObservableObject {
    @Published var layout: DisplayLayoutConfig
    @Published var activeDividerDragWeights: [Double]? = nil
    @Published var activeColumnDividerIndex: Int? = nil
    @Published var activeRowDividerIndex: Int? = nil

    init(layout: DisplayLayoutConfig) {
        self.layout = layout
    }
}

private struct ResizeCursorOverlay: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> ResizeCursorNSView {
        ResizeCursorNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: ResizeCursorNSView, context: Context) {
        nsView.customHoverCursor = cursor
    }

    final class ResizeCursorNSView: NSView, HoverCursorProviderView {
        var customHoverCursor: NSCursor

        init(cursor: NSCursor) {
            self.customHoverCursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

struct ZoneOnScreenEditorView: View {
    let display: ConnectedDisplay
    let gaps: GapConfig
    let style: OverlayStyleConfig
    let onSave: (DisplayLayoutConfig) -> Void
    let onCancel: () -> Void

    @StateObject private var state: ZoneOnScreenEditorState

    init(
        display: ConnectedDisplay,
        initialLayout: DisplayLayoutConfig,
        gaps: GapConfig,
        style: OverlayStyleConfig = OverlayStyleConfig(),
        onSave: @escaping (DisplayLayoutConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.display = display
        self.gaps = gaps
        self.style = style
        self.onSave = onSave
        self.onCancel = onCancel
        _state = StateObject(wrappedValue: ZoneOnScreenEditorState(layout: initialLayout))
    }

    static func zoneMetricsLabel(
        normalizedRect: NormalizedRect,
        widthPoints: CGFloat,
        heightPoints: CGFloat
    ) -> String {
        let w = Int(round(widthPoints))
        let h = Int(round(heightPoints))
        let wPct = Int(round(normalizedRect.width * 100))
        let hPct = Int(round(normalizedRect.height * 100))
        if wPct >= 99 && hPct >= 99 {
            return "\(w) × \(h)"
        }
        if hPct >= 99 {
            return "\(wPct)% · \(w) × \(h)"
        }
        if wPct >= 99 {
            return "\(hPct)% · \(w) × \(h)"
        }
        return "\(wPct)% × \(hPct)% · \(w) × \(h)"
    }

    private var effectiveOuterMargin: CGFloat {
        CGFloat(state.layout.outerMarginPoints ?? gaps.outerMarginPoints)
    }

    private var effectiveInnerGap: CGFloat {
        CGFloat(state.layout.innerGapPoints ?? gaps.innerGapPoints)
    }

    private var resolvedZones: [ResolvedZone] {
        SnapGeometry.resolveZones(
            layout: state.layout,
            usableAXRect: display.usableAX,
            primaryScreenHeight: display.primaryScreenHeight,
            gaps: gaps
        )
    }

    var body: some View {
        let localUsableX = display.usableAX.minX - display.frameAX.minX
        let localUsableY = display.usableAX.minY - display.frameAX.minY
        let usableW = max(1, display.usableAX.width)
        let usableH = max(1, display.usableAX.height)

        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())

            // Render all live template zones
            ForEach(resolvedZones) { zone in
                editorZoneCard(zone)
            }

            // Interactive column divider handles
            columnDividerHandles(
                localUsableY: localUsableY,
                usableW: usableW,
                usableH: usableH
            )

            // Interactive row divider handles
            rowDividerHandles(
                localUsableX: localUsableX,
                usableW: usableW,
                usableH: usableH
            )

            // Floating control bar & subtle hint at top-center of usable area
            VStack(spacing: 8) {
                floatingToolbar
                editorHintPill
            }
            .position(
                x: localUsableX + usableW / 2.0,
                y: localUsableY + 54
            )
        }
        .frame(width: display.frameAX.width, height: display.frameAX.height, alignment: .topLeading)
        .toolboxDarkAppearance()
    }

    private var hasAdjustableDividers: Bool {
        state.layout.division.columnWeights.count > 1 || state.layout.division.rowWeights.count > 1
    }

    private var editorHintPill: some View {
        Text(
            hasAdjustableDividers
                ? "Drag white handles to resize · Esc to cancel"
                : "Choose a multi-zone template above to adjust dividers · Esc to cancel"
        )
        .toolboxFont(.caption2.weight(.medium))
        .foregroundStyle(Color.white.opacity(0.84))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
        )
        .allowsHitTesting(false)
    }

    private func editorZoneCard(_ zone: ResolvedZone) -> some View {
        let localX = zone.frameInAX.minX - display.frameAX.minX
        let localY = zone.frameInAX.minY - display.frameAX.minY
        let width = max(24, zone.frameInAX.width)
        let height = max(24, zone.frameInAX.height)
        let tint = style.tintColor.swatchColor
        let stroke = style.tintColor.readableStrokeColor
        let radius = CGFloat(style.cornerRadiusPoints)
        let strokeWidth = CGFloat(min(max(style.borderWidthPoints, 1.5), 4.0))
        let fillOpacity = max(0.12, style.fillOpacity)

        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint.opacity(fillOpacity))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(stroke.opacity(0.92), lineWidth: strokeWidth)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(zone.badgeNumber)")
                        .toolboxFont(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(style.tintColor == .neutral ? .black : .white)
                        .frame(width: 24, height: 24)
                        .background(tint.opacity(0.92), in: Circle())
                    Text(zone.name)
                        .toolboxFont(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text(
                    Self.zoneMetricsLabel(
                        normalizedRect: zone.normalizedRect,
                        widthPoints: width,
                        heightPoints: height
                    )
                )
                .toolboxFont(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.84))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(width: width, height: height)
        .offset(x: localX, y: localY)
    }

    @ViewBuilder
    private func columnDividerHandles(
        localUsableY: CGFloat,
        usableW: CGFloat,
        usableH: CGFloat
    ) -> some View {
        let weights = state.layout.division.columnWeights
        if weights.count > 1 {
            let cols = SnapGeometry.divideAxis(
                origin: display.usableAX.minX,
                totalSpan: display.usableAX.width,
                weights: weights,
                outerMargin: effectiveOuterMargin,
                innerGap: effectiveInnerGap
            )
            ForEach(0..<(cols.count - 1), id: \.self) { dividerIndex in
                let gapMidAX = ((cols[dividerIndex].offset + cols[dividerIndex].span) + cols[dividerIndex + 1].offset) / 2.0
                let dividerX = gapMidAX - display.frameAX.minX
                let isDragging = state.activeColumnDividerIndex == dividerIndex
                let strokeAccent = style.tintColor.readableStrokeColor

                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 22, height: max(80, usableH - 120))
                    Capsule()
                        .fill(isDragging ? strokeAccent : Color.white.opacity(0.92))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.black.opacity(isDragging ? 0.35 : 0.25), lineWidth: 0.75)
                        )
                        .frame(width: isDragging ? 6 : 5, height: isDragging ? 60 : 52)
                        .shadow(color: (isDragging ? strokeAccent : Color.black).opacity(0.45), radius: isDragging ? 6 : 4)
                }
                .contentShape(Rectangle())
                .overlay(ResizeCursorOverlay(cursor: .resizeLeftRight).allowsHitTesting(false))
                .position(x: dividerX, y: localUsableY + usableH / 2.0)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if state.activeDividerDragWeights == nil {
                                state.activeDividerDragWeights = state.layout.division.columnWeights
                            }
                            state.activeColumnDividerIndex = dividerIndex
                            let baseWeights = state.activeDividerDragWeights ?? state.layout.division.columnWeights
                            state.layout.division.columnWeights = adjustedDividerWeights(
                                baseWeights: baseWeights,
                                dividerIndex: dividerIndex,
                                translationPoints: value.translation.width,
                                totalUsableSpan: usableW,
                                minFraction: 0.12
                            )
                        }
                        .onEnded { _ in
                            state.activeDividerDragWeights = nil
                            state.activeColumnDividerIndex = nil
                        }
                )
            }
        }
    }

    @ViewBuilder
    private func rowDividerHandles(
        localUsableX: CGFloat,
        usableW: CGFloat,
        usableH: CGFloat
    ) -> some View {
        let weights = state.layout.division.rowWeights
        if weights.count > 1 {
            let rows = SnapGeometry.divideAxis(
                origin: display.usableAX.minY,
                totalSpan: display.usableAX.height,
                weights: weights,
                outerMargin: effectiveOuterMargin,
                innerGap: effectiveInnerGap
            )
            let cols = SnapGeometry.divideAxis(
                origin: display.usableAX.minX,
                totalSpan: display.usableAX.width,
                weights: state.layout.division.columnWeights,
                outerMargin: effectiveOuterMargin,
                innerGap: effectiveInnerGap
            )
            let horizontalBounds: (minX: CGFloat, maxX: CGFloat) = {
                if state.layout.presetKind == .leftMainRightStack, cols.count >= 2 {
                    let minX = cols[1].offset - display.frameAX.minX
                    let maxX = (cols[1].offset + cols[1].span) - display.frameAX.minX
                    return (minX, maxX)
                }
                if state.layout.presetKind == .leftStackRightMain, cols.count >= 2 {
                    let minX = cols[0].offset - display.frameAX.minX
                    let maxX = (cols[0].offset + cols[0].span) - display.frameAX.minX
                    return (minX, maxX)
                }
                return (
                    localUsableX + effectiveOuterMargin,
                    localUsableX + usableW - effectiveOuterMargin
                )
            }()
            let spanW = max(64, (horizontalBounds.maxX - horizontalBounds.minX) - 48)
            let centerX = (horizontalBounds.minX + horizontalBounds.maxX) / 2.0

            ForEach(0..<(rows.count - 1), id: \.self) { dividerIndex in
                let gapMidAX = ((rows[dividerIndex].offset + rows[dividerIndex].span) + rows[dividerIndex + 1].offset) / 2.0
                let dividerY = gapMidAX - display.frameAX.minY
                let isDragging = state.activeRowDividerIndex == dividerIndex
                let strokeAccent = style.tintColor.readableStrokeColor

                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: spanW, height: 22)
                    Capsule()
                        .fill(isDragging ? strokeAccent : Color.white.opacity(0.92))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.black.opacity(isDragging ? 0.35 : 0.25), lineWidth: 0.75)
                        )
                        .frame(width: isDragging ? 60 : 52, height: isDragging ? 6 : 5)
                        .shadow(color: (isDragging ? strokeAccent : Color.black).opacity(0.45), radius: isDragging ? 6 : 4)
                }
                .contentShape(Rectangle())
                .overlay(ResizeCursorOverlay(cursor: .resizeUpDown).allowsHitTesting(false))
                .position(x: centerX, y: dividerY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if state.activeDividerDragWeights == nil {
                                state.activeDividerDragWeights = state.layout.division.rowWeights
                            }
                            state.activeRowDividerIndex = dividerIndex
                            let baseWeights = state.activeDividerDragWeights ?? state.layout.division.rowWeights
                            state.layout.division.rowWeights = adjustedDividerWeights(
                                baseWeights: baseWeights,
                                dividerIndex: dividerIndex,
                                translationPoints: value.translation.height,
                                totalUsableSpan: usableH,
                                minFraction: 0.14
                            )
                        }
                        .onEnded { _ in
                            state.activeDividerDragWeights = nil
                            state.activeRowDividerIndex = nil
                        }
                )
            }
        }
    }

    private func adjustedDividerWeights(
        baseWeights: [Double],
        dividerIndex: Int,
        translationPoints: CGFloat,
        totalUsableSpan: CGFloat,
        minFraction: Double
    ) -> [Double] {
        guard dividerIndex >= 0, dividerIndex + 1 < baseWeights.count else { return baseWeights }
        let baseTotal = baseWeights.reduce(0, +)
        let pairSum = baseWeights[dividerIndex] + baseWeights[dividerIndex + 1]
        let deltaWeight = Double(translationPoints / max(100, totalUsableSpan)) * baseTotal
        let minW = min(baseTotal * minFraction, pairSum * 0.45)
        let newLeading = min(max(baseWeights[dividerIndex] + deltaWeight, minW), pairSum - minW)
        let newTrailing = pairSum - newLeading
        var updated = baseWeights
        updated[dividerIndex] = newLeading
        updated[dividerIndex + 1] = newTrailing
        return updated
    }

    private var floatingToolbar: some View {
        let canReset = state.layout.hasCustomDividerProportions
            || !state.layout.customZones.isEmpty
            || state.layout.presetKind == .custom

        return HStack(spacing: 10) {
            Label(display.signature.localizedName, systemImage: "display")
                .toolboxFont(.callout.weight(.semibold))
                .foregroundStyle(.white)

            Divider().frame(height: 18)

            Menu {
                Section("1 & 2 Zones") {
                    ForEach([DisplayPresetKind.maximized, .halves, .asymmetric, .asymmetricRight, .verticalStack2]) { preset in
                        templateMenuButton(preset)
                    }
                }
                Section("3 Zones") {
                    ForEach([DisplayPresetKind.leftMainRightStack, .leftStackRightMain, .thirds, .ultrawideFocus, .verticalStack3]) { preset in
                        templateMenuButton(preset)
                    }
                }
                Section("4 & 6 Zones") {
                    ForEach([DisplayPresetKind.quarters, .fourColumns, .sixths]) { preset in
                        templateMenuButton(preset)
                    }
                }
            } label: {
                Label(state.layout.presetKind.label, systemImage: "rectangle.3.group")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .fixedSize()
            .pointerCursor()

            Divider().frame(height: 18)

            Button("Reset") {
                let targetPreset: DisplayPresetKind = (state.layout.presetKind == .custom) ? .halves : state.layout.presetKind
                state.layout.presetID = targetPreset.rawValue
                state.layout.division = targetPreset.defaultDivision
                state.layout.customZones.removeAll()
                state.activeDividerDragWeights = nil
                state.activeColumnDividerIndex = nil
                state.activeRowDividerIndex = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canReset)
            .pointerCursor(canReset)

            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()

            Button("Done") {
                onSave(state.layout)
            }
            .buttonStyle(.toolboxProminent)
            .controlSize(.small)
            .help("Save layout (or press Esc to cancel)")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    private func templateMenuButton(_ preset: DisplayPresetKind) -> some View {
        Button {
            state.layout.presetID = preset.rawValue
            state.layout.division = preset.defaultDivision
            state.layout.customZones.removeAll()
            state.activeDividerDragWeights = nil
            state.activeColumnDividerIndex = nil
            state.activeRowDividerIndex = nil
        } label: {
            if state.layout.presetKind == preset {
                Label(preset.label, systemImage: "checkmark")
            } else {
                Text(preset.label)
            }
        }
    }
}
