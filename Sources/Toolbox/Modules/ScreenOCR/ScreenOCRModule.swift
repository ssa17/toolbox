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

/// Result of the Developer Tools offline OCR pipeline self-check (synthetic sample,
/// no screen capture involved). Session-only.
struct OCRSelfCheckResult: Equatable, Sendable {
    var recognizedText: String
    var qrPayloads: [String]
    var lineCount: Int
    var recognitionDurationMs: Int

    var isEmpty: Bool {
        recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && qrPayloads.isEmpty
    }
}

/// One instrumented stage of the developer live-capture pipeline test.
struct OCRPipelineStage: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pending
        case pass
        case fail
        case skipped
    }

    let id: String
    var name: String
    var status: Status = .pending
    var detail: String?
}

/// Report of one developer pipeline test run (interactive crosshair or full-screen control).
/// The captured file is retained (artifactPath) so it can be inspected or re-OCRed.
struct OCRPipelineReport: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case interactive
        case fullScreen

        var label: String {
            switch self {
            case .interactive: return "Interactive region (crosshair)"
            case .fullScreen: return "Full main screen (control)"
            }
        }
    }

    var kind: Kind
    var stages: [OCRPipelineStage]
    var startedAt: Date
    var artifactPath: String?
    var outputPreview: String?

    var isComplete: Bool { stages.allSatisfy { $0.status != .pending } }
    var hasFailure: Bool { stages.contains { $0.status == .fail } }
}

/// Thin wrapper over the CoreGraphics Screen Recording TCC APIs (macOS 10.15+).
/// `/usr/sbin/screencapture` is the Apple-signed capture binary; macOS attributes its
/// Screen Recording permission to the responsible app (Toolbox) and prompts cleanly,
/// so no custom `CGWindowListCreateImage` capture loop is needed.
@MainActor
enum ScreenCapturePermission {
    /// Holds the most recent uncached `--check-screen-recording` child probe result once available.
    /// `TCC.framework` caches the first `TCCAccessPreflight("kTCCServiceScreenCapture")` call per
    /// process lifetime in its internal dictionary, and `SkyLight` caches via `std::call_once`, so
    /// a fresh `Toolbox --check-screen-recording` subprocess is used to detect live grants/revocations.
    private static var liveProbedValue: Bool? = nil
    private static var isProbeInFlight: Bool = false

    static var isGranted: Bool {
        if let liveProbedValue {
            return liveProbedValue
        }
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    static func probeUncachedAsync(completion: @escaping @MainActor (Bool) -> Void) {
        guard !PermissionsManager.isRunningInDiagnosticMode,
              let executableURL = Bundle.main.executableURL else {
            let current = isGranted
            completion(current)
            return
        }
        guard !isProbeInFlight else { return }
        isProbeInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = executableURL
            proc.arguments = ["--check-screen-recording"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            let granted: Bool
            do {
                try proc.run()
                proc.waitUntilExit()
                granted = (proc.terminationStatus == 0)
            } catch {
                granted = false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isProbeInFlight = false
                    liveProbedValue = granted
                    completion(granted)
                }
            }
        }
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
        PermissionsManager.openSystemSettings(
            primaryURL: PermissionsManager.screenRecordingSettingsURL,
            fallbackURL: PermissionsManager.legacyScreenRecordingSettingsURL
        )
    }
}

@MainActor
final class ScreenOCRModule: NSObject, ToolboxModule, ObservableObject {
    let id = "screen_ocr"
    let name = "Screen OCR"
    let tagline = "Drag-select any area on screen to copy unselectable text or QR codes, completely offline."
    let aboutSummary = "Invokes macOS's interactive crosshair region selector, then runs Apple's on-device Vision OCR and QR/barcode detection locally over the selection. Recognition never leaves your Mac, and the recent-captures list lives only in memory for the current Toolbox session."
    let featureTips = [
        "Press your shortcut (default ⇧ ⌘ 0) and drag a box over any text, screenshot, or dialog to copy it.",
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
    @Published private(set) var isRunningSelfCheck = false
    @Published private(set) var lastSelfCheck: OCRSelfCheckResult?
    @Published private(set) var isRunningPipelineTest = false
    @Published private(set) var pipelineReport: OCRPipelineReport?
    @Published private(set) var recentCaptures: [RecentOCRCapture] = []
    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var isAwaitingScreenPermission: Bool = false

    /// The last capture whose recognition came back empty/failed. Kept on disk (never
    /// deleted on failure) so Developer Tools can re-run the engine on the exact file,
    /// reveal it in Finder, or run `Toolbox --ocr-file <path>` on it.
    @Published private(set) var lastFailedCapturePath: String?
    @Published private(set) var lastFailedCaptureNote: String?
    @Published private(set) var isReanalyzing = false

    /// True while any capture/OCR work is in flight. Includes the developer pipeline
    /// test on purpose: its interactive crosshair must not stack a second crosshair when
    /// the global hotkey fires at the same time.
    var isCaptureInFlight: Bool {
        isCapturing || isRecognizing || isRunningPipelineTest
    }

    let hotKeyName = "screen_ocr.capture"

    static let pendingReopenToastKey = "toolbox.pendingScreenRecordingReadyToastAt"

    private var captureProcess: Process?
    private var pipelineTestProcess: Process?
    private var captureGeneration: UInt64 = 0
    private var pipelineTestGeneration: UInt64 = 0
    private var awaitingScreenGrantDeadline: Date?
    private var recentScreenGrantUntil: Date = .distantPast
    private var screenPermissionPollTask: Task<Void, Never>?
    private var sheetWaitTask: Task<Void, Never>?
    private var hasPromptedScreenThisSession: Bool = false
    private var isScreenRequestInFlight: Bool = false
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?

    /// True while awaiting or right after granting Screen Recording so macOS System Settings'
    /// "Quit & Reopen" button can terminate and relaunch Toolbox even when `dockQuitBehavior == .closeWindow`.
    var shouldAllowSystemQuitAndReopen: Bool {
        isAwaitingScreenPermission || Date() <= recentScreenGrantUntil
    }

    override init() {
        super.init()
        screenRecordingGranted = ScreenCapturePermission.isGranted
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeLiveScreenPermission()
            }
        }
    }

    deinit {
        screenPermissionPollTask?.cancel()
        sheetWaitTask?.cancel()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

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
        cancelPipelineTest()
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
            requestScreenAccess()
            HUDToast.shared.show(
                title: "Screen Recording permission is required",
                symbol: "record.circle",
                tint: .orange
            )
            return
        }

        beginInteractiveCapture()
    }

    private func beginInteractiveCapture() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-ocr-\(UUID().uuidString).png")
        try? FileManager.default.removeItem(at: tempURL)

        captureGeneration &+= 1
        let generation = captureGeneration

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i = interactive region selection, -x = no camera shutter sound
        process.arguments = ["-i", "-x", tempURL.path]

        process.terminationHandler = { [weak self] proc in
            let fileURL = tempURL
            let exitCode = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleCaptureFinished(
                    process: proc,
                    generation: generation,
                    exitCode: exitCode,
                    fileURL: fileURL
                )
            }
        }

        do {
            try process.run()
            captureProcess = process
            isCapturing = true
            ModuleRegistry.shared.notifyChanged()
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

    private func handleCaptureFinished(
        process: Process,
        generation: UInt64,
        exitCode: Int32,
        fileURL: URL
    ) {
        guard generation == captureGeneration, captureProcess === process else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        captureProcess = nil
        isCapturing = false
        ModuleRegistry.shared.notifyChanged()

        // If the module was stopped (disabled, or the app paused) between the user's
        // selection and this handler firing, drop the capture instead of recognizing it
        // and writing to the clipboard.
        guard isRunning else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        // When the user pressed Esc, screencapture exits 0 without writing the file:
        // treat that as a quiet cancellation (no toast, no error). A non-zero exit
        // without a file is logged so failures aren't mistaken for Esc.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try? FileManager.default.removeItem(at: fileURL)
            if exitCode != 0 {
                DeveloperEventLog.shared.record(
                    .ocr,
                    "Screen capture exited with status \(exitCode)",
                    detail: "No file written"
                )
                if config.showToast {
                    HUDToast.shared.show(
                        title: "Screen capture failed (exit \(exitCode))",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
            }
            return
        }

        let outcome = ScreenOCREngine.loadCapturedImage(at: fileURL)

        guard let image = outcome.image else {
            // Decoding failed: KEEP the file as evidence and surface it in Developer Tools.
            lastFailedCapturePath = fileURL.path
            lastFailedCaptureNote = nil
            isRecognizing = false
            DeveloperEventLog.shared.record(
                .ocr,
                "Captured file could not be decoded",
                detail: "\(outcome.failureMessage ?? "unknown decode failure") · file kept: \(fileURL.path)"
            )
            if config.showToast {
                HUDToast.shared.show(
                    title: outcome.failureMessage ?? "Could not read captured region",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
            return
        }
        // Note: the file is deliberately NOT deleted here anymore — the recognition
        // outcome decides. Empty/failed results keep it for diagnosis; success removes it.

        let preserveLineBreaks = config.preserveLineBreaks
        let detectBarcodes = config.detectQRCodes
        let showToast = config.showToast

        isRecognizing = true
        ModuleRegistry.shared.notifyChanged()
        lastImageSize = CGSize(width: image.width, height: image.height)
        let imageBox = ImageBox(image: image)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let prepared = ScreenOCREngine.prepareImage(imageBox.image)
            let result = ScreenOCREngine.recognize(
                in: prepared,
                preserveLineBreaks: preserveLineBreaks,
                detectBarcodes: detectBarcodes
            )
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(
                    result,
                    generation: generation,
                    captureFile: fileURL,
                    showToast: showToast
                )
            }
        }
    }

    /// Diagnostic: re-run the recognition engine on the last retained (failed) capture so
    /// the exact file can be re-inspected from Developer Tools without re-capturing.
    func reanalyzeFailedCapture() {
        guard !isReanalyzing else { return }
        guard let path = lastFailedCapturePath,
              FileManager.default.fileExists(atPath: path) else {
            lastFailedCaptureNote = "No retained capture available — run the hotkey and let it fail first."
            return
        }
        isReanalyzing = true
        ModuleRegistry.shared.notifyChanged()
        let preserveLineBreaks = config.preserveLineBreaks
        let detectBarcodes = config.detectQRCodes
        let fileURL = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = ScreenOCREngine.loadCapturedImage(at: fileURL)
            let note: String
            if let image = outcome.image {
                let fraction = ScreenOCREngine.imageBlackFraction(image)
                let result = ScreenOCREngine.recognize(
                    in: ScreenOCREngine.prepareImage(image),
                    preserveLineBreaks: preserveLineBreaks,
                    detectBarcodes: detectBarcodes
                )
                let preview = result.text.prefix(80)
                note = "\(image.width)x\(image.height) px · near-black \(ScreenOCREngine.percent(fraction)) · \(result.textObservationCount) observation(s)"
                    + (result.engineError.map { " · error: \($0)" } ?? "")
                    + (result.isEmpty ? " · still empty" : " · text: \(preview)")
            } else {
                note = "could not decode retained file (\(outcome.failureMessage ?? "unknown"))"
            }
            Task { @MainActor [weak self] in
                self?.isReanalyzing = false
                self?.lastFailedCaptureNote = note
                ModuleRegistry.shared.notifyChanged()
                DeveloperEventLog.shared.record(.ocr, "Re-analyzed retained capture", detail: note)
            }
        }
    }


    private func handleRecognitionResult(
        _ result: OCRResult,
        generation: UInt64,
        captureFile: URL,
        showToast: Bool
    ) {
        guard generation == captureGeneration else {
            try? FileManager.default.removeItem(at: captureFile)
            return
        }

        isRecognizing = false
        ModuleRegistry.shared.notifyChanged()

        // Recognition runs off the main thread; the module may have been stopped or the
        // app paused while it was in flight. In that case do not touch the clipboard.
        guard isRunning else {
            try? FileManager.default.removeItem(at: captureFile)
            return
        }

        let imageSizeText = "\(lastImageSize?.width ?? 0)x\(lastImageSize?.height ?? 0)"
        let fractionText = result.blackFraction.map { "near-black \(ScreenOCREngine.percent($0))" } ?? "blank: n/a"
        guard !result.isEmpty else {
            // Three distinct failure situations: the region genuinely contained no text,
            // the capture came back *uniform* black (Screen Recording permission failure
            // signature), or the Vision engine itself errored. Note: a dark-themed UI is
            // NOT uniform black, so dark screenshots take the plain no-text path.
            //
            // KEEP the capture file on every failure path — it is the one piece of
            // evidence that pins down exactly what the system returned, and Developer
            // Tools (Reveal / Re-analyze) plus `Toolbox --ocr-file` act on it.
            lastFailedCapturePath = captureFile.path
            lastFailedCaptureNote = nil
            let engineFailed = result.engineError != nil
            DeveloperEventLog.shared.record(
                .ocr,
                engineFailed ? "Vision engine error during recognition"
                    : (result.looksBlank ? "Capture produced a uniform-black image" : "No text found in selection"),
                detail: "image \(imageSizeText) · \(result.textObservationCount) observation(s) · \(fractionText)\(result.engineError.map { " · error: \($0)" } ?? "") · file kept: \(captureFile.path)"
            )
            if showToast {
                let title: String
                let symbol: String
                if engineFailed {
                    title = "Recognition failed — open Developer Tools → Screen OCR"
                    symbol = "exclamationmark.triangle.fill"
                } else if result.looksBlank {
                    title = "Selection looks black — check Screen Recording permission"
                    symbol = "record.circle.badge.exclamationmark"
                } else {
                    title = "No text found in selection"
                    symbol = "text.viewfinder"
                }
                HUDToast.shared.show(title: title, symbol: symbol, tint: .orange)
            }
            return
        }

        // Success: nothing to diagnose, clean up the file.
        try? FileManager.default.removeItem(at: captureFile)

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
        captureGeneration &+= 1
        captureProcess?.terminate()
        captureProcess = nil
        isCapturing = false
        isRecognizing = false
    }

    // MARK: - State

    /// Size of the most recent capture image, for developer-event diagnostics.
    private var lastImageSize: CGSize?

    // MARK: - Screen Recording Permission

    func refreshScreenPermission() {
        applyScreenPermission(ScreenCapturePermission.isGranted)
    }

    func probeLiveScreenPermission() {
        ScreenCapturePermission.probeUncachedAsync { [weak self] granted in
            self?.applyScreenPermission(granted)
        }
    }

    private func applyScreenPermission(_ granted: Bool) {
        let wasGranted = screenRecordingGranted
        if granted != screenRecordingGranted {
            screenRecordingGranted = granted
        }
        if granted {
            let awaiting = awaitingScreenGrantDeadline.map { Date() <= $0 } ?? false
            stopAwaitingScreenGrant()
            if awaiting && !wasGranted && !PermissionsManager.isRunningInDiagnosticMode {
                recentScreenGrantUntil = Date().addingTimeInterval(60)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.pendingReopenToastKey)
                waitForSystemSettingsSheetAndReturnToApp()
            }
        } else if let deadline = awaitingScreenGrantDeadline, Date() > deadline {
            stopAwaitingScreenGrant()
        }
    }

    /// Waits for macOS System Settings' "Quit & Reopen / Later" sheet to be dismissed before
    /// focusing Toolbox, so Toolbox never jumps in front of the macOS dialog while the user is
    /// choosing "Quit & Reopen" or "Later".
    private func waitForSystemSettingsSheetAndReturnToApp() {
        sheetWaitTask?.cancel()
        sheetWaitTask = Task { @MainActor [weak self] in
            // Give System Settings ~350ms to present its post-toggle "Quit & Reopen / Later" sheet.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }

            let deadline = Date().addingTimeInterval(30)
            while !Task.isCancelled && Date() <= deadline {
                let hasSheet = PermissionsManager.hasSystemSettingsAlertSheet()
                    || PermissionsManager.hasSystemPermissionPromptWindow()
                if !hasSheet {
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if Task.isCancelled { return }
            guard let self, self.screenRecordingGranted else { return }
            UserDefaults.standard.removeObject(forKey: Self.pendingReopenToastKey)
            MainWindowController.shared.show(destination: nil)
            HUDToast.shared.show(
                title: "Screen Recording granted — Screen OCR is ready",
                symbol: "checkmark.shield.fill",
                tint: .green
            )
        }
    }

    func requestScreenAccess() {
        refreshScreenPermission()
        guard !screenRecordingGranted else { return }
        guard !isScreenRequestInFlight else { return }

        beginAwaitingScreenGrant()

        guard !PermissionsManager.isRunningInDiagnosticMode else { return }

        if hasPromptedScreenThisSession {
            openScreenSettings()
            return
        }

        hasPromptedScreenThisSession = true
        isScreenRequestInFlight = true
        if PermissionsManager.hasSystemPermissionPromptWindow() {
            isScreenRequestInFlight = false
            return
        }
        _ = ScreenCapturePermission.requestAccess()

        let appearDeadline = Date().addingTimeInterval(1.1)
        func checkPromptAppearance() {
            MainActor.assumeIsolated {
                self.probeLiveScreenPermission()
                if self.screenRecordingGranted || PermissionsManager.hasSystemPermissionPromptWindow() {
                    self.isScreenRequestInFlight = false
                    return
                }
                if Date() >= appearDeadline {
                    self.isScreenRequestInFlight = false
                    self.openScreenSettings()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        checkPromptAppearance()
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            checkPromptAppearance()
        }
    }

    func openScreenSettings() {
        beginAwaitingScreenGrant()
        ScreenCapturePermission.openSystemSettings()
    }

    private func beginAwaitingScreenGrant() {
        isAwaitingScreenPermission = true
        awaitingScreenGrantDeadline = Date().addingTimeInterval(120)
        screenPermissionPollTask?.cancel()
        screenPermissionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled { return }
                guard let self,
                      let deadline = self.awaitingScreenGrantDeadline,
                      Date() <= deadline else {
                    self?.stopAwaitingScreenGrant()
                    return
                }
                self.probeLiveScreenPermission()
                if self.screenRecordingGranted {
                    return
                }
            }
        }
    }

    private func stopAwaitingScreenGrant() {
        isAwaitingScreenPermission = false
        awaitingScreenGrantDeadline = nil
        screenPermissionPollTask?.cancel()
        screenPermissionPollTask = nil
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

    // MARK: - Developer Self-Check (non-interactive)

    /// Developer Tools hook: renders a synthetic sample (text lines + a real QR code)
    /// offscreen and runs the exact same engine path a real capture uses
    /// (`prepareImage` → `recognize`), using the module's current recognition settings.
    /// No Screen Recording permission and no crosshair interaction required.
    func runSelfCheck() {
        guard !isRunningSelfCheck, !isCaptureInFlight else { return }
        isRunningSelfCheck = true
        ModuleRegistry.shared.notifyChanged()
        DeveloperEventLog.shared.record(.ocr, "Developer OCR self-check started")

        let preserveLineBreaks = config.preserveLineBreaks
        let detectBarcodes = config.detectQRCodes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let sample = ScreenOCREngine.makeSelfCheckSample() else {
                Task { @MainActor [weak self] in
                    self?.finishSelfCheckFailed("Could not render the sample image")
                }
                return
            }
            let prepared = ScreenOCREngine.prepareImage(sample)
            let start = DispatchTime.now()
            let result = ScreenOCREngine.recognize(
                in: prepared,
                preserveLineBreaks: preserveLineBreaks,
                detectBarcodes: detectBarcodes
            )
            let durationMs = Int(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Task { @MainActor [weak self] in
                self?.finishSelfCheck(result, durationMs: durationMs)
            }
        }
    }

    private func finishSelfCheck(_ result: OCRResult, durationMs: Int) {
        isRunningSelfCheck = false
        ModuleRegistry.shared.notifyChanged()
        let summary = OCRSelfCheckResult(
            recognizedText: result.text,
            qrPayloads: result.qrPayloads,
            lineCount: result.lineCount,
            recognitionDurationMs: durationMs
        )
        lastSelfCheck = summary
        let detail = "\(summary.lineCount) line(s) · \(summary.qrPayloads.count) QR payload(s) · \(summary.recognitionDurationMs) ms"
        DeveloperEventLog.shared.record(
            .ocr,
            summary.isEmpty ? "Developer OCR self-check: no output" : "Developer OCR self-check passed",
            detail: detail
        )
    }

    private func finishSelfCheckFailed(_ message: String) {
        isRunningSelfCheck = false
        ModuleRegistry.shared.notifyChanged()
        lastSelfCheck = OCRSelfCheckResult(recognizedText: message, qrPayloads: [], lineCount: 0, recognitionDurationMs: 0)
        DeveloperEventLog.shared.record(.ocr, "Developer OCR self-check failed", detail: message)
    }

    /// Clears the last self-check result (used by the snapshot runner for deterministic renders).
    func clearSelfCheckResults() {
        lastSelfCheck = nil
    }

    // MARK: - Developer Live Pipeline Test (stage-by-stage)

    /// Runs the REAL capture pipeline — the same `screencapture` binary, the same load →
    /// prepare → recognize path production uses — and records every stage in
    /// `pipelineReport`. The captured file is RETAINED (artifactPath) so it can be
    /// revealed in Finder or re-OCRed via `Toolbox --ocr-file`.
    /// - `interactive: true` reproduces the hotkey flow (crosshair drag, Esc cancels);
    ///   `false` runs a non-interactive full-main-screen control capture.
    func runPipelineTest(interactive: Bool) {
        guard !isRunningPipelineTest, !isCaptureInFlight else { return }

        pipelineTestGeneration &+= 1
        let generation = pipelineTestGeneration

        // Clear artifacts from previous test runs so the temp dir doesn't accumulate.
        let tempDir = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) {
            for item in items where item.hasPrefix("toolbox-ocr-pipetest-") {
                try? FileManager.default.removeItem(at: tempDir.appendingPathComponent(item))
            }
        }

        let fileURL = tempDir.appendingPathComponent("toolbox-ocr-pipetest-\(UUID().uuidString).png")
        try? FileManager.default.removeItem(at: fileURL)

        pipelineReport = OCRPipelineReport(
            kind: interactive ? .interactive : .fullScreen,
            stages: [
                OCRPipelineStage(id: "permission", name: "Screen Recording Permission"),
                OCRPipelineStage(id: "tempdir", name: "Temp Directory"),
                OCRPipelineStage(id: "launch", name: "Launch screencapture"),
                OCRPipelineStage(id: "file", name: "Capture File"),
                OCRPipelineStage(id: "decode", name: "Image Decode"),
                OCRPipelineStage(id: "prepare", name: "Image Prep"),
                OCRPipelineStage(id: "vision", name: "Vision Recognition"),
                OCRPipelineStage(id: "barcode", name: "QR / Barcode Detection"),
                OCRPipelineStage(id: "output", name: "Combined Output")
            ],
            startedAt: Date(),
            artifactPath: nil,
            outputPreview: nil
        )
        isRunningPipelineTest = true
        ModuleRegistry.shared.notifyChanged()
        DeveloperEventLog.shared.record(.ocr, "Pipeline test started", detail: pipelineReport!.kind.label)

        // Stage 1: permission (live preflight — the thing that blackens captures when missing).
        let granted = ScreenCapturePermission.isGranted
        refreshScreenPermission()
        updatePipelineStage("permission", granted ? .pass : .fail,
                            granted ? "granted" : "NOT granted — macOS will render other apps' content black")

        // Stage 2: temp dir identity + writability (a child process must be able to write it).
        let probe = tempDir.appendingPathComponent("toolbox-ocr-write-probe-\(UUID().uuidString)")
        let writable = (try? Data([1]).write(to: probe)) != nil
        try? FileManager.default.removeItem(at: probe)
        updatePipelineStage("tempdir", writable ? .pass : .fail,
                            "\(tempDir.path)\(writable ? "" : " — not writable!")")

        // Stage 3: launch the real binary with the same arguments production uses.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let launchArgs = (interactive ? ["-i", "-x"] : ["-x"]) + [fileURL.path]
        process.arguments = launchArgs
        do {
            try process.run()
            pipelineTestProcess = process
            updatePipelineStage("launch", .pass, "pid \(process.processIdentifier) · \(launchArgs.joined(separator: " "))")
        } catch {
            updatePipelineStage("launch", .fail, error.localizedDescription)
            markStagesNotReached(from: "file")
            finishPipelineTestRun()
            return
        }

        process.terminationHandler = { [weak self] proc in
            let exitCode = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handlePipelineTestProcessFinished(
                    process: proc,
                    generation: generation,
                    exitCode: exitCode,
                    fileURL: fileURL
                )
            }
        }
    }

    private func updatePipelineStage(_ id: String, _ status: OCRPipelineStage.Status, _ detail: String?) {
        guard let idx = pipelineReport?.stages.firstIndex(where: { $0.id == id }) else { return }
        pipelineReport?.stages[idx].status = status
        pipelineReport?.stages[idx].detail = detail
    }

    private func markStagesNotReached(from id: String) {
        guard var report = pipelineReport else { return }
        var reached = false
        for i in report.stages.indices {
            if report.stages[i].id == id { reached = true }
            if reached, report.stages[i].status == .pending {
                report.stages[i].status = .skipped
                report.stages[i].detail = "not reached"
            }
        }
        pipelineReport = report
    }

    private func handlePipelineTestProcessFinished(
        process: Process,
        generation: UInt64,
        exitCode: Int32,
        fileURL: URL
    ) {
        guard generation == pipelineTestGeneration, pipelineTestProcess === process else {
            return
        }
        pipelineTestProcess = nil
        let fm = FileManager.default

        guard fm.fileExists(atPath: fileURL.path) else {
            if exitCode == 0, pipelineReport?.kind == .interactive {
                updatePipelineStage("file", .skipped, "no file written — crosshair cancelled (Esc)")
            } else {
                updatePipelineStage("file", .fail, "screencapture exited \(exitCode) without writing a file")
            }
            markStagesNotReached(from: "file")
            finishPipelineTestRun()
            return
        }

        // Stage 4: file on disk (retained for inspection, unlike production which deletes it).
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        updatePipelineStage("file", .pass, "\(fileURL.lastPathComponent) · \(Int(size)) bytes (kept)")
        pipelineReport?.artifactPath = fileURL.path

        // Stage 5: decode.
        let load = ScreenOCREngine.loadCapturedImage(at: fileURL)
        guard load.kind == .loaded, let image = load.image else {
            updatePipelineStage("decode", .fail, load.failureMessage ?? "could not decode")
            markStagesNotReached(from: "prepare")
            finishPipelineTestRun()
            return
        }
        let colorSpace = image.colorSpace?.name.map { $0 as String } ?? "nil"
        updatePipelineStage(
            "decode", .pass,
            "\(image.width)x\(image.height) px · \(colorSpace) · alpha=\(image.alphaInfo.rawValue) · near-black \(ScreenOCREngine.percent(ScreenOCREngine.imageBlackFraction(image)))"
        )

        // Stage 6: prep (2x upscale for tiny regions).
        let prepared = ScreenOCREngine.prepareImage(image)
        updatePipelineStage(
            "prepare", prepared === image ? .skipped : .pass,
            prepared === image ? "no upscale (height ≥ 32)" : "2x → \(prepared.width)x\(prepared.height)"
        )

        // Stages 7–9: recognition off the main thread, exactly like production.
        let preserveLineBreaks = config.preserveLineBreaks
        let detectBarcodes = config.detectQRCodes
        let imageBox = ImageBox(image: prepared)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = DispatchTime.now()
            let result = ScreenOCREngine.recognize(
                in: imageBox.image,
                preserveLineBreaks: preserveLineBreaks,
                detectBarcodes: detectBarcodes
            )
            let durationMs = Int(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Task { @MainActor [weak self] in
                guard let self, self.pipelineTestGeneration == generation else { return }
                if let engineError = result.engineError {
                    self.updatePipelineStage("vision", .fail, "engine error: \(engineError)")
                } else {
                    self.updatePipelineStage(
                        "vision", .pass,
                        "\(result.textObservationCount) observation(s) · \(durationMs) ms\(result.blackFraction.map { " · near-black \(ScreenOCREngine.percent($0))" } ?? "")"
                    )
                }
                if detectBarcodes {
                    self.updatePipelineStage("barcode", .pass, "\(result.qrPayloads.count) payload(s)")
                } else {
                    self.updatePipelineStage("barcode", .skipped, "disabled in Screen OCR settings")
                }
                if result.isEmpty {
                    let why: String
                    if result.engineError != nil { why = "engine error (see Vision stage)" }
                    else if result.looksBlank { why = "image is uniform-black — Screen Recording permission failure signature" }
                    else { why = "no text or QR in the captured region" }
                    self.updatePipelineStage("output", .fail, "empty — \(why)")
                } else {
                    self.updatePipelineStage("output", .pass, "\(result.lineCount) line(s)")
                    self.pipelineReport?.outputPreview = result.clipboardString
                }
                self.finishPipelineTestRun()
            }
        }
    }

    private func finishPipelineTestRun() {
        isRunningPipelineTest = false
        let failures = pipelineReport?.stages.filter { $0.status == .fail }.count ?? 0
        let summary = pipelineReport?.kind.label ?? ""
        DeveloperEventLog.shared.record(
            .ocr,
            failures == 0 ? "Pipeline test completed (all stages OK)" : "Pipeline test found \(failures) failing stage(s)",
            detail: summary
        )
        ModuleRegistry.shared.notifyChanged()
    }

    /// Tears down an in-flight pipeline test (used when the module stops).
    func cancelPipelineTest() {
        guard isRunningPipelineTest || pipelineTestProcess != nil else { return }
        pipelineTestGeneration &+= 1
        pipelineTestProcess?.terminate()
        pipelineTestProcess = nil
        isRunningPipelineTest = false
        if var report = pipelineReport {
            for i in report.stages.indices where report.stages[i].status == .pending {
                report.stages[i].status = .skipped
                report.stages[i].detail = "cancelled"
            }
            pipelineReport = report
        }
        ModuleRegistry.shared.notifyChanged()
    }

    /// Clears the pipeline report (snapshot runner determinism hook).
    func clearPipelineReport() {
        pipelineReport = nil
    }

    /// Test/snapshot hook to seed a pipeline report render.
    func setPipelineReportForTesting(_ report: OCRPipelineReport?) {
        pipelineReport = report
    }

    /// Removes stale capture artifacts from the previous session (production captures,
    /// pipeline-test artifacts, CLI captures) from the temp directory. Safe to run at
    /// launch: no capture can be in flight at that point, and every `toolbox-ocr-*` file
    /// is session-scoped by design. `nonisolated` so the app delegate can call it.
    nonisolated static func sweepStaleTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) else { return }
        for item in items where item.hasPrefix("toolbox-ocr-") {
            try? FileManager.default.removeItem(at: tempDir.appendingPathComponent(item))
        }
    }

    /// Test/snapshot hook to seed the failed-capture evidence render.
    func setLastFailedCaptureForTesting(path: String?, note: String? = nil) {
        lastFailedCapturePath = path
        lastFailedCaptureNote = note
    }
}
