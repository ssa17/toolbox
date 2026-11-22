import AppKit
import SwiftUI

@MainActor
private final class ZoneOnScreenEditorState: ObservableObject {
    @Published var layout: DisplayLayoutConfig
    @Published var isDrawingCustomZone: Bool = false
    @Published var drawStartNormalized: CGPoint? = nil
    @Published var drawCurrentNormalized: CGPoint? = nil
    @Published var activeDividerDragWeights: [Double]? = nil

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
    let onSave: (DisplayLayoutConfig) -> Void
    let onCancel: () -> Void

    @StateObject private var state: ZoneOnScreenEditorState

    init(
        display: ConnectedDisplay,
        initialLayout: DisplayLayoutConfig,
        gaps: GapConfig,
        onSave: @escaping (DisplayLayoutConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.display = display
        self.gaps = gaps
        self.onSave = onSave
        self.onCancel = onCancel
        _state = StateObject(wrappedValue: ZoneOnScreenEditorState(layout: initialLayout))
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

            // Render all live zones (division cells + custom zones)
            ForEach(resolvedZones) { zone in
                editorZoneCard(zone)
            }

            // Custom zone drawing surface when active
            if state.isDrawingCustomZone {
                customZoneDrawingSurface(
                    localUsableX: localUsableX,
                    localUsableY: localUsableY,
                    usableW: usableW,
                    usableH: usableH
                )
            }

            // Interactive column divider handles
            columnDividerHandles(
                localUsableX: localUsableX,
                localUsableY: localUsableY,
                usableW: usableW,
                usableH: usableH
            )

            // Interactive row divider handles
            rowDividerHandles(
                localUsableX: localUsableX,
                localUsableY: localUsableY,
                usableW: usableW,
                usableH: usableH
            )

            // Floating control bar at top-center of usable area
            floatingToolbar
                .position(
                    x: localUsableX + usableW / 2.0,
                    y: localUsableY + 40
                )
        }
        .frame(width: display.frameAX.width, height: display.frameAX.height, alignment: .topLeading)
        .toolboxDarkAppearance()
    }

    private func editorZoneCard(_ zone: ResolvedZone) -> some View {
        let localX = zone.frameInAX.minX - display.frameAX.minX
        let localY = zone.frameInAX.minY - display.frameAX.minY
        let width = max(24, zone.frameInAX.width)
        let height = max(24, zone.frameInAX.height)
        let isCustom = (zone.gridCoord == nil)
        let accent: Color = isCustom ? .teal : .indigo

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.16))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ToolboxTheme.readableAccentText(for: accent).opacity(0.88), lineWidth: 2)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(zone.badgeNumber)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(accent.opacity(0.9), in: Circle())
                    Text(zone.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    if isCustom {
                        Button {
                            state.layout.customZones.removeAll { $0.id == zone.id }
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                                .padding(5)
                                .background(Color.red.opacity(0.18), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
                Text("\(Int(round(width))) × \(Int(round(height)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.82))
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
        localUsableX: CGFloat,
        localUsableY: CGFloat,
        usableW: CGFloat,
        usableH: CGFloat
    ) -> some View {
        let weights = state.layout.division.columnWeights
        if weights.count > 1 && !state.isDrawingCustomZone {
            let total = weights.reduce(0, +)
            ForEach(0..<(weights.count - 1), id: \.self) { dividerIndex in
                let fraction = weights.prefix(dividerIndex + 1).reduce(0, +) / total
                let dividerX = localUsableX + CGFloat(fraction) * usableW

                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 22, height: max(80, usableH - 120))
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 5, height: 52)
                        .shadow(color: .black.opacity(0.45), radius: 4)
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
                            let baseWeights = state.activeDividerDragWeights ?? state.layout.division.columnWeights
                            let baseTotal = baseWeights.reduce(0, +)
                            let pairSum = baseWeights[dividerIndex] + baseWeights[dividerIndex + 1]
                            let deltaWeight = Double(value.translation.width / max(100, usableW)) * baseTotal
                            let minW = baseTotal * 0.12
                            let newLeft = min(max(baseWeights[dividerIndex] + deltaWeight, minW), pairSum - minW)
                            let newRight = pairSum - newLeft
                            var updated = baseWeights
                            updated[dividerIndex] = newLeft
                            updated[dividerIndex + 1] = newRight
                            state.layout.division.columnWeights = updated
                            state.layout.presetID = DisplayPresetKind.custom.rawValue
                        }
                        .onEnded { _ in
                            state.activeDividerDragWeights = nil
                        }
                )
            }
        }
    }

    @ViewBuilder
    private func rowDividerHandles(
        localUsableX: CGFloat,
        localUsableY: CGFloat,
        usableW: CGFloat,
        usableH: CGFloat
    ) -> some View {
        let weights = state.layout.division.rowWeights
        if weights.count > 1 && !state.isDrawingCustomZone {
            let total = weights.reduce(0, +)
            ForEach(0..<(weights.count - 1), id: \.self) { dividerIndex in
                let fraction = weights.prefix(dividerIndex + 1).reduce(0, +) / total
                let dividerY = localUsableY + CGFloat(fraction) * usableH

                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: max(80, usableW - 120), height: 22)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 52, height: 5)
                        .shadow(color: .black.opacity(0.45), radius: 4)
                }
                .contentShape(Rectangle())
                .overlay(ResizeCursorOverlay(cursor: .resizeUpDown).allowsHitTesting(false))
                .position(x: localUsableX + usableW / 2.0, y: dividerY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if state.activeDividerDragWeights == nil {
                                state.activeDividerDragWeights = state.layout.division.rowWeights
                            }
                            let baseWeights = state.activeDividerDragWeights ?? state.layout.division.rowWeights
                            let baseTotal = baseWeights.reduce(0, +)
                            let pairSum = baseWeights[dividerIndex] + baseWeights[dividerIndex + 1]
                            let deltaWeight = Double(value.translation.height / max(100, usableH)) * baseTotal
                            let minW = baseTotal * 0.14
                            let newTop = min(max(baseWeights[dividerIndex] + deltaWeight, minW), pairSum - minW)
                            let newBottom = pairSum - newTop
                            var updated = baseWeights
                            updated[dividerIndex] = newTop
                            updated[dividerIndex + 1] = newBottom
                            state.layout.division.rowWeights = updated
                            state.layout.presetID = DisplayPresetKind.custom.rawValue
                        }
                        .onEnded { _ in
                            state.activeDividerDragWeights = nil
                        }
                )
            }
        }
    }

    private func customZoneDrawingSurface(
        localUsableX: CGFloat,
        localUsableY: CGFloat,
        usableW: CGFloat,
        usableH: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Color.teal.opacity(0.06)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            let sx = min(max(value.startLocation.x / usableW, 0), 1)
                            let sy = min(max(value.startLocation.y / usableH, 0), 1)
                            let cx = min(max(value.location.x / usableW, 0), 1)
                            let cy = min(max(value.location.y / usableH, 0), 1)
                            state.drawStartNormalized = CGPoint(x: sx, y: sy)
                            state.drawCurrentNormalized = CGPoint(x: cx, y: cy)
                        }
                        .onEnded { _ in
                            if let s = state.drawStartNormalized, let c = state.drawCurrentNormalized {
                                let nx = min(s.x, c.x)
                                let ny = min(s.y, c.y)
                                let nw = abs(c.x - s.x)
                                let nh = abs(c.y - s.y)
                                if nw >= 0.08 && nh >= 0.08 {
                                    let count = state.layout.customZones.count + 1
                                    let zone = ZoneDefinition(
                                        id: "custom:\(UUID().uuidString.prefix(8))",
                                        name: "Custom \(count)",
                                        normalizedRect: NormalizedRect(x: nx, y: ny, width: nw, height: nh).clamped,
                                        isCustom: true
                                    )
                                    state.layout.customZones.append(zone)
                                }
                            }
                            state.drawStartNormalized = nil
                            state.drawCurrentNormalized = nil
                            state.isDrawingCustomZone = false
                        }
                )

            if let s = state.drawStartNormalized, let c = state.drawCurrentNormalized {
                let rx = min(s.x, c.x) * usableW
                let ry = min(s.y, c.y) * usableH
                let rw = abs(c.x - s.x) * usableW
                let rh = abs(c.y - s.y) * usableH
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.teal.opacity(0.24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.teal, lineWidth: 2)
                    )
                    .frame(width: max(8, rw), height: max(8, rh))
                    .offset(x: rx, y: ry)
            }
        }
        .frame(width: usableW, height: usableH)
        .offset(x: localUsableX, y: localUsableY)
    }

    private var floatingToolbar: some View {
        HStack(spacing: 10) {
            Label(display.signature.localizedName, systemImage: "display")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                Button("- Col") {
                    if state.layout.division.columnWeights.count > 1 {
                        state.layout.division.columnWeights.removeLast()
                        state.layout.presetID = DisplayPresetKind.custom.rawValue
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.layout.division.columnWeights.count <= 1)
                .pointerCursor(state.layout.division.columnWeights.count > 1)

                Button("+ Col") {
                    if state.layout.division.columnWeights.count < 4 {
                        state.layout.division.columnWeights.append(1.0)
                        state.layout.presetID = DisplayPresetKind.custom.rawValue
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.layout.division.columnWeights.count >= 4)
                .pointerCursor(state.layout.division.columnWeights.count < 4)

                Button("- Row") {
                    if state.layout.division.rowWeights.count > 1 {
                        state.layout.division.rowWeights.removeLast()
                        state.layout.presetID = DisplayPresetKind.custom.rawValue
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.layout.division.rowWeights.count <= 1)
                .pointerCursor(state.layout.division.rowWeights.count > 1)

                Button("+ Row") {
                    if state.layout.division.rowWeights.count < 3 {
                        state.layout.division.rowWeights.append(1.0)
                        state.layout.presetID = DisplayPresetKind.custom.rawValue
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.layout.division.rowWeights.count >= 3)
                .pointerCursor(state.layout.division.rowWeights.count < 3)
            }

            Divider().frame(height: 18)

            Button(state.isDrawingCustomZone ? "Drag on Screen…" : "+ Draw Zone") {
                state.isDrawingCustomZone.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()

            Button("Reset") {
                let kind = DisplayPresetKind(rawValue: state.layout.presetID) ?? .halves
                state.layout.division = kind == .custom ? DisplayDivision() : kind.defaultDivision
                state.layout.customZones.removeAll()
                state.isDrawingCustomZone = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()

            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()

            Button("Done (Esc)") {
                onSave(state.layout)
            }
            .buttonStyle(.toolboxProminent)
            .controlSize(.small)
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
}
