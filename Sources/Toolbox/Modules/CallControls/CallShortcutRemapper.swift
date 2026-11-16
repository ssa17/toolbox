import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

enum CallActionKind: String, Equatable, Sendable {
    case mic
    case video

    var label: String {
        switch self {
        case .mic: return "Mic"
        case .video: return "Video"
        }
    }
}

struct RunningCallAppSnapshot: Equatable, Sendable {
    let bundleIdentifier: String
    let pid: pid_t
    let windowTitles: [String]
    let hasActiveCallControl: Bool?
    let hasActiveAudioInput: Bool

    init(
        bundleIdentifier: String,
        pid: pid_t,
        windowTitles: [String],
        hasActiveCallControl: Bool? = nil,
        hasActiveAudioInput: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.windowTitles = windowTitles
        self.hasActiveCallControl = hasActiveCallControl
        self.hasActiveAudioInput = hasActiveAudioInput
    }
}

enum CallRemapDecision: Equatable, Sendable {
    case passThrough
    case passThroughWithHardwareSync(action: CallActionKind)
    case globalHardwareOnly(action: CallActionKind)
    case remap(
        action: CallActionKind,
        targetApp: CallAppShortcutMapping,
        targetPID: pid_t?,
        targetShortcut: ShortcutSpec,
        requiresBriefFocusRestore: Bool
    )
}

enum AXMenuTriggerOutcome: Equatable, Sendable {
    case pressed
    case menuItemDisabled
    case notFound
}

struct SimulatedCallContext: Equatable, Sendable {
    let frontmostBundleID: String?
    let frontmostPID: pid_t?
    let frontmostWindowTitle: String?
    let runningApps: [RunningCallAppSnapshot]
    let simulateAccessibilityGranted: Bool
    let osMuteShortcut: ShortcutSpec
}

private final class CallRemapperTapStartState: @unchecked Sendable {
    var succeeded = false
}

/// Context-aware background `CGEventTap` that translates the user's unified
/// Mic / Video shortcuts into each enabled call app's native shortcut without
/// interfering with other applications.
final class CallShortcutRemapper: @unchecked Sendable {
    static let syntheticEventTag: Int64 = 0x544C4258 // 'TLBX'

    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()
    private let dispatchQueue = DispatchQueue(label: "app.toolbox.call-shortcut-dispatch", qos: .userInteractive)
    private let contextRefreshQueue = DispatchQueue(label: "app.toolbox.call-context-refresh", qos: .utility)

    private var isActive = false
    private var micShortcut: ShortcutSpec = .none
    private var videoShortcut: ShortcutSpec = .none
    private var overrideScope: CallOverrideScope = .everywhere
    private var mappings: [CallAppShortcutMapping] = CallAppShortcutMapping.defaults

    private var frontmostBundleID: String?
    private var frontmostPID: pid_t?
    private var frontmostWindowTitle: String?
    private var mruAppPIDs: [pid_t] = []
    private var runningSnapshots: [RunningCallAppSnapshot] = []
    private var isCallActivityActive: Bool = false
    private var simulatedContext: SimulatedCallContext?
    private var suppressedKeyUps: Set<UInt16> = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowTitleRefreshTimer: Timer?

    var onRemapTriggered: (@Sendable (CallActionKind, CallAppShortcutMapping, ShortcutSpec, Bool, Bool?) -> Void)?
    var onGlobalActionTriggered: (@Sendable (CallActionKind, Bool) -> Void)?
    var onNativeAppMicShortcutPressed: (@Sendable (CallAppShortcutMapping, pid_t) -> Void)?
    var onSimulatedActionTriggered: (@Sendable (CallActionKind, Bool) -> Void)?

    deinit {
        uninstall()
    }

    var isInstalled: Bool {
        withLock { tap != nil }
    }

    func updateConfiguration(
        micShortcut: ShortcutSpec,
        videoShortcut: ShortcutSpec,
        overrideScope: CallOverrideScope,
        mappings: [CallAppShortcutMapping]
    ) {
        withLock {
            self.micShortcut = micShortcut
            self.videoShortcut = videoShortcut
            self.overrideScope = overrideScope
            self.mappings = mappings
        }
        refreshApplicationContextAsync()
    }

    func updateSimulatedContext(_ context: SimulatedCallContext?) {
        withLock {
            self.simulatedContext = context
        }
    }

    func updateCallActivity(_ active: Bool) {
        let changed = withLock { () -> Bool in
            let didChange = (self.isCallActivityActive != active)
            self.isCallActivityActive = active
            return didChange
        }
        if changed {
            refreshApplicationContextAsync()
        }
    }

    func refreshContextIfInstalled() {
        if isInstalled {
            refreshApplicationContextAsync()
        }
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()
        withLock { isActive = true }
        installWorkspaceObserversOnMain()
        refreshApplicationContextAsync()

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = CallRemapperTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            guard let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<CallShortcutRemapper>.fromOpaque(userInfo).takeUnretainedValue()
                    return owner.handle(type: type, event: event)
                },
                userInfo: selfPtr
            ) else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let rl = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)

            self.withLock {
                self.tap = newTap
                self.runLoopSource = source
                self.backgroundRunLoop = rl
            }

            startState.succeeded = true
            readySem.signal()
            CFRunLoopRun()
            exitSem.signal()
        }
        thread.name = "app.toolbox.call-shortcut-tap"
        thread.qualityOfService = .userInteractive

        withLock {
            self.tapThread = thread
            self.tapExitSemaphore = exitSem
        }
        thread.start()
        readySem.wait()

        if !startState.succeeded {
            _ = exitSem.wait(timeout: .now() + 0.5)
            removeWorkspaceObserversOnMain()
            withLock {
                self.isActive = false
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
        removeWorkspaceObserversOnMain()

        let (currentTap, currentSource, currentRL, currentThread, exitSem) = withLock {
            isActive = false
            suppressedKeyUps.removeAll()
            let values = (tap, runLoopSource, backgroundRunLoop, tapThread, tapExitSemaphore)
            tap = nil
            runLoopSource = nil
            backgroundRunLoop = nil
            tapThread = nil
            tapExitSemaphore = nil
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

    // MARK: - Workspace & Window Context Caching

    private func installWorkspaceObserversOnMain() {
        let setup = { [weak self] in
            guard let self else { return }
            self.removeWorkspaceObserversLockedOnMain()

            let nc = NSWorkspace.shared.notificationCenter
            let names: [NSNotification.Name] = [
                NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification
            ]
            for name in names {
                let observer = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self else { return }
                    if name == NSWorkspace.didActivateApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self.recordActivatedApp(bundleID: app.bundleIdentifier, pid: app.processIdentifier)
                    }
                    self.refreshApplicationContextAsync()
                }
                self.workspaceObservers.append(observer)
            }

            if let front = NSWorkspace.shared.frontmostApplication {
                self.recordActivatedApp(bundleID: front.bundleIdentifier, pid: front.processIdentifier)
            }

            let timer = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
                self?.refreshWindowTitlesIfNeeded()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.windowTitleRefreshTimer = timer
        }

        if Thread.isMainThread {
            setup()
        } else {
            DispatchQueue.main.sync(execute: setup)
        }
    }

    private func removeWorkspaceObserversOnMain() {
        if Thread.isMainThread {
            removeWorkspaceObserversLockedOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.removeWorkspaceObserversLockedOnMain()
            }
        }
    }

    private func removeWorkspaceObserversLockedOnMain() {
        windowTitleRefreshTimer?.invalidate()
        windowTitleRefreshTimer = nil
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            nc.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func recordActivatedApp(bundleID: String?, pid: pid_t) {
        withLock {
            if frontmostPID != pid {
                frontmostWindowTitle = nil
            }
            frontmostBundleID = bundleID
            frontmostPID = pid
            mruAppPIDs.removeAll { $0 == pid }
            mruAppPIDs.insert(pid, at: 0)
            if mruAppPIDs.count > 40 {
                mruAppPIDs.removeLast(mruAppPIDs.count - 40)
            }
        }
    }

    private func refreshWindowTitlesIfNeeded() {
        let shouldRefresh = withLock {
            guard isActive else { return false }
            let gatedMappings = mappings.filter {
                $0.enabled && !($0.requiredWindowTitleSubstring ?? "").isEmpty
            }
            guard !gatedMappings.isEmpty else { return false }
            if let frontmostBundleID,
               gatedMappings.contains(where: { $0.matches(bundleID: frontmostBundleID) }) {
                return true
            }
            if overrideScope == .activeOrRunningBackground {
                return runningSnapshots.contains { snap in
                    gatedMappings.contains { $0.matches(bundleID: snap.bundleIdentifier) }
                }
            }
            return false
        }
        if shouldRefresh {
            refreshApplicationContextAsync()
        }
    }

    private func refreshApplicationContextAsync() {
        let snapshotData: (mappings: [CallAppShortcutMapping], mru: [pid_t], callActive: Bool) = withLock {
            (mappings, mruAppPIDs, isCallActivityActive)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication
            let frontBundle = front?.bundleIdentifier
            let frontPID = front?.processIdentifier
            let running = NSWorkspace.shared.runningApplications.compactMap { app -> (bundleID: String, pid: pid_t)? in
                guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
                return (bundleID, app.processIdentifier)
            }

            self.contextRefreshQueue.async { [weak self] in
                guard let self else { return }
                let mruOrder = Dictionary(uniqueKeysWithValues: snapshotData.mru.enumerated().map { ($1, $0) })
                let enabledMappings = snapshotData.mappings.filter(\.enabled)

                var frontTitle: String?
                if let frontPID,
                   let frontBundle,
                   enabledMappings.contains(where: { $0.matches(bundleID: frontBundle) && !($0.requiredWindowTitleSubstring ?? "").isEmpty }) {
                    frontTitle = Self.focusedWindowTitle(for: frontPID) ?? Self.allWindowTitles(for: frontPID).first
                }

                let activeInputBundles = CoreAudioController.activeInputProcessBundleIDs()
                var callSnapshots: [RunningCallAppSnapshot] = []
                for app in running {
                    let matchingMappings = enabledMappings.filter { $0.matches(bundleID: app.bundleID) }
                    guard !matchingMappings.isEmpty else { continue }
                    let needsTitles = matchingMappings.contains { !($0.requiredWindowTitleSubstring ?? "").isEmpty }
                    let titles = needsTitles ? Self.allWindowTitles(for: app.pid) : []
                    let hasAudioInput = CoreAudioController.bundleID(app.bundleID, matchesActiveInputProcessBundleIDs: activeInputBundles)
                    let shouldProbeAX = (!snapshotData.callActive || running.count > 1) && !hasAudioInput && app.pid != frontPID && AXIsProcessTrusted()
                    let hasControl: Bool? = shouldProbeAX
                        ? (Self.inspectCallAppMuteState(pid: app.pid) != nil)
                        : nil
                    callSnapshots.append(RunningCallAppSnapshot(
                        bundleIdentifier: app.bundleID,
                        pid: app.pid,
                        windowTitles: titles,
                        hasActiveCallControl: hasControl,
                        hasActiveAudioInput: hasAudioInput
                    ))
                }

                callSnapshots.sort { lhs, rhs in
                    let lRank = mruOrder[lhs.pid] ?? Int.max
                    let rRank = mruOrder[rhs.pid] ?? Int.max
                    return lRank < rRank
                }

                self.withLock {
                    self.frontmostBundleID = frontBundle
                    self.frontmostPID = frontPID
                    self.frontmostWindowTitle = frontTitle
                    self.runningSnapshots = callSnapshots
                }
            }
        }
    }

    /// Unified target resolution for both shortcut dispatch and UI/pill status previews.
    /// Frontmost call apps and apps actively owning a call stream block fallback to idle background apps
    /// even when their shortcut for `action` (e.g., Slack `.video`) is empty.
    private static func resolveCallTarget(
        action: CallActionKind,
        overrideScope: CallOverrideScope,
        mappings: [CallAppShortcutMapping],
        frontmostBundleID: String?,
        frontmostPID: pid_t?,
        frontmostWindowTitle: String?,
        runningApps: [RunningCallAppSnapshot],
        isCallActivityActive: Bool
    ) -> (app: CallAppShortcutMapping, pid: pid_t?, shortcut: ShortcutSpec, requiresBriefFocusRestore: Bool)? {
        let enabledMappings = mappings.filter(\.enabled)

        // 1. Check frontmost app across all enabled call apps first.
        if let frontmostBundleID {
            for mapping in enabledMappings where mapping.matches(bundleID: frontmostBundleID) {
                if passesWindowTitleGate(mapping: mapping, titles: frontmostWindowTitle.map { [$0] } ?? []) {
                    let targetShortcut = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
                    guard !targetShortcut.isEmpty else { return nil }
                    return (mapping, frontmostPID, targetShortcut, false)
                }
            }
        }

        // 2. Background call app routing
        guard overrideScope != .activeCallAppOnly else {
            return nil
        }

        let activeCallApps = runningApps.filter { $0.hasActiveAudioInput || $0.hasActiveCallControl == true }
        let candidateApps: [RunningCallAppSnapshot]
        if !activeCallApps.isEmpty {
            candidateApps = activeCallApps
        } else if isCallActivityActive {
            candidateApps = runningApps
        } else {
            return nil
        }

        for app in candidateApps {
            let isAlreadyFrontmost = (app.pid == frontmostPID)
            for mapping in enabledMappings where mapping.matches(bundleID: app.bundleIdentifier) {
                guard passesWindowTitleGate(mapping: mapping, titles: app.windowTitles) else {
                    continue
                }
                let targetShortcut = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
                guard !targetShortcut.isEmpty else { return nil }
                return (mapping, app.pid, targetShortcut, !isAlreadyFrontmost && mapping.allowBriefFocusRestore)
            }
        }
        return nil
    }

    /// Returns the call app and native shortcut that would receive `action` right now.
    static func resolveTargetPreview(
        action: CallActionKind,
        overrideScope: CallOverrideScope,
        mappings: [CallAppShortcutMapping],
        frontmostBundleID: String?,
        frontmostPID: pid_t?,
        frontmostWindowTitle: String?,
        runningApps: [RunningCallAppSnapshot],
        isCallActivityActive: Bool = true
    ) -> (app: CallAppShortcutMapping, pid: pid_t?, shortcut: ShortcutSpec, requiresBriefFocusRestore: Bool)? {
        resolveCallTarget(
            action: action,
            overrideScope: overrideScope,
            mappings: mappings,
            frontmostBundleID: frontmostBundleID,
            frontmostPID: frontmostPID,
            frontmostWindowTitle: frontmostWindowTitle,
            runningApps: runningApps,
            isCallActivityActive: isCallActivityActive
        )
    }

    func currentTargetSummary(for action: CallActionKind) -> (appName: String, pid: pid_t?, shortcut: ShortcutSpec)? {
        let state = withLock {
            (
                overrideScope: overrideScope,
                mappings: mappings,
                frontBundle: frontmostBundleID,
                frontPID: frontmostPID,
                frontTitle: frontmostWindowTitle,
                running: runningSnapshots,
                callActive: isCallActivityActive
            )
        }
        guard let target = Self.resolveTargetPreview(
            action: action,
            overrideScope: state.overrideScope,
            mappings: state.mappings,
            frontmostBundleID: state.frontBundle,
            frontmostPID: state.frontPID,
            frontmostWindowTitle: state.frontTitle,
            runningApps: state.running,
            isCallActivityActive: state.callActive
        ) else {
            return nil
        }
        return (target.app.appName, target.pid, target.shortcut)
    }

    @discardableResult
    func triggerManualAction(
        _ action: CallActionKind,
        mappings: [CallAppShortcutMapping],
        overrideScope: CallOverrideScope,
        isCallActivityActive: Bool = true
    ) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let frontBundle = front?.bundleIdentifier
        let frontPID = front?.processIdentifier
        let frontTitle: String? = {
            guard let frontPID, let frontBundle else { return nil }
            let needsTitle = mappings.contains {
                $0.enabled && $0.matches(bundleID: frontBundle) && !($0.requiredWindowTitleSubstring ?? "").isEmpty
            }
            return needsTitle ? (Self.focusedWindowTitle(for: frontPID) ?? Self.allWindowTitles(for: frontPID).first) : nil
        }()

        let stateMru = withLock { mruAppPIDs }
        let mruOrder = Dictionary(uniqueKeysWithValues: stateMru.enumerated().map { ($1, $0) })
        let enabledMappings = mappings.filter(\.enabled)
        let activeInputBundles = CoreAudioController.activeInputProcessBundleIDs()
        let matchedRunning = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated && (app.bundleIdentifier.map { bid in enabledMappings.contains { $0.matches(bundleID: bid) } } ?? false)
        }
        var snapshots: [RunningCallAppSnapshot] = []
        for app in matchedRunning {
            guard let bundleID = app.bundleIdentifier else { continue }
            let matching = enabledMappings.filter { $0.matches(bundleID: bundleID) }
            let needsTitles = matching.contains { !($0.requiredWindowTitleSubstring ?? "").isEmpty }
            let titles = needsTitles ? Self.allWindowTitles(for: app.processIdentifier) : []
            let hasAudioInput = CoreAudioController.bundleID(bundleID, matchesActiveInputProcessBundleIDs: activeInputBundles)
            let shouldProbeAX = (!isCallActivityActive || matchedRunning.count > 1) && !hasAudioInput && app.processIdentifier != frontPID && AXIsProcessTrusted()
            let hasControl: Bool? = shouldProbeAX
                ? (Self.inspectCallAppMuteState(pid: app.processIdentifier) != nil)
                : nil
            snapshots.append(RunningCallAppSnapshot(
                bundleIdentifier: bundleID,
                pid: app.processIdentifier,
                windowTitles: titles,
                hasActiveCallControl: hasControl,
                hasActiveAudioInput: hasAudioInput
            ))
        }
        snapshots.sort { (mruOrder[$0.pid] ?? Int.max) < (mruOrder[$1.pid] ?? Int.max) }

        guard let resolved = Self.resolveTargetPreview(
            action: action,
            overrideScope: overrideScope,
            mappings: mappings,
            frontmostBundleID: frontBundle,
            frontmostPID: frontPID,
            frontmostWindowTitle: frontTitle,
            runningApps: snapshots,
            isCallActivityActive: isCallActivityActive
        ) else {
            return false
        }

        dispatchRemappedShortcut(
            action: action,
            targetApp: resolved.app,
            targetPID: resolved.pid,
            targetShortcut: resolved.shortcut,
            requiresBriefFocusRestore: resolved.requiresBriefFocusRestore
        )
        return true
    }

    // MARK: - Event Tap Handling & Pure Decision Engine

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let (shouldRearm, currentTap) = withLock { (isActive, tap) }
            if shouldRearm, let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == Self.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp {
            let shouldSuppressKeyUp = withLock { suppressedKeyUps.remove(keyCode) != nil }
            return shouldSuppressKeyUp ? nil : Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let modifiers = Self.modifiers(from: event.flags)

        let state = withLock {
            (
                micShortcut: micShortcut,
                videoShortcut: videoShortcut,
                overrideScope: overrideScope,
                mappings: mappings,
                frontBundle: frontmostBundleID,
                frontPID: frontmostPID,
                frontTitle: frontmostWindowTitle,
                running: runningSnapshots,
                callActive: isCallActivityActive,
                simulated: simulatedContext
            )
        }

        if let sim = state.simulated {
            if Self.matchesShortcut(keyCode: keyCode, modifiers: modifiers, shortcut: sim.osMuteShortcut) {
                withLock { _ = suppressedKeyUps.insert(keyCode) }
                let cb = onSimulatedActionTriggered
                DispatchQueue.main.async {
                    cb?(.mic, true)
                }
                return nil
            }

            let matchedAction: CallActionKind? = {
                if Self.matchesShortcut(keyCode: keyCode, modifiers: modifiers, shortcut: state.micShortcut) {
                    return .mic
                }
                if Self.matchesShortcut(keyCode: keyCode, modifiers: modifiers, shortcut: state.videoShortcut) {
                    return .video
                }
                return nil
            }()

            guard let matchedAction else {
                return Unmanaged.passUnretained(event)
            }

            let decision = Self.resolveDecision(
                keyCode: keyCode,
                modifiers: modifiers,
                eventUserData: userData,
                micShortcut: state.micShortcut,
                videoShortcut: state.videoShortcut,
                overrideScope: state.overrideScope,
                mappings: state.mappings,
                frontmostBundleID: sim.frontmostBundleID,
                frontmostPID: sim.frontmostPID,
                frontmostWindowTitle: sim.frontmostWindowTitle,
                runningApps: sim.runningApps
            )

            switch decision {
            case .passThrough:
                let cb = onSimulatedActionTriggered
                DispatchQueue.main.async {
                    cb?(matchedAction, false)
                }
                return Unmanaged.passUnretained(event)

            case .passThroughWithHardwareSync, .globalHardwareOnly, .remap:
                withLock { _ = suppressedKeyUps.insert(keyCode) }
                let cb = onSimulatedActionTriggered
                DispatchQueue.main.async {
                    cb?(matchedAction, true)
                }
                return nil
            }
        }

        let decision = Self.resolveDecision(
            keyCode: keyCode,
            modifiers: modifiers,
            eventUserData: userData,
            micShortcut: state.micShortcut,
            videoShortcut: state.videoShortcut,
            overrideScope: state.overrideScope,
            mappings: state.mappings,
            frontmostBundleID: state.frontBundle,
            frontmostPID: state.frontPID,
            frontmostWindowTitle: state.frontTitle,
            runningApps: state.running,
            isCallActivityActive: state.callActive
        )

        switch decision {
        case .passThrough:
            if let frontBundle = state.frontBundle,
               let frontPID = state.frontPID,
               let nativeMapping = state.mappings.first(where: {
                   $0.enabled && $0.matches(bundleID: frontBundle) &&
                   Self.matchesShortcut(keyCode: keyCode, modifiers: modifiers, shortcut: $0.micShortcut)
               }) {
                let nativeCB = onNativeAppMicShortcutPressed
                DispatchQueue.main.async {
                    nativeCB?(nativeMapping, frontPID)
                }
            }
            return Unmanaged.passUnretained(event)

        case .passThroughWithHardwareSync(let action):
            let cb = onGlobalActionTriggered
            DispatchQueue.main.async {
                cb?(action, true)
            }
            return Unmanaged.passUnretained(event)

        case .globalHardwareOnly(let action):
            withLock { _ = suppressedKeyUps.insert(keyCode) }
            let cb = onGlobalActionTriggered
            DispatchQueue.main.async {
                cb?(action, false)
            }
            return nil

        case .remap(let action, let targetApp, let targetPID, let targetShortcut, let requiresFocusRestore):
            withLock { _ = suppressedKeyUps.insert(keyCode) }
            dispatchRemappedShortcut(
                action: action,
                targetApp: targetApp,
                targetPID: targetPID,
                targetShortcut: targetShortcut,
                requiresBriefFocusRestore: requiresFocusRestore
            )
            return nil
        }
    }

    /// Pure, deterministic routing decision used by both the live `CGEventTap` and self-tests.
    static func resolveDecision(
        keyCode: UInt16,
        modifiers: [KeyModifier],
        eventUserData: Int64,
        micShortcut: ShortcutSpec,
        videoShortcut: ShortcutSpec,
        overrideScope: CallOverrideScope,
        mappings: [CallAppShortcutMapping],
        frontmostBundleID: String?,
        frontmostPID: pid_t?,
        frontmostWindowTitle: String?,
        runningApps: [RunningCallAppSnapshot],
        isCallActivityActive: Bool = true
    ) -> CallRemapDecision {
        if eventUserData == syntheticEventTag {
            return .passThrough
        }

        let matchedAction: CallActionKind? = {
            if matchesShortcut(keyCode: keyCode, modifiers: modifiers, shortcut: micShortcut) {
                return .mic
            }
            if matchesShortcut(keyCode: keyCode, modifiers: modifiers, shortcut: videoShortcut) {
                return .video
            }
            return nil
        }()

        guard let action = matchedAction else {
            return .passThrough
        }

        let userShortcut = (action == .mic) ? micShortcut : videoShortcut
        if let resolved = resolveCallTarget(
            action: action,
            overrideScope: overrideScope,
            mappings: mappings,
            frontmostBundleID: frontmostBundleID,
            frontmostPID: frontmostPID,
            frontmostWindowTitle: frontmostWindowTitle,
            runningApps: runningApps,
            isCallActivityActive: isCallActivityActive
        ) {
            let isAlreadyFrontmost = (resolved.pid == frontmostPID) && !resolved.requiresBriefFocusRestore
            if isAlreadyFrontmost && resolved.shortcut == userShortcut {
                if overrideScope == .everywhere && action == .mic {
                    return .passThroughWithHardwareSync(action: .mic)
                }
                return .passThrough
            }
            return .remap(
                action: action,
                targetApp: resolved.app,
                targetPID: resolved.pid,
                targetShortcut: resolved.shortcut,
                requiresBriefFocusRestore: resolved.requiresBriefFocusRestore
            )
        }

        if overrideScope == .everywhere {
            return .globalHardwareOnly(action: action)
        }

        return .passThrough
    }

    static func matchesShortcut(keyCode: UInt16, modifiers: [KeyModifier], shortcut: ShortcutSpec) -> Bool {
        guard !shortcut.isEmpty, let expectedCode = shortcut.carbonKeyCode else {
            return false
        }
        return UInt32(keyCode) == expectedCode && Set(modifiers) == Set(shortcut.modifiers)
    }

    static func modifiers(from flags: CGEventFlags) -> [KeyModifier] {
        var result: [KeyModifier] = []
        if flags.contains(.maskControl) { result.append(.control) }
        if flags.contains(.maskAlternate) { result.append(.option) }
        if flags.contains(.maskShift) { result.append(.shift) }
        if flags.contains(.maskCommand) { result.append(.command) }
        return result
    }

    static func cgEventFlags(for modifiers: [KeyModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mod in modifiers {
            switch mod {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            }
        }
        return flags
    }

    private static func passesWindowTitleGate(mapping: CallAppShortcutMapping, titles: [String]) -> Bool {
        guard let needle = mapping.requiredWindowTitleSubstring?.trimmingCharacters(in: .whitespacesAndNewlines),
              !needle.isEmpty else {
            return true
        }
        return titles.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    // MARK: - Synthetic Shortcut Relay

    private func dispatchRemappedShortcut(
        action: CallActionKind,
        targetApp: CallAppShortcutMapping,
        targetPID: pid_t?,
        targetShortcut: ShortcutSpec,
        requiresBriefFocusRestore: Bool
    ) {
        guard let targetKeyCode = targetShortcut.carbonKeyCode else { return }
        let targetFlags = Self.cgEventFlags(for: targetShortcut.modifiers)
        let callback = onRemapTriggered

        dispatchQueue.async {
            let preRelayAppMuted: Bool? = {
                guard action == .mic, let pid = targetPID else { return nil }
                return Self.inspectCallAppMuteState(pid: pid)
            }()

            // Prefer direct AX menu item invocation for native Mac apps (FaceTime, Zoom, etc.):
            // triggers silently without focus disruption when enabled, and avoids error beeps/focus
            // flash when an app's call menu item is disabled (e.g. FaceTime open outside an active call).
            if let pid = targetPID {
                switch Self.inspectOrPressMenuItem(pid: pid, shortcut: targetShortcut, performPress: true) {
                case .pressed:
                    DispatchQueue.main.async {
                        callback?(action, targetApp, targetShortcut, true, preRelayAppMuted)
                    }
                    return
                case .menuItemDisabled:
                    DispatchQueue.main.async {
                        callback?(action, targetApp, targetShortcut, false, preRelayAppMuted)
                    }
                    return
                case .notFound:
                    break
                }
            }

            if requiresBriefFocusRestore, let pid = targetPID {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let previousApp = NSWorkspace.shared.frontmostApplication
                        Self.activateApplicationForRelay(
                            pid: pid,
                            requiredTitleSubstring: targetApp.requiredWindowTitleSubstring
                        )
                        self.waitUntilFrontmostAndDispatch(
                            targetPID: pid,
                            previousApp: previousApp,
                            attemptsRemaining: 14,
                            keyCode: CGKeyCode(targetKeyCode),
                            flags: targetFlags,
                            action: action,
                            targetApp: targetApp,
                            targetShortcut: targetShortcut,
                            preRelayAppMuted: preRelayAppMuted,
                            callback: callback
                        )
                    }
                }
                return
            }

            let frontPIDSnapshot = self.withLock { self.frontmostPID }
            if let pid = targetPID {
                if let titleNeedle = targetApp.requiredWindowTitleSubstring, !titleNeedle.isEmpty {
                    Self.raiseMatchingWindowIfNeeded(pid: pid, titleSubstring: titleNeedle)
                } else {
                    Self.raiseCallWindowIfNeeded(pid: pid)
                }
            }
            if let pid = targetPID, frontPIDSnapshot != pid {
                Self.postKeyCombo(keyCode: CGKeyCode(targetKeyCode), flags: targetFlags, targetPID: pid)
            } else {
                Self.postKeyCombo(keyCode: CGKeyCode(targetKeyCode), flags: targetFlags, targetPID: nil)
            }
            DispatchQueue.main.async {
                callback?(action, targetApp, targetShortcut, true, preRelayAppMuted)
            }
        }
    }

    @MainActor
    private func waitUntilFrontmostAndDispatch(
        targetPID: pid_t,
        previousApp: NSRunningApplication?,
        attemptsRemaining: Int,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        action: CallActionKind,
        targetApp: CallAppShortcutMapping,
        targetShortcut: ShortcutSpec,
        preRelayAppMuted: Bool?,
        callback: (@Sendable (CallActionKind, CallAppShortcutMapping, ShortcutSpec, Bool, Bool?) -> Void)?
    ) {
        let isFrontmostNow = (NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID)
        if !isFrontmostNow && attemptsRemaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                MainActor.assumeIsolated {
                    self?.waitUntilFrontmostAndDispatch(
                        targetPID: targetPID,
                        previousApp: previousApp,
                        attemptsRemaining: attemptsRemaining - 1,
                        keyCode: keyCode,
                        flags: flags,
                        action: action,
                        targetApp: targetApp,
                        targetShortcut: targetShortcut,
                        preRelayAppMuted: preRelayAppMuted,
                        callback: callback
                    )
                }
            }
            return
        }

        // Settle delay so Electron/WebView2 web views finish wiring key window focus.
        dispatchQueue.asyncAfter(deadline: .now() + 0.045) {
            Self.postKeyCombo(keyCode: keyCode, flags: flags, targetPID: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.115) {
                MainActor.assumeIsolated {
                    if let previousApp, previousApp.processIdentifier != targetPID, !previousApp.isTerminated {
                        NSApp.yieldActivation(to: previousApp)
                        previousApp.activate()
                    }
                    callback?(action, targetApp, targetShortcut, true, preRelayAppMuted)
                }
            }
        }
    }

    @MainActor
    private static func activateApplicationForRelay(pid: pid_t, requiredTitleSubstring: String?) {
        if let requiredTitleSubstring, !requiredTitleSubstring.isEmpty {
            raiseMatchingWindowIfNeeded(pid: pid, titleSubstring: requiredTitleSubstring)
        } else {
            raiseCallWindowIfNeeded(pid: pid)
        }
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElem, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            _ = app.activate()
        }
    }

    private static func raiseCallWindowIfNeeded(pid: pid_t) {
        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              windows.count > 1 else {
            return
        }
        for win in windows.prefix(8) {
            var remaining = 120
            if searchWindowForMuteState(win, depthRemaining: 8, nodeBudget: &remaining) != nil {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                return
            }
        }
    }

    private static func raiseMatchingWindowIfNeeded(pid: pid_t, titleSubstring: String) {
        let needle = titleSubstring.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return
        }
        for win in windows.prefix(12) {
            if let title = windowTitle(of: win), title.localizedCaseInsensitiveContains(needle) {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                break
            }
        }
    }

    private static func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags, targetPID: pid_t?) {
        // Prefer .cghidEventTap when the target is already frontmost or recently activated,
        // and fall back to process-targeted postToPid when targeting a background process
        // without focus activation so keystrokes never leak into an unrelated active app.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        if let targetPID {
            down.postToPid(targetPID)
            usleep(12_000)
            up.postToPid(targetPID)
        } else {
            down.post(tap: .cghidEventTap)
            usleep(12_000)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Accessibility Mute State Inspection & Menu Item Lookup

    /// Classifies a call-app button or menu label into whether the mic is currently muted (`true`)
    /// or live (`false`), returning `nil` for unrelated controls (e.g. "Mute notifications", "Mute all").
    static func classifyCallMuteControlLabel(_ rawText: String, isMenuItem: Bool = false) -> Bool? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        // Strip trailing keyboard shortcut parentheticals such as "Unmute mic (⌘⇧M)" or "Turn off microphone (⌘ + d)"
        if let parenStart = text.range(of: " ("), text.hasSuffix(")") {
            text = String(text[..<parenStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let excludedTerms = [
            "notification", "alert", "chat", "channel", "thread", "tab", "site",
            "speaker", "others", "all", "participant", "everyone", "audience",
            "incoming", "deafen", "video", "camera", "sound", "ringtone", "volume"
        ]
        if excludedTerms.contains(where: { text.contains($0) }) {
            return nil
        }

        let unmutePhrases = [
            "unmute mic", "unmute microphone", "unmute audio", "unmute myself", "unmute me",
            "unmute huddle", "turn on mic", "turn on microphone", "turn mic on", "turn microphone on",
            "mic is muted", "microphone is muted", "mic muted", "microphone muted"
        ]
        if text == "unmute" || unmutePhrases.contains(where: { text.contains($0) }) {
            return true
        }
        if isMenuItem && text.hasPrefix("unmute") {
            return true
        }

        let mutePhrases = [
            "mute mic", "mute microphone", "mute audio", "mute myself", "mute me",
            "mute huddle", "turn off mic", "turn off microphone", "turn mic off", "turn microphone off",
            "mic is on", "microphone is on", "microphone unmuted"
        ]
        if text == "mute" || mutePhrases.contains(where: { text.contains($0) }) {
            return false
        }
        if isMenuItem && text.hasPrefix("mute") {
            return false
        }

        return nil
    }

    /// Reads the live in-app mic mute state (`true` = muted, `false` = live, `nil` = unknown/no active call)
    /// from an app's menu bar or meeting window Accessibility tree. Call off the CGEventTap thread.
    static func inspectCallAppMuteState(pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var mbRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXMenuBarAttribute as CFString, &mbRef) == .success,
           let mb = mbRef {
            if let menuResult = searchMenuForMuteState(mb as! AXUIElement, depthRemaining: 4, pathDepth: 0) {
                return menuResult
            }
        }

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            let orderedWindows = prioritizedCallWindows(windows)
            var totalBudget = 1600
            for win in orderedWindows.prefix(8) {
                var perWindowBudget = min(450, totalBudget)
                let startBudget = perWindowBudget
                if let winResult = searchWindowForMuteState(win, depthRemaining: 24, nodeBudget: &perWindowBudget) {
                    return winResult
                }
                totalBudget -= (startBudget - perWindowBudget)
                if totalBudget <= 0 { break }
            }
        }
        return nil
    }

    private static func prioritizedCallWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        guard windows.count > 1 else { return windows }
        return windows.enumerated().sorted { lhs, rhs in
            let lScore = callWindowPriorityScore(lhs.element)
            let rScore = callWindowPriorityScore(rhs.element)
            if lScore != rScore { return lScore > rScore }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func callWindowPriorityScore(_ win: AXUIElement) -> Int {
        var score = 0
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = (titleRef as? String)?.lowercased() {
            let keywords = ["huddle", "meeting", "call", "meet", "zoom", "facetime"]
            if keywords.contains(where: { title.contains($0) }) {
                score += 10
            }
        }
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == "AXFloatingWindow" || subrole == "AXSystemDialog" {
            score += 5
        }
        return score
    }

    private static func searchMenuForMuteState(
        _ container: AXUIElement,
        depthRemaining: Int,
        pathDepth: Int
    ) -> Bool? {
        guard depthRemaining > 0 else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pathDepth == 0 && title == "Apple" {
                continue
            }

            if pathDepth >= 2, !title.isEmpty,
               let classified = classifyCallMuteControlLabel(title, isMenuItem: true) {
                var enRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXEnabledAttribute as CFString, &enRef)
                let isEnabled = (enRef as? Bool) ?? true
                if isEnabled {
                    if !classified {
                        var markRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(child, kAXMenuItemMarkCharAttribute as CFString, &markRef)
                        if let mark = markRef as? String,
                           !mark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return true
                        }
                    }
                    return classified
                }
            }

            if let nested = searchMenuForMuteState(child, depthRemaining: depthRemaining - 1, pathDepth: pathDepth + 1) {
                return nested
            }
        }
        return nil
    }

    private static func searchWindowForMuteState(
        _ element: AXUIElement,
        depthRemaining: Int,
        nodeBudget: inout Int
    ) -> Bool? {
        guard depthRemaining > 0, nodeBudget > 0 else { return nil }
        nodeBudget -= 1

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        let interactiveRoles: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXSwitch"
        ]
        if interactiveRoles.contains(role) {
            var enRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enRef)
            let isEnabled = (enRef as? Bool) ?? true
            if isEnabled {
                let textAttributes: [CFString] = [
                    kAXDescriptionAttribute as CFString,
                    kAXTitleAttribute as CFString,
                    kAXHelpAttribute as CFString
                ]
                for attr in textAttributes {
                    var valueRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, attr, &valueRef) == .success,
                       let label = valueRef as? String,
                       let classified = classifyCallMuteControlLabel(label, isMenuItem: false) {
                        if !classified && (role == "AXCheckBox" || role == "AXSwitch" || role == "AXRadioButton") {
                            var controlValRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &controlValRef) == .success {
                                if let intVal = controlValRef as? Int, intVal != 0 {
                                    return true
                                }
                                if let boolVal = controlValRef as? Bool, boolVal {
                                    return true
                                }
                            }
                        }
                        return classified
                    }
                }
            }
        }

        if role == "AXMenuBar" {
            return nil
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = searchWindowForMuteState(child, depthRemaining: depthRemaining - 1, nodeBudget: &nodeBudget) {
                return found
            }
            if nodeBudget <= 0 { break }
        }
        return nil
    }

    static func inspectOrPressMenuItem(
        pid: pid_t,
        shortcut: ShortcutSpec,
        performPress: Bool
    ) -> AXMenuTriggerOutcome {
        guard !shortcut.isEmpty else { return .notFound }
        let targetKey = shortcut.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard targetKey.count == 1 else { return .notFound }

        let targetMods = Set(shortcut.modifiers)
        let appElem = AXUIElementCreateApplication(pid)
        var mbRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXMenuBarAttribute as CFString, &mbRef) == .success,
              let mb = mbRef else {
            return .notFound
        }

        if let outcome = searchMenuContainer(
            mb as! AXUIElement,
            targetKey: targetKey,
            targetModifiers: targetMods,
            depthRemaining: 3,
            performPress: performPress
        ) {
            return outcome
        }
        return .notFound
    }

    private static func searchMenuContainer(
        _ container: AXUIElement,
        targetKey: String,
        targetModifiers: Set<KeyModifier>,
        depthRemaining: Int,
        performPress: Bool
    ) -> AXMenuTriggerOutcome? {
        guard depthRemaining > 0 else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var cmdRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXMenuItemCmdCharAttribute as CFString, &cmdRef) == .success,
               let cmdStr = (cmdRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               cmdStr == targetKey {
                var modRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXMenuItemCmdModifiersAttribute as CFString, &modRef)
                let axMods = (modRef as? Int) ?? 0
                if axMenuModifiersMatch(axMods, expected: targetModifiers) {
                    var enRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(child, kAXEnabledAttribute as CFString, &enRef)
                    let isEnabled = (enRef as? Bool) ?? true
                    if !isEnabled {
                        return .menuItemDisabled
                    }
                    if performPress {
                        let err = AXUIElementPerformAction(child, kAXPressAction as CFString)
                        return err == .success ? .pressed : .notFound
                    }
                    return .pressed
                }
            }

            if let nested = searchMenuContainer(
                child,
                targetKey: targetKey,
                targetModifiers: targetModifiers,
                depthRemaining: depthRemaining - 1,
                performPress: performPress
            ) {
                return nested
            }
        }
        return nil
    }

    static func keyModifiers(fromAXModifiers axMods: Int) -> [KeyModifier] {
        var mods: [KeyModifier] = []
        if (axMods & 4) != 0 { mods.append(.control) }
        if (axMods & 2) != 0 { mods.append(.option) }
        if (axMods & 1) != 0 { mods.append(.shift) }
        if (axMods & 8) == 0 { mods.append(.command) }
        return mods
    }

    static func axMenuModifiersMatch(_ axMods: Int, expected: Set<KeyModifier>) -> Bool {
        Set(keyModifiers(fromAXModifiers: axMods)) == expected
    }

    struct DetectedMenuControl: Identifiable, Equatable {
        var id: String { "\(menuPath)::\(shortcut.displayString)" }
        let title: String
        let menuPath: String
        let shortcut: ShortcutSpec
        let kind: CallActionKind?
    }

    struct InspectedAppControls: Equatable {
        let bundleIdentifier: String
        let isRunning: Bool
        let accessibilityGranted: Bool
        let allShortcutControls: [DetectedMenuControl]
        let micCandidates: [DetectedMenuControl]
        let videoCandidates: [DetectedMenuControl]

        var suggestedMic: ShortcutSpec { micCandidates.first?.shortcut ?? .none }
        var suggestedVideo: ShortcutSpec { videoCandidates.first?.shortcut ?? .none }
    }

    static func shortcutFromMenuItem(cmdChar: String?, virtualKey: Int?, axMods: Int) -> ShortcutSpec? {
        let key: String
        if let virtualKey {
            switch virtualKey {
            case 49: key = "space"
            case 36: key = "return"
            case 48: key = "tab"
            default:
                guard let ch = cleanASCIIKey(from: cmdChar) else { return nil }
                key = ch
            }
        } else if let ch = cleanASCIIKey(from: cmdChar) {
            key = ch
        } else {
            return nil
        }
        let mods = keyModifiers(fromAXModifiers: axMods)
        return ShortcutSpec(key: key, modifiers: mods)
    }

    private static func cleanASCIIKey(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              trimmed.count == 1,
              let scalar = trimmed.unicodeScalars.first,
              scalar.isASCII,
              !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        return trimmed == " " ? "space" : trimmed
    }

    static func classifyControlKind(title: String, menuPath: String) -> (kind: CallActionKind, score: Int)? {
        let lowTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowTitle.isEmpty else { return nil }
        let excludedSubstrings = ["notification", "alert", "do not disturb", "mute site", "mute tab", "zoom", "quit"]
        if excludedSubstrings.contains(where: { lowTitle.contains($0) }) {
            return nil
        }
        let lowPath = menuPath.lowercased()
        let inCallMenuBonus = (lowPath.contains("meeting") || lowPath.contains("call") || lowPath.contains("video") || lowPath.contains("audio") || lowPath.contains("huddle")) ? 2 : 0

        if lowTitle.contains("video") || lowTitle.contains("camera") || lowTitle.contains("webcam") {
            let exactBonus = (lowTitle.contains("toggle") || lowTitle.contains("start") || lowTitle.contains("stop") || lowTitle.contains("turn")) ? 4 : 2
            return (.video, exactBonus + inCallMenuBonus)
        }
        if lowTitle == "mute" || lowTitle.contains("mute") || lowTitle.contains("microphone") || lowTitle.contains("mic") || lowTitle.contains("audio") {
            let exactBonus = (lowTitle == "mute" || lowTitle.contains("mute audio") || lowTitle.contains("microphone") || lowTitle.contains("mic")) ? 4 : 2
            return (.mic, exactBonus + inCallMenuBonus)
        }
        return nil
    }

    static func scanMenuBarControls(forBundleID bundleID: String) -> InspectedAppControls {
        let running = NSWorkspace.shared.runningApplications.first { app in
            !app.isTerminated && (app.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame)
        }
        let axGranted = AXIsProcessTrusted()
        guard let running, axGranted else {
            return InspectedAppControls(
                bundleIdentifier: bundleID,
                isRunning: running != nil,
                accessibilityGranted: axGranted,
                allShortcutControls: [],
                micCandidates: [],
                videoCandidates: []
            )
        }

        let appElem = AXUIElementCreateApplication(running.processIdentifier)
        var mbRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXMenuBarAttribute as CFString, &mbRef) == .success,
              let mb = mbRef else {
            return InspectedAppControls(
                bundleIdentifier: bundleID,
                isRunning: true,
                accessibilityGranted: true,
                allShortcutControls: [],
                micCandidates: [],
                videoCandidates: []
            )
        }

        var collected: [(control: DetectedMenuControl, score: Int)] = []
        collectShortcutMenuControls(
            mb as! AXUIElement,
            pathPrefix: [],
            depthRemaining: 4,
            into: &collected
        )

        var seenIDs = Set<String>()
        let uniqueControls = collected.filter { item in
            seenIDs.insert(item.control.id).inserted
        }
        let allControls = uniqueControls.map(\.control)
        let micCandidates = uniqueControls
            .filter { $0.control.kind == .mic }
            .sorted { $0.score > $1.score }
            .map(\.control)
        let videoCandidates = uniqueControls
            .filter { $0.control.kind == .video }
            .sorted { $0.score > $1.score }
            .map(\.control)

        return InspectedAppControls(
            bundleIdentifier: bundleID,
            isRunning: true,
            accessibilityGranted: true,
            allShortcutControls: allControls,
            micCandidates: micCandidates,
            videoCandidates: videoCandidates
        )
    }

    private static func collectShortcutMenuControls(
        _ container: AXUIElement,
        pathPrefix: [String],
        depthRemaining: Int,
        into results: inout [(control: DetectedMenuControl, score: Int)]
    ) {
        guard depthRemaining > 0 else { return }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(container, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }

        for child in children {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pathPrefix.isEmpty && (title == "Apple" || title.isEmpty) {
                if title == "Apple" { continue }
            }

            var cmdRef: CFTypeRef?
            var vkeyRef: CFTypeRef?
            var modRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXMenuItemCmdCharAttribute as CFString, &cmdRef)
            AXUIElementCopyAttributeValue(child, kAXMenuItemCmdVirtualKeyAttribute as CFString, &vkeyRef)
            AXUIElementCopyAttributeValue(child, kAXMenuItemCmdModifiersAttribute as CFString, &modRef)

            let cmdChar = cmdRef as? String
            let vkey = vkeyRef as? Int
            let axMods = (modRef as? Int) ?? 0
            let fullPath = (title.isEmpty ? pathPrefix : pathPrefix + [title])
            let pathString = fullPath.joined(separator: " > ")

            if !title.isEmpty,
               let spec = shortcutFromMenuItem(cmdChar: cmdChar, virtualKey: vkey, axMods: axMods),
               !spec.isEmpty {
                let classified = classifyControlKind(title: title, menuPath: pathString)
                results.append((
                    DetectedMenuControl(
                        title: title,
                        menuPath: pathString,
                        shortcut: spec,
                        kind: classified?.kind
                    ),
                    classified?.score ?? 0
                ))
            }

            collectShortcutMenuControls(
                child,
                pathPrefix: title.isEmpty ? pathPrefix : fullPath,
                depthRemaining: depthRemaining - 1,
                into: &results
            )
        }
    }

    private static func focusedWindowTitle(for pid: pid_t) -> String? {
        let appElem = AXUIElementCreateApplication(pid)
        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let windowElem = focusedWindowRef else {
            return nil
        }
        return windowTitle(of: windowElem as! AXUIElement)
    }

    static func allWindowTitles(for pid: pid_t) -> [String] {
        var titles: [String] = []
        let appElem = AXUIElementCreateApplication(pid)
        if let focused = focusedWindowTitle(for: pid) {
            titles.append(focused)
        }
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for win in windows.prefix(12) {
                if let title = windowTitle(of: win), !titles.contains(title) {
                    titles.append(title)
                }
            }
        }
        if titles.isEmpty,
           let cgList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in cgList {
                guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                      ownerPID == pid,
                      let title = info[kCGWindowName as String] as? String,
                      !title.isEmpty else {
                    continue
                }
                titles.append(title)
            }
        }
        return titles
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String,
              !title.isEmpty else {
            return nil
        }
        return title
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
