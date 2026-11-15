import AppKit
import CoreGraphics
import Foundation

enum InputLockDecision: Equatable, Sendable {
    case passThrough
    case swallow
    case unlock
}

private final class CleanLockTapStartState: @unchecked Sendable {
    var succeeded = false
}

/// Dedicated background `CGEventTap` that temporarily swallows keyboard, media,
/// and (optionally) mouse/trackpad events during a Clean Lock session.
///
/// Runs on its own `Thread` + `CFRunLoop` so main-thread UI updates never stall
/// event delivery, and includes a press-and-hold emergency kill switch
/// (`Hold ⌃ ⌥ ⌘ Esc` for 3 seconds) plus sticky-modifier release grace.
final class InputLockTap: @unchecked Sendable {
    static let killSwitchHoldDuration: TimeInterval = 3.0
    static let killSwitchReleaseGraceDuration: TimeInterval = 1.5
    static let stickyModifierGraceSeconds: TimeInterval = 0.150
    static let escapeKeyCode: Int64 = 53
    static let systemDefinedEventRawValue: UInt32 = 14

    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()

    private var lockMouseAndTrackpad = true
    private var isLockActive = false
    private var lockStartedAt: TimeInterval = 0
    private var killSwitchHoldStartedAt: TimeInterval?
    private var awaitingKillSwitchRelease = false
    private var killSwitchReleaseDeadline: TimeInterval = 0
    private var blockedCount: Int = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    var onKillSwitchUnlock: (@Sendable () -> Void)?
    var onKillSwitchReleased: (@Sendable () -> Void)?

    deinit {
        uninstall()
    }

    func configureSession(lockMouseAndTrackpad: Bool, now: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        withLock {
            self.lockMouseAndTrackpad = lockMouseAndTrackpad
            self.lockStartedAt = now
            self.killSwitchHoldStartedAt = nil
            self.awaitingKillSwitchRelease = false
            self.killSwitchReleaseDeadline = 0
            self.blockedCount = 0
        }
    }

    @discardableResult
    func install(lockMouseAndTrackpad: Bool) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()
        configureSession(lockMouseAndTrackpad: lockMouseAndTrackpad)
        withLock { isLockActive = true }

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = CleanLockTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = Self.eventMask(lockMouseAndTrackpad: lockMouseAndTrackpad)
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            guard let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<InputLockTap>.fromOpaque(userInfo).takeUnretainedValue()
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
        thread.name = "app.toolbox.clean-lock-tap"
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
                self.isLockActive = false
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
            isLockActive = false
            killSwitchHoldStartedAt = nil
            awaitingKillSwitchRelease = false
            killSwitchReleaseDeadline = 0
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

    var isInstalled: Bool {
        withLock { tap != nil }
    }

    var currentBlockedCount: Int {
        withLock { blockedCount }
    }

    func currentKillSwitchProgress(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Double {
        withLock {
            guard let started = killSwitchHoldStartedAt else { return 0.0 }
            let elapsed = max(0.0, now - started)
            return min(1.0, elapsed / Self.killSwitchHoldDuration)
        }
    }

    func beginKillSwitchReleaseGrace(now: TimeInterval = CFAbsoluteTimeGetCurrent()) {
        withLock {
            guard !awaitingKillSwitchRelease else { return }
            killSwitchHoldStartedAt = nil
            awaitingKillSwitchRelease = true
            killSwitchReleaseDeadline = now + Self.killSwitchReleaseGraceDuration
        }
    }

    static func eventMask(lockMouseAndTrackpad: Bool) -> CGEventMask {
        var mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << UInt64(systemDefinedEventRawValue))

        if lockMouseAndTrackpad {
            mask |=
                (1 << CGEventType.leftMouseDown.rawValue) |
                (1 << CGEventType.leftMouseUp.rawValue) |
                (1 << CGEventType.leftMouseDragged.rawValue) |
                (1 << CGEventType.rightMouseDown.rawValue) |
                (1 << CGEventType.rightMouseUp.rawValue) |
                (1 << CGEventType.rightMouseDragged.rawValue) |
                (1 << CGEventType.otherMouseDown.rawValue) |
                (1 << CGEventType.otherMouseUp.rawValue) |
                (1 << CGEventType.otherMouseDragged.rawValue) |
                (1 << CGEventType.scrollWheel.rawValue)
        }
        return mask
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let (shouldRearm, currentTap) = withLock { (isLockActive, tap) }
            if shouldRearm, let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch evaluateEvent(event, now: CFAbsoluteTimeGetCurrent()) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .unlock:
            let callback = onKillSwitchUnlock
            DispatchQueue.main.async {
                callback?()
            }
            return nil
        }
    }

    /// Evaluates a `CGEvent` against the active lock rules and kill-switch state.
    /// Exposed as `internal` for deterministic unit testing with synthesized events.
    func evaluateEvent(
        _ event: CGEvent,
        now: TimeInterval = CFAbsoluteTimeGetCurrent()
    ) -> InputLockDecision {
        let type = event.type
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        return withLock {
            if awaitingKillSwitchRelease {
                if now >= killSwitchReleaseDeadline {
                    awaitingKillSwitchRelease = false
                    let callback = onKillSwitchReleased
                    DispatchQueue.main.async {
                        callback?()
                    }
                    return .passThrough
                }
                if type == .keyDown && keyCode == Self.escapeKeyCode {
                    return .swallow
                }
                if type == .keyUp && keyCode == Self.escapeKeyCode {
                    awaitingKillSwitchRelease = false
                    let callback = onKillSwitchReleased
                    DispatchQueue.main.async {
                        callback?()
                    }
                    return .swallow
                }
                return .passThrough
            }

            switch type {
            case .mouseMoved:
                return .passThrough

            case .flagsChanged:
                if killSwitchHoldStartedAt != nil && !Self.hasKillSwitchModifiers(flags) {
                    killSwitchHoldStartedAt = nil
                }
                if now - lockStartedAt < Self.stickyModifierGraceSeconds {
                    return .passThrough
                }
                blockedCount += 1
                return .swallow

            case .keyDown:
                if keyCode == Self.escapeKeyCode && Self.hasKillSwitchModifiers(flags) {
                    if killSwitchHoldStartedAt == nil {
                        killSwitchHoldStartedAt = now
                    }
                    let elapsed = now - (killSwitchHoldStartedAt ?? now)
                    if elapsed >= Self.killSwitchHoldDuration {
                        killSwitchHoldStartedAt = nil
                        awaitingKillSwitchRelease = true
                        killSwitchReleaseDeadline = now + Self.killSwitchReleaseGraceDuration
                        return .unlock
                    }
                    return .swallow
                }

                if killSwitchHoldStartedAt != nil && !Self.hasKillSwitchModifiers(flags) {
                    killSwitchHoldStartedAt = nil
                }
                blockedCount += 1
                return .swallow

            case .keyUp:
                if keyCode == Self.escapeKeyCode {
                    killSwitchHoldStartedAt = nil
                }
                blockedCount += 1
                return .swallow

            case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                 .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                 .scrollWheel:
                guard lockMouseAndTrackpad else {
                    return .passThrough
                }
                blockedCount += 1
                return .swallow

            default:
                if type.rawValue == Self.systemDefinedEventRawValue {
                    blockedCount += 1
                    return .swallow
                }
                return .passThrough
            }
        }
    }

    private static func hasKillSwitchModifiers(_ flags: CGEventFlags) -> Bool {
        flags.contains([.maskControl, .maskAlternate, .maskCommand])
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
