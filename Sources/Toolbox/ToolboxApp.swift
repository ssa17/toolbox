import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var allowImmediateTermination = false
    private var menuBarController: MenuBarController?

    static func terminateNow() {
        allowImmediateTermination = true
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.allowImmediateTermination = true
            }
        }
        let configManager = ConfigManager.shared
        let registry = ModuleRegistry.shared
        let permissions = PermissionsManager.shared
        _ = UpdateManager.shared

        self.menuBarController = MenuBarController()
        applyGeneralPreferences(configManager.config.general)

        configManager.onConfigChanged = { [weak self] newConfig in
            self?.applyGeneralPreferences(newConfig.general)
            registry.reloadAll(with: newConfig)
        }

        // Reload all modules when the Accessibility permission state changes in either
        // direction, so permission gated modules (event taps) start/stop and report correctly.
        permissions.onAccessibilityChanged = { _ in
            registry.reloadAll(with: configManager.config)
        }

        // Start all enabled modules immediately (Accessibility-gated modules wait gracefully without blocking launch).
        registry.reloadAll(with: configManager.config)

        // Screen OCR: remove capture artifacts left behind by the previous session
        // (failed captures are intentionally kept on disk for diagnosis, so they must
        // not accumulate across launches).
        ScreenOCRModule.sweepStaleTempFiles()

        if configManager.config.general.openDashboardOnLaunch {
            MainWindowController.shared.show(destination: .dashboard)
            let isDiagnosticMode = CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--snapshot-ui")
            if !isDiagnosticMode,
               !configManager.config.general.hasSeenAccessibilityOnboarding,
               !permissions.isAccessibilityGranted {
                permissions.presentOnboardingModal()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag || ConfigManager.shared.config.general.openDashboardOnDockClick {
            MainWindowController.shared.show(destination: nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowImmediateTermination {
            return .terminateNow
        }
        if ConfigManager.shared.config.general.dockQuitBehavior == .closeWindow,
           let win = MainWindowController.shared.currentWindow,
           win.isVisible {
            win.close()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ModuleRegistry.shared.cleanLock.stop()
        ModuleRegistry.shared.callControls.stop()
        ModuleRegistry.shared.screenOCR.stop()
    }

    private func applyGeneralPreferences(_ general: GeneralConfig) {
        let policy: NSApplication.ActivationPolicy = general.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
        menuBarController?.setVisible(general.showInMenuBar, isActive: general.appEnabled)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Toolbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

@main
enum ToolboxMain {
    static func main() {
        if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            print("Toolbox \(version)")
            return
        }

        if CommandLine.arguments.contains("--self-test") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            exit(SelfTestRunner.runAll())
        }

        if let snapIdx = CommandLine.arguments.firstIndex(of: "--snapshot-ui") {
            let outPath: String
            if snapIdx + 1 < CommandLine.arguments.count {
                outPath = CommandLine.arguments[snapIdx + 1]
            } else {
                outPath = FileManager.default.currentDirectoryPath + "/.work/snapshots"
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            exit(SnapshotRunner.run(outputDir: outPath))
        }

        if let ocrIdx = CommandLine.arguments.firstIndex(of: "--ocr-file") {
            let path: String?
            if ocrIdx + 1 < CommandLine.arguments.count {
                path = CommandLine.arguments[ocrIdx + 1]
            } else {
                path = nil
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            exit(OCRCliRunner.runFile(path: path))
        }

        if CommandLine.arguments.contains("--ocr-capture") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            exit(OCRCliRunner.runCapture())
        }

        // Single-instance guard: focus an already-running Toolbox.app instead of spawning duplicates.
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let currentPID = ProcessInfo.processInfo.processIdentifier
            if let existing = running.first(where: { $0.processIdentifier != currentPID }) {
                existing.activate()
                return
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
