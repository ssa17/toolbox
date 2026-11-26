import AppKit
import Carbon
import CoreGraphics
import Foundation
import os

enum SwitcherNavigationDirection: String, Equatable, Sendable {
    case up
    case down
    case left
    case right
}

enum SwitcherQuickAction: String, Equatable, Sendable {
    case close
    case toggleMinimize
    case hideApp
    case quitApp
}

enum WindowSwitcherTapDecision: Equatable, Sendable {
    case passThrough
    case swallowOnly
    case openAndCycle(reverse: Bool)
    case cycleForward
    case cycleBackward
    case navigate(SwitcherNavigationDirection)
    case quickAction(SwitcherQuickAction)
    case enterFilterMode
    case appendFilterChar(String)
    case backspaceFilter
    case commit
    case cancel
}

struct WindowSwitcherTapState: Equatable, Sendable {
    var triggerModifier: SwitcherTriggerModifier = .option
    var triggerKeyCode: UInt16 = UInt16(kVK_Tab)
    var enableQuickActions: Bool = true
    var isHUDOpen: Bool = false
    var isHoldTriggeredSession: Bool = false
    var isFilterModeActive: Bool = false
}

private final class WindowSwitcherTapStartState: @unchecked Sendable {
    var succeeded = false
}

/// Dedicated background `CGEventTap` for `WindowSwitcherModule`.
/// Intercepts the configured hold-and-cycle chord (`⌥ Tab` / `⌥ ⇧ Tab` by default)
/// plus HUD navigation, quick actions, and modifier release (`flagsChanged`).
final class WindowSwitcherEventTap: @unchecked Sendable {
    static let syntheticEventTag: Int64 = 0x544C4258 // 'TLBX'
    static let relevantModifierMask: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift
    ]

    private let lifecycleLock = NSLock()
    private let fieldsLock = NSLock()
    private let stateLock = OSAllocatedUnfairLock<WindowSwitcherTapState>(initialState: WindowSwitcherTapState())

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    var onDecision: (@MainActor @Sendable (WindowSwitcherTapDecision) -> Void)?

    deinit {
        uninstall()
    }

    var isInstalled: Bool {
        fieldsLock.lock()
        defer { fieldsLock.unlock() }
        return tap != nil
    }

    internal var runsOnDedicatedBackgroundRunLoopForTesting: Bool {
        fieldsLock.lock()
        defer { fieldsLock.unlock() }
        guard let rl = backgroundRunLoop, let thread = tapThread else { return false }
        return !thread.isMainThread && rl !== CFRunLoopGetMain()
    }

    static func keyCode(for triggerKey: String) -> UInt16 {
        let normalized = triggerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "tab", "":
            return UInt16(kVK_Tab)
        case "`", "grave", "backtick":
            return UInt16(kVK_ANSI_Grave)
        default:
            if let code = ShortcutSpec(key: normalized, modifiers: []).carbonKeyCode {
                return UInt16(code)
            }
            return UInt16(kVK_Tab)
        }
    }

    func updateConfig(_ config: WindowSwitcherConfig) {
        let keyCode = Self.keyCode(for: config.normalizedTriggerKey)
        stateLock.withLock { state in
            state.triggerModifier = config.triggerModifier
            state.triggerKeyCode = keyCode
            state.enableQuickActions = config.enableQuickActions
        }
    }

    func setHUDSessionState(isOpen: Bool, isHoldTriggered: Bool, isFilterModeActive: Bool) {
        stateLock.withLock { state in
            state.isHUDOpen = isOpen
            state.isHoldTriggeredSession = isOpen ? isHoldTriggered : false
            state.isFilterModeActive = isOpen ? isFilterModeActive : false
        }
    }

    func currentTapStateSnapshot() -> WindowSwitcherTapState {
        stateLock.withLock { $0 }
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = WindowSwitcherTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<WindowSwitcherEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                return owner.handleTapEvent(type: type, event: event)
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
            CGEvent.tapEnable(tap: newTap, enable: true)

            self.fieldsLock.lock()
            self.tap = newTap
            self.runLoopSource = source
            self.backgroundRunLoop = rl
            self.fieldsLock.unlock()

            startState.succeeded = true
            readySem.signal()
            CFRunLoopRun()
            exitSem.signal()
        }
        thread.name = "app.toolbox.window-switcher-tap"
        thread.qualityOfService = .userInteractive

        fieldsLock.lock()
        tapThread = thread
        tapExitSemaphore = exitSem
        fieldsLock.unlock()
        thread.start()
        readySem.wait()

        if !startState.succeeded {
            _ = exitSem.wait(timeout: .now() + 0.5)
            fieldsLock.lock()
            tapThread = nil
            tapExitSemaphore = nil
            fieldsLock.unlock()
        }
        return startState.succeeded
    }

    func uninstall() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        uninstallLocked()
    }

    private func uninstallLocked() {
        fieldsLock.lock()
        let currentTap = tap
        let currentSource = runLoopSource
        let currentRL = backgroundRunLoop
        let currentThread = tapThread
        let exitSem = tapExitSemaphore

        tap = nil
        runLoopSource = nil
        backgroundRunLoop = nil
        tapThread = nil
        tapExitSemaphore = nil
        fieldsLock.unlock()

        stateLock.withLock { state in
            state.isHUDOpen = false
            state.isHoldTriggeredSession = false
            state.isFilterModeActive = false
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

    // MARK: - Pure Decision Logic

    static func decideKeyDown(
        keyCode: UInt16,
        flags: CGEventFlags,
        characters: String?,
        isAutoRepeat: Bool,
        userData: Int64,
        state: inout WindowSwitcherTapState
    ) -> WindowSwitcherTapDecision {
        if userData == syntheticEventTag {
            return .passThrough
        }

        let mods = flags.intersection(relevantModifierMask)
        let triggerFlag = state.triggerModifier.cgEventFlag

        if !state.isHUDOpen {
            guard keyCode == state.triggerKeyCode else {
                return .passThrough
            }
            if mods == triggerFlag {
                if isAutoRepeat { return .swallowOnly }
                state.isHUDOpen = true
                state.isHoldTriggeredSession = true
                state.isFilterModeActive = false
                return .openAndCycle(reverse: false)
            }
            if mods == [triggerFlag, .maskShift] {
                if isAutoRepeat { return .swallowOnly }
                state.isHUDOpen = true
                state.isHoldTriggeredSession = true
                state.isFilterModeActive = false
                return .openAndCycle(reverse: true)
            }
            return .passThrough
        }

        // HUD is open: intercept navigation, quick actions, filter, commit, and cancel.
        if keyCode == UInt16(kVK_Escape) {
            state.isHUDOpen = false
            state.isHoldTriggeredSession = false
            state.isFilterModeActive = false
            return .cancel
        }

        if keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            state.isHUDOpen = false
            state.isHoldTriggeredSession = false
            state.isFilterModeActive = false
            return .commit
        }

        if keyCode == state.triggerKeyCode {
            return mods.contains(.maskShift) ? .cycleBackward : .cycleForward
        }

        switch keyCode {
        case UInt16(kVK_UpArrow):
            return .navigate(.up)
        case UInt16(kVK_DownArrow):
            return .navigate(.down)
        case UInt16(kVK_LeftArrow):
            return .navigate(.left)
        case UInt16(kVK_RightArrow):
            return .navigate(.right)
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            return .backspaceFilter
        default:
            break
        }

        let nonShiftMods = mods.subtracting(.maskShift)
        let quickActionAllowed = state.enableQuickActions && !state.isFilterModeActive
        if quickActionAllowed && (nonShiftMods == triggerFlag || nonShiftMods.isEmpty) {
            switch keyCode {
            case UInt16(kVK_ANSI_W):
                return isAutoRepeat ? .swallowOnly : .quickAction(.close)
            case UInt16(kVK_ANSI_M):
                return isAutoRepeat ? .swallowOnly : .quickAction(.toggleMinimize)
            case UInt16(kVK_ANSI_H):
                return isAutoRepeat ? .swallowOnly : .quickAction(.hideApp)
            case UInt16(kVK_ANSI_Q):
                return isAutoRepeat ? .swallowOnly : .quickAction(.quitApp)
            default:
                break
            }
        }

        if keyCode == UInt16(kVK_ANSI_Slash) && !mods.contains(.maskShift) && (nonShiftMods.isEmpty || nonShiftMods == triggerFlag) {
            state.isFilterModeActive = true
            return .enterFilterMode
        }

        if let chars = filteredPrintableInput(characters),
           !mods.contains(.maskCommand),
           !mods.contains(.maskControl),
           !mods.contains(.maskAlternate) {
            state.isFilterModeActive = true
            return .appendFilterChar(chars)
        }

        return .swallowOnly
    }

    static func decideFlagsChanged(
        flags: CGEventFlags,
        userData: Int64,
        state: inout WindowSwitcherTapState
    ) -> WindowSwitcherTapDecision {
        if userData == syntheticEventTag {
            return .passThrough
        }
        guard state.isHUDOpen,
              state.isHoldTriggeredSession,
              !state.isFilterModeActive else {
            return .passThrough
        }
        if !flags.contains(state.triggerModifier.cgEventFlag) {
            state.isHUDOpen = false
            state.isHoldTriggeredSession = false
            state.isFilterModeActive = false
            return .commit
        }
        return .passThrough
    }

    private static func filteredPrintableInput(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let scalars = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(UInt32(0xF700)...UInt32(0xF8FF)).contains(scalar.value)
        }
        guard !scalars.isEmpty else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: - CGEventTap Callback

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            fieldsLock.lock()
            let currentTap = tap
            fieldsLock.unlock()
            if PermissionsManager.shouldRearmEventTap(for: type), let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            } else {
                Task { @MainActor in
                    PermissionsManager.shared.refresh()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == Self.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        let decision: WindowSwitcherTapDecision
        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let chars = extractUnicodeString(from: event)
            decision = stateLock.withLock { state in
                Self.decideKeyDown(
                    keyCode: keyCode,
                    flags: flags,
                    characters: chars,
                    isAutoRepeat: isAutoRepeat,
                    userData: userData,
                    state: &state
                )
            }

        case .flagsChanged:
            let flags = event.flags
            decision = stateLock.withLock { state in
                Self.decideFlagsChanged(flags: flags, userData: userData, state: &state)
            }

        default:
            return Unmanaged.passUnretained(event)
        }

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallowOnly:
            return nil
        default:
            let handler = onDecision
            if let handler {
                Task { @MainActor in
                    handler(decision)
                }
            }
            return type == .flagsChanged ? Unmanaged.passUnretained(event) : nil
        }
    }

    private func extractUnicodeString(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }
}
