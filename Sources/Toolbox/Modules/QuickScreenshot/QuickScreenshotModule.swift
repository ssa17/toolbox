import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

@MainActor
final class QuickScreenshotModule: NSObject, ToolboxModule, ObservableObject {
    let id = "quick_screenshot"
    let name = "Quick Screenshot"
    let tagline = "Capture any area or window into a fast floating editor to annotate, redact secrets, copy to clipboard, or share."
    let aboutSummary = "Invokes macOS's interactive area/window capture, opens a native-resolution Quick Editor with arrows, shapes, step badges, crop, and irreversible solid or pixelated redactions, plus on-device Vision Auto-Redact for API keys and PII. Flattened copies write directly to the clipboard (and Toolbox's Clipboard Image History) or save cleanly to PNG/JPEG."
    let featureTips = [
        "Press your shortcut (default ⌃ ⌥ ⌘ 5) and drag an area, or press Space to snap a window; Esc cancels cleanly.",
        "Use Auto-Redact to locally scan for emails, API keys, GitHub/AWS tokens, JWTs, and cards, then review each match before copying.",
        "Single-key tools inside the editor: S Select, A Arrow, R Rect, E Ellipse, H Highlight, T Text, N Number, X Redact, C Crop."
    ]
    let symbolName = "camera.viewfinder"
    let accentColor = Color.red
    let category: ModuleCategory = .productivity
    let requiresAccessibility = false

    static let maxOpenEditors = 5
    nonisolated static let privateTempFolderName = "toolbox-shot-private"

    @Published private(set) var config: QuickScreenshotConfig = QuickScreenshotConfig()
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var isAwaitingScreenPermission: Bool = false
    @Published private(set) var openEditorCount: Int = 0

    let hotKeyName = "quick_screenshot.capture"

    var isCaptureInFlight: Bool {
        isCapturing
    }

    var shouldAllowSystemQuitAndReopen: Bool {
        isAwaitingScreenPermission || Date() <= recentScreenGrantUntil
    }

    private var captureProcess: Process?
    private var captureGeneration: UInt64 = 0
    private var captureOriginApp: NSRunningApplication?
    private var editorControllers: [QuickScreenshotEditorWindowController] = []
    private var previewPanel: NSPanel?
    private var previewDismissTask: Task<Void, Never>?

    private var awaitingScreenGrantDeadline: Date?
    private var recentScreenGrantUntil: Date = .distantPast
    private var screenPermissionPollTask: Task<Void, Never>?
    private var sheetWaitTask: Task<Void, Never>?
    private var hasPromptedScreenThisSession: Bool = false
    private var isScreenRequestInFlight: Bool = false
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?

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
        previewDismissTask?.cancel()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    // MARK: - ToolboxModule

    func isEnabled(in config: ToolboxConfig) -> Bool {
        config.quickScreenshot.enabled
    }

    func setEnabled(_ enabled: Bool, in config: inout ToolboxConfig) {
        config.quickScreenshot.enabled = enabled
    }

    func shortcutText(in config: ToolboxConfig) -> String? {
        config.quickScreenshot.shortcut.isEmpty ? nil : config.quickScreenshot.shortcut.displayString
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
        dismissQuickPreview()
        isRunning = false
    }

    func reload(with fullConfig: ToolboxConfig) {
        self.config = fullConfig.quickScreenshot

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
        AnyView(QuickScreenshotSettingsView(module: self))
    }

    // MARK: - Hotkey

    func registerHotKey() {
        HotKeyManager.shared.register(name: hotKeyName, shortcut: config.shortcut) { [weak self] in
            self?.captureRegion()
        }
    }

    // MARK: - Capture Flow

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
        let tempDir: URL
        do {
            tempDir = try Self.ensurePrivateTempDirectory()
        } catch {
            HUDToast.shared.show(
                title: "Could not prepare private capture folder",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
            return
        }

        let tempURL = tempDir.appendingPathComponent("toolbox-shot-\(UUID().uuidString).png")
        try? FileManager.default.removeItem(at: tempURL)

        captureGeneration &+= 1
        let generation = captureGeneration
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            captureOriginApp = frontApp
        } else {
            captureOriginApp = nil
        }

        var args = ["-i", "-x"]
        if config.omitWindowShadow {
            args.append("-o")
        }
        args.append(tempURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args

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
            DeveloperEventLog.shared.record(.quickScreenshot, "Interactive screenshot capture started")
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
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        guard generation == captureGeneration, captureProcess === process else {
            return
        }

        let originApp = captureOriginApp
        captureOriginApp = nil
        captureProcess = nil
        isCapturing = false
        ModuleRegistry.shared.notifyChanged()

        // If disabled or paused mid-flight, discard immediately without touching clipboard or UI.
        guard isRunning,
              ConfigManager.shared.config.general.appEnabled,
              isEnabled(in: ConfigManager.shared.config) else {
            DeveloperEventLog.shared.record(.quickScreenshot, "Discarded capture (module stopped mid-flight)")
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if exitCode != 0 {
                DeveloperEventLog.shared.record(
                    .quickScreenshot,
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

        // Enforce owner-only 0600 permissions on the captured file before reading.
        _ = chmod(fileURL.path, 0o600)

        let outcome = ScreenOCREngine.loadCapturedImage(at: fileURL)
        guard let image = outcome.image else {
            DeveloperEventLog.shared.record(
                .quickScreenshot,
                "Captured file could not be decoded",
                detail: outcome.failureMessage ?? "unknown decode failure"
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

        if ScreenOCREngine.imageLooksBlank(image) {
            probeLiveScreenPermission()
            if !screenRecordingGranted {
                if config.showToast {
                    HUDToast.shared.show(
                        title: "Capture looks black — check Screen Recording permission",
                        symbol: "record.circle.badge.exclamationmark",
                        tint: .orange
                    )
                }
                return
            }
        }

        DeveloperEventLog.shared.record(
            .quickScreenshot,
            "Captured screenshot",
            detail: "\(image.width)x\(image.height) px"
        )

        if config.openEditorAfterCapture {
            openEditor(for: image, previousFrontmostApp: originApp)
        } else {
            let copied = ScreenshotRenderer.copyToPasteboard(image)
            if copied && config.showToast {
                HUDToast.shared.show(
                    title: "Screenshot copied to clipboard",
                    symbol: "camera.viewfinder",
                    tint: .red
                )
            }
            showQuickPreview(for: image, previousFrontmostApp: originApp)
        }
    }

    func cancelActiveCapture() {
        captureGeneration &+= 1
        captureOriginApp = nil
        captureProcess?.terminate()
        captureProcess = nil
        isCapturing = false
    }

    // MARK: - Editor Window Management

    @discardableResult
    func openEditor(
        for image: CGImage,
        previousFrontmostApp: NSRunningApplication? = nil
    ) -> QuickScreenshotEditorWindowController? {
        dismissQuickPreview()

        if editorControllers.count >= Self.maxOpenEditors {
            if let cleanIdx = editorControllers.firstIndex(where: { !$0.session.hasUnexportedChanges }) {
                let oldestClean = editorControllers[cleanIdx]
                oldestClean.forceClose()
            } else {
                HUDToast.shared.show(
                    title: "Close or save an open screenshot editor first (max \(Self.maxOpenEditors))",
                    symbol: "rectangle.stack.badge.minus",
                    tint: .orange
                )
                editorControllers.last?.presentEditor()
                return nil
            }
        }

        let controller = QuickScreenshotEditorWindowController(
            image: image,
            config: config,
            previousFrontmostApp: previousFrontmostApp,
            onClosed: { [weak self] closed in
                self?.removeEditorController(closed)
            }
        )
        editorControllers.append(controller)
        openEditorCount = editorControllers.count

        if !PermissionsManager.isRunningInDiagnosticMode {
            controller.presentEditor()
        }
        return controller
    }

    private func removeEditorController(_ controller: QuickScreenshotEditorWindowController) {
        editorControllers.removeAll { $0 === controller }
        openEditorCount = editorControllers.count
    }

    // MARK: - No-Editor Quick Preview Card

    private func showQuickPreview(
        for image: CGImage,
        previousFrontmostApp: NSRunningApplication? = nil
    ) {
        dismissQuickPreview()
        guard !PermissionsManager.isRunningInDiagnosticMode else { return }

        let panel = PointerCursorNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 152),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ToolboxTheme.applyDarkAppearance(to: panel)

        let previewView = QuickScreenshotCornerPreviewView(
            image: image,
            onAnnotate: { [weak self] in
                self?.dismissQuickPreview()
                _ = self?.openEditor(for: image, previousFrontmostApp: previousFrontmostApp)
            },
            onDismiss: { [weak self] in
                self?.dismissQuickPreview()
            }
        )
        let hosting = PointerCursorHostingView(rootView: previewView)
        panel.contentView = hosting

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            let origin = NSPoint(x: vf.maxX - 276, y: vf.minY + 18)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        previewPanel = panel

        previewDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismissQuickPreview()
        }
    }

    func dismissQuickPreview() {
        previewDismissTask?.cancel()
        previewDismissTask = nil
        previewPanel?.orderOut(nil)
        previewPanel?.contentView = nil
        previewPanel = nil
    }

    // MARK: - Private Temp File Hygiene

    static func ensurePrivateTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(privateTempFolderName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(dir.path, 0o700)
        return dir
    }

    nonisolated static func sweepStaleTempFiles() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        if let items = try? fm.contentsOfDirectory(atPath: tempDir.path) {
            for item in items where item.hasPrefix("toolbox-shot-") && item != privateTempFolderName {
                try? fm.removeItem(at: tempDir.appendingPathComponent(item))
            }
        }
        let privateDir = tempDir.appendingPathComponent(privateTempFolderName, isDirectory: true)
        if let privateItems = try? fm.contentsOfDirectory(atPath: privateDir.path) {
            for item in privateItems where item.hasPrefix("toolbox-shot-") {
                try? fm.removeItem(at: privateDir.appendingPathComponent(item))
            }
        }
    }

    // MARK: - Screen Recording Permission (Reuses ScreenCapturePermission)

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
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: ScreenOCRModule.pendingReopenToastKey)
                waitForSystemSettingsSheetAndReturnToApp()
            }
        } else if let deadline = awaitingScreenGrantDeadline, Date() > deadline {
            stopAwaitingScreenGrant()
        }
    }

    private func waitForSystemSettingsSheetAndReturnToApp() {
        sheetWaitTask?.cancel()
        sheetWaitTask = Task { @MainActor [weak self] in
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
            UserDefaults.standard.removeObject(forKey: ScreenOCRModule.pendingReopenToastKey)
            MainWindowController.shared.show(destination: nil)
            HUDToast.shared.show(
                title: "Screen Recording granted — Quick Screenshot is ready",
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
}

private struct QuickScreenshotCornerPreviewView: View {
    let image: CGImage
    let onAnnotate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(decorative: image, scale: 2.0, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 236, maxHeight: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button("Annotate") {
                    onAnnotate()
                }
                .buttonStyle(.toolboxProminent(.red))
                .controlSize(.small)
                .pointerCursor()

                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .padding(10)
        .frame(width: 260)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .toolboxDarkAppearance()
    }
}
