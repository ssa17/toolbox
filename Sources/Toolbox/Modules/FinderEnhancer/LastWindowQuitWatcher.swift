import AppKit
import ApplicationServices
import Foundation

/// Normalized Accessibility window attributes used to decide whether an app still has open windows.
struct AXWindowSnapshot: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let isMinimized: Bool
    let isFullScreen: Bool
}

/// Pure eligibility and window-counting policy for Auto-Quit on Last Window Close.
enum LastWindowQuitPolicy {
    /// System and shell apps that must never be auto-quit under any configuration.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.windowmanager",
        "com.apple.controlcenter",
        "com.apple.notificationcenter",
        "com.apple.spotlight",
        "com.apple.screencaptureui",
        "com.apple.securityagent",
        "com.apple.usernotificationcenter"
    ]

    private static let countableSubroles: Set<String> = [
        "AXStandardWindow",
        "AXDialog",
        "AXSystemDialog"
    ]

    static func isProtected(
        bundleID: String?,
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let trimmed = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return true
        }
        let lower = trimmed.lowercased()
        if protectedBundleIDs.contains(lower) {
            return true
        }
        if let selfBundleID = selfBundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !selfBundleID.isEmpty,
           lower == selfBundleID {
            return true
        }
        return false
    }

    static func isEligible(
        bundleID: String?,
        activationPolicy: NSApplication.ActivationPolicy,
        isSelfProcess: Bool,
        selfBundleID: String? = Bundle.main.bundleIdentifier,
        mode: AutoQuitAppMode,
        allowlistBundleIDs: [String],
        excludedBundleIDs: [String]
    ) -> Bool {
        guard activationPolicy == .regular, !isSelfProcess else {
            return false
        }
        guard let trimmed = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !isProtected(bundleID: trimmed, selfBundleID: selfBundleID) else {
            return false
        }

        switch mode {
        case .allowlistOnly:
            return allowlistBundleIDs.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trimmed) == .orderedSame
            }
        case .allExceptExcluded:
            return !excludedBundleIDs.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trimmed) == .orderedSame
            }
        }
    }

    /// Returns `true` when an AX window counts as an open application window.
    /// Minimized and fullscreen windows are explicitly counted as open so minimizing
    /// an app's only window never triggers auto-quit.
    static func isRelevantOpenWindow(_ window: AXWindowSnapshot) -> Bool {
        if window.isMinimized || window.isFullScreen {
            return true
        }
        if let subrole = window.subrole {
            return countableSubroles.contains(subrole)
        }
        return false
    }

    static func countRelevantOpenWindows(_ windows: [AXWindowSnapshot]) -> Int {
        windows.reduce(into: 0) { count, win in
            if isRelevantOpenWindow(win) {
                count += 1
            }
        }
    }

    /// Final safety gate evaluated after `autoQuitDelayMs` expires.
    static func shouldTerminateAfterGraceDelay(
        isRunning: Bool,
        isTerminated: Bool,
        isHidden: Bool,
        isEligible: Bool,
        relevantWindowCount: Int?
    ) -> Bool {
        guard isRunning, !isTerminated, !isHidden, isEligible else {
            return false
        }
        return relevantWindowCount == 0
    }
}

/// Watches `.regular` applications via `NSWorkspace` + per-PID `AXObserver`s and gracefully
/// calls `app.terminate()` after a configurable grace delay once an app's last window closes.
@MainActor
final class LastWindowQuitWatcher {
    private final class ObservedAppEntry {
        let pid: pid_t
        let bundleID: String
        let appElement: AXUIElement
        var observer: AXObserver?
        var hadWindowObserved: Bool
        var pendingQuitWorkItem: DispatchWorkItem?
        var pendingQuitGeneration: UInt64 = 0

        init(pid: pid_t, bundleID: String, appElement: AXUIElement, hadWindowObserved: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.appElement = appElement
            self.hadWindowObserved = hadWindowObserved
        }

        deinit {
            pendingQuitWorkItem?.cancel()
        }
    }

    private static let axTimeoutSeconds: Float = 0.15
    private static let watchedNotifications: [String] = [
        kAXUIElementDestroyedNotification,
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification
    ]

    private var config = FinderEnhancerConfig()
    private var isActive = false
    private var observedApps: [pid_t: ObservedAppEntry] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Optional testing override; when nil in production, calls `app.terminate()`.
    internal var terminateHandlerForTesting: ((NSRunningApplication) -> Bool)?

    var watchedAppCount: Int {
        observedApps.count
    }

    var pendingQuitCount: Int {
        observedApps.values.filter { $0.pendingQuitWorkItem != nil }.count
    }

    var onAppAutoQuit: ((String, String) -> Void)?

    func start(with config: FinderEnhancerConfig) {
        self.config = config
        if !isActive {
            isActive = true
            installWorkspaceObservers()
        }
        syncObservedApplications()
    }

    func updateConfig(_ config: FinderEnhancerConfig) {
        self.config = config
        if isActive {
            syncObservedApplications()
        }
    }

    func stop() {
        isActive = false
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        let pids = Array(observedApps.keys)
        for pid in pids {
            detachObserver(for: pid)
        }
        observedApps.removeAll()
    }

    // MARK: - Workspace Lifecycle

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.isActive, let app else { return }
                self.attachIfEligible(app)
            }
        }

        let terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let pid = app?.processIdentifier else { return }
                self.detachObserver(for: pid)
            }
        }

        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.isActive, let app else { return }
                self.handleAppActivatedOrUnhidden(app)
            }
        }

        let unhideObs = nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.isActive, let app else { return }
                self.handleAppActivatedOrUnhidden(app)
            }
        }

        workspaceObservers = [launchObs, terminateObs, activateObs, unhideObs]
    }

    private func syncObservedApplications() {
        guard isActive, PermissionsManager.isProcessTrusted() else {
            let pids = Array(observedApps.keys)
            for pid in pids {
                detachObserver(for: pid)
            }
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        var eligiblePIDs = Set<pid_t>()

        for app in running {
            let pid = app.processIdentifier
            let isEligible = LastWindowQuitPolicy.isEligible(
                bundleID: app.bundleIdentifier,
                activationPolicy: app.activationPolicy,
                isSelfProcess: pid == selfPID,
                mode: config.autoQuitMode,
                allowlistBundleIDs: config.autoQuitAllowlistBundleIDs,
                excludedBundleIDs: config.autoQuitExcludedBundleIDs
            )
            if isEligible && !app.isTerminated {
                eligiblePIDs.insert(pid)
                if observedApps[pid] == nil {
                    attachIfEligible(app)
                }
            }
        }

        for pid in Array(observedApps.keys) where !eligiblePIDs.contains(pid) {
            detachObserver(for: pid)
        }
    }

    private func attachIfEligible(_ app: NSRunningApplication) {
        guard isActive, PermissionsManager.isProcessTrusted() else { return }
        let pid = app.processIdentifier
        guard observedApps[pid] == nil else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier

        guard LastWindowQuitPolicy.isEligible(
            bundleID: app.bundleIdentifier,
            activationPolicy: app.activationPolicy,
            isSelfProcess: pid == selfPID,
            mode: config.autoQuitMode,
            allowlistBundleIDs: config.autoQuitAllowlistBundleIDs,
            excludedBundleIDs: config.autoQuitExcludedBundleIDs
        ),
        let bundleID = app.bundleIdentifier else {
            return
        }

        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElem, Self.axTimeoutSeconds)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, userInfo in
            guard let userInfo else { return }
            let box = Unmanaged<AXObserverContextBox>.fromOpaque(userInfo).takeUnretainedValue()
            let notifName = notification as String
            MainActor.assumeIsolated {
                box.watcher?.handleAXNotification(pid: box.pid, name: notifName)
            }
        }

        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else {
            return
        }

        let initialCount = Self.relevantOpenWindowCount(for: appElem) ?? 0
        let entry = ObservedAppEntry(
            pid: pid,
            bundleID: bundleID,
            appElement: appElem,
            hadWindowObserved: initialCount > 0
        )
        entry.observer = observer

        let contextBox = AXObserverContextBox(watcher: self, pid: pid)
        observerContextBoxes[pid] = contextBox
        let boxPtr = Unmanaged.passUnretained(contextBox).toOpaque()

        var registeredCount = 0
        for name in Self.watchedNotifications {
            let addErr = AXObserverAddNotification(observer, appElem, name as CFString, boxPtr)
            if addErr == .success || addErr == .notificationAlreadyRegistered {
                registeredCount += 1
            } else {
                DeveloperEventLog.shared.record(
                    .finderEnhancer,
                    "AXObserverAddNotification failed",
                    detail: "\(bundleID) \(name) err=\(addErr.rawValue)"
                )
            }
        }
        guard registeredCount > 0 else {
            observerContextBoxes.removeValue(forKey: pid)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observedApps[pid] = entry
    }

    private var observerContextBoxes: [pid_t: AXObserverContextBox] = [:]

    private func detachObserver(for pid: pid_t) {
        if let entry = observedApps.removeValue(forKey: pid) {
            entry.pendingQuitWorkItem?.cancel()
            entry.pendingQuitWorkItem = nil
            entry.pendingQuitGeneration &+= 1
            if let observer = entry.observer {
                for name in Self.watchedNotifications {
                    _ = AXObserverRemoveNotification(observer, entry.appElement, name as CFString)
                }
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        observerContextBoxes.removeValue(forKey: pid)
    }

    private func handleAppActivatedOrUnhidden(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard let entry = observedApps[pid] else {
            attachIfEligible(app)
            return
        }
        cancelPendingQuit(for: entry)
        if let count = Self.relevantOpenWindowCount(for: entry.appElement), count > 0 {
            entry.hadWindowObserved = true
        }
    }

    // MARK: - AX Notification Handling & Grace Timer

    fileprivate func handleAXNotification(pid: pid_t, name: String) {
        guard isActive, let entry = observedApps[pid] else { return }

        switch name {
        case kAXWindowCreatedNotification:
            entry.hadWindowObserved = true
            cancelPendingQuit(for: entry)

        case kAXFocusedWindowChangedNotification:
            if let count = Self.relevantOpenWindowCount(for: entry.appElement), count > 0 {
                entry.hadWindowObserved = true
                cancelPendingQuit(for: entry)
            }

        case kAXUIElementDestroyedNotification:
            guard let count = Self.relevantOpenWindowCount(for: entry.appElement) else {
                // AX IPC failure or timeout — fail safe and cancel any pending quit.
                cancelPendingQuit(for: entry)
                return
            }
            if count > 0 {
                entry.hadWindowObserved = true
                cancelPendingQuit(for: entry)
            } else if entry.hadWindowObserved {
                schedulePendingQuit(for: entry)
            }

        default:
            break
        }
    }

    private func cancelPendingQuit(for entry: ObservedAppEntry) {
        entry.pendingQuitWorkItem?.cancel()
        entry.pendingQuitWorkItem = nil
        entry.pendingQuitGeneration &+= 1
    }

    private func schedulePendingQuit(for entry: ObservedAppEntry) {
        cancelPendingQuit(for: entry)
        let generation = entry.pendingQuitGeneration
        let delayMs = FinderEnhancerConfig.clampedAutoQuitDelayMs(config.autoQuitDelayMs)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateGraceTimerFire(pid: entry.pid, generation: generation)
            }
        }
        entry.pendingQuitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }

    private func evaluateGraceTimerFire(pid: pid_t, generation: UInt64) {
        guard isActive,
              let entry = observedApps[pid],
              entry.pendingQuitGeneration == generation else {
            return
        }
        entry.pendingQuitWorkItem = nil

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            detachObserver(for: pid)
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let stillEligible = LastWindowQuitPolicy.isEligible(
            bundleID: app.bundleIdentifier,
            activationPolicy: app.activationPolicy,
            isSelfProcess: pid == selfPID,
            mode: config.autoQuitMode,
            allowlistBundleIDs: config.autoQuitAllowlistBundleIDs,
            excludedBundleIDs: config.autoQuitExcludedBundleIDs
        )
        let windowCount = Self.relevantOpenWindowCount(for: entry.appElement)

        guard LastWindowQuitPolicy.shouldTerminateAfterGraceDelay(
            isRunning: !app.isTerminated,
            isTerminated: app.isTerminated,
            isHidden: app.isHidden,
            isEligible: stillEligible,
            relevantWindowCount: windowCount
        ) else {
            if let windowCount, windowCount > 0 {
                entry.hadWindowObserved = true
            }
            return
        }

        if let testHandler = terminateHandlerForTesting {
            _ = testHandler(app)
            return
        }

        // Never terminate real user apps during automated `--self-test` / `--snapshot-ui` runs.
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }

        let appName = app.localizedName ?? entry.bundleID
        if app.terminate() {
            onAppAutoQuit?(appName, entry.bundleID)
        }
    }

    // MARK: - Live AX Window Inspection

    static func relevantOpenWindowCount(for appElement: AXUIElement) -> Int? {
        AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        if err == .noValue {
            return 0
        }
        guard err == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        let snapshots = windows.map { window -> AXWindowSnapshot in
            AXUIElementSetMessagingTimeout(window, axTimeoutSeconds)
            return AXWindowSnapshot(
                role: copyStringAttribute(kAXRoleAttribute, from: window),
                subrole: copyStringAttribute(kAXSubroleAttribute, from: window),
                isMinimized: copyBoolAttribute(kAXMinimizedAttribute, from: window),
                isFullScreen: copyBoolAttribute("AXFullScreen", from: window)
            )
        }
        return countRelevantOpenWindows(snapshots)
    }

    private static func countRelevantOpenWindows(_ snapshots: [AXWindowSnapshot]) -> Int {
        LastWindowQuitPolicy.countRelevantOpenWindows(snapshots)
    }

    private static func copyStringAttribute(_ attr: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyBoolAttribute(_ attr: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else {
            return false
        }
        if let boolVal = value as? Bool { return boolVal }
        if let numVal = value as? NSNumber { return numVal.boolValue }
        return false
    }
}

private final class AXObserverContextBox {
    weak var watcher: LastWindowQuitWatcher?
    let pid: pid_t

    init(watcher: LastWindowQuitWatcher, pid: pid_t) {
        self.watcher = watcher
        self.pid = pid
    }
}
