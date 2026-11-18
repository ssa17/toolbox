import AppKit
import ApplicationServices

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )!
    static let legacyAccessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!
    static let legacyScreenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    private static let awaitingGrantWindowSeconds: TimeInterval = 180

    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published private(set) var simulatedAccessibilityGranted: Bool? = nil
    @Published var isPresentingOnboardingModal: Bool = false
    @Published private(set) var isAwaitingAccessibilityGrant: Bool = false
    @Published private(set) var hasAttemptedGrantWithoutSuccess: Bool = false
    @Published private(set) var isResettingAccessibility: Bool = false

    let isAdHocSigned: Bool

    var onAccessibilityChanged: ((Bool) -> Void)?
    var onReturnToAppRequested: (() -> Void)?

    private var lastActualAccessibilityGranted: Bool = false
    private var timer: Timer?
    private var fastPollTimer: Timer?
    private var promptMonitorTimer: Timer?
    private var awaitingGrantDeadline: Date?
    private var isRequestInFlight: Bool = false
    private var didVisitSystemSettingsWhileAwaiting: Bool = false
    private var axNotificationHoldoffUntil: Date = .distantPast
    private var ignoringSelfPostedNotificationUntil: Date = .distantPast
    private var nextAllowedCacheFlushAt: Date = .distantPast
    private var activeObserver: NSObjectProtocol?
    private var workspaceActivateObserver: NSObjectProtocol?
    private var distributedAccessibilityObserver: NSObjectProtocol?

    private typealias TCCAccessCheckAuditTokenFunc = @convention(c) (
        CFString,
        UnsafePointer<audit_token_t>,
        CFDictionary?
    ) -> UInt8

    nonisolated private static let tccAccessCheckAuditTokenSymbol: TCCAccessCheckAuditTokenFunc? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let sym = dlsym(handle, "TCCAccessCheckAuditToken") else {
            return nil
        }
        return unsafeBitCast(sym, to: TCCAccessCheckAuditTokenFunc.self)
    }()

    nonisolated private static let currentAuditToken: audit_token_t? = {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &token) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? token : nil
    }()

    /// Queries `tccd` directly for `kTCCServiceAccessibility` using the current process's `audit_token_t`.
    /// Unlike `TCCAccessPreflight` (which passes `target_token == nil` and caches permanently in
    /// `TCC.framework`'s in-process dictionary for `.app` bundles) and `AXIsProcessTrusted()` (which caches
    /// in `HIServices`'s `cacheDict`), `TCCAccessCheckAuditToken` with a non-null `audit_token_t` is never
    /// cached in-process.
    nonisolated static func tccCheckAccessibilityGranted() -> Bool? {
        guard let checkFn = tccAccessCheckAuditTokenSymbol,
              var token = currentAuditToken else {
            return nil
        }
        let result = withUnsafePointer(to: &token) { ptr in
            checkFn("kTCCServiceAccessibility" as CFString, ptr, nil)
        }
        return result != 0
    }

    nonisolated(unsafe) private static var cachedLiveTrustedState: Bool = (
        tccCheckAccessibilityGranted() ?? AXIsProcessTrusted()
    )

    /// Ground-truth Accessibility check that queries `tccd` directly (bypassing `HIServices`'s
    /// stale in-process `cacheDict`) and keeps `cachedLiveTrustedState` updated.
    nonisolated static func isProcessTrusted() -> Bool {
        let trusted = tccCheckAccessibilityGranted() ?? AXIsProcessTrusted()
        cachedLiveTrustedState = trusted
        return trusted
    }

    /// Zero-XPC fast path for real-time `CGEventTap` callbacks.
    nonisolated static func isProcessTrustedFast() -> Bool {
        cachedLiveTrustedState
    }

    /// Posts `com.apple.accessibility.api` on the distributed notification center so `HIServices`'s
    /// internal `apiNotifyCallback` clears its in-process `cacheDict`.
    nonisolated static func flushHIServicesAccessibilityCache() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            CFNotificationName("com.apple.accessibility.api" as CFString),
            nil,
            nil,
            true
        )
    }

    var actualAccessibilityGranted: Bool {
        Self.isProcessTrusted()
    }

    nonisolated static func shouldRearmEventTap(
        for type: CGEventType,
        isTrusted: Bool = isProcessTrustedFast()
    ) -> Bool {
        type == .tapDisabledByTimeout && isTrusted
    }

    static var isRunningInDiagnosticMode: Bool {
        let args = CommandLine.arguments
        return args.contains("--self-test")
            || args.contains("--snapshot-ui")
            || args.contains("--ocr-file")
            || args.contains("--ocr-capture")
            || args.contains("--check-screen-recording")
    }

    private init() {
        let actual = Self.isProcessTrusted()
        lastActualAccessibilityGranted = actual
        isAccessibilityGranted = actual
        isAdHocSigned = RuntimeDiagnosticsSnapshot.inspectCodeSignature().isAdHoc

        let bgTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(bgTimer, forMode: .common)
        timer = bgTimer

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidBecomeActive()
            }
        }

        workspaceActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor [weak self] in
                self?.handleWorkspaceAppActivated(bundleID: bundleID)
            }
        }

        distributedAccessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDistributedAccessibilityNotification()
            }
        }
    }

    func refresh() {
        let actual: Bool
        if let tcc = Self.tccCheckAccessibilityGranted() {
            actual = tcc
            if Date() >= axNotificationHoldoffUntil {
                let axCached = AXIsProcessTrusted()
                if axCached != tcc {
                    scheduleHIServicesCacheResync()
                }
            }
        } else {
            actual = AXIsProcessTrusted()
        }
        Self.cachedLiveTrustedState = actual
        applyAccessibilityCheck(actual)
        ModuleRegistry.shared.screenOCR.refreshScreenPermission()
    }

    private func scheduleHIServicesCacheResync(force: Bool = false) {
        let now = Date()
        guard force || now >= nextAllowedCacheFlushAt else { return }
        ignoringSelfPostedNotificationUntil = now.addingTimeInterval(0.16)
        axNotificationHoldoffUntil = now.addingTimeInterval(0.07)
        nextAllowedCacheFlushAt = now.addingTimeInterval(1.20)
        Self.flushHIServicesAccessibilityCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                _ = AXIsProcessTrusted()
                self?.refresh()
            }
        }
    }

    private func applyAccessibilityCheck(_ actual: Bool) {
        let wasActualGranted = lastActualAccessibilityGranted
        let actualChanged = actual != wasActualGranted
        lastActualAccessibilityGranted = actual

        let effective = simulatedAccessibilityGranted ?? actual
        if effective != isAccessibilityGranted {
            isAccessibilityGranted = effective
        }

        if actualChanged {
            onAccessibilityChanged?(actual)
        }

        if actual {
            let shouldReturn = Self.shouldReturnToAppOnGrant(
                isAwaiting: isAwaitingGrantWindowActive,
                wasGranted: wasActualGranted,
                nowGranted: actual,
                isDiagnosticMode: Self.isRunningInDiagnosticMode,
                simulatedOverride: simulatedAccessibilityGranted
            )
            stopAwaitingAccessibilityGrant()
            hasAttemptedGrantWithoutSuccess = false

            if shouldReturn {
                if isPresentingOnboardingModal {
                    dismissOnboardingModal(markSeen: true)
                }
                returnToAppAfterGrant()
            }
        } else if let deadline = awaitingGrantDeadline, Date() > deadline {
            stopAwaitingAccessibilityGrant()
        }
    }

    private var isAwaitingGrantWindowActive: Bool {
        guard isAwaitingAccessibilityGrant, let deadline = awaitingGrantDeadline else { return false }
        return Date() <= deadline
    }

    static func shouldReturnToAppOnGrant(
        isAwaiting: Bool,
        wasGranted: Bool,
        nowGranted: Bool,
        isDiagnosticMode: Bool,
        simulatedOverride: Bool?
    ) -> Bool {
        isAwaiting && !wasGranted && nowGranted && !isDiagnosticMode && simulatedOverride == nil
    }

    private func handleDistributedAccessibilityNotification() {
        if Date() < ignoringSelfPostedNotificationUntil {
            return
        }
        // Hold off calling AXIsProcessTrusted() for 70ms while tccd finishes committing
        // the SQLite update that triggered com.apple.accessibility.api (~15–25ms window).
        axNotificationHoldoffUntil = Date().addingTimeInterval(0.07)
        refresh()
        for delay in [0.08, 0.22, 0.50, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
    }

    private func handleWorkspaceAppActivated(bundleID: String?) {
        if bundleID == "com.apple.systempreferences", isAwaitingGrantWindowActive {
            didVisitSystemSettingsWhileAwaiting = true
        }
        refresh()
    }

    private func handleAppDidBecomeActive() {
        refresh()
        if isAwaitingGrantWindowActive,
           didVisitSystemSettingsWhileAwaiting,
           !actualAccessibilityGranted {
            hasAttemptedGrantWithoutSuccess = true
        }
    }

    private func beginAwaitingAccessibilityGrant() {
        isAwaitingAccessibilityGrant = true
        awaitingGrantDeadline = Date().addingTimeInterval(Self.awaitingGrantWindowSeconds)
        didVisitSystemSettingsWhileAwaiting = false

        guard fastPollTimer == nil else { return }
        let fastTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(fastTimer, forMode: .common)
        fastPollTimer = fastTimer
    }

    private func stopAwaitingAccessibilityGrant() {
        isAwaitingAccessibilityGrant = false
        awaitingGrantDeadline = nil
        didVisitSystemSettingsWhileAwaiting = false
        fastPollTimer?.invalidate()
        fastPollTimer = nil
    }

    private func returnToAppAfterGrant() {
        if let onReturnToAppRequested {
            onReturnToAppRequested()
            return
        }
        ModuleRegistry.shared.screenOCR.refreshScreenPermission()
        let needsScreenOCR = ConfigManager.shared.config.screenOCR.enabled
            && !ModuleRegistry.shared.screenOCR.screenRecordingGranted

        MainWindowController.shared.show(destination: nil)
        if needsScreenOCR {
            HUDToast.shared.show(
                title: "Step 1 complete: Accessibility granted — enable Screen Recording next",
                symbol: "checkmark.shield.fill",
                tint: .green
            )
        } else {
            HUDToast.shared.show(
                title: "Accessibility granted — Toolbox is ready",
                symbol: "checkmark.shield.fill",
                tint: .green
            )
        }
    }

    /// Overrides the UI-reported Accessibility status in-memory for Developer Tools previews.
    /// Does not modify real macOS TCC trust or background event taps.
    func setSimulatedAccessibilityGranted(_ simulated: Bool?) {
        simulatedAccessibilityGranted = simulated
        refresh()
    }

    func presentOnboardingModal() {
        refresh()
        isPresentingOnboardingModal = true
    }

    func dismissOnboardingModal(markSeen: Bool = true) {
        isPresentingOnboardingModal = false
        if markSeen && !ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding {
            ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding = true
        }
    }

    /// Smoothly guides the user to grant Accessibility permission without burying the macOS TCC dialog
    /// or opening duplicate prompts. Calls `AXIsProcessTrustedWithOptions` so macOS shows its native
    /// grant dialog (which adds Toolbox to the list and opens System Settings when the user clicks
    /// "Open System Settings"), and only opens System Settings directly if macOS suppressed the dialog.
    func promptAndOpenSettings() {
        refresh()
        guard !actualAccessibilityGranted else { return }
        guard !isRequestInFlight else { return }

        beginAwaitingAccessibilityGrant()

        guard !Self.isRunningInDiagnosticMode else { return }

        isRequestInFlight = true
        if Self.hasSystemPermissionPromptWindow() {
            monitorSystemPromptUntilDismissed()
            return
        }

        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        waitForSystemPromptOrOpenSettings()
    }

    private func waitForSystemPromptOrOpenSettings() {
        promptMonitorTimer?.invalidate()
        let appearDeadline = Date().addingTimeInterval(1.1)
        let monitor = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if self.actualAccessibilityGranted {
                    self.promptMonitorTimer?.invalidate()
                    self.promptMonitorTimer = nil
                    self.isRequestInFlight = false
                    return
                }
                if Self.hasSystemPermissionPromptWindow() {
                    self.monitorSystemPromptUntilDismissed()
                    return
                }
                if Date() >= appearDeadline {
                    self.promptMonitorTimer?.invalidate()
                    self.promptMonitorTimer = nil
                    self.isRequestInFlight = false
                    self.openAccessibilitySettings()
                }
            }
        }
        RunLoop.main.add(monitor, forMode: .common)
        promptMonitorTimer = monitor
    }

    private func monitorSystemPromptUntilDismissed() {
        promptMonitorTimer?.invalidate()
        let deadline = Date().addingTimeInterval(30)
        let monitor = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if self.actualAccessibilityGranted || !Self.hasSystemPermissionPromptWindow() || Date() > deadline {
                    self.promptMonitorTimer?.invalidate()
                    self.promptMonitorTimer = nil
                    self.isRequestInFlight = false
                    guard !self.actualAccessibilityGranted else { return }

                    // When the user clicks "Open System Settings" on universalAccessAuthWarn while System Settings
                    // is cold-launching, macOS briefly re-activates Toolbox before System Settings creates its window,
                    // causing System Settings to open behind Toolbox. Re-yield activation once System Settings opens.
                    for delay in [0.55, 1.10] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            MainActor.assumeIsolated {
                                self?.bringSystemSettingsToFrontIfOpenBehindToolbox()
                            }
                        }
                    }
                }
            }
        }
        RunLoop.main.add(monitor, forMode: .common)
        promptMonitorTimer = monitor
    }

    private func bringSystemSettingsToFrontIfOpenBehindToolbox() {
        refresh()
        guard !actualAccessibilityGranted, NSApp.isActive else { return }
        guard let settingsApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systempreferences" && !$0.isTerminated
        }) else {
            return
        }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let hasSettingsWindow = info.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
            return owner == "System Settings" || owner == "System Preferences"
        }
        guard hasSettingsWindow else { return }
        NSApp.yieldActivation(to: settingsApp)
        _ = settingsApp.activate()
    }

    func openAccessibilitySettings() {
        Self.openSystemSettings(
            primaryURL: Self.accessibilitySettingsURL,
            fallbackURL: Self.legacyAccessibilitySettingsURL
        )
    }

    static func openSystemSettings(primaryURL: URL, fallbackURL: URL) {
        guard !isRunningInDiagnosticMode else { return }
        if NSApp.isActive,
           let settingsApp = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == "com.apple.systempreferences" && !$0.isTerminated
           }) {
            NSApp.yieldActivation(to: settingsApp)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(primaryURL, configuration: config) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(fallbackURL)
                }
            }
        }
    }

    /// Detects whether macOS is currently displaying a TCC permission prompt window
    /// (typically owned by `UserNotificationCenter`, `CoreServicesUIAgent`, or `universalAccessAuthWarn`).
    static func hasSystemPermissionPromptWindow() -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let promptOwners: Set<String> = [
            "UserNotificationCenter",
            "CoreServicesUIAgent",
            "universalAccessAuthWarn"
        ]
        for window in info {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  promptOwners.contains(owner) else {
                continue
            }
            if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
               let width = boundsDict["Width"] as? Double,
               let height = boundsDict["Height"] as? Double,
               width > 120 && height > 60 {
                return true
            }
        }
        return false
    }

    /// Detects whether System Settings is currently presenting a modal alert sheet
    /// (such as macOS's "Quit & Reopen / Later" prompt after enabling Screen Recording).
    static func hasSystemSettingsAlertSheet() -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var settingsWindowCount = 0
        for window in info {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "System Settings" || owner == "System Preferences" else {
                continue
            }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let width = boundsDict["Width"] as? Double,
                  let height = boundsDict["Height"] as? Double,
                  width > 120 && height > 80 else {
                continue
            }
            settingsWindowCount += 1
            if width <= 520 && height <= 450 {
                return true
            }
        }
        return settingsWindowCount >= 2
    }

    /// Clears any stale TCC entry (e.g. from an earlier unsigned dev build) and re-prompts cleanly.
    func resetAndRegrantAccessibility() {
        guard !isResettingAccessibility else { return }

        promptMonitorTimer?.invalidate()
        promptMonitorTimer = nil
        isRequestInFlight = false
        hasAttemptedGrantWithoutSuccess = false

        guard let bundleID = Bundle.main.bundleIdentifier, !Self.isRunningInDiagnosticMode else {
            promptAndOpenSettings()
            return
        }

        let bundlePath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executablePath ?? ""
        isResettingAccessibility = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleID]
            try? process.run()
            process.waitUntilExit()

            Self.clearUniversalAccessWarningSuppression(
                bundleID: bundleID,
                bundlePath: bundlePath,
                executablePath: executablePath
            )

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleHIServicesCacheResync(force: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.isResettingAccessibility = false
                            self.refresh()
                            self.promptAndOpenSettings()
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func clearUniversalAccessWarningSuppression(
        bundleID: String,
        bundlePath: String,
        executablePath: String
    ) {
        let domain = "com.apple.universalaccessAuthWarning" as CFString
        let baseKeys = [bundleID, bundlePath, executablePath].filter { !$0.isEmpty }
        var allKeys: [String] = []
        for base in baseKeys {
            allKeys.append(base)
            for prefix in 0...4 {
                allKeys.append("\(prefix)::\(base)")
            }
        }
        for key in allKeys {
            CFPreferencesSetValue(
                key as CFString,
                nil,
                domain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    // MARK: - Testing Helpers

    internal func setAwaitingGrantForTesting(_ awaiting: Bool) {
        if awaiting {
            isAwaitingAccessibilityGrant = true
            awaitingGrantDeadline = Date().addingTimeInterval(Self.awaitingGrantWindowSeconds)
        } else {
            stopAwaitingAccessibilityGrant()
        }
    }

    internal func applyAccessibilityStateForTesting(wasGranted: Bool, nowGranted: Bool) {
        lastActualAccessibilityGranted = wasGranted
        applyAccessibilityCheck(nowGranted)
    }

    internal func markAttemptedGrantWithoutSuccessForTesting(_ attempted: Bool) {
        hasAttemptedGrantWithoutSuccess = attempted
    }
}
