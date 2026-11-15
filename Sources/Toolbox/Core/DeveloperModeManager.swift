import CryptoKit
import Foundation

/// Subsections shown under the hidden `Developer` sidebar group when unlocked.
enum DeveloperSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case updates
    case uiAndModules
    case eventsAndTaps
    case hotKeysAndConfig
    case checksAndDiagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updates: return "Updates"
        case .uiAndModules: return "UI & Modules"
        case .eventsAndTaps: return "Events & Taps"
        case .hotKeysAndConfig: return "HotKeys & Config"
        case .checksAndDiagnostics: return "Checks & Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .updates:
            return "Simulate app-wide update states, customize release notes, preview dark Sparkle dialogs, and probe the live appcast feed."
        case .uiAndModules:
            return "Override Accessibility UI banners, trigger HUD toasts, launch floating popovers, and inspect or reload modules."
        case .eventsAndTaps:
            return "Stream internal module events live, inspect the Scroll Direction CGEventTap, and watch the Dock window Z-order stack."
        case .hotKeysAndConfig:
            return "Inspect and trigger Carbon global hotkeys, test shortcut collisions, and checkpoint, diff, or reset config sections."
        case .checksAndDiagnostics:
            return "Run non-destructive preflight checks, inspect code signing and Gatekeeper status, and manage PIN lock behavior."
        }
    }

    var symbolName: String {
        switch self {
        case .updates: return "arrow.down.circle"
        case .uiAndModules: return "square.stack.3d.up"
        case .eventsAndTaps: return "waveform.path.ecg"
        case .hotKeysAndConfig: return "keyboard"
        case .checksAndDiagnostics: return "checkmark.shield"
        }
    }
}

/// Update UI presets that can be simulated in-memory without touching Sparkle feeds or disk state.
enum UpdateSimulationPreset: String, CaseIterable, Identifiable, Sendable {
    case upToDate
    case checking
    case updateAvailable
    case checkFailed
    case neverChecked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .upToDate: return "Up to Date"
        case .checking: return "Checking (62%)"
        case .updateAvailable: return "Update Available"
        case .checkFailed: return "Check Failed"
        case .neverChecked: return "Never Checked"
        }
    }

    var summary: String {
        switch self {
        case .upToDate:
            return "Simulates a recent check with no newer release (green Up to Date badge in Settings)."
        case .checking:
            return "Holds the inline check progress bar at 62% in Settings and the menu bar popover."
        case .updateAvailable:
            return "Activates the top window banner, sidebar version pill, menu bar Update button, and Settings card."
        case .checkFailed:
            return "Simulates a failed GitHub Releases lookup (orange Check Failed badge & error message)."
        case .neverChecked:
            return "Clears the last-checked timestamp to show the fresh 'Never' state in Settings."
        }
    }
}

/// Previewable states of the custom dark `ToolboxUpdateWindowController`.
enum UpdateDialogPreviewKind: String, CaseIterable, Identifiable, Sendable {
    case updateAvailable
    case permissionPrompt
    case downloading
    case extracting
    case readyToInstall
    case installing
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updateAvailable: return "Update Available"
        case .permissionPrompt: return "Permission Prompt"
        case .downloading: return "Downloading"
        case .extracting: return "Verifying"
        case .readyToInstall: return "Ready to Install"
        case .installing: return "Installing"
        case .error: return "Update Error"
        }
    }
}

/// Preset toast notifications for testing `HUDToast` layout and styling.
enum ToastPreviewPreset: String, CaseIterable, Identifiable, Sendable {
    case success
    case info
    case warning
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .success: return "Success"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var defaultMessage: String {
        switch self {
        case .success: return "Copied snippet to clipboard"
        case .info: return "Update simulation ready"
        case .warning: return "Accessibility access recommended"
        case .error: return "Could not terminate process"
        }
    }
}

enum ReleaseNotesPreset: String, CaseIterable, Identifiable, Sendable {
    case standard
    case longScrollable
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard Changelog"
        case .longScrollable: return "Long (Scrollable)"
        case .custom: return "Custom HTML"
        }
    }
}

enum UpdateErrorPreset: String, CaseIterable, Identifiable, Sendable {
    case networkTimeout
    case eddsaSignatureInvalid
    case archiveCorrupt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .networkTimeout: return "Network Timeout"
        case .eddsaSignatureInvalid: return "EdDSA Signature Mismatch"
        case .archiveCorrupt: return "Corrupt Archive"
        }
    }

    var message: String {
        switch self {
        case .networkTimeout:
            return "Unable to reach GitHub Releases (simulated network timeout)."
        case .eddsaSignatureInvalid:
            return "EdDSA signature verification failed against SUPublicEDKey (simulated security failure)."
        case .archiveCorrupt:
            return "The downloaded Toolbox update archive could not be extracted cleanly (simulated I/O error)."
        }
    }
}

enum PinVerificationResult: Equatable, Sendable {
    case unlocked
    case wrongPin(remainingAttempts: Int)
    case lockedOut(remainingSeconds: Int)
}

/// Manages PIN-gated unlock state, brute-force throttling, hidden gesture progression,
/// and coordinated simulation resets for Developer Tools.
@MainActor
final class DeveloperModeManager: ObservableObject {
    static let shared = DeveloperModeManager()

    static let requiredUnlockTaps = 5
    static let maxFailedPinAttempts = 5
    static let pinLockoutDuration: TimeInterval = 15.0

    private static let defaultsUnlockedKey = "toolbox.developerModeUnlocked"
    private static let defaultsPersistentKey = "toolbox.developerModePersistent"
    private static let tapResetWindow: TimeInterval = 4.0
    private static let pinSalt = "toolbox.dev.pin.v1:"
    // Salted SHA-256 digest of the developer PIN; keeps the PIN out of plaintext strings.
    private static let expectedPinDigestBytes: [UInt8] = [
        0xad, 0xfd, 0xba, 0x8a, 0x97, 0xe7, 0x45, 0x7d,
        0xf4, 0xff, 0x01, 0x9c, 0xb5, 0xe9, 0xc1, 0x56,
        0x70, 0x1b, 0x6c, 0x89, 0xa8, 0x27, 0xa7, 0x62,
        0xa3, 0x54, 0xd1, 0x78, 0xd8, 0x4d, 0x13, 0xcf
    ]

    @Published private(set) var isUnlocked: Bool
    @Published private(set) var unlockTapCount: Int = 0
    @Published var isPinPromptPresented: Bool = false
    @Published private(set) var failedPinAttempts: Int = 0
    @Published private(set) var pinLockoutUntil: Date?
    @Published var stayUnlockedAcrossLaunches: Bool {
        didSet {
            guard !isSessionOnly else { return }
            userDefaults.set(stayUnlockedAcrossLaunches, forKey: Self.defaultsPersistentKey)
            if stayUnlockedAcrossLaunches && isUnlocked {
                userDefaults.set(true, forKey: Self.defaultsUnlockedKey)
            } else {
                userDefaults.removeObject(forKey: Self.defaultsUnlockedKey)
            }
        }
    }

    @Published var simulatedUpdateVersion: String = "1.2.0"
    @Published var simulatedUpdateSizeMB: Double = 3.4
    @Published var selectedErrorPreset: UpdateErrorPreset = .networkTimeout {
        didSet {
            simulatedUpdateError = selectedErrorPreset.message
        }
    }
    @Published var simulatedUpdateError: String = UpdateErrorPreset.networkTimeout.message
    @Published var selectedReleaseNotesPreset: ReleaseNotesPreset = .standard
    @Published var customReleaseNotesHTML: String = """
    <p><strong>What's New in Toolbox</strong></p>
    <ul>
      <li>Added Developer Tools diagnostics and live trace console</li>
      <li>Centered Sparkle update dialogs cleanly over the main window</li>
    </ul>
    """
    @Published var toastPreviewMessage: String = "Simulated action completed"

    private let userDefaults: UserDefaults
    private let isSessionOnly: Bool
    private var tapResetWorkItem: DispatchWorkItem?

    static var isLaunchFlagEnabled: Bool {
        CommandLine.arguments.contains("--dev")
            || ProcessInfo.processInfo.environment["TOOLBOX_DEV"] == "1"
    }

    private static var isIsolatedMode: Bool {
        CommandLine.arguments.contains("--self-test")
            || CommandLine.arguments.contains("--snapshot-ui")
            || !(ProcessInfo.processInfo.environment["TOOLBOX_CONFIG_DIR"] ?? "").isEmpty
    }

    init(
        userDefaults: UserDefaults = .standard,
        isSessionOnly: Bool = DeveloperModeManager.isIsolatedMode
    ) {
        self.userDefaults = userDefaults
        self.isSessionOnly = isSessionOnly

        let persistedPreference = isSessionOnly ? false : userDefaults.bool(forKey: Self.defaultsPersistentKey)
        self.stayUnlockedAcrossLaunches = persistedPreference

        if Self.isLaunchFlagEnabled {
            self.isUnlocked = true
        } else if !isSessionOnly && persistedPreference && userDefaults.bool(forKey: Self.defaultsUnlockedKey) {
            self.isUnlocked = true
        } else {
            self.isUnlocked = false
        }
    }

    var hasActiveSimulation: Bool {
        UpdateManager.shared.isSimulatingState
            || PermissionsManager.shared.simulatedAccessibilityGranted != nil
    }

    var simulatedUpdateSizeBytes: Int64 {
        Int64(max(0.1, simulatedUpdateSizeMB) * 1_000_000)
    }

    func effectiveReleaseNotesHTML(for version: String) -> String {
        switch selectedReleaseNotesPreset {
        case .standard:
            return UpdateManager.sampleReleaseNotesHTML(for: version)
        case .longScrollable:
            return """
            <p><strong>Toolbox v\(version) Release Highlights</strong></p>
            <ul>
              <li>Added PIN-gated Developer Tools with Updates, UI &amp; Modules, Events &amp; Taps, HotKeys &amp; Config, and Checks &amp; Diagnostics.</li>
              <li>Centered the dark Sparkle update window directly over Toolbox's main window across all height transitions.</li>
              <li>Added live CoreGraphics layer-0 window stack inspection and Scroll Direction event-tap monitoring.</li>
              <li>Introduced in-memory config checkpoints with flattened key-path diffs against disk and checkpoint state.</li>
            </ul>
            <p><strong>Bug Fixes &amp; Hardening</strong></p>
            <ul>
              <li>Salted SHA-256 PIN verification with brute-force cooldown throttling.</li>
              <li>Preserved Accessibility trust state cleanly when simulating UI permission banners.</li>
              <li>Verified Developer ID code signature, Hardened Runtime flag, CDHash, and Gatekeeper status.</li>
              <li>Improved hotkey registration error surfacing and conflict detection across modules.</li>
            </ul>
            """
        case .custom:
            return customReleaseNotesHTML
        }
    }

    /// Subtle progressive hint shown only after multiple taps on the About Toolbox header.
    var unlockProgressHint: String? {
        guard !isUnlocked, unlockTapCount >= 2 else { return nil }
        let remaining = max(1, Self.requiredUnlockTaps - unlockTapCount)
        return remaining == 1
            ? "1 more click to enter developer PIN"
            : "\(remaining) more clicks to enter developer PIN"
    }

    func remainingLockoutSeconds(relativeTo now: Date = Date()) -> Int {
        guard let pinLockoutUntil, pinLockoutUntil > now else { return 0 }
        return max(1, Int(ceil(pinLockoutUntil.timeIntervalSince(now))))
    }

    /// Records a click on the About Toolbox header. Returns `true` when the PIN prompt is triggered.
    @discardableResult
    func registerAboutHeaderTap() -> Bool {
        guard !isUnlocked else { return false }

        tapResetWorkItem?.cancel()
        unlockTapCount += 1

        if unlockTapCount >= Self.requiredUnlockTaps {
            unlockTapCount = 0
            isPinPromptPresented = true
            return true
        }

        let work = DispatchWorkItem { [weak self] in
            self?.unlockTapCount = 0
        }
        tapResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapResetWindow, execute: work)
        return false
    }

    func dismissPinPrompt() {
        isPinPromptPresented = false
        unlockTapCount = 0
    }

    func verifyPIN(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let digest = SHA256.hash(data: Data((Self.pinSalt + trimmed).utf8))
        let candidateBytes = Array(digest)
        guard candidateBytes.count == Self.expectedPinDigestBytes.count else { return false }
        let diff = zip(candidateBytes, Self.expectedPinDigestBytes).reduce(UInt8(0)) { acc, pair in
            acc | (pair.0 ^ pair.1)
        }
        return diff == 0
    }

    @discardableResult
    func submitPIN(_ candidate: String, now: Date = Date()) -> PinVerificationResult {
        let lockoutRemaining = remainingLockoutSeconds(relativeTo: now)
        if lockoutRemaining > 0 {
            return .lockedOut(remainingSeconds: lockoutRemaining)
        }

        pinLockoutUntil = nil

        if verifyPIN(candidate) {
            failedPinAttempts = 0
            pinLockoutUntil = nil
            isPinPromptPresented = false
            unlock()
            return .unlocked
        }

        failedPinAttempts += 1
        if failedPinAttempts >= Self.maxFailedPinAttempts {
            failedPinAttempts = 0
            pinLockoutUntil = now.addingTimeInterval(Self.pinLockoutDuration)
            return .lockedOut(remainingSeconds: Int(Self.pinLockoutDuration))
        }

        return .wrongPin(remainingAttempts: Self.maxFailedPinAttempts - failedPinAttempts)
    }

    func unlock() {
        tapResetWorkItem?.cancel()
        tapResetWorkItem = nil
        unlockTapCount = 0
        isPinPromptPresented = false
        isUnlocked = true
        if !isSessionOnly && stayUnlockedAcrossLaunches {
            userDefaults.set(true, forKey: Self.defaultsUnlockedKey)
        }
    }

    func lock() {
        tapResetWorkItem?.cancel()
        tapResetWorkItem = nil
        unlockTapCount = 0
        isPinPromptPresented = false
        failedPinAttempts = 0
        pinLockoutUntil = nil
        resetAllSimulations()
        isUnlocked = false
        if !isSessionOnly {
            userDefaults.removeObject(forKey: Self.defaultsUnlockedKey)
        }
    }

    func resetAllSimulations() {
        UpdateManager.shared.clearSimulation()
        PermissionsManager.shared.setSimulatedAccessibilityGranted(nil)
        objectWillChange.send()
    }
}
