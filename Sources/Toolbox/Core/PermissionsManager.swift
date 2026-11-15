import AppKit
import ApplicationServices

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published private(set) var simulatedAccessibilityGranted: Bool? = nil
    var onAccessibilityChanged: ((Bool) -> Void)?

    private var lastActualAccessibilityGranted: Bool = false
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    var actualAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private init() {
        let actual = AXIsProcessTrusted()
        lastActualAccessibilityGranted = actual
        isAccessibilityGranted = actual

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        let actual = AXIsProcessTrusted()
        let actualChanged = actual != lastActualAccessibilityGranted
        lastActualAccessibilityGranted = actual

        let effective = simulatedAccessibilityGranted ?? actual
        if effective != isAccessibilityGranted {
            isAccessibilityGranted = effective
        }

        if actualChanged {
            onAccessibilityChanged?(actual)
        }
    }

    /// Overrides the UI-reported Accessibility status in-memory for Developer Tools previews.
    /// Does not modify real macOS TCC trust or background event taps.
    func setSimulatedAccessibilityGranted(_ simulated: Bool?) {
        simulatedAccessibilityGranted = simulated
        refresh()
    }

    /// Trigger the system Accessibility prompt ONLY when the user explicitly clicks Grant.
    func promptAndOpenSettings() {
        refresh()
        guard !isAccessibilityGranted else { return }

        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
        if !isAccessibilityGranted {
            openAccessibilitySettings()
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Clears any stale TCC entry (e.g. from an earlier unsigned dev build) and re-prompts.
    func resetAndRegrantAccessibility() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            promptAndOpenSettings()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        try? process.run()
        process.waitUntilExit()
        refresh()
        promptAndOpenSettings()
    }
}
