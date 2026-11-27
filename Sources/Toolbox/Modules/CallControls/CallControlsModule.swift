import AppKit
import ApplicationServices
import CoreAudio
import SwiftUI

/// In-memory call & hardware state override used by Developer Tools to test Call Controls
/// behavior and floating pill UI without modifying config or OS audio hardware.
struct CallSimulationState: Equatable, Sendable {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case zoomCall
        case faceTimeCall
        case slackHuddle
        case teamsBackground
        case googleMeetTab
        case discordCall
        case noCallApp
        case typingAutoMuted

        var id: String { rawValue }

        var label: String {
            switch self {
            case .zoomCall: return "Zoom Call"
            case .faceTimeCall: return "FaceTime Call"
            case .slackHuddle: return "Slack Huddle"
            case .teamsBackground: return "Teams (Bg)"
            case .googleMeetTab: return "Google Meet"
            case .discordCall: return "Discord Call"
            case .noCallApp: return "No Call App"
            case .typingAutoMuted: return "Typing Mute"
            }
        }
    }

    enum AppPlacement: String, CaseIterable, Identifiable, Sendable {
        case frontmost
        case background

        var id: String { rawValue }

        var label: String {
            switch self {
            case .frontmost: return "Frontmost App"
            case .background: return "Running in Background"
            }
        }
    }

    enum DeviceProfile: String, CaseIterable, Identifiable, Sendable {
        case macBookPro
        case airPods
        case noHardware

        var id: String { rawValue }

        var label: String {
            switch self {
            case .macBookPro: return "MacBook Pro"
            case .airPods: return "AirPods"
            case .noHardware: return "No Mic / No Cam"
            }
        }
    }

    enum PillVisibilityMode: String, CaseIterable, Identifiable, Sendable {
        case forceShow
        case autoDuringCall
        case forceHide

        var id: String { rawValue }

        var label: String {
            switch self {
            case .forceShow: return "Show"
            case .autoDuringCall: return "Auto (Call)"
            case .forceHide: return "Hide"
            }
        }
    }

    var targetAppID: String = "zoom" // "none" or a CallAppShortcutMapping.id
    var appPlacement: AppPlacement = .frontmost
    var customWindowTitle: String = "Zoom Meeting"
    var isMicStreamActive: Bool = true
    var isMuted: Bool = false
    var isTypingMuted: Bool = false
    var isCameraActive: Bool = true
    var hasInputDevice: Bool = true
    var hasCameraDevice: Bool = true
    var inputDeviceName: String = "MacBook Pro Microphone"
    var cameraDeviceName: String = "FaceTime HD"
    var pillVisibilityMode: PillVisibilityMode = .forceShow
    var simulateAccessibilityGranted: Bool = true
    var simulatedScopeOverride: CallOverrideScope? = nil

    var deviceProfile: DeviceProfile {
        get {
            if !hasInputDevice && !hasCameraDevice { return .noHardware }
            if inputDeviceName == "AirPods" { return .airPods }
            return .macBookPro
        }
        set {
            switch newValue {
            case .macBookPro:
                hasInputDevice = true
                hasCameraDevice = true
                inputDeviceName = "MacBook Pro Microphone"
                cameraDeviceName = "FaceTime HD"
            case .airPods:
                hasInputDevice = true
                hasCameraDevice = true
                inputDeviceName = "AirPods"
                cameraDeviceName = "FaceTime HD"
            case .noHardware:
                hasInputDevice = false
                hasCameraDevice = false
                isMicStreamActive = false
                isCameraActive = false
                isTypingMuted = false
                inputDeviceName = "No Microphone"
                cameraDeviceName = "No Camera"
            }
        }
    }

    static func preset(_ preset: Preset) -> CallSimulationState {
        switch preset {
        case .zoomCall:
            return CallSimulationState(
                targetAppID: "zoom",
                appPlacement: .frontmost,
                customWindowTitle: "Zoom Meeting",
                isMicStreamActive: true,
                isMuted: false,
                isTypingMuted: false,
                isCameraActive: true
            )
        case .faceTimeCall:
            return CallSimulationState(
                targetAppID: "facetime",
                appPlacement: .frontmost,
                customWindowTitle: "FaceTime",
                isMicStreamActive: true,
                isMuted: false,
                isTypingMuted: false,
                isCameraActive: true
            )
        case .slackHuddle:
            return CallSimulationState(
                targetAppID: "slack",
                appPlacement: .frontmost,
                customWindowTitle: "Slack Huddle",
                isMicStreamActive: true,
                isMuted: false,
                isTypingMuted: false,
                isCameraActive: false
            )
        case .teamsBackground:
            return CallSimulationState(
                targetAppID: "teams",
                appPlacement: .background,
                customWindowTitle: "Microsoft Teams Meeting",
                isMicStreamActive: true,
                isMuted: false,
                isTypingMuted: false,
                isCameraActive: true
            )
        case .googleMeetTab:
            return CallSimulationState(
                targetAppID: "google_meet",
                appPlacement: .frontmost,
                customWindowTitle: "Meet - Daily Standup",
                isMicStreamActive: true,
                isMuted: false,
                isTypingMuted: false,
                isCameraActive: true
            )
        case .discordCall:
            return CallSimulationState(
                targetAppID: "discord",
                appPlacement: .frontmost,
                customWindowTitle: "Discord Voice",
                isMicStreamActive: true,
                isMuted: false,
                isTypingMuted: false,
                isCameraActive: false
            )
        case .noCallApp:
            return CallSimulationState(
                targetAppID: "none",
                appPlacement: .frontmost,
                customWindowTitle: "Desktop",
                isMicStreamActive: true,
                isMuted: false,
                isTypingMuted: false,
                isCameraActive: false
            )
        case .typingAutoMuted:
            return CallSimulationState(
                targetAppID: "zoom",
                appPlacement: .background,
                customWindowTitle: "Zoom Meeting",
                isMicStreamActive: true,
                isMuted: true,
                isTypingMuted: true,
                isCameraActive: false
            )
        }
    }
}

@MainActor
final class CallControlsModule: ToolboxModule, ObservableObject {
    let id = "call_controls"
    let name = "Call Controls"
    let tagline = "Use one custom mic and video shortcut across Teams, Zoom, Slack & Meet, switch audio devices, and auto-mute while typing."
    let aboutSummary = "Set one custom Mic and Video keybind that works across apps: mutes your macOS microphone globally and relays your shortcuts into FaceTime (mic), Microsoft Teams, Zoom, Slack, Google Meet, and Discord. Includes a draggable Mic & Camera floating pill, audio output cycling, and Auto-Mute While Typing. Note: macOS has no global OS camera mute and FaceTime has no camera shortcut, so camera toggling works inside call apps that expose a native video shortcut."
    let featureTips = [
        "Set My Mic Keybind once: under Everywhere scope it toggles your macOS mic in any app and relays into active or running calls like FaceTime, Teams, Zoom, Slack, or Meet.",
        "Video toggling relays to apps with a native camera shortcut (Teams, Zoom, Google Meet, or any app you assign a Native Video key for); macOS sandboxes cameras per app and FaceTime exposes no video-off shortcut.",
        "If you prefer your shortcut not to intercept outside calls (e.g. Cmd+Shift+Space in code editors), switch Override Scope to Active or background call apps or Active call app only.",
        "Star your favorite speakers and headphones to switch between them in one click or shortcut.",
        "Auto-Mute While Typing never overrides a manual mute: if you muted yourself, typing will never unmute your mic."
    ]
    let symbolName = "mic.slash"
    let accentColor = Color.green
    let category: ModuleCategory = .system
    let requiresAccessibility = false
    let accessibilityReason = "Needed to translate your unified Mic/Video call keybinds and detect keystrokes for Auto-Mute While Typing. Hardware mic mute, camera status indicator, and audio device switching work without Accessibility."

    let osMuteHotKeyName = "call_controls.os_mute"
    let cycleOutputHotKeyName = "call_controls.cycle_output"

    @Published private(set) var isRunning = false
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var hardwareInputMuted: Bool = false
    @Published private(set) var callAppMutedState: Bool? = nil
    @Published private(set) var isInputMuted: Bool = false
    @Published private(set) var isTypingMuted: Bool = false
    @Published private(set) var isMicStreamActive: Bool = false
    @Published private(set) var hasActiveCallAppSession: Bool = false
    @Published private(set) var isCameraActive: Bool = false
    @Published private(set) var activeCameraName: String? = nil
    @Published private(set) var hasCameraDevice: Bool = false
    @Published private(set) var isRemapperTapInstalled: Bool = false
    @Published private(set) var isTypingTapInstalled: Bool = false
    @Published private(set) var lastRelayedActionLabel: String? = nil
    @Published private(set) var runningAppBundleIDs: Set<String> = []
    @Published private(set) var floatingPillFrameSnapshot: NSRect? = nil
    @Published var developerSimulation: CallSimulationState? = nil {
        didSet {
            syncCallShortcutRemapper()
            syncFloatingIndicator()
            ModuleRegistry.shared.notifyChanged()
        }
    }
    @Published private(set) var lastSimulationOutcome: String? = nil
    @Published private(set) var bluetoothMicLockState = BluetoothMicLockState()
    /// Apps that opened the Bluetooth mic themselves, so the mic guard cannot protect stereo.
    @Published private(set) var pinnedBluetoothMicAppNames: [String] = []

    private var config = CallControlsConfig()
    private var appEnabled = true

    private let coreAudio = CoreAudioController()
    private let callRemapper = CallShortcutRemapper()
    private let typingGuard = TypingMicGuard()
    private let floatingIndicator = FloatingMicIndicatorPanel()
    private lazy var bluetoothMicLock = BluetoothMicLockController(
        listDevices: { CoreAudioController.listDevices() },
        setDefaultInputDevice: { [weak self] uid in
            guard let self else { return false }
            return self.coreAudio.setDefaultInputDevice(uid: uid)
        }
    )
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var callAppPollTimer: Timer?
    private let callAppInspectionQueue = DispatchQueue(label: "app.toolbox.call-app-ax-poll", qos: .utility)
    private var lastCallRelayUptime: TimeInterval = 0
    private var consecutiveNilCallAppPolls: Int = 0
    private var pendingSmartUnmuteOnly: Bool = false
    private var simulatedTypingBurstTask: Task<Void, Never>?
    private var reportedPinnedBluetoothMicApps: Set<String> = []
    #if DEBUG
    private var pinnedBluetoothMicAppsDiagnosticOverride: [String]?
    #endif

    init() {
        coreAudio.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.refreshAudioDevices()
            self.bluetoothMicLock.handleDevicesChanged()
            self.refreshPinnedBluetoothMicApps()
        }
        coreAudio.onDefaultInputChanged = { [weak self] _ in
            guard let self else { return }
            self.restoreTypingMuteIfNeeded(forceUnmuteCurrentDevice: true)
            self.refreshAudioDevices()
            self.bluetoothMicLock.handleDefaultInputChanged()
            self.refreshPinnedBluetoothMicApps()
        }
        coreAudio.onDefaultOutputChanged = { [weak self] _ in
            self?.refreshAudioDevices()
        }
        coreAudio.onInputMuteOrVolumeChanged = { [weak self] in
            self?.refreshMuteStateFromHardware()
        }
        coreAudio.onInputStreamActivityChanged = { [weak self] in
            self?.refreshMicStreamActivity()
        }
        coreAudio.onCameraStateChanged = { [weak self] in
            self?.refreshCameraStatus()
        }

        bluetoothMicLock.onStateChanged = { [weak self] in
            guard let self else { return }
            if self.bluetoothMicLockState != self.bluetoothMicLock.state {
                self.bluetoothMicLockState = self.bluetoothMicLock.state
            }
        }
        bluetoothMicLock.onReverted = { [weak self] from, to in
            guard let self else { return }
            self.handleBluetoothMicReverted(from: from, to: to)
        }
        bluetoothMicLock.onLoopBreakerTripped = { [weak self] device, resumeAt in
            guard let self else { return }
            self.handleBluetoothMicLockThrottled(for: device, resumeAt: resumeAt)
        }

        callRemapper.onRemapTriggered = { [weak self] action, mapping, targetShortcut, deliveredToCallApp, preRelayAppMuted in
            Task { @MainActor in
                self?.handleCallShortcutRelayed(
                    action: action,
                    mapping: mapping,
                    targetShortcut: targetShortcut,
                    deliveredToCallApp: deliveredToCallApp,
                    preRelayAppMuted: preRelayAppMuted
                )
            }
        }
        callRemapper.onGlobalActionTriggered = { [weak self] action, passedThrough in
            Task { @MainActor in
                self?.handleGlobalKeybindWithoutRelay(action: action, passedThrough: passedThrough)
            }
        }
        callRemapper.onNativeAppMicShortcutPressed = { [weak self] mapping, pid in
            Task { @MainActor in
                self?.handleNativeAppMicShortcutPressed(mapping: mapping, pid: pid)
            }
        }
        callRemapper.onSimulatedActionTriggered = { [weak self] action, wasConsumed in
            Task { @MainActor in
                self?.handlePhysicalKeybindDuringSimulation(action: action, wasConsumed: wasConsumed)
            }
        }

        typingGuard.onSetTypingMute = { [weak self] shouldMute in
            Task { @MainActor in
                self?.applyTypingMute(shouldMute)
            }
        }

        floatingIndicator.onToggleMute = { [weak self] in
            guard let self else { return }
            if self.developerSimulation != nil {
                self.toggleSimulatedMicFromPill()
            } else {
                self.toggleSmartMicMute()
            }
        }
        floatingIndicator.onToggleVideo = { [weak self] in
            guard let self else { return }
            if self.developerSimulation != nil {
                self.triggerSimulatedAction(.video, fallbackToDefaultIfUnbound: true, respectSimulatedAccessibility: true)
            } else {
                self.toggleCallVideo()
            }
        }
        floatingIndicator.onToggleShowVideo = { [weak self] in
            guard let self else { return }
            let next = !ConfigManager.shared.config.callControls.showVideoInFloatingIndicator
            ConfigManager.shared.config.callControls.showVideoInFloatingIndicator = next
            self.showToast(
                title: next ? "Camera status shown in floating pill" : "Camera status hidden from pill",
                symbol: next ? "video.fill" : "video.slash.fill",
                tint: next ? .green : .red
            )
        }
        floatingIndicator.onOpenSettings = { [weak self] in
            guard let self else { return }
            MainWindowController.shared.show(destination: .module(self.id))
        }
        floatingIndicator.onHidePill = { [weak self] in
            guard let self else { return }
            if self.developerSimulation != nil {
                self.developerSimulation?.pillVisibilityMode = .forceHide
                self.showToast(title: "Simulated floating pill hidden", symbol: "eye.slash", tint: .secondary, force: true)
            } else {
                ConfigManager.shared.config.callControls.showFloatingMicIndicator = false
                self.showToast(title: "Floating status pill hidden", symbol: "eye.slash", tint: .secondary)
            }
        }
        floatingIndicator.onFrameChanged = { [weak self] frame in
            self?.floatingPillFrameSnapshot = frame
        }
    }

    var inputDevices: [AudioDeviceInfo] {
        devices.filter(\.hasInput)
    }

    var outputDevices: [AudioDeviceInfo] {
        devices.filter(\.hasOutput)
    }

    var defaultInputDevice: AudioDeviceInfo? {
        inputDevices.first(where: \.isDefaultInput)
    }

    var defaultOutputDevice: AudioDeviceInfo? {
        outputDevices.first(where: \.isDefaultOutput)
    }

    func needsAccessibilityForConfiguredFeatures(_ cfg: CallControlsConfig) -> Bool {
        let hasUnifiedCallKeybind = !cfg.micShortcut.isEmpty || !cfg.videoShortcut.isEmpty
        return hasUnifiedCallKeybind || cfg.autoMuteWhileTyping
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.callControls.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.callControls.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        if !config.callControls.micShortcut.isEmpty {
            return config.callControls.micShortcut.displayString
        }
        if !config.callControls.osMuteShortcut.isEmpty {
            return config.callControls.osMuteShortcut.displayString
        }
        if !config.callControls.cycleOutputShortcut.isEmpty {
            return config.callControls.cycleOutputShortcut.displayString
        }
        return nil
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !config.callControls.enabled { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if needsAccessibilityForConfiguredFeatures(config.callControls) && !accessibilityGranted {
            return "Needs Accessibility"
        }
        if isTypingMuted { return "Typing Mute" }
        if isInputMuted { return "Mic Muted" }
        return isRunning ? "Active" : "Standby"
    }

    func start() {
        isRunning = true
        coreAudio.startObserving()
        installAppLifecycleObservers()
        refreshAudioDevices()
        refreshMicStreamActivity()
        refreshCameraStatus()
        refreshRunningApplications()
        syncSubfeatures()
    }

    func stop() {
        shutdown(preserveDeveloperSimulation: false)
    }

    private func shutdown(preserveDeveloperSimulation: Bool) {
        HotKeyManager.shared.unregister(name: osMuteHotKeyName)
        HotKeyManager.shared.unregister(name: cycleOutputHotKeyName)

        if !preserveDeveloperSimulation {
            simulatedTypingBurstTask?.cancel()
            simulatedTypingBurstTask = nil
            developerSimulation = nil
        }

        restoreTypingMuteIfNeeded(forceUnmuteCurrentDevice: true)
        typingGuard.uninstall()
        isTypingTapInstalled = false
        bluetoothMicLock.invalidate()
        bluetoothMicLockState = bluetoothMicLock.state
        pinnedBluetoothMicAppNames = []
        reportedPinnedBluetoothMicApps.removeAll()

        if developerSimulation == nil {
            callRemapper.uninstall()
            isRemapperTapInstalled = false
            floatingIndicator.hide()
        }
        coreAudio.stopObserving()
        coreAudio.clearSavedFallbackVolumes()
        removeAppLifecycleObservers()
        stopCallAppPollTimer()

        callAppMutedState = nil
        hasActiveCallAppSession = false
        consecutiveNilCallAppPolls = 0
        pendingSmartUnmuteOnly = false
        isTypingMuted = false
        isRunning = false
        updateEffectiveMuteState()
        syncCallShortcutRemapper()
        syncFloatingIndicator()
    }

    func reload(with fullConfig: ToolboxConfig) {
        let previousConfig = self.config
        self.config = fullConfig.callControls
        self.appEnabled = fullConfig.general.appEnabled

        if previousConfig.autoMuteWhileTyping && !config.autoMuteWhileTyping {
            restoreTypingMuteIfNeeded(forceUnmuteCurrentDevice: true)
        }

        if config.enabled && appEnabled {
            if !isRunning {
                start()
            } else {
                syncSubfeatures()
            }
        } else {
            shutdown(preserveDeveloperSimulation: true)
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(CallControlsSettingsView(module: self))
    }

    // MARK: - Subfeature Synchronization

    private func syncSubfeatures() {
        registerHotKeys()
        syncCallShortcutRemapper()
        syncTypingMicGuard()
        syncCallAppPollTimer()
        syncFloatingIndicator()
        syncBluetoothMicLock()
    }

    // MARK: - Bluetooth Mic Lock

    /// Keeps AirPods / Bluetooth headsets in high-quality stereo by holding the default input
    /// on a non-Bluetooth microphone whenever a call app opens the headset mic.
    private func syncBluetoothMicLock() {
        let shouldEngage = isRunning && appEnabled && config.enabled && config.preventBluetoothMicSwitch
        // configure() already schedules an evaluation when the guard engages or the fallback
        // changes, so no extra evaluateSoon() here (it would restart the 150 ms debounce on
        // every unrelated config reload).
        bluetoothMicLock.configure(
            enabled: shouldEngage,
            fallbackUID: config.bluetoothMicLockFallbackUID
        )
        if bluetoothMicLockState != bluetoothMicLock.state {
            bluetoothMicLockState = bluetoothMicLock.state
        }
        refreshPinnedBluetoothMicApps()
    }

    private func handleBluetoothMicReverted(from bluetooth: AudioDeviceInfo, to fallback: AudioDeviceInfo) {
        // Re-sync this module's mute state and the typing guard against the new default device.
        refreshAudioDevices()
        syncTypingMicGuard()
        refreshPinnedBluetoothMicApps()
        DeveloperEventLog.shared.record(
            .callControls,
            "Kept Bluetooth audio in stereo",
            detail: "\(bluetooth.name) mic -> \(fallback.name)"
        )
        if config.showToasts && config.showBluetoothMicLockToast {
            HUDToast.shared.show(
                title: "\(bluetooth.name) kept in stereo",
                subtitle: "Apps now use \(fallback.name) - not the headset mic",
                symbol: "dot.radiowaves.left.and.right",
                tint: .blue
            )
        }
        ModuleRegistry.shared.notifyChanged()
    }

    private func handleBluetoothMicLockThrottled(for device: AudioDeviceInfo, resumeAt: TimeInterval) {
        let seconds = max(1, Int((resumeAt - ProcessInfo.processInfo.systemUptime).rounded()))
        DeveloperEventLog.shared.record(
            .callControls,
            "Bluetooth mic lock paused",
            detail: "\(device.name) re-selected too often; retrying in \(seconds)s"
        )
        ModuleRegistry.shared.notifyChanged()
    }

    /// Detects apps that opened the Bluetooth microphone directly. Those apps force the headset
    /// into hands-free call mode regardless of the system default input, so the only real fix is
    /// for the user to point that app at "Same as System".
    private func refreshPinnedBluetoothMicApps() {
        #if DEBUG
        if let override = pinnedBluetoothMicAppsDiagnosticOverride {
            if pinnedBluetoothMicAppNames != override {
                pinnedBluetoothMicAppNames = override
            }
            return
        }
        #endif
        let guardEngaged = isRunning && appEnabled && config.enabled && config.preventBluetoothMicSwitch
        guard guardEngaged else {
            if !pinnedBluetoothMicAppNames.isEmpty {
                pinnedBluetoothMicAppNames = []
            }
            if !reportedPinnedBluetoothMicApps.isEmpty {
                // Re-engaging the guard must announce hijacking apps again.
                reportedPinnedBluetoothMicApps.removeAll()
            }
            return
        }

        let devices = CoreAudioController.listDevices()
        let defaultInputUID = devices.first(where: \.isDefaultInput)?.uid
        let pinnedBundleIDs = BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs(
            captures: CoreAudioController.activeInputProcessCaptures(),
            devices: devices,
            defaultInputUID: defaultInputUID
        )

        let names = pinnedBundleIDs
            .filter { !$0.isEmpty }
            .map { displayName(forBundleID: $0) }
            .reduce(into: [String]()) { unique, name in
                if !unique.contains(name) { unique.append(name) }
            }
        if pinnedBluetoothMicAppNames != names {
            pinnedBluetoothMicAppNames = names
        }

        for bundleID in pinnedBundleIDs where !reportedPinnedBluetoothMicApps.contains(bundleID) {
            reportedPinnedBluetoothMicApps.insert(bundleID)
            let appName = displayName(forBundleID: bundleID)
            DeveloperEventLog.shared.record(
                .callControls,
                "App opened the Bluetooth mic directly",
                detail: "\(appName) (\(bundleID)) - set its mic to Same as System"
            )
            showToast(
                title: "\(appName) is using the headset mic",
                subtitle: "Set its microphone to \"Same as System\" to keep stereo",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    /// Best-effort friendly name for a process bundle ID (call app presets → running app → ID).
    func displayName(forBundleID bundleID: String) -> String {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "An app" }
        let low = trimmed.lowercased()

        for mapping in config.appShortcutMappings {
            let matched = mapping.bundleIdentifiers.contains { candidate in
                let preset = candidate.lowercased()
                return low == preset || low.hasPrefix(preset + ".")
            }
            if matched {
                return mapping.appName
            }
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: trimmed).first,
           let name = app.localizedName,
           !name.isEmpty {
            return name
        }
        // Helper processes report as "com.acme.app.helper"; fall back to the owning app.
        if let parent = NSWorkspace.shared.runningApplications.first(where: { app in
            guard let appBundle = app.bundleIdentifier?.lowercased() else { return false }
            return !app.isTerminated && low.hasPrefix(appBundle + ".")
        }), let name = parent.localizedName, !name.isEmpty {
            return name
        }
        return trimmed
    }

    #if DEBUG
    /// Snapshot / self-test hook: the pinned-app warning can only be rendered on screen when a
    /// real app is hijacking a Bluetooth mic, so allow diagnostics to fake it.
    func setPinnedBluetoothMicAppsForDiagnostics(_ appNames: [String]?) {
        pinnedBluetoothMicAppsDiagnosticOverride = appNames
        pinnedBluetoothMicAppNames = appNames ?? []
        ModuleRegistry.shared.notifyChanged()
    }
    #endif

    /// One-line actionable hint for the menu bar and Settings warning.
    func pinnedBluetoothMicHint(for appName: String) -> String {
        "\(appName) opened the headset's mic itself, so Toolbox can't keep stereo. Set \(appName)'s microphone to \"Same as System\"."
    }

    /// Non-Bluetooth microphones that can serve as the mic-lock fallback.
    var bluetoothMicFallbackOptions: [AudioDeviceInfo] {
        BluetoothMicLockPolicy.fallbackCandidates(from: devices)
    }

    /// Bluetooth headsets currently connected with an input (AirPods, Beats, headsets).
    var connectedBluetoothInputs: [AudioDeviceInfo] {
        inputDevices.filter { $0.transport == .bluetooth }
    }

    var isBluetoothMicLockAvailable: Bool {
        !connectedBluetoothInputs.isEmpty && !bluetoothMicFallbackOptions.isEmpty
    }

    var isBluetoothMicLockEnabled: Bool {
        bluetoothMicLockState.isEnabled
    }

    var isBluetoothMicBypassed: Bool {
        bluetoothMicLockState.isBluetoothMicBypassed
    }

    /// Short one-line description for the menu bar row and Settings status row.
    func bluetoothMicLockStatusText(in cfg: CallControlsConfig) -> String {
        guard cfg.preventBluetoothMicSwitch else { return "Off - apps may use the headset mic" }
        guard !connectedBluetoothInputs.isEmpty else { return "No Bluetooth headset connected" }
        if let bypassed = bluetoothMicLockState.bypassedBluetoothName {
            return "Using \(bypassed)'s mic - audio is in call mode until it disconnects"
        }
        if let pinnedApp = pinnedBluetoothMicAppNames.first {
            return "\(pinnedApp) is using the headset mic - set it to Same as System"
        }
        if bluetoothMicLockState.isThrottled {
            return "Paused - an app keeps re-opening the headset mic"
        }
        if let fallback = bluetoothMicLockState.resolvedFallbackName {
            return "Stereo kept - apps use \(fallback)"
        }
        return "Stereo kept - no other microphone available yet"
    }

    /// "Allow Headset Mic" (until disconnect): arms the temporary override and, when needed,
    /// switches the default input to the headset so the user can walk away from the desk.
    func allowBluetoothMicUntilDisconnect() {
        let target = connectedBluetoothInputs.first(where: \.isDefaultInput) ?? connectedBluetoothInputs.first
        guard let target else {
            showToast(
                title: "No Bluetooth headset connected",
                symbol: "dot.radiowaves.left.and.right",
                tint: .orange,
                force: true
            )
            return
        }

        if !target.isDefaultInput {
            restoreTypingMuteIfNeeded(forceUnmuteCurrentDevice: true)
            guard coreAudio.setDefaultInputDevice(uid: target.uid) else {
                refreshAudioDevices()
                showToast(
                    title: "Could not switch to \(target.name) mic",
                    subtitle: "The microphone stayed where it was",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    force: true
                )
                return
            }
        }
        // Only arm the override once the headset mic really is the active input.
        bluetoothMicLock.armBypass(bluetoothUID: target.uid)
        refreshAudioDevices()
        refreshPinnedBluetoothMicApps()
        bluetoothMicLockState = bluetoothMicLock.state
        DeveloperEventLog.shared.record(.callControls, "Using Bluetooth headset mic until disconnect", detail: target.name)
        showToast(
            title: "Using \(target.name)'s mic",
            subtitle: "Audio drops to call quality until the headset disconnects",
            symbol: "dot.radiowaves.left.and.right",
            tint: .blue
        )
        ModuleRegistry.shared.notifyChanged()
    }

    /// Re-arms the guard immediately (clears the temporary override and reverts the mic).
    func restoreBluetoothMicLock() {
        bluetoothMicLock.clearBypass()
        let outcome = bluetoothMicLock.evaluate()
        bluetoothMicLockState = bluetoothMicLock.state
        switch outcome {
        case .reverted, .suppressedByBypass:
            break // The revert handler already logged and toasted the device switch.
        case .suppressedByLoopBreaker:
            showToast(
                title: "Mic switch paused",
                subtitle: "An app keeps re-opening the headset mic - retrying shortly",
                symbol: "pause.circle.fill",
                tint: .orange
            )
        case .suppressedByNoFallback, .revertFailed:
            showToast(
                title: "No other microphone available",
                subtitle: "The headset's mic has to be used",
                symbol: "mic.slash",
                tint: .orange,
                force: true
            )
        case .idle:
            showToast(
                title: connectedBluetoothInputs.isEmpty
                    ? "No Bluetooth headset connected"
                    : "Back to stereo",
                symbol: "waveform",
                tint: .secondary
            )
        }
        ModuleRegistry.shared.notifyChanged()
    }

    private func registerHotKeys() {
        if !config.osMuteShortcut.isEmpty {
            HotKeyManager.shared.register(name: osMuteHotKeyName, shortcut: config.osMuteShortcut) { [weak self] in
                guard let self else { return }
                if self.developerSimulation != nil {
                    self.triggerSimulatedAction(.mic, fallbackToDefaultIfUnbound: true)
                } else {
                    self.toggleHardwareMicMute()
                }
            }
        } else {
            HotKeyManager.shared.unregister(name: osMuteHotKeyName)
        }

        if !config.cycleOutputShortcut.isEmpty {
            HotKeyManager.shared.register(name: cycleOutputHotKeyName, shortcut: config.cycleOutputShortcut) { [weak self] in
                self?.cycleOutputDevice()
            }
        } else {
            HotKeyManager.shared.unregister(name: cycleOutputHotKeyName)
        }
    }

    private func syncCallShortcutRemapper() {
        if let sim = developerSimulation {
            let activeCfg = ConfigManager.shared.config.callControls
            let effectiveScope = sim.simulatedScopeOverride ?? activeCfg.overrideScope
            let wantsSimRemapper = !activeCfg.micShortcut.isEmpty
                || !activeCfg.videoShortcut.isEmpty
                || !activeCfg.osMuteShortcut.isEmpty

            callRemapper.updateConfiguration(
                micShortcut: activeCfg.micShortcut,
                videoShortcut: activeCfg.videoShortcut,
                overrideScope: effectiveScope,
                mappings: activeCfg.appShortcutMappings
            )
            callRemapper.updateSimulatedContext(
                Self.buildSimulatedContext(sim: sim, config: activeCfg)
            )

            guard wantsSimRemapper, PermissionsManager.shared.actualAccessibilityGranted else {
                callRemapper.uninstall()
                isRemapperTapInstalled = false
                return
            }

            if !callRemapper.isInstalled {
                isRemapperTapInstalled = callRemapper.install()
                if !isRemapperTapInstalled {
                    DeveloperEventLog.shared.record(.callControls, "Simulated keybind tap failed to install")
                }
            } else {
                isRemapperTapInstalled = true
            }
            return
        }

        callRemapper.updateSimulatedContext(nil)

        guard isRunning else {
            callRemapper.uninstall()
            isRemapperTapInstalled = false
            return
        }

        let wantsRemapper = (!config.micShortcut.isEmpty || !config.videoShortcut.isEmpty)
            && (config.overrideScope == .everywhere || config.appShortcutMappings.contains(where: \.enabled))

        guard wantsRemapper, PermissionsManager.shared.isAccessibilityGranted else {
            callRemapper.uninstall()
            isRemapperTapInstalled = false
            return
        }

        callRemapper.updateConfiguration(
            micShortcut: config.micShortcut,
            videoShortcut: config.videoShortcut,
            overrideScope: config.overrideScope,
            mappings: config.appShortcutMappings
        )

        if !callRemapper.isInstalled {
            isRemapperTapInstalled = callRemapper.install()
            if !isRemapperTapInstalled {
                DeveloperEventLog.shared.record(.callControls, "Call shortcut event tap failed to install")
            }
        } else {
            isRemapperTapInstalled = true
        }
    }

    private func syncTypingMicGuard() {
        guard config.autoMuteWhileTyping, PermissionsManager.shared.isAccessibilityGranted else {
            restoreTypingMuteIfNeeded(forceUnmuteCurrentDevice: true)
            typingGuard.uninstall()
            isTypingTapInstalled = false
            return
        }

        let ignored = [
            config.micShortcut,
            config.videoShortcut,
            config.osMuteShortcut,
            config.cycleOutputShortcut
        ].filter { !$0.isEmpty }

        let manualMute = isTypingMuted ? false : isInputMuted
        typingGuard.configure(
            unmuteDelayMs: config.typingUnmuteDelayMs,
            ignoredShortcuts: ignored,
            isManuallyMuted: manualMute
        )

        if !typingGuard.isInstalled {
            isTypingTapInstalled = typingGuard.install()
            if !isTypingTapInstalled {
                DeveloperEventLog.shared.record(.callControls, "Typing mic guard event tap failed to install")
            }
        } else {
            isTypingTapInstalled = true
        }
    }

    var isFloatingPillVisible: Bool {
        floatingIndicator.isVisible
    }

    var floatingPillFrame: NSRect? {
        floatingIndicator.currentFrame
    }

    var hasCustomFloatingPillPosition: Bool {
        floatingIndicator.hasCustomPosition
    }

    func applyDeveloperSimulationPreset(_ preset: CallSimulationState.Preset) {
        simulatedTypingBurstTask?.cancel()
        simulatedTypingBurstTask = nil
        developerSimulation = .preset(preset)
        DeveloperEventLog.shared.record(.callControls, "Started call simulation preset", detail: preset.label)
    }

    func applyDeveloperSimulation(for mapping: CallAppShortcutMapping) {
        simulatedTypingBurstTask?.cancel()
        simulatedTypingBurstTask = nil
        let title = (mapping.requiredWindowTitleSubstring?.isEmpty == false)
            ? "\(mapping.requiredWindowTitleSubstring!) - Call"
            : mapping.appName
        developerSimulation = CallSimulationState(
            targetAppID: mapping.id,
            appPlacement: .frontmost,
            customWindowTitle: title,
            isMicStreamActive: true,
            isMuted: false,
            isTypingMuted: false,
            isCameraActive: !mapping.videoShortcut.isEmpty
        )
        DeveloperEventLog.shared.record(.callControls, "Started call simulation for app", detail: mapping.appName)
    }

    func clearDeveloperSimulation() {
        guard developerSimulation != nil || lastSimulationOutcome != nil else { return }
        simulatedTypingBurstTask?.cancel()
        simulatedTypingBurstTask = nil
        developerSimulation = nil
        lastSimulationOutcome = nil
    }

    func simulatedTargetMapping(in cfg: CallControlsConfig) -> CallAppShortcutMapping? {
        guard let sim = developerSimulation, sim.targetAppID != "none" else { return nil }
        return cfg.appShortcutMappings.first(where: { $0.id == sim.targetAppID })
    }

    static func buildSimulatedContext(
        sim: CallSimulationState,
        config activeConfig: CallControlsConfig
    ) -> SimulatedCallContext {
        var frontBundleID = "com.apple.Xcode"
        var frontPID: pid_t = 9001
        var frontTitle = "Toolbox — Developer Simulation"
        var backgroundApps: [RunningCallAppSnapshot] = []

        if sim.targetAppID != "none",
           let target = activeConfig.appShortcutMappings.first(where: { $0.id == sim.targetAppID }),
           let firstBundle = target.bundleIdentifiers.first {
            let titles: [String] = {
                if !sim.customWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return [sim.customWindowTitle]
                }
                if let required = target.requiredWindowTitleSubstring, !required.isEmpty {
                    return ["\(required) - Call"]
                }
                return [target.appName]
            }()

            if sim.appPlacement == .frontmost {
                frontBundleID = firstBundle
                frontPID = 8401
                frontTitle = titles.first ?? target.appName
            } else {
                backgroundApps.append(
                    RunningCallAppSnapshot(
                        bundleIdentifier: firstBundle,
                        pid: 8401,
                        windowTitles: titles
                    )
                )
            }
        }

        return SimulatedCallContext(
            frontmostBundleID: frontBundleID,
            frontmostPID: frontPID,
            frontmostWindowTitle: frontTitle,
            runningApps: backgroundApps,
            simulateAccessibilityGranted: sim.simulateAccessibilityGranted,
            osMuteShortcut: activeConfig.osMuteShortcut
        )
    }

    func simulatedRoutingDecision(
        for action: CallActionKind,
        using cfg: CallControlsConfig? = nil,
        fallbackToDefaultIfUnbound: Bool = false
    ) -> CallRemapDecision {
        let activeConfig = cfg ?? ConfigManager.shared.config.callControls
        guard let sim = developerSimulation else { return .passThrough }
        let effectiveScope = sim.simulatedScopeOverride ?? activeConfig.overrideScope
        let shortcut = (action == .mic) ? activeConfig.micShortcut : activeConfig.videoShortcut
        let effectiveShortcut: ShortcutSpec = {
            if !shortcut.isEmpty { return shortcut }
            guard fallbackToDefaultIfUnbound else { return .none }
            return action == .mic ? CallControlsConfig.defaultMicShortcut : CallControlsConfig.defaultVideoShortcut
        }()
        guard let keyCode = effectiveShortcut.carbonKeyCode else { return .passThrough }

        let context = Self.buildSimulatedContext(sim: sim, config: activeConfig)
        return CallShortcutRemapper.resolveDecision(
            keyCode: UInt16(keyCode),
            modifiers: effectiveShortcut.modifiers,
            eventUserData: 0,
            micShortcut: action == .mic ? effectiveShortcut : .none,
            videoShortcut: action == .video ? effectiveShortcut : .none,
            overrideScope: effectiveScope,
            mappings: activeConfig.appShortcutMappings,
            frontmostBundleID: context.frontmostBundleID,
            frontmostPID: context.frontmostPID,
            frontmostWindowTitle: context.frontmostWindowTitle,
            runningApps: context.runningApps
        )
    }

    func toggleSimulatedMicFromPill() {
        guard var sim = developerSimulation else { return }
        simulatedTypingBurstTask?.cancel()
        simulatedTypingBurstTask = nil
        guard sim.hasInputDevice else {
            let msg = "No input microphone available"
            lastSimulationOutcome = msg
            HUDToast.shared.show(title: msg, symbol: "mic.slash", tint: .orange)
            return
        }
        sim.isTypingMuted = false
        sim.isMuted.toggle()
        developerSimulation = sim
        let label = sim.isMuted ? "Mic Muted - \(sim.inputDeviceName)" : "Mic Live - \(sim.inputDeviceName)"
        lastSimulationOutcome = "\(label) (Pill Click)"
        DeveloperEventLog.shared.record(.callControls, "Simulated Pill Mic Toggle", detail: lastSimulationOutcome)
        HUDToast.shared.show(
            title: label,
            symbol: sim.isMuted ? "mic.slash.fill" : "mic.fill",
            tint: sim.isMuted ? .red : .green
        )
    }

    func simulateTypingBurst() {
        guard var sim = developerSimulation else { return }
        guard sim.hasInputDevice else {
            lastSimulationOutcome = "Typing Burst skipped — No input microphone available"
            HUDToast.shared.show(title: "No input microphone available", symbol: "mic.slash", tint: .orange)
            return
        }
        if sim.isMuted && !sim.isTypingMuted {
            let msg = "Typing Burst skipped — mic is manually muted (manual mute takes precedence)"
            lastSimulationOutcome = msg
            DeveloperEventLog.shared.record(.callControls, "Simulated Typing Burst Skipped", detail: msg)
            HUDToast.shared.show(title: "Manual mute stays active while typing", symbol: "mic.slash.fill", tint: .red)
            return
        }

        simulatedTypingBurstTask?.cancel()
        let delayMs = CallControlsConfig.clampedTypingDelayMs(ConfigManager.shared.config.callControls.typingUnmuteDelayMs)
        sim.isTypingMuted = true
        sim.isMuted = true
        developerSimulation = sim

        let startMsg = "Typing Auto-Mute active · restores after \(delayMs) ms idle"
        lastSimulationOutcome = startMsg
        DeveloperEventLog.shared.record(.callControls, "Simulated Typing Burst Started", detail: startMsg)
        HUDToast.shared.show(title: "Typing Mute active (\(delayMs) ms restore)", symbol: "keyboard", tint: .orange)

        simulatedTypingBurstTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled, let self, var current = self.developerSimulation, current.isTypingMuted else { return }
            current.isTypingMuted = false
            current.isMuted = false
            self.developerSimulation = current
            self.simulatedTypingBurstTask = nil
            let restoredMsg = "Mic Live - \(current.inputDeviceName) (Typing Restored after \(delayMs) ms)"
            self.lastSimulationOutcome = restoredMsg
            DeveloperEventLog.shared.record(.callControls, "Simulated Typing Burst Restored", detail: restoredMsg)
            HUDToast.shared.show(title: "Mic Live - \(current.inputDeviceName)", symbol: "mic.fill", tint: .green)
        }
    }

    private func handlePhysicalKeybindDuringSimulation(action: CallActionKind, wasConsumed: Bool) {
        guard let sim = developerSimulation else { return }
        let cfg = ConfigManager.shared.config.callControls
        let effectiveScope = sim.simulatedScopeOverride ?? cfg.overrideScope
        if !wasConsumed {
            let mapped = simulatedTargetMapping(in: cfg)
            let msg: String = {
                if effectiveScope == .activeCallAppOnly && sim.appPlacement == .background, let mapped {
                    return "Keybind passed through (Background \(mapped.appName) ignored in Active App Only mode)"
                }
                if let mapped, !mapped.enabled {
                    return "Keybind passed through (\(mapped.appName) disabled in Call Apps)"
                }
                if let mapped,
                   let req = mapped.requiredWindowTitleSubstring,
                   !req.isEmpty,
                   !sim.customWindowTitle.localizedCaseInsensitiveContains(req) {
                    return "Keybind passed through (\(mapped.appName) title '\(sim.customWindowTitle)' lacks '\(req)')"
                }
                return "Keybind passed through to active app (no call target matched)"
            }()
            lastSimulationOutcome = msg
            DeveloperEventLog.shared.record(.callControls, "Simulated Keybind Pass-Through", detail: msg)
            HUDToast.shared.show(title: msg, symbol: "arrow.uturn.right.circle", tint: .secondary)
            return
        }
        triggerSimulatedAction(action, fallbackToDefaultIfUnbound: false, respectSimulatedAccessibility: true)
    }

    func triggerSimulatedAction(
        _ action: CallActionKind,
        fallbackToDefaultIfUnbound: Bool = true,
        respectSimulatedAccessibility: Bool = true
    ) {
        guard var sim = developerSimulation else { return }
        let cfg = ConfigManager.shared.config.callControls
        let effectiveScope = sim.simulatedScopeOverride ?? cfg.overrideScope
        let mapped = simulatedTargetMapping(in: cfg)
        let videoCapableSummary = Self.videoCapableAppsSummary(from: cfg.appShortcutMappings)

        if respectSimulatedAccessibility && !sim.simulateAccessibilityGranted {
            let msg = "\(action.label) blocked — Accessibility is simulated as Denied"
            lastSimulationOutcome = msg
            DeveloperEventLog.shared.record(.callControls, "Simulated \(action.label) Blocked (Accessibility)", detail: msg)
            HUDToast.shared.show(
                title: "Grant Accessibility for \(action.label.lowercased()) keybind (Simulated)",
                symbol: "lock.shield",
                tint: .orange
            )
            return
        }

        let decision = simulatedRoutingDecision(
            for: action,
            using: cfg,
            fallbackToDefaultIfUnbound: fallbackToDefaultIfUnbound
        )
        switch decision {
        case .remap(let resolvedAction, let app, _, let targetShortcut, let focusRestore):
            if resolvedAction == .mic {
                simulatedTypingBurstTask?.cancel()
                simulatedTypingBurstTask = nil
                guard sim.hasInputDevice else {
                    let msg = "No input microphone available"
                    lastSimulationOutcome = msg
                    HUDToast.shared.show(title: msg, symbol: "mic.slash", tint: .orange)
                    return
                }
                sim.isTypingMuted = false
                sim.isMuted.toggle()
                developerSimulation = sim
                let stateLabel = sim.isMuted ? "Mic Muted" : "Mic Live"
                let note = "\(stateLabel) · \(app.appName) (Sim · \(targetShortcut.displayString)\(focusRestore ? ", bg relay" : ""))"
                lastSimulationOutcome = note
                DeveloperEventLog.shared.record(.callControls, "Simulated Mic Action", detail: note)
                HUDToast.shared.show(
                    title: "\(stateLabel) · \(app.appName)",
                    symbol: sim.isMuted ? "mic.slash.fill" : "mic.fill",
                    tint: sim.isMuted ? .red : .green
                )
            } else {
                guard sim.hasCameraDevice else {
                    let msg = "No camera detected"
                    lastSimulationOutcome = msg
                    HUDToast.shared.show(title: msg, symbol: "video.slash", tint: .orange)
                    return
                }
                sim.isCameraActive.toggle()
                developerSimulation = sim
                let stateLabel = sim.isCameraActive ? "Camera On" : "Camera Off"
                let note = "\(stateLabel) · \(app.appName) (Sim -> \(targetShortcut.displayString))"
                lastSimulationOutcome = note
                DeveloperEventLog.shared.record(.callControls, "Simulated Video Action", detail: note)
                HUDToast.shared.show(
                    title: "\(stateLabel) · \(app.appName)",
                    symbol: sim.isCameraActive ? "video.fill" : "video.slash.fill",
                    tint: sim.isCameraActive ? .green : .red
                )
            }

        case .passThroughWithHardwareSync(let resolvedAction):
            if resolvedAction == .mic {
                simulatedTypingBurstTask?.cancel()
                simulatedTypingBurstTask = nil
                guard sim.hasInputDevice else {
                    let msg = "No input microphone available"
                    lastSimulationOutcome = msg
                    HUDToast.shared.show(title: msg, symbol: "mic.slash", tint: .orange)
                    return
                }
                sim.isTypingMuted = false
                sim.isMuted.toggle()
                developerSimulation = sim
                let stateLabel = sim.isMuted ? "Mic Muted" : "Mic Live"
                let appLabel = mapped?.appName ?? "Call App"
                let note = "\(stateLabel) · \(appLabel) (Same-Key Sync)"
                lastSimulationOutcome = note
                DeveloperEventLog.shared.record(.callControls, "Simulated Mic Sync", detail: note)
                HUDToast.shared.show(
                    title: "\(stateLabel) - \(sim.inputDeviceName) (Synced)",
                    symbol: sim.isMuted ? "mic.slash.fill" : "mic.fill",
                    tint: sim.isMuted ? .red : .green
                )
            } else {
                guard sim.hasCameraDevice else {
                    let msg = "No camera detected"
                    lastSimulationOutcome = msg
                    HUDToast.shared.show(title: msg, symbol: "video.slash", tint: .orange)
                    return
                }
                sim.isCameraActive.toggle()
                developerSimulation = sim
                let stateLabel = sim.isCameraActive ? "Camera On" : "Camera Off"
                let appLabel = mapped?.appName ?? "Call App"
                let note = "\(stateLabel) · \(appLabel) (Synced)"
                lastSimulationOutcome = note
                DeveloperEventLog.shared.record(.callControls, "Simulated Video Sync", detail: note)
                HUDToast.shared.show(
                    title: note,
                    symbol: sim.isCameraActive ? "video.fill" : "video.slash.fill",
                    tint: sim.isCameraActive ? .green : .red
                )
            }

        case .globalHardwareOnly(let resolvedAction):
            if resolvedAction == .mic {
                simulatedTypingBurstTask?.cancel()
                simulatedTypingBurstTask = nil
                guard sim.hasInputDevice else {
                    let msg = "No input microphone available"
                    lastSimulationOutcome = msg
                    HUDToast.shared.show(title: msg, symbol: "mic.slash", tint: .orange)
                    return
                }
                sim.isTypingMuted = false
                sim.isMuted.toggle()
                developerSimulation = sim
                let label = sim.isMuted ? "Mic Muted - \(sim.inputDeviceName)" : "Mic Live - \(sim.inputDeviceName)"
                let suffix = (mapped != nil && mapped?.enabled == true) ? "" : " (No active call app)"
                lastSimulationOutcome = label + suffix
                DeveloperEventLog.shared.record(.callControls, "Simulated Global Mic", detail: lastSimulationOutcome)
                HUDToast.shared.show(title: label, symbol: sim.isMuted ? "mic.slash.fill" : "mic.fill", tint: sim.isMuted ? .red : .green)
            } else {
                let unsupported = (mapped?.videoShortcut.isEmpty == true) ? mapped?.appName : nil
                let bgCapable = (effectiveScope == .activeCallAppOnly && mapped != nil && !(mapped!.videoShortcut.isEmpty) && sim.appPlacement == .background) ? mapped?.appName : nil
                let msg = Self.videoUnavailableMessage(
                    frontUnsupportedAppName: sim.appPlacement == .frontmost ? unsupported : nil,
                    anyUnsupportedAppName: unsupported,
                    backgroundCapableAppName: bgCapable,
                    overrideScope: effectiveScope,
                    videoCapableSummary: videoCapableSummary
                )
                lastSimulationOutcome = msg
                DeveloperEventLog.shared.record(.callControls, "Simulated Video Blocked", detail: msg)
                HUDToast.shared.show(title: msg, symbol: "video.slash", tint: .orange)
            }

        case .passThrough:
            let msg: String = {
                if effectiveScope == .activeCallAppOnly && sim.appPlacement == .background, let mapped {
                    return "Passed through (Background \(mapped.appName) ignored in Active App Only mode)"
                }
                if let mapped, !mapped.enabled {
                    return "Passed through (\(mapped.appName) is disabled in Call Apps)"
                }
                if let mapped,
                   let req = mapped.requiredWindowTitleSubstring,
                   !req.isEmpty,
                   !sim.customWindowTitle.localizedCaseInsensitiveContains(req) {
                    return "Passed through (\(mapped.appName) tab '\(sim.customWindowTitle)' does not match '\(req)')"
                }
                return "Passed through to active app (no call target matched)"
            }()
            lastSimulationOutcome = msg
            DeveloperEventLog.shared.record(.callControls, "Simulated Keybind Pass-Through", detail: msg)
            HUDToast.shared.show(title: msg, symbol: "arrow.uturn.right.circle", tint: .secondary)
        }
    }

    private struct FloatingIndicatorPayload {
        let isMuted: Bool
        let isTypingMuted: Bool
        let inputDeviceName: String
        let hasInputDevice: Bool
        let showVideoStatus: Bool
        let isCameraActive: Bool
        let cameraDeviceName: String?
        let hasCameraDevice: Bool
        let canToggleVideo: Bool
        let videoTargetAppName: String?
        let videoUnavailableAppName: String?
        let videoCapableSummary: String
    }

    private func buildFloatingIndicatorPayload() -> FloatingIndicatorPayload {
        if let sim = developerSimulation {
            let cfg = ConfigManager.shared.config.callControls
            let effectiveScope = sim.simulatedScopeOverride ?? cfg.overrideScope
            let mapped = simulatedTargetMapping(in: cfg)
            let titleMatches: Bool = {
                guard let mapped else { return true }
                guard let req = mapped.requiredWindowTitleSubstring, !req.isEmpty else { return true }
                return sim.customWindowTitle.localizedCaseInsensitiveContains(req)
            }()
            let canToggleVideo: Bool = {
                guard sim.simulateAccessibilityGranted,
                      sim.hasCameraDevice,
                      let mapped,
                      mapped.enabled,
                      titleMatches,
                      !mapped.videoShortcut.isEmpty else {
                    return false
                }
                return effectiveScope != .activeCallAppOnly || sim.appPlacement == .frontmost
            }()
            return FloatingIndicatorPayload(
                isMuted: sim.isMuted,
                isTypingMuted: sim.isTypingMuted,
                inputDeviceName: sim.inputDeviceName,
                hasInputDevice: sim.hasInputDevice,
                showVideoStatus: cfg.showVideoInFloatingIndicator,
                isCameraActive: sim.isCameraActive,
                cameraDeviceName: sim.hasCameraDevice ? sim.cameraDeviceName : nil,
                hasCameraDevice: sim.hasCameraDevice,
                canToggleVideo: canToggleVideo,
                videoTargetAppName: canToggleVideo ? mapped?.appName : nil,
                videoUnavailableAppName: canToggleVideo ? nil : (mapped?.videoShortcut.isEmpty == true ? mapped?.appName : nil),
                videoCapableSummary: Self.videoCapableAppsSummary(from: cfg.appShortcutMappings)
            )
        }

        let inputName = defaultInputDevice?.name ?? "No Microphone"
        let videoTarget = currentTargetSummary(for: .video)
        let canToggleVideo = PermissionsManager.shared.isAccessibilityGranted && videoTarget != nil
        return FloatingIndicatorPayload(
            isMuted: isInputMuted,
            isTypingMuted: isTypingMuted,
            inputDeviceName: inputName,
            hasInputDevice: defaultInputDevice != nil,
            showVideoStatus: config.showVideoInFloatingIndicator,
            isCameraActive: isCameraActive,
            cameraDeviceName: activeCameraName,
            hasCameraDevice: hasCameraDevice,
            canToggleVideo: canToggleVideo,
            videoTargetAppName: videoTarget?.appName,
            videoUnavailableAppName: canToggleVideo ? nil : runningVideoUnsupportedApp()?.appName,
            videoCapableSummary: Self.videoCapableAppsSummary(from: config.appShortcutMappings)
        )
    }

    func populateFloatingState(_ targetState: FloatingMicIndicatorState) {
        let p = buildFloatingIndicatorPayload()
        targetState.isMuted = p.isMuted
        targetState.isTypingMuted = p.isTypingMuted
        targetState.inputDeviceName = p.inputDeviceName
        targetState.hasInputDevice = p.hasInputDevice
        targetState.showVideoStatus = p.showVideoStatus
        targetState.isCameraActive = p.isCameraActive
        targetState.cameraDeviceName = p.cameraDeviceName
        targetState.hasCameraDevice = p.hasCameraDevice
        targetState.canToggleVideo = p.canToggleVideo
        targetState.videoTargetAppName = p.videoTargetAppName
        targetState.videoUnavailableAppName = p.videoUnavailableAppName
        targetState.videoCapableSummary = p.videoCapableSummary
    }

    private func syncFloatingIndicator() {
        let p = buildFloatingIndicatorPayload()
        floatingIndicator.update(
            isMuted: p.isMuted,
            isTypingMuted: p.isTypingMuted,
            inputDeviceName: p.inputDeviceName,
            hasInputDevice: p.hasInputDevice,
            showVideoStatus: p.showVideoStatus,
            isCameraActive: p.isCameraActive,
            cameraDeviceName: p.cameraDeviceName,
            hasCameraDevice: p.hasCameraDevice,
            canToggleVideo: p.canToggleVideo,
            videoTargetAppName: p.videoTargetAppName,
            videoUnavailableAppName: p.videoUnavailableAppName,
            videoCapableSummary: p.videoCapableSummary
        )

        if let sim = developerSimulation {
            let cfg = ConfigManager.shared.config.callControls
            let simCallActive = sim.isMicStreamActive || sim.isCameraActive
            let shouldShowSimPill: Bool = {
                switch sim.pillVisibilityMode {
                case .forceShow: return true
                case .forceHide: return false
                case .autoDuringCall:
                    return cfg.showFloatingMicIndicator && (!cfg.showFloatingPillOnlyDuringCalls || simCallActive)
                }
            }()
            if shouldShowSimPill {
                floatingIndicator.show()
            } else {
                floatingIndicator.hide()
            }
            return
        }

        let shouldShowPill = isRunning
            && config.showFloatingMicIndicator
            && (!config.showFloatingPillOnlyDuringCalls || isCallOrMediaActive)
        if shouldShowPill {
            floatingIndicator.show()
        } else {
            floatingIndicator.hide()
        }
    }

    // MARK: - User Actions (Hardware Mic Mute, Device Switching, Call Relay)

    static func resolveCallOrMediaActive(
        isCameraActive: Bool,
        isMicStreamActive: Bool,
        hasActiveCallAppSession: Bool
    ) -> Bool {
        isCameraActive || isMicStreamActive || hasActiveCallAppSession
    }

    var isCallOrMediaActive: Bool {
        if let sim = developerSimulation {
            return sim.isMicStreamActive || sim.isCameraActive
        }
        return Self.resolveCallOrMediaActive(
            isCameraActive: isCameraActive,
            isMicStreamActive: isMicStreamActive,
            hasActiveCallAppSession: hasActiveCallAppSession
        )
    }

    func refreshMicStreamActivity() {
        let active = CoreAudioController.isDefaultInputRunningSomewhere()
        if isMicStreamActive != active {
            isMicStreamActive = active
        }
        refreshPinnedBluetoothMicApps()
        if !active && !isCameraActive && !hasActiveCallAppSession && callAppMutedState != nil {
            callAppMutedState = nil
        }
        callRemapper.updateCallActivity(isCallOrMediaActive)
        if active {
            callRemapper.refreshContextIfInstalled()
        }
        syncCallAppPollTimer()
        updateEffectiveMuteState()
    }

    func refreshCameraStatus() {
        let cam = CoreAudioController.currentCameraStatus()
        hasCameraDevice = cam.hasCamera
        isCameraActive = cam.isCameraActive
        activeCameraName = cam.activeCameraName
        if !isCameraActive && !isMicStreamActive && !hasActiveCallAppSession && callAppMutedState != nil {
            callAppMutedState = nil
        }
        callRemapper.updateCallActivity(isCallOrMediaActive)
        syncCallAppPollTimer()
        syncFloatingIndicator()
    }

    func toggleFloatingPillVisibility() {
        let next = !ConfigManager.shared.config.callControls.showFloatingMicIndicator
        ConfigManager.shared.config.callControls.showFloatingMicIndicator = next
        if next && ConfigManager.shared.config.callControls.showFloatingPillOnlyDuringCalls && !isCallOrMediaActive {
            showToast(
                title: "Floating pill enabled (appears when a call starts)",
                symbol: "capsule.portrait.tophalf.filled",
                tint: .blue,
                force: true
            )
        } else {
            showToast(
                title: next ? "Floating status pill shown" : "Floating status pill hidden",
                symbol: next ? "capsule.inset.filled" : "eye.slash",
                tint: .secondary
            )
        }
    }

    func resetFloatingPillPosition() {
        floatingIndicator.resetToDefaultPosition()
        showToast(title: "Floating pill reset to top-right", symbol: "arrow.up.right.square", tint: .secondary)
    }

    func moveMicKeybindToGlobalOSMute() {
        let current = ConfigManager.shared.config.callControls.micShortcut
        guard !current.isEmpty else { return }
        ConfigManager.shared.config.callControls.osMuteShortcut = current
        ConfigManager.shared.config.callControls.micShortcut = .none
        showToast(
            title: "Moved \(current.displayString) to Global Mic Mute",
            symbol: "mic.fill",
            tint: .green,
            force: true
        )
    }

    func currentTargetSummary(for action: CallActionKind) -> (appName: String, pid: pid_t?, shortcut: ShortcutSpec)? {
        if let summary = callRemapper.currentTargetSummary(for: action) {
            return summary
        }
        // Fallback summary before/without tap install so UI still accurately reflects what would match.
        let front = NSWorkspace.shared.frontmostApplication
        let enabledMappings = config.appShortcutMappings.filter(\.enabled)
        let frontTitle = CallShortcutRemapper.frontmostWindowTitleIfNeeded(
            frontPID: front?.processIdentifier,
            frontBundle: front?.bundleIdentifier,
            enabledMappings: enabledMappings
        )
        let runningApps: [(bundleID: String, pid: pid_t)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let bundleID = app.bundleIdentifier else { return nil }
            return (bundleID, app.processIdentifier)
        }
        let snapshots = CallShortcutRemapper.buildRunningCallAppSnapshots(
            runningApps: runningApps,
            enabledMappings: enabledMappings,
            frontmostPID: front?.processIdentifier,
            mruOrder: [:],
            isCallActivityActive: isCallOrMediaActive,
            probeAX: false
        )
        guard let target = CallShortcutRemapper.resolveTargetPreview(
            action: action,
            overrideScope: config.overrideScope,
            mappings: config.appShortcutMappings,
            frontmostBundleID: front?.bundleIdentifier,
            frontmostPID: front?.processIdentifier,
            frontmostWindowTitle: frontTitle,
            runningApps: snapshots,
            isCallActivityActive: isCallOrMediaActive
        ) else {
            return nil
        }
        return (target.app.appName, target.pid, target.shortcut)
    }

    private func mappingForTargetAppName(_ appName: String) -> CallAppShortcutMapping? {
        config.appShortcutMappings.first(where: { $0.appName == appName })
    }

    func targetReadinessNote(for action: CallActionKind) -> (appName: String, isMenuReady: Bool?)? {
        guard let summary = currentTargetSummary(for: action) else { return nil }
        guard let pid = summary.pid, PermissionsManager.shared.isAccessibilityGranted else {
            return (summary.appName, nil)
        }
        if let mapping = mappingForTargetAppName(summary.appName),
           CallShortcutRemapper.isBrowserMapping(mapping) {
            return (summary.appName, true)
        }
        switch CallShortcutRemapper.inspectOrPressMenuItem(
            pid: pid,
            shortcut: summary.shortcut,
            action: action,
            performPress: false
        ) {
        case .pressed:
            return (summary.appName, true)
        case .menuItemDisabled:
            return (summary.appName, false)
        case .notFound:
            return (summary.appName, nil)
        }
    }

    func runningVideoUnsupportedApp(frontmostOnly: Bool = false) -> CallAppShortcutMapping? {
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontBundle,
           let frontUnsupported = config.appShortcutMappings.first(where: {
               $0.enabled && $0.videoShortcut.isEmpty && $0.matches(bundleID: frontBundle)
           }) {
            return frontUnsupported
        }
        guard !frontmostOnly else { return nil }
        let activeInputBundles = CoreAudioController.activeInputProcessBundleIDs()
        if let activeUnsupported = config.appShortcutMappings.first(where: { mapping in
            mapping.enabled
                && mapping.videoShortcut.isEmpty
                && mapping.bundleIdentifiers.contains {
                    CoreAudioController.bundleID($0, matchesActiveInputProcessBundleIDs: activeInputBundles)
                }
        }) {
            return activeUnsupported
        }
        return config.appShortcutMappings.first { mapping in
            mapping.enabled && mapping.videoShortcut.isEmpty && isAppRunning(for: mapping)
        }
    }

    private func runningVideoCapableApp() -> CallAppShortcutMapping? {
        config.appShortcutMappings.first { mapping in
            mapping.enabled && !mapping.videoShortcut.isEmpty && isAppRunning(for: mapping)
        }
    }

    static func shortCallAppName(_ appName: String) -> String {
        switch appName {
        case "Microsoft Teams": return "Teams"
        case "Google Meet (Browsers)": return "Meet"
        default: return appName
        }
    }

    static func formattedAppList(_ names: [String]) -> String {
        switch names.count {
        case 0: return "a supported call app"
        case 1: return names[0]
        case 2: return "\(names[0]) or \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head), or \(names[names.count - 1])"
        }
    }

    static func videoCapableAppsSummary(from mappings: [CallAppShortcutMapping]) -> String {
        let names = mappings
            .filter { $0.enabled && !$0.videoShortcut.isEmpty }
            .map { shortCallAppName($0.appName) }
        return formattedAppList(names)
    }

    static func videoUnavailableMessage(
        frontUnsupportedAppName: String?,
        anyUnsupportedAppName: String?,
        backgroundCapableAppName: String?,
        overrideScope: CallOverrideScope,
        videoCapableSummary: String
    ) -> String {
        if let frontUnsupportedAppName {
            return "\(frontUnsupportedAppName) doesn't allow video shortcuts (macOS has no OS camera mute)"
        }
        if overrideScope == .activeCallAppOnly, let backgroundCapableAppName {
            return "Focus \(backgroundCapableAppName) or switch scope to Everywhere to toggle camera"
        }
        if let anyUnsupportedAppName {
            return "\(anyUnsupportedAppName) doesn't allow video shortcuts (macOS has no OS camera mute)"
        }
        return "Open \(videoCapableSummary) to toggle camera (macOS has no OS camera mute)"
    }

    private func showVideoUnavailableToast() {
        let message = Self.videoUnavailableMessage(
            frontUnsupportedAppName: runningVideoUnsupportedApp(frontmostOnly: true)?.appName,
            anyUnsupportedAppName: runningVideoUnsupportedApp()?.appName,
            backgroundCapableAppName: runningVideoCapableApp()?.appName,
            overrideScope: config.overrideScope,
            videoCapableSummary: Self.videoCapableAppsSummary(from: config.appShortcutMappings)
        )
        showToast(title: message, symbol: "video.slash", tint: .orange, force: true)
    }

    func toggleCallVideo() {
        guard PermissionsManager.shared.isAccessibilityGranted else {
            showToast(title: "Grant Accessibility to toggle video in call apps", symbol: "lock.shield", tint: .orange, force: true)
            PermissionsManager.shared.promptAndOpenSettings()
            return
        }
        let sent = callRemapper.triggerManualAction(
            .video,
            mappings: config.appShortcutMappings,
            overrideScope: config.overrideScope
        )
        if !sent {
            showVideoUnavailableToast()
        }
    }

    func triggerUnifiedActionFromHyperKey(_ action: CallActionKind) {
        switch action {
        case .mic:
            if developerSimulation != nil {
                triggerSimulatedAction(.mic, fallbackToDefaultIfUnbound: true, respectSimulatedAccessibility: true)
            } else {
                toggleSmartMicMute()
            }
        case .video:
            if developerSimulation != nil {
                triggerSimulatedAction(.video, fallbackToDefaultIfUnbound: true, respectSimulatedAccessibility: true)
            } else {
                toggleCallVideo()
            }
        }
    }

    func refreshAudioDevices() {
        let updated = CoreAudioController.listDevices()
        if devices != updated {
            devices = updated
        }
        hardwareInputMuted = coreAudio.currentInputMuteState()
        updateEffectiveMuteState()
    }

    private func refreshMuteStateFromHardware() {
        let hardwareMuted = coreAudio.currentInputMuteState()
        hardwareInputMuted = hardwareMuted
        if isTypingMuted && !hardwareMuted {
            // External app or hardware button unmuted while typing-muted; clear transient flag.
            isTypingMuted = false
        }
        let updated = CoreAudioController.listDevices()
        if devices != updated {
            devices = updated
        }
        updateEffectiveMuteState()
    }

    static func resolveEffectiveMuteState(
        isTypingMuted: Bool,
        hardwareMuted: Bool,
        callAppMuted: Bool?
    ) -> Bool {
        if isTypingMuted { return true }
        return hardwareMuted || (callAppMuted ?? false)
    }

    private func updateEffectiveMuteState() {
        let effective = Self.resolveEffectiveMuteState(
            isTypingMuted: isTypingMuted,
            hardwareMuted: hardwareInputMuted,
            callAppMuted: callAppMutedState
        )
        if isInputMuted != effective {
            isInputMuted = effective
        }
        if !isTypingMuted {
            typingGuard.syncManualMuteState(effective)
        }
        syncFloatingIndicator()
    }

    func toggleHardwareMicMute() {
        setHardwareMicMuted(!hardwareInputMuted, announceToast: true)
    }

    /// Context-aware mic toggle used by the Floating Pill and Menu Bar button:
    /// reads the live app mute status first so hardware and in-app mute stay aligned.
    func toggleSmartMicMute() {
        guard PermissionsManager.shared.isAccessibilityGranted,
              let target = currentTargetSummary(for: .mic),
              let pid = target.pid else {
            toggleHardwareMicMute()
            return
        }

        let requiredTitle = mappingForTargetAppName(target.appName)?.requiredWindowTitleSubstring
        callAppInspectionQueue.async { [weak self] in
            let inspected = CallShortcutRemapper.inspectCallAppState(
                pid: pid,
                requiredWindowTitleSubstring: requiredTitle
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                if inspected.hasActiveControl {
                    self.hasActiveCallAppSession = true
                    self.consecutiveNilCallAppPolls = 0
                }
                if !self.isCallOrMediaActive && !inspected.hasActiveControl {
                    self.toggleHardwareMicMute()
                    return
                }
                if let freshObserved = inspected.isMuted {
                    self.callAppMutedState = freshObserved
                    self.updateEffectiveMuteState()
                }
                self.performSmartMicToggle(targetAppName: target.appName)
            }
        }
    }

    private func performSmartMicToggle(targetAppName: String) {
        if isInputMuted {
            // User wants to UNMUTE. Clear any leftover hardware mute first, and relay to the call app
            // if the call app itself is muted (or its state could not be read yet).
            let hadHardwareMute = hardwareInputMuted
            if hadHardwareMute {
                _ = setHardwareMicMuted(false, announceToast: false)
            }
            if callAppMutedState == true || !hadHardwareMute || callAppMutedState == nil {
                pendingSmartUnmuteOnly = hadHardwareMute
                let sent = callRemapper.triggerManualAction(
                    .mic,
                    mappings: config.appShortcutMappings,
                    overrideScope: config.overrideScope,
                    isCallActivityActive: isCallOrMediaActive
                )
                if !sent {
                    pendingSmartUnmuteOnly = false
                    if hadHardwareMute {
                        let micName = defaultInputDevice?.name ?? "Microphone"
                        showToast(title: "Mic Live - \(micName)", symbol: "mic.fill", tint: .green)
                    }
                }
            } else {
                let micName = defaultInputDevice?.name ?? "Microphone"
                showToast(title: "Mic Live · \(targetAppName) (\(micName))", symbol: "mic.fill", tint: .green)
            }
        } else {
            // User wants to MUTE.
            pendingSmartUnmuteOnly = false
            let sent = callRemapper.triggerManualAction(
                .mic,
                mappings: config.appShortcutMappings,
                overrideScope: config.overrideScope,
                isCallActivityActive: isCallOrMediaActive
            )
            if !sent {
                _ = setHardwareMicMuted(true, announceToast: true)
            }
        }
    }

    @discardableResult
    func setHardwareMicMuted(_ muted: Bool, announceToast: Bool = true) -> Bool {
        guard defaultInputDevice != nil else {
            showToast(title: "No input microphone available", symbol: "mic.slash", tint: .orange, force: true)
            return false
        }

        // Manual mute/unmute always takes precedence over typing guard.
        isTypingMuted = false
        typingGuard.syncManualMuteState(muted)

        let ok = coreAudio.setDefaultInputMuted(muted)
        refreshAudioDevices()

        guard ok else {
            showToast(title: "Could not change mic mute", symbol: "exclamationmark.triangle.fill", tint: .orange, force: true)
            return false
        }

        let micName = defaultInputDevice?.name ?? "Microphone"
        DeveloperEventLog.shared.record(
            .callControls,
            muted ? "Hardware mic muted" : "Hardware mic unmuted",
            detail: micName
        )

        if announceToast {
            showToast(
                title: muted ? "Mic Muted - \(micName)" : "Mic Live - \(micName)",
                symbol: muted ? "mic.slash.fill" : "mic.fill",
                tint: muted ? .red : .green
            )
        }
        ModuleRegistry.shared.notifyChanged()
        return true
    }

    @discardableResult
    func selectOutputDevice(_ device: AudioDeviceInfo) -> Bool {
        guard device.hasOutput else { return false }
        let ok = coreAudio.setDefaultOutputDevice(uid: device.uid)
        refreshAudioDevices()
        if ok {
            DeveloperEventLog.shared.record(.callControls, "Switched output device", detail: device.name)
            showToast(
                title: "Output -> \(device.name)",
                symbol: device.transport.symbolName(isInput: false),
                tint: .blue
            )
        } else {
            showToast(title: "Could not switch output device", symbol: "exclamationmark.triangle.fill", tint: .orange, force: true)
        }
        return ok
    }

    @discardableResult
    func selectInputDevice(_ device: AudioDeviceInfo) -> Bool {
        guard device.hasInput else { return false }
        restoreTypingMuteIfNeeded(forceUnmuteCurrentDevice: true)
        let ok = coreAudio.setDefaultInputDevice(uid: device.uid)
        // Reconcile the temporary override with the device the user actually landed on: an explicit
        // Bluetooth pick must win until the headset disconnects, while picking a wired mic is an
        // explicit "back to stereo" that drops the bypass. A failed switch changes nothing.
        switch BluetoothMicLockPolicy.bypassActionAfterManualInputSelection(
            selectedUID: device.uid,
            selectedIsBluetooth: device.transport == .bluetooth,
            switchSucceeded: ok,
            guardEnabled: config.preventBluetoothMicSwitch,
            currentlyBypassed: bluetoothMicLock.bypassedUID != nil
        ) {
        case .arm(let uid):
            bluetoothMicLock.armBypass(bluetoothUID: uid)
        case .clear:
            bluetoothMicLock.clearBypass()
        case .unchanged:
            break
        }
        refreshAudioDevices()
        refreshPinnedBluetoothMicApps()
        if bluetoothMicLockState != bluetoothMicLock.state {
            bluetoothMicLockState = bluetoothMicLock.state
        }
        if ok {
            DeveloperEventLog.shared.record(.callControls, "Switched input device", detail: device.name)
            showToast(
                title: "Input -> \(device.name)",
                symbol: "mic.circle.fill",
                tint: .green
            )
        } else {
            showToast(title: "Could not switch input device", symbol: "exclamationmark.triangle.fill", tint: .orange, force: true)
        }
        return ok
    }

    func cycleOutputDevice() {
        let availableOutputs = outputDevices
        guard availableOutputs.count >= 2 else {
            showToast(
                title: availableOutputs.isEmpty ? "No output devices found" : "Only 1 output device connected",
                symbol: "speaker.slash",
                tint: .orange,
                force: true
            )
            return
        }

        let favoriteUIDs = config.favoriteOutputUIDs
        let favoriteOutputs = favoriteUIDs.compactMap { uid in
            availableOutputs.first(where: { $0.uid == uid })
        }

        let pool: [AudioDeviceInfo]
        let hintSuffix: String
        if favoriteOutputs.count >= 2 {
            pool = favoriteOutputs
            hintSuffix = ""
        } else if favoriteOutputs.count == 1,
                  let fav = favoriteOutputs.first,
                  defaultOutputDevice?.uid == fav.uid {
            showToast(title: "Star 2+ output devices to cycle", symbol: "star.circle", tint: .orange, force: true)
            return
        } else if favoriteOutputs.count == 1, let fav = favoriteOutputs.first {
            let ok = coreAudio.setDefaultOutputDevice(uid: fav.uid)
            refreshAudioDevices()
            if ok {
                DeveloperEventLog.shared.record(.callControls, "Switched to favorite output", detail: fav.name)
                showToast(title: "Output -> \(fav.name)", symbol: fav.transport.symbolName(isInput: false), tint: .blue)
            }
            return
        } else {
            pool = availableOutputs
            hintSuffix = " (star favorites to narrow)"
        }

        let currentUID = defaultOutputDevice?.uid
        let nextDevice: AudioDeviceInfo
        if let currentUID, let idx = pool.firstIndex(where: { $0.uid == currentUID }) {
            nextDevice = pool[(idx + 1) % pool.count]
        } else {
            nextDevice = pool[0]
        }

        if coreAudio.setDefaultOutputDevice(uid: nextDevice.uid) {
            refreshAudioDevices()
            DeveloperEventLog.shared.record(.callControls, "Cycled output device", detail: nextDevice.name)
            showToast(
                title: "Output -> \(nextDevice.name)\(hintSuffix)",
                symbol: nextDevice.transport.symbolName(isInput: false),
                tint: .blue
            )
        }
    }

    func toggleFavoriteOutput(_ uid: String) {
        var favs = ConfigManager.shared.config.callControls.favoriteOutputUIDs
        if let idx = favs.firstIndex(of: uid) {
            favs.remove(at: idx)
        } else {
            favs.append(uid)
        }
        ConfigManager.shared.config.callControls.favoriteOutputUIDs = favs
    }

    func toggleFavoriteInput(_ uid: String) {
        var favs = ConfigManager.shared.config.callControls.favoriteInputUIDs
        if let idx = favs.firstIndex(of: uid) {
            favs.remove(at: idx)
        } else {
            favs.append(uid)
        }
        ConfigManager.shared.config.callControls.favoriteInputUIDs = favs
    }

    func isAppRunning(for mapping: CallAppShortcutMapping) -> Bool {
        mapping.bundleIdentifiers.contains { candidate in
            runningAppBundleIDs.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
    }

    func resetMappingsToDefaults() {
        ConfigManager.shared.config.callControls.appShortcutMappings = CallAppShortcutMapping.defaults
        showToast(title: "Call app presets restored", symbol: "arrow.counterclockwise", tint: .green)
    }

    // MARK: - Private Handlers

    private func handleGlobalKeybindWithoutRelay(action: CallActionKind, passedThrough: Bool) {
        switch action {
        case .mic:
            if passedThrough,
               let target = currentTargetSummary(for: .mic),
               let pid = target.pid,
               PermissionsManager.shared.isAccessibilityGranted {
                lastCallRelayUptime = ProcessInfo.processInfo.systemUptime
                callAppInspectionQueue.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                    let observedPostToggle = CallShortcutRemapper.inspectCallAppMuteState(pid: pid)
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning, self.developerSimulation == nil else { return }
                        let nextMuted = observedPostToggle ?? !self.isInputMuted
                        self.callAppMutedState = nextMuted
                        if self.config.syncHardwareMuteWithAppMicToggle, self.defaultInputDevice != nil {
                            if self.hardwareInputMuted != nextMuted {
                                _ = self.setHardwareMicMuted(nextMuted, announceToast: false)
                            } else {
                                self.updateEffectiveMuteState()
                            }
                        } else if !nextMuted && self.hardwareInputMuted && self.defaultInputDevice != nil {
                            _ = self.setHardwareMicMuted(false, announceToast: false)
                        } else {
                            self.updateEffectiveMuteState()
                        }
                        let title = "\(nextMuted ? "Mic Muted" : "Mic Live") · \(target.appName)"
                        self.lastRelayedActionLabel = "\(title) (Synced)"
                        self.showToast(
                            title: title,
                            symbol: nextMuted ? "mic.slash.fill" : "mic.fill",
                            tint: nextMuted ? .red : .green
                        )
                        self.scheduleCallAppMuteStateRefresh(pid: pid, appName: target.appName)
                    }
                }
                return
            }

            guard defaultInputDevice != nil else {
                showToast(title: "No input microphone available", symbol: "mic.slash", tint: .orange, force: true)
                return
            }
            let nextMuted = !hardwareInputMuted
            guard setHardwareMicMuted(nextMuted, announceToast: false) else { return }
            let micName = defaultInputDevice?.name ?? "Microphone"
            let label = nextMuted ? "Mic Muted - \(micName)" : "Mic Live - \(micName)"
            lastRelayedActionLabel = passedThrough ? "\(label) (Synced)" : label
            showToast(
                title: label,
                symbol: nextMuted ? "mic.slash.fill" : "mic.fill",
                tint: nextMuted ? .red : .green
            )

        case .video:
            showVideoUnavailableToast()
        }
    }

    private func handleNativeAppMicShortcutPressed(mapping: CallAppShortcutMapping, pid: pid_t) {
        guard isRunning, developerSimulation == nil else { return }
        lastCallRelayUptime = ProcessInfo.processInfo.systemUptime
        scheduleCallAppMuteStateRefresh(
            pid: pid,
            appName: mapping.appName,
            requiredWindowTitleSubstring: mapping.requiredWindowTitleSubstring
        )
    }

    private func handleCallShortcutRelayed(
        action: CallActionKind,
        mapping: CallAppShortcutMapping,
        targetShortcut: ShortcutSpec,
        deliveredToCallApp: Bool,
        preRelayAppMuted: Bool?
    ) {
        if action == .mic {
            let wasPendingSmartUnmuteOnly = pendingSmartUnmuteOnly
            pendingSmartUnmuteOnly = false

            if !deliveredToCallApp {
                if wasPendingSmartUnmuteOnly {
                    let micName = defaultInputDevice?.name ?? "Microphone"
                    let title = "Mic Live - \(micName)"
                    lastRelayedActionLabel = title
                    DeveloperEventLog.shared.record(.callControls, title, detail: "\(mapping.appName) idle")
                    showToast(title: title, symbol: "mic.fill", tint: .green)
                    return
                }
                if config.overrideScope == .everywhere, defaultInputDevice != nil {
                    let nextMuted = !hardwareInputMuted
                    if setHardwareMicMuted(nextMuted, announceToast: false) {
                        let hwLabel = nextMuted ? "Mic Muted" : "Mic Live"
                        let title = "\(hwLabel) (\(mapping.appName) idle)"
                        lastRelayedActionLabel = title
                        DeveloperEventLog.shared.record(.callControls, title, detail: targetShortcut.displayString)
                        showToast(
                            title: title,
                            symbol: nextMuted ? "mic.slash.fill" : "mic.fill",
                            tint: nextMuted ? .red : .green
                        )
                        return
                    }
                }
                let note = "\(mapping.appName) mic is disabled until a call is active"
                lastRelayedActionLabel = note
                DeveloperEventLog.shared.record(.callControls, note)
                showToast(title: note, symbol: "mic.slash", tint: .orange, force: true)
                return
            }

            let targetMuted: Bool
            if let preMuted = preRelayAppMuted {
                targetMuted = !preMuted
            } else if let cached = callAppMutedState {
                targetMuted = !cached
            } else {
                targetMuted = !isInputMuted
            }

            lastCallRelayUptime = ProcessInfo.processInfo.systemUptime
            if preRelayAppMuted != nil {
                hasActiveCallAppSession = true
                consecutiveNilCallAppPolls = 0
            }
            callAppMutedState = targetMuted
            if config.syncHardwareMuteWithAppMicToggle && defaultInputDevice != nil {
                if hardwareInputMuted != targetMuted {
                    _ = setHardwareMicMuted(targetMuted, announceToast: false)
                } else {
                    updateEffectiveMuteState()
                }
            } else {
                if !targetMuted && hardwareInputMuted && defaultInputDevice != nil {
                    _ = setHardwareMicMuted(false, announceToast: false)
                } else {
                    updateEffectiveMuteState()
                }
            }
            callRemapper.updateCallActivity(isCallOrMediaActive)
            syncCallAppPollTimer()

            let stateLabel = targetMuted ? "Mic Muted" : "Mic Live"
            let title = "\(stateLabel) · \(mapping.appName)"
            lastRelayedActionLabel = title
            DeveloperEventLog.shared.record(
                .callControls,
                title,
                detail: "\(targetShortcut.displayString) · preAX=\(preRelayAppMuted.map { $0 ? "muted" : "live" } ?? "unknown")"
            )
            showToast(
                title: title,
                symbol: targetMuted ? "mic.slash.fill" : "mic.fill",
                tint: targetMuted ? .red : .green
            )

            if let pid = currentTargetSummary(for: .mic)?.pid {
                scheduleCallAppMuteStateRefresh(
                    pid: pid,
                    appName: mapping.appName,
                    requiredWindowTitleSubstring: mapping.requiredWindowTitleSubstring
                )
            }
            return
        }

        if !deliveredToCallApp {
            let note = "\(mapping.appName) \(action.label.lowercased()) is disabled until a call is active"
            lastRelayedActionLabel = note
            DeveloperEventLog.shared.record(.callControls, note)
            showToast(title: note, symbol: "video.slash", tint: .orange, force: true)
            return
        }

        let expectedCameraOn = !isCameraActive
        let stateTitle = expectedCameraOn ? "Camera On · \(mapping.appName)" : "Camera Off · \(mapping.appName)"
        let label = "\(stateTitle) (\(targetShortcut.displayString))"
        lastRelayedActionLabel = label
        DeveloperEventLog.shared.record(.callControls, "Relayed Video shortcut", detail: label)
        showToast(
            title: stateTitle,
            symbol: expectedCameraOn ? "video.fill" : "video.slash.fill",
            tint: expectedCameraOn ? .green : .red
        )
        // Refresh call-app AX state promptly so turning camera off keeps the floating pill
        // visible while the call session (e.g. Google Meet) remains open.
        pollActiveCallAppMuteState()
    }

    private func hasRunningTitleGatedCallBrowser() -> Bool {
        config.appShortcutMappings.contains { mapping in
            mapping.enabled
                && !(mapping.requiredWindowTitleSubstring ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && isAppRunning(for: mapping)
        }
    }

    private func syncCallAppPollTimer() {
        let shouldPoll = isRunning
            && PermissionsManager.shared.isAccessibilityGranted
            && developerSimulation == nil
            && (isMicStreamActive || isCameraActive || hasActiveCallAppSession || hasRunningTitleGatedCallBrowser())
        guard shouldPoll else {
            stopCallAppPollTimer()
            return
        }
        guard callAppPollTimer == nil else { return }
        pollActiveCallAppMuteState()
        let timer = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollActiveCallAppMuteState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        callAppPollTimer = timer
    }

    private func stopCallAppPollTimer() {
        callAppPollTimer?.invalidate()
        callAppPollTimer = nil
    }

    private func callAppPollCandidates() -> [(pid: pid_t, appName: String, requiredWindowTitleSubstring: String?, checkTitleGate: Bool)] {
        var candidates: [(pid: pid_t, appName: String, requiredWindowTitleSubstring: String?, checkTitleGate: Bool)] = []
        var seenKeys = Set<String>()

        if let summary = currentTargetSummary(for: .mic), let pid = summary.pid {
            let mapping = mappingForTargetAppName(summary.appName)
            let req = mapping?.requiredWindowTitleSubstring
            let key = "\(pid)::\(req ?? "")"
            if seenKeys.insert(key).inserted {
                candidates.append((pid, summary.appName, req, !(req ?? "").isEmpty))
            }
        }

        let allowNonGatedIdleCheck = isMicStreamActive || isCameraActive || hasActiveCallAppSession
        let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.bundleIdentifier != nil }
        for mapping in config.appShortcutMappings where mapping.enabled && !mapping.micShortcut.isEmpty {
            let req = mapping.requiredWindowTitleSubstring?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isTitleGated = !(req ?? "").isEmpty
            guard isTitleGated || allowNonGatedIdleCheck else { continue }
            for app in runningApps where mapping.matches(bundleID: app.bundleIdentifier) {
                let key = "\(app.processIdentifier)::\(req ?? "")"
                if seenKeys.insert(key).inserted {
                    candidates.append((app.processIdentifier, mapping.appName, req, isTitleGated))
                }
            }
        }
        return candidates
    }

    private func pollActiveCallAppMuteState() {
        guard isRunning, PermissionsManager.shared.isAccessibilityGranted, developerSimulation == nil else {
            return
        }
        let candidates = callAppPollCandidates()
        guard !candidates.isEmpty else {
            handlePollNoActiveCallControl()
            return
        }

        callAppInspectionQueue.async { [weak self] in
            let streamActive = CoreAudioController.isDefaultInputRunningSomewhere()
            var matchedAppName: String? = nil
            var matchedState: (isMuted: Bool?, hasActiveControl: Bool) = (nil, false)

            for candidate in candidates {
                if candidate.checkTitleGate, let needle = candidate.requiredWindowTitleSubstring, !needle.isEmpty {
                    let titles = CallShortcutRemapper.allWindowTitles(for: candidate.pid)
                    guard titles.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) else {
                        continue
                    }
                }
                let inspected = CallShortcutRemapper.inspectCallAppState(
                    pid: candidate.pid,
                    requiredWindowTitleSubstring: candidate.requiredWindowTitleSubstring
                )
                if inspected.hasActiveControl {
                    matchedAppName = candidate.appName
                    matchedState = inspected
                    break
                }
            }

            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.developerSimulation == nil else { return }
                if self.isMicStreamActive != streamActive {
                    self.isMicStreamActive = streamActive
                    self.callRemapper.updateCallActivity(self.isCallOrMediaActive)
                }
                if matchedState.hasActiveControl {
                    self.consecutiveNilCallAppPolls = 0
                    let sessionChanged = !self.hasActiveCallAppSession
                    self.hasActiveCallAppSession = true
                    if sessionChanged {
                        self.callRemapper.updateCallActivity(self.isCallOrMediaActive)
                        self.callRemapper.refreshContextIfInstalled()
                    }
                    if let observed = matchedState.isMuted {
                        self.applyObservedCallAppMuteState(observed, appName: matchedAppName)
                    } else if sessionChanged {
                        self.syncFloatingIndicator()
                    }
                } else {
                    self.handlePollNoActiveCallControl()
                }
            }
        }
    }

    private func handlePollNoActiveCallControl() {
        consecutiveNilCallAppPolls += 1
        guard consecutiveNilCallAppPolls >= 2 else { return }
        let changed = hasActiveCallAppSession
        hasActiveCallAppSession = false
        if !isMicStreamActive && !isCameraActive && callAppMutedState != nil {
            callAppMutedState = nil
        }
        if changed {
            callRemapper.updateCallActivity(isCallOrMediaActive)
        }
        updateEffectiveMuteState()
        syncCallAppPollTimer()
    }

    private func scheduleCallAppMuteStateRefresh(
        pid: pid_t,
        appName: String,
        requiredWindowTitleSubstring: String? = nil
    ) {
        for delay in [0.18, 0.48] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, self.developerSimulation == nil else { return }
                self.callAppInspectionQueue.async { [weak self] in
                    let observed = CallShortcutRemapper.inspectCallAppMuteState(
                        pid: pid,
                        requiredWindowTitleSubstring: requiredWindowTitleSubstring
                    )
                    Task { @MainActor [weak self] in
                        self?.applyObservedCallAppMuteState(observed, appName: appName)
                    }
                }
            }
        }
    }

    struct ObservedCallMutePlan: Equatable, Sendable {
        let adoptCallAppMuted: Bool
        let hardwareMuteTarget: Bool?
        let announceHardwareSyncLog: Bool
    }

    static func planObservedCallMuteSync(
        observedMuted: Bool?,
        previousCallAppMuted: Bool?,
        hardwareInputMuted: Bool,
        syncHardwareWithApp: Bool,
        isTypingMuted: Bool,
        withinPostRelaySettleWindow: Bool,
        defaultInputAvailable: Bool
    ) -> ObservedCallMutePlan? {
        guard let observedMuted else { return nil }
        if withinPostRelaySettleWindow,
           let prev = previousCallAppMuted,
           prev != observedMuted {
            return nil
        }
        let hardwareTarget: Bool? = {
            guard syncHardwareWithApp, !isTypingMuted, defaultInputAvailable else {
                return nil
            }
            return hardwareInputMuted != observedMuted ? observedMuted : nil
        }()
        let shouldLog = (hardwareTarget != nil) && (previousCallAppMuted == nil || previousCallAppMuted != observedMuted)
        return ObservedCallMutePlan(
            adoptCallAppMuted: observedMuted,
            hardwareMuteTarget: hardwareTarget,
            announceHardwareSyncLog: shouldLog
        )
    }

    private func applyObservedCallAppMuteState(_ observedMuted: Bool?, appName: String?) {
        guard isRunning, isCallOrMediaActive, developerSimulation == nil else {
            return
        }
        let elapsedSinceRelay = ProcessInfo.processInfo.systemUptime - lastCallRelayUptime
        guard let plan = Self.planObservedCallMuteSync(
            observedMuted: observedMuted,
            previousCallAppMuted: callAppMutedState,
            hardwareInputMuted: hardwareInputMuted,
            syncHardwareWithApp: config.syncHardwareMuteWithAppMicToggle,
            isTypingMuted: isTypingMuted,
            withinPostRelaySettleWindow: elapsedSinceRelay < 0.42,
            defaultInputAvailable: defaultInputDevice != nil
        ) else {
            return
        }

        callAppMutedState = plan.adoptCallAppMuted
        if let hardwareTarget = plan.hardwareMuteTarget {
            _ = setHardwareMicMuted(hardwareTarget, announceToast: false)
            if plan.announceHardwareSyncLog {
                DeveloperEventLog.shared.record(
                    .callControls,
                    hardwareTarget ? "Synced hardware mic to app mute" : "Synced hardware mic to app live",
                    detail: appName
                )
            }
            return
        }
        updateEffectiveMuteState()
    }

    private func applyTypingMute(_ shouldMute: Bool) {
        guard config.enabled && appEnabled && config.autoMuteWhileTyping else {
            if isTypingMuted {
                isTypingMuted = false
                _ = coreAudio.setDefaultInputMuted(false)
                refreshAudioDevices()
            }
            return
        }

        if shouldMute {
            guard !typingGuard.isManuallyMuted else { return }
            if coreAudio.setDefaultInputMuted(true) {
                isTypingMuted = true
                refreshAudioDevices()
                DeveloperEventLog.shared.record(.callControls, "Typing guard muted microphone")
            }
        } else {
            guard isTypingMuted && !typingGuard.isManuallyMuted else { return }
            isTypingMuted = false
            _ = coreAudio.setDefaultInputMuted(false)
            refreshAudioDevices()
            DeveloperEventLog.shared.record(.callControls, "Typing guard restored microphone")
        }
        ModuleRegistry.shared.notifyChanged()
    }

    private func restoreTypingMuteIfNeeded(forceUnmuteCurrentDevice: Bool) {
        let shouldRestore = typingGuard.restoreIfTypingMuted() || isTypingMuted
        isTypingMuted = false
        if shouldRestore && forceUnmuteCurrentDevice {
            _ = coreAudio.setDefaultInputMuted(false)
            hardwareInputMuted = coreAudio.currentInputMuteState()
            DeveloperEventLog.shared.record(.callControls, "Restored mic from typing mute")
        }
        updateEffectiveMuteState()
    }

    private func showToast(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        tint: Color,
        force: Bool = false
    ) {
        guard force || config.showToasts else { return }
        HUDToast.shared.show(title: title, subtitle: subtitle, symbol: symbol, tint: tint)
    }

    // MARK: - App Running Status Tracking

    private func installAppLifecycleObservers() {
        removeAppLifecycleObservers()
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for name in names {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshRunningApplications()
                }
            }
            appLifecycleObservers.append(obs)
        }
    }

    private func removeAppLifecycleObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in appLifecycleObservers {
            nc.removeObserver(obs)
        }
        appLifecycleObservers.removeAll()
    }

    func refreshRunningApplications() {
        runningAppBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.isTerminated ? nil : app.bundleIdentifier
            }
        )
        syncCallAppPollTimer()
        syncFloatingIndicator()
    }
}
