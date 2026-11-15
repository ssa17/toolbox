import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScrollDirectionModule: ToolboxModule, ObservableObject {
    let id = "scroll_direction"
    let name = "Scroll Direction"
    let tagline = "Invert mouse scrolling so it goes the other way from your trackpad."
    let aboutSummary = "macOS applies one scroll direction to every pointing device, so the setting in System Settings always moves your mouse and trackpad together. This module inverts scroll events for the device you pick (mouse by default) at the system event level, so the two can scroll in opposite directions. It never changes the system setting itself, so it keeps working across macOS versions and with any mouse."
    let featureTips = [
        "Your trackpad keeps the direction you set in System Settings; only the selected device is inverted.",
        "Works with any mouse, Bluetooth or USB, and stops instantly when disabled.",
        "High resolution mice (like the Magic Mouse) report trackpad style scroll events. If Live Status shows 'Trackpad' while using your mouse, switch the target to Trackpad."
    ]
    let symbolName = "arrow.up.and.down"
    let accentColor = Color.pink
    let category: ModuleCategory = .system
    let requiresAccessibility = true
    let accessibilityReason = "Needed to observe and invert scroll events from your mouse or trackpad."

    @Published private(set) var isRunning = false
    @Published private(set) var eventsInverted: Int = 0
    @Published private(set) var eventsObserved: Int = 0
    @Published private(set) var lastObservedClass: ScrollTarget?
    @Published private(set) var lastInvertedClass: ScrollTarget?

    let hotKeyName = "scroll_direction.toggle"

    private var config = ScrollDirectionConfig()
    private let tap = ScrollInversionTap()
    private var statsTimer: Timer?

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.scrollDirection.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.scrollDirection.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.scrollDirection.shortcut.isEmpty ? nil : config.scrollDirection.shortcut.displayString
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !isEnabled(in: config) { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if !accessibilityGranted { return "Needs Accessibility" }
        if !isRunning || !tap.isInstalled { return "Standby" }
        switch config.scrollDirection.target {
        case .mouse: return "Inverting Mouse"
        case .trackpad: return "Inverting Trackpad"
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        syncTap()
        startStatsTimer()
        ModuleRegistry.shared.notifyChanged()
    }

    func stop() {
        HotKeyManager.shared.unregister(name: hotKeyName)
        guard isRunning else { return }
        stopStatsTimer()
        tap.uninstall()
        tap.resetStats()
        isRunning = false
        eventsInverted = 0
        eventsObserved = 0
        lastObservedClass = nil
        lastInvertedClass = nil
        ModuleRegistry.shared.notifyChanged()
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.scrollDirection
        if fullConfig.general.appEnabled && config.enabled {
            if !isRunning {
                start()
            } else {
                syncTap()
            }
        } else {
            if isRunning { stop() }
        }
        syncHotKey(appEnabled: fullConfig.general.appEnabled)
    }

    private func syncHotKey(appEnabled: Bool) {
        if appEnabled && !config.shortcut.isEmpty {
            HotKeyManager.shared.register(name: hotKeyName, shortcut: config.shortcut) { [weak self] in
                self?.toggleEnabledFromHotKey()
            }
        } else {
            HotKeyManager.shared.unregister(name: hotKeyName)
        }
    }

    private func toggleEnabledFromHotKey() {
        let next = !ConfigManager.shared.config.scrollDirection.enabled
        ConfigManager.shared.config.scrollDirection.enabled = next
        HUDToast.shared.show(
            title: next ? "Scroll Direction On" : "Scroll Direction Off",
            symbol: "arrow.up.and.down",
            tint: next ? .pink : .secondary
        )
    }

    /// Whether the event tap is currently installed (used by the settings UI).
    var isTapInstalled: Bool {
        tap.isInstalled
    }

    func makeSettingsView() -> AnyView {
        AnyView(ScrollDirectionSettingsView(module: self))
    }

    /// Installs or removes the tap according to the current permission state and
    /// applies a possibly changed target. Safe to call on any config or permission change.
    private func syncTap() {
        tap.setTarget(config.target)
        if AXIsProcessTrusted() {
            if !tap.isInstalled {
                tap.install()
            }
        } else {
            tap.uninstall()
        }
        refreshPublishedStats()
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPublishedStats()
            }
        }
    }

    private func refreshPublishedStats() {
        eventsInverted = tap.eventsInverted
        eventsObserved = tap.eventsObserved
        lastObservedClass = tap.lastObservedClass
        lastInvertedClass = tap.lastInvertedClass
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
}
