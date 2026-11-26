import Foundation

/// Pure, side-effect-free policy deciding which microphone should become the system default
/// input when macOS (or a call/browser app) switches it to a Bluetooth headset.
///
/// macOS drops Bluetooth headphones from high-quality stereo (`A2DP`) to the low-bitrate mono
/// Hands-Free Profile (`HFP`) as soon as a Bluetooth microphone is opened. Keeping the default
/// input on a wired or built-in mic keeps the headset in stereo while still routing call audio
/// and output to the headset.
enum BluetoothMicLockPolicy {
    /// Inputs eligible as a fallback. Physical non-Bluetooth microphones win; virtual/aggregate
    /// devices are only used when no physical non-Bluetooth input exists (never leave the user
    /// without a working microphone, but don't route calls into a loopback driver by choice).
    static func fallbackCandidates(from devices: [AudioDeviceInfo]) -> [AudioDeviceInfo] {
        let inputs = devices.filter { $0.hasInput && $0.transport != .bluetooth }
        let physical = inputs.filter { $0.transport != .virtual && $0.transport != .aggregate }
        return physical.isEmpty ? inputs : physical
    }

    /// Resolves the microphone to revert to, or `nil` when no revert is warranted.
    ///
    /// Priority: explicit preferred fallback → last known non-Bluetooth default → USB →
    /// built-in → any remaining non-Bluetooth input.
    static func resolveRevertTarget(
        currentDefaultInput: AudioDeviceInfo?,
        availableInputs: [AudioDeviceInfo],
        preferredFallbackUID: String?,
        lastNonBluetoothUID: String?,
        bypassedBluetoothUID: String?
    ) -> AudioDeviceInfo? {
        guard let current = currentDefaultInput, current.transport == .bluetooth else {
            return nil
        }
        if let bypassedBluetoothUID, !bypassedBluetoothUID.isEmpty, current.uid == bypassedBluetoothUID {
            return nil
        }
        return resolveFallback(
            availableInputs: availableInputs,
            preferredFallbackUID: preferredFallbackUID,
            lastNonBluetoothUID: lastNonBluetoothUID
        )
    }

    /// Priority-order fallback resolution, independent of what is currently selected.
    static func resolveFallback(
        availableInputs: [AudioDeviceInfo],
        preferredFallbackUID: String?,
        lastNonBluetoothUID: String?
    ) -> AudioDeviceInfo? {
        let candidates = fallbackCandidates(from: availableInputs)
        guard !candidates.isEmpty else { return nil }

        if let preferredFallbackUID, !preferredFallbackUID.isEmpty,
           let preferred = candidates.first(where: { $0.uid == preferredFallbackUID }) {
            return preferred
        }
        if let lastNonBluetoothUID, !lastNonBluetoothUID.isEmpty,
           let last = candidates.first(where: { $0.uid == lastNonBluetoothUID }) {
            return last
        }
        if let usb = candidates.first(where: { $0.transport == .usb }) {
            return usb
        }
        if let builtIn = candidates.first(where: { $0.transport == .builtIn }) {
            return builtIn
        }
        return candidates.first
    }

    /// Human-readable label for the `Auto (USB → Built-in)` fallback mode.
    static let autoFallbackLabel = "Auto: USB → Built-in"

    /// Returns the saved fallback UID when that device is no longer connected, so the picker can
    /// show a "disconnected" placeholder instead of a blank (invalid) selection.
    static func disconnectedFallbackUID(
        _ savedUID: String?,
        available: [AudioDeviceInfo]
    ) -> String? {
        guard let savedUID, !savedUID.isEmpty else { return nil }
        return available.contains(where: { $0.uid == savedUID }) ? nil : savedUID
    }

    /// How the temporary override must react when the user picks a device by hand.
    ///
    /// Only a *successful* switch may change the override, otherwise a failed CoreAudio write
    /// would leave the guard bypassed with no headset mic to show for it.
    static func bypassActionAfterManualInputSelection(
        selectedUID: String,
        selectedIsBluetooth: Bool,
        switchSucceeded: Bool,
        guardEnabled: Bool,
        currentlyBypassed: Bool
    ) -> BluetoothMicBypassAction {
        guard switchSucceeded else { return .unchanged }
        if selectedIsBluetooth, guardEnabled {
            return .arm(selectedUID)
        }
        return currentlyBypassed ? .clear : .unchanged
    }

    /// Bundle IDs of processes capturing a Bluetooth microphone **that is not the current system
    /// default**. Those apps picked the headset mic themselves, so they force hands-free call mode
    /// no matter what the system default input is - the guard cannot win, and the user has to set
    /// that app's microphone to "Same as System" (or the fallback device) for stereo to survive.
    /// Bundle ID prefixes belonging to system daemons and voice assistants. They may briefly open
    /// the headset mic (dictation, "Hey Siri"), but the user has no per-app microphone setting to
    /// change, so warning about them would be noise with no fix behind it.
    static let nonActionableCaptureBundleIDPrefixes: [String] = [
        "com.apple.siri",
        "com.apple.assistant",
        "com.apple.corespeech",
        "com.apple.speech",
        "com.apple.voicebanking",
        "com.apple.dictation",
        "com.apple.controlcenter",
        "com.apple.accessibility",
        "com.apple.telephonyutilities",
        "com.apple.avconferenced",
        "com.apple.mediaremoted",
        "com.apple.audiomxd",
        "com.apple.coreaudio",
        "systemsoundserverd"
    ]

    /// `true` when the capture is something the user can actually re-point at "Same as System".
    static func isActionableCaptureBundleID(_ bundleID: String) -> Bool {
        let low = bundleID.lowercased()
        guard !low.isEmpty else { return false }
        return !nonActionableCaptureBundleIDPrefixes.contains { low.hasPrefix($0) }
    }

    static func pinnedBluetoothMicBundleIDs(
        captures: [ProcessInputCapture],
        devices: [AudioDeviceInfo],
        defaultInputUID: String?
    ) -> [String] {
        let bluetoothInputs = devices.filter { $0.hasInput && $0.transport == .bluetooth }
        guard !bluetoothInputs.isEmpty else { return [] }

        let bluetoothDeviceIDs = Set(bluetoothInputs.map(\.deviceID))
        let defaultBluetoothDeviceID = bluetoothInputs.first { $0.uid == defaultInputUID }?.deviceID

        var pinned: Set<String> = []
        for capture in captures {
            guard let bundleID = capture.bundleID, isActionableCaptureBundleID(bundleID) else { continue }
            let usedBluetoothDevices = capture.deviceIDs.filter { bluetoothDeviceIDs.contains($0) }
            guard !usedBluetoothDevices.isEmpty else { continue }
            // Capturing the headset mic *because it is the system default* is expected (and
            // already handled by the guard), not a pinned app.
            if let defaultBluetoothDeviceID, usedBluetoothDevices.allSatisfy({ $0 == defaultBluetoothDeviceID }) {
                continue
            }
            pinned.insert(bundleID)
        }
        return pinned.sorted()
    }
}

/// Sliding-window rate limiter that stops Toolbox from thrashing CoreAudio when an app
/// aggressively re-selects its Bluetooth microphone (e.g. a tight reconnect loop).
struct BluetoothMicRevertLoopBreaker: Equatable, Sendable {
    static let windowSeconds: TimeInterval = 5
    static let maxRevertsPerWindow: Int = 4
    static let pauseSeconds: TimeInterval = 15

    private(set) var revertTimestamps: [TimeInterval] = []
    private(set) var pausedUntil: TimeInterval?

    /// Records a revert and returns `true` when this revert tripped the pause threshold.
    @discardableResult
    mutating func registerRevert(at now: TimeInterval) -> Bool {
        pruneExpired(at: now)
        revertTimestamps.append(now)
        guard revertTimestamps.count > Self.maxRevertsPerWindow else { return false }
        revertTimestamps.removeAll()
        pausedUntil = now + Self.pauseSeconds
        return true
    }

    func isPaused(at now: TimeInterval) -> Bool {
        guard let pausedUntil else { return false }
        return now < pausedUntil
    }

    mutating func pruneExpired(at now: TimeInterval) {
        revertTimestamps.removeAll { now - $0 > Self.windowSeconds }
        if let pausedUntil, now >= pausedUntil {
            self.pausedUntil = nil
        }
    }
}

/// What to do with the temporary override after the user picks an input device by hand.
enum BluetoothMicBypassAction: Equatable, Sendable {
    case arm(String)
    case clear
    case unchanged
}

/// What the controller decided (or declined) to do during one evaluation pass.
enum BluetoothMicLockOutcome: Equatable, Sendable {
    case idle
    case reverted(targetUID: String)
    case suppressedByBypass(bluetoothUID: String)
    case suppressedByLoopBreaker(bluetoothUID: String)
    case suppressedByNoFallback(bluetoothUID: String)
    case revertFailed(targetUID: String)
}

/// Observable snapshot the Call Controls UI renders (published by `CallControlsModule`).
struct BluetoothMicLockState: Equatable, Sendable {
    var isEnabled: Bool = false
    var bluetoothDefaultInputName: String? = nil
    var bypassedBluetoothName: String? = nil
    var resolvedFallbackName: String? = nil
    var isThrottled: Bool = false
    var lastRevertSummary: String? = nil

    var isBluetoothMicBypassed: Bool { bypassedBluetoothName != nil }
}

/// Zero-permission CoreAudio guard that keeps the default input locked to a non-Bluetooth
/// microphone so Bluetooth headphones stay in high-quality stereo.
///
/// The controller is deliberately decoupled from `CoreAudioController` through injected
/// closures so the revert policy, debounce, loop breaker, and state machine are unit-testable
/// without touching real audio hardware.
@MainActor
final class BluetoothMicLockController {
    typealias DeviceListProvider = () -> [AudioDeviceInfo]
    typealias DefaultInputSetter = (String) -> Bool
    typealias TimeProvider = () -> TimeInterval

    /// Suppression/debounce window: long enough to skip mid-handshake device churn.
    static let debounceInterval: TimeInterval = 0.15

    /// Fired after the default input was moved off `from` onto `to`.
    var onReverted: ((AudioDeviceInfo, AudioDeviceInfo) -> Void)?
    /// Fired when the loop breaker pauses auto-revert for a Bluetooth device.
    var onLoopBreakerTripped: ((AudioDeviceInfo, TimeInterval) -> Void)?
    /// Fired whenever `state` changes so the module can republish it.
    var onStateChanged: (() -> Void)?

    private(set) var state = BluetoothMicLockState()

    private let listDevices: DeviceListProvider
    private let setDefaultInputDevice: DefaultInputSetter
    private let now: TimeProvider

    private var isEnabled = false
    private var fallbackUID: String?
    private var bypassedBluetoothUID: String?
    private var lastNonBluetoothUID: String?
    private var isThrottled = false
    private var lastRevertSummary: String?
    private var loopBreakers: [String: BluetoothMicRevertLoopBreaker] = [:]
    private var pendingEvaluation: DispatchWorkItem?
    /// Delayed re-evaluation scheduled when the loop breaker pauses the guard, so the promised
    /// retry actually happens even if no further CoreAudio event arrives.
    private var pendingLoopBreakerRetry: DispatchWorkItem?

    init(
        listDevices: @escaping DeviceListProvider = { CoreAudioController.listDevices() },
        setDefaultInputDevice: @escaping DefaultInputSetter,
        now: @escaping TimeProvider = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.listDevices = listDevices
        self.setDefaultInputDevice = setDefaultInputDevice
        self.now = now
    }

    // MARK: - Public State

    var bypassedUID: String? { bypassedBluetoothUID }
    var hasPendingEvaluation: Bool { pendingEvaluation != nil }
    var hasPendingLoopBreakerRetry: Bool { pendingLoopBreakerRetry != nil }

    // MARK: - Configuration & Lifecycle

    func configure(enabled: Bool, fallbackUID: String?) {
        let previousFallback = self.fallbackUID
        let wasEnabled = isEnabled
        self.isEnabled = enabled
        self.fallbackUID = fallbackUID?.isEmpty == true ? nil : fallbackUID

        guard enabled else {
            invalidate() // also refreshes published state
            return
        }

        if !wasEnabled || previousFallback != self.fallbackUID {
            // Evaluate right away when the guard engages or the user picks a new fallback mic.
            scheduleEvaluation()
        }
        refreshState()
    }

    /// Cancels pending debounce/retry work and drops all transient state (module disabled,
    /// paused, or the app is quitting). The bypass is intentionally cleared too: re-enabling
    /// later must not silently inherit a choice the user made in an earlier session.
    func invalidate() {
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        pendingLoopBreakerRetry?.cancel()
        pendingLoopBreakerRetry = nil
        isEnabled = false
        isThrottled = false
        bypassedBluetoothUID = nil
        lastRevertSummary = nil
        loopBreakers.removeAll()
        refreshState()
    }

    /// Arms the temporary override so the guard leaves the given Bluetooth device alone
    /// until it disconnects.
    func armBypass(bluetoothUID: String) {
        guard !bluetoothUID.isEmpty else { return }
        bypassedBluetoothUID = bluetoothUID
        refreshState()
    }

    /// Clears the temporary override immediately and re-runs the guard.
    func clearBypass() {
        guard bypassedBluetoothUID != nil else { return }
        bypassedBluetoothUID = nil
        cancelLoopBreakerRetry()
        refreshState()
        scheduleEvaluation()
    }

    // MARK: - Event Hooks

    /// `kAudioHardwarePropertyDevices` changed: clears a stale bypass once the headset is gone.
    func handleDevicesChanged() {
        guard isEnabled else {
            refreshState()
            return
        }
        if let bypassed = bypassedBluetoothUID,
           !listDevices().contains(where: { $0.uid == bypassed }) {
            bypassedBluetoothUID = nil
        }
        refreshState()
        scheduleEvaluation()
    }

    /// `kAudioHardwarePropertyDefaultInputDevice` changed (often to a Bluetooth mic when a call
    /// app opens the microphone).
    func handleDefaultInputChanged() {
        guard isEnabled else { return }
        refreshState()
        scheduleEvaluation()
    }

    // MARK: - Debounced Evaluation

    private func scheduleEvaluation() {
        guard isEnabled else { return }
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingEvaluation = nil
            guard self.isEnabled else { return }
            self.evaluate()
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Re-evaluations are also driven by CoreAudio events, but a paused guard must retry on its own
    /// timer: the call app may already hold the Bluetooth mic, so no further event would arrive to
    /// wake the guard up after `pausedUntil` passes.
    private func scheduleLoopBreakerRetry(after delay: TimeInterval) {
        cancelLoopBreakerRetry()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingLoopBreakerRetry = nil
            guard self.isEnabled else { return }
            self.evaluate()
        }
        pendingLoopBreakerRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, delay), execute: work)
    }

    private func cancelLoopBreakerRetry() {
        pendingLoopBreakerRetry?.cancel()
        pendingLoopBreakerRetry = nil
    }

    /// Runs one revert evaluation synchronously (also used by self-tests with an injected clock).
    @discardableResult
    func evaluate() -> BluetoothMicLockOutcome {
        evaluate(at: now())
    }

    @discardableResult
    func evaluate(at timestamp: TimeInterval) -> BluetoothMicLockOutcome {
        guard isEnabled else { return .idle }

        let devices = listDevices()
        let inputs = devices.filter(\.hasInput)
        let defaultInput = inputs.first(where: \.isDefaultInput)

        // Remember the last non-Bluetooth default so we can prefer it over "first USB device".
        if let defaultInput, defaultInput.transport != .bluetooth {
            lastNonBluetoothUID = defaultInput.uid
        }
        if let bypassed = bypassedBluetoothUID,
           !devices.contains(where: { $0.uid == bypassed }) {
            bypassedBluetoothUID = nil
        }

        guard let bluetoothInput = defaultInput,
              bluetoothInput.transport == .bluetooth,
              bluetoothInput.hasInput else {
            isThrottled = false
            refreshState()
            return .idle
        }

        if let breaker = loopBreakers[bluetoothInput.uid], breaker.isPaused(at: timestamp) {
            isThrottled = true
            scheduleLoopBreakerRetry(after: (breaker.pausedUntil ?? timestamp) - timestamp)
            refreshState()
            return .suppressedByLoopBreaker(bluetoothUID: bluetoothInput.uid)
        }
        isThrottled = false
        if pendingLoopBreakerRetry != nil {
            cancelLoopBreakerRetry()
        }

        if let bypassedBluetoothUID, bypassedBluetoothUID == bluetoothInput.uid {
            refreshState()
            return .suppressedByBypass(bluetoothUID: bluetoothInput.uid)
        }

        guard let target = BluetoothMicLockPolicy.resolveRevertTarget(
            currentDefaultInput: bluetoothInput,
            availableInputs: inputs,
            preferredFallbackUID: fallbackUID,
            lastNonBluetoothUID: lastNonBluetoothUID,
            bypassedBluetoothUID: nil
        ) else {
            refreshState()
            return .suppressedByNoFallback(bluetoothUID: bluetoothInput.uid)
        }

        guard setDefaultInputDevice(target.uid) else {
            refreshState()
            return .revertFailed(targetUID: target.uid)
        }

        lastNonBluetoothUID = target.uid
        lastRevertSummary = "\(bluetoothInput.name) → \(target.name)"

        var breaker = loopBreakers[bluetoothInput.uid] ?? BluetoothMicRevertLoopBreaker()
        let didTrip = breaker.registerRevert(at: timestamp)
        loopBreakers[bluetoothInput.uid] = breaker
        if didTrip {
            isThrottled = true
        }

        refreshState()
        onReverted?(bluetoothInput, target)

        if didTrip {
            scheduleLoopBreakerRetry(after: BluetoothMicRevertLoopBreaker.pauseSeconds)
            onLoopBreakerTripped?(bluetoothInput, timestamp + BluetoothMicRevertLoopBreaker.pauseSeconds)
        }
        return .reverted(targetUID: target.uid)
    }

    // MARK: - Derived State

    private func refreshState() {
        let devices = listDevices()
        let inputs = devices.filter(\.hasInput)
        let defaultInput = inputs.first(where: \.isDefaultInput)
        let bluetoothDefault = (defaultInput?.transport == .bluetooth && defaultInput?.hasInput == true)
            ? defaultInput
            : nil

        let bypassedName: String? = {
            guard let bypassedBluetoothUID else { return nil }
            guard let match = inputs.first(where: { $0.uid == bypassedBluetoothUID }) else { return nil }
            return match.name
        }()

        let fallback = BluetoothMicLockPolicy.resolveFallback(
            availableInputs: inputs,
            preferredFallbackUID: fallbackUID,
            lastNonBluetoothUID: lastNonBluetoothUID
        )

        var updated = BluetoothMicLockState()
        updated.isEnabled = isEnabled
        updated.isThrottled = isThrottled
        updated.lastRevertSummary = lastRevertSummary
        updated.bluetoothDefaultInputName = bluetoothDefault?.name
        updated.bypassedBluetoothName = bypassedName
        updated.resolvedFallbackName = fallback?.name

        if updated != state {
            state = updated
            onStateChanged?()
        }
    }
}
