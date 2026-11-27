import AppKit
import Carbon
import CoreGraphics
import Foundation
import os

struct HyperKeyLiveEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case tapAction
        case toolboxDispatch
        case thirdPartyChord
        case heldReleased
    }

    let timestamp: Date
    let summary: String
    let detail: String?
    let kind: Kind
}

struct HyperKeyCallControlsBindings: Equatable, Sendable {
    var enabled: Bool = false
    var micShortcut: ShortcutSpec = .none
    var videoShortcut: ShortcutSpec = .none
}

/// Pure, thread-safe state machine deciding how `F18` (remapped Caps Lock) and chorded keys behave.
struct HyperKeyStateMachine: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case passThrough
        case swallowOnly
        case dispatchToolboxHotKey(name: String, shortcut: ShortcutSpec)
        case dispatchCallControls(action: CallActionKind, shortcut: ShortcutSpec)
        case synthesizeThirdPartyKeyDown(keyCode: UInt16, modifiers: [KeyModifier], flags: CGEventFlags)
        case synthesizeThirdPartyKeyUp(keyCode: UInt16, modifiers: [KeyModifier], flags: CGEventFlags)
        case triggerTapAction(HyperKeyTapAction)
        case heldReleasedWithoutChord
    }

    static let f18KeyCode: UInt16 = UInt16(kVK_F18) // 79
    static let syntheticEventTag: Int64 = 0x544C4258 // 'TLBX'

    var holdMode: HyperKeyHoldMode = .toolboxChord
    var tapAction: HyperKeyTapAction = .capsLock
    var tapThresholdMs: Int = HyperKeyConfig.defaultTapThresholdMs

    private(set) var isHeld: Bool = false
    private(set) var downTimestampNs: UInt64 = 0
    private(set) var usedAsChord: Bool = false
    private(set) var swallowedToolboxKeyCodes: Set<UInt16> = []
    private(set) var activeThirdPartyChords: [UInt16: [KeyModifier]] = [:]

    mutating func resetTransientState() {
        isHeld = false
        downTimestampNs = 0
        usedAsChord = false
        swallowedToolboxKeyCodes.removeAll()
        activeThirdPartyChords.removeAll()
    }

    mutating func handleKeyDown(
        keyCode: UInt16,
        flags: CGEventFlags,
        isAutoRepeat: Bool,
        userData: Int64,
        timestampNs: UInt64,
        registeredHotKeys: [ActiveHotKeyBinding],
        callControls: HyperKeyCallControlsBindings
    ) -> Decision {
        if userData == Self.syntheticEventTag {
            return .passThrough
        }

        if keyCode == Self.f18KeyCode {
            if isAutoRepeat || isHeld {
                return .swallowOnly
            }
            isHeld = true
            downTimestampNs = timestampNs
            usedAsChord = false
            return .swallowOnly
        }

        guard isHeld else {
            return .passThrough
        }

        usedAsChord = true

        let physicalMods = Self.modifiers(from: flags)
        let effectiveMods = Self.orderedModifierUnion(holdMode.modifiers, physicalMods)
        let effectiveFlags = holdMode.cgEventFlags.union(Self.cgFlags(for: effectiveMods))

        // Fast Path 1: Direct in-process dispatch for registered Toolbox Carbon hotkeys.
        if let binding = registeredHotKeys.first(where: {
            $0.isArmed && $0.keyCode == UInt32(keyCode) && $0.modifiers == effectiveMods
        }) {
            if !isAutoRepeat {
                swallowedToolboxKeyCodes.insert(keyCode)
                return .dispatchToolboxHotKey(name: binding.name, shortcut: binding.shortcut)
            }
            swallowedToolboxKeyCodes.insert(keyCode)
            return .swallowOnly
        }

        // Fast Path 2: Direct dispatch for Call Controls Mic/Video (handled by CallShortcutRemapper, not HotKeyManager).
        if callControls.enabled {
            if !callControls.micShortcut.isEmpty,
               callControls.micShortcut.carbonKeyCode == UInt32(keyCode),
               callControls.micShortcut.modifiers == effectiveMods {
                swallowedToolboxKeyCodes.insert(keyCode)
                return isAutoRepeat ? .swallowOnly : .dispatchCallControls(action: .mic, shortcut: callControls.micShortcut)
            }
            if !callControls.videoShortcut.isEmpty,
               callControls.videoShortcut.carbonKeyCode == UInt32(keyCode),
               callControls.videoShortcut.modifiers == effectiveMods {
                swallowedToolboxKeyCodes.insert(keyCode)
                return isAutoRepeat ? .swallowOnly : .dispatchCallControls(action: .video, shortcut: callControls.videoShortcut)
            }
        }

        // Third-party pass-through path: synthesize modifier lifecycle + key chord.
        activeThirdPartyChords[keyCode] = effectiveMods
        return .synthesizeThirdPartyKeyDown(keyCode: keyCode, modifiers: effectiveMods, flags: effectiveFlags)
    }

    mutating func handleKeyUp(
        keyCode: UInt16,
        flags: CGEventFlags,
        userData: Int64,
        timestampNs: UInt64
    ) -> Decision {
        if userData == Self.syntheticEventTag {
            return .passThrough
        }

        if keyCode == Self.f18KeyCode {
            guard isHeld else {
                return .passThrough
            }
            let wasChord = usedAsChord
            let elapsedMs: Int
            if timestampNs >= downTimestampNs {
                elapsedMs = Int((timestampNs - downTimestampNs) / 1_000_000)
            } else {
                elapsedMs = Int.max
            }
            isHeld = false
            downTimestampNs = 0
            usedAsChord = false

            if !wasChord && elapsedMs <= tapThresholdMs {
                return .triggerTapAction(tapAction)
            }
            if !wasChord {
                return .heldReleasedWithoutChord
            }
            return .swallowOnly
        }

        if swallowedToolboxKeyCodes.remove(keyCode) != nil {
            return .swallowOnly
        }

        if let mods = activeThirdPartyChords.removeValue(forKey: keyCode) {
            return .synthesizeThirdPartyKeyUp(
                keyCode: keyCode,
                modifiers: mods,
                flags: Self.cgFlags(for: mods)
            )
        }

        return .passThrough
    }

    static func modifiers(from flags: CGEventFlags) -> [KeyModifier] {
        var result: [KeyModifier] = []
        if flags.contains(.maskControl) { result.append(.control) }
        if flags.contains(.maskAlternate) { result.append(.option) }
        if flags.contains(.maskShift) { result.append(.shift) }
        if flags.contains(.maskCommand) { result.append(.command) }
        return result
    }

    static func orderedModifierUnion(_ lhs: [KeyModifier], _ rhs: [KeyModifier]) -> [KeyModifier] {
        let ordered: [KeyModifier] = [.control, .option, .shift, .command]
        let combined = Set(lhs).union(rhs)
        return ordered.filter { combined.contains($0) }
    }

    static func cgFlags(for modifiers: [KeyModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for mod in modifiers {
            switch mod {
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .shift: flags.insert(.maskShift)
            case .command: flags.insert(.maskCommand)
            }
        }
        return flags
    }
}

private struct TapProtectedState: Sendable {
    var machine = HyperKeyStateMachine()
    var callControls = HyperKeyCallControlsBindings()
}

private final class HyperKeyTapStartState: @unchecked Sendable {
    var succeeded = false
}

/// Dedicated background `CGEventTap` intercepting `F18` (remapped Caps Lock) for dual-role Hyper Key behavior.
final class HyperKeyEventTap: @unchecked Sendable {
    static let relevantModifierMask: CGEventFlags = [
        .maskControl,
        .maskAlternate,
        .maskShift,
        .maskCommand
    ]

    private let lifecycleLock = NSLock()
    private let fieldsLock = NSLock()
    private let stateLock = OSAllocatedUnfairLock<TapProtectedState>(initialState: TapProtectedState())
    private let postQueue = DispatchQueue(label: "app.toolbox.hyperkey-post", qos: .userInteractive)
    nonisolated private static let sharedHeldModifiersLock = OSAllocatedUnfairLock<CGEventFlags>(initialState: [])

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var tapExitSemaphore: DispatchSemaphore?

    var onTriggerToolboxHotKey: (@MainActor @Sendable (String, ShortcutSpec) -> Void)?
    var onTriggerCallControls: (@MainActor @Sendable (CallActionKind, ShortcutSpec) -> Void)?
    var onToggleCapsLock: (@MainActor @Sendable () -> Void)?
    var onLiveEvent: (@MainActor @Sendable (HyperKeyLiveEvent) -> Void)?
    var onHoldModifiersChanged: (@MainActor @Sendable (CGEventFlags) -> Void)?

    nonisolated static func currentHeldModifierFlags() -> CGEventFlags {
        sharedHeldModifiersLock.withLock { $0 }
    }

    private func syncSharedHeldModifiers(_ flags: CGEventFlags) {
        let changed = Self.sharedHeldModifiersLock.withLock { current -> Bool in
            guard current != flags else { return false }
            current = flags
            return true
        }
        guard changed, let cb = onHoldModifiersChanged else { return }
        Task { @MainActor in
            cb(flags)
        }
    }

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

    func updateConfig(_ config: HyperKeyConfig) {
        let heldFlags: CGEventFlags = stateLock.withLock { state in
            state.machine.holdMode = config.holdMode
            state.machine.tapAction = config.tapAction
            state.machine.tapThresholdMs = HyperKeyConfig.clampedTapThresholdMs(config.tapThresholdMs)
            return state.machine.isHeld ? state.machine.holdMode.cgEventFlags : []
        }
        syncSharedHeldModifiers(heldFlags)
    }

    func updateCallControlsBindings(_ bindings: HyperKeyCallControlsBindings) {
        stateLock.withLock { state in
            state.callControls = bindings
        }
    }

    func resetTransientState() {
        stateLock.withLock { state in
            state.machine.resetTransientState()
        }
        syncSharedHeldModifiers([])
    }

    @discardableResult
    func install() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        uninstallLocked()

        let readySem = DispatchSemaphore(value: 0)
        let exitSem = DispatchSemaphore(value: 0)
        let startState = HyperKeyTapStartState()

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                exitSem.signal()
                return
            }

            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            guard let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<HyperKeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                    return owner.handleTapEvent(type: type, event: event)
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
        thread.name = "app.toolbox.hyperkey-tap"
        thread.qualityOfService = .userInteractive

        fieldsLock.lock()
        tapThread = thread
        tapExitSemaphore = exitSem
        fieldsLock.unlock()
        thread.start()
        // Bounded wait: the tap thread signals readySem on every setup path (success, failure, or
        // missing self), so a timeout here means the thread is stuck before signaling.
        _ = readySem.wait(timeout: .now() + 5.0)

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

        resetTransientState()

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

    // MARK: - CGEventTap Callback

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            fieldsLock.lock()
            let currentTap = tap
            fieldsLock.unlock()
            if PermissionsManager.shouldRearmEventTap(for: type), let currentTap {
                CGEvent.tapEnable(tap: currentTap, enable: true)
            } else {
                resetTransientState()
                Task { @MainActor in
                    PermissionsManager.shared.refresh()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if IsSecureEventInputEnabled() {
            resetTransientState()
            return Unmanaged.passUnretained(event)
        }

        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == HyperKeyStateMachine.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let timestampNs = UInt64(event.timestamp)

        let decision: HyperKeyStateMachine.Decision
        let heldFlags: CGEventFlags
        switch type {
        case .keyDown:
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let registeredHotKeys = HotKeyManager.currentActiveBindingsSnapshot()
            (decision, heldFlags) = stateLock.withLock { state in
                let d = state.machine.handleKeyDown(
                    keyCode: keyCode,
                    flags: flags,
                    isAutoRepeat: isAutoRepeat,
                    userData: userData,
                    timestampNs: timestampNs,
                    registeredHotKeys: registeredHotKeys,
                    callControls: state.callControls
                )
                return (d, state.machine.isHeld ? state.machine.holdMode.cgEventFlags : [])
            }

        case .keyUp:
            (decision, heldFlags) = stateLock.withLock { state in
                let d = state.machine.handleKeyUp(
                    keyCode: keyCode,
                    flags: flags,
                    userData: userData,
                    timestampNs: timestampNs
                )
                return (d, state.machine.isHeld ? state.machine.holdMode.cgEventFlags : [])
            }

        default:
            return Unmanaged.passUnretained(event)
        }
        syncSharedHeldModifiers(heldFlags)

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)

        case .swallowOnly:
            return nil

        case .dispatchToolboxHotKey(let name, let shortcut):
            let triggerCB = onTriggerToolboxHotKey
            Task { @MainActor in
                triggerCB?(name, shortcut)
            }
            return nil

        case .dispatchCallControls(let action, let shortcut):
            let callCB = onTriggerCallControls
            Task { @MainActor in
                callCB?(action, shortcut)
            }
            return nil

        case .synthesizeThirdPartyKeyDown(let targetKeyCode, let modifiers, let synthFlags):
            let keyLabel = ShortcutSpec.keyName(for: targetKeyCode) ?? "Key(\(targetKeyCode))"
            let chordDisplay = ShortcutSpec(key: keyLabel, modifiers: modifiers).displayString
            postThirdPartyKeyDown(keyCode: targetKeyCode, flags: synthFlags)
            emitLiveEvent(HyperKeyLiveEvent(
                timestamp: Date(),
                summary: "Held → Sent \(chordDisplay) to active app",
                detail: nil,
                kind: .thirdPartyChord
            ))
            return nil

        case .synthesizeThirdPartyKeyUp(let targetKeyCode, _, let synthFlags):
            postThirdPartyKeyUp(keyCode: targetKeyCode, flags: synthFlags)
            return nil

        case .triggerTapAction(let action):
            switch action {
            case .capsLock:
                let toggleCB = onToggleCapsLock
                Task { @MainActor in
                    toggleCB?()
                }
            case .escape:
                postEscapeTap()
                emitLiveEvent(HyperKeyLiveEvent(
                    timestamp: Date(),
                    summary: "Tapped → Escape (⎋)",
                    detail: nil,
                    kind: .tapAction
                ))
            case .none:
                emitLiveEvent(HyperKeyLiveEvent(
                    timestamp: Date(),
                    summary: "Tapped → Ignored (Single Tap Disabled)",
                    detail: nil,
                    kind: .tapAction
                ))
            }
            return nil

        case .heldReleasedWithoutChord:
            emitLiveEvent(HyperKeyLiveEvent(
                timestamp: Date(),
                summary: "Held past tap threshold → No chord pressed",
                detail: nil,
                kind: .heldReleased
            ))
            return nil
        }
    }

    private func emitLiveEvent(_ event: HyperKeyLiveEvent) {
        let cb = onLiveEvent
        Task { @MainActor in
            cb?(event)
        }
    }

    private func postThirdPartyKeyDown(keyCode: UInt16, flags: CGEventFlags) {
        postQueue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            if let flagsEvent = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Command), keyDown: true) {
                flagsEvent.type = .flagsChanged
                flagsEvent.flags = flags
                flagsEvent.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
                flagsEvent.post(tap: .cgSessionEventTap)
            }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
                down.flags = flags
                down.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
                down.post(tap: .cgSessionEventTap)
            }
        }
    }

    private func postThirdPartyKeyUp(keyCode: UInt16, flags: CGEventFlags) {
        postQueue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
                up.flags = flags
                up.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
                up.post(tap: .cgSessionEventTap)
            }
            let currentPhysical = CGEventSource.flagsState(.hidSystemState).intersection(Self.relevantModifierMask)
            if let flagsUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Command), keyDown: false) {
                flagsUp.type = .flagsChanged
                flagsUp.flags = currentPhysical
                flagsUp.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
                flagsUp.post(tap: .cgSessionEventTap)
            }
        }
    }

    private func postEscapeTap() {
        postQueue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Escape), keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Escape), keyDown: false) {
                down.flags = []
                up.flags = []
                down.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
                up.setIntegerValueField(.eventSourceUserData, value: HyperKeyStateMachine.syntheticEventTag)
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }
}
