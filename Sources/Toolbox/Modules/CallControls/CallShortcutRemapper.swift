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
    private var simulatedContext: SimulatedCallContext?
    private var suppressedKeyUps: Set<UInt16> = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowTitleRefreshTimer: Timer?

    var onRemapTriggered: (@Sendable (CallActionKind, CallAppShortcutMapping, ShortcutSpec, Bool) -> Void)?
    var onGlobalActionTriggered: (@Sendable (CallActionKind, Bool) -> Void)?
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
        let snapshotData: (mappings: [CallAppShortcutMapping], mru: [pid_t]) = withLock {
            (mappings, mruAppPIDs)
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

                var callSnapshots: [RunningCallAppSnapshot] = []
                for app in running {
                    let matchingMappings = enabledMappings.filter { $0.matches(bundleID: app.bundleID) }
                    guard !matchingMappings.isEmpty else { continue }
                    let needsTitles = matchingMappings.contains { !($0.requiredWindowTitleSubstring ?? "").isEmpty }
                    let titles = needsTitles ? Self.allWindowTitles(for: app.pid) : []
                    callSnapshots.append(RunningCallAppSnapshot(
                        bundleIdentifier: app.bundleID,
                        pid: app.pid,
                        windowTitles: titles
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

    /// Returns the call app and native shortcut that would receive `action` right now.
    static func resolveTargetPreview(
        action: CallActionKind,
        overrideScope: CallOverrideScope,
        mappings: [CallAppShortcutMapping],
        frontmostBundleID: String?,
        frontmostPID: pid_t?,
        frontmostWindowTitle: String?,
        runningApps: [RunningCallAppSnapshot]
    ) -> (app: CallAppShortcutMapping, pid: pid_t?, shortcut: ShortcutSpec, requiresBriefFocusRestore: Bool)? {
        let enabledMappings = mappings.filter { mapping in
            guard mapping.enabled else { return false }
            let target = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
            return !target.isEmpty
        }

        if let frontmostBundleID {
            for mapping in enabledMappings where mapping.matches(bundleID: frontmostBundleID) {
                if passesWindowTitleGate(mapping: mapping, titles: frontmostWindowTitle.map { [$0] } ?? []) {
                    let targetShortcut = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
                    return (mapping, frontmostPID, targetShortcut, false)
                }
            }
        }

        guard overrideScope != .activeCallAppOnly else {
            return nil
        }

        for app in runningApps {
            for mapping in enabledMappings where mapping.matches(bundleID: app.bundleIdentifier) {
                guard passesWindowTitleGate(mapping: mapping, titles: app.windowTitles) else {
                    continue
                }
                let targetShortcut = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
                let isAlreadyFrontmost = (app.pid == frontmostPID)
                return (mapping, app.pid, targetShortcut, !isAlreadyFrontmost && mapping.allowBriefFocusRestore)
            }
        }
        return nil
    }

    func currentTargetSummary(for action: CallActionKind) -> (appName: String, pid: pid_t?, shortcut: ShortcutSpec)? {
        let state = withLock {
            (
                overrideScope: overrideScope,
                mappings: mappings,
                frontBundle: frontmostBundleID,
                frontPID: frontmostPID,
                frontTitle: frontmostWindowTitle,
                running: runningSnapshots
            )
        }
        guard let target = Self.resolveTargetPreview(
            action: action,
            overrideScope: state.overrideScope,
            mappings: state.mappings,
            frontmostBundleID: state.frontBundle,
            frontmostPID: state.frontPID,
            frontmostWindowTitle: state.frontTitle,
            runningApps: state.running
        ) else {
            return nil
        }
        return (target.app.appName, target.pid, target.shortcut)
    }

    @discardableResult
    func triggerManualAction(
        _ action: CallActionKind,
        mappings: [CallAppShortcutMapping],
        overrideScope: CallOverrideScope
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
        var snapshots: [RunningCallAppSnapshot] = []
        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated, let bundleID = app.bundleIdentifier else { continue }
            let matching = enabledMappings.filter { $0.matches(bundleID: bundleID) }
            guard !matching.isEmpty else { continue }
            let needsTitles = matching.contains { !($0.requiredWindowTitleSubstring ?? "").isEmpty }
            let titles = needsTitles ? Self.allWindowTitles(for: app.processIdentifier) : []
            snapshots.append(RunningCallAppSnapshot(
                bundleIdentifier: bundleID,
                pid: app.processIdentifier,
                windowTitles: titles
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
            runningApps: snapshots
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
            runningApps: state.running
        )

        switch decision {
        case .passThrough:
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
        runningApps: [RunningCallAppSnapshot]
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
        let enabledMappings = mappings.filter { mapping in
            guard mapping.enabled else { return false }
            let target = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
            return !target.isEmpty
        }

        // 1. Check frontmost app first
        if let frontmostBundleID {
            for mapping in enabledMappings where mapping.matches(bundleID: frontmostBundleID) {
                if passesWindowTitleGate(mapping: mapping, titles: frontmostWindowTitle.map { [$0] } ?? []) {
                    let targetShortcut = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
                    if targetShortcut == userShortcut {
                        if overrideScope == .everywhere && action == .mic {
                            return .passThroughWithHardwareSync(action: .mic)
                        }
                        return .passThrough
                    }
                    return .remap(
                        action: action,
                        targetApp: mapping,
                        targetPID: frontmostPID,
                        targetShortcut: targetShortcut,
                        requiresBriefFocusRestore: false
                    )
                }
            }
        }

        // 2. Optionally fall back to background running call apps
        guard overrideScope != .activeCallAppOnly else {
            return .passThrough
        }

        for app in runningApps {
            for mapping in enabledMappings where mapping.matches(bundleID: app.bundleIdentifier) {
                guard passesWindowTitleGate(mapping: mapping, titles: app.windowTitles) else {
                    continue
                }
                let targetShortcut = (action == .mic) ? mapping.micShortcut : mapping.videoShortcut
                let isAlreadyFrontmost = (app.pid == frontmostPID)
                if isAlreadyFrontmost && targetShortcut == userShortcut {
                    if overrideScope == .everywhere && action == .mic {
                        return .passThroughWithHardwareSync(action: .mic)
                    }
                    return .passThrough
                }
                return .remap(
                    action: action,
                    targetApp: mapping,
                    targetPID: app.pid,
                    targetShortcut: targetShortcut,
                    requiresBriefFocusRestore: !isAlreadyFrontmost && mapping.allowBriefFocusRestore
                )
            }
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

        // Prefer direct AX menu item invocation for native Mac apps (FaceTime, Zoom, etc.):
        // triggers silently without focus disruption when enabled, and avoids error beeps/focus
        // flash when an app's call menu item is disabled (e.g. FaceTime open outside an active call).
        if let pid = targetPID {
            switch Self.inspectOrPressMenuItem(pid: pid, shortcut: targetShortcut, performPress: true) {
            case .pressed:
                DispatchQueue.main.async {
                    callback?(action, targetApp, targetShortcut, true)
                }
                return
            case .menuItemDisabled:
                DispatchQueue.main.async {
                    callback?(action, targetApp, targetShortcut, false)
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
                        attemptsRemaining: 12,
                        keyCode: CGKeyCode(targetKeyCode),
                        flags: targetFlags,
                        action: action,
                        targetApp: targetApp,
                        targetShortcut: targetShortcut,
                        callback: callback
                    )
                }
            }
            return
        }

        let frontPIDSnapshot = withLock { frontmostPID }
        dispatchQueue.async {
            if let pid = targetPID, let titleNeedle = targetApp.requiredWindowTitleSubstring, !titleNeedle.isEmpty {
                Self.raiseMatchingWindowIfNeeded(pid: pid, titleSubstring: titleNeedle)
            }
            if let pid = targetPID, frontPIDSnapshot != pid {
                Self.postKeyCombo(keyCode: CGKeyCode(targetKeyCode), flags: targetFlags, targetPID: pid)
            } else {
                Self.postKeyCombo(keyCode: CGKeyCode(targetKeyCode), flags: targetFlags, targetPID: nil)
            }
            DispatchQueue.main.async {
                callback?(action, targetApp, targetShortcut, true)
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
        callback: (@Sendable (CallActionKind, CallAppShortcutMapping, ShortcutSpec, Bool) -> Void)?
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
                        callback: callback
                    )
                }
            }
            return
        }

        // Small settle delay so Electron/Chromium web views finish wiring key window focus.
        dispatchQueue.asyncAfter(deadline: .now() + 0.025) {
            Self.postKeyCombo(keyCode: keyCode, flags: flags, targetPID: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.090) {
                MainActor.assumeIsolated {
                    if let previousApp, previousApp.processIdentifier != targetPID, !previousApp.isTerminated {
                        NSApp.yieldActivation(to: previousApp)
                        previousApp.activate()
                    }
                    callback?(action, targetApp, targetShortcut, true)
                }
            }
        }
    }

    @MainActor
    private static func activateApplicationForRelay(pid: pid_t, requiredTitleSubstring: String?) {
        if let requiredTitleSubstring, !requiredTitleSubstring.isEmpty {
            raiseMatchingWindowIfNeeded(pid: pid, titleSubstring: requiredTitleSubstring)
        }
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElem, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            _ = app.activate()
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

    // MARK: - Accessibility Menu Item Lookup & Window Title Queries

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
