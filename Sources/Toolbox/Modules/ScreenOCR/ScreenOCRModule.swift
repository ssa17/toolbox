import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Session-only record of a successful capture. Never persisted to disk (privacy).
struct RecentOCRCapture: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var lineCount: Int
    var isQR: Bool
    var createdAt: Date
}

/// Thin wrapper over the CoreGraphics Screen Recording TCC APIs (macOS 10.15+).
/// `/usr/sbin/screencapture` is the Apple-signed capture binary; macOS attributes its
/// Screen Recording permission to the responsible app (Toolbox) and prompts cleanly,
/// so no custom `CGWindowListCreateImage` capture loop is needed.
@MainActor
enum ScreenCapturePermission {
    /// `CGPreflightScreenCaptureAccess` is macOS 10.15+; before that there was no
    /// Screen Recording gate, so treat older systems as granted.
    static var isGranted: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// Triggers the system "Toolbox would like to record this computer's screen" prompt.
    @discardableResult
    static func requestAccess() -> Bool {
        if #available(macOS 10.15, *) {
            return CGRequestScreenCaptureAccess()
        }
        return true
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class ScreenOCRModule: NSObject, ToolboxModule, ObservableObject {
    let id = "screen_ocr"
    let name = "Screen OCR"
    let tagline = "Drag-select any area on screen to copy unselectable text or QR codes, completely offline."
    let aboutSummary = "Invokes macOS's interactive crosshair region selector, then runs Apple's on-device Vision OCR and QR/barcode detection locally over the selection. Recognition never leaves your Mac, and the recent-captures list lives only in memory for the current Toolbox session."
    let featureTips = [
        "Press your shortcut (default ⌃ ⌥ ⌘ O) and drag a box over any text, screenshot, or dialog to copy it.",
        "Works on unselectable text inside videos, PDFs, simulators, and other apps' windows, with no network involved.",
        "QR and barcode detection runs in the same pass, so pointing at a QR code copies its payload.",
        "Up to 10 recent captures are kept in memory for the session and are never written to disk."
    ]
    let symbolName = "text.viewfinder"
    let accentColor = Color.mint
    let category: ModuleCategory = .developer
    let requiresAccessibility = false

    static let maxRecentCaptures = 10

    @Published private(set) var config: ScreenOCRConfig = ScreenOCRConfig()
    private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var recentCaptures: [RecentOCRCapture] = []
    @Published private(set) var screenRecordingGranted: Bool = false

    var isCaptureInFlight: Bool {
        isCapturing || isRecognizing
    }

    let hotKeyName = "screen_ocr.capture"

    private var captureProcess: Process?

    // MARK: - ToolboxModule

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.screenOCR.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.screenOCR.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.screenOCR.shortcut.isEmpty ? nil : config.screenOCR.shortcut.displayString
    }

    func statusText(in config: ToolboxConfig, accessibilityGranted: Bool) -> String {
        if !isEnabled(in: config) { return "Disabled" }
        if !config.general.appEnabled { return "Paused" }
        if !screenRecordingGranted { return "Needs Screen Access" }
        return isRunning ? "Active" : "Standby"
    }

    func start() {
        guard !isRunning else { return }
        registerHotKey()
        isRunning = true
        refreshScreenPermission()
    }

    func stop() {
        HotKeyManager.shared.unregister(name: hotKeyName)
        cancelActiveCapture()
        isRunning = false
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.screenOCR

        // The module must never run while the whole app is paused, even if its own
        // enabled flag is true (the registry normally enforces this via stop()).
        if config.enabled && fullConfig.general.appEnabled {
            if !isRunning {
                start()
            } else {
                registerHotKey()
                refreshScreenPermission()
            }
        } else if isRunning {
            stop()
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(ScreenOCRSettingsView(module: self))
    }

    // MARK: - Hotkey

    func registerHotKey() {
        HotKeyManager.shared.register(name: hotKeyName, shortcut: config.shortcut) { [weak self] in
            self?.captureRegion()
        }
    }

    // MARK: - Capture Flow

    /// Public entry point (global hotkey, Settings button, or menu bar).
    /// Guards against stacked crosshair sessions and checks Screen Recording permission first.
    func captureRegion() {
        guard !isCaptureInFlight else { return }

        let fullConfig = ConfigManager.shared.config
        guard isEnabled(in: fullConfig), fullConfig.general.appEnabled else { return }

        refreshScreenPermission()
        guard screenRecordingGranted else {
            _ = ScreenCapturePermission.requestAccess()
            if config.showToast {
                HUDToast.shared.show(
                    title: "Screen Recording permission is required",
                    symbol: "record.circle",
                    tint: .orange
                )
            }
            return
        }

        beginInteractiveCapture()
    }

    private func beginInteractiveCapture() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-ocr-\(UUID().uuidString).png")
        try? FileManager.default.removeItem(at: tempURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i = interactive region selection, -x = no camera shutter sound
        process.arguments = ["-i", "-x", tempURL.path]

        process.terminationHandler = { [weak self] _ in
            let fileURL = tempURL
            Task { @MainActor [weak self] in
                self?.handleCaptureFinished(fileURL: fileURL)
            }
        }

        do {
            try process.run()
            captureProcess = process
            isCapturing = true
            DeveloperEventLog.shared.record(.ocr, "Interactive region capture started")
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            isCapturing = false
            HUDToast.shared.show(
                title: "Could not start screen capture",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    private func handleCaptureFinished(fileURL: URL) {
        captureProcess = nil
        isCapturing = false

        // When the user pressed Esc, screencapture exits without writing the file:
        // treat that as a quiet cancellation (no toast, no error).
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let outcome = ScreenOCREngine.loadCapturedImage(at: fileURL)
        // Never let a screenshot linger on disk, even when decoding fails.
        try? FileManager.default.removeItem(at: fileURL)

        guard let image = outcome.image else {
            isRecognizing = false
            if config.showToast {
                HUDToast.shared.show(
                    title: outcome.failureMessage ?? "Could not read captured region",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
            return
        }

        let level = config.recognitionLevel
        let preserveLineBreaks = config.preserveLineBreaks
        let detectBarcodes = config.detectQRCodes
        let showToast = config.showToast

        isRecognizing = true
        let imageBox = ImageBox(image: image)

        Task.detached(priority: .userInitiated) {
            let prepared = ScreenOCREngine.prepareImage(imageBox.image)
            let result = ScreenOCREngine.recognize(
                in: prepared,
                recognitionLevel: level,
                preserveLineBreaks: preserveLineBreaks,
                detectBarcodes: detectBarcodes
            )
            await MainActor.run { [weak self] in
                self?.handleRecognitionResult(result, showToast: showToast)
            }
        }
    }

    private func handleRecognitionResult(_ result: OCRResult, showToast: Bool) {
        isRecognizing = false

        guard !result.isEmpty else {
            if showToast {
                HUDToast.shared.show(
                    title: "No text found in selection",
                    symbol: "text.viewfinder",
                    tint: .orange
                )
            }
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.clipboardString, forType: .string)

        if showToast {
            HUDToast.shared.show(
                title: result.toastSummary,
                symbol: result.qrPayloads.isEmpty ? "text.viewfinder" : "qrcode",
                tint: .mint
            )
        }

        appendRecent(result)
        DeveloperEventLog.shared.record(.ocr, result.toastSummary, detail: "\(result.text.count) chars")
    }

    /// Tears down any in-flight capture (used when the module stops or the app pauses).
    func cancelActiveCapture() {
        captureProcess?.terminate()
        captureProcess = nil
        isCapturing = false
        isRecognizing = false
    }

    // MARK: - Screen Recording Permission

    func refreshScreenPermission() {
        let granted = ScreenCapturePermission.isGranted
        if granted != screenRecordingGranted {
            screenRecordingGranted = granted
        }
    }

    func requestScreenAccess() {
        _ = ScreenCapturePermission.requestAccess()
        refreshScreenPermission()
    }

    func openScreenSettings() {
        ScreenCapturePermission.openSystemSettings()
    }

    /// Test hook to force the Screen Recording permission UI state.
    func setScreenRecordingGrantedForTesting(_ granted: Bool) {
        screenRecordingGranted = granted
    }

    // MARK: - Recent Captures (session only, in-memory)

    func appendRecent(_ result: OCRResult) {
        let capture = RecentOCRCapture(
            id: UUID().uuidString,
            text: result.clipboardString,
            lineCount: result.lineCount,
            isQR: result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !result.qrPayloads.isEmpty,
            createdAt: Date()
        )
        recentCaptures.insert(capture, at: 0)
        if recentCaptures.count > Self.maxRecentCaptures {
            recentCaptures = Array(recentCaptures.prefix(Self.maxRecentCaptures))
        }
    }

    func copyRecent(_ capture: RecentOCRCapture) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(capture.text, forType: .string)
        if config.showToast {
            HUDToast.shared.show(
                title: "Copied to clipboard",
                symbol: "doc.on.clipboard",
                tint: .mint
            )
        }
    }

    func clearRecentCaptures() {
        recentCaptures.removeAll()
    }

    /// Test/snapshot hook to seed the in-memory recent list.
    func replaceRecentCaptures(_ captures: [RecentOCRCapture]) {
        recentCaptures = captures
    }
}
