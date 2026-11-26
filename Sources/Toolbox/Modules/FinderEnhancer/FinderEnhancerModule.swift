import AppKit
import Foundation
import SwiftUI

@MainActor
final class FinderEnhancerModule: ToolboxModule, ObservableObject {
    let id = "finder_enhancer"
    let name = "Finder Enhancer"
    let tagline = "Add ⌘ X cut-and-paste and Return-to-open in Finder, plus optional auto-quit when an app's last window closes."
    let aboutSummary = "macOS Finder normally requires copying with ⌘ C and moving with ⌥ ⌘ V, uses Return to rename instead of open, and leaves single-window apps sitting in the Dock after their last window closes. Finder Enhancer adds familiar ⌘ X → ⌘ V file moving, Return-to-open (and optional F2 rename), plus an allowlist-first Auto-Quit watcher, each guarded by Accessibility checks so typing, inline renaming, dialogs, and system apps are never interrupted."
    let featureTips = [
        "Pressing ⌘ X in Finder copies the selection and arms a one-shot move; pressing ⌘ V runs Finder's native Move Item Here (⌥ ⌘ V) so macOS handles permissions, volumes, and ⌘ Z undo.",
        "Pressing Esc, copying anything else in another app, or focusing a text field (inline rename, Search, Go to Folder) automatically disarms or passes keys straight through.",
        "Auto-Quit defaults to Allowlist Only (Preview, TextEdit, QuickTime Player, System Settings, Calculator, Font Book) and always uses graceful termination so unsaved-document prompts stay intact."
    ]
    let symbolName = "folder.badge.gearshape"
    let accentColor = Color.blue
    let category: ModuleCategory = .system
    let requiresAccessibility = true
    let accessibilityReason = "Needed to intercept Finder-only shortcuts safely, verify no text field or dialog is focused, and watch when an app's last window closes."

    @Published private(set) var isRunning = false
    @Published private(set) var isKeyTapInstalled = false
    @Published private(set) var armedCutItemCount: Int = 0
    @Published private(set) var watchedAutoQuitAppCount: Int = 0
    @Published private(set) var movesCompletedCount: Int = 0
    @Published private(set) var itemsOpenedCount: Int = 0
    @Published private(set) var itemsRenamedCount: Int = 0
    @Published private(set) var appsAutoQuitCount: Int = 0
    @Published private(set) var lastError: String? = nil

    private var config = FinderEnhancerConfig()
    private let keyInterceptor = FinderKeyInterceptor()
    private let quitWatcher = LastWindowQuitWatcher()
    private var workspaceActivationObserver: NSObjectProtocol?
    private var reconcileTimer: Timer?

    internal var runsKeyTapOnBackgroundThreadForTesting: Bool {
        keyInterceptor.runsOnDedicatedBackgroundRunLoopForTesting
    }

    init() {
        wireCallbacks()
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.finderEnhancer.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.finderEnhancer.enabled = enabled
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !isEnabled(in: config) { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if !accessibilityGranted { return "Needs Accessibility" }
        if !config.finderEnhancer.hasAnyFeatureEnabled { return "Standby" }
        if config.finderEnhancer.needsKeyTap && !isKeyTapInstalled { return "Standby" }
        if armedCutItemCount > 0 { return "Cut Armed (\(armedCutItemCount))" }
        return "Active"
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installWorkspaceObserver()
        syncSubsystems()
        ModuleRegistry.shared.notifyChanged()
    }

    func stop() {
        guard isRunning || keyInterceptor.isInstalled || quitWatcher.watchedAppCount > 0 else { return }
        stopReconcileTimer()
        removeWorkspaceObserver()
        keyInterceptor.uninstall()
        quitWatcher.stop()
        isKeyTapInstalled = false
        armedCutItemCount = 0
        watchedAutoQuitAppCount = 0
        lastError = nil
        isRunning = false
        ModuleRegistry.shared.notifyChanged()
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.finderEnhancer
        if fullConfig.general.appEnabled && config.enabled {
            if !isRunning {
                start()
            } else {
                syncSubsystems()
            }
        } else {
            if isRunning {
                stop()
            }
        }
    }

    func disarmCutState() {
        keyInterceptor.disarmCutState()
        if armedCutItemCount != 0 {
            armedCutItemCount = 0
            stopReconcileTimer()
            ModuleRegistry.shared.notifyChanged()
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(FinderEnhancerSettingsView(module: self))
    }

    // MARK: - Internal Wiring & Lifecycle

    private func wireCallbacks() {
        keyInterceptor.onCutArmed = { [weak self] itemCount in
            guard let self else { return }
            self.armedCutItemCount = itemCount
            self.startReconcileTimer()
            ModuleRegistry.shared.notifyChanged()
            DeveloperEventLog.shared.record(
                .finderEnhancer,
                "Cut armed (\(itemCount) item\(itemCount == 1 ? "" : "s"))"
            )
            if self.config.showCutToast && !PermissionsManager.isRunningInDiagnosticMode {
                let noun = itemCount == 1 ? "item" : "items"
                HUDToast.shared.show(
                    title: "Cut \(itemCount) \(noun) — press ⌘ V to move",
                    symbol: "scissors",
                    tint: .blue
                )
            }
        }

        keyInterceptor.onCutDisarmed = { [weak self] in
            guard let self else { return }
            if self.armedCutItemCount != 0 {
                self.armedCutItemCount = 0
                self.stopReconcileTimer()
                ModuleRegistry.shared.notifyChanged()
            }
        }

        keyInterceptor.onCutMoveExecuted = { [weak self] in
            guard let self else { return }
            self.movesCompletedCount += 1
            self.armedCutItemCount = 0
            self.stopReconcileTimer()
            ModuleRegistry.shared.notifyChanged()
            DeveloperEventLog.shared.record(.finderEnhancer, "Moved cut item(s) via ⌥ ⌘ V")
        }

        keyInterceptor.onReturnOpenExecuted = { [weak self] in
            guard let self else { return }
            self.itemsOpenedCount += 1
            DeveloperEventLog.shared.record(.finderEnhancer, "Translated Return → ⌘ O in Finder")
        }

        keyInterceptor.onF2RenameExecuted = { [weak self] in
            guard let self else { return }
            self.itemsRenamedCount += 1
            DeveloperEventLog.shared.record(.finderEnhancer, "Translated F2 → Return in Finder")
        }

        quitWatcher.onAppAutoQuit = { [weak self] appName, bundleID in
            guard let self else { return }
            self.appsAutoQuitCount += 1
            DeveloperEventLog.shared.record(
                .finderEnhancer,
                "Auto-quit \(appName)",
                detail: bundleID
            )
        }
    }

    private func syncSubsystems() {
        let trusted = PermissionsManager.isProcessTrusted()
        keyInterceptor.updateConfig(config)
        updateFrontmostAppSnapshot()

        // 1. Finder-scoped keyboard tap
        let wasTapInstalled = keyInterceptor.isInstalled
        if isRunning && trusted && config.needsKeyTap {
            if !keyInterceptor.isInstalled {
                if keyInterceptor.install() {
                    lastError = nil
                } else {
                    lastError = "Failed to install Finder keyboard tap (toggle Accessibility off/on in System Settings if you upgraded from an unsigned build)."
                }
            } else {
                lastError = nil
            }
        } else {
            keyInterceptor.uninstall()
            lastError = nil
        }
        isKeyTapInstalled = keyInterceptor.isInstalled
        if isKeyTapInstalled != wasTapInstalled {
            DeveloperEventLog.shared.record(
                .finderEnhancer,
                isKeyTapInstalled ? "Finder key tap installed" : "Finder key tap uninstalled"
            )
        }

        // 2. Last-window auto-quit watcher
        let prevWatched = watchedAutoQuitAppCount
        if isRunning && trusted && config.enableAutoQuitOnLastWindowClose {
            quitWatcher.start(with: config)
        } else {
            quitWatcher.stop()
        }
        watchedAutoQuitAppCount = quitWatcher.watchedAppCount
        if watchedAutoQuitAppCount != prevWatched && config.enableAutoQuitOnLastWindowClose && trusted {
            DeveloperEventLog.shared.record(
                .finderEnhancer,
                "Auto-quit watching \(watchedAutoQuitAppCount) app(s)",
                detail: config.autoQuitMode.rawValue
            )
        }

        if armedCutItemCount > 0 && !config.enableCutAndPaste {
            armedCutItemCount = 0
            stopReconcileTimer()
        }
        ModuleRegistry.shared.notifyChanged()
    }

    private func installWorkspaceObserver() {
        removeWorkspaceObserver()
        updateFrontmostAppSnapshot()
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.keyInterceptor.updateFrontmostApplication(
                    bundleID: app?.bundleIdentifier,
                    pid: app?.processIdentifier
                )
                if self.armedCutItemCount > 0 {
                    self.keyInterceptor.reconcilePasteboard(currentChangeCount: NSPasteboard.general.changeCount)
                }
            }
        }
    }

    private func removeWorkspaceObserver() {
        if let obs = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceActivationObserver = nil
        }
    }

    private func updateFrontmostAppSnapshot() {
        let front = NSWorkspace.shared.frontmostApplication
        keyInterceptor.updateFrontmostApplication(
            bundleID: front?.bundleIdentifier,
            pid: front?.processIdentifier
        )
    }

    private func startReconcileTimer() {
        guard reconcileTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.armedCutItemCount == 0 {
                    self.stopReconcileTimer()
                    return
                }
                self.keyInterceptor.reconcilePasteboard(currentChangeCount: NSPasteboard.general.changeCount)
                self.watchedAutoQuitAppCount = self.quitWatcher.watchedAppCount
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    private func stopReconcileTimer() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
    }
}
