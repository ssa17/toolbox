import AppKit
import ApplicationServices

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var isAccessibilityGranted: Bool = false
    var onAccessibilityChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    private init() {
        isAccessibilityGranted = AXIsProcessTrusted()

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
        let current = AXIsProcessTrusted()
        if current != isAccessibilityGranted {
            isAccessibilityGranted = current
            onAccessibilityChanged?(current)
        }
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
