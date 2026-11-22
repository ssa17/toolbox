import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

struct GlassPaneItem: Equatable, Identifiable, Sendable {
    let id: String
    let zone: ResolvedZone
}

/// Pure, testable session state for post-snap frosted glass panes.
struct GlassPaneSessionState: Equatable, Sendable {
    var panes: [GlassPaneItem] = []
    var activePaneID: String? = nil
    var excludedPIDs: Set<pid_t> = []
    var excludedWindowNumbers: Set<Int> = []
    var excludedCandidateIDs: Set<String> = []
    var candidates: [AppCardCandidate] = []

    var isActive: Bool { !panes.isEmpty }

    var activePane: GlassPaneItem? {
        guard let activePaneID else { return nil }
        return panes.first { $0.id == activePaneID }
    }

    static func begin(
        remainingZones: [ResolvedZone],
        snappedWindowNumber: Int?,
        snappedCandidateID: String? = nil,
        occupiedWindowNumbers: Set<Int> = [],
        selfPID: pid_t,
        initialCandidates: [AppCardCandidate],
        ignoredBundleIDs: Set<String> = []
    ) -> GlassPaneSessionState {
        guard !remainingZones.isEmpty else {
            return GlassPaneSessionState()
        }
        let items = remainingZones.map { GlassPaneItem(id: $0.id, zone: $0) }
        let excludedPIDs: Set<pid_t> = selfPID != 0 ? [selfPID] : []
        var excludedWinNums = occupiedWindowNumbers
        if let snappedWindowNumber {
            excludedWinNums.insert(snappedWindowNumber)
        }
        var excludedIDs: Set<String> = []
        if let snappedCandidateID, !snappedCandidateID.isEmpty {
            excludedIDs.insert(snappedCandidateID)
        }
        let filtered = AppCardLayoutEngine.dedupeAndFilterCandidates(
            initialCandidates,
            excludingPIDs: excludedPIDs,
            excludingWindowNumbers: excludedWinNums,
            excludingCandidateIDs: excludedIDs,
            ignoredBundleIDs: ignoredBundleIDs
        )
        return GlassPaneSessionState(
            panes: items,
            activePaneID: items.count == 1 ? items[0].id : nil,
            excludedPIDs: excludedPIDs,
            excludedWindowNumbers: excludedWinNums,
            excludedCandidateIDs: excludedIDs,
            candidates: filtered
        )
    }

    mutating func activatePane(id: String) {
        guard panes.contains(where: { $0.id == id }) else { return }
        activePaneID = id
    }

    mutating func completePlacement(paneID: String, placedCandidate: AppCardCandidate) {
        panes.removeAll { $0.id == paneID }
        if let winNum = placedCandidate.windowNumber {
            excludedWindowNumbers.insert(winNum)
        }
        excludedCandidateIDs.insert(placedCandidate.id)
        candidates.removeAll { candidate in
            if excludedCandidateIDs.contains(candidate.id) { return true }
            if let winNum = candidate.windowNumber, excludedWindowNumbers.contains(winNum) { return true }
            return false
        }

        if panes.isEmpty {
            activePaneID = nil
        } else if panes.count == 1 {
            activePaneID = panes[0].id
        } else if activePaneID == paneID || !panes.contains(where: { $0.id == activePaneID }) {
            activePaneID = nil
        }
    }

    mutating func updateCandidates(_ raw: [AppCardCandidate], ignoredBundleIDs: Set<String> = []) {
        candidates = AppCardLayoutEngine.dedupeAndFilterCandidates(
            raw,
            excludingPIDs: excludedPIDs,
            excludingWindowNumbers: excludedWindowNumbers,
            excludingCandidateIDs: excludedCandidateIDs,
            ignoredBundleIDs: ignoredBundleIDs
        )
    }
}

private final class SendableSCWindowBox: @unchecked Sendable {
    let windowNumber: Int
    let scWindow: SCWindow
    let pixelWidth: Int
    let pixelHeight: Int

    init(windowNumber: Int, scWindow: SCWindow, pixelWidth: Int, pixelHeight: Int) {
        self.windowNumber = windowNumber
        self.scWindow = scWindow
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

private final class SendableCGImageBox: @unchecked Sendable {
    let cgImage: CGImage
    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

enum WindowThumbnailCapturer {
    fileprivate static func captureThumbnails(
        windowNumbers: [Int],
        permissionGranted: Bool,
        maxPixelDimension: Int = 480
    ) async -> [Int: SendableCGImageBox] {
        guard permissionGranted, !windowNumbers.isEmpty else {
            return [:]
        }

        let targetIDs = Set(windowNumbers.prefix(16).map { CGWindowID($0) })
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            return [:]
        }

        var boxes: [SendableSCWindowBox] = []
        boxes.reserveCapacity(targetIDs.count)

        for scWin in content.windows where targetIDs.contains(scWin.windowID) {
            let bounds = scWin.frame
            guard bounds.width >= 40, bounds.height >= 40 else { continue }
            let scale = min(
                Double(maxPixelDimension) / max(1.0, Double(bounds.width)),
                Double(maxPixelDimension) / max(1.0, Double(bounds.height)),
                1.0
            )
            let rawW = max(64, Int((Double(bounds.width) * scale).rounded()))
            let rawH = max(64, Int((Double(bounds.height) * scale).rounded()))
            let evenW = rawW - (rawW % 2)
            let evenH = rawH - (rawH % 2)
            boxes.append(SendableSCWindowBox(
                windowNumber: Int(scWin.windowID),
                scWindow: scWin,
                pixelWidth: max(64, evenW),
                pixelHeight: max(64, evenH)
            ))
        }

        guard !boxes.isEmpty else { return [:] }

        var captured: [Int: SendableCGImageBox] = [:]
        let batchSize = 4
        var cursor = 0

        while cursor < boxes.count {
            if Task.isCancelled { break }
            let end = min(boxes.count, cursor + batchSize)
            let slice = Array(boxes[cursor..<end])
            cursor = end

            await withTaskGroup(of: (Int, SendableCGImageBox?).self) { group in
                for box in slice {
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: box.scWindow)
                        let streamConfig = SCStreamConfiguration()
                        streamConfig.width = size_t(box.pixelWidth)
                        streamConfig.height = size_t(box.pixelHeight)
                        streamConfig.scalesToFit = true
                        streamConfig.preservesAspectRatio = true
                        streamConfig.showsCursor = false
                        streamConfig.ignoreShadowsSingleWindow = true

                        guard let cgImage = try? await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: streamConfig
                        ) else {
                            return (box.windowNumber, nil)
                        }
                        return (box.windowNumber, SendableCGImageBox(cgImage))
                    }
                }
                for await (winNum, imageBox) in group {
                    if let imageBox {
                        captured[winNum] = imageBox
                    }
                }
            }
        }

        return captured
    }
}

private final class GlassPaneNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class GlassPaneBackdropView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class GlassPaneObservableStore: ObservableObject {
    @Published var state = GlassPaneSessionState()
    @Published var thumbnailsByWindowNumber: [Int: NSImage] = [:]
    @Published var iconsByPID: [pid_t: NSImage] = [:]
    @Published var style: OverlayStyleConfig = OverlayStyleConfig()
    @Published var showThumbnails: Bool = true
}

@MainActor
final class GlassPaneSessionController: ObservableObject {
    static let shared = GlassPaneSessionController()

    private let store = GlassPaneObservableStore()
    private var panels: [String: GlassPaneNSPanel] = [:]
    private var cachedWindowsByCandidateID: [String: DiscoveredAXWindow] = [:]
    private var activeDisplay: ConnectedDisplay?
    private var onSelectAppHandler: ((AppCardCandidate, DiscoveredAXWindow?, ResolvedZone, ConnectedDisplay) -> Void)?
    private var sessionGeneration: UInt64 = 0
    private var thumbnailTask: Task<Void, Never>?

    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private init() {}

    var isActive: Bool {
        store.state.isActive
    }

    func present(
        remainingZones: [ResolvedZone],
        on display: ConnectedDisplay,
        snappedWindow: DiscoveredAXWindow,
        occupiedWindowNumbers: Set<Int> = [],
        config: WindowSnapperConfig,
        axController: AXWindowController,
        onSelectApp: @escaping (AppCardCandidate, DiscoveredAXWindow?, ResolvedZone, ConnectedDisplay) -> Void
    ) {
        dismiss()

        guard config.enabled,
              config.topEdgePanel.enabled,
              config.topEdgePanel.showAppCards,
              !remainingZones.isEmpty else {
            return
        }

        sessionGeneration &+= 1
        let gen = sessionGeneration
        activeDisplay = display
        onSelectAppHandler = onSelectApp

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let ignored = Set(config.ignoredBundleIDs)
        var initialExcludedWinNums = occupiedWindowNumbers
        if let snappedWinNum = snappedWindow.windowNumber {
            initialExcludedWinNums.insert(snappedWinNum)
        }
        let snappedCandidateID = AppCardCandidate.makeID(
            pid: snappedWindow.pid,
            windowNumber: snappedWindow.windowNumber,
            title: snappedWindow.title,
            frameAX: snappedWindow.frameAX
        )

        let fastCandidates = Self.fastLayerZeroCandidates(
            excludingPIDs: [selfPID],
            excludingWindowNumbers: initialExcludedWinNums,
            ignoredBundleIDs: ignored
        )

        store.style = config.overlayStyle
        store.showThumbnails = config.topEdgePanel.showWindowThumbnails
        store.thumbnailsByWindowNumber = [:]
        store.iconsByPID = Self.collectAppIcons(for: fastCandidates)
        store.state = GlassPaneSessionState.begin(
            remainingZones: remainingZones,
            snappedWindowNumber: snappedWindow.windowNumber,
            snappedCandidateID: snappedCandidateID,
            occupiedWindowNumbers: occupiedWindowNumbers,
            selfPID: selfPID,
            initialCandidates: fastCandidates,
            ignoredBundleIDs: ignored
        )

        guard store.state.isActive else { return }

        createPanels(for: store.state.panes, style: config.overlayStyle)
        installDismissMonitors()

        if config.topEdgePanel.showWindowThumbnails {
            let initialWinNums = store.state.candidates.compactMap(\.windowNumber)
            scheduleThumbnailCapture(windowNumbers: initialWinNums, generation: gen)
        }

        let excludedPIDs = store.state.excludedPIDs
        let excludedWindowNumbers = store.state.excludedWindowNumbers
        axController.inspectRunningAppWindows(
            excludingPIDs: excludedPIDs,
            excludingWindowNumbers: excludedWindowNumbers,
            ignoredBundleIDs: ignored
        ) { [weak self] refinedCandidates, windowsByID in
            guard let self, self.sessionGeneration == gen, self.store.state.isActive else { return }
            self.cachedWindowsByCandidateID = windowsByID
            self.store.state.updateCandidates(refinedCandidates, ignoredBundleIDs: ignored)
            let updatedIcons = Self.collectAppIcons(for: self.store.state.candidates)
            for (pid, icon) in updatedIcons where self.store.iconsByPID[pid] == nil {
                self.store.iconsByPID[pid] = icon
            }
            if config.topEdgePanel.showWindowThumbnails {
                let winNums = self.store.state.candidates.compactMap(\.windowNumber)
                let missing = winNums.filter { self.store.thumbnailsByWindowNumber[$0] == nil }
                if !missing.isEmpty {
                    self.scheduleThumbnailCapture(windowNumbers: missing, generation: gen)
                }
            }
        }
    }

    func dismiss() {
        sessionGeneration &+= 1
        thumbnailTask?.cancel()
        thumbnailTask = nil
        removeDismissMonitors()

        for (_, panel) in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        cachedWindowsByCandidateID.removeAll()
        activeDisplay = nil
        onSelectAppHandler = nil
        if store.state.isActive {
            store.state = GlassPaneSessionState()
        }
        store.thumbnailsByWindowNumber = [:]
        store.iconsByPID = [:]
        PointerCursorNSView.syncVisibleWindowUnderMouseOrResetCursor()
    }

    func containsScreenPointAX(_ pointAX: CGPoint) -> Bool {
        guard isActive, !panels.isEmpty else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        let appKitPoint = SnapGeometry.axPointToAppKit(pointAX, primaryScreenHeight: primaryHeight)
        return containsScreenPointAppKit(appKitPoint)
    }

    func containsScreenPointAppKit(_ pointAppKit: CGPoint) -> Bool {
        guard isActive else { return false }
        return panels.values.contains { $0.isVisible && $0.frame.contains(pointAppKit) }
    }

    // MARK: - User Interactions

    private func handleActivatePane(id paneID: String) {
        guard store.state.isActive else { return }
        store.state.activatePane(id: paneID)
    }

    private func handleSelectCard(_ candidate: AppCardCandidate, forPane pane: GlassPaneItem) {
        guard store.state.isActive, let display = activeDisplay else { return }
        let handler = onSelectAppHandler
        let preResolvedWindow = cachedWindowsByCandidateID[candidate.id]

        if let panel = panels.removeValue(forKey: pane.id) {
            panel.orderOut(nil)
        }
        store.state.completePlacement(paneID: pane.id, placedCandidate: candidate)
        let shouldTearDown = !store.state.isActive

        handler?(candidate, preResolvedWindow, pane.zone, display)

        if shouldTearDown {
            dismiss()
        } else {
            PointerCursorNSView.syncVisibleWindowUnderMouseOrResetCursor()
        }
    }

    // MARK: - Panels

    private func createPanels(for panes: [GlassPaneItem], style: OverlayStyleConfig) {
        let cornerRadius = max(8, CGFloat(style.cornerRadiusPoints))

        for pane in panes {
            let rect = pane.zone.frameInAppKit
            let panel = GlassPaneNSPanel(
                contentRect: rect,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            ToolboxTheme.applyDarkAppearance(to: panel)

            let backdrop = GlassPaneBackdropView(frame: NSRect(origin: .zero, size: rect.size))
            backdrop.autoresizingMask = [.width, .height]
            backdrop.material = .hudWindow
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = cornerRadius
            backdrop.layer?.masksToBounds = true

            let paneID = pane.id
            let rootView = GlassPaneHostView(
                pane: pane,
                store: store,
                onActivatePane: { [weak self] in
                    self?.handleActivatePane(id: paneID)
                },
                onSelectCandidate: { [weak self] candidate in
                    guard let self,
                          let currentPane = self.store.state.panes.first(where: { $0.id == paneID }) else {
                        return
                    }
                    self.handleSelectCard(candidate, forPane: currentPane)
                },
                onDismissAll: { [weak self] in
                    self?.dismiss()
                }
            )
            let hosting = PointerCursorHostingView(rootView: rootView)
            hosting.frame = backdrop.bounds
            hosting.autoresizingMask = [.width, .height]
            backdrop.addSubview(hosting)

            panel.contentView = backdrop
            panel.setFrame(rect, display: true)
            panel.orderFrontRegardless()
            panels[pane.id] = panel
        }
    }

    // MARK: - Monitors

    private func installDismissMonitors() {
        removeDismissMonitors()

        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                if !self.containsScreenPointAppKit(NSEvent.mouseLocation) {
                    self.dismiss()
                }
            }
        }

        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let eventWinNum = event.windowNumber
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let insidePanelWindow = self.panels.values.contains { $0.windowNumber == eventWinNum }
                if !insidePanelWindow && !self.containsScreenPointAppKit(NSEvent.mouseLocation) {
                    self.dismiss()
                }
            }
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.dismiss()
            }
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let didDismiss = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isActive else { return false }
                self.dismiss()
                return true
            }
            return didDismiss ? nil : event
        }
    }

    private func removeDismissMonitors() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
    }

    // MARK: - Candidates, Icons & Thumbnails

    private static func fastLayerZeroCandidates(
        excludingPIDs: Set<pid_t>,
        excludingWindowNumbers: Set<Int>,
        ignoredBundleIDs: Set<String>
    ) -> [AppCardCandidate] {
        let entries = AXWindowController.onScreenLayerZeroWindows()
        var candidates: [AppCardCandidate] = []

        for (rank, entry) in entries.enumerated() {
            guard !excludingPIDs.contains(entry.ownerPID),
                  !excludingWindowNumbers.contains(entry.windowNumber),
                  let app = NSRunningApplication(processIdentifier: entry.ownerPID),
                  !app.isTerminated,
                  app.activationPolicy == .regular else {
                continue
            }
            candidates.append(AppCardCandidate(
                pid: entry.ownerPID,
                bundleIdentifier: app.bundleIdentifier ?? "",
                appName: app.localizedName ?? (app.bundleIdentifier ?? "App"),
                windowTitle: entry.title,
                windowNumber: entry.windowNumber,
                windowFrameAX: entry.boundsAX,
                isMinimized: false,
                zOrderRank: rank
            ))
        }

        return AppCardLayoutEngine.dedupeAndFilterCandidates(
            candidates,
            excludingPIDs: excludingPIDs,
            excludingWindowNumbers: excludingWindowNumbers,
            ignoredBundleIDs: ignoredBundleIDs
        )
    }

    private static func collectAppIcons(for candidates: [AppCardCandidate]) -> [pid_t: NSImage] {
        var result: [pid_t: NSImage] = [:]
        for c in candidates {
            if let app = NSRunningApplication(processIdentifier: c.pid), let icon = app.icon {
                result[c.pid] = icon
            } else if !c.bundleIdentifier.isEmpty,
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundleIdentifier) {
                result[c.pid] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return result
    }

    private func scheduleThumbnailCapture(windowNumbers: [Int], generation: UInt64) {
        guard !windowNumbers.isEmpty else { return }
        let permissionGranted = ScreenCapturePermission.isGranted && !PermissionsManager.isRunningInDiagnosticMode
        guard permissionGranted else { return }

        thumbnailTask?.cancel()
        thumbnailTask = Task.detached(priority: .userInitiated) { [weak self] in
            let captured = await WindowThumbnailCapturer.captureThumbnails(
                windowNumbers: windowNumbers,
                permissionGranted: permissionGranted
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.sessionGeneration == generation, self.store.state.isActive else { return }
                for (winNum, imageBox) in captured {
                    let cgImg = imageBox.cgImage
                    self.store.thumbnailsByWindowNumber[winNum] = NSImage(
                        cgImage: cgImg,
                        size: NSSize(width: cgImg.width, height: cgImg.height)
                    )
                }
            }
        }
    }
}

// MARK: - SwiftUI Views (Shared by Runtime Panes & Snapshots)

private struct GlassPaneHostView: View {
    let pane: GlassPaneItem
    @ObservedObject var store: GlassPaneObservableStore
    let onActivatePane: () -> Void
    let onSelectCandidate: (AppCardCandidate) -> Void
    let onDismissAll: () -> Void

    var body: some View {
        GlassPaneSurfaceView(
            pane: pane,
            isActive: store.state.activePaneID == pane.id,
            candidates: store.state.candidates,
            thumbnailsByWindowNumber: store.thumbnailsByWindowNumber,
            iconsByPID: store.iconsByPID,
            style: store.style,
            showThumbnails: store.showThumbnails,
            onActivate: onActivatePane,
            onSelectCandidate: onSelectCandidate,
            onDismiss: onDismissAll
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolboxDarkAppearance()
    }
}

@MainActor
private final class GlassPaneHoverState: ObservableObject {
    @Published var isHovered: Bool = false
}

struct GlassPaneSurfaceView: View {
    let pane: GlassPaneItem
    let isActive: Bool
    let candidates: [AppCardCandidate]
    let thumbnailsByWindowNumber: [Int: NSImage]
    let iconsByPID: [pid_t: NSImage]
    let style: OverlayStyleConfig
    let showThumbnails: Bool
    var isEmbeddedInBackdrop: Bool = false
    let onActivate: () -> Void
    let onSelectCandidate: (AppCardCandidate) -> Void
    let onDismiss: () -> Void

    @StateObject private var hoverState = GlassPaneHoverState()

    private var cornerRadius: CGFloat {
        max(8, CGFloat(style.cornerRadiusPoints))
    }

    private var accentStroke: Color {
        style.tintColor.readableStrokeColor
    }

    private var accentTint: Color {
        style.tintColor.swatchColor
    }

    var body: some View {
        let isInactiveHovered = hoverState.isHovered
        ZStack {
            if isEmbeddedInBackdrop {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThickMaterial.opacity(0.86))
            }

            if isActive {
                activeBody
            } else {
                inactiveBody
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isActive
                        ? accentStroke.opacity(0.90)
                        : (isInactiveHovered ? accentStroke.opacity(0.75) : Color.white.opacity(0.22)),
                    lineWidth: isActive ? 2.0 : (isInactiveHovered ? 1.75 : 1.0)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var inactiveBody: some View {
        let isInactiveHovered = hoverState.isHovered
        return Button {
            onActivate()
        } label: {
            ZStack {
                Color.black.opacity(isInactiveHovered ? 0.14 : 0.24)

                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(isInactiveHovered ? accentTint.opacity(0.28) : Color.white.opacity(0.10))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isInactiveHovered ? accentStroke.opacity(0.85) : Color.white.opacity(0.24),
                                        lineWidth: 1.0
                                    )
                            )
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(pane.zone.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("\(Int(round(pane.zone.frameInAppKit.width))) × \(Int(round(pane.zone.frameInAppKit.height)))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.68))

                    Text("Click to choose an app")
                        .font(.caption)
                        .foregroundStyle(isInactiveHovered ? accentStroke : Color.white.opacity(0.76))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(isInactiveHovered ? accentTint.opacity(0.22) : Color.white.opacity(0.08))
                        )
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoverState.isHovered = hovering
        }
        .pointerCursor()
    }

    private var activeBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accentStroke)
                    .frame(width: 7, height: 7)

                Text(pane.zone.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("· Choose an app")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("Esc")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss panes (Esc)")
                .pointerCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.20))

            Divider()
                .overlay(Color.white.opacity(0.12))

            if candidates.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Text("No other running app windows")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Open or unhide another app window to place it here.")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                    Button("Dismiss") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    let innerSize = CGSize(
                        width: max(120, geo.size.width - 28),
                        height: max(100, geo.size.height - 24)
                    )
                    let rows = AppCardLayoutEngine.layoutRows(
                        for: candidates,
                        in: innerSize,
                        spacing: 12
                    )
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 12) {
                            ForEach(rows) { row in
                                HStack(spacing: 12) {
                                    ForEach(row.items) { item in
                                        let winNum = item.candidate.windowNumber
                                        let thumb = showThumbnails ? winNum.flatMap { thumbnailsByWindowNumber[$0] } : nil
                                        GlassPaneAppCardView(
                                            item: item,
                                            thumbnail: thumb,
                                            icon: iconsByPID[item.candidate.pid],
                                            accentTint: accentTint,
                                            accentStroke: accentStroke
                                        ) {
                                            onSelectCandidate(item.candidate)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.18))
    }
}

private struct GlassPaneAppCardView: View {
    let item: AppCardLayoutItem
    let thumbnail: NSImage?
    let icon: NSImage?
    let accentTint: Color
    let accentStroke: Color
    let onTap: () -> Void

    @StateObject private var hoverState = GlassPaneHoverState()

    var body: some View {
        let isHovered = hoverState.isHovered
        Button(action: onTap) {
            Group {
                if let thumbnail {
                    thumbnailCardBody(thumbnail: thumbnail, isHovered: isHovered)
                } else {
                    fallbackCardBody(isHovered: isHovered)
                }
            }
            .frame(width: item.size.width, height: item.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? accentStroke : Color.white.opacity(0.20),
                        lineWidth: isHovered ? 2.0 : 1.0
                    )
            )
            .shadow(color: .black.opacity(isHovered ? 0.42 : 0.24), radius: isHovered ? 10 : 5, y: 3)
        }
        .buttonStyle(ToolboxPressFeedbackButtonStyle(pressScale: 0.97, pressOpacity: 0.90))
        .onHover { hovering in
            hoverState.isHovered = hovering
        }
        .pointerCursor()
    }

    private func thumbnailCardBody(thumbnail: NSImage, isHovered: Bool) -> some View {
        let hasSubtitle = !item.candidate.windowTitle.isEmpty && item.size.width >= 120
        let footerH: CGFloat = hasSubtitle ? 36 : 28
        let thumbH = max(32, item.size.height - footerH)
        return ZStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black.opacity(0.45)
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: item.size.width, height: thumbH, alignment: .top)
                        .clipped()
                }
                .frame(width: item.size.width, height: thumbH)

                Divider()
                    .overlay(Color.white.opacity(0.10))

                HStack(spacing: 7) {
                    appIconView(size: item.size.width >= 165 ? 18 : 15)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.candidate.appName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if hasSubtitle {
                            Text(item.candidate.windowTitle)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity)
                .frame(height: footerH)
                .background(Color.black.opacity(0.62))
            }

            if isHovered {
                accentTint.opacity(0.12)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fallbackCardBody(isHovered: Bool) -> some View {
        let iconSize = min(38, max(22, round(item.size.height * 0.28)))
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? accentTint.opacity(0.22) : Color.white.opacity(0.09))

            VStack(spacing: 5) {
                appIconView(size: iconSize)

                Text(item.candidate.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)

                if item.size.height >= 78, !item.candidate.windowTitle.isEmpty {
                    Text(item.candidate.windowTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.70))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                } else if item.candidate.isMinimized {
                    Text("Minimized")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.60))
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func appIconView(size: CGFloat) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.72, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
        }
    }
}
