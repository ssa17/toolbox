import AppKit
import Carbon
import Foundation
import SwiftUI

enum KeyboardPreviewZoneTarget: Equatable, Sendable {
    case directional(SnapDirectionAction)
    case preset(id: String, fallbackName: String)
}

struct KeyboardPreviewState: Equatable, Sendable {
    var target: KeyboardPreviewZoneTarget
    var directionalAction: SnapDirectionAction?
    var directionalStep: Int
    var requiredModifiers: [KeyModifier]

    init(
        target: KeyboardPreviewZoneTarget,
        directionalStep: Int = 0,
        requiredModifiers: [KeyModifier]
    ) {
        self.target = target
        if case .directional(let action) = target {
            self.directionalAction = action
            self.directionalStep = ((directionalStep % 3) + 3) % 3
        } else {
            self.directionalAction = nil
            self.directionalStep = 0
        }
        self.requiredModifiers = requiredModifiers
    }

    mutating func apply(
        nextTarget: KeyboardPreviewZoneTarget,
        requiredModifiers: [KeyModifier],
        cycleEnabled: Bool
    ) {
        self.requiredModifiers = requiredModifiers
        switch nextTarget {
        case .directional(let action):
            if cycleEnabled, let currentAction = self.directionalAction, currentAction == action {
                self.directionalStep = (self.directionalStep + 1) % 3
            } else {
                self.directionalStep = 0
            }
            self.directionalAction = action
            self.target = nextTarget
        case .preset:
            self.directionalAction = nil
            self.directionalStep = 0
            self.target = nextTarget
        }
    }

    static func cgFlags(for modifiers: [KeyModifier]) -> CGEventFlags {
        var raw: UInt64 = 0
        for mod in modifiers {
            switch mod {
            case .control: raw |= CGEventFlags.maskControl.rawValue
            case .option: raw |= CGEventFlags.maskAlternate.rawValue
            case .shift: raw |= CGEventFlags.maskShift.rawValue
            case .command: raw |= CGEventFlags.maskCommand.rawValue
            }
        }
        return CGEventFlags(rawValue: raw)
    }

    static func modifiersStillHeld(_ requiredModifiers: [KeyModifier], liveFlags: CGEventFlags) -> Bool {
        guard !requiredModifiers.isEmpty else { return false }
        let needed = cgFlags(for: requiredModifiers)
        return liveFlags.contains(needed)
    }
}

private struct PendingKeyboardSnapSession {
    let window: DiscoveredAXWindow
    let display: ConnectedDisplay
    var state: KeyboardPreviewState
    var zone: ResolvedZone
}

private final class PreviewTapStartState: @unchecked Sendable {
    var succeeded = false
}

/// Active only during keyboard snap preview mode so Delete/Backspace, Forward Delete,
/// and Escape cancel and consume the keypress before Carbon hotkeys or the focused app.
final class KeyboardSnapPreviewTap: @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?
    private var isActive = false

    var onCancelKeyPressed: (@Sendable () -> Void)?
    var onFlagsChanged: (@Sendable () -> Void)?
    var onDebugKeyDown: (@Sendable (UInt16, UInt64) -> Void)?

    deinit {
        uninstall()
    }

    static func isCancelKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Delete)
            || keyCode == UInt16(kVK_ForwardDelete)
            || keyCode == UInt16(kVK_Escape)
            || keyCode == UInt16(kVK_ANSI_KeypadClear)
    }

    var isInstalled: Bool {
        withLock { tap != nil }
    }

    func setActive(_ active: Bool) {
        let (currentTap, changed): (CFMachPort?, Bool) = withLock {
            let prev = isActive
            isActive = active
            return (tap, prev != active)
        }
        if let currentTap, changed || CGEvent.tapIsEnabled(tap: currentTap) != active {
            CGEvent.tapEnable(tap: currentTap, enable: active)
        }
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = PreviewTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<KeyboardSnapPreviewTap>.fromOpaque(userInfo).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            }
            guard let newTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: selfPtr
            ) ?? CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: tapCallback,
                userInfo: selfPtr
            ) else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let rl = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)

            let initiallyActive: Bool = self.withLock {
                self.tap = newTap
                self.runLoopSource = source
                self.backgroundRunLoop = rl
                return self.isActive
            }
            CGEvent.tapEnable(tap: newTap, enable: initiallyActive)

            startState.succeeded = true
            readySem.signal()
            CFRunLoopRun()
            exitSem.signal()
        }
        thread.name = "app.toolbox.window-snapper-keyboard-preview-tap"
        thread.qualityOfService = .userInteractive

        withLock {
            self.tapThread = thread
            self.tapExitSemaphore = exitSem
        }
        thread.start()
        readySem.wait()

        if !startState.succeeded {
            _ = exitSem.wait(timeout: .now() + 0.5)
            withLock {
                self.tapThread = nil
                self.tapExitSemaphore = nil
            }
        }
        return startState.succeeded
    }

    func uninstall() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        uninstallLocked()
    }

    private func uninstallLocked() {
        let (currentTap, currentSource, currentRL, currentThread, exitSem) = withLock {
            let values = (tap, runLoopSource, backgroundRunLoop, tapThread, tapExitSemaphore)
            tap = nil
            runLoopSource = nil
            backgroundRunLoop = nil
            tapThread = nil
            tapExitSemaphore = nil
            isActive = false
            return values
        }

        if let currentTap {
            CGEvent.tapEnable(tap: currentTap, enable: false)
            if let currentRL, let currentSource {
                CFRunLoopRemoveSource(currentRL, currentSource, .commonModes)
            }
            CFMachPortInvalidate(currentTap)
        }
        if let currentRL {
            CFRunLoopStop(currentRL)
        }
        if let exitSem, Thread.current !== currentThread {
            _ = exitSem.wait(timeout: .now() + 1.0)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let (active, current) = withLock { (isActive, tap) }
            guard active else {
                return Unmanaged.passUnretained(event)
            }
            if type == .tapDisabledByTimeout {
                if PermissionsManager.shouldRearmEventTap(for: type), let current {
                    CGEvent.tapEnable(tap: current, enable: true)
                } else {
                    Task { @MainActor in
                        PermissionsManager.shared.refresh()
                    }
                }
            } else if let current, !CGEvent.tapIsEnabled(tap: current) {
                Task { @MainActor in
                    PermissionsManager.shared.refresh()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard withLock({ isActive }) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown {
                onDebugKeyDown?(keyCode, event.flags.rawValue)
            }
            if Self.isCancelKeyCode(keyCode) {
                let currentTap: CFMachPort? = withLock {
                    isActive = false
                    return tap
                }
                if let currentTap {
                    CGEvent.tapEnable(tap: currentTap, enable: false)
                }
                onCancelKeyPressed?()
                return nil
            }
        } else if type == .flagsChanged {
            onFlagsChanged?()
        }

        return Unmanaged.passUnretained(event)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

@MainActor
final class WindowSnapperModule: ToolboxModule, ObservableObject {
    let id = "window_snapper"
    let name = "Window Snapper"
    let tagline = "Snap windows to custom display zones and switch workspace profiles in one click."
    let aboutSummary = "Organize windows across one or multiple displays with magnetic edge & corner snapping, a Top Edge Panel with frosted glass panes for filling remaining slots, customizable per-display grids with adjustable dividers, hold-to-preview keyboard shortcuts, automatic pre-snap size restoration, and one-click Workspace Profiles."
    let featureTips = [
        "Drag near the top center of any display to reveal the Top Edge Panel and snap straight into any template mini-cell, then fill empty remaining cells via frosted glass panes.",
        "Hold Shift while dragging a window to reveal every zone in your display grid, and hover near a divider seam to span adjacent cells.",
        "Hold shortcut modifiers (such as Ctrl+Opt+Cmd) and tap an arrow or zone key to preview and cycle sizes before releasing to snap, or press Backspace to cancel.",
        "Use Workspace Profiles to pick a screen layout template, bind a global shortcut to the profile, and launch your apps into position in one click."
    ]
    let symbolName = "rectangle.3.group"
    let accentColor = Color.indigo
    let category: ModuleCategory = .windowAndDock
    let requiresAccessibility = true
    let accessibilityReason = "Needed to detect window drag gestures, read window frames, and resize or move application windows."

    @Published private(set) var isRunning = false
    @Published private(set) var sequoiaConflictStatus: SequoiaTilingConflictStatus = SnapGeometry.currentSequoiaTilingConflict()
    /// The ID of the profile whose previous workspace can be restored right now,
    /// or nil when no restore is available. Published so the settings view and
    /// status bar menu can show a "Restore" affordance without observing the engine.
    @Published private(set) var restoreAvailableProfileID: String? = nil

    let displayRegistry = DisplayRegistry.shared
    let overlayController = ZoneOverlayController.shared
    let glassPaneController = GlassPaneSessionController.shared
    let axController = AXWindowController()
    lazy var dragMonitor: WindowDragMonitor = WindowDragMonitor(
        axController: axController,
        displayRegistry: displayRegistry,
        overlayController: overlayController
    )
    lazy var profileEngine: ProfileEngine = {
        let engine = ProfileEngine(
            axController: axController,
            displayRegistry: displayRegistry,
            overlayController: overlayController
        )
        engine.onRestoreSnapshotChanged = { [weak self] in
            self?.refreshRestoreAvailability()
        }
        return engine
    }()

    private var config = WindowSnapperConfig()
    private let preSnapStoreURL: URL = ConfigManager.shared.configURL
        .deletingLastPathComponent()
        .appendingPathComponent("pre_snap_frames.json")
    private var preSnapStore = PreSnapFrameStore()
    private var lastDirectionalSnap: (pid: pid_t, title: String, action: SnapDirectionAction, stepIndex: Int, timestamp: Date)?
    private var pendingKeyboardSnap: PendingKeyboardSnapSession?
    private var keyboardLookupInFlight = false
    private var keyboardLookupGeneration: UInt64 = 0
    private var queuedKeyboardTriggers: [(target: KeyboardPreviewZoneTarget, requiredModifiers: [KeyModifier])] = []
    private var keyboardPreviewGlobalMonitor: Any?
    private var keyboardPreviewLocalMonitor: Any?
    private var keyboardPreviewPollTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var hasShownTilingConflictToastThisLaunch = false
    private let keyboardPreviewTap = KeyboardSnapPreviewTap()
    private var lastKeyboardPreviewCancelUptime: TimeInterval = 0

    init() {
        let livePIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        self.preSnapStore = PreSnapFrameStore.load(from: preSnapStoreURL, livePIDs: livePIDs)

        keyboardPreviewTap.onCancelKeyPressed = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.cancelPendingKeyboardSnap()
                }
            }
        }
        keyboardPreviewTap.onFlagsChanged = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.pollKeyboardPreviewModifiers()
                }
            }
        }
        keyboardPreviewTap.onDebugKeyDown = { keyCode, flags in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DeveloperEventLog.shared.record(
                        .windowSnapper,
                        "Keyboard preview key",
                        detail: "keyCode=\(keyCode) flags=\(flags)"
                    )
                }
            }
        }
        overlayController.onBeforeBlockingOverlayShown = { [weak self] in
            self?.glassPaneController.dismiss()
        }
        dragMonitor.preSnapLookup = { [weak self] win in
            self?.preSnapStore.lookupOriginalFrameIfSnapped(for: win)
        }
        dragMonitor.onShouldIgnoreMouseDownAtAXPoint = { [weak self] pt in
            self?.glassPaneController.containsScreenPointAX(pt) ?? false
        }
        dragMonitor.onExternalMouseDownOrDragBegan = { [weak self] in
            self?.glassPaneController.dismiss()
        }
        dragMonitor.onSnapCommitted = { [weak self] win, zone, display, templateContext in
            guard let self else { return }
            self.glassPaneController.dismiss()
            self.commitSnap(window: win, targetZone: zone, targetDisplay: display, isKeyboardSnap: false)

            if let templateContext,
               self.config.enabled,
               self.config.topEdgePanel.enabled,
               self.config.topEdgePanel.showAppCards {
                let selfPID = ProcessInfo.processInfo.processIdentifier
                let footprints: [VisibleWindowFootprint] = AXWindowController.onScreenLayerZeroWindows().compactMap { entry in
                    guard entry.ownerPID == selfPID
                        || NSRunningApplication(processIdentifier: entry.ownerPID)?.activationPolicy == .regular else {
                        return nil
                    }
                    return VisibleWindowFootprint(
                        windowNumber: entry.windowNumber,
                        ownerPID: entry.ownerPID,
                        boundsAX: entry.boundsAX
                    )
                }
                let occupancy = TopEdgePanelGeometry.unoccupiedRemainingCells(
                    allCells: templateContext.allCells,
                    snappedCellID: templateContext.snappedCellID,
                    snappedWindowNumber: win.windowNumber,
                    visibleWindowsFrontToBack: footprints
                )
                if !occupancy.unoccupiedCells.isEmpty {
                    self.glassPaneController.present(
                        remainingZones: occupancy.unoccupiedCells,
                        on: display,
                        snappedWindow: win,
                        occupiedWindowNumbers: occupancy.occupiedWindowNumbers,
                        config: self.config,
                        axController: self.axController
                    ) { [weak self] candidate, preResolvedWindow, targetCell, targetDisplay in
                        self?.placeGlassPaneCandidate(
                            candidate: candidate,
                            preResolvedWindow: preResolvedWindow,
                            targetZone: targetCell,
                            targetDisplay: targetDisplay
                        )
                    }
                }
            }
        }
        dragMonitor.onUnsnapCommitted = { [weak self] win, originalFrameAX, releasePointAX, grabRatioX in
            self?.restoreWindowOnDragAwayRelease(
                window: win,
                originalFrameAX: originalFrameAX,
                releasePointAX: releasePointAX,
                horizontalGrabRatio: grabRatioX
            )
        }
        dragMonitor.onExternalMaximizeDetected = { [weak self] windowNumber, pid, bundleID, preClickFrameAX, postClickFrameAX in
            guard let self else { return }
            let dummy = DiscoveredAXWindow(
                pid: pid,
                windowNumber: windowNumber,
                bundleIdentifier: bundleID,
                appName: "",
                title: "",
                frameAX: preClickFrameAX,
                isFullscreen: false,
                isMinimized: false,
                elementBox: AXElementBox(AXWindowController.applicationElement(for: pid), selfWindowNumber: windowNumber)
            )
            let effectiveOriginal = self.preSnapStore.lookupOriginalFrameIfSnapped(for: dummy, currentSizeAX: preClickFrameAX.size)
                ?? preClickFrameAX
            self.preSnapStore.recordSnap(
                pid: pid,
                windowNumber: windowNumber,
                bundleIdentifier: bundleID,
                preSnapFrameAX: effectiveOriginal,
                appliedFrameAX: postClickFrameAX
            )
            self.persistPreSnapStore()
        }
        dragMonitor.onExternalUnmaximizeDetected = { [weak self] windowNumber, pid, _ in
            guard let self else { return }
            self.preSnapStore.clearRecord(pid: pid, windowNumber: windowNumber, sizeAX: nil)
            self.persistPreSnapStore()
        }
        displayRegistry.onDisplaysReconfigurationBegan = { [weak self] isRemoved in
            guard let self else { return }
            self.glassPaneController.dismiss()
            self.profileEngine.cancelInFlightApply()
            if self.isRunning,
               ConfigManager.shared.config.general.appEnabled,
               self.config.showSnapHUDToasts,
               !PermissionsManager.isRunningInDiagnosticMode {
                let autoProfile = self.config.autoApplyProfileID.flatMap { id in
                    self.config.profiles.first(where: { $0.id == id })
                }
                if let autoProfile {
                    HUDToast.shared.showLoading(
                        title: isRemoved ? "Display Disconnected" : "Display Detected",
                        subtitle: isRemoved ? "Adjusting \(autoProfile.name)…" : "Loading \(autoProfile.name)…",
                        tint: .indigo,
                        maxDuration: 5.0
                    )
                } else if self.config.displayConnectMode == .alwaysExtend && !isRemoved {
                    HUDToast.shared.showLoading(
                        title: "Display Detected",
                        subtitle: "Extending displays…",
                        tint: .indigo,
                        maxDuration: 5.0
                    )
                } else if self.config.displayConnectMode == .alwaysMirror && !isRemoved {
                    HUDToast.shared.showLoading(
                        title: "Display Detected",
                        subtitle: "Mirroring displays…",
                        tint: .indigo,
                        maxDuration: 5.0
                    )
                }
            }
        }
        displayRegistry.onDisplaysReconfigured = { [weak self] connected, _ in
            guard let self else { return }
            self.glassPaneController.dismiss()
            guard self.isRunning, ConfigManager.shared.config.general.appEnabled else { return }
            self.profileEngine.handleDisplaysReconfigured(
                connectedDisplays: connected,
                config: self.config
            ) { [weak self] batch in
                self?.recordBatchInPreSnapStore(batch)
            }
            if !self.profileEngine.isApplyingProfile,
               self.profileEngine.suggestedTopologyProfileID == nil,
               self.config.autoApplyProfileID == nil {
                HUDToast.shared.dismiss()
            }
            if self.overlayController.isLivePreviewActive {
                self.overlayController.showLiveSettingsPreview(displays: connected, config: self.config)
            }
        }
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.windowSnapper.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.windowSnapper.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        guard config.windowSnapper.keyboardSnappingEnabled,
              !config.windowSnapper.hotKeys.leftHalf.isEmpty else {
            return nil
        }
        return config.windowSnapper.hotKeys.leftHalf.displayString
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !isEnabled(in: config) { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if !accessibilityGranted { return "Needs Accessibility" }
        if let activeID = config.windowSnapper.activeProfileID,
           let active = config.windowSnapper.profiles.first(where: { $0.id == activeID }) {
            return "Active · \(active.name)"
        }
        return isRunning ? "Active" : "Standby"
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        displayRegistry.startObserving()
        refreshSequoiaConflictStatus()
        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSequoiaConflictStatus()
                }
            }
        }
        syncRuntimeComponents(appEnabled: ConfigManager.shared.config.general.appEnabled)
        if config.drag.enabled && sequoiaConflictStatus.hasConflictWithToolboxDrag && !hasShownTilingConflictToastThisLaunch {
            hasShownTilingConflictToastThisLaunch = true
            HUDToast.shared.show(
                title: "Turn off macOS tiling in Desktop & Dock so Window Snapper handles it all",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                duration: 3.5
            )
        }
        ModuleRegistry.shared.notifyChanged()
    }

    func stop() {
        cancelPendingKeyboardSnap()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        HotKeyManager.shared.unregisterAll(prefix: "window_snapper.")
        keyboardPreviewTap.uninstall()
        dragMonitor.stop()
        profileEngine.stopAllWatchers()
        displayRegistry.stopObserving()
        overlayController.endOnScreenEditor()
        overlayController.hideAllPreviews()
        glassPaneController.dismiss()
        guard isRunning else { return }
        isRunning = false
        ModuleRegistry.shared.notifyChanged()
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.windowSnapper
        dragMonitor.updateConfig(config)
        displayRegistry.refresh(gaps: config.gaps)
        refreshSequoiaConflictStatus()

        if fullConfig.general.appEnabled && config.enabled {
            if !config.keyboardSnappingEnabled {
                cancelPendingKeyboardSnap()
            }
            if !isRunning {
                start()
            } else {
                syncRuntimeComponents(appEnabled: fullConfig.general.appEnabled)
            }
        } else {
            if isRunning {
                stop()
            } else {
                cancelPendingKeyboardSnap()
                HotKeyManager.shared.unregisterAll(prefix: "window_snapper.")
            }
        }
        refreshRestoreAvailability()
    }

    /// Recomputes the published restore-availability signal from the current
    /// config and the engine's stored restore snapshot. Call whenever the
    /// snapshot changes (via the engine callback) or the config reloads.
    private func refreshRestoreAvailability() {
        let cfg = ConfigManager.shared.config.windowSnapper
        let available: String?
        if let activeID = cfg.activeProfileID,
           profileEngine.canRestorePreviousWorkspace(forProfileID: activeID, config: cfg) {
            available = activeID
        } else {
            available = nil
        }
        if restoreAvailableProfileID != available {
            restoreAvailableProfileID = available
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(WindowSnapperSettingsView(module: self))
    }

    func refreshSequoiaConflictStatus() {
        sequoiaConflictStatus = SnapGeometry.currentSequoiaTilingConflict()
    }

    private func syncRuntimeComponents(appEnabled: Bool) {
        if config.drag.enabled && PermissionsManager.isProcessTrusted() {
            dragMonitor.start()
        } else {
            dragMonitor.stop()
        }
        if appEnabled && config.enabled && config.keyboardSnappingEnabled && PermissionsManager.isProcessTrusted() {
            if !keyboardPreviewTap.isInstalled {
                _ = keyboardPreviewTap.install()
            }
        } else {
            keyboardPreviewTap.uninstall()
        }
        syncHotKeys(appEnabled: appEnabled)
        profileEngine.syncActiveProfileWatchers(config: ConfigManager.shared.config)
        if overlayController.isLivePreviewActive {
            overlayController.showLiveSettingsPreview(
                displays: displayRegistry.connectedDisplays,
                config: config
            )
        }
        if !config.topEdgePanel.enabled || !config.topEdgePanel.showAppCards {
            glassPaneController.dismiss()
        }
    }

    // MARK: - HotKey Registration

    private func syncHotKeys(appEnabled: Bool) {
        HotKeyManager.shared.unregisterAll(prefix: "window_snapper.")
        guard appEnabled, config.enabled else { return }

        if config.keyboardSnappingEnabled {
            for action in WindowSnapperHotKeyAction.allCases {
                let spec = config.hotKeys.shortcut(for: action)
                guard !spec.isEmpty else { continue }
                HotKeyManager.shared.register(name: action.registrationName, shortcut: spec) { [weak self] in
                    self?.handleHotKeyAction(action)
                }
            }
        }

        for profile in config.profiles where !profile.shortcut.isEmpty {
            let profileID = profile.id
            HotKeyManager.shared.register(
                name: "window_snapper.profile.\(profileID)",
                shortcut: profile.shortcut
            ) { [weak self] in
                guard let self,
                      let currentProfile = ConfigManager.shared.config.windowSnapper.profiles.first(where: { $0.id == profileID }) else {
                    return
                }
                self.triggerProfileShortcut(currentProfile)
            }
        }

        for layout in config.displayLayouts {
            for zone in layout.customZones where !zone.shortcut.isEmpty {
                let targetLayout = layout
                let targetZone = zone
                HotKeyManager.shared.register(
                    name: "window_snapper.zone.\(layout.id).\(zone.id)",
                    shortcut: zone.shortcut
                ) { [weak self] in
                    self?.snapFocusedWindowToCustomZone(targetZone, preferredDisplay: targetLayout.display)
                }
            }
        }
    }

    static func shouldSuppressPostCancelRestore(
        now: TimeInterval,
        cancelUptime: TimeInterval,
        graceInterval: TimeInterval = 0.45
    ) -> Bool {
        cancelUptime > 0 && (now - cancelUptime) >= 0 && (now - cancelUptime) < graceInterval
    }

    private static func isAnyCancelKeyCurrentlyPressed() -> Bool {
        let cancelKeys: [CGKeyCode] = [
            CGKeyCode(kVK_Delete),
            CGKeyCode(kVK_ForwardDelete),
            CGKeyCode(kVK_Escape),
            CGKeyCode(kVK_ANSI_KeypadClear)
        ]
        return cancelKeys.contains { key in
            CGEventSource.keyState(.hidSystemState, key: key)
                || CGEventSource.keyState(.combinedSessionState, key: key)
        }
    }

    private var hasActiveOrPendingKeyboardSnap: Bool {
        pendingKeyboardSnap != nil || keyboardLookupInFlight
    }

    private func handleHotKeyAction(_ action: WindowSnapperHotKeyAction) {
        let requiredModifiers = config.hotKeys.shortcut(for: action).modifiers
        switch action {
        case .leftHalf:
            triggerKeyboardZoneShortcut(target: .directional(.leftHalf), requiredModifiers: requiredModifiers)
        case .rightHalf:
            triggerKeyboardZoneShortcut(target: .directional(.rightHalf), requiredModifiers: requiredModifiers)
        case .topHalf:
            triggerKeyboardZoneShortcut(target: .directional(.topHalf), requiredModifiers: requiredModifiers)
        case .bottomHalf:
            triggerKeyboardZoneShortcut(target: .directional(.bottomHalf), requiredModifiers: requiredModifiers)
        case .topLeft:
            triggerKeyboardZoneShortcut(target: .preset(id: "preset:top_left", fallbackName: "Top Left"), requiredModifiers: requiredModifiers)
        case .topRight:
            triggerKeyboardZoneShortcut(target: .preset(id: "preset:top_right", fallbackName: "Top Right"), requiredModifiers: requiredModifiers)
        case .bottomLeft:
            triggerKeyboardZoneShortcut(target: .preset(id: "preset:bottom_left", fallbackName: "Bottom Left"), requiredModifiers: requiredModifiers)
        case .bottomRight:
            triggerKeyboardZoneShortcut(target: .preset(id: "preset:bottom_right", fallbackName: "Bottom Right"), requiredModifiers: requiredModifiers)
        case .maximize:
            triggerKeyboardZoneShortcut(target: .preset(id: "universal:maximize", fallbackName: "Maximize"), requiredModifiers: requiredModifiers)
        case .center:
            triggerKeyboardZoneShortcut(target: .preset(id: "universal:center", fallbackName: "Center"), requiredModifiers: requiredModifiers)
        case .previousDisplay:
            cancelPendingKeyboardSnap()
            performDisplayHop(direction: -1)
        case .nextDisplay:
            cancelPendingKeyboardSnap()
            performDisplayHop(direction: 1)
        case .restorePreSnap:
            if hasActiveOrPendingKeyboardSnap {
                cancelPendingKeyboardSnap()
                return
            }
            if Self.shouldSuppressPostCancelRestore(
                now: ProcessInfo.processInfo.systemUptime,
                cancelUptime: lastKeyboardPreviewCancelUptime
            ) {
                return
            }
            restoreFocusedWindow()
        }
    }

    private func triggerKeyboardZoneShortcut(
        target: KeyboardPreviewZoneTarget,
        requiredModifiers: [KeyModifier]
    ) {
        glassPaneController.dismiss()
        guard ensureAccessibilityForAction() else { return }
        displayRegistry.refresh(gaps: config.gaps)

        if var active = pendingKeyboardSnap {
            active.state.apply(
                nextTarget: target,
                requiredModifiers: requiredModifiers,
                cycleEnabled: config.cycleRepeatedDirectionShortcuts
            )
            guard let nextZone = resolveZone(for: active.state, on: active.display) else {
                cancelPendingKeyboardSnap()
                return
            }
            active.zone = nextZone
            pendingKeyboardSnap = active

            let liveFlags = CGEventSource.flagsState(.combinedSessionState)
            if !KeyboardPreviewState.modifiersStillHeld(active.state.requiredModifiers, liveFlags: liveFlags) {
                commitPendingKeyboardSnap()
            } else {
                showKeyboardSnapOverlay(for: active)
            }
            return
        }

        if keyboardLookupInFlight {
            queuedKeyboardTriggers.append((target: target, requiredModifiers: requiredModifiers))
            return
        }

        keyboardLookupInFlight = true
        keyboardLookupGeneration &+= 1
        let gen = keyboardLookupGeneration
        queuedKeyboardTriggers.removeAll()
        installKeyboardPreviewMonitors()

        axController.inspectFocusedStandardWindow(ignoredBundleIDs: Set(config.ignoredBundleIDs)) { [weak self] lookup in
            guard let self else { return }
            guard self.keyboardLookupInFlight, self.keyboardLookupGeneration == gen else { return }
            self.keyboardLookupInFlight = false
            let queued = self.queuedKeyboardTriggers
            self.queuedKeyboardTriggers.removeAll()

            guard let win = self.unwrapFocusedWindow(lookup),
                  let display = self.displayRegistry.display(containingAXRect: win.frameAX) else {
                self.removeKeyboardPreviewMonitors()
                return
            }

            let initialStep: Int = {
                if case .directional(let action) = target {
                    return self.nextDirectionalStep(for: win, action: action, on: display)
                }
                return 0
            }()

            var state = KeyboardPreviewState(
                target: target,
                directionalStep: initialStep,
                requiredModifiers: requiredModifiers
            )
            for item in queued {
                state.apply(
                    nextTarget: item.target,
                    requiredModifiers: item.requiredModifiers,
                    cycleEnabled: self.config.cycleRepeatedDirectionShortcuts
                )
            }

            guard let zone = self.resolveZone(for: state, on: display) else {
                self.removeKeyboardPreviewMonitors()
                return
            }

            if Self.isAnyCancelKeyCurrentlyPressed() {
                self.cancelPendingKeyboardSnap()
                return
            }

            let liveFlags = CGEventSource.flagsState(.combinedSessionState)
            if !KeyboardPreviewState.modifiersStillHeld(state.requiredModifiers, liveFlags: liveFlags) {
                self.removeKeyboardPreviewMonitors()
                self.commitKeyboardPreview(window: win, display: display, zone: zone, state: state, hadVisiblePreview: false)
                return
            }

            let session = PendingKeyboardSnapSession(window: win, display: display, state: state, zone: zone)
            self.pendingKeyboardSnap = session
            self.showKeyboardSnapOverlay(for: session)
        }
    }

    private func resolveZone(for state: KeyboardPreviewState, on display: ConnectedDisplay) -> ResolvedZone? {
        let layout = DisplayRegistry.layout(for: display.signature, in: config.displayLayouts)
        switch state.target {
        case .directional(let action):
            let outer = CGFloat(layout?.outerMarginPoints ?? config.gaps.outerMarginPoints)
            let inner = CGFloat(layout?.innerGapPoints ?? config.gaps.innerGapPoints)
            let norm = action.normalizedRect(forStep: state.directionalStep)
            let targetAX = SnapGeometry.applyGaps(
                to: norm,
                in: display.usableAX,
                outerMargin: outer,
                innerGap: inner
            )
            return ResolvedZone(
                id: "direction:\(action.rawValue):\(state.directionalStep)",
                name: action.fractionName(for: state.directionalStep),
                badgeNumber: 0,
                normalizedRect: norm,
                frameInAX: targetAX,
                frameInAppKit: SnapGeometry.axToAppKit(targetAX, primaryScreenHeight: display.primaryScreenHeight),
                gridCoord: nil,
                shortcut: .none
            )
        case .preset(let id, _):
            return SnapGeometry.resolveUniversalOrBuiltInZone(
                id: id,
                usableAXRect: display.usableAX,
                primaryScreenHeight: display.primaryScreenHeight,
                gaps: config.gaps,
                layoutOverride: layout,
                centerWidthFraction: config.centerWidthFraction,
                centerHeightFraction: config.centerHeightFraction
            )
        }
    }

    private func showKeyboardSnapOverlay(for session: PendingKeyboardSnapSession) {
        let minWarning = SnapGeometry.evaluateMinSizeFit(
            targetFrameAX: session.zone.frameInAX,
            minSize: session.window.minSize,
            usableAXRect: session.display.usableAX
        )
        let hintText: String = {
            if session.state.directionalAction != nil && config.cycleRepeatedDirectionShortcuts {
                return "Tap key to cycle · Release modifiers to snap · ⌫ Cancel"
            }
            return "Release modifiers to snap · ⌫ Cancel"
        }()
        overlayController.showKeyboardSnapPreview(
            on: session.display,
            zone: session.zone,
            minSizeWarning: minWarning,
            hintText: hintText,
            style: config.overlayStyle
        )
    }

    private func commitPendingKeyboardSnap() {
        guard let session = pendingKeyboardSnap else {
            removeKeyboardPreviewMonitors()
            return
        }
        pendingKeyboardSnap = nil
        keyboardLookupInFlight = false
        queuedKeyboardTriggers.removeAll()
        removeKeyboardPreviewMonitors()
        overlayController.hideDragOverlays()
        commitKeyboardPreview(
            window: session.window,
            display: session.display,
            zone: session.zone,
            state: session.state,
            hadVisiblePreview: true
        )
    }

    private func commitKeyboardPreview(
        window: DiscoveredAXWindow,
        display: ConnectedDisplay,
        zone: ResolvedZone,
        state: KeyboardPreviewState,
        hadVisiblePreview: Bool
    ) {
        if let dirAction = state.directionalAction {
            lastDirectionalSnap = (window.pid, window.title, dirAction, state.directionalStep, Date())
        } else {
            lastDirectionalSnap = nil
        }
        commitSnap(
            window: window,
            targetZone: zone,
            targetDisplay: display,
            isKeyboardSnap: true,
            shouldFlashOverlay: !hadVisiblePreview
        )
    }

    private func cancelPendingKeyboardSnap() {
        let hadPreview = pendingKeyboardSnap != nil || keyboardLookupInFlight
        pendingKeyboardSnap = nil
        keyboardLookupInFlight = false
        keyboardLookupGeneration &+= 1
        queuedKeyboardTriggers.removeAll()
        removeKeyboardPreviewMonitors()
        if hadPreview {
            lastKeyboardPreviewCancelUptime = ProcessInfo.processInfo.systemUptime
            overlayController.hideDragOverlays()
        }
    }

    private func pollKeyboardPreviewModifiers() {
        guard hasActiveOrPendingKeyboardSnap else {
            removeKeyboardPreviewMonitors()
            return
        }
        if Self.isAnyCancelKeyCurrentlyPressed() {
            cancelPendingKeyboardSnap()
            return
        }
        guard let session = pendingKeyboardSnap else { return }
        let liveFlags = CGEventSource.flagsState(.combinedSessionState)
        if !KeyboardPreviewState.modifiersStillHeld(session.state.requiredModifiers, liveFlags: liveFlags) {
            commitPendingKeyboardSnap()
        }
    }

    private func installKeyboardPreviewMonitors() {
        removeKeyboardPreviewMonitors(deactivateTap: false)

        if !keyboardPreviewTap.isInstalled && PermissionsManager.isProcessTrusted() {
            _ = keyboardPreviewTap.install()
        }
        keyboardPreviewTap.setActive(true)

        keyboardPreviewGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let eventType = event.type
            let keyCode = event.keyCode
            Task { @MainActor [weak self] in
                guard let self else { return }
                if eventType == .keyDown && KeyboardSnapPreviewTap.isCancelKeyCode(keyCode) {
                    self.cancelPendingKeyboardSnap()
                } else if eventType == .flagsChanged {
                    self.pollKeyboardPreviewModifiers()
                }
            }
        }

        keyboardPreviewLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && KeyboardSnapPreviewTap.isCancelKeyCode(event.keyCode) {
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard self.hasActiveOrPendingKeyboardSnap else { return false }
                    self.cancelPendingKeyboardSnap()
                    return true
                }
                if consumed { return nil }
            } else if event.type == .flagsChanged {
                MainActor.assumeIsolated {
                    self.pollKeyboardPreviewModifiers()
                }
            }
            return event
        }

        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollKeyboardPreviewModifiers()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keyboardPreviewPollTimer = timer
    }

    private func removeKeyboardPreviewMonitors(deactivateTap: Bool = true) {
        if deactivateTap {
            keyboardPreviewTap.setActive(false)
        }
        keyboardPreviewPollTimer?.invalidate()
        keyboardPreviewPollTimer = nil
        if let keyboardPreviewGlobalMonitor {
            NSEvent.removeMonitor(keyboardPreviewGlobalMonitor)
            self.keyboardPreviewGlobalMonitor = nil
        }
        if let keyboardPreviewLocalMonitor {
            NSEvent.removeMonitor(keyboardPreviewLocalMonitor)
            self.keyboardPreviewLocalMonitor = nil
        }
    }

    // MARK: - Keyboard Placement & Pre-Snap Restore

    func performDirectionalSnap(_ action: SnapDirectionAction) {
        guard ensureAccessibilityForAction() else { return }
        displayRegistry.refresh(gaps: config.gaps)
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectFocusedStandardWindow(ignoredBundleIDs: ignored) { [weak self] lookup in
            guard let self else { return }
            guard let win = self.unwrapFocusedWindow(lookup) else { return }
            guard let display = self.displayRegistry.display(containingAXRect: win.frameAX) else { return }

            let step = self.nextDirectionalStep(for: win, action: action, on: display)
            self.lastDirectionalSnap = (win.pid, win.title, action, step, Date())

            let layout = DisplayRegistry.layout(for: display.signature, in: self.config.displayLayouts)
            let outer = CGFloat(layout?.outerMarginPoints ?? self.config.gaps.outerMarginPoints)
            let inner = CGFloat(layout?.innerGapPoints ?? self.config.gaps.innerGapPoints)
            let norm = action.normalizedRect(forStep: step)
            let targetAX = SnapGeometry.applyGaps(
                to: norm,
                in: display.usableAX,
                outerMargin: outer,
                innerGap: inner
            )
            let zone = ResolvedZone(
                id: "direction:\(action.rawValue):\(step)",
                name: action.fractionName(for: step),
                badgeNumber: 0,
                normalizedRect: norm,
                frameInAX: targetAX,
                frameInAppKit: SnapGeometry.axToAppKit(targetAX, primaryScreenHeight: display.primaryScreenHeight),
                gridCoord: nil,
                shortcut: .none
            )
            self.commitSnap(window: win, targetZone: zone, targetDisplay: display, isKeyboardSnap: true)
        }
    }

    private func nextDirectionalStep(
        for win: DiscoveredAXWindow,
        action: SnapDirectionAction,
        on display: ConnectedDisplay
    ) -> Int {
        guard config.cycleRepeatedDirectionShortcuts else { return 0 }
        if let prev = lastDirectionalSnap,
           prev.pid == win.pid,
           prev.title == win.title,
           prev.action == action,
           Date().timeIntervalSince(prev.timestamp) <= 2.5 {
            return (prev.stepIndex + 1) % 3
        }
        // Also advance if the window is already sitting at step 0 (half)
        let layout = DisplayRegistry.layout(for: display.signature, in: config.displayLayouts)
        let outer = CGFloat(layout?.outerMarginPoints ?? config.gaps.outerMarginPoints)
        let inner = CGFloat(layout?.innerGapPoints ?? config.gaps.innerGapPoints)
        let halfAX = SnapGeometry.applyGaps(
            to: action.normalizedRect(forStep: 0),
            in: display.usableAX,
            outerMargin: outer,
            innerGap: inner
        )
        if abs(win.frameAX.minX - halfAX.minX) <= 12
            && abs(win.frameAX.minY - halfAX.minY) <= 12
            && abs(win.frameAX.width - halfAX.width) <= 12
            && abs(win.frameAX.height - halfAX.height) <= 12 {
            return 1
        }
        return 0
    }

    func performPresetZoneSnap(id: String, fallbackName: String) {
        guard ensureAccessibilityForAction() else { return }
        displayRegistry.refresh(gaps: config.gaps)
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectFocusedStandardWindow(ignoredBundleIDs: ignored) { [weak self] lookup in
            guard let self else { return }
            guard let win = self.unwrapFocusedWindow(lookup) else { return }
            guard let display = self.displayRegistry.display(containingAXRect: win.frameAX) else { return }
            let layout = DisplayRegistry.layout(for: display.signature, in: self.config.displayLayouts)
            guard let zone = SnapGeometry.resolveUniversalOrBuiltInZone(
                id: id,
                usableAXRect: display.usableAX,
                primaryScreenHeight: display.primaryScreenHeight,
                gaps: self.config.gaps,
                layoutOverride: layout,
                centerWidthFraction: self.config.centerWidthFraction,
                centerHeightFraction: self.config.centerHeightFraction
            ) else {
                return
            }
            self.lastDirectionalSnap = nil
            self.commitSnap(window: win, targetZone: zone, targetDisplay: display, isKeyboardSnap: true)
        }
    }

    func snapFocusedWindowToCustomZone(_ zoneDef: ZoneDefinition, preferredDisplay: DisplaySignature?) {
        guard ensureAccessibilityForAction() else { return }
        displayRegistry.refresh(gaps: config.gaps)
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectFocusedStandardWindow(ignoredBundleIDs: ignored) { [weak self] lookup in
            guard let self else { return }
            guard let win = self.unwrapFocusedWindow(lookup) else { return }
            let targetDisplay: ConnectedDisplay? = {
                if let preferredDisplay,
                   let matchedSig = DisplayRegistry.matchDisplay(
                       for: preferredDisplay,
                       among: self.displayRegistry.connectedDisplays.map(\.signature)
                   ),
                   let found = self.displayRegistry.connectedDisplays.first(where: { $0.signature == matchedSig }) {
                    return found
                }
                return self.displayRegistry.display(containingAXRect: win.frameAX)
            }()
            guard let display = targetDisplay else { return }
            let layout = DisplayRegistry.layout(for: display.signature, in: self.config.displayLayouts)
            let outer = CGFloat(layout?.outerMarginPoints ?? self.config.gaps.outerMarginPoints)
            let inner = CGFloat(layout?.innerGapPoints ?? self.config.gaps.innerGapPoints)
            let axFrame = SnapGeometry.applyGaps(
                to: zoneDef.normalizedRect,
                in: display.usableAX,
                outerMargin: outer,
                innerGap: inner
            )
            let resolved = ResolvedZone(
                id: zoneDef.id,
                name: zoneDef.name,
                badgeNumber: 0,
                normalizedRect: zoneDef.normalizedRect,
                frameInAX: axFrame,
                frameInAppKit: SnapGeometry.axToAppKit(axFrame, primaryScreenHeight: display.primaryScreenHeight),
                gridCoord: nil,
                shortcut: zoneDef.shortcut
            )
            self.commitSnap(window: win, targetZone: resolved, targetDisplay: display, isKeyboardSnap: true)
        }
    }

    func performDisplayHop(direction: Int) {
        glassPaneController.dismiss()
        guard ensureAccessibilityForAction() else { return }
        displayRegistry.refresh(gaps: config.gaps)
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectFocusedStandardWindow(ignoredBundleIDs: ignored) { [weak self] lookup in
            guard let self else { return }
            guard let win = self.unwrapFocusedWindow(lookup) else { return }
            guard let currentDisplay = self.displayRegistry.display(containingAXRect: win.frameAX),
                  let nextDisplay = self.displayRegistry.adjacentDisplay(from: currentDisplay, direction: direction) else {
                if self.config.showSnapHUDToasts {
                    HUDToast.shared.show(
                        title: "Connect another display to move windows across monitors",
                        symbol: "display.2",
                        tint: .secondary
                    )
                }
                return
            }

            let norm = SnapGeometry.normalizedRect(forAXFrame: win.frameAX, inUsableAXRect: currentDisplay.usableAX)
            let targetLayout = DisplayRegistry.layout(for: nextDisplay.signature, in: self.config.displayLayouts)
            let outer = CGFloat(targetLayout?.outerMarginPoints ?? self.config.gaps.outerMarginPoints)
            let inner = CGFloat(targetLayout?.innerGapPoints ?? self.config.gaps.innerGapPoints)
            let targetAX = SnapGeometry.applyGaps(
                to: norm,
                in: nextDisplay.usableAX,
                outerMargin: outer,
                innerGap: inner
            )
            let zone = ResolvedZone(
                id: "display_hop:\(nextDisplay.displayID)",
                name: nextDisplay.signature.localizedName,
                badgeNumber: 0,
                normalizedRect: norm,
                frameInAX: targetAX,
                frameInAppKit: SnapGeometry.axToAppKit(targetAX, primaryScreenHeight: nextDisplay.primaryScreenHeight),
                gridCoord: nil,
                shortcut: .none
            )
            self.commitSnap(window: win, targetZone: zone, targetDisplay: nextDisplay, isKeyboardSnap: true)
        }
    }

    func restoreFocusedWindow() {
        glassPaneController.dismiss()
        guard ensureAccessibilityForAction() else { return }
        displayRegistry.refresh(gaps: config.gaps)
        let ignored = Set(config.ignoredBundleIDs)

        axController.inspectFocusedStandardWindow(ignoredBundleIDs: ignored) { [weak self] lookup in
            guard let self, let win = self.unwrapFocusedWindow(lookup) else { return }
            guard let preFrame = self.preSnapStore.lookupOriginalFrameIfSnapped(for: win) else {
                if self.config.showSnapHUDToasts {
                    HUDToast.shared.show(title: "No previous size recorded for window", symbol: "macwindow", tint: .secondary)
                }
                return
            }
            let targetDisplay = self.displayRegistry.display(containingAXRect: preFrame)
                ?? self.displayRegistry.mainDisplay()
            guard let display = targetDisplay else { return }
            let sourceDisplay = self.displayRegistry.display(containingAXRect: win.frameAX)
            self.axController.snapWindow(
                win,
                toAXFrame: preFrame,
                usableAXRect: display.usableAX,
                sourceDisplayFrameAX: sourceDisplay?.frameAX,
                targetDisplayFrameAX: display.frameAX,
                animationSpeed: self.config.windowAnimationSpeed
            ) { [weak self] execResult in
                guard let self, execResult != nil else { return }
                self.preSnapStore.clearRecord(for: win)
                self.persistPreSnapStore()
                if self.config.showSnapHUDToasts {
                    HUDToast.shared.show(
                        title: "Restored \(win.appName)",
                        symbol: "arrow.down.right.and.arrow.up.left",
                        tint: .indigo
                    )
                }
            }
        }
    }

    private func recordBatchInPreSnapStore(_ batch: WindowSnapUndoBatch) {
        for item in batch.items {
            let dummy = DiscoveredAXWindow(
                pid: item.pid,
                windowNumber: item.windowNumber,
                bundleIdentifier: item.bundleIdentifier,
                appName: item.appName,
                title: item.windowTitle,
                frameAX: item.initialFrameAX,
                isFullscreen: false,
                isMinimized: false,
                elementBox: AXElementBox(AXWindowController.applicationElement(for: item.pid), selfWindowNumber: item.windowNumber)
            )
            let effectiveOriginal = preSnapStore.lookupOriginalFrameIfSnapped(for: dummy, currentSizeAX: item.initialFrameAX.size)
                ?? item.initialFrameAX
            preSnapStore.recordSnap(
                pid: item.pid,
                windowNumber: item.windowNumber,
                bundleIdentifier: item.bundleIdentifier,
                preSnapFrameAX: effectiveOriginal,
                appliedFrameAX: item.afterFrameAX
            )
        }
        persistPreSnapStore()
    }

    private func persistPreSnapStore() {
        preSnapStore.save(to: preSnapStoreURL)
    }

    private func restoreWindowOnDragAwayRelease(
        window: DiscoveredAXWindow,
        originalFrameAX: CGRect,
        releasePointAX: CGPoint,
        horizontalGrabRatio: CGFloat
    ) {
        displayRegistry.refresh(gaps: config.gaps)
        guard let display = displayRegistry.display(containingAXPoint: releasePointAX)
            ?? displayRegistry.display(containingAXRect: window.frameAX)
            ?? displayRegistry.mainDisplay() else {
            preSnapStore.clearRecord(for: window)
            persistPreSnapStore()
            return
        }

        axController.readWindowFrame(window.elementBox) { [weak self] readFrame in
            guard let self else { return }
            let liveFrame = readFrame ?? window.frameAX
            if abs(liveFrame.width - originalFrameAX.width) <= 10
                && abs(liveFrame.height - originalFrameAX.height) <= 10 {
                if let alignedOrigin = WindowDragMonitor.detachedReleaseOriginIfNeeded(
                    liveFrameAX: liveFrame,
                    releasePointAX: releasePointAX,
                    horizontalGrabRatio: horizontalGrabRatio,
                    usableAXRect: display.usableAX
                ) {
                    self.axController.moveWindowPosition(window.elementBox, toAXOrigin: alignedOrigin)
                }
                self.preSnapStore.clearRecord(for: window)
                self.persistPreSnapStore()
                return
            }

            let computeClampedTarget: (CGRect) -> CGRect = { currentFrame in
                let newOrigin = WindowDragMonitor.restoredDragOrigin(
                    pointerAX: releasePointAX,
                    initialFrameAX: currentFrame,
                    preSnapSize: originalFrameAX.size,
                    horizontalGrabRatio: horizontalGrabRatio
                )
                return SnapGeometry.clampFrameForMinimumSize(
                    targetFrame: CGRect(origin: newOrigin, size: originalFrameAX.size),
                    actualSize: originalFrameAX.size,
                    usableRect: display.usableAX,
                    outerMargin: 0
                )
            }

            let restoredTarget = computeClampedTarget(liveFrame)
            let sourceDisplay = self.displayRegistry.display(containingAXRect: liveFrame)
            self.axController.snapWindow(
                window,
                toAXFrame: restoredTarget,
                usableAXRect: display.usableAX,
                sourceDisplayFrameAX: sourceDisplay?.frameAX,
                targetDisplayFrameAX: display.frameAX,
                animationSpeed: self.config.windowAnimationSpeed
            ) { [weak self] _ in
                guard let self else { return }
                // Re-verify briefly after mouseUp in case WindowServer finalized a native drag loop and reverted size
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000)
                    guard let self else { return }
                    self.axController.readWindowFrame(window.elementBox) { [weak self] postFrame in
                        guard let self else { return }
                        if let postFrame,
                           (abs(postFrame.width - originalFrameAX.width) > 10 || abs(postFrame.height - originalFrameAX.height) > 10) {
                            let retryTarget = computeClampedTarget(postFrame)
                            self.axController.snapWindow(
                                window,
                                toAXFrame: retryTarget,
                                usableAXRect: display.usableAX,
                                sourceDisplayFrameAX: sourceDisplay?.frameAX,
                                targetDisplayFrameAX: display.frameAX
                            ) { _ in }
                        }
                        self.preSnapStore.clearRecord(for: window)
                        self.persistPreSnapStore()
                        DeveloperEventLog.shared.record(
                            .windowSnapper,
                            "Restored \(window.appName) pre-snap size",
                            detail: "\(Int(originalFrameAX.width))x\(Int(originalFrameAX.height))"
                        )
                    }
                }
            }
        }
    }

    private func commitSnap(
        window: DiscoveredAXWindow,
        targetZone: ResolvedZone,
        targetDisplay: ConnectedDisplay,
        isKeyboardSnap: Bool,
        shouldFlashOverlay: Bool = true
    ) {
        let effectiveInitialFrame = preSnapStore.lookupOriginalFrameIfSnapped(for: window) ?? window.frameAX
        let sourceDisplay = displayRegistry.display(containingAXRect: window.frameAX)
        axController.snapWindow(
            window,
            toAXFrame: targetZone.frameInAX,
            usableAXRect: targetDisplay.usableAX,
            sourceDisplayFrameAX: sourceDisplay?.frameAX,
            targetDisplayFrameAX: targetDisplay.frameAX,
            animationSpeed: config.windowAnimationSpeed
        ) { [weak self] execResult in
            guard let self, let execResult else { return }

            self.preSnapStore.recordSnap(
                window: window,
                preSnapFrameAX: effectiveInitialFrame,
                appliedFrameAX: execResult.appliedFrameAX
            )
            self.persistPreSnapStore()

            if execResult.clampedForMinSize {
                let minDesc = execResult.minSizeReported.map { "\(Int($0.width))x\(Int($0.height))" } ?? "app limit"
                DeveloperEventLog.shared.record(
                    .windowSnapper,
                    "Clamped \(window.appName) after min-size constraint",
                    detail: "zone: \(targetZone.name) · min: \(minDesc)"
                )
                if self.config.showSnapHUDToasts {
                    let actualW = Int(round(execResult.appliedFrameAX.width))
                    let actualH = Int(round(execResult.appliedFrameAX.height))
                    HUDToast.shared.show(
                        title: "\(window.appName) hit min size (\(actualW)×\(actualH))",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        duration: 2.4
                    )
                }
            } else {
                DeveloperEventLog.shared.record(
                    .windowSnapper,
                    "Snapped \(window.appName) -> \(targetZone.name)",
                    detail: "\(Int(execResult.appliedFrameAX.width))x\(Int(execResult.appliedFrameAX.height))"
                )
                if self.config.showSnapHUDToasts {
                    HUDToast.shared.show(
                        title: window.appName,
                        subtitle: "Snapped to \(targetZone.name)",
                        symbol: "rectangle.3.group",
                        tint: .indigo,
                        duration: 1.4
                    )
                }
            }

            let announcement = "\(window.appName) snapped to \(targetZone.name)"
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: announcement]
            )
        }
    }

    private func ensureAccessibilityForAction() -> Bool {
        guard PermissionsManager.isProcessTrusted() else {
            HUDToast.shared.show(
                title: "Grant Accessibility access to snap windows",
                symbol: "hand.raised.fill",
                tint: .orange
            )
            return false
        }
        return true
    }

    private func unwrapFocusedWindow(_ lookup: FocusedWindowLookupResult) -> DiscoveredAXWindow? {
        switch lookup {
        case .window(let win):
            return win
        case .fullscreen:
            if config.showSnapHUDToasts {
                HUDToast.shared.show(
                    title: "Exit fullscreen to snap window",
                    symbol: "arrow.down.right.and.arrow.up.left",
                    tint: .orange
                )
            }
            return nil
        case .ignored, .none:
            return nil
        }
    }

    // MARK: - Settings & Menu Bar Helpers

    func applyShortcutPreset(_ preset: WindowSnapperShortcutPreset) {
        ConfigManager.shared.config.windowSnapper.hotKeys = WindowSnapperHotKeys.forPreset(preset)
    }

    func previewDisplayZones(duration: TimeInterval = 3.0) {
        displayRegistry.refresh(gaps: config.gaps)
        overlayController.showLiveSettingsPreview(
            displays: displayRegistry.connectedDisplays,
            config: ConfigManager.shared.config.windowSnapper,
            autoHideAfter: duration
        )
    }

    func flashTopEdgeTriggerZone(distancePoints: Double, triggerWidth: TopEdgeTriggerWidth? = nil) {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }
        let snapConfig = ConfigManager.shared.config.windowSnapper
        displayRegistry.refresh(gaps: snapConfig.gaps)
        let displays = displayRegistry.connectedDisplays
        guard !displays.isEmpty else { return }

        let slots = TopEdgePanelGeometry.visibleSlots(for: snapConfig.topEdgePanel)
        let widthChoice = triggerWidth ?? snapConfig.topEdgePanel.triggerWidth
        let isZero = distancePoints <= 0.5
        let distLabel = TopEdgePanelConfig.triggerDistanceLabel(for: distancePoints)
        let banner = "Top-Edge Trigger · \(distLabel) (\(Int(round(distancePoints))) pt) · \(widthChoice.label)"

        overlayController.flashTriggerZones(
            on: displays,
            regionsProvider: { display in
                let pickerLayout = TopEdgePanelGeometry.pickerLayout(for: display, slots: slots)
                let rect = TopEdgePanelGeometry.triggerZoneRectAX(
                    for: display,
                    layout: pickerLayout,
                    triggerDistancePoints: CGFloat(distancePoints),
                    cornerBandPoints: CGFloat(snapConfig.drag.cornerBandPoints),
                    triggerWidth: widthChoice
                )
                let region = TriggerFlashRegion(
                    id: "top-edge-trigger",
                    frameAX: rect,
                    isZeroHairline: isZero,
                    cornerRadius: isZero ? 2 : 8
                )
                return (
                    regions: [region],
                    bannerAnchorAX: CGPoint(x: rect.midX, y: rect.maxY + 20)
                )
            },
            bannerText: banner,
            style: snapConfig.overlayStyle
        )
    }

    func flashEdgePullTriggerZone(distancePoints: Double) {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }
        let snapConfig = ConfigManager.shared.config.windowSnapper
        displayRegistry.refresh(gaps: snapConfig.gaps)
        let displays = displayRegistry.connectedDisplays
        guard !displays.isEmpty else { return }

        let isZero = distancePoints <= 0.5
        let distLabel = DragSnapConfig.edgeProximityLabel(for: distancePoints)
        let banner = "Edge Magnetic Pull · \(distLabel) (\(Int(round(distancePoints))) pt)"
        let labels = ["left", "right", "top"]

        overlayController.flashTriggerZones(
            on: displays,
            regionsProvider: { display in
                let rects = SnapGeometry.edgePullFlashRectsAX(
                    usableAX: display.usableAX,
                    edgeProximityPoints: CGFloat(distancePoints),
                    cornerBandPoints: CGFloat(snapConfig.drag.cornerBandPoints)
                )
                let regions = zip(labels, rects).map { label, rect in
                    TriggerFlashRegion(
                        id: "edge-\(label)",
                        frameAX: rect,
                        isZeroHairline: isZero,
                        cornerRadius: isZero ? 2 : 6
                    )
                }
                return (
                    regions: regions,
                    bannerAnchorAX: CGPoint(
                        x: display.usableAX.midX,
                        y: display.usableAX.minY + max(CGFloat(distancePoints), 12) + 24
                    )
                )
            },
            bannerText: banner,
            style: snapConfig.overlayStyle
        )
    }

    func flashCornerBandTriggerZone(bandPoints: Double) {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }
        let snapConfig = ConfigManager.shared.config.windowSnapper
        displayRegistry.refresh(gaps: snapConfig.gaps)
        let displays = displayRegistry.connectedDisplays
        guard !displays.isEmpty else { return }

        let bandLabel = DragSnapConfig.cornerBandLabel(for: bandPoints)
        let banner = "Corner Quadrant Band · \(bandLabel) (\(Int(round(bandPoints))) pt)"
        let labels = ["tl", "tr", "bl", "br"]

        overlayController.flashTriggerZones(
            on: displays,
            regionsProvider: { display in
                let rects = SnapGeometry.cornerBandFlashRectsAX(
                    usableAX: display.usableAX,
                    cornerBandPoints: CGFloat(bandPoints)
                )
                let regions = zip(labels, rects).map { label, rect in
                    TriggerFlashRegion(
                        id: "corner-\(label)",
                        frameAX: rect,
                        isZeroHairline: false,
                        cornerRadius: 8
                    )
                }
                return (
                    regions: regions,
                    bannerAnchorAX: CGPoint(
                        x: display.usableAX.midX,
                        y: display.usableAX.minY + 28
                    )
                )
            },
            bannerText: banner,
            style: snapConfig.overlayStyle
        )
    }

    func flashTileSpacingPreview(spacingPoints: Double) {
        let snapConfig = ConfigManager.shared.config.windowSnapper
        var previewGaps = snapConfig.gaps
        let clamped = GapConfig.clampedGap(spacingPoints)
        previewGaps.outerMarginPoints = clamped
        previewGaps.innerGapPoints = clamped
        let label = GapConfig.spacingPresetLabel(for: spacingPoints)
        let banner = "Tile Spacing · \(label) (\(Int(round(spacingPoints))) pt)"
        flashStylePreviewOverlay(gaps: previewGaps, style: snapConfig.overlayStyle, banner: banner)
    }

    func flashOutlineThicknessPreview(borderWidthPoints: Double) {
        let snapConfig = ConfigManager.shared.config.windowSnapper
        var previewStyle = snapConfig.overlayStyle
        previewStyle.borderWidthPoints = min(max(borderWidthPoints, 1.0), 8.0)
        let label = OverlayStyleConfig.borderThicknessLabel(for: borderWidthPoints)
        let banner = "Outline Thickness · \(label) (\(Int(round(borderWidthPoints))) pt)"
        flashStylePreviewOverlay(gaps: snapConfig.gaps, style: previewStyle, banner: banner)
    }

    func flashOutlineStylePreview(
        tintColor: OverlayTintColor? = nil,
        fillOpacity: Double? = nil
    ) {
        let snapConfig = ConfigManager.shared.config.windowSnapper
        var previewStyle = snapConfig.overlayStyle
        if let tintColor {
            previewStyle.tintColor = tintColor
        }
        if let fillOpacity {
            previewStyle.fillOpacity = min(max(fillOpacity, 0.0), 0.35)
        }
        let opacityPct = Int(round(previewStyle.fillOpacity * 100))
        let banner = "Overlay Style · \(previewStyle.tintColor.label) · \(opacityPct)%"
        flashStylePreviewOverlay(gaps: snapConfig.gaps, style: previewStyle, banner: banner)
    }

    func flashZoneLabelsPreview(showLabels: Bool) {
        let snapConfig = ConfigManager.shared.config.windowSnapper
        var previewStyle = snapConfig.overlayStyle
        previewStyle.showZoneLabelsAndDimensions = showLabels
        let banner = "Zone Labels · \(showLabels ? "Shown" : "Hidden")"
        flashStylePreviewOverlay(
            gaps: snapConfig.gaps,
            style: previewStyle,
            banner: banner,
            showZoneLabels: showLabels
        )
    }

    func flashCenterSizePreview(widthFraction: Double, heightFraction: Double, label: String) {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }
        let snapConfig = ConfigManager.shared.config.windowSnapper
        displayRegistry.refresh(gaps: snapConfig.gaps)
        let displays = displayRegistry.connectedDisplays
        guard !displays.isEmpty else { return }

        overlayController.flashZoneStylePreview(
            on: displays,
            zonesProvider: { display in
                guard let zone = SnapGeometry.resolveUniversalOrBuiltInZone(
                    id: "universal:center",
                    usableAXRect: display.usableAX,
                    primaryScreenHeight: display.primaryScreenHeight,
                    gaps: snapConfig.gaps,
                    layoutOverride: nil,
                    centerWidthFraction: widthFraction,
                    centerHeightFraction: heightFraction
                ) else {
                    return []
                }
                return [zone]
            },
            bannerText: "Center Window · \(label)",
            style: snapConfig.overlayStyle,
            showZoneLabels: snapConfig.overlayStyle.showZoneLabelsAndDimensions
        )
    }

    private func flashStylePreviewOverlay(
        gaps: GapConfig,
        style: OverlayStyleConfig,
        banner: String,
        showZoneLabels: Bool = false
    ) {
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }
        displayRegistry.refresh(gaps: gaps)
        let displays = displayRegistry.connectedDisplays
        guard !displays.isEmpty else { return }

        overlayController.flashZoneStylePreview(
            on: displays,
            zonesProvider: { display in
                SnapGeometry.stylePreviewZonesAX(
                    usableAXRect: display.usableAX,
                    primaryScreenHeight: display.primaryScreenHeight,
                    gaps: gaps
                )
            },
            bannerText: banner,
            style: style,
            showZoneLabels: showZoneLabels
        )
    }

    func previewProfile(_ profile: WorkspaceProfile, duration: TimeInterval = 3.0) {
        profileEngine.previewProfile(
            profile,
            config: ConfigManager.shared.config.windowSnapper,
            autoHideAfter: duration
        )
    }

    /// Activates a profile from any UI path (Apply button, status bar menu, shortcut).
    /// Toggling is intentional: pressing the activation control while the profile is
    /// already active and a restore snapshot is stored restores the previous workspace.
    func applyProfile(_ profile: WorkspaceProfile) {
        glassPaneController.dismiss()
        guard ensureAccessibilityForAction() else { return }
        profileEngine.toggleOrApplyProfile(profile) { [weak self] batch in
            self?.recordBatchInPreSnapStore(batch)
        }
    }

    /// Applies a profile unconditionally without toggle-restoring the previous workspace
    /// (used by Save & Apply in the Profile Editor).
    func applyProfileDirectly(_ profile: WorkspaceProfile) {
        glassPaneController.dismiss()
        guard ensureAccessibilityForAction() else { return }
        profileEngine.cancelInFlightApply()
        profileEngine.applyProfile(profile) { [weak self] batch in
            self?.recordBatchInPreSnapStore(batch)
        }
    }

    func triggerProfileShortcut(_ profile: WorkspaceProfile) {
        applyProfile(profile)
    }

    func swapExternalDisplays() {
        var cfg = ConfigManager.shared.config.windowSnapper
        cfg.swapExternalDisplays.toggle()
        ConfigManager.shared.config.windowSnapper = cfg

        let targetProfile = cfg.activeProfileID.flatMap { id in cfg.profiles.first(where: { $0.id == id }) }
            ?? cfg.autoApplyProfileID.flatMap { id in cfg.profiles.first(where: { $0.id == id }) }

        if displayRegistry.connectedDisplays.count >= 3,
           let profile = targetProfile,
           ensureAccessibilityForAction() {
            glassPaneController.dismiss()
            profileEngine.applyProfile(profile) { [weak self] batch in
                self?.recordBatchInPreSnapStore(batch)
            }
        } else if cfg.showSnapHUDToasts {
            HUDToast.shared.show(
                title: cfg.swapExternalDisplays ? "Swapped External Displays" : "Restored External Order",
                subtitle: "External 1 & External 2",
                symbol: "arrow.left.arrow.right",
                tint: .indigo
            )
        }
    }

    func applyDisplayConnectModeNow() {
        let cfg = ConfigManager.shared.config.windowSnapper
        let mode = cfg.displayConnectMode
        guard mode != .systemDefault else { return }
        let changed = displayRegistry.applyDisplayConnectMode(mode)
        if cfg.showSnapHUDToasts {
            let title: String
            switch mode {
            case .alwaysExtend:
                title = changed ? "Extended Displays" : "Already Extended"
            case .alwaysMirror:
                title = changed ? "Mirrored Displays" : "Already Mirrored"
            case .systemDefault:
                return
            }
            HUDToast.shared.show(
                title: title,
                symbol: "display.2",
                tint: .indigo
            )
        }
    }

    func identifyDisplays() {
        overlayController.showDisplayIdentification(
            displays: displayRegistry.connectedDisplays,
            swapExternalDisplays: ConfigManager.shared.config.windowSnapper.swapExternalDisplays,
            style: ConfigManager.shared.config.windowSnapper.overlayStyle,
            duration: 2.2
        )
    }

    func captureOpenWindowsForVariant(
        displayCount: Int,
        completion: @escaping @MainActor (ProfileDisplayVariant) -> Void
    ) {
        profileEngine.captureCurrentWindowsForVariant(
            displayCount: displayCount,
            config: ConfigManager.shared.config.windowSnapper,
            completion: completion
        )
    }

    private func placeGlassPaneCandidate(
        candidate: AppCardCandidate,
        preResolvedWindow: DiscoveredAXWindow?,
        targetZone: ResolvedZone,
        targetDisplay: ConnectedDisplay
    ) {
        guard ensureAccessibilityForAction() else { return }
        axController.resolveAndActivateWindow(
            forCandidate: candidate,
            preResolvedWindow: preResolvedWindow
        ) { [weak self] resolvedWin in
            guard let self else { return }
            if let win = resolvedWin ?? preResolvedWindow {
                self.commitSnap(
                    window: win,
                    targetZone: targetZone,
                    targetDisplay: targetDisplay,
                    isKeyboardSnap: false
                )
            } else if self.config.showSnapHUDToasts {
                HUDToast.shared.show(
                    title: "Couldn't move \(candidate.appName) window",
                    symbol: "exclamationmark.triangle",
                    tint: .orange
                )
            }
        }
    }

    func captureCurrentWorkspaceAsProfile(name: String, completion: @escaping @MainActor (WorkspaceProfile) -> Void) {
        profileEngine.captureCurrentWorkspace(
            name: name,
            config: ConfigManager.shared.config.windowSnapper,
            completion: completion
        )
    }

    func beginOnScreenLayoutEditor(for display: ConnectedDisplay) {
        let currentLayout = ensureDisplayLayout(for: display.signature)
        beginOnScreenLayoutEditor(for: display, initialLayout: currentLayout) { [weak self] updatedLayout in
            self?.saveDisplayLayout(updatedLayout)
        }
    }

    func beginOnScreenLayoutEditor(
        for display: ConnectedDisplay,
        initialLayout: DisplayLayoutConfig,
        onCommit: @escaping (DisplayLayoutConfig) -> Void
    ) {
        let snapConfig = ConfigManager.shared.config.windowSnapper
        overlayController.beginOnScreenEditor(
            for: display,
            initialLayout: initialLayout,
            gaps: snapConfig.gaps,
            style: snapConfig.overlayStyle,
            onCommitLayout: onCommit
        )
    }

    @discardableResult
    func ensureDisplayLayout(for signature: DisplaySignature) -> DisplayLayoutConfig {
        let layouts = ConfigManager.shared.config.windowSnapper.displayLayouts
        if let existing = DisplayRegistry.layout(for: signature, in: layouts) {
            return existing
        }
        let created = DisplayLayoutConfig(display: signature)
        ConfigManager.shared.config.windowSnapper.displayLayouts.append(created)
        return created
    }

    func saveDisplayLayout(_ updated: DisplayLayoutConfig) {
        var layouts = ConfigManager.shared.config.windowSnapper.displayLayouts
        if let idx = layouts.firstIndex(where: { $0.id == updated.id }) {
            layouts[idx] = updated
        } else if let matchedSig = DisplayRegistry.matchDisplay(for: updated.display, among: layouts.map(\.display)),
                  let idx = layouts.firstIndex(where: { $0.display == matchedSig }) {
            layouts[idx] = updated
        } else {
            layouts.append(updated)
        }
        ConfigManager.shared.config.windowSnapper.displayLayouts = layouts
    }
}
