import AppKit
import SwiftUI

@MainActor
final class FloatingMicIndicatorState: ObservableObject {
    @Published var isMuted: Bool = false
    @Published var isTypingMuted: Bool = false
    @Published var inputDeviceName: String = "System Microphone"
    @Published var hasInputDevice: Bool = true
    @Published var showVideoStatus: Bool = true
    @Published var isCameraActive: Bool = false
    @Published var cameraDeviceName: String? = nil
    @Published var hasCameraDevice: Bool = true
    @Published var canToggleVideo: Bool = false
    @Published var videoTargetAppName: String? = nil
    @Published var videoUnavailableAppName: String? = nil
    @Published var videoCapableSummary: String = "Teams, Zoom, or Meet"
}

private struct FloatingPillAnchor: Equatable {
    var anchorX: CGFloat
    var topY: CGFloat
    var pinTrailing: Bool
}

private final class FloatingPillNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Positioning is explicitly clamped within visibleFrame using screenPadding.
        frameRect
    }
}

/// Non-activating, draggable floating call status pill that stays visible across spaces,
/// defaults to the top-right corner, remembers dragged positions, and resizes smoothly
/// around its pinned corner without jumping when video status toggles.
@MainActor
final class FloatingMicIndicatorPanel {
    private enum DefaultsKey {
        static let hasCustomPosition = "CallControls.FloatingPill.HasCustomPosition"
        static let anchorX = "CallControls.FloatingPill.AnchorX"
        static let topY = "CallControls.FloatingPill.TopY"
        static let pinTrailing = "CallControls.FloatingPill.PinTrailing"

        static let legacyHasCustomPosition = "AudioGuard.FloatingPill.HasCustomPosition"
        static let legacyAnchorX = "AudioGuard.FloatingPill.AnchorX"
        static let legacyTopY = "AudioGuard.FloatingPill.TopY"
        static let legacyPinTrailing = "AudioGuard.FloatingPill.PinTrailing"
    }

    private static let defaultMarginRight: CGFloat = 18
    private static let defaultMarginTop: CGFloat = 14
    static let screenPadding: CGFloat = 6

    private let userDefaults: UserDefaults?
    private var panel: NSPanel?
    private var customAnchor: FloatingPillAnchor?
    private var isProgrammaticFrameUpdate = false
    private var isResizeScheduled = false
    let state = FloatingMicIndicatorState()

    var onToggleMute: (() -> Void)?
    var onToggleVideo: (() -> Void)?
    var onToggleShowVideo: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onHidePill: (() -> Void)?
    var onFrameChanged: ((NSRect?) -> Void)?

    init(userDefaults: UserDefaults? = FloatingMicIndicatorPanel.defaultUserDefaults()) {
        self.userDefaults = userDefaults
        loadSavedAnchor()
    }

    private static func defaultUserDefaults() -> UserDefaults? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--self-test") || args.contains("--snapshot-ui") {
            return nil
        }
        return .standard
    }

    private static func defaultScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    var currentFrame: NSRect? {
        panel?.frame
    }

    var hasCustomPosition: Bool {
        customAnchor != nil
    }

    static func measuredPillSize(for state: FloatingMicIndicatorState) -> NSSize {
        let view = FloatingMicIndicatorView(state: state)
        let hosting = PointerCursorHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        return NSSize(
            width: max(135, min(460, ceil(fitting.width))),
            height: max(38, min(72, ceil(fitting.height)))
        )
    }

    func update(
        isMuted: Bool,
        isTypingMuted: Bool,
        inputDeviceName: String,
        hasInputDevice: Bool,
        showVideoStatus: Bool,
        isCameraActive: Bool,
        cameraDeviceName: String?,
        hasCameraDevice: Bool,
        canToggleVideo: Bool,
        videoTargetAppName: String? = nil,
        videoUnavailableAppName: String? = nil,
        videoCapableSummary: String = "Teams, Zoom, or Meet"
    ) {
        let layoutAffectingChange =
            state.showVideoStatus != showVideoStatus ||
            state.isCameraActive != isCameraActive ||
            state.isMuted != isMuted ||
            state.isTypingMuted != isTypingMuted ||
            state.inputDeviceName != inputDeviceName ||
            state.cameraDeviceName != cameraDeviceName ||
            state.hasInputDevice != hasInputDevice ||
            state.hasCameraDevice != hasCameraDevice ||
            state.canToggleVideo != canToggleVideo ||
            state.videoTargetAppName != videoTargetAppName ||
            state.videoUnavailableAppName != videoUnavailableAppName

        state.isMuted = isMuted
        state.isTypingMuted = isTypingMuted
        state.inputDeviceName = inputDeviceName
        state.hasInputDevice = hasInputDevice
        state.showVideoStatus = showVideoStatus
        state.isCameraActive = isCameraActive
        state.cameraDeviceName = cameraDeviceName
        state.hasCameraDevice = hasCameraDevice
        state.canToggleVideo = canToggleVideo
        state.videoTargetAppName = videoTargetAppName
        state.videoUnavailableAppName = videoUnavailableAppName
        state.videoCapableSummary = videoCapableSummary

        if layoutAffectingChange, let panel, panel.isVisible {
            scheduleResize(for: panel)
        }
    }

    func show() {
        if let existing = panel {
            scheduleResize(for: existing)
            existing.orderFrontRegardless()
            onFrameChanged?(existing.frame)
            return
        }

        let view = FloatingMicIndicatorView(
            state: state,
            onToggleMute: { [weak self] in self?.onToggleMute?() },
            onToggleVideo: { [weak self] in self?.onToggleVideo?() },
            onToggleShowVideo: { [weak self] in self?.onToggleShowVideo?() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onResetPosition: { [weak self] in self?.resetToDefaultPosition() },
            onHidePill: { [weak self] in self?.onHidePill?() },
            onUserDragged: { [weak self] frame in
                self?.recordUserDraggedFrame(frame)
            }
        )

        let hosting = PointerCursorHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]

        let newPanel = FloatingPillNSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.isReleasedWhenClosed = false
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.level = .statusBar
        newPanel.hidesOnDeactivate = false
        newPanel.acceptsMouseMovedEvents = true
        newPanel.isMovable = true
        newPanel.isMovableByWindowBackground = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.contentView = hosting

        let size = prepareAndMeasureFittingSize(for: newPanel)
        let initialFrame = anchoredFrame(forSize: size, preferredScreen: Self.defaultScreen())
        applyFrame(initialFrame, to: newPanel)
        newPanel.orderFrontRegardless()
        self.panel = newPanel

        // Re-measure on the next runloop turn after SwiftUI finishes initial pass
        scheduleResize(for: newPanel)
    }

    func hide() {
        isResizeScheduled = false
        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel = nil
        onFrameChanged?(nil)
    }

    func resetToDefaultPosition() {
        customAnchor = nil
        clearSavedAnchor()
        guard let panel, panel.isVisible else { return }
        let size = prepareAndMeasureFittingSize(for: panel)
        let targetScreen = Self.defaultScreen() ?? panel.screen
        let nextFrame = anchoredFrame(forSize: size, preferredScreen: targetScreen)
        if !framesApproximatelyEqual(panel.frame, nextFrame) {
            applyFrame(nextFrame, to: panel)
        }
    }

    private func scheduleResize(for targetPanel: NSPanel) {
        guard !isResizeScheduled else { return }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self, weak targetPanel] in
            guard let self, let targetPanel, self.panel === targetPanel else { return }
            self.isResizeScheduled = false
            self.resizePanelToFit(targetPanel)
        }
    }

    private func prepareAndMeasureFittingSize(for targetPanel: NSPanel) -> NSSize {
        guard let hosting = targetPanel.contentView else {
            return targetPanel.frame.size
        }
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        return clampedFittingSize(for: hosting)
    }

    private func resizePanelToFit(_ targetPanel: NSPanel) {
        let size = prepareAndMeasureFittingSize(for: targetPanel)
        let screen = targetPanel.screen ?? Self.defaultScreen()
        let nextFrame = anchoredFrame(forSize: size, preferredScreen: screen)
        if !framesApproximatelyEqual(targetPanel.frame, nextFrame) {
            applyFrame(nextFrame, to: targetPanel)
        }
    }

    private func applyFrame(_ frame: NSRect, to targetPanel: NSPanel) {
        isProgrammaticFrameUpdate = true
        defer { isProgrammaticFrameUpdate = false }
        targetPanel.setFrame(frame, display: true, animate: false)
        if let contentView = targetPanel.contentView {
            targetPanel.invalidateCursorRects(for: contentView)
            targetPanel.resetCursorRects()
        }
        onFrameChanged?(targetPanel.frame)
    }

    private func clampedFittingSize(for view: NSView) -> NSSize {
        let fitting = view.fittingSize
        return NSSize(
            width: max(135, min(460, ceil(fitting.width))),
            height: max(38, min(72, ceil(fitting.height)))
        )
    }

    static func defaultTopRightFrame(for size: NSSize, inVisibleFrame vf: NSRect) -> NSRect {
        let origin = NSPoint(
            x: round(vf.maxX - size.width - Self.defaultMarginRight),
            y: round(vf.maxY - size.height - Self.defaultMarginTop)
        )
        return NSRect(origin: origin, size: size)
    }

    private func anchoredFrame(forSize size: NSSize, preferredScreen: NSScreen?) -> NSRect {
        let screen = screenForCustomAnchor() ?? preferredScreen ?? Self.defaultScreen()
        guard let screen else {
            return NSRect(origin: NSPoint(x: 40, y: 40), size: size)
        }
        let vf = screen.visibleFrame

        if let anchor = customAnchor {
            var x = anchor.pinTrailing ? (anchor.anchorX - size.width) : anchor.anchorX
            var y = anchor.topY - size.height

            let minX = vf.minX + Self.screenPadding
            let maxX = max(minX, vf.maxX - size.width - Self.screenPadding)
            let minY = vf.minY + Self.screenPadding
            let maxY = max(minY, vf.maxY - size.height - Self.screenPadding)

            x = min(max(x, minX), maxX)
            y = min(max(y, minY), maxY)
            return NSRect(origin: NSPoint(x: round(x), y: round(y)), size: size)
        }

        // Default: top-right corner pinned so showing/hiding Video expands inward to the left.
        return Self.defaultTopRightFrame(for: size, inVisibleFrame: vf)
    }

    func recordDraggedFrameForTesting(_ frame: NSRect) {
        recordUserDraggedFrame(frame)
    }

    private func recordUserDraggedFrame(_ frame: NSRect) {
        guard !isProgrammaticFrameUpdate else { return }
        let targetScreen = NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? panel?.screen
            ?? Self.defaultScreen()
        guard let vf = targetScreen?.visibleFrame else { return }

        let roundedFrame = NSRect(
            x: round(frame.origin.x),
            y: round(frame.origin.y),
            width: frame.size.width,
            height: frame.size.height
        )

        // Pin whichever horizontal edge is closer so hiding/showing Video stays anchored nicely.
        let pinTrailing = (roundedFrame.midX >= vf.midX)
        let anchor = FloatingPillAnchor(
            anchorX: pinTrailing ? roundedFrame.maxX : roundedFrame.minX,
            topY: roundedFrame.maxY,
            pinTrailing: pinTrailing
        )
        customAnchor = anchor
        saveAnchor(anchor)
        onFrameChanged?(roundedFrame)
    }

    private func screenForCustomAnchor() -> NSScreen? {
        guard let anchor = customAnchor else { return nil }
        // Step 1pt inward from the pinned edge so an anchor near a shared monitor boundary
        // resolves strictly to the screen containing the pill rather than an adjacent screen.
        let inwardX = anchor.pinTrailing ? (anchor.anchorX - 1) : (anchor.anchorX + 1)
        let probe = NSPoint(x: inwardX, y: anchor.topY - 10)
        return NSScreen.screens.first { $0.frame.contains(probe) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -40, dy: -40).contains(probe) }
    }

    private func loadSavedAnchor() {
        guard let defaults = userDefaults else {
            customAnchor = nil
            return
        }
        if defaults.bool(forKey: DefaultsKey.hasCustomPosition) {
            customAnchor = FloatingPillAnchor(
                anchorX: defaults.double(forKey: DefaultsKey.anchorX),
                topY: defaults.double(forKey: DefaultsKey.topY),
                pinTrailing: defaults.bool(forKey: DefaultsKey.pinTrailing)
            )
        } else if defaults.bool(forKey: DefaultsKey.legacyHasCustomPosition) {
            let migrated = FloatingPillAnchor(
                anchorX: defaults.double(forKey: DefaultsKey.legacyAnchorX),
                topY: defaults.double(forKey: DefaultsKey.legacyTopY),
                pinTrailing: defaults.bool(forKey: DefaultsKey.legacyPinTrailing)
            )
            customAnchor = migrated
            saveAnchor(migrated)
        } else {
            customAnchor = nil
        }
    }

    private func saveAnchor(_ anchor: FloatingPillAnchor) {
        guard let defaults = userDefaults else { return }
        defaults.set(true, forKey: DefaultsKey.hasCustomPosition)
        defaults.set(Double(anchor.anchorX), forKey: DefaultsKey.anchorX)
        defaults.set(Double(anchor.topY), forKey: DefaultsKey.topY)
        defaults.set(anchor.pinTrailing, forKey: DefaultsKey.pinTrailing)
    }

    private func clearSavedAnchor() {
        guard let defaults = userDefaults else { return }
        defaults.removeObject(forKey: DefaultsKey.hasCustomPosition)
        defaults.removeObject(forKey: DefaultsKey.anchorX)
        defaults.removeObject(forKey: DefaultsKey.topY)
        defaults.removeObject(forKey: DefaultsKey.pinTrailing)
        defaults.removeObject(forKey: DefaultsKey.legacyHasCustomPosition)
        defaults.removeObject(forKey: DefaultsKey.legacyAnchorX)
        defaults.removeObject(forKey: DefaultsKey.legacyTopY)
        defaults.removeObject(forKey: DefaultsKey.legacyPinTrailing)
    }

    private func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
        abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
        abs(lhs.size.width - rhs.size.width) < 0.5 &&
        abs(lhs.size.height - rhs.size.height) < 0.5
    }
}

/// AppKit drag surface that moves the enclosing borderless `.nonactivatingPanel`
/// reliably on first click and clamps cleanly within screen visible bounds.
private struct PillDragRegion: NSViewRepresentable {
    var cursor: NSCursor = .openHand
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onDragFinished: (NSRect) -> Void

    func makeNSView(context: Context) -> PillDragNSView {
        let view = PillDragNSView()
        view.dragCursor = cursor
        view.onHoverChanged = onHoverChanged
        view.onDragFinished = onDragFinished
        return view
    }

    func updateNSView(_ nsView: PillDragNSView, context: Context) {
        nsView.dragCursor = cursor
        nsView.onHoverChanged = onHoverChanged
        nsView.onDragFinished = onDragFinished
    }
}

private final class PillDragNSView: NSView, HoverCursorProviderView {
    var dragCursor: NSCursor = .openHand {
        didSet {
            if oldValue !== dragCursor {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var onHoverChanged: ((Bool) -> Void)?
    var onDragFinished: ((NSRect) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var cursorTrackingArea: NSTrackingArea?
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var didMoveDuringDrag = false

    var customHoverCursor: NSCursor {
        dragStartMouseLocation == nil ? dragCursor : .closedHand
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = bounds.size != newSize
        super.setFrameSize(newSize)
        if changed {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !bounds.isEmpty else { return }
        addCursorRect(bounds, cursor: customHoverCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let hoverArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        let cursorArea = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverArea)
        addTrackingArea(cursorArea)
        self.hoverTrackingArea = hoverArea
        self.cursorTrackingArea = cursorArea
    }

    override func mouseEntered(with event: NSEvent) {
        dragCursor.set()
        onHoverChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        if dragStartMouseLocation == nil {
            dragCursor.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if dragStartMouseLocation == nil {
            dragCursor.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if dragStartMouseLocation == nil {
            onHoverChanged?(false)
            if let window {
                let rootView = window.contentView?.superview ?? window.contentView
                let pt = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                if let rootView, PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: pt) {
                    PointerCursorNSView.forcePointingHandCursor()
                } else {
                    NSCursor.arrow.set()
                }
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        didMoveDuringDrag = false
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartWindowOrigin else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        if abs(dx) > 0.5 || abs(dy) > 0.5 {
            didMoveDuringDrag = true
        }

        var nextOrigin = NSPoint(x: round(startOrigin.x + dx), y: round(startOrigin.y + dy))
        let size = window.frame.size
        if let screen = screenContaining(point: currentMouse) ?? window.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let pad = FloatingMicIndicatorPanel.screenPadding
            let minX = vf.minX + pad
            let maxX = max(minX, vf.maxX - size.width - pad)
            let minY = vf.minY + pad
            let maxY = max(minY, vf.maxY - size.height - pad)
            nextOrigin.x = round(min(max(nextOrigin.x, minX), maxX))
            nextOrigin.y = round(min(max(nextOrigin.y, minY), maxY))
        }

        window.setFrameOrigin(nextOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStartMouseLocation != nil {
            NSCursor.pop()
            if didMoveDuringDrag, let window {
                onDragFinished?(window.frame)
            }
        }
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
        didMoveDuringDrag = false
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

@MainActor
private final class PillHoverState: ObservableObject {
    @Published var isHandleHovered = false
    @Published var isMicHovered = false
    @Published var isVideoHovered = false
    @Published var isHideHovered = false
}

struct FloatingMicIndicatorView: View {
    @ObservedObject var state: FloatingMicIndicatorState
    @StateObject private var hoverState = PillHoverState()
    var onToggleMute: () -> Void = {}
    var onToggleVideo: () -> Void = {}
    var onToggleShowVideo: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onResetPosition: () -> Void = {}
    var onHidePill: () -> Void = {}
    var onUserDragged: (NSRect) -> Void = { _ in }

    private var micAccentColor: Color {
        if !state.hasInputDevice { return .secondary }
        if state.isTypingMuted { return .orange }
        return state.isMuted ? .red : .green
    }

    private var micStatusTitle: String {
        if !state.hasInputDevice { return "No Mic" }
        if state.isTypingMuted { return "Typing Mute" }
        return state.isMuted ? "Mic Muted" : "Mic Live"
    }

    private var micSymbolName: String {
        if !state.hasInputDevice { return "mic.slash" }
        if state.isTypingMuted { return "keyboard" }
        return state.isMuted ? "mic.slash.fill" : "mic.fill"
    }

    private var videoAccentColor: Color {
        if !state.hasCameraDevice { return .secondary }
        return state.isCameraActive ? .green : .red
    }

    private var videoStatusTitle: String {
        if !state.hasCameraDevice { return "No Cam" }
        return state.isCameraActive ? "Cam Live" : "Cam Off"
    }

    private var videoSymbolName: String {
        if !state.hasCameraDevice { return "video.slash" }
        return state.isCameraActive ? "video.fill" : "video.slash.fill"
    }

    private var videoChipSubtitle: String {
        if !state.hasCameraDevice { return "No Camera" }
        if state.canToggleVideo {
            if state.isCameraActive {
                return state.cameraDeviceName ?? "Camera On"
            }
            if let appName = state.videoTargetAppName {
                return "Toggle \(CallControlsModule.shortCallAppName(appName))"
            }
            return "Click to Toggle"
        }
        if let unavailable = state.videoUnavailableAppName {
            return "Monitor · \(unavailable)"
        }
        return "Monitor Only"
    }

    private var videoTooltipText: String {
        if state.canToggleVideo {
            return "Click to toggle camera in \(state.videoTargetAppName ?? "call app")"
        }
        if let unavailable = state.videoUnavailableAppName {
            return "Camera monitor only — \(unavailable) has no camera shortcut and macOS has no OS camera mute"
        }
        return "Camera monitor only — macOS has no global camera mute (open \(state.videoCapableSummary) to toggle)"
    }

    private var borderAccentColor: Color {
        if state.isTypingMuted { return .orange }
        if (state.hasInputDevice && !state.isMuted) || (state.showVideoStatus && state.isCameraActive) {
            return .green
        }
        return .red
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(hoverState.isHandleHovered ? 0.10 : 0.0))
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hoverState.isHandleHovered ? .primary : .secondary)
            }
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
            .help("Drag to move floating status pill")
            .overlay(
                PillDragRegion(
                    cursor: .openHand,
                    onHoverChanged: { hovering in hoverState.isHandleHovered = hovering },
                    onDragFinished: onUserDragged
                )
            )

            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 22)

            Button {
                onToggleMute()
            } label: {
                statusChip(
                    symbol: micSymbolName,
                    accent: micAccentColor,
                    title: micStatusTitle,
                    subtitle: state.inputDeviceName,
                    contentMinWidth: 88,
                    subtitleMaxWidth: state.showVideoStatus ? 140 : 165
                )
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(hoverState.isMicHovered ? 0.08 : 0.0))
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!state.hasInputDevice)
            .onHover { hovering in hoverState.isMicHovered = hovering }
            .help(state.isMuted ? "Click to unmute microphone" : "Click to mute microphone")
            .pointerCursor(state.hasInputDevice)

            if state.showVideoStatus {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 1, height: 22)

                Button {
                    onToggleVideo()
                } label: {
                    statusChip(
                        symbol: videoSymbolName,
                        accent: videoAccentColor,
                        title: videoStatusTitle,
                        subtitle: videoChipSubtitle,
                        contentMinWidth: 108,
                        subtitleMaxWidth: 108
                    )
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(hoverState.isVideoHovered ? 0.08 : 0.0))
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in hoverState.isVideoHovered = hovering }
                .help(videoTooltipText)
                .pointerCursor(true)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 22)

            Button {
                onHidePill()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(hoverState.isHideHovered ? 0.10 : 0.0))
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(hoverState.isHideHovered ? .primary : .secondary)
                }
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { hovering in hoverState.isHideHovered = hovering }
            .help("Hide floating status pill")
            .pointerCursor(true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 44)
        .fixedSize()
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(borderAccentColor.opacity(0.38), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .clipShape(Capsule())
        .contextMenu {
            Button(state.isMuted ? "Unmute Microphone" : "Mute Microphone") {
                onToggleMute()
            }
            .disabled(!state.hasInputDevice)

            if state.canToggleVideo {
                Button("Toggle Camera in Call App") {
                    onToggleVideo()
                }
            }

            Divider()

            Button(state.showVideoStatus ? "Hide Video Status from Pill" : "Show Video Status in Pill") {
                onToggleShowVideo()
            }

            Button("Reset Position to Top-Right") {
                onResetPosition()
            }

            Button("Open Call Controls Settings") {
                onOpenSettings()
            }

            Button("Hide Floating Status Pill") {
                onHidePill()
            }
        }
    }

    private func statusChip(
        symbol: String,
        accent: Color,
        title: String,
        subtitle: String,
        contentMinWidth: CGFloat,
        subtitleMaxWidth: CGFloat
    ) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 24, height: 24)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: contentMinWidth, maxWidth: subtitleMaxWidth, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}
