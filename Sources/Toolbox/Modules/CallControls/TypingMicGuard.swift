import Carbon
import CoreGraphics
import Foundation

enum TypingMicAction: Equatable, Sendable {
    case none
    case muteAndScheduleUnmute
    case rescheduleUnmute
}

/// Pure, deterministic state machine for Auto-Mute Mic While Typing.
/// Enforces manual-mute precedence so typing never unmutes a mic that the user
/// muted manually.
struct TypingMicStateMachine: Sendable {
    var isManuallyMuted: Bool = false
    var isTypingMuted: Bool = false
    var unmuteDelayMs: Int = 450

    var unmuteDelaySeconds: TimeInterval {
        TimeInterval(CallControlsConfig.clampedTypingDelayMs(unmuteDelayMs)) / 1000.0
    }

    static func shouldIgnoreKeystroke(
        keyCode: UInt16,
        flags: CGEventFlags,
        eventUserData: Int64,
        ignoredShortcuts: [ShortcutSpec]
    ) -> Bool {
        if eventUserData == CallShortcutRemapper.syntheticEventTag {
            return true
        }
        // Ignore Command and Control chords (shortcuts, copy/paste, terminal controls, etc.)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return true
        }
        let modifiers = CallShortcutRemapper.modifiers(from: flags)
        for shortcut in ignoredShortcuts where !shortcut.isEmpty {
            if CallShortcutRemapper.matchesShortcut(keyCode: keyCode, modifiers: modifiers, shortcut: shortcut) {
                return true
            }
        }
        return false
    }

    mutating func handleFilteredKeystroke() -> TypingMicAction {
        guard !isManuallyMuted else {
            return .none
        }
        if !isTypingMuted {
            isTypingMuted = true
            return .muteAndScheduleUnmute
        }
        return .rescheduleUnmute
    }

    /// Returns `true` if the caller should unmute the microphone now.
    mutating func handleUnmuteTimerFired() -> Bool {
        guard isTypingMuted && !isManuallyMuted else {
            return false
        }
        isTypingMuted = false
        return true
    }

    /// Syncs external or user-initiated manual mute changes.
    /// Returns `true` if any pending typing-unmute timer should be cancelled.
    mutating func setManualMute(_ muted: Bool) -> Bool {
        isManuallyMuted = muted
        let wasTypingMuted = isTypingMuted
        isTypingMuted = false
        return wasTypingMuted || muted
    }

    /// Forces any transient typing mute to be cleared when stopping or switching devices.
    /// Returns `true` if the microphone was muted by the typing guard and must be restored.
    mutating func forceStopAndRestore() -> Bool {
        let shouldRestore = isTypingMuted && !isManuallyMuted
        isTypingMuted = false
        return shouldRestore
    }
}

private final class TypingMicTapStartState: @unchecked Sendable {
    var succeeded = false
}

/// Passive `.listenOnly` background `CGEventTap` that mutes the OS input mic
/// while typing and restores it after `typingUnmuteDelayMs` of keyboard silence.
final class TypingMicGuard: @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()

    private var isActive = false
    private var stateMachine = TypingMicStateMachine()
    private var ignoredShortcuts: [ShortcutSpec] = []
    private var unmuteWorkItem: DispatchWorkItem?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    var onSetTypingMute: (@Sendable (Bool) -> Void)?

    deinit {
        uninstall()
    }

    var isInstalled: Bool {
        withLock { tap != nil }
    }

    var isTypingMuted: Bool {
        withLock { stateMachine.isTypingMuted }
    }

    var isManuallyMuted: Bool {
        withLock { stateMachine.isManuallyMuted }
    }

    func configure(
        unmuteDelayMs: Int,
        ignoredShortcuts: [ShortcutSpec],
        isManuallyMuted: Bool
    ) {
        withLock {
            stateMachine.unmuteDelayMs = CallControlsConfig.clampedTypingDelayMs(unmuteDelayMs)
            self.ignoredShortcuts = ignoredShortcuts
            if stateMachine.isManuallyMuted != isManuallyMuted {
                let shouldCancel = stateMachine.setManualMute(isManuallyMuted)
                if shouldCancel {
                    unmuteWorkItem?.cancel()
                    unmuteWorkItem = nil
                }
            }
        }
    }

    func syncManualMuteState(_ muted: Bool) {
        withLock {
            let shouldCancel = stateMachine.setManualMute(muted)
            if shouldCancel {
                unmuteWorkItem?.cancel()
                unmuteWorkItem = nil
            }
        }
    }

    /// Clears any pending typing mute and returns whether the caller should immediately unmute.
    @discardableResult
    func restoreIfTypingMuted() -> Bool {
        withLock {
            unmuteWorkItem?.cancel()
            unmuteWorkItem = nil
            return stateMachine.forceStopAndRestore()
        }
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()
        withLock { isActive = true }

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = TypingMicTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            guard let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<TypingMicGuard>.fromOpaque(userInfo).takeUnretainedValue()
                    owner.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
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
        thread.name = "app.toolbox.typing-mic-guard"
        thread.qualityOfService = .utility

        withLock {
            self.tapThread = thread
            self.tapExitSemaphore = exitSem
        }
        thread.start()
        readySem.wait()

        if !startState.succeeded {
            _ = exitSem.wait(timeout: .now() + 0.5)
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
        let shouldRestoreMute = withLock {
            isActive = false
            unmuteWorkItem?.cancel()
            unmuteWorkItem = nil
            return stateMachine.forceStopAndRestore()
        }

        let (currentTap, currentSource, currentRL, currentThread, exitSem) = withLock {
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

        if shouldRestoreMute {
            let callback = onSetTypingMute
            DispatchQueue.main.async {
                callback?(false)
            }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let (shouldRearm, currentTap) = withLock { (isActive, tap) }
            if shouldRearm, PermissionsManager.shouldRearmEventTap(for: type), let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            } else {
                Task { @MainActor in
                    PermissionsManager.shared.refresh()
                }
            }
            return
        }

        guard type == .keyDown else { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let userData = event.getIntegerValueField(.eventSourceUserData)

        let (action, delaySeconds): (TypingMicAction, TimeInterval) = withLock {
            guard isActive else { return (.none, 0) }
            if TypingMicStateMachine.shouldIgnoreKeystroke(
                keyCode: keyCode,
                flags: flags,
                eventUserData: userData,
                ignoredShortcuts: ignoredShortcuts
            ) {
                return (.none, 0)
            }
            let act = stateMachine.handleFilteredKeystroke()
            return (act, stateMachine.unmuteDelaySeconds)
        }

        guard action != .none else { return }

        scheduleUnmute(after: delaySeconds)

        if action == .muteAndScheduleUnmute {
            let callback = onSetTypingMute
            DispatchQueue.main.async {
                callback?(true)
            }
        }
    }

    private func scheduleUnmute(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let shouldUnmute = self.withLock {
                self.unmuteWorkItem = nil
                return self.stateMachine.handleUnmuteTimerFired()
            }
            if shouldUnmute {
                let callback = self.onSetTypingMute
                DispatchQueue.main.async {
                    callback?(false)
                }
            }
        }

        withLock {
            unmuteWorkItem?.cancel()
            unmuteWorkItem = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
