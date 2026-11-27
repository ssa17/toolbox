import AppKit
import Combine
import Foundation
import SwiftUI

/// Turns Caps Lock into a dual-role Hyper Key (hold for `⌃ ⌥ ⌘` or `⌃ ⌥ ⇧ ⌘`, quick tap for Caps Lock / Escape / Disabled).
@MainActor
final class HyperKeyModule: ObservableObject, ToolboxModule {
    let id = "hyper_key"
    let name = "Keyboard Shortcuts & Hyper Key"
    let tagline = "Organize every Toolbox shortcut by feature and turn Caps Lock into a dual-role Hyper Key."
    let aboutSummary = "Maps Caps Lock in-process via IOKit HID UserKeyMapping to F18 and intercepts it on a dedicated background CGEventTap. Holding Caps Lock acts as a full modifier chord with deterministic direct dispatch for Toolbox shortcuts; a quick tap toggles Caps Lock or sends Escape."
    let featureTips = [
        "Use Hold = ⌃ ⌥ ⌘ (Toolbox Chord) so every default Toolbox shortcut works with Caps Lock + Key immediately.",
        "Keep System Settings → Keyboard → Modifier Keys → Caps Lock set to “Caps Lock” so macOS delivers raw key presses.",
        "Open Keyboard Shortcuts in the sidebar to search, test, and organize every Toolbox shortcut in one place."
    ]
    let symbolName = "keyboard"
    let accentColor: Color = .indigo
    let category: ModuleCategory = .automation
    let requiresAccessibility = false
    let accessibilityReason = "Accessibility permission is required when Caps Lock Hyper Key is enabled."
    let supportsMenuBar = true
    let supportsEnableToggle = true

    @Published private(set) var isRunning = false
    @Published private(set) var isTapInstalled = false
    @Published private(set) var isHIDRemapActive = false
    @Published private(set) var externalCapsLockWarning: String? = nil
    @Published private(set) var lastLiveEvent: HyperKeyLiveEvent? = nil

    private var config: HyperKeyConfig = HyperKeyConfig()
    private let remapper = CapsLockRemapper()
    private let eventTap = HyperKeyEventTap()
    private var didPerformInitialCleanup = false
    private var workspaceObserver: NSObjectProtocol?

    internal var runsTapOnBackgroundThreadForTesting: Bool {
        eventTap.runsOnDedicatedBackgroundRunLoopForTesting
    }

    init() {
        eventTap.onTriggerToolboxHotKey = { [weak self] name, shortcut in
            self?.handleToolboxHotKeyTrigger(name: name, shortcut: shortcut)
        }
        eventTap.onTriggerCallControls = { [weak self] action, shortcut in
            self?.handleCallControlsTrigger(action: action, shortcut: shortcut)
        }
        eventTap.onToggleCapsLock = { [weak self] in
            self?.handleCapsLockToggleTap()
        }
        eventTap.onLiveEvent = { [weak self] event in
            self?.lastLiveEvent = event
        }
        eventTap.onHoldModifiersChanged = { _ in
            ModuleRegistry.shared.windowSnapper.handleHyperKeyModifiersChanged()
        }
    }

    var hasRequiredPermissions: Bool {
        let permissions = PermissionsManager.shared
        return permissions.isAccessibilityGranted && permissions.isInputMonitoringGranted
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.hyperKey.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.hyperKey.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.hyperKey.enabled ? "⇪ → \(config.hyperKey.holdMode.shortLabel)" : nil
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !isEnabled(in: config) { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        let hasInputMonitoring = PermissionsManager.shared.isInputMonitoringGranted
        if !accessibilityGranted || !hasInputMonitoring { return "Needs Permissions" }
        return isRunning ? "Active" : "Standby"
    }

    func start() {
        reload(with: ConfigManager.shared.config)
    }

    func stop() {
        let wasActive = isRunning || isTapInstalled || isHIDRemapActive
        removeWorkspaceObserver()
        eventTap.uninstall()
        remapper.restorePreToolboxMappings()
        isTapInstalled = false
        isHIDRemapActive = false
        isRunning = false
        if wasActive {
            DeveloperEventLog.shared.record(.hyperKey, "Hyper Key stopped & Caps Lock restored")
        }
        ModuleRegistry.shared.notifyChanged()
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.hyperKey
        eventTap.updateConfig(fullConfig.hyperKey)
        eventTap.updateCallControlsBindings(HyperKeyCallControlsBindings(
            enabled: fullConfig.general.appEnabled && fullConfig.callControls.enabled,
            micShortcut: fullConfig.callControls.micShortcut,
            videoShortcut: fullConfig.callControls.videoShortcut
        ))

        guard fullConfig.general.appEnabled && fullConfig.hyperKey.enabled else {
            if !didPerformInitialCleanup {
                didPerformInitialCleanup = true
                remapper.cleanupStaleMappingIfNeeded()
            }
            externalCapsLockWarning = remapper.detectNativeModifierKeysOverride()
            stop()
            return
        }

        didPerformInitialCleanup = true

        let permissions = PermissionsManager.shared
        let permissionsReady = PermissionsManager.isRunningInDiagnosticMode
            ? (permissions.isAccessibilityGranted && permissions.isInputMonitoringGranted)
            : (PermissionsManager.isProcessTrusted() && permissions.actualInputMonitoringGranted)

        guard permissionsReady else {
            externalCapsLockWarning = remapper.detectNativeModifierKeysOverride()
            stop()
            return
        }

        installWorkspaceObserverIfNeeded()

        let remapResult = remapper.applyRemap()
        externalCapsLockWarning = remapResult.externalWarning
        isHIDRemapActive = PermissionsManager.isRunningInDiagnosticMode ? true : remapResult.applied

        let tapStarted = PermissionsManager.isRunningInDiagnosticMode
            ? true
            : (eventTap.isInstalled || eventTap.install())
        isTapInstalled = PermissionsManager.isRunningInDiagnosticMode ? eventTap.isInstalled : tapStarted
        isRunning = tapStarted

        if tapStarted {
            DeveloperEventLog.shared.record(
                .hyperKey,
                "Hyper Key active (\(fullConfig.hyperKey.holdMode.shortLabel))",
                detail: "Tap: \(fullConfig.hyperKey.tapAction.label) (\(fullConfig.hyperKey.tapThresholdMs) ms)"
            )
        }
        ModuleRegistry.shared.notifyChanged()
    }

    func makeSettingsView() -> AnyView {
        AnyView(HyperKeyModuleSettingsView(module: self))
    }

    // MARK: - Event Dispatch

    private func handleToolboxHotKeyTrigger(name: String, shortcut: ShortcutSpec) {
        let triggered = HotKeyManager.shared.simulateTrigger(name: name)
        let actionLabel = ShortcutCatalog.descriptors(in: ConfigManager.shared.config)
            .first(where: { $0.registrationKey == name })
            .map { "\($0.moduleName) · \($0.actionTitle)" } ?? name

        lastLiveEvent = HyperKeyLiveEvent(
            timestamp: Date(),
            summary: triggered
                ? "Held → Dispatched \(actionLabel) (\(shortcut.displayString))"
                : "Held → Pressed \(shortcut.displayString)",
            detail: name,
            kind: .toolboxDispatch
        )
        DeveloperEventLog.shared.record(.hyperKey, "Direct dispatch: \(actionLabel)", detail: shortcut.displayString)
    }

    private func handleCallControlsTrigger(action: CallActionKind, shortcut: ShortcutSpec) {
        ModuleRegistry.shared.callControls.triggerUnifiedActionFromHyperKey(action)
        let actionLabel = action == .mic ? "Call Controls · Toggle Mic Mute" : "Call Controls · Toggle Camera Video"
        lastLiveEvent = HyperKeyLiveEvent(
            timestamp: Date(),
            summary: "Held → Dispatched \(actionLabel) (\(shortcut.displayString))",
            detail: "call_controls.\(action.rawValue)",
            kind: .toolboxDispatch
        )
        DeveloperEventLog.shared.record(.hyperKey, "Direct dispatch: \(actionLabel)", detail: shortcut.displayString)
    }

    private func handleCapsLockToggleTap() {
        let newState = remapper.toggleSystemCapsLockState()
        let stateLabel: String
        if let newState {
            stateLabel = newState ? "Caps Lock ON" : "Caps Lock OFF"
        } else {
            stateLabel = "Toggle Caps Lock"
        }
        lastLiveEvent = HyperKeyLiveEvent(
            timestamp: Date(),
            summary: "Tapped → \(stateLabel)",
            detail: nil,
            kind: .tapAction
        )
        DeveloperEventLog.shared.record(.hyperKey, "Caps Lock tap: \(stateLabel)")
    }

    private func installWorkspaceObserverIfNeeded() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.eventTap.resetTransientState()
            }
        }
    }

    private func removeWorkspaceObserver() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }
}
