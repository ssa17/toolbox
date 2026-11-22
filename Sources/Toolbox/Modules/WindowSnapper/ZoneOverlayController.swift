import AppKit
import QuartzCore
import SwiftUI

extension OverlayTintColor {
    var swatchColor: Color {
        switch self {
        case .indigo: return .indigo
        case .blue: return .blue
        case .teal: return .teal
        case .purple: return .purple
        case .pink: return .pink
        case .neutral: return .white
        }
    }

    var readableStrokeColor: Color {
        switch self {
        case .neutral:
            return .white
        default:
            return ToolboxTheme.readableAccentText(for: swatchColor)
        }
    }
}

enum ProfileRulePreviewStatus: Equatable, Sendable {
    case ready
    case willLaunch
    case mainDisplayFallback
    case alreadyPlaced
    case notRunningSkipped

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .willLaunch: return "Will launch"
        case .mainDisplayFallback: return "Main display fallback"
        case .alreadyPlaced: return "Already placed"
        case .notRunningSkipped: return "Closed (skip)"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .willLaunch: return "arrow.up.forward.app.fill"
        case .mainDisplayFallback: return "display.trianglebadge.exclamationmark"
        case .alreadyPlaced: return "checkmark.seal.fill"
        case .notRunningSkipped: return "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .indigo
        case .willLaunch: return .orange
        case .mainDisplayFallback: return .teal
        case .alreadyPlaced: return .green
        case .notRunningSkipped: return .secondary
        }
    }
}

struct ProfilePreviewOverlayItem: Equatable, Identifiable, Sendable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let zone: ResolvedZone
    let status: ProfileRulePreviewStatus
}

struct TriggerFlashRegion: Equatable, Identifiable, Sendable {
    let id: String
    let frameAX: CGRect
    let isZeroHairline: Bool
    let cornerRadius: CGFloat
}

enum OverlayDisplayMode: Equatable, Sendable {
    case hidden
    case singleZonePreview(
        zone: ResolvedZone?,
        style: OverlayStyleConfig,
        minSizeWarning: ZoneMinSizeWarning? = nil,
        hintBannerText: String? = nil
    )
    case topEdgeTemplatePicker(
        layout: TopEdgePickerLayout,
        activeSlot: TopEdgePanelSlotKind?,
        hoveredCellIndex: Int?,
        previewZones: [ResolvedZone],
        highlightedZone: ResolvedZone?,
        style: OverlayStyleConfig,
        minSizeWarning: ZoneMinSizeWarning? = nil
    )
    case fullGridDrag(
        zones: [ResolvedZone],
        highlightedZone: ResolvedZone?,
        isSpanning: Bool,
        style: OverlayStyleConfig,
        minSizeWarning: ZoneMinSizeWarning? = nil
    )
    case triggerZoneFlash(
        regions: [TriggerFlashRegion],
        bannerText: String,
        bannerAnchorAX: CGPoint,
        style: OverlayStyleConfig
    )
    case liveSettingsPreview(
        zones: [ResolvedZone],
        displayTitle: String,
        style: OverlayStyleConfig
    )
    case profileDryRun(
        profileName: String,
        items: [ProfilePreviewOverlayItem],
        displayTitle: String,
        style: OverlayStyleConfig
    )
}

@MainActor
final class OverlayPanelState: ObservableObject {
    @Published var mode: OverlayDisplayMode = .hidden
    @Published var displayFrameAX: CGRect = .zero
    @Published var usableAXRect: CGRect = .zero
}

private final class OverlayNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class InteractiveEditorNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class ZoneOverlayController: ObservableObject {
    static let shared = ZoneOverlayController()

    @Published private(set) var isLivePreviewActive: Bool = false
    @Published private(set) var isDryRunPreviewActive: Bool = false
    @Published private(set) var activeDryRunProfileID: String? = nil
    @Published private(set) var isEditingOnScreen: Bool = false
    @Published private(set) var editingDisplayID: CGDirectDisplayID? = nil

    private var passivePanels: [CGDirectDisplayID: (panel: OverlayNSPanel, state: OverlayPanelState)] = [:]
    private var editorPanel: InteractiveEditorNSPanel?
    private var editorEscLocalMonitor: Any?
    private var editorEscGlobalMonitor: Any?
    private var flashGeneration: UInt64 = 0
    private var flashWorkItem: DispatchWorkItem?
    private var previewAutoHideGeneration: UInt64 = 0
    private var previewAutoHideWorkItem: DispatchWorkItem?

    var onBeforeBlockingOverlayShown: (() -> Void)?

    private init() {}

    // MARK: - Passive Preview Control

    func showSingleZoneDragPreview(
        on display: ConnectedDisplay,
        zone: ResolvedZone?,
        style: OverlayStyleConfig,
        minSizeWarning: ZoneMinSizeWarning? = nil,
        hintBannerText: String? = nil
    ) {
        if hasPendingFlashOrFade {
            cancelFlash()
        }
        clearOtherDisplays(except: display.displayID)
        let entry = ensurePassivePanel(for: display)
        let nextMode: OverlayDisplayMode = .singleZonePreview(
            zone: zone,
            style: style,
            minSizeWarning: minSizeWarning,
            hintBannerText: hintBannerText
        )
        if entry.state.displayFrameAX != display.frameAX {
            entry.state.displayFrameAX = display.frameAX
        }
        if entry.state.usableAXRect != display.usableAX {
            entry.state.usableAXRect = display.usableAX
        }
        if entry.state.mode != nextMode {
            entry.state.mode = nextMode
        }
        positionAndShow(entry.panel, for: display)
    }

    func showTopEdgeTemplatePicker(
        on display: ConnectedDisplay,
        layout: TopEdgePickerLayout,
        activeSlot: TopEdgePanelSlotKind?,
        hoveredCellIndex: Int?,
        previewZones: [ResolvedZone],
        highlightedZone: ResolvedZone?,
        style: OverlayStyleConfig,
        minSizeWarning: ZoneMinSizeWarning? = nil
    ) {
        if hasPendingFlashOrFade {
            cancelFlash()
        }
        clearOtherDisplays(except: display.displayID)
        let entry = ensurePassivePanel(for: display)
        let nextMode: OverlayDisplayMode = .topEdgeTemplatePicker(
            layout: layout,
            activeSlot: activeSlot,
            hoveredCellIndex: hoveredCellIndex,
            previewZones: previewZones,
            highlightedZone: highlightedZone,
            style: style,
            minSizeWarning: minSizeWarning
        )
        if entry.state.displayFrameAX != display.frameAX {
            entry.state.displayFrameAX = display.frameAX
        }
        if entry.state.usableAXRect != display.usableAX {
            entry.state.usableAXRect = display.usableAX
        }
        if entry.state.mode != nextMode {
            entry.state.mode = nextMode
        }
        positionAndShow(entry.panel, for: display)
    }

    func showKeyboardSnapPreview(
        on display: ConnectedDisplay,
        zone: ResolvedZone,
        minSizeWarning: ZoneMinSizeWarning?,
        hintText: String,
        style: OverlayStyleConfig
    ) {
        cancelFlash()
        cancelPreviewAutoHide()
        isLivePreviewActive = false
        isDryRunPreviewActive = false
        activeDryRunProfileID = nil
        clearOtherDisplays(except: display.displayID)
        let entry = ensurePassivePanel(for: display)
        entry.state.displayFrameAX = display.frameAX
        entry.state.usableAXRect = display.usableAX
        entry.state.mode = .singleZonePreview(
            zone: zone,
            style: style,
            minSizeWarning: minSizeWarning,
            hintBannerText: hintText
        )
        positionAndShow(entry.panel, for: display)
    }

    func showFullGridDragOverlay(
        on display: ConnectedDisplay,
        zones: [ResolvedZone],
        highlightedZone: ResolvedZone?,
        isSpanning: Bool,
        style: OverlayStyleConfig,
        minSizeWarning: ZoneMinSizeWarning? = nil
    ) {
        if hasPendingFlashOrFade {
            cancelFlash()
        }
        clearOtherDisplays(except: display.displayID)
        let entry = ensurePassivePanel(for: display)
        let nextMode: OverlayDisplayMode = .fullGridDrag(
            zones: zones,
            highlightedZone: highlightedZone,
            isSpanning: isSpanning,
            style: style,
            minSizeWarning: minSizeWarning
        )
        if entry.state.displayFrameAX != display.frameAX {
            entry.state.displayFrameAX = display.frameAX
        }
        if entry.state.usableAXRect != display.usableAX {
            entry.state.usableAXRect = display.usableAX
        }
        if entry.state.mode != nextMode {
            entry.state.mode = nextMode
        }
        positionAndShow(entry.panel, for: display)
    }

    func showLiveSettingsPreview(
        displays: [ConnectedDisplay],
        config: WindowSnapperConfig,
        autoHideAfter: TimeInterval? = 3.0
    ) {
        onBeforeBlockingOverlayShown?()
        cancelFlash()
        cancelPreviewAutoHide()
        isLivePreviewActive = true
        isDryRunPreviewActive = false
        activeDryRunProfileID = nil

        let activeIDs = Set(displays.map(\.displayID))
        hideUnlistedPassivePanels(keeping: activeIDs)

        for display in displays {
            let layout = DisplayRegistry.layout(for: display.signature, in: config.displayLayouts)
            let zones = SnapGeometry.resolveZones(
                layout: layout,
                usableAXRect: display.usableAX,
                primaryScreenHeight: display.primaryScreenHeight,
                gaps: config.gaps
            )
            let entry = ensurePassivePanel(for: display)
            entry.state.displayFrameAX = display.frameAX
            entry.state.usableAXRect = display.usableAX
            entry.state.mode = .liveSettingsPreview(
                zones: zones,
                displayTitle: display.signature.localizedName,
                style: config.overlayStyle
            )
            positionAndShow(entry.panel, for: display)
        }

        schedulePreviewAutoHide(after: autoHideAfter)
    }

    func showLayoutProfilePreview(
        profile: WorkspaceProfile,
        displays: [ConnectedDisplay],
        config: WindowSnapperConfig,
        autoHideAfter: TimeInterval? = 3.0
    ) {
        onBeforeBlockingOverlayShown?()
        cancelFlash()
        cancelPreviewAutoHide()
        isDryRunPreviewActive = true
        isLivePreviewActive = false
        activeDryRunProfileID = profile.id

        let activeIDs = Set(displays.map(\.displayID))
        hideUnlistedPassivePanels(keeping: activeIDs)

        for display in displays {
            let layout = DisplayRegistry.layout(
                for: display.signature,
                in: config.displayLayouts,
                overrides: profile.displayLayoutOverrides
            )
            let zones = SnapGeometry.resolveZones(
                layout: layout,
                usableAXRect: display.usableAX,
                primaryScreenHeight: display.primaryScreenHeight,
                gaps: config.gaps
            )
            let entry = ensurePassivePanel(for: display)
            entry.state.displayFrameAX = display.frameAX
            entry.state.usableAXRect = display.usableAX
            entry.state.mode = .liveSettingsPreview(
                zones: zones,
                displayTitle: "Profile: \(profile.name) · \(display.signature.localizedName)",
                style: config.overlayStyle
            )
            positionAndShow(entry.panel, for: display)
        }

        schedulePreviewAutoHide(after: autoHideAfter)
    }

    func showProfileDryRunPreview(
        profile: WorkspaceProfile,
        itemsByDisplay: [CGDirectDisplayID: [ProfilePreviewOverlayItem]],
        displays: [ConnectedDisplay],
        style: OverlayStyleConfig,
        autoHideAfter: TimeInterval? = 3.0
    ) {
        onBeforeBlockingOverlayShown?()
        cancelFlash()
        cancelPreviewAutoHide()
        isDryRunPreviewActive = true
        isLivePreviewActive = false
        activeDryRunProfileID = profile.id

        let activeIDs = Set(displays.map(\.displayID))
        hideUnlistedPassivePanels(keeping: activeIDs)

        for display in displays {
            let items = itemsByDisplay[display.displayID] ?? []
            let entry = ensurePassivePanel(for: display)
            entry.state.displayFrameAX = display.frameAX
            entry.state.usableAXRect = display.usableAX
            if items.isEmpty {
                entry.state.mode = .hidden
                entry.panel.orderOut(nil)
            } else {
                entry.state.mode = .profileDryRun(
                    profileName: profile.name,
                    items: items,
                    displayTitle: display.signature.localizedName,
                    style: style
                )
                positionAndShow(entry.panel, for: display)
            }
        }

        schedulePreviewAutoHide(after: autoHideAfter)
    }

    func flashZone(
        _ zone: ResolvedZone,
        on display: ConnectedDisplay,
        style: OverlayStyleConfig,
        duration: TimeInterval = 0.18
    ) {
        guard !isLivePreviewActive, !isDryRunPreviewActive, !isEditingOnScreen else { return }

        showSingleZoneDragPreview(
            on: display,
            zone: zone,
            style: style
        )

        flashGeneration &+= 1
        let gen = flashGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.flashGeneration == gen else { return }
                self.hideDragOverlays()
            }
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func flashTriggerZones(
        on displays: [ConnectedDisplay],
        regionsProvider: (ConnectedDisplay) -> (regions: [TriggerFlashRegion], bannerAnchorAX: CGPoint),
        bannerText: String,
        style: OverlayStyleConfig,
        holdDuration: TimeInterval = 0.65,
        fadeDuration: TimeInterval = 0.28
    ) {
        guard !isLivePreviewActive, !isDryRunPreviewActive, !isEditingOnScreen else { return }

        cancelFlash()
        let activeIDs = Set(displays.map(\.displayID))
        hideUnlistedPassivePanels(keeping: activeIDs)
        guard !displays.isEmpty else { return }

        for display in displays {
            let payload = regionsProvider(display)
            let entry = ensurePassivePanel(for: display)
            if entry.state.displayFrameAX != display.frameAX {
                entry.state.displayFrameAX = display.frameAX
            }
            if entry.state.usableAXRect != display.usableAX {
                entry.state.usableAXRect = display.usableAX
            }
            entry.state.mode = .triggerZoneFlash(
                regions: payload.regions,
                bannerText: bannerText,
                bannerAnchorAX: payload.bannerAnchorAX,
                style: style
            )
            resetPanelAlphaImmediate([entry.panel])
            positionAndShow(entry.panel, for: display)
        }

        flashGeneration &+= 1
        let gen = flashGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.flashGeneration == gen else { return }
                guard fadeDuration > 0.01 else {
                    self.hideDragOverlays()
                    return
                }
                let fadingPanels = self.passivePanels.values.compactMap { entry -> OverlayNSPanel? in
                    guard entry.panel.isVisible else { return nil }
                    return entry.panel
                }
                guard !fadingPanels.isEmpty else {
                    self.hideDragOverlays()
                    return
                }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = fadeDuration
                    context.allowsImplicitAnimation = true
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for panel in fadingPanels {
                        panel.animator().alphaValue = 0.0
                    }
                }, completionHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.flashGeneration == gen else { return }
                        self.hideDragOverlays()
                    }
                })
            }
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: work)
    }

    func hideDragOverlays() {
        invalidateFlashTimerOnly()
        if isLivePreviewActive || isDryRunPreviewActive {
            return
        }
        for (_, entry) in passivePanels {
            if entry.panel.isVisible {
                entry.panel.orderOut(nil)
            }
            if entry.state.mode != .hidden {
                entry.state.mode = .hidden
            }
            if entry.panel.alphaValue < 0.999 {
                resetPanelAlphaImmediate([entry.panel])
            }
        }
    }

    func hideAllPreviews() {
        invalidateFlashTimerOnly()
        cancelPreviewAutoHide()
        isLivePreviewActive = false
        isDryRunPreviewActive = false
        activeDryRunProfileID = nil
        for (_, entry) in passivePanels {
            if entry.panel.isVisible {
                entry.panel.orderOut(nil)
            }
            if entry.state.mode != .hidden {
                entry.state.mode = .hidden
            }
            if entry.panel.alphaValue < 0.999 {
                resetPanelAlphaImmediate([entry.panel])
            }
        }
    }

    // MARK: - 1:1 Interactive On-Screen Editor

    func beginOnScreenEditor(
        for display: ConnectedDisplay,
        initialLayout: DisplayLayoutConfig,
        gaps: GapConfig,
        onCommitLayout: @escaping (DisplayLayoutConfig) -> Void
    ) {
        onBeforeBlockingOverlayShown?()
        endOnScreenEditor()
        hideAllPreviews()

        isEditingOnScreen = true
        editingDisplayID = display.displayID

        let panel = InteractiveEditorNSPanel(
            contentRect: display.frameAppKit,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ToolboxTheme.applyDarkAppearance(to: panel)

        let editorView = ZoneOnScreenEditorView(
            display: display,
            initialLayout: initialLayout,
            gaps: gaps,
            onSave: { [weak self] updated in
                onCommitLayout(updated)
                self?.endOnScreenEditor()
            },
            onCancel: { [weak self] in
                self?.endOnScreenEditor()
            }
        )
        let hosting = PointerCursorHostingView(rootView: editorView)
        hosting.frame = NSRect(origin: .zero, size: display.frameAppKit.size)
        panel.contentView = hosting
        panel.setFrame(display.frameAppKit, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.editorPanel = panel

        editorEscLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.endOnScreenEditor()
                return nil
            }
            return event
        }
        editorEscGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.endOnScreenEditor()
            }
        }
    }

    func endOnScreenEditor() {
        if let editorEscLocalMonitor {
            NSEvent.removeMonitor(editorEscLocalMonitor)
            self.editorEscLocalMonitor = nil
        }
        if let editorEscGlobalMonitor {
            NSEvent.removeMonitor(editorEscGlobalMonitor)
            self.editorEscGlobalMonitor = nil
        }
        editorPanel?.orderOut(nil)
        editorPanel = nil
        isEditingOnScreen = false
        editingDisplayID = nil
        PointerCursorNSView.syncVisibleWindowUnderMouseOrResetCursor()
    }

    // MARK: - Panel Management

    private var hasPendingFlashOrFade: Bool {
        flashWorkItem != nil || passivePanels.values.contains { $0.panel.alphaValue < 0.999 }
    }

    private func resetPanelAlphaImmediate(_ panels: [OverlayNSPanel]) {
        guard panels.contains(where: { $0.alphaValue < 0.999 }) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for panel in panels {
                panel.animator().alphaValue = 1.0
                panel.alphaValue = 1.0
            }
        }
    }

    private func invalidateFlashTimerOnly() {
        flashGeneration &+= 1
        flashWorkItem?.cancel()
        flashWorkItem = nil
    }

    private func cancelFlash() {
        invalidateFlashTimerOnly()
        resetPanelAlphaImmediate(passivePanels.values.map(\.panel))
    }

    private func cancelPreviewAutoHide() {
        previewAutoHideGeneration &+= 1
        previewAutoHideWorkItem?.cancel()
        previewAutoHideWorkItem = nil
    }

    private func schedulePreviewAutoHide(after delay: TimeInterval?) {
        guard let delay, delay > 0 else { return }
        let gen = previewAutoHideGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.previewAutoHideGeneration == gen else { return }
                self.hideAllPreviews()
            }
        }
        previewAutoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ensurePassivePanel(for display: ConnectedDisplay) -> (panel: OverlayNSPanel, state: OverlayPanelState) {
        if let existing = passivePanels[display.displayID] {
            return existing
        }

        let state = OverlayPanelState()
        state.displayFrameAX = display.frameAX
        state.usableAXRect = display.usableAX

        let panel = OverlayNSPanel(
            contentRect: display.frameAppKit,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ToolboxTheme.applyDarkAppearance(to: panel)

        let rootView = OverlayPanelContainerView(state: state)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: display.frameAppKit.size)
        panel.contentView = hosting

        let entry = (panel: panel, state: state)
        passivePanels[display.displayID] = entry
        return entry
    }

    private func positionAndShow(_ panel: OverlayNSPanel, for display: ConnectedDisplay) {
        if panel.alphaValue < 0.999 {
            resetPanelAlphaImmediate([panel])
        }
        if panel.frame != display.frameAppKit {
            panel.setFrame(display.frameAppKit, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func clearOtherDisplays(except activeDisplayID: CGDirectDisplayID) {
        for (id, entry) in passivePanels where id != activeDisplayID {
            if entry.state.mode != .hidden {
                entry.state.mode = .hidden
            }
            if entry.panel.isVisible {
                entry.panel.orderOut(nil)
            }
        }
    }

    private func hideUnlistedPassivePanels(keeping activeIDs: Set<CGDirectDisplayID>) {
        for (id, entry) in passivePanels where !activeIDs.contains(id) {
            if entry.state.mode != .hidden {
                entry.state.mode = .hidden
            }
            if entry.panel.isVisible {
                entry.panel.orderOut(nil)
            }
        }
    }

    internal var passivePanelCountForTesting: Int {
        passivePanels.count
    }

    internal func anyPassivePanelIsVisibleForTesting() -> Bool {
        passivePanels.values.contains { $0.panel.isVisible }
    }
}

private struct OverlayPanelContainerView: View {
    @ObservedObject var state: OverlayPanelState

    var body: some View {
        ZoneOverlayPreviewCanvasView(
            mode: state.mode,
            displayFrameAX: state.displayFrameAX,
            usableAXRect: state.usableAXRect
        )
        .frame(
            width: max(1, state.displayFrameAX.width),
            height: max(1, state.displayFrameAX.height)
        )
        .toolboxDarkAppearance()
    }
}

struct ZoneOverlayPreviewCanvasView: View {
    let mode: OverlayDisplayMode
    let displayFrameAX: CGRect
    let usableAXRect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            switch mode {
            case .hidden:
                EmptyView()

            case .singleZonePreview(let zone, let style, let minSizeWarning, let hintBannerText):
                if let zone {
                    if let minSizeWarning,
                       Self.clampedFootprintDiffers(minSizeWarning.clampedFrameAX, from: zone.frameInAX) {
                        minSizeClampedFootprintView(
                            clampedFrameAX: minSizeWarning.clampedFrameAX,
                            cornerRadius: CGFloat(style.cornerRadiusPoints)
                        )
                    }

                    zoneOutlineView(
                        zone: zone,
                        isHighlighted: true,
                        showBadges: style.showZoneLabelsAndDimensions,
                        style: style,
                        isDashed: false,
                        minSizeWarning: minSizeWarning
                    )
                    .animation(.easeOut(duration: 0.12), value: zone.frameInAX)
                }

                if let hintBannerText {
                    bannerPill(
                        icon: "keyboard",
                        text: hintBannerText,
                        tint: minSizeWarning != nil ? .orange : style.tintColor.swatchColor
                    )
                }

            case .topEdgeTemplatePicker(let layout, let activeSlot, let hoveredCellIndex, _, let highlightedZone, let style, let minSizeWarning):
                if activeSlot != nil, let highlighted = highlightedZone {
                    if let minSizeWarning,
                       Self.clampedFootprintDiffers(minSizeWarning.clampedFrameAX, from: highlighted.frameInAX) {
                        minSizeClampedFootprintView(
                            clampedFrameAX: minSizeWarning.clampedFrameAX,
                            cornerRadius: CGFloat(style.cornerRadiusPoints)
                        )
                    }

                    zoneOutlineView(
                        zone: highlighted,
                        isHighlighted: true,
                        showBadges: style.showZoneLabelsAndDimensions,
                        style: style,
                        isDashed: false,
                        minSizeWarning: minSizeWarning
                    )
                    .animation(.easeOut(duration: 0.12), value: highlighted.frameInAX)
                }

                topEdgeTemplatePickerView(
                    layout: layout,
                    activeSlot: activeSlot,
                    hoveredCellIndex: hoveredCellIndex,
                    highlightedZone: highlightedZone,
                    style: style
                )

            case .fullGridDrag(let zones, let highlightedZone, let isSpanning, let style, let minSizeWarning):
                if let highlighted = highlightedZone,
                   let minSizeWarning,
                   Self.clampedFootprintDiffers(minSizeWarning.clampedFrameAX, from: highlighted.frameInAX) {
                    minSizeClampedFootprintView(
                        clampedFrameAX: minSizeWarning.clampedFrameAX,
                        cornerRadius: CGFloat(style.cornerRadiusPoints)
                    )
                }

                ForEach(zones) { zone in
                    let isCoveredByHighlight: Bool = {
                        guard let hi = highlightedZone else { return false }
                        if hi.id == zone.id { return true }
                        let intersection = hi.frameInAX.intersection(zone.frameInAX)
                        return !intersection.isNull && intersection.width > 10 && intersection.height > 10
                    }()
                    let cellWarning: ZoneMinSizeWarning? = (!isSpanning && highlightedZone?.id == zone.id) ? minSizeWarning : nil

                    zoneOutlineView(
                        zone: zone,
                        isHighlighted: isCoveredByHighlight && !isSpanning,
                        showBadges: style.showZoneLabelsAndDimensions,
                        style: style,
                        isDashed: !isCoveredByHighlight,
                        minSizeWarning: cellWarning
                    )
                }

                if let highlighted = highlightedZone, isSpanning {
                    zoneOutlineView(
                        zone: highlighted,
                        isHighlighted: true,
                        showBadges: style.showZoneLabelsAndDimensions,
                        style: style,
                        isDashed: false,
                        minSizeWarning: minSizeWarning
                    )
                    .animation(.easeOut(duration: 0.12), value: highlighted.frameInAX)
                }

            case .triggerZoneFlash(let regions, let bannerText, let bannerAnchorAX, let style):
                let tint = baseTint(style: style)
                let strokeColor = style.tintColor.readableStrokeColor

                ForEach(regions) { region in
                    let localX = region.frameAX.minX - displayFrameAX.minX
                    let localY = region.frameAX.minY - displayFrameAX.minY
                    let w = max(2, region.frameAX.width)
                    let h = max(2, region.frameAX.height)

                    Group {
                        if region.isZeroHairline {
                            RoundedRectangle(cornerRadius: region.cornerRadius, style: .continuous)
                                .fill(strokeColor.opacity(0.88))
                                .shadow(color: tint.opacity(0.55), radius: 6)
                        } else {
                            RoundedRectangle(cornerRadius: region.cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.26))
                                .overlay(
                                    RoundedRectangle(cornerRadius: region.cornerRadius, style: .continuous)
                                        .strokeBorder(strokeColor.opacity(0.92), lineWidth: 1.5)
                                )
                                .shadow(color: tint.opacity(0.35), radius: 8)
                        }
                    }
                    .frame(width: w, height: h)
                    .offset(x: localX, y: localY)
                }
                .animation(.easeOut(duration: 0.14), value: regions)

                let rawLocalX = bannerAnchorAX.x - displayFrameAX.minX
                let rawLocalY = bannerAnchorAX.y - displayFrameAX.minY
                let marginX = min(120, max(20, usableAXRect.width * 0.35))
                let minLocalX = (usableAXRect.minX - displayFrameAX.minX) + marginX
                let maxLocalX = max(minLocalX, (usableAXRect.maxX - displayFrameAX.minX) - marginX)
                let minLocalY = (usableAXRect.minY - displayFrameAX.minY) + 22
                let maxLocalY = max(minLocalY, (usableAXRect.maxY - displayFrameAX.minY) - 24)
                let clampedX = min(max(rawLocalX, minLocalX), maxLocalX)
                let clampedY = min(max(rawLocalY, minLocalY), maxLocalY)

                HStack(spacing: 6) {
                    Circle()
                        .fill(strokeColor)
                        .frame(width: 6, height: 6)
                    Text(bannerText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThickMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .position(x: clampedX, y: clampedY)

            case .liveSettingsPreview(let zones, let displayTitle, let style):
                ForEach(zones) { zone in
                    zoneOutlineView(
                        zone: zone,
                        isHighlighted: false,
                        showBadges: true,
                        style: style,
                        isDashed: false,
                        isSettingsLiveMode: true
                    )
                }

                bannerPill(
                    icon: "rectangle.3.group",
                    text: "Live Preview: \(displayTitle)",
                    tint: .indigo
                )

            case .profileDryRun(let profileName, let items, let displayTitle, let style):
                ForEach(items) { item in
                    profileDryRunZoneView(item: item, style: style)
                }

                bannerPill(
                    icon: "sparkles.rectangle.stack",
                    text: "Profile Dry-Run: \(profileName) (\(displayTitle))",
                    tint: .indigo
                )
            }
        }
        .frame(
            width: max(1, displayFrameAX.width),
            height: max(1, displayFrameAX.height),
            alignment: .topLeading
        )
    }

    private func baseTint(style: OverlayStyleConfig) -> Color {
        style.tintColor.swatchColor
    }

    private static func clampedFootprintDiffers(_ clampedAX: CGRect, from targetAX: CGRect) -> Bool {
        abs(clampedAX.width - targetAX.width) > 2.0
            || abs(clampedAX.height - targetAX.height) > 2.0
            || abs(clampedAX.minX - targetAX.minX) > 2.0
            || abs(clampedAX.minY - targetAX.minY) > 2.0
    }

    private func minSizeClampedFootprintView(clampedFrameAX: CGRect, cornerRadius: CGFloat) -> some View {
        let localX = clampedFrameAX.minX - displayFrameAX.minX
        let localY = clampedFrameAX.minY - displayFrameAX.minY
        let width = max(20, clampedFrameAX.width)
        let height = max(20, clampedFrameAX.height)
        let readableOrange = ToolboxTheme.readableAccentText(for: .orange)

        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.orange.opacity(0.08))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    readableOrange.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            Text("Actual \(Int(round(width)))×\(Int(round(height)))")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(readableOrange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThickMaterial, in: Capsule())
                .padding(10)
        }
        .frame(width: width, height: height)
        .offset(x: localX, y: localY)
    }

    private func zoneOutlineView(
        zone: ResolvedZone,
        isHighlighted: Bool,
        showBadges: Bool,
        style: OverlayStyleConfig,
        isDashed: Bool,
        isSettingsLiveMode: Bool = false,
        minSizeWarning: ZoneMinSizeWarning? = nil
    ) -> some View {
        let localX = zone.frameInAX.minX - displayFrameAX.minX
        let localY = zone.frameInAX.minY - displayFrameAX.minY
        let width = max(20, zone.frameInAX.width)
        let height = max(20, zone.frameInAX.height)
        let hasWarning = isHighlighted && minSizeWarning != nil
        let tint: Color = hasWarning ? .orange : baseTint(style: style)
        let fillAlpha: Double = {
            if style.fillOpacity <= 0.001 {
                return 0.0
            }
            return isHighlighted
                ? min(0.45, style.fillOpacity * 1.45)
                : (isSettingsLiveMode ? max(0.10, style.fillOpacity * 0.8) : max(0.05, style.fillOpacity * 0.45))
        }()
        let radius = CGFloat(style.cornerRadiusPoints)
        let strokeWidth = CGFloat(isHighlighted ? max(1.0, style.borderWidthPoints) : max(1.0, style.borderWidthPoints * 0.7))
        let readableTint = hasWarning
            ? ToolboxTheme.readableAccentText(for: .orange)
            : style.tintColor.readableStrokeColor

        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint.opacity(fillAlpha))

            if isDashed {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        readableTint.opacity(0.65),
                        style: StrokeStyle(lineWidth: strokeWidth, dash: [7, 5])
                    )
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        readableTint.opacity(isHighlighted ? 0.96 : 0.72),
                        lineWidth: strokeWidth
                    )
            }

            if showBadges || hasWarning {
                VStack(spacing: 6) {
                    if showBadges {
                        HStack(spacing: 6) {
                            if zone.badgeNumber > 0 {
                                Text("\(zone.badgeNumber)")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(tint.opacity(0.85), in: Circle())
                            }
                            Text(zone.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        Text("\(Int(round(width))) × \(Int(round(height)))")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.84))

                        if !zone.shortcut.isEmpty {
                            ShortcutPill(shortcut: zone.shortcut)
                        }
                    }

                    if hasWarning, let minSizeWarning {
                        Label(minSizeWarning.badgeText, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ToolboxTheme.readableAccentText(for: .orange))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder((hasWarning ? Color.orange : Color.white).opacity(0.24), lineWidth: 0.75)
                )
            }
        }
        .frame(width: width, height: height)
        .offset(x: localX, y: localY)
    }

    private func profileDryRunZoneView(
        item: ProfilePreviewOverlayItem,
        style: OverlayStyleConfig
    ) -> some View {
        let localX = item.zone.frameInAX.minX - displayFrameAX.minX
        let localY = item.zone.frameInAX.minY - displayFrameAX.minY
        let width = max(40, item.zone.frameInAX.width)
        let height = max(40, item.zone.frameInAX.height)
        let statusColor = item.status.color
        let radius = CGFloat(style.cornerRadiusPoints)
        let appIcon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier).map {
            NSWorkspace.shared.icon(forFile: $0.path)
        }

        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(statusColor.opacity(style.fillOpacity <= 0.001 ? 0.0 : max(0.12, style.fillOpacity)))

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    ToolboxTheme.readableAccentText(for: statusColor).opacity(0.88),
                    lineWidth: CGFloat(max(1.0, style.borderWidthPoints))
                )

            VStack(spacing: 8) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "macwindow")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Text(item.appName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(item.zone.name) · \(Int(round(width))) × \(Int(round(height)))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.78))

                HStack(spacing: 5) {
                    Image(systemName: item.status.symbolName)
                        .font(.caption2.weight(.bold))
                    Text(item.status.label)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(ToolboxTheme.readableAccentText(for: statusColor))
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(statusColor.opacity(0.20), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(statusColor.opacity(0.42), lineWidth: 0.75)
                )
            }
            .padding(14)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
            )
        }
        .frame(width: width, height: height)
        .offset(x: localX, y: localY)
    }

    private func topEdgeTemplatePickerView(
        layout: TopEdgePickerLayout,
        activeSlot: TopEdgePanelSlotKind?,
        hoveredCellIndex: Int?,
        highlightedZone: ResolvedZone?,
        style: OverlayStyleConfig
    ) -> some View {
        let localX = layout.pickerFrameAX.minX - displayFrameAX.minX
        let localY = layout.pickerFrameAX.minY - displayFrameAX.minY
        let pillW = max(80, layout.pickerFrameAX.width)
        let pillH = max(40, layout.pickerFrameAX.height)
        let tint = baseTint(style: style)
        let strokeColor = style.tintColor.readableStrokeColor

        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .frame(width: pillW, height: pillH)
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 6)

                if let leftDividerX = layout.leftDividerX {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: pillH - 22)
                        .offset(
                            x: (leftDividerX - layout.pickerFrameAX.minX) - 0.5,
                            y: 11
                        )
                }

                if let rightDividerX = layout.rightDividerX {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: pillH - 22)
                        .offset(
                            x: (rightDividerX - layout.pickerFrameAX.minX) - 0.5,
                            y: 11
                        )
                }

                ForEach(layout.slots) { slotFrame in
                    let isActive = slotFrame.item.kind == activeSlot
                    let slotX = slotFrame.frameAX.minX - layout.pickerFrameAX.minX
                    let slotY = slotFrame.frameAX.minY - layout.pickerFrameAX.minY

                    TopEdgePickerSlotTile(
                        kind: slotFrame.item.kind,
                        isActive: isActive,
                        hoveredCellIndex: isActive ? hoveredCellIndex : nil,
                        tint: tint,
                        strokeColor: strokeColor
                    )
                    .frame(width: slotFrame.frameAX.width, height: slotFrame.frameAX.height)
                    .offset(x: slotX, y: slotY)
                }
            }
            .frame(width: pillW, height: pillH, alignment: .topLeading)
            .offset(x: localX, y: localY)
            .animation(.easeOut(duration: 0.12), value: activeSlot)
            .animation(.easeOut(duration: 0.08), value: hoveredCellIndex)

            if let activeSlot {
                let captionText: String = {
                    switch activeSlot {
                    case .maximize:
                        return "Maximize · Release to fill screen"
                    case .template(let preset):
                        if let highlightedZone {
                            return "\(preset.label) · \(highlightedZone.name) · Release to snap"
                        }
                        return "\(preset.label) · Hover a cell and release"
                    }
                }()
                let centerX = (layout.maximizeSlot?.frameAX.midX ?? layout.pickerFrameAX.midX) - displayFrameAX.minX
                let pillTopY = (layout.pickerFrameAX.maxY - displayFrameAX.minY) + 8

                HStack(spacing: 6) {
                    Circle()
                        .fill(strokeColor)
                        .frame(width: 6, height: 6)
                    Text(captionText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThickMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .position(x: centerX, y: pillTopY + 12)
            }
        }
    }

    private func bannerPill(icon: String, text: String, tint: Color) -> some View {
        let localCenterX = (usableAXRect.midX - displayFrameAX.minX)
        let localY = (usableAXRect.minY - displayFrameAX.minY) + 14

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToolboxTheme.readableAccentText(for: tint))
            Text(text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .position(x: localCenterX, y: localY + 14)
    }
}

struct TopEdgePickerSlotTile: View {
    let kind: TopEdgePanelSlotKind
    let isActive: Bool
    var hoveredCellIndex: Int? = nil
    let tint: Color
    let strokeColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? tint.opacity(0.18) : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isActive ? strokeColor.opacity(0.72) : Color.white.opacity(0.18),
                            lineWidth: isActive ? 1.25 : 0.75
                        )
                )

            switch kind {
            case .maximize:
                GeometryReader { geo in
                    let pad = TopEdgePanelGeometry.slotInnerPadding
                    let innerW = max(12, geo.size.width - pad * 2)
                    let innerH = max(12, geo.size.height - pad * 2)
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(isActive ? tint.opacity(0.80) : Color.white.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(
                                    isActive ? strokeColor : Color.white.opacity(0.42),
                                    lineWidth: isActive ? 1.25 : 1.0
                                )
                        )
                        .overlay(
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(isActive ? .white : Color.white.opacity(0.86))
                        )
                        .frame(width: innerW, height: innerH)
                        .offset(x: pad, y: pad)
                }

            case .template(let preset):
                TemplateMiniThumbnailView(
                    preset: preset,
                    cellFill: isActive ? Color.white.opacity(0.22) : Color.white.opacity(0.30),
                    cellStroke: isActive ? Color.white.opacity(0.32) : Color.white.opacity(0.35),
                    highlightedCellIndex: isActive ? hoveredCellIndex : nil,
                    highlightedCellFill: tint == .white ? Color.white.opacity(0.90) : strokeColor.opacity(0.92),
                    highlightedCellStroke: Color.white.opacity(0.95),
                    padding: TopEdgePanelGeometry.slotInnerPadding,
                    cellGap: TopEdgePanelGeometry.miniCellGap
                )
            }
        }
    }
}

struct TemplateMiniThumbnailView: View {
    let preset: DisplayPresetKind
    var cellFill: Color = Color.white.opacity(0.45)
    var cellStroke: Color = Color.white.opacity(0.35)
    var highlightedCellIndex: Int? = nil
    var highlightedCellFill: Color = .indigo
    var highlightedCellStroke: Color = .white
    var padding: CGFloat = 4
    var cellGap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let innerW = max(4, geo.size.width - padding * 2)
            let innerH = max(4, geo.size.height - padding * 2)
            ForEach(Array(preset.templatePreviewRects.enumerated()), id: \.offset) { idx, rawRect in
                let isCellHighlighted = (highlightedCellIndex == idx)
                let nr = rawRect.clamped
                let cellW = max(3, CGFloat(nr.width) * innerW - cellGap * 2)
                let cellH = max(3, CGFloat(nr.height) * innerH - cellGap * 2)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(isCellHighlighted ? highlightedCellFill : cellFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(
                                isCellHighlighted ? highlightedCellStroke : cellStroke,
                                lineWidth: isCellHighlighted ? 1.25 : 0.5
                            )
                    )
                    .frame(width: cellW, height: cellH)
                    .offset(
                        x: padding + CGFloat(nr.x) * innerW + cellGap,
                        y: padding + CGFloat(nr.y) * innerH + cellGap
                    )
            }
        }
    }
}
