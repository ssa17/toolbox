import AppKit
import SwiftUI

/// Headless visual snapshot utility (`Toolbox --snapshot-ui <dir>`).
/// Renders key Toolbox views offscreen into PNG files so agents and developers can
/// visually inspect spacing, card hierarchy, contrast, and icon states without
/// touching user configuration or stealing desktop focus.
@MainActor
enum SnapshotRunner {
    static func run(outputDir: String) -> Int32 {
        let fm = FileManager.default
        let outURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        do {
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        } catch {
            fputs("SnapshotRunner failed to create directory \(outputDir): \(error)\n", stderr)
            return 1
        }

        let configManager = ConfigManager.shared
        let registry = ModuleRegistry.shared

        // Reset clean temporary state for deterministic screenshots
        configManager.config = ToolboxConfig()
        registry.reloadAll(with: configManager.config)

        let navDashboard = NavigationState()
        navDashboard.selection = .dashboard
        navDashboard.isSidebarVisible = true

        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 940, height: 700),
            to: outURL.appendingPathComponent("dashboard_active.png")
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 1140, height: 760),
            to: outURL.appendingPathComponent("dashboard_active_default_width.png")
        )

        configManager.config.general.showModuleCardDetails = false
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 940, height: 700),
            to: outURL.appendingPathComponent("dashboard_active_compact.png")
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 820, height: 560),
            to: outURL.appendingPathComponent("dashboard_active_compact_minwidth.png")
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 1140, height: 760),
            to: outURL.appendingPathComponent("dashboard_active_compact_default_width.png")
        )
        configManager.config.general.showModuleCardDetails = true

        let prevSimAX = PermissionsManager.shared.simulatedAccessibilityGranted
        PermissionsManager.shared.setSimulatedAccessibilityGranted(false)
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 940, height: 760),
            to: outURL.appendingPathComponent("dashboard_needs_accessibility.png")
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 820, height: 560),
            to: outURL.appendingPathComponent("dashboard_needs_accessibility_compact.png")
        )
        saveViewSnapshot(
            AccessibilityOnboardingModalView(permissions: PermissionsManager.shared),
            size: NSSize(width: 540, height: 470),
            to: outURL.appendingPathComponent("accessibility_onboarding_modal.png")
        )
        let navModuleNeedsAX = NavigationState()
        navModuleNeedsAX.selection = .module("dock_minimize")
        navModuleNeedsAX.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navModuleNeedsAX),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_dock_needs_accessibility.png")
        )
        PermissionsManager.shared.setSimulatedAccessibilityGranted(prevSimAX)

        let navModule = NavigationState()
        navModule.selection = .module("dock_minimize")
        navModule.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navModule),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_dock.png")
        )

        let navScroll = NavigationState()
        navScroll.selection = .module("scroll_direction")
        navScroll.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navScroll),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_scroll.png")
        )

        let navClipboard = NavigationState()
        navClipboard.selection = .module("clipboard")
        navClipboard.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navClipboard),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_clipboard.png")
        )

        // Seed deterministic sample entries so the dropdown renders richly (the
        // snapshot run is routed into a temporary config dir, so this never touches
        // the user's real clipboard files).
        let clipboardModule = registry.clipboard
        clipboardModule.clearHistory(keepPinned: false)
        clipboardModule.recordText(#"func greet(_ name: String) -> String { return \(name)! }"#)
        clipboardModule.recordText("git commit -m \"feat: reorder pinned clipboard items\"")
        clipboardModule.recordText("SELECT id, email FROM users WHERE active = true;")
        clipboardModule.recordText("⌘ ⌥ V — Toolbox clipboard hotkey")
        clipboardModule.togglePin(clipboardModule.entries[3]) // func
        clipboardModule.togglePin(clipboardModule.entries[3]) // git (lands on top)
        let swiftHelper = clipboardModule.entries[1]
        clipboardModule.renameEntry(swiftHelper, title: "Swift helper")
        let clipboardUI = ClipboardPopoverUIState()
        clipboardUI.resetForOpen(entries: clipboardModule.entries)
        saveViewSnapshot(
            ClipboardPopoverView(
                module: clipboardModule,
                uiState: clipboardUI,
                onSelect: { _ in },
                onClose: {}
            )
            .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 440, height: 500),
            to: outURL.appendingPathComponent("popover_clipboard.png")
        )

        let navPortKiller = NavigationState()
        navPortKiller.selection = .module("port_killer")
        navPortKiller.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navPortKiller),
            size: NSSize(width: 940, height: 760),
            to: outURL.appendingPathComponent("module_port_killer.png")
        )

        // Seed a couple of recent captures so the Screen OCR settings page renders richly.
        let ocrModule = registry.screenOCR
        ocrModule.replaceRecentCaptures([
            RecentOCRCapture(
                id: "snap-qr",
                text: "https://github.com/toolbox/releases",
                lineCount: 1,
                isQR: true,
                createdAt: Date()
            ),
            RecentOCRCapture(
                id: "snap-text",
                text: "EADDRINUSE: address already in use 127.0.0.1:5173\nnode:events:1796\n(Use `node --trace-uncaught` to show where the code was most likely originated)",
                lineCount: 3,
                isQR: false,
                createdAt: Date()
            )
        ])
        // Pin the Screen Recording badge to a deterministic state: the module otherwise
        // reflects the machine's real TCC grant, which varies between CI boxes and laptops.
        ocrModule.setScreenRecordingGrantedForTesting(true)

        let navScreenOCR = NavigationState()
        navScreenOCR.selection = .module("screen_ocr")
        navScreenOCR.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navScreenOCR),
            size: NSSize(width: 940, height: 860),
            to: outURL.appendingPathComponent("module_screen_ocr.png")
        )
        ocrModule.replaceRecentCaptures([])

        let navCommands = NavigationState()
        navCommands.selection = .module("custom_commands")
        navCommands.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navCommands),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("module_custom_commands.png")
        )

        let navCleanLock = NavigationState()
        navCleanLock.selection = .module("clean_lock")
        navCleanLock.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navCleanLock),
            size: NSSize(width: 940, height: 700),
            to: outURL.appendingPathComponent("module_clean_lock.png")
        )

        let hudState = CleanLockHUDState()
        hudState.totalSeconds = 60
        hudState.remainingSeconds = 42
        hudState.remainingInterval = 42
        hudState.lockMouseAndTrackpad = true
        hudState.blockedCount = 14
        hudState.killSwitchProgress = 0.35
        saveViewSnapshot(
            CleanLockHUDCardView(state: hudState),
            size: NSSize(width: 320, height: 340),
            to: outURL.appendingPathComponent("clean_lock_hud.png")
        )

        let prevCallMicShortcut = configManager.config.callControls.micShortcut
        let prevCallVideoShortcut = configManager.config.callControls.videoShortcut
        configManager.config.callControls.micShortcut = ShortcutSpec(key: "m", modifiers: [.control, .option, .command])
        configManager.config.callControls.videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])

        let navCallControls = NavigationState()
        navCallControls.selection = .module("call_controls")
        navCallControls.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navCallControls),
            size: NSSize(width: 940, height: 1420),
            to: outURL.appendingPathComponent("module_call_controls.png")
        )
        configManager.config.callControls.micShortcut = prevCallMicShortcut
        configManager.config.callControls.videoShortcut = prevCallVideoShortcut

        let micPillState = FloatingMicIndicatorState()
        micPillState.isMuted = true
        micPillState.isTypingMuted = false
        micPillState.inputDeviceName = "MacBook Pro Microphone"
        micPillState.hasInputDevice = true
        micPillState.showVideoStatus = true
        micPillState.isCameraActive = true
        micPillState.cameraDeviceName = "FaceTime HD"
        micPillState.hasCameraDevice = true
        micPillState.canToggleVideo = false
        micPillState.videoUnavailableAppName = "FaceTime"
        saveViewSnapshot(
            FloatingMicIndicatorView(state: micPillState)
                .padding(8),
            size: NSSize(width: 420, height: 68),
            to: outURL.appendingPathComponent("call_controls_floating_pill.png")
        )

        let navJSON = NavigationState()
        navJSON.selection = .jsonConfig
        navJSON.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navJSON),
            size: NSSize(width: 940, height: 660),
            to: outURL.appendingPathComponent("json_config.png")
        )

        let navSupport = NavigationState()
        navSupport.selection = .support
        navSupport.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navSupport),
            size: NSSize(width: 940, height: 840),
            to: outURL.appendingPathComponent("support.png")
        )

        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let baseIcon = NSImage(contentsOf: icnsURL) {
            let supporterIcon = SupportState.makeSupporterDockIcon(from: baseIcon)
            saveViewSnapshot(
                Image(nsImage: supporterIcon)
                    .resizable()
                    .frame(width: 256, height: 256)
                    .padding(16),
                size: NSSize(width: 288, height: 288),
                to: outURL.appendingPathComponent("supporter_dock_icon.png")
            )
        }

        let navSettings = NavigationState()
        navSettings.selection = .settings
        navSettings.isSidebarVisible = true
        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: nil,
            lastCheckedAt: Date()
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navSettings),
            size: NSSize(width: 940, height: 1220),
            to: outURL.appendingPathComponent("settings_up_to_date.png")
        )

        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: true,
            checkProgress: 0.62,
            pendingUpdateVersion: nil,
            lastCheckedAt: Date().addingTimeInterval(-3600)
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navSettings),
            size: NSSize(width: 940, height: 1220),
            to: outURL.appendingPathComponent("settings_checking.png")
        )

        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: "1.1",
            pendingUpdateSizeBytes: 3_420_000,
            lastCheckedAt: Date()
        )
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navSettings),
            size: NSSize(width: 940, height: 1220),
            to: outURL.appendingPathComponent("settings_update_available.png")
        )

        saveViewSnapshot(
            MenuBarPopoverView(onOpenDashboard: { _ in }, onClosePopover: { _ in }),
            size: NSSize(width: 340, height: 470),
            to: outURL.appendingPathComponent("menubar_update_available.png")
        )

        saveUpdateDialogSnapshot(to: outURL.appendingPathComponent("update_dialog.png"))

        UpdateManager.shared.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: nil,
            lastCheckedAt: nil
        )

        saveViewSnapshot(
            MenuBarPopoverView(onOpenDashboard: { _ in }, onClosePopover: { _ in }),
            size: NSSize(width: 340, height: 470),
            to: outURL.appendingPathComponent("menubar_active.png")
        )

        let pkModule = ModuleRegistry.shared.portKiller
        saveViewSnapshot(
            ZStack(alignment: .topLeading) {
                PortKillerPopoverView(
                    module: pkModule,
                    uiState: pkModule.popoverState,
                    onClose: {}
                )
                .background(Color(nsColor: .windowBackgroundColor))

                PortKillerTooltipBubbleView(text: "Graceful Stop (SIGTERM) on PID 88038 (↩)")
                    .offset(x: 212, y: 114)
            },
            size: NSSize(width: 480, height: 500),
            to: outURL.appendingPathComponent("popover_port_killer.png")
        )

        configManager.config.general.appEnabled = false
        registry.reloadAll(with: configManager.config)

        saveViewSnapshot(
            MenuBarPopoverView(onOpenDashboard: { _ in }, onClosePopover: { _ in }),
            size: NSSize(width: 340, height: 470),
            to: outURL.appendingPathComponent("menubar_paused.png")
        )

        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDashboard),
            size: NSSize(width: 940, height: 700),
            to: outURL.appendingPathComponent("dashboard_paused.png")
        )

        configManager.config.general.appEnabled = true
        DeveloperModeManager.shared.unlock()
        UpdateManager.shared.applySimulationPreset(.updateAvailable, version: "1.2.0", sizeBytes: 3_565_158)

        let navDevUpdates = NavigationState()
        navDevUpdates.selection = .developer(.updates)
        navDevUpdates.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDevUpdates),
            size: NSSize(width: 940, height: 1280),
            to: outURL.appendingPathComponent("developer_updates.png")
        )

        let navDevUI = NavigationState()
        navDevUI.selection = .developer(.uiAndModules)
        navDevUI.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDevUI),
            size: NSSize(width: 940, height: 820),
            to: outURL.appendingPathComponent("developer_ui_modules.png")
        )

        registry.callControls.applyDeveloperSimulationPreset(.zoomCall)
        let navDevCallControls = NavigationState()
        navDevCallControls.selection = .developer(.callControls)
        navDevCallControls.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDevCallControls),
            size: NSSize(width: 940, height: 1320),
            to: outURL.appendingPathComponent("developer_call_controls.png")
        )
        registry.callControls.clearDeveloperSimulation()

        DeveloperEventLog.shared.clear()
        DeveloperEventLog.shared.record(.hotkeys, "Triggered hotkey: clipboard.toggle", detail: "⌘⌥V")
        DeveloperEventLog.shared.record(.dock, "Handled dock click on Safari", detail: "mode: hide_app · wasFrontmost: true")
        DeveloperEventLog.shared.record(.updates, "Applied update preset: Update Available", detail: "version: 1.2.0")
        let navDevEvents = NavigationState()
        navDevEvents.selection = .developer(.eventsAndTaps)
        navDevEvents.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDevEvents),
            size: NSSize(width: 940, height: 960),
            to: outURL.appendingPathComponent("developer_events.png")
        )

        // Screen OCR developer section: seed a failed interactive pipeline run (red stage
        // states render) plus a passing offline self-check, and the matching OCR event.
        let devOCR = registry.screenOCR
        devOCR.clearPipelineReport()
        devOCR.setPipelineReportForTesting(OCRPipelineReport(
            kind: .interactive,
            stages: [
                OCRPipelineStage(id: "permission", name: "Screen Recording Permission", status: .pass, detail: "granted"),
                OCRPipelineStage(id: "tempdir", name: "Temp Directory", status: .pass, detail: "/var/folders/5s/…/T"),
                OCRPipelineStage(id: "launch", name: "Launch screencapture", status: .pass, detail: "pid 48213 · -i -x /var/folders/5s/…/toolbox-ocr-pipetest-9F2A….png"),
                OCRPipelineStage(id: "file", name: "Capture File", status: .pass, detail: "toolbox-ocr-pipetest-9F2A….png · 184,220 bytes (kept)"),
                OCRPipelineStage(id: "decode", name: "Image Decode", status: .pass, detail: "812x504 px · kCGColorSpaceSRGB · alpha=1 · near-black 2.4%"),
                OCRPipelineStage(id: "prepare", name: "Image Prep", status: .skipped, detail: "no upscale (height ≥ 32)"),
                OCRPipelineStage(id: "vision", name: "Vision Recognition", status: .fail, detail: "0 observation(s) · 318 ms · near-black 2.4%"),
                OCRPipelineStage(id: "barcode", name: "QR / Barcode Detection", status: .pass, detail: "0 payload(s)"),
                OCRPipelineStage(id: "output", name: "Combined Output", status: .fail, detail: "empty — no text or QR in the captured region")
            ],
            startedAt: Date(),
            artifactPath: "/var/folders/5s/…/T/toolbox-ocr-pipetest-9F2A….png",
            outputPreview: nil
        ))
        DeveloperEventLog.shared.record(.ocr, "No text found in selection", detail: "image 812x504 · 0 observation(s) · near-black 2.4% · file kept: /var/folders/5s/…/toolbox-ocr-9F2A….png")
        devOCR.setLastFailedCaptureForTesting(
            path: "/var/folders/5s/…/T/toolbox-ocr-9F2A….png",
            note: "812x504 px · near-black 2.4% · 0 observation(s) · still empty"
        )
        let navDevOCR = NavigationState()
        navDevOCR.selection = .developer(.screenOCR)
        navDevOCR.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDevOCR),
            size: NSSize(width: 940, height: 1380),
            to: outURL.appendingPathComponent("developer_screen_ocr.png")
        )
        devOCR.setPipelineReportForTesting(nil)
        DeveloperEventLog.shared.clear()

        ConfigCheckpointStore.shared.saveCheckpoint()
        let navDevHotKeys = NavigationState()
        navDevHotKeys.selection = .developer(.hotKeysAndConfig)
        navDevHotKeys.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDevHotKeys),
            size: NSSize(width: 940, height: 900),
            to: outURL.appendingPathComponent("developer_hotkeys_config.png")
        )
        ConfigCheckpointStore.shared.clearCheckpoint()
        DeveloperEventLog.shared.clear()

        DeveloperHealthCheckRunner.shared.runAllChecks()
        let navDevChecks = NavigationState()
        navDevChecks.selection = .developer(.checksAndDiagnostics)
        navDevChecks.isSidebarVisible = true
        saveViewSnapshot(
            MainWindowController.makeRootView(navState: navDevChecks),
            size: NSSize(width: 940, height: 1750),
            to: outURL.appendingPathComponent("developer_checks.png")
        )

        UpdateManager.shared.clearSimulation()
        DeveloperModeManager.shared.lock()

        saveViewSnapshot(
            DeveloperPinPromptView(onUnlocked: {}, onCancel: {}),
            size: NSSize(width: 360, height: 220),
            to: outURL.appendingPathComponent("developer_pin_prompt.png")
        )

        renderStatusBarPreview(to: outURL.appendingPathComponent("statusbar_icons.png"))

        // Clean up temp config dir created by ConfigManager isolated mode
        let tempDir = configManager.configURL.deletingLastPathComponent()
        if tempDir.path.contains("toolbox-isolated-") {
            try? fm.removeItem(at: tempDir)
        }

        print("Saved UI snapshots to \(outURL.path)")
        return 0
    }

    private static func saveViewSnapshot<V: View>(_ view: V, size: NSSize, to url: URL) {
        let darkWrapped = ZStack {
            Color(red: 0.145, green: 0.149, blue: 0.165)
            view
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: darkWrapped)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.145, green: 0.149, blue: 0.165, alpha: 1.0)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.10))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fputs("SnapshotRunner could not allocate bitmap rep for \(url.lastPathComponent)\n", stderr)
            window.close()
            return
        }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
        window.close()
    }

    private static func renderStatusBarPreview(to url: URL) {
        let size = NSSize(width: 320, height: 110)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()

        let activeImg = MenuBarController.makeStatusBarIcon(isActive: true)
        let pausedImg = MenuBarController.makeStatusBarIcon(isActive: false)

        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            activeImg.draw(in: NSRect(x: 56, y: 42, width: 44, height: 44), from: .zero, operation: .sourceOver, fraction: 1.0)
            pausedImg.draw(in: NSRect(x: 206, y: 42, width: 44, height: 44), from: .zero, operation: .sourceOver, fraction: 0.55)
        }

        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.9, alpha: 1.0)
        ]
        NSAttributedString(string: "Active (Filled)", attributes: attr).draw(at: NSPoint(x: 34, y: 16))
        NSAttributedString(string: "Paused (Outlined)", attributes: attr).draw(at: NSPoint(x: 174, y: 16))

        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private static func saveUpdateDialogSnapshot(to url: URL) {
        let controller = ToolboxUpdateWindowController()
        controller.populatePreviewAvailable(
            version: "1.1",
            currentVersion: "1.0",
            sizeBytes: 3_420_000,
            notes: """
            ### What's New in Toolbox 1.1
            - **Inline Settings update checker** — progress bar, version badge, and last checked timestamp.
            - **Custom dark update dialog** — shown only when a new release is ready.
            - **Update-available indicators** — across the sidebar, dashboard banner, and status bar menu.
            """
        )
        guard let view = controller.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
