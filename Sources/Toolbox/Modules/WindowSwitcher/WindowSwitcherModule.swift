import AppKit
import Carbon
import CoreGraphics
import Foundation
import SwiftUI

private final class SwitcherHUDPanel: PointerCursorNSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowSwitcherModule: NSObject, ToolboxModule, ObservableObject {
    let id = "window_switcher"
    let name = "Window Switcher"
    let tagline = "Switch directly between individual open and minimized windows with keyboard navigation and optional live thumbnails."
    let aboutSummary = "macOS ⌘ Tab only switches between applications and skips minimized windows. Window Switcher provides a keyboard-first, window-level HUD (⌥ Tab / ⌥ ⇧ Tab by default) ordered by recency, with optional live thumbnails, type-to-filter, and instant Close, Minimize, Hide, and Quit actions."
    let featureTips = [
        "Hold ⌥ Option and press Tab (or ⇧ Tab) to cycle through individual windows; release ⌥ to focus the selected window.",
        "Use arrow keys to navigate rows or grid cards, press / to pin the HUD open and filter by title or app name, or press Esc to cancel.",
        "With Quick Actions enabled, press W to close, M to minimize/restore, H to hide, or Q to quit the highlighted window's app.",
        "Enable Live Window Thumbnails in Appearance when Screen Recording is granted; without Screen Recording, cards fall back to crisp app icons with zero unexpected prompts."
    ]
    let symbolName = "rectangle.stack"
    let accentColor = Color.indigo
    let category: ModuleCategory = .windowAndDock
    let requiresAccessibility = true
    let accessibilityReason = "Required to detect trigger keystrokes and modifier-release events (⌥/⌃/⌘) globally, inspect open and minimized windows, and raise or manage windows."

    let currentAppHotKeyName = "window_switcher.current_app"

    @Published private(set) var isRunning = false
    @Published private(set) var isTapInstalled = false
    @Published private(set) var isHUDVisible = false
    @Published private(set) var switchesCompletedCount: Int = 0
    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var isAwaitingScreenPermission: Bool = false
    @Published private(set) var lastError: String? = nil

    let hudStore = WindowSwitcherHUDStore()

    private var config = WindowSwitcherConfig()
    private let eventTap = WindowSwitcherEventTap()
    private let thumbnailProvider = WindowThumbnailProvider()
    private var mruTracker = WindowMRUTracker()
    private var handlesByID: [String: WindowAXHandle] = [:]

    private let enumQueue = DispatchQueue(label: "app.toolbox.window-switcher.enum", qos: .userInteractive)
    private var openGeneration: UInt64 = 0
    private var isOpeningSession = false
    private var pendingCycleDelta: Int = 0
    private var pendingCommitBeforeOpen = false
    private var panel: SwitcherHUDPanel?
    private var outsideClickMonitor: Any?
    private var localMouseMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var watchdogTimer: Timer?
    private var isHoldSession = false
    private var hudOpenedAt: Date = .distantPast

    private var hasPromptedScreenThisSession = false
    private var isScreenRequestInFlight = false
    private var awaitingScreenGrantDeadline: Date?
    private var recentScreenGrantUntil: Date = .distantPast
    private var screenPermissionPollTask: Task<Void, Never>?
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?

    /// True while awaiting or right after granting Screen Recording so macOS System Settings'
    /// "Quit & Reopen" button can terminate and relaunch Toolbox even when `dockQuitBehavior == .closeWindow`.
    var shouldAllowSystemQuitAndReopen: Bool {
        isAwaitingScreenPermission || Date() <= recentScreenGrantUntil
    }

    internal var runsTapOnBackgroundThreadForTesting: Bool {
        eventTap.runsOnDedicatedBackgroundRunLoopForTesting
    }

    override init() {
        super.init()
        screenRecordingGranted = ScreenCapturePermission.isGranted
        wireCallbacks()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeLiveScreenPermission()
            }
        }
    }

    deinit {
        screenPermissionPollTask?.cancel()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    // MARK: - ToolboxModule

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.windowSwitcher.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.windowSwitcher.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.windowSwitcher.triggerShortcutSpec.displayString
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !isEnabled(in: config) { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if !accessibilityGranted { return "Needs Accessibility" }
        return isTapInstalled ? "Active" : "Standby"
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installWorkspaceObserver()
        syncSubsystems()
        ModuleRegistry.shared.notifyChanged()
    }

    func stop() {
        stopAwaitingScreenGrant()
        guard isRunning || eventTap.isInstalled || HotKeyManager.shared.isRegistered(name: currentAppHotKeyName) || isHUDVisible || isOpeningSession else {
            return
        }
        dismissHUD(cancelOnly: true)
        removeWorkspaceObserver()
        HotKeyManager.shared.unregister(name: currentAppHotKeyName)
        eventTap.uninstall()
        thumbnailProvider.cancelActiveCapture()
        isTapInstalled = false
        lastError = nil
        isRunning = false
        ModuleRegistry.shared.notifyChanged()
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.windowSwitcher
        hudStore.showThumbnails = config.showThumbnails
        hudStore.enableQuickActions = config.enableQuickActions
        hudStore.triggerModifier = config.triggerModifier
        hudStore.triggerKeyLabel = ShortcutSpec(
            key: config.normalizedTriggerKey,
            modifiers: []
        ).keyDisplayLabel

        if fullConfig.general.appEnabled && config.enabled {
            if !isRunning {
                start()
            } else {
                syncSubsystems()
            }
        } else {
            if isRunning {
                stop()
            } else {
                HotKeyManager.shared.unregister(name: currentAppHotKeyName)
            }
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(WindowSwitcherSettingsView(module: self))
    }

    // MARK: - Screen Recording Permission (Optional Thumbnails)

    func refreshScreenPermission() {
        applyScreenPermission(ScreenCapturePermission.isGranted)
    }

    func probeLiveScreenPermission() {
        ScreenCapturePermission.probeUncachedAsync { [weak self] granted in
            self?.applyScreenPermission(granted)
        }
    }

    private func applyScreenPermission(_ granted: Bool) {
        let wasGranted = screenRecordingGranted
        if granted != screenRecordingGranted {
            screenRecordingGranted = granted
        }
        if granted {
            let awaiting = awaitingScreenGrantDeadline.map { Date() <= $0 } ?? false
            stopAwaitingScreenGrant()
            if awaiting && !wasGranted && !PermissionsManager.isRunningInDiagnosticMode {
                recentScreenGrantUntil = Date().addingTimeInterval(60)
                HUDToast.shared.show(
                    title: "Screen Recording granted — Window Switcher thumbnails ready",
                    symbol: "checkmark.shield.fill",
                    tint: .green
                )
            }
        } else if let deadline = awaitingScreenGrantDeadline, Date() > deadline {
            stopAwaitingScreenGrant()
        }
    }

    func requestScreenAccess() {
        refreshScreenPermission()
        guard !screenRecordingGranted else { return }
        guard !isScreenRequestInFlight else { return }

        beginAwaitingScreenGrant()

        guard !PermissionsManager.isRunningInDiagnosticMode else { return }

        if hasPromptedScreenThisSession {
            openScreenSettings()
            return
        }

        hasPromptedScreenThisSession = true
        isScreenRequestInFlight = true
        if PermissionsManager.hasSystemPermissionPromptWindow() {
            isScreenRequestInFlight = false
            return
        }
        _ = ScreenCapturePermission.requestAccess()

        let appearDeadline = Date().addingTimeInterval(1.1)
        func checkPromptAppearance() {
            MainActor.assumeIsolated {
                self.probeLiveScreenPermission()
                if self.screenRecordingGranted || PermissionsManager.hasSystemPermissionPromptWindow() {
                    self.isScreenRequestInFlight = false
                    return
                }
                if Date() >= appearDeadline {
                    self.isScreenRequestInFlight = false
                    self.openScreenSettings()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        checkPromptAppearance()
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            checkPromptAppearance()
        }
    }

    func openScreenSettings() {
        beginAwaitingScreenGrant()
        ScreenCapturePermission.openSystemSettings()
    }

    private func beginAwaitingScreenGrant() {
        isAwaitingScreenPermission = true
        awaitingScreenGrantDeadline = Date().addingTimeInterval(120)
        screenPermissionPollTask?.cancel()
        screenPermissionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled { return }
                guard let self,
                      let deadline = self.awaitingScreenGrantDeadline,
                      Date() <= deadline else {
                    self?.stopAwaitingScreenGrant()
                    return
                }
                self.probeLiveScreenPermission()
                if self.screenRecordingGranted {
                    return
                }
            }
        }
    }

    private func stopAwaitingScreenGrant() {
        isAwaitingScreenPermission = false
        awaitingScreenGrantDeadline = nil
        screenPermissionPollTask?.cancel()
        screenPermissionPollTask = nil
    }

    func setScreenRecordingGrantedForTesting(_ granted: Bool) {
        screenRecordingGranted = granted
    }

    // MARK: - Public Actions & Preview

    func openCurrentAppSwitcher() {
        let fullConfig = ConfigManager.shared.config
        guard fullConfig.general.appEnabled,
              fullConfig.windowSwitcher.enabled,
              PermissionsManager.isProcessTrusted() else {
            return
        }
        let frontApp = NSWorkspace.shared.frontmostApplication
        beginSwitcherSession(
            reverse: false,
            holdTriggered: false,
            currentAppOnlyPID: frontApp?.processIdentifier,
            currentAppName: frontApp?.localizedName
        )
    }

    func openPreviewHUD() {
        let fullConfig = ConfigManager.shared.config
        guard fullConfig.general.appEnabled else { return }
        beginSwitcherSession(
            reverse: false,
            holdTriggered: false,
            currentAppOnlyPID: nil,
            currentAppName: nil
        )
    }

    // MARK: - Subsystem Sync

    private func wireCallbacks() {
        eventTap.onDecision = { [weak self] decision in
            self?.handleTapDecision(decision)
        }
    }

    private func syncSubsystems() {
        let trusted = PermissionsManager.isProcessTrusted()
        eventTap.updateConfig(config)

        let wasTapInstalled = eventTap.isInstalled
        if isRunning && trusted {
            if !eventTap.isInstalled {
                if eventTap.install() {
                    lastError = nil
                } else {
                    lastError = "Failed to install Window Switcher keyboard tap (toggle Accessibility off/on in System Settings if you upgraded from an unsigned build)."
                }
            } else {
                lastError = nil
            }
        } else {
            dismissHUD(cancelOnly: true)
            eventTap.uninstall()
            lastError = nil
        }

        isTapInstalled = eventTap.isInstalled
        if isTapInstalled != wasTapInstalled {
            DeveloperEventLog.shared.record(
                .windowSwitcher,
                isTapInstalled ? "Window Switcher tap installed" : "Window Switcher tap uninstalled"
            )
        }

        if isRunning && trusted && !config.currentAppOnlyShortcut.isEmpty {
            HotKeyManager.shared.register(
                name: currentAppHotKeyName,
                shortcut: config.currentAppOnlyShortcut
            ) { [weak self] in
                self?.openCurrentAppSwitcher()
            }
        } else {
            HotKeyManager.shared.unregister(name: currentAppHotKeyName)
        }

        if !trusted {
            dismissHUD(cancelOnly: true)
        }
        ModuleRegistry.shared.notifyChanged()
    }

    // MARK: - Workspace & MRU Tracking

    private func installWorkspaceObserver() {
        removeWorkspaceObserver()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular {
            mruTracker.recordAppActivation(pid: front.processIdentifier)
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let app, app.activationPolicy == .regular {
                    self.mruTracker.recordAppActivation(pid: app.processIdentifier)
                }
                if self.isHUDVisible,
                   let pid = app?.processIdentifier,
                   pid != ProcessInfo.processInfo.processIdentifier {
                    self.dismissHUD(cancelOnly: true)
                }
            }
        }
    }

    private func removeWorkspaceObserver() {
        if let obs = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceActivationObserver = nil
        }
    }

    // MARK: - Event Tap Dispatch

    private func handleTapDecision(_ decision: WindowSwitcherTapDecision) {
        if !hudStore.state.isOpen && isOpeningSession {
            switch decision {
            case .openAndCycle(let reverse):
                pendingCycleDelta += (reverse ? -1 : 1)
                return
            case .cycleForward:
                pendingCycleDelta += 1
                return
            case .cycleBackward:
                pendingCycleDelta -= 1
                return
            case .navigate(let direction):
                switch direction {
                case .down, .right: pendingCycleDelta += 1
                case .up, .left: pendingCycleDelta -= 1
                }
                return
            case .commit:
                pendingCommitBeforeOpen = true
                return
            case .cancel:
                dismissHUD(cancelOnly: true)
                return
            default:
                break
            }
        }

        switch decision {
        case .passThrough, .swallowOnly:
            break
        case .openAndCycle(let reverse):
            if !isHUDVisible && !isOpeningSession {
                beginSwitcherSession(
                    reverse: reverse,
                    holdTriggered: true,
                    currentAppOnlyPID: nil,
                    currentAppName: nil
                )
            } else if reverse {
                hudStore.state.cycleBackward()
            } else {
                hudStore.state.cycleForward()
            }
        case .cycleForward:
            hudStore.state.cycleForward()
        case .cycleBackward:
            hudStore.state.cycleBackward()
        case .navigate(let direction):
            hudStore.state.navigate(direction)
        case .quickAction(let action):
            performQuickAction(action, at: hudStore.state.selectedIndex)
        case .enterFilterMode:
            hudStore.state.isFilterModeActive = true
            updatePanelLayoutSize()
        case .appendFilterChar(let char):
            hudStore.state.appendFilterCharacter(char)
            updatePanelLayoutSize()
        case .backspaceFilter:
            hudStore.state.backspaceFilter()
            updatePanelLayoutSize()
        case .commit:
            commitSelection()
        case .cancel:
            dismissHUD(cancelOnly: true)
        }
    }

    // MARK: - Session Lifecycle

    private func beginSwitcherSession(
        reverse: Bool,
        holdTriggered: Bool,
        currentAppOnlyPID: pid_t?,
        currentAppName: String?
    ) {
        openGeneration &+= 1
        let generation = openGeneration
        let activeConfig = config
        let snapshotTracker = mruTracker
        let panelWindowNum = panel?.windowNumber
        let activeDisplayBounds = activeDisplayBoundsAX()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let showThumbs = activeConfig.showThumbnails
        let screenGranted = ScreenCapturePermission.isGranted
        screenRecordingGranted = screenGranted

        isOpeningSession = true
        pendingCycleDelta = 0
        pendingCommitBeforeOpen = false
        isHoldSession = holdTriggered
        eventTap.setHUDSessionState(
            isOpen: true,
            isHoldTriggered: holdTriggered,
            isFilterModeActive: false
        )

        // Phase 1: Instant open using WindowServer on-screen list + self windows (zero AX IPC delay).
        let onScreenEntries = WindowEnumerator.onScreenLayerZeroEntries(excludingPanelWindowNumber: panelWindowNum)
        var zOrderMap: [Int: Int] = [:]
        for entry in onScreenEntries {
            zOrderMap[entry.windowNumber] = entry.zOrderRank
        }
        let (selfItems, selfHandles) = WindowEnumerator.enumerateSelfWindows(
            excludingPanelWindowNumber: panelWindowNum,
            zOrderByWindowNumber: zOrderMap
        )
        let (fastItems, fastHandles) = WindowEnumerator.fastOnScreenItems(
            from: onScreenEntries,
            excludingPID: selfPID
        )

        var initialHandles = fastHandles
        for (k, v) in selfHandles {
            initialHandles[k] = v
        }
        let initialCombined = selfItems + fastItems
        let initialSorted = WindowEnumerator.filterAndSort(
            items: initialCombined,
            config: activeConfig,
            mruTracker: snapshotTracker,
            activeDisplayBoundsAX: activeDisplayBounds,
            currentAppOnlyPID: currentAppOnlyPID,
            query: ""
        )

        isOpeningSession = false
        handlesByID = initialHandles
        hudStore.showThumbnails = showThumbs
        hudStore.enableQuickActions = activeConfig.enableQuickActions
        hudStore.triggerModifier = activeConfig.triggerModifier
        hudStore.triggerKeyLabel = ShortcutSpec(
            key: activeConfig.normalizedTriggerKey,
            modifiers: []
        ).keyDisplayLabel
        hudStore.currentAppName = currentAppName
        hudStore.iconsByPID = Self.resolveAppIcons(for: initialSorted)

        let initialWinNumbers = initialSorted.compactMap(\.windowNumber)
        hudStore.thumbnailsByWindowNumber = showThumbs && screenGranted
            ? thumbnailProvider.cachedThumbnails(for: initialWinNumbers)
            : [:]

        hudStore.state.open(
            windows: initialSorted,
            reverse: reverse,
            layoutStyle: activeConfig.layoutStyle,
            currentAppOnly: currentAppOnlyPID != nil
        )
        presentHUDPanel()

        if showThumbs && screenGranted {
            thumbnailProvider.captureThumbnails(
                for: initialWinNumbers,
                showThumbnails: true,
                permissionGranted: true
            ) { [weak self] winNum, image in
                guard let self, self.isHUDVisible, self.openGeneration == generation else { return }
                self.hudStore.thumbnailsByWindowNumber[winNum] = image
            }
        }

        // Phase 2: Enrich concurrently in background via AX (minimized windows, hidden apps, full titles).
        enumQueue.async { [weak self] in
            let (extItems, extHandles) = WindowEnumerator.enumerateExternalWindows(
                excludingPID: selfPID,
                onScreenEntries: onScreenEntries
            )
            let combinedItems = selfItems + extItems
            var combinedHandles = extHandles
            for (k, v) in selfHandles {
                combinedHandles[k] = v
            }

            let sorted = WindowEnumerator.filterAndSort(
                items: combinedItems,
                config: activeConfig,
                mruTracker: snapshotTracker,
                activeDisplayBoundsAX: activeDisplayBounds,
                currentAppOnlyPID: currentAppOnlyPID,
                query: ""
            )

            Task { @MainActor [weak self] in
                guard let self,
                      self.openGeneration == generation,
                      self.isHUDVisible else {
                    return
                }
                let livePIDs = Set(combinedItems.map(\.pid))
                self.mruTracker.pruneDeadPIDs(livePIDs)
                self.handlesByID = combinedHandles
                for (pid, icon) in Self.resolveAppIcons(for: sorted) where self.hudStore.iconsByPID[pid] == nil {
                    self.hudStore.iconsByPID[pid] = icon
                }

                self.hudStore.state.mergeEnrichedWindows(sorted)
                self.updatePanelLayoutSize()
                if let p = self.panel {
                    self.centerPanelOnActiveScreen(p)
                }

                if showThumbs && screenGranted {
                    let allWinNumbers = sorted.compactMap(\.windowNumber)
                    let missingThumbNumbers = allWinNumbers.filter { self.hudStore.thumbnailsByWindowNumber[$0] == nil }
                    if !missingThumbNumbers.isEmpty {
                        for (winNum, img) in self.thumbnailProvider.cachedThumbnails(for: missingThumbNumbers) {
                            self.hudStore.thumbnailsByWindowNumber[winNum] = img
                        }
                        let stillMissing = missingThumbNumbers.filter { self.hudStore.thumbnailsByWindowNumber[$0] == nil }
                        if !stillMissing.isEmpty {
                            self.thumbnailProvider.captureThumbnails(
                                for: stillMissing,
                                showThumbnails: true,
                                permissionGranted: true
                            ) { [weak self] winNum, image in
                                guard let self, self.isHUDVisible, self.openGeneration == generation else { return }
                                self.hudStore.thumbnailsByWindowNumber[winNum] = image
                            }
                        }
                    }
                }
            }
        }
    }

    private func presentHUDPanel() {
        let hudPanel = ensureHUDPanel()
        updatePanelLayoutSize()
        centerPanelOnActiveScreen(hudPanel)
        hudOpenedAt = Date()
        hudPanel.orderFrontRegardless()
        isHUDVisible = true
        installOutsideClickMonitors(for: hudPanel)
        startWatchdogTimerIfNeeded()
        PointerCursorNSView.syncCursor(in: hudPanel)
    }

    private func ensureHUDPanel() -> SwitcherHUDPanel {
        if let panel { return panel }

        let created = SwitcherHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 256),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .popUpMenu
        created.isOpaque = false
        created.isMovableByWindowBackground = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.acceptsMouseMovedEvents = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ToolboxTheme.applyDarkAppearance(to: created)

        let rootView = WindowSwitcherPanelView(
            store: hudStore,
            onSelectIndex: { [weak self] idx in
                guard let self else { return }
                self.hudStore.state.selectedIndex = idx
                self.commitSelection()
            },
            onHoverIndex: { [weak self] idx in
                guard let self, self.hudStore.state.selectedIndex != idx else { return }
                self.hudStore.state.selectedIndex = idx
            },
            onToggleLayout: { [weak self] style in
                guard let self else { return }
                self.hudStore.state.layoutStyle = style
                ConfigManager.shared.config.windowSwitcher.layoutStyle = style
                self.updatePanelLayoutSize()
                if let p = self.panel {
                    self.centerPanelOnActiveScreen(p)
                }
            },
            onToggleFilterMode: { [weak self] in
                guard let self else { return }
                let next = !self.hudStore.state.isFilterModeActive
                self.hudStore.state.isFilterModeActive = next
                self.eventTap.setHUDSessionState(
                    isOpen: true,
                    isHoldTriggered: self.isHoldSession,
                    isFilterModeActive: next
                )
                self.updatePanelLayoutSize()
            },
            onClearFilter: { [weak self] in
                guard let self else { return }
                self.hudStore.state.updateFilter("")
                self.updatePanelLayoutSize()
            },
            onQuickAction: { [weak self] action, idx in
                self?.performQuickAction(action, at: idx)
            },
            onCancel: { [weak self] in
                self?.dismissHUD(cancelOnly: true)
            }
        )

        created.contentView = PointerCursorHostingView(rootView: rootView)
        panel = created
        return created
    }

    private func updatePanelLayoutSize() {
        guard let panel else { return }
        let count = max(1, hudStore.state.filteredWindows.count)
        let hasFilterBar = hudStore.state.isFilterModeActive || !hudStore.state.filterQuery.isEmpty

        let targetSize: NSSize
        switch hudStore.state.layoutStyle {
        case .strip:
            let mouse = NSEvent.mouseLocation
            let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
            let maxWidth = max(560, (activeScreen?.visibleFrame.width ?? 1280) - 80)
            let desiredWidth = CGFloat(min(6, count)) * 192 + 32
            let width = min(maxWidth, max(540, desiredWidth))
            let height: CGFloat = (hudStore.state.filteredWindows.isEmpty ? 200 : 228) + (hasFilterBar ? 34 : 0)
            targetSize = NSSize(width: width, height: height)

        case .list:
            let chromeHeight: CGFloat = 90 + (hasFilterBar ? 34 : 0)
            let rowHeight: CGFloat = hudStore.showThumbnails ? 57 : 51
            let bodyHeight = min(380, max(160, CGFloat(count) * rowHeight + 20))
            targetSize = NSSize(width: 560, height: min(500, max(240, chromeHeight + bodyHeight)))
        }

        let current = panel.frame
        if abs(current.width - targetSize.width) > 1 || abs(current.height - targetSize.height) > 1 {
            let newOrigin = NSPoint(
                x: current.midX - targetSize.width / 2,
                y: current.midY - targetSize.height / 2
            )
            panel.setFrame(NSRect(origin: newOrigin, size: targetSize), display: true)
        }
    }

    private func centerPanelOnActiveScreen(_ hudPanel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = hudPanel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        hudPanel.setFrameOrigin(origin)
    }

    // MARK: - Commit, Cancel & Quick Actions

    private func commitSelection() {
        openGeneration &+= 1
        let chosen = hudStore.state.commit()
        tearDownHUDChrome()

        guard let chosen else { return }
        mruTracker.recordWindowActivation(windowID: chosen.id, pid: chosen.pid)
        let handle = handlesByID[chosen.id]
        handlesByID.removeAll()

        WindowEnumerator.focusWindow(chosen, handle: handle)
        switchesCompletedCount += 1
        DeveloperEventLog.shared.record(
            .windowSwitcher,
            "Switched to \(chosen.appName)",
            detail: chosen.displayTitle
        )
    }

    func dismissHUD(cancelOnly: Bool) {
        openGeneration &+= 1
        if cancelOnly {
            hudStore.state.cancel()
        }
        handlesByID.removeAll()
        tearDownHUDChrome()
    }

    private func tearDownHUDChrome() {
        isOpeningSession = false
        pendingCycleDelta = 0
        pendingCommitBeforeOpen = false
        isHoldSession = false
        eventTap.setHUDSessionState(isOpen: false, isHoldTriggered: false, isFilterModeActive: false)
        thumbnailProvider.cancelActiveCapture()
        stopWatchdogTimer()
        removeOutsideClickMonitors()
        panel?.orderOut(nil)
        isHUDVisible = false
    }

    private func performQuickAction(_ action: SwitcherQuickAction, at index: Int) {
        guard config.enableQuickActions,
              index >= 0,
              index < hudStore.state.filteredWindows.count else {
            return
        }
        let item = hudStore.state.filteredWindows[index]
        let handle = handlesByID[item.id]

        switch action {
        case .close:
            if WindowEnumerator.closeWindow(item, handle: handle) {
                hudStore.state.removeWindow(id: item.id)
                handlesByID.removeValue(forKey: item.id)
                DeveloperEventLog.shared.record(.windowSwitcher, "Closed window", detail: "\(item.appName) — \(item.displayTitle)")
            }

        case .toggleMinimize:
            let nextMinimized = WindowEnumerator.toggleMinimize(item, handle: handle)
            let updated = SwitcherWindowItem(
                id: item.id,
                pid: item.pid,
                windowNumber: item.windowNumber,
                bundleIdentifier: item.bundleIdentifier,
                appName: item.appName,
                title: item.title,
                frameAX: item.frameAX,
                isMinimized: nextMinimized,
                isHiddenApp: item.isHiddenApp,
                isOnActiveSpace: item.isOnActiveSpace,
                zOrderRank: item.zOrderRank
            )
            hudStore.state.updateWindow(updated)
            DeveloperEventLog.shared.record(
                .windowSwitcher,
                nextMinimized ? "Minimized window" : "Restored window",
                detail: "\(item.appName) — \(item.displayTitle)"
            )

        case .hideApp:
            if WindowEnumerator.hideApp(pid: item.pid) {
                for idx in hudStore.state.allWindows.indices where hudStore.state.allWindows[idx].pid == item.pid {
                    let w = hudStore.state.allWindows[idx]
                    hudStore.state.updateWindow(
                        SwitcherWindowItem(
                            id: w.id,
                            pid: w.pid,
                            windowNumber: w.windowNumber,
                            bundleIdentifier: w.bundleIdentifier,
                            appName: w.appName,
                            title: w.title,
                            frameAX: w.frameAX,
                            isMinimized: w.isMinimized,
                            isHiddenApp: true,
                            isOnActiveSpace: w.isOnActiveSpace,
                            zOrderRank: w.zOrderRank
                        )
                    )
                }
                if !config.includeHiddenApps {
                    hudStore.state.removeWindows(pid: item.pid)
                }
                DeveloperEventLog.shared.record(.windowSwitcher, "Hid app", detail: item.appName)
            }

        case .quitApp:
            if WindowEnumerator.quitApp(pid: item.pid, bundleID: item.bundleIdentifier) {
                hudStore.state.removeWindows(pid: item.pid)
                DeveloperEventLog.shared.record(.windowSwitcher, "Quit app", detail: item.appName)
            }
        }

        if hudStore.state.filteredWindows.isEmpty && hudStore.state.filterQuery.isEmpty {
            dismissHUD(cancelOnly: true)
        } else {
            updatePanelLayoutSize()
        }
    }

    // MARK: - Monitors & Watchdog

    private func installOutsideClickMonitors(for hudPanel: NSPanel) {
        removeOutsideClickMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak hudPanel] _ in
            Task { @MainActor [weak self, weak hudPanel] in
                guard let self, let hudPanel, hudPanel.isVisible else { return }
                if !hudPanel.frame.contains(NSEvent.mouseLocation) {
                    self.dismissHUD(cancelOnly: true)
                }
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak hudPanel] event in
            guard let self, let hudPanel, hudPanel.isVisible else { return event }
            if let window = event.window,
               window !== hudPanel,
               !NSStringFromClass(type(of: window)).contains("Menu"),
               !hudPanel.frame.contains(NSEvent.mouseLocation) {
                self.dismissHUD(cancelOnly: true)
            }
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func startWatchdogTimerIfNeeded() {
        stopWatchdogTimer()
        guard isHoldSession else { return }

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isHUDVisible else {
                    self?.stopWatchdogTimer()
                    return
                }
                if IsSecureEventInputEnabled() {
                    self.dismissHUD(cancelOnly: true)
                    return
                }
                if Date().timeIntervalSince(self.hudOpenedAt) >= 0.25,
                   self.isHoldSession,
                   !self.hudStore.state.isFilterModeActive {
                    if !Self.isModifierHeldInSession(self.config.triggerModifier) {
                        self.commitSelection()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdogTimer() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private static func isModifierHeldInSession(_ modifier: SwitcherTriggerModifier) -> Bool {
        let hidFlags = CGEventSource.flagsState(.hidSystemState)
        let combinedFlags = CGEventSource.flagsState(.combinedSessionState)
        let cocoaFlags = NSEvent.modifierFlags
        let matchesCocoa: Bool = {
            switch modifier {
            case .option: return cocoaFlags.contains(.option)
            case .control: return cocoaFlags.contains(.control)
            case .command: return cocoaFlags.contains(.command)
            }
        }()
        return hidFlags.contains(modifier.cgEventFlag)
            || combinedFlags.contains(modifier.cgEventFlag)
            || matchesCocoa
    }

    private func activeDisplayBoundsAX() -> CGRect? {
        DisplayRegistry.shared.refresh(gaps: ConfigManager.shared.config.windowSnapper.gaps)
        let mouseAX = CGEvent(source: nil)?.location ?? .zero
        return DisplayRegistry.shared.display(containingAXPoint: mouseAX)?.frameAX
    }

    private static func resolveAppIcons(for items: [SwitcherWindowItem]) -> [pid_t: NSImage] {
        var icons: [pid_t: NSImage] = [:]
        for item in items where icons[item.pid] == nil {
            if let app = NSRunningApplication(processIdentifier: item.pid), let icon = app.icon {
                icons[item.pid] = icon
            } else if !item.bundleIdentifier.isEmpty,
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier) {
                icons[item.pid] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return icons
    }
}
