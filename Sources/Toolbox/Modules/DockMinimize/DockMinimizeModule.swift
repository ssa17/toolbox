import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class DockMinimizeModule: ToolboxModule, ObservableObject {
    let id = "dock_minimize"
    let name = "Dock Click to Minimize"
    let tagline = "Click an active app in the Dock to make it disappear and click again to bring it back."
    let aboutSummary = "Brings Windows taskbar click behavior to the macOS Dock without cluttering the minimized window tray. Clicking the active app's Dock icon makes its windows disappear completely and focuses the window underneath. Clicking the icon again brings its windows right back to the front."
    let featureTips = [
        "Makes windows disappear cleanly without adding thumbnails to the right side of the Dock.",
        "Clicking the Dock icon again (or pressing ⌘ Tab) brings the app's windows right back to the front.",
        "Hold ⌘, ⌥, ⌃, or ⇧ while clicking to keep macOS's native modifier behaviors."
    ]
    let symbolName = "dock.rectangle"
    let accentColor = Color.blue
    let category: ModuleCategory = .windowAndDock
    let requiresAccessibility = true
    let accessibilityReason = "Needed to inspect which Dock icon was clicked and hide, minimize, or restore the app's windows."

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private static let axTimeoutSeconds: Float = 0.1
    private static let minimizeActivationGraceInterval: TimeInterval = 0.35
    private static let hiddenUnderlyingSkipInterval: TimeInterval = 0.5
    /// Pointer travel (in points) beyond which a Dock-icon press is treated as a
    /// drag to reposition the icon rather than a click. Kept small so we yield to
    /// the Dock's own drag handling before the icon has moved far.
    private static let dragThreshold: CGFloat = 4
    /// Marker placed on synthetic `CGEvent`s replayed to the Dock when a press
    /// turns into a drag so our own event tap passes them straight through.
    private static let syntheticEventTag: Int64 = 0x5442444D
    private static let exposeNotifications = [
        "AXExposeShowAllWindows",
        "AXExposeShowFrontWindows",
        "AXExposeShowDesktop",
        "AXExposeExit"
    ]

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    private struct DockAppIdentity {
        let bundleID: String?
        let bundleURLPath: String?
        let title: String?
    }

    private struct WindowInspection {
        var openWindows: [AXUIElement] = []
        var minimizableOpenWindows: [AXUIElement] = []
        var minimizedWindows: [AXUIElement] = []
        var hasActiveFullscreen = false
    }

    private struct SelfWindowInspection {
        var openWindows: [NSWindow] = []
        var minimizedWindows: [NSWindow] = []
        var hasActiveFullscreen = false
    }

    /// The action to take for a Dock click, decided at mouse-down and executed at
    /// mouse-up once we know the gesture was a click and not a drag.
    private enum DockClickAction {
        case unhideAndFocus
        case restore
        case hideApp
        case sendToBack
        case minimizeAll
        case minimizeFrontWindow
    }

    /// A Dock-icon press awaiting its mouse-up so a click (act) can be told apart
    /// from a drag (replay the press and let the Dock reposition the icon).
    private struct PendingDockClick {
        let downLocation: CGPoint
        let flags: CGEventFlags
        let clickCount: Int64
        let app: NSRunningApplication
        let isSelf: Bool
        let action: DockClickAction
        var maxTravel: CGFloat = 0
        var forwardedDownToDock = false
    }

    let hotKeyName = "dock_minimize.toggle"

    private var config = DockMinimizeConfig()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingDockClick: PendingDockClick?
    private var activationObserver: NSObjectProtocol?
    private var dockLaunchObserver: NSObjectProtocol?
    private var exposeObserver: AXObserver?
    private var exposeDockElement: AXUIElement?
    private var isExposeActive = false
    private var recentApps: [NSRunningApplication] = []
    private var minimizedByDockClick: [pid_t: [AXUIElement]] = [:]
    private var minimizedSelfByDockClick: [WeakWindow] = []
    private var lastMinimizeTime: [pid_t: Date] = [:]
    private var hiddenByDockClick: Set<pid_t> = []
    private var recentlyHiddenAt: [pid_t: Date] = [:]

    init() {
        if let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy == .regular {
            recentApps.append(front)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.recordActivatedApp(app)
            }
        }
    }

    private func recordActivatedApp(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        recentApps.removeAll { $0.isTerminated || $0.processIdentifier == app.processIdentifier }
        recentApps.insert(app, at: 0)
        if recentApps.count > 12 {
            recentApps.removeLast(recentApps.count - 12)
        }

        if minimizedByDockClick.count > 16 || recentlyHiddenAt.count > 16 {
            let trackedPIDs = Set(minimizedByDockClick.keys).union(recentlyHiddenAt.keys).union(hiddenByDockClick)
            for trackedPID in trackedPIDs where NSRunningApplication(processIdentifier: trackedPID) == nil {
                minimizedByDockClick.removeValue(forKey: trackedPID)
                lastMinimizeTime.removeValue(forKey: trackedPID)
                recentlyHiddenAt.removeValue(forKey: trackedPID)
                hiddenByDockClick.remove(trackedPID)
            }
        }

        let pid = app.processIdentifier
        if let hiddenAt = recentlyHiddenAt[pid], Date().timeIntervalSince(hiddenAt) >= Self.minimizeActivationGraceInterval {
            recentlyHiddenAt.removeValue(forKey: pid)
            hiddenByDockClick.remove(pid)
        } else if recentlyHiddenAt[pid] == nil {
            hiddenByDockClick.remove(pid)
        }

        if let lastMin = lastMinimizeTime[pid], Date().timeIntervalSince(lastMin) < Self.minimizeActivationGraceInterval {
            return
        }
        guard isRunning,
              config.actionMode == .minimizeAll || config.actionMode == .minimizeFrontWindow else {
            return
        }
        if let bundleID = app.bundleIdentifier, config.excludedBundleIDs.contains(bundleID) {
            return
        }

        let isSelf = pid == ProcessInfo.processInfo.processIdentifier
        let hasTrackedWindows = isSelf ? !minimizedSelfByDockClick.isEmpty : (minimizedByDockClick[pid] != nil)
        guard hasTrackedWindows else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.restoreMinimizedOnActivationIfNeeded(app)
            }
        }
    }

    private func restoreMinimizedOnActivationIfNeeded(_ app: NSRunningApplication) {
        guard isRunning,
              !app.isTerminated,
              config.actionMode == .minimizeAll || config.actionMode == .minimizeFrontWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return
        }

        let pid = app.processIdentifier
        if let lastMin = lastMinimizeTime[pid], Date().timeIntervalSince(lastMin) < Self.minimizeActivationGraceInterval {
            return
        }

        if pid == ProcessInfo.processInfo.processIdentifier {
            let inspection = inspectSelfWindows()
            if inspection.openWindows.isEmpty && !inspection.minimizedWindows.isEmpty && !minimizedSelfByDockClick.isEmpty {
                _ = restoreSelfWindows(minimizedWindows: inspection.minimizedWindows, replacing: nil)
            } else if config.actionMode == .minimizeAll && !inspection.openWindows.isEmpty {
                minimizedSelfByDockClick.removeAll()
            }
            return
        }

        let inspection = inspectWindows(of: pid)
        if inspection.openWindows.isEmpty && !inspection.minimizedWindows.isEmpty && minimizedByDockClick[pid] != nil {
            _ = restoreWindows(of: app, minimizedWindows: inspection.minimizedWindows, replacing: nil)
        } else if config.actionMode == .minimizeAll && !inspection.openWindows.isEmpty {
            minimizedByDockClick.removeValue(forKey: pid)
        }
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.dockMinimize.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.dockMinimize.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.dockMinimize.shortcut.isEmpty ? nil : config.dockMinimize.shortcut.displayString
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.dockMinimize
        if fullConfig.general.appEnabled && config.enabled && PermissionsManager.isProcessTrusted() {
            if !isRunning { start() }
        } else {
            if isRunning { stop() }
        }
        syncHotKey(appEnabled: fullConfig.general.appEnabled)
    }

    private func syncHotKey(appEnabled: Bool) {
        if appEnabled && !config.shortcut.isEmpty {
            HotKeyManager.shared.register(name: hotKeyName, shortcut: config.shortcut) { [weak self] in
                self?.toggleEnabledFromHotKey()
            }
        } else {
            HotKeyManager.shared.unregister(name: hotKeyName)
        }
    }

    private func toggleEnabledFromHotKey() {
        let next = !ConfigManager.shared.config.dockMinimize.enabled
        ConfigManager.shared.config.dockMinimize.enabled = next
        HUDToast.shared.show(
            title: next ? "Dock Minimize On" : "Dock Minimize Off",
            symbol: "dock.rectangle",
            tint: next ? .blue : .secondary
        )
    }

    func start() {
        guard !isRunning else { return }
        guard PermissionsManager.isProcessTrusted() else {
            lastError = "Waiting for Accessibility permission."
            return
        }

        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                if event.getIntegerValueField(.eventSourceUserData) == DockMinimizeModule.syntheticEventTag {
                    return Unmanaged.passUnretained(event)
                }
                let module = Unmanaged<DockMinimizeModule>.fromOpaque(userInfo).takeUnretainedValue()
                let location = event.location
                let flags = event.flags
                let clickCount = event.getIntegerValueField(.mouseEventClickState)
                let shouldConsume = MainActor.assumeIsolated {
                    module.handleEvent(type: type, location: location, flags: flags, clickCount: clickCount)
                }
                return shouldConsume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            lastError = "Failed to install CGEventTap (toggle Accessibility off/on in System Settings if you upgraded from an unsigned build)."
            NSLog("Toolbox: \(lastError ?? "")")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.lastError = nil
        self.isRunning = true

        installExposeObserver()
        if dockLaunchObserver == nil {
            dockLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.dock" else { return }
                MainActor.assumeIsolated {
                    if self?.isRunning == true {
                        self?.installExposeObserver()
                    }
                }
            }
        }
    }

    func stop() {
        HotKeyManager.shared.unregister(name: hotKeyName)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        if let observer = dockLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            dockLaunchObserver = nil
        }
        teardownExposeObserver()
        eventTap = nil
        runLoopSource = nil
        pendingDockClick = nil
        isExposeActive = false
        minimizedByDockClick.removeAll()
        minimizedSelfByDockClick.removeAll()
        lastMinimizeTime.removeAll()
        hiddenByDockClick.removeAll()
        recentlyHiddenAt.removeAll()
        isRunning = false
    }

    func makeSettingsView() -> AnyView {
        AnyView(DockMinimizeSettingsView(module: self))
    }

    /// Fast screen-edge geometry filter so non-Dock clicks skip Accessibility IPC.
    static func isPointNearDockEdge(_ point: CGPoint, inDisplayBounds bounds: CGRect) -> Bool {
        let menuBarHeight: CGFloat = 24
        if point.y - bounds.minY < menuBarHeight {
            return false
        }
        let edgeBand: CGFloat = 160
        let nearBottom = (bounds.maxY - point.y) <= edgeBand
        let nearLeft = (point.x - bounds.minX) <= edgeBand
        let nearRight = (bounds.maxX - point.x) <= edgeBand
        return nearBottom || nearLeft || nearRight
    }

    /// Returns `true` when pointer travel between mouse-down and mouse-up stayed
    /// within `dragThreshold`, meaning the gesture was a click rather than a Dock
    /// icon drag.
    static func shouldExecuteDockClick(downLocation: CGPoint, upLocation: CGPoint, maxTravel: CGFloat) -> Bool {
        let upTravel = hypot(upLocation.x - downLocation.x, upLocation.y - downLocation.y)
        return max(maxTravel, upTravel) <= dragThreshold
    }

    private static func isPointNearDockEdge(_ point: CGPoint) -> Bool {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &displayCount) == .success, displayCount > 0 else {
            return true
        }
        for display in displays.prefix(Int(displayCount)) {
            let bounds = CGDisplayBounds(display)
            if bounds.contains(point) {
                return isPointNearDockEdge(point, inDisplayBounds: bounds)
            }
        }
        return true
    }

    private func installExposeObserver() {
        teardownExposeObserver()
        guard PermissionsManager.isProcessTrusted(),
              let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
            return
        }

        let dockElement = applicationElement(for: dockPID)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, userInfo in
            guard let userInfo else { return }
            let module = Unmanaged<DockMinimizeModule>.fromOpaque(userInfo).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated {
                module.handleExposeNotification(name)
            }
        }
        guard AXObserverCreate(dockPID, callback, &obs) == .success, let observer = obs else {
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.exposeNotifications {
            _ = AXObserverAddNotification(observer, dockElement, name as CFString, selfPtr)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        self.exposeObserver = observer
        self.exposeDockElement = dockElement
        self.isExposeActive = false
    }

    private func teardownExposeObserver() {
        if let observer = exposeObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        exposeObserver = nil
        exposeDockElement = nil
        isExposeActive = false
    }

    private func handleExposeNotification(_ name: String) {
        switch name {
        case "AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop":
            isExposeActive = true
        default:
            isExposeActive = false
        }
    }

    private func handleEvent(type: CGEventType, location: CGPoint, flags: CGEventFlags, clickCount: Int64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pendingDockClick = nil
            if PermissionsManager.shouldRearmEventTap(for: type), let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                Task { @MainActor in
                    PermissionsManager.shared.refresh()
                }
            }
            return false
        }

        if type == .leftMouseDragged {
            guard var pending = pendingDockClick else { return false }
            if pending.forwardedDownToDock {
                return false
            }

            let travelled = hypot(location.x - pending.downLocation.x, location.y - pending.downLocation.y)
            if travelled > pending.maxTravel {
                pending.maxTravel = travelled
            }

            // Still within jitter threshold — keep holding the press back so the Dock
            // does not start a long-press timer if this turns out to be a click.
            if pending.maxTravel <= Self.dragThreshold {
                pendingDockClick = pending
                return true
            }

            // Pointer moved past the drag threshold: replay the held mouse-down and
            // this drag event in order so the Dock can take over and reposition the icon.
            pending.forwardedDownToDock = true
            pendingDockClick = pending
            postSyntheticMouseEvent(
                type: .leftMouseDown,
                location: pending.downLocation,
                flags: pending.flags,
                clickCount: pending.clickCount
            )
            postSyntheticMouseEvent(
                type: .leftMouseDragged,
                location: location,
                flags: flags,
                clickCount: pending.clickCount
            )
            return true
        }

        if type == .leftMouseUp {
            guard let pending = pendingDockClick else { return false }
            pendingDockClick = nil

            // Already handed off to the Dock as a drag — let the release drop the icon.
            if pending.forwardedDownToDock {
                return false
            }

            // Fast flick past the drag threshold without an intermediate drag event:
            // replay down + up to the Dock instead of firing our click action.
            guard Self.shouldExecuteDockClick(
                downLocation: pending.downLocation,
                upLocation: location,
                maxTravel: pending.maxTravel
            ) else {
                postSyntheticMouseEvent(
                    type: .leftMouseDown,
                    location: pending.downLocation,
                    flags: pending.flags,
                    clickCount: pending.clickCount
                )
                postSyntheticMouseEvent(
                    type: .leftMouseUp,
                    location: location,
                    flags: flags,
                    clickCount: pending.clickCount
                )
                return true
            }

            // It was a click: the Dock never saw the press (so no long-press menu or
            // stuck highlight), and we consume the release after running the action.
            let frontmost = NSWorkspace.shared.frontmostApplication
            let isFrontmost = frontmost?.processIdentifier == pending.app.processIdentifier
            let handled = pending.isSelf
                ? executeSelfDockClick(pending.action, app: pending.app, frontmost: frontmost)
                : executeExternalAppDockClick(pending.action, app: pending.app, frontmost: frontmost)

            if handled {
                let appLabel = pending.app.localizedName ?? pending.app.bundleIdentifier ?? "PID \(pending.app.processIdentifier)"
                DeveloperEventLog.shared.record(
                    .dock,
                    "Handled dock click on \(appLabel)",
                    detail: "mode: \(config.actionMode.rawValue) · wasFrontmost: \(isFrontmost)"
                )
            }
            return true
        }

        guard type == .leftMouseDown else { return false }
        pendingDockClick = nil

        if isExposeActive {
            return false
        }

        if config.clickMode == .doubleClick && clickCount < 2 {
            return false
        }

        if config.ignoreModifiedClicks {
            if flags.contains(.maskCommand) || flags.contains(.maskAlternate) || flags.contains(.maskControl) || flags.contains(.maskShift) {
                return false
            }
        }

        guard Self.isPointNearDockEdge(location) else {
            return false
        }

        guard let clicked = dockAppIdentity(at: location) else {
            return false
        }

        if let bundleID = clicked.bundleID,
           config.excludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return false
        }

        guard let clickedApp = resolveRunningApp(for: clicked),
              !clickedApp.isTerminated,
              clickedApp.activationPolicy == .regular else {
            return false
        }

        if let appBundleID = clickedApp.bundleIdentifier,
           config.excludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(appBundleID) == .orderedSame }) {
            return false
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let isFrontmost = frontmost?.processIdentifier == clickedApp.processIdentifier

        let isSelf = clickedApp.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard let action = isSelf
            ? decideSelfDockClick(clickedApp, frontmost: frontmost, isFrontmost: isFrontmost)
            : decideExternalAppDockClick(clickedApp, frontmost: frontmost, isFrontmost: isFrontmost) else {
            return false
        }

        // Hold back the press until we know whether this is a click (execute on
        // release without ever notifying the Dock) or a drag (replay down + drag
        // to the Dock once pointer travel exceeds `dragThreshold`).
        pendingDockClick = PendingDockClick(
            downLocation: location,
            flags: flags,
            clickCount: clickCount,
            app: clickedApp,
            isSelf: isSelf,
            action: action
        )
        return true
    }

    private func postSyntheticMouseEvent(
        type: CGEventType,
        location: CGPoint,
        flags: CGEventFlags,
        clickCount: Int64
    ) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        event.post(tap: .cghidEventTap)
    }

    private func decideSelfDockClick(
        _ selfApp: NSRunningApplication,
        frontmost: NSRunningApplication?,
        isFrontmost: Bool
    ) -> DockClickAction? {
        let pid = selfApp.processIdentifier
        let inspection = inspectSelfWindows()
        if inspection.hasActiveFullscreen {
            return nil
        }

        if isAppHidden(selfApp) {
            if !inspection.openWindows.isEmpty || !inspection.minimizedWindows.isEmpty || hiddenByDockClick.contains(pid) {
                return .unhideAndFocus
            }
            return nil
        }

        if config.actionMode != .sendToBack,
           inspection.openWindows.isEmpty,
           !inspection.minimizedWindows.isEmpty {
            return .restore
        }

        guard isFrontmost, !inspection.openWindows.isEmpty else {
            return nil
        }

        switch config.actionMode {
        case .hideApp: return .hideApp
        case .sendToBack: return .sendToBack
        case .minimizeAll: return .minimizeAll
        case .minimizeFrontWindow: return .minimizeFrontWindow
        }
    }

    private func executeSelfDockClick(
        _ action: DockClickAction,
        app: NSRunningApplication,
        frontmost: NSRunningApplication?
    ) -> Bool {
        let pid = app.processIdentifier
        let inspection = inspectSelfWindows()

        switch action {
        case .unhideAndFocus:
            return unhideAndFocusApp(app, replacing: frontmost)
        case .restore:
            return restoreSelfWindows(minimizedWindows: inspection.minimizedWindows, replacing: frontmost)
        case .hideApp:
            let nextApp = preferredUnderlyingApp(excludingPID: pid)
            return hideApp(app, focusingNext: nextApp)
        case .sendToBack:
            return sendBehindPreviousApp(app)
        case .minimizeAll:
            guard !inspection.openWindows.isEmpty else { return false }
            let nextApp = preferredUnderlyingApp(excludingPID: pid)
            minimizedSelfByDockClick = inspection.openWindows.map { WeakWindow(window: $0) }
            lastMinimizeTime[pid] = Date()
            for window in inspection.openWindows {
                window.miniaturize(nil)
            }
            if let nextApp {
                _ = focusTargetApp(nextApp, replacing: app)
            }
            return true
        case .minimizeFrontWindow:
            guard let targetWin = inspection.openWindows.first else { return false }
            let nextApp = inspection.openWindows.count == 1 ? preferredUnderlyingApp(excludingPID: pid) : nil
            minimizedSelfByDockClick.append(WeakWindow(window: targetWin))
            lastMinimizeTime[pid] = Date()
            targetWin.miniaturize(nil)
            if inspection.openWindows.count == 1 {
                if let nextApp {
                    _ = focusTargetApp(nextApp, replacing: app)
                }
            } else if inspection.openWindows.count > 1 {
                inspection.openWindows[1].makeKeyAndOrderFront(nil)
            }
            return true
        }
    }

    private func decideExternalAppDockClick(
        _ clickedApp: NSRunningApplication,
        frontmost: NSRunningApplication?,
        isFrontmost: Bool
    ) -> DockClickAction? {
        let pid = clickedApp.processIdentifier
        let inspection = inspectWindows(of: pid)
        if inspection.hasActiveFullscreen {
            return nil
        }

        // Step A: Hidden app clicked -> bring its windows straight back to the front.
        if isAppHidden(clickedApp) {
            if !inspection.openWindows.isEmpty || !inspection.minimizedWindows.isEmpty || hiddenByDockClick.contains(pid) {
                return .unhideAndFocus
            }
            return nil
        }

        // Step B: All windows minimized in Dock tray -> restore and focus.
        if config.actionMode != .sendToBack,
           inspection.openWindows.isEmpty,
           !inspection.minimizedWindows.isEmpty {
            return .restore
        }

        // Step C: Active frontmost app clicked -> hide, send behind, or minimize.
        guard isFrontmost else {
            return nil
        }

        switch config.actionMode {
        case .hideApp:
            guard !inspection.openWindows.isEmpty || hasOnScreenLayerZeroWindow(pid: pid) else {
                return nil
            }
            return .hideApp
        case .sendToBack:
            guard !inspection.openWindows.isEmpty || hasOnScreenLayerZeroWindow(pid: pid) else {
                return nil
            }
            return .sendToBack
        case .minimizeAll:
            guard !inspection.minimizableOpenWindows.isEmpty else { return nil }
            return .minimizeAll
        case .minimizeFrontWindow:
            guard !inspection.minimizableOpenWindows.isEmpty else { return nil }
            return .minimizeFrontWindow
        }
    }

    private func executeExternalAppDockClick(
        _ action: DockClickAction,
        app: NSRunningApplication,
        frontmost: NSRunningApplication?
    ) -> Bool {
        let pid = app.processIdentifier
        let inspection = inspectWindows(of: pid)

        switch action {
        case .unhideAndFocus:
            return unhideAndFocusApp(app, replacing: frontmost)
        case .restore:
            return restoreWindows(of: app, minimizedWindows: inspection.minimizedWindows, replacing: frontmost)
        case .hideApp:
            guard !inspection.openWindows.isEmpty || hasOnScreenLayerZeroWindow(pid: pid) else {
                return false
            }
            let nextApp = preferredUnderlyingApp(excludingPID: pid)
            return hideApp(app, focusingNext: nextApp)
        case .sendToBack:
            guard !inspection.openWindows.isEmpty || hasOnScreenLayerZeroWindow(pid: pid) else {
                return false
            }
            return sendBehindPreviousApp(app)
        case .minimizeAll:
            let targets = inspection.minimizableOpenWindows
            guard !targets.isEmpty else { return false }
            let nextApp = preferredUnderlyingApp(excludingPID: pid)
            var didMinimizeAny = false
            for window in targets {
                AXUIElementSetMessagingTimeout(window, Self.axTimeoutSeconds)
                if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                    didMinimizeAny = true
                }
            }
            guard didMinimizeAny else {
                return false
            }
            minimizedByDockClick[pid] = targets
            lastMinimizeTime[pid] = Date()
            if let nextApp {
                _ = focusTargetApp(nextApp, replacing: app)
            }
            return true
        case .minimizeFrontWindow:
            let targets = inspection.minimizableOpenWindows
            guard let targetWin = targets.first else { return false }
            let nextApp = targets.count == 1 ? preferredUnderlyingApp(excludingPID: pid) : nil
            AXUIElementSetMessagingTimeout(targetWin, Self.axTimeoutSeconds)
            guard AXUIElementSetAttributeValue(targetWin, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else {
                return false
            }
            minimizedByDockClick[pid, default: []].append(targetWin)
            lastMinimizeTime[pid] = Date()
            if targets.count == 1 {
                if let nextApp {
                    _ = focusTargetApp(nextApp, replacing: app)
                }
            } else if targets.count > 1 {
                raiseAndMakeMain(targets[1])
            }
            return true
        }
    }

    private func applicationElement(for pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)
        return element
    }

    private func unhideProcess(_ app: NSRunningApplication) {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSApp.unhideWithoutActivation()
            _ = app.unhide()
            return
        }
        let appAX = applicationElement(for: app.processIdentifier)
        _ = AXUIElementSetAttributeValue(appAX, kAXHiddenAttribute as CFString, kCFBooleanFalse)
        _ = app.unhide()
    }

    private func raiseAndMakeMain(_ window: AXUIElement) {
        AXUIElementSetMessagingTimeout(window, Self.axTimeoutSeconds)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func isAppHidden(_ app: NSRunningApplication) -> Bool {
        if app.isHidden {
            return true
        }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier {
            return NSApp.isHidden
        }
        let appAX = applicationElement(for: pid)
        var hiddenVal: AnyObject?
        if AXUIElementCopyAttributeValue(appAX, kAXHiddenAttribute as CFString, &hiddenVal) == .success,
           let hidden = hiddenVal as? Bool {
            return hidden
        }
        return false
    }

    private func resolveHideFocusTarget(
        for app: NSRunningApplication,
        preferredNext: NSRunningApplication?
    ) -> NSRunningApplication? {
        if let preferredNext {
            return preferredNext
        }
        // When no other window is visible on screen, focus windowless Finder (Desktop)
        // before hiding so macOS does not refuse to hide the last unhidden app.
        guard app.bundleIdentifier != "com.apple.finder",
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              !finder.isTerminated,
              !hasOpenNonMinimizedWindow(pid: finder.processIdentifier) else {
            return nil
        }
        if isAppHidden(finder) {
            unhideProcess(finder)
        }
        return finder
    }

    private func hideApp(_ app: NSRunningApplication, focusingNext nextApp: NSRunningApplication?) -> Bool {
        let pid = app.processIdentifier
        if let targetToFocus = resolveHideFocusTarget(for: app, preferredNext: nextApp) {
            _ = focusTargetApp(targetToFocus, replacing: app)
        }

        if pid == ProcessInfo.processInfo.processIdentifier {
            NSApp.hide(nil)
            _ = app.hide()
            recentlyHiddenAt[pid] = Date()
            hiddenByDockClick.insert(pid)
            return true
        }

        let appAX = applicationElement(for: pid)
        let axErr = AXUIElementSetAttributeValue(appAX, kAXHiddenAttribute as CFString, kCFBooleanTrue)
        let nsHid = app.hide()
        let hidden = (axErr == .success) || nsHid || isAppHidden(app)
        if hidden {
            recentlyHiddenAt[pid] = Date()
            hiddenByDockClick.insert(pid)
        }
        return hidden
    }

    private func unhideAndFocusApp(_ app: NSRunningApplication, replacing frontmost: NSRunningApplication?) -> Bool {
        let pid = app.processIdentifier
        recentlyHiddenAt.removeValue(forKey: pid)
        hiddenByDockClick.remove(pid)
        unhideProcess(app)

        if pid == ProcessInfo.processInfo.processIdentifier {
            let inspection = inspectSelfWindows()
            if inspection.openWindows.isEmpty && !inspection.minimizedWindows.isEmpty {
                _ = restoreSelfWindows(minimizedWindows: inspection.minimizedWindows, replacing: frontmost)
            } else {
                _ = focusTargetApp(app, replacing: frontmost)
                inspection.openWindows.first?.makeKeyAndOrderFront(nil)
            }
            return true
        }

        let inspection = inspectWindows(of: pid)
        if inspection.openWindows.isEmpty && !inspection.minimizedWindows.isEmpty {
            minimizedByDockClick.removeValue(forKey: pid)
            for window in inspection.minimizedWindows.reversed() {
                AXUIElementSetMessagingTimeout(window, Self.axTimeoutSeconds)
                _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }

        _ = focusTargetApp(app, replacing: frontmost)

        let refreshed = inspectWindows(of: pid)
        if let topWin = refreshed.openWindows.first {
            raiseAndMakeMain(topWin)
        }
        return true
    }

    private func restoreWindows(
        of app: NSRunningApplication,
        minimizedWindows: [AXUIElement],
        replacing frontmost: NSRunningApplication?
    ) -> Bool {
        let pid = app.processIdentifier
        recentlyHiddenAt.removeValue(forKey: pid)
        hiddenByDockClick.remove(pid)
        if isAppHidden(app) {
            unhideProcess(app)
        }

        var didRestoreAny = false
        var topWindow: AXUIElement?

        switch config.actionMode {
        case .minimizeAll, .hideApp:
            let tracked = minimizedByDockClick.removeValue(forKey: pid) ?? []
            let trackedStillMinimized = tracked.filter { candidate in
                minimizedWindows.contains { CFEqual($0, candidate) }
            }
            let toRestore = trackedStillMinimized.isEmpty ? minimizedWindows : trackedStillMinimized
            topWindow = toRestore.first

            for window in toRestore.reversed() {
                AXUIElementSetMessagingTimeout(window, Self.axTimeoutSeconds)
                if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success {
                    didRestoreAny = true
                }
            }
        case .minimizeFrontWindow:
            var tracked = minimizedByDockClick[pid] ?? []
            var popped: AXUIElement?
            while let candidate = tracked.popLast() {
                if let matched = minimizedWindows.first(where: { CFEqual($0, candidate) }) {
                    popped = matched
                    break
                }
            }
            if tracked.isEmpty {
                minimizedByDockClick.removeValue(forKey: pid)
            } else {
                minimizedByDockClick[pid] = tracked
            }

            if let target = popped ?? minimizedWindows.first {
                topWindow = target
                AXUIElementSetMessagingTimeout(target, Self.axTimeoutSeconds)
                if AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success {
                    didRestoreAny = true
                }
            }
        case .sendToBack:
            return false
        }

        if didRestoreAny {
            if let frontmost, frontmost.processIdentifier != pid {
                _ = focusTargetApp(app, replacing: frontmost)
            } else if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                _ = focusTargetApp(app, replacing: NSWorkspace.shared.frontmostApplication)
            }
            if let topWindow {
                raiseAndMakeMain(topWindow)
            }
        }
        return didRestoreAny
    }

    private func restoreSelfWindows(minimizedWindows: [NSWindow], replacing frontmost: NSRunningApplication?) -> Bool {
        let selfApp = NSRunningApplication.current
        let pid = selfApp.processIdentifier
        recentlyHiddenAt.removeValue(forKey: pid)
        hiddenByDockClick.remove(pid)
        if isAppHidden(selfApp) {
            unhideProcess(selfApp)
        }

        var topWindow: NSWindow?
        switch config.actionMode {
        case .minimizeAll, .hideApp:
            let tracked = minimizedSelfByDockClick.compactMap(\.window).filter { win in
                minimizedWindows.contains { $0 === win }
            }
            minimizedSelfByDockClick.removeAll()
            let toRestore = tracked.isEmpty ? minimizedWindows : tracked
            topWindow = toRestore.first
            for window in toRestore.reversed() {
                window.deminiaturize(nil)
            }
        case .minimizeFrontWindow:
            var popped: NSWindow?
            while let entry = minimizedSelfByDockClick.popLast() {
                if let win = entry.window, minimizedWindows.contains(where: { $0 === win }) {
                    popped = win
                    break
                }
            }
            if let target = popped ?? minimizedWindows.first {
                topWindow = target
                target.deminiaturize(nil)
            }
        case .sendToBack:
            return false
        }

        guard let topWindow else { return false }
        if frontmost?.processIdentifier != pid {
            _ = focusTargetApp(selfApp, replacing: frontmost)
        }
        topWindow.makeKeyAndOrderFront(nil)
        return true
    }

    private func dockAppIdentity(at point: CGPoint) -> DockAppIdentity? {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
            return nil
        }

        let dockElement = applicationElement(for: dockPID)

        // 1) Direct AX hit-test against the Dock process
        var elementRef: AXUIElement?
        if AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &elementRef) == .success,
           let element = elementRef,
           let identity = extractIdentity(fromElementOrParent: element) {
            return identity
        }

        // 2) Fallback: scan AXApplicationDockItem rects directly (handles badges/edges cleanly)
        if let identity = dockItemByGeometry(in: dockElement, point: point) {
            return identity
        }

        return nil
    }

    private func extractIdentity(fromElementOrParent start: AXUIElement) -> DockAppIdentity? {
        var current: AXUIElement? = start
        for _ in 0..<4 {
            guard let el = current else { break }
            AXUIElementSetMessagingTimeout(el, Self.axTimeoutSeconds)
            var subroleValue: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleValue)
            if let subrole = subroleValue as? String, subrole == "AXApplicationDockItem" {
                return identity(fromDockItem: el)
            }
            var parentValue: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = parentValue,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                break
            }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private func dockItemByGeometry(in dockElement: AXUIElement, point: CGPoint) -> DockAppIdentity? {
        var childrenVal: AnyObject?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else {
            return nil
        }

        for list in children {
            AXUIElementSetMessagingTimeout(list, Self.axTimeoutSeconds)
            var itemsVal: AnyObject?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &itemsVal) == .success,
                  let items = itemsVal as? [AXUIElement] else {
                continue
            }
            for item in items {
                AXUIElementSetMessagingTimeout(item, Self.axTimeoutSeconds)
                var posVal: AnyObject?
                var sizeVal: AnyObject?
                guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posVal) == .success,
                      AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeVal) == .success,
                      let posAX = posVal,
                      let sizeAX = sizeVal,
                      CFGetTypeID(posAX) == AXValueGetTypeID(),
                      CFGetTypeID(sizeAX) == AXValueGetTypeID() else {
                    continue
                }
                var origin = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(posAX as! AXValue, .cgPoint, &origin)
                AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)

                let rect = CGRect(origin: origin, size: size)
                if rect.contains(point) {
                    var subroleVal: AnyObject?
                    AXUIElementCopyAttributeValue(item, kAXSubroleAttribute as CFString, &subroleVal)
                    if (subroleVal as? String) == "AXApplicationDockItem" {
                        return identity(fromDockItem: item)
                    }
                }
            }
        }
        return nil
    }

    private func identity(fromDockItem item: AXUIElement) -> DockAppIdentity {
        AXUIElementSetMessagingTimeout(item, Self.axTimeoutSeconds)
        var bundleID: String?
        var bundleURLPath: String?
        var urlValue: AnyObject?
        if AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlValue) == .success,
           let url = urlValue as? URL {
            bundleURLPath = url.standardizedFileURL.path
            if let bundle = Bundle(url: url) {
                bundleID = bundle.bundleIdentifier
            }
        }

        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleValue)
        let title = titleValue as? String

        return DockAppIdentity(bundleID: bundleID, bundleURLPath: bundleURLPath, title: title)
    }

    private func resolveRunningApp(for identity: DockAppIdentity) -> NSRunningApplication? {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let activeFrontmost = (frontmost?.activationPolicy == .regular && frontmost?.isTerminated == false) ? frontmost : nil

        func firstMatching(_ predicate: (NSRunningApplication) -> Bool) -> NSRunningApplication? {
            if let activeFrontmost, predicate(activeFrontmost) {
                return activeFrontmost
            }
            return candidates.first(where: predicate)
        }

        if let path = identity.bundleURLPath,
           let match = firstMatching({ $0.bundleURL?.standardizedFileURL.path == path }) {
            return match
        }
        if let bundleID = identity.bundleID,
           let match = firstMatching({ $0.bundleIdentifier == bundleID }) {
            return match
        }
        if let title = identity.title,
           let match = firstMatching({ $0.localizedName == title }) {
            return match
        }
        return nil
    }

    private func inspectWindows(of pid: pid_t) -> WindowInspection {
        let appElement = applicationElement(for: pid)

        var focusedValue: AnyObject?
        let focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let rawFocused = focusedValue,
           CFGetTypeID(rawFocused) == AXUIElementGetTypeID() {
            focusedWindow = (rawFocused as! AXUIElement)
        } else {
            focusedWindow = nil
        }

        var isFocusedFullscreen = false
        if let focusedWindow, isAXWindowFullscreen(focusedWindow) {
            isFocusedFullscreen = true
        }

        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return WindowInspection(hasActiveFullscreen: isFocusedFullscreen)
        }

        var openWindows: [AXUIElement] = []
        var minimizableOpenWindows: [AXUIElement] = []
        var minimizedWindows: [AXUIElement] = []
        var anyFullscreen = isFocusedFullscreen

        for window in windows {
            AXUIElementSetMessagingTimeout(window, Self.axTimeoutSeconds)
            if isAXWindowFullscreen(window) {
                anyFullscreen = true
                continue
            }

            var subroleValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
            let subrole = subroleValue as? String
            guard subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String) else {
                continue
            }

            var minimizedValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
            let isMinimized = (minimizedValue as? Bool) ?? false

            var settable = DarwinBoolean(false)
            let isMinimizable = AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success && settable.boolValue

            if isMinimized {
                minimizedWindows.append(window)
            } else {
                let isFocused = focusedWindow.map { CFEqual(window, $0) } ?? false
                if isFocused {
                    openWindows.insert(window, at: 0)
                    if isMinimizable {
                        minimizableOpenWindows.insert(window, at: 0)
                    }
                } else {
                    openWindows.append(window)
                    if isMinimizable {
                        minimizableOpenWindows.append(window)
                    }
                }
            }
        }

        let hasActiveFullscreen = isFocusedFullscreen || (anyFullscreen && openWindows.isEmpty && minimizedWindows.isEmpty)
        return WindowInspection(
            openWindows: openWindows,
            minimizableOpenWindows: minimizableOpenWindows,
            minimizedWindows: minimizedWindows,
            hasActiveFullscreen: hasActiveFullscreen
        )
    }

    private func inspectSelfWindows() -> SelfWindowInspection {
        let windows = NSApp.windows.filter {
            $0.level == .normal &&
            $0.styleMask.contains(.titled) &&
            $0.styleMask.contains(.miniaturizable) &&
            !$0.isSheet
        }

        let keyWindow = NSApp.keyWindow
        let isKeyFullscreen = keyWindow?.styleMask.contains(.fullScreen) ?? false
        var openWindows: [NSWindow] = []
        var minimizedWindows: [NSWindow] = []
        var anyFullscreen = isKeyFullscreen

        for window in windows {
            if window.styleMask.contains(.fullScreen) {
                anyFullscreen = true
                continue
            }
            if window.isMiniaturized {
                minimizedWindows.append(window)
            } else if window.isVisible {
                if window === keyWindow {
                    openWindows.insert(window, at: 0)
                } else {
                    openWindows.append(window)
                }
            }
        }

        let hasActiveFullscreen = isKeyFullscreen || (anyFullscreen && openWindows.isEmpty && minimizedWindows.isEmpty)
        return SelfWindowInspection(
            openWindows: openWindows,
            minimizedWindows: minimizedWindows,
            hasActiveFullscreen: hasActiveFullscreen
        )
    }

    private func isAXWindowFullscreen(_ window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, Self.axTimeoutSeconds)
        var fullscreenValue: AnyObject?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenValue) == .success,
           let isFullscreen = fullscreenValue as? Bool {
            return isFullscreen
        }
        return false
    }

    private func onScreenLayerZeroPIDs() -> [pid_t] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var pids: [pid_t] = []
        for entry in windowList {
            guard ((entry[kCGWindowLayer as String] as? Int) ?? -1) == 0,
                  ((entry[kCGWindowAlpha as String] as? Double) ?? 0) > 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 50, bounds.height >= 50,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            pids.append(ownerPID)
        }
        return pids
    }

    struct WindowStackEntry: Identifiable, Sendable {
        var id: pid_t { pid }
        let pid: pid_t
        let appName: String
        let bundleIdentifier: String?
        let isFrontmost: Bool
        let isHidden: Bool
    }

    /// Returns deduplicated regular apps ordered front-to-back using the live CoreGraphics layer-0 stack.
    func liveWindowStackSnapshot() -> [WindowStackEntry] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var seen = Set<pid_t>()
        var result: [WindowStackEntry] = []

        for pid in onScreenLayerZeroPIDs() {
            guard seen.insert(pid).inserted,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  !app.isTerminated else {
                continue
            }
            result.append(WindowStackEntry(
                pid: pid,
                appName: app.localizedName ?? "PID \(pid)",
                bundleIdentifier: app.bundleIdentifier,
                isFrontmost: pid == frontPID,
                isHidden: app.isHidden
            ))
        }
        return result
    }

    private func hasOnScreenLayerZeroWindow(pid: pid_t) -> Bool {
        onScreenLayerZeroPIDs().contains(pid)
    }

    private func preferredUnderlyingApp(excludingPID pid: pid_t) -> NSRunningApplication? {
        if let target = topmostVisibleAppBehind(frontmostPID: pid) {
            return target
        }

        for candidate in recentApps where
            !candidate.isTerminated &&
            !candidate.isHidden &&
            candidate.processIdentifier != pid &&
            hasOpenNonMinimizedWindow(pid: candidate.processIdentifier) {
            if let hiddenAt = recentlyHiddenAt[candidate.processIdentifier],
               Date().timeIntervalSince(hiddenAt) < Self.hiddenUnderlyingSkipInterval {
                continue
            }
            return candidate
        }
        return nil
    }

    private func sendBehindPreviousApp(_ frontmost: NSRunningApplication) -> Bool {
        // 1. Prefer the live front-to-back on-screen window stack so fast clicks or
        //    non-focused interactions always target the actual window directly behind `frontmost`
        //    without accidentally reopening a closed-window app (like System Settings).
        if let target = preferredUnderlyingApp(excludingPID: frontmost.processIdentifier) {
            return focusTargetApp(target, replacing: frontmost)
        }

        // 2. Nothing visible underneath on this Space: hide cleanly instead of opening another app.
        return hideApp(frontmost, focusingNext: nil)
    }

    private func topmostVisibleAppBehind(frontmostPID: pid_t) -> NSRunningApplication? {
        for ownerPID in onScreenLayerZeroPIDs() {
            guard ownerPID != frontmostPID,
                  let app = NSRunningApplication(processIdentifier: ownerPID),
                  app.activationPolicy == .regular,
                  !app.isTerminated,
                  !app.isHidden else {
                continue
            }

            if let hiddenAt = recentlyHiddenAt[ownerPID], Date().timeIntervalSince(hiddenAt) < Self.hiddenUnderlyingSkipInterval {
                continue
            }

            return app
        }
        return nil
    }

    private func hasOpenNonMinimizedWindow(pid: pid_t) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier {
            return !inspectSelfWindows().openWindows.isEmpty
        }
        return !inspectWindows(of: pid).openWindows.isEmpty || hasOnScreenLayerZeroWindow(pid: pid)
    }

    private func focusTargetApp(_ target: NSRunningApplication, replacing frontmost: NSRunningApplication?) -> Bool {
        if let frontmost, frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: target)
        }

        if target.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        // Set AX frontmost directly so focus transfers even when Toolbox itself is not the active app
        // (macOS cooperative activation otherwise ignores background app `activate()` calls).
        let targetAX = applicationElement(for: target.processIdentifier)
        let axResult = AXUIElementSetAttributeValue(targetAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let activated = target.activate()
        return axResult == .success || activated
    }
}
