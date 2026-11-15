import AppKit
import ApplicationServices
import SwiftUI

enum CleanLockUnlockReason: String, Sendable {
    case timerExpired = "timer_expired"
    case killSwitchHeld = "kill_switch_held"
    case systemStop = "system_stop"
}

@MainActor
final class CleanLockModule: ToolboxModule, ObservableObject {
    let id = "clean_lock"
    let name = "Clean Lock"
    let tagline = "Lock your keyboard and trackpad on a countdown timer with a large on-screen display for safe cleaning."
    let aboutSummary = "Temporarily blocks all keyboard keys (including volume, brightness, and media keys) and mouse/trackpad clicks & scrolling so you can wipe your MacBook safely. A large center-screen countdown automatically restores full control at 0, with a deliberate Hold ⌃ ⌥ ⌘ Esc (3s) emergency kill switch."
    let featureTips = [
        "Trigger Clean Lock from this settings page whenever you need to wipe crumbs or dust.",
        "Every lock session is strictly bounded (10s to 3m) and automatically restores full input when the countdown hits 0.",
        "Need to cancel early? Hold ⌃ ⌥ ⌘ Esc continuously for 3 seconds to unlock immediately."
    ]
    let symbolName = "keyboard.badge.ellipsis"
    let accentColor = Color.red
    let category: ModuleCategory = .system
    let requiresAccessibility = true
    let supportsMenuBar = false
    let supportsEnableToggle = false
    let accessibilityReason = "Needed to intercept and temporarily block keyboard and pointer events during the Clean Lock countdown."

    @Published private(set) var isLocked = false
    @Published private(set) var remainingSeconds: Int = 60
    @Published private(set) var totalDurationSeconds: Int = 60
    @Published private(set) var blockedInputCount: Int = 0
    @Published private(set) var killSwitchProgress: Double = 0.0

    var isRunning: Bool { isLocked }

    private var config = CleanLockConfig()
    private let inputLockTap = InputLockTap()
    private let hudPanel = CleanLockHUDPanel()
    private var countdownTimer: Timer?
    private var releaseGraceTimer: Timer?
    private var lockDeadline: Date?

    init() {
        inputLockTap.onKillSwitchUnlock = { [weak self] in
            Task { @MainActor in
                self?.unlock(reason: .killSwitchHeld)
            }
        }
        inputLockTap.onKillSwitchReleased = { [weak self] in
            Task { @MainActor in
                self?.finishKillSwitchReleaseGrace()
            }
        }
    }

    func isEnabled(in config: ToolboxConfig) -> Bool {
        true
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        // On-demand module: no persistent enable/disable toggle.
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !config.general.appEnabled { return "Paused" }
        if !accessibilityGranted { return "Needs Accessibility" }
        if isLocked { return "Locked (\(remainingSeconds)s)" }
        return "On Demand"
    }

    func start() {
        // Clean Lock only intercepts input during an explicit lock session.
    }

    func stop() {
        unlock(reason: .systemStop)
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.cleanLock
        if !fullConfig.general.appEnabled {
            stop()
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(CleanLockSettingsView(module: self))
    }

    /// Starts a bounded Clean Lock session. Refuses to lock if Accessibility is not granted
    /// or if the session-level `CGEventTap` fails to install.
    @discardableResult
    func lock(durationSeconds: Int? = nil) -> Bool {
        guard !isLocked else { return true }
        finishKillSwitchReleaseGrace()

        guard AXIsProcessTrusted() else {
            PermissionsManager.shared.refresh()
            PermissionsManager.shared.promptAndOpenSettings()
            DeveloperEventLog.shared.record(.cleanLock, "Lock refused (Accessibility not granted)")
            return false
        }

        let clampedDuration = CleanLockConfig.clampedDuration(durationSeconds ?? config.durationSeconds)
        let lockPointer = config.lockMouseAndTrackpad

        guard inputLockTap.install(lockMouseAndTrackpad: lockPointer) else {
            HUDToast.shared.show(
                title: "Could not start Clean Lock",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
            DeveloperEventLog.shared.record(.cleanLock, "Event tap installation failed")
            return false
        }

        beginCountdownSession(
            durationSeconds: clampedDuration,
            lockMouseAndTrackpad: lockPointer,
            showHUD: true
        )
        DeveloperEventLog.shared.record(
            .cleanLock,
            "Clean Lock activated",
            detail: "\(clampedDuration)s · pointer \(lockPointer ? "locked" : "unlocked")"
        )
        return true
    }

    func unlock(reason: CleanLockUnlockReason) {
        let wasLocked = isLocked
        countdownTimer?.invalidate()
        countdownTimer = nil
        lockDeadline = nil

        hudPanel.close()
        isLocked = false
        killSwitchProgress = 0.0
        remainingSeconds = 0

        if reason == .killSwitchHeld && wasLocked && inputLockTap.isInstalled {
            // Keep swallowing Esc repeats/keyUp briefly until the user lifts Esc so macOS
            // does not play the "no input allowed" alert beep on the held shortcut.
            inputLockTap.beginKillSwitchReleaseGrace()
            releaseGraceTimer?.invalidate()
            let timer = Timer(timeInterval: InputLockTap.killSwitchReleaseGraceDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.finishKillSwitchReleaseGrace()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            releaseGraceTimer = timer
        } else {
            finishKillSwitchReleaseGrace()
        }

        guard wasLocked else { return }

        DeveloperEventLog.shared.record(.cleanLock, "Clean Lock released", detail: reason.rawValue)

        if reason != .systemStop {
            let title = config.lockMouseAndTrackpad
                ? "Keyboard & Mouse Unlocked"
                : "Keyboard Unlocked"
            HUDToast.shared.show(title: title, symbol: "lock.open.fill", tint: .green)
        }
    }

    private func finishKillSwitchReleaseGrace() {
        releaseGraceTimer?.invalidate()
        releaseGraceTimer = nil
        inputLockTap.uninstall()
    }

    /// Starts the bounded countdown timer and optional HUD. Exposed internally for self-tests.
    internal func beginCountdownSession(
        durationSeconds: Int,
        lockMouseAndTrackpad: Bool,
        showHUD: Bool
    ) {
        let clamped = CleanLockConfig.clampedDuration(durationSeconds)
        totalDurationSeconds = clamped
        remainingSeconds = clamped
        blockedInputCount = 0
        killSwitchProgress = 0.0
        isLocked = true
        lockDeadline = Date().addingTimeInterval(TimeInterval(clamped))

        if showHUD {
            hudPanel.show(
                totalSeconds: clamped,
                remainingSeconds: clamped,
                lockMouseAndTrackpad: lockMouseAndTrackpad
            )
        }

        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickCountdown()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    internal func tickCountdown(now: Date = Date()) {
        guard isLocked, let deadline = lockDeadline else { return }

        let progress = inputLockTap.currentKillSwitchProgress()
        killSwitchProgress = progress
        if progress >= 1.0 {
            unlock(reason: .killSwitchHeld)
            return
        }

        let remainingInterval = deadline.timeIntervalSince(now)
        if remainingInterval <= 0 {
            unlock(reason: .timerExpired)
            return
        }

        let nextSeconds = max(1, Int(ceil(remainingInterval)))
        remainingSeconds = nextSeconds
        blockedInputCount = inputLockTap.currentBlockedCount
        hudPanel.update(
            remainingSeconds: nextSeconds,
            remainingInterval: remainingInterval,
            blockedCount: blockedInputCount,
            killSwitchProgress: progress
        )
    }
}
