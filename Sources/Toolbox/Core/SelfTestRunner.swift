import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Built-in diagnostic & regression test runner (`Toolbox --self-test`).
/// Runs isolated checks without modifying user config or requiring XCTest.
@MainActor
enum SelfTestRunner {
    private static var failures: [String] = []

    static func runAll() -> Int32 {
        failures.removeAll()
        print("Running Toolbox self-tests...")

        testShortcutSpecTokensAndDisplaySpacing()
        testLegacyV1ConfigMigrationAndExtensions()
        testGeneralConfigDefaults()
        testNavigationHistoryAndPreservation()
        testClipboardCaptureDedupConcealedAndPinning()
        testClipboardPanelDoesNotHideOnDeactivate()
        testClipboardDeleteAndPopoverUIState()
        testKeepAwakePmsetParsing()
        testHotKeyManagerRegistrationAndUnregistration()
        testCustomCommandsShellExecution()
        testModuleRegistryAndSettingsViews()
        testKeepAwakeLifecycle()
        testMasterTogglePauseResumeAndInstantPopover()
        testScrollDirectionConfigAndMigration()
        testScrollInversionClassificationAndInversion()
        testScrollDirectionModuleLifecycleAndRegistry()
        testDockMinimizeWindowsBehaviorAndPreFilter()
        testUpdateManagerAndCustomDialog()
        testMenuBarCustomizationOrderAndVisibility()
        testPortScannerParsersAndElevatedMerge()
        testPortKillerSafetyAndLiveLoopbackListener()
        testDeveloperModeAndSimulations()
        testCleanLockEventFilteringAndLifecycle()
        testCallControlsConfigAndCoreAudioEnumeration()
        testCallControlsShortcutRemapper()
        testCallControlsTypingMicStateMachine()
        testCallControlsHotKeyConflictsAndLifecycle()
        testCallControlsDeveloperSimulation()
        testScreenOCRConfigAndLifecycle()
        testScreenOCREngineRecognition()
        testMultiScreenOnboardingClipboardScrollAndMicSync()
        testSupportLinks()

        if failures.isEmpty {
            print("All 32 self-test suites passed.")
            return 0
        } else {
            for f in failures {
                fputs("FAIL: \(f)\n", stderr)
            }
            return 1
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures.append(message)
        }
    }

    private static func testShortcutSpecTokensAndDisplaySpacing() {
        let shortcut = ShortcutSpec(key: "d", modifiers: [.command, .option, .shift])
        expect(shortcut.tokens == ["⌥", "⇧", "⌘", "D"], "ShortcutSpec.tokens order/content mismatch: \(shortcut.tokens)")
        expect(shortcut.displayString == "⌥ ⇧ ⌘ D", "ShortcutSpec.displayString spacing mismatch: \(shortcut.displayString)")
        expect(shortcut.carbonKeyCode != nil, "ShortcutSpec.carbonKeyCode should resolve 'd'")

        if let data = try? JSONEncoder().encode(shortcut),
           let decoded = try? JSONDecoder().decode(ShortcutSpec.self, from: data) {
            expect(decoded == shortcut, "ShortcutSpec Codable round-trip mismatch")
        } else {
            failures.append("ShortcutSpec Codable encode/decode failed")
        }

        // Unbound / empty spec
        expect(ShortcutSpec.none.isEmpty, "ShortcutSpec.none should be empty")
        expect(ShortcutSpec.none.tokens.isEmpty, "ShortcutSpec.none.tokens should be empty")
        expect(ShortcutSpec.none.displayString.isEmpty, "ShortcutSpec.none.displayString should be empty")
        expect(ShortcutSpec.none.carbonKeyCode == nil, "ShortcutSpec.none.carbonKeyCode should be nil")

        // Function key, arrow key, special glyph, and modifier normalization
        let fnKey = ShortcutSpec(key: "f5", modifiers: [])
        expect(fnKey.isFunctionKey, "f5 should be recognized as a function key")
        expect(fnKey.tokens == ["F5"], "Function key tokens mismatch: \(fnKey.tokens)")
        expect(fnKey.carbonKeyCode != nil, "ShortcutSpec.carbonKeyCode should resolve 'f5'")

        let arrowKey = ShortcutSpec(key: "up", modifiers: [.option, .control])
        expect(arrowKey.tokens == ["⌃", "⌥", "↑"], "Arrow key tokens mismatch: \(arrowKey.tokens)")
        expect(arrowKey.displayString == "⌃ ⌥ ↑", "Arrow key displayString mismatch: \(arrowKey.displayString)")
        expect(arrowKey.carbonKeyCode != nil, "ShortcutSpec.carbonKeyCode should resolve 'up'")

        let returnKey = ShortcutSpec(key: "return", modifiers: [.command])
        expect(returnKey.tokens == ["⌘", "↩"], "Return key tokens mismatch: \(returnKey.tokens)")

        let unnormalized = ShortcutSpec(key: "D", modifiers: [.command, .shift, .option, .command])
        expect(unnormalized == shortcut, "ShortcutSpec should normalize key case, modifier order, and duplicates")
    }

    private static func testLegacyV1ConfigMigrationAndExtensions() {
        let legacyV1JSON = """
        {
          "version": 1,
          "dockMinimize": {
            "enabled": true,
            "hideInsteadOfMinimize": true,
            "excludedBundleIDs": ["com.apple.finder", "com.apple.Terminal"]
          },
          "clipboard": {
            "enabled": true,
            "maxItems": 42,
            "pasteAutomatically": false,
            "pollIntervalMs": 350
          },
          "extensions": {
            "my_plugin": { "threshold": 3.5, "active": true }
          }
        }
        """
        guard let data = legacyV1JSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) else {
            failures.append("Failed to decode legacy v1 JSON config")
            return
        }

        expect(decoded.dockMinimize.actionMode == .hideApp, "Legacy hideInsteadOfMinimize should migrate to .hideApp")
        expect(decoded.dockMinimize.excludedBundleIDs == ["com.apple.finder", "com.apple.Terminal"], "Excluded bundle IDs mismatch")
        expect(decoded.clipboard.maxItems == 42, "Clipboard maxItems mismatch")
        expect(!decoded.clipboard.pasteAutomatically, "Clipboard pasteAutomatically mismatch")
        expect(decoded.clipboard.shortcut == ShortcutSpec(key: "v", modifiers: [.command, .option]), "Clipboard default shortcut mismatch")
        expect(decoded.extensions["my_plugin"] == .object(["threshold": .number(3.5), "active": .bool(true)]), "Extensions JSONValue mismatch")
    }

    private static func testClipboardCaptureDedupConcealedAndPinning() {
        let clipboard = ClipboardModule()
        clipboard.clearHistory(keepPinned: false)

        var cfg = ToolboxConfig()
        cfg.clipboard.maxItems = 3
        cfg.clipboard.deduplicate = true
        cfg.clipboard.ignoreConcealedTypes = true
        clipboard.reload(with: cfg)
        // Clear any item captured from the live system pasteboard during start()
        clipboard.clearHistory(keepPinned: false)

        clipboard.recordText(
            "super-secret-password",
            pasteboardTypes: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]
        )
        expect(clipboard.entries.isEmpty, "Concealed pasteboard type should be ignored")

        clipboard.recordText("first")
        clipboard.recordText("second")
        clipboard.recordText("first")
        expect(clipboard.entries.map(\.text) == ["first", "second"], "Clipboard deduplication order mismatch")

        let second = clipboard.entries[1]
        clipboard.togglePin(second)
        clipboard.renameEntry(second, title: "My Snippet")
        clipboard.recordText("third")
        clipboard.recordText("fourth")

        expect(clipboard.entries.count == 3, "Clipboard history should respect maxItems=3")
        expect(clipboard.entries.contains(where: { $0.text == "second" && $0.isPinned && $0.customTitle == "My Snippet" }), "Pinned & renamed entry should survive trim")

        // Unpinned history persistence across restarts (with persistHistory toggle)
        let historyFileURL = ConfigManager.shared.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("clipboard_history.json")
        expect(FileManager.default.fileExists(atPath: historyFileURL.path), "Unpinned clipboard history should be saved to clipboard_history.json when persistHistory is enabled")

        let restoredClipboard = ClipboardModule()
        restoredClipboard.reload(with: cfg)
        expect(
            restoredClipboard.entries.contains(where: { $0.text == "fourth" && !$0.isPinned }),
            "New ClipboardModule instance should restore unpinned history when persistHistory is true (got: \(restoredClipboard.entries.map(\.text)))"
        )
        restoredClipboard.stop()

        clipboard.clearHistory(keepPinned: true)
        expect(clipboard.entries.map(\.text) == ["second"], "clearHistory(keepPinned: true) should keep pinned items")
        expect(!FileManager.default.fileExists(atPath: historyFileURL.path), "clearHistory(keepPinned: true) should delete clipboard_history.json")

        clipboard.recordText("temporary")
        expect(FileManager.default.fileExists(atPath: historyFileURL.path), "Recording unpinned item should recreate clipboard_history.json")
        cfg.clipboard.persistHistory = false
        clipboard.reload(with: cfg)
        expect(!FileManager.default.fileExists(atPath: historyFileURL.path), "Disabling persistHistory must delete clipboard_history.json")

        clipboard.clearHistory(keepPinned: false)
        clipboard.stop()
    }

    private static func testGeneralConfigDefaults() {
        let cfg = ToolboxConfig()
        expect(cfg.general.showInDock, "Toolbox should show in Dock by default")
        expect(cfg.general.showInMenuBar, "Toolbox should show in Menu Bar by default")
        expect(cfg.general.openDashboardOnDockClick, "Toolbox should reopen Dashboard on Dock click by default")
        expect(cfg.general.dockQuitBehavior == .closeWindow, "Dock Quit behavior should default to closeWindow")
        expect(!cfg.keepAwake.enabled, "KeepAwake should default to disabled (off by default)")
        expect(!cfg.screenOCR.enabled, "ScreenOCR should default to disabled (off by default)")
        expect(cfg.screenOCR.recognitionLevel == .accurate, "ScreenOCR should default to accurate recognition")
        expect(cfg.screenOCR.shortcut == ShortcutSpec(key: "o", modifiers: [.control, .option, .command]), "ScreenOCR default shortcut should be ⌃ ⌥ ⌘ O")
        expect(!cfg.customCommands.enabled, "CustomCommands should default to disabled (off by default)")
        expect(!cfg.scrollDirection.enabled, "ScrollDirection should default to disabled (off by default)")
        expect(cfg.dockMinimize.excludedBundleIDs.isEmpty, "No apps should be excluded by default")
        expect(DockActionMode.allCases.contains(.sendToBack), "DockActionMode should include sendToBack")
        expect(cfg.clipboard.maxItems == 25, "Clipboard default maxItems should be 25")
        expect(cfg.clipboard.persistHistory, "Clipboard default persistHistory should be true")
    }

    private static func testNavigationHistoryAndPreservation() {
        let nav = NavigationState()
        expect(nav.selection == .dashboard, "Initial selection should be dashboard")
        expect(nav.isSidebarVisible, "Sidebar should start visible by default")
        nav.toggleSidebar()
        expect(!nav.isSidebarVisible, "Sidebar should collapse when toggled")
        nav.toggleSidebar()
        expect(nav.isSidebarVisible, "Sidebar should reopen when toggled again")
        expect(!nav.canGoBack, "Initial back history should be empty")

        nav.navigate(to: .module("clipboard"))
        nav.navigate(to: .jsonConfig)
        expect(nav.canGoBack, "Should be able to go back after navigation")
        expect(nav.selection == .jsonConfig, "Current selection should be jsonConfig")

        nav.goBack()
        expect(nav.selection == .module("clipboard"), "Back should return to clipboard module")
        nav.goBack()
        expect(nav.selection == .dashboard, "Back should return to dashboard")
    }

    private static func testKeepAwakePmsetParsing() {
        let current = """
        System-wide power settings:
        Currently in use:
         disksleep            10
         displaysleep         60
         sleep                0
        """
        let custom = """
        Battery Power:
         displaysleep         10
        AC Power:
         displaysleep         60
        """
        let info = KeepAwakeModule.parsePmset(currentOutput: current, customOutput: custom)
        expect(info.activeDisplaySleepMinutes == 60, "Active displaysleep should be 60")
        expect(info.batteryDisplaySleepMinutes == 10, "Battery displaysleep should be 10")
        expect(info.acDisplaySleepMinutes == 60, "AC displaysleep should be 60")
    }

    private static func testClipboardPanelDoesNotHideOnDeactivate() {
        let clipboard = ClipboardModule()
        let panel = clipboard.ensurePanel(width: 360, height: 400)
        expect(!panel.hidesOnDeactivate, "Clipboard NSPanel must have hidesOnDeactivate = false")
        expect(panel.styleMask.contains(.nonactivatingPanel), "Clipboard NSPanel must be nonactivatingPanel")
        clipboard.showPopover()
        expect(clipboard.isPopoverVisible, "Clipboard showPopover() should make panel visible")
        clipboard.hidePopover()
        expect(!clipboard.isPopoverVisible, "Clipboard hidePopover() should hide panel")
    }

    private static func testClipboardDeleteAndPopoverUIState() {
        let clipboard = ClipboardModule()
        var cfg = ToolboxConfig()
        cfg.clipboard.maxItems = 5
        clipboard.reload(with: cfg)
        clipboard.clearHistory(keepPinned: false)
        clipboard.recordText("first item")
        clipboard.recordText("second item")
        expect(clipboard.entries.count == 2, "Expected 2 recorded clipboard entries")
        let e1 = clipboard.entries[0]
        let e2 = clipboard.entries[1]

        let uiState = ClipboardPopoverUIState()
        uiState.resetForOpen(entries: clipboard.entries)
        expect(uiState.selectedEntryID == e1.id, "resetForOpen should select first entry")
        expect(uiState.pendingDeleteEntry == nil, "resetForOpen should clear pendingDeleteEntry")
        expect(!uiState.pendingClearAll, "resetForOpen should clear pendingClearAll")

        uiState.pendingDeleteEntry = e1
        uiState.pendingClearAll = true
        uiState.previewEntryID = e2.id
        uiState.resetForOpen(entries: clipboard.entries)
        expect(uiState.pendingDeleteEntry == nil, "resetForOpen must reset pendingDeleteEntry")
        expect(!uiState.pendingClearAll, "resetForOpen must reset pendingClearAll")
        expect(uiState.previewEntryID == nil, "resetForOpen must reset previewEntryID")

        clipboard.deleteEntry(e1)
        expect(clipboard.entries.map(\.id) == [e2.id], "deleteEntry should remove target entry")
        clipboard.clearHistory(keepPinned: false)
        clipboard.stop()
    }

    private static func testHotKeyManagerRegistrationAndUnregistration() {
        let manager = HotKeyManager.shared
        let shortcut = ShortcutSpec(key: "j", modifiers: [.command, .option, .shift])
        let registered = manager.register(name: "selftest.hotkey", shortcut: shortcut) {}
        expect(registered, "HotKeyManager failed to register test shortcut")
        expect(manager.isRegistered(name: "selftest.hotkey"), "HotKeyManager should report registered")
        expect(manager.registrationErrors["selftest.hotkey"] == nil, "Unexpected registration error")

        manager.unregister(name: "selftest.hotkey")
        expect(!manager.isRegistered(name: "selftest.hotkey"), "HotKeyManager should unregister cleanly")

        let emptyRegistered = manager.register(name: "selftest.empty", shortcut: .none) {}
        expect(emptyRegistered && !manager.isRegistered(name: "selftest.empty"), "Registering .none should cleanly leave hotkey unregistered")
        expect(manager.registrationErrors["selftest.empty"] == nil, "Registering .none should not produce an error")

        let suspendOk = manager.register(name: "selftest.suspend", shortcut: shortcut) {}
        expect(suspendOk, "HotKeyManager failed to register suspend test shortcut")
        manager.setSuspendedForRecording(true)
        expect(manager.isSuspendedForRecording, "HotKeyManager should report suspended for recording")
        expect(manager.isRegistered(name: "selftest.suspend"), "Suspended registration should remain tracked by name")
        manager.setSuspendedForRecording(false)
        expect(!manager.isSuspendedForRecording, "HotKeyManager should resume after recording")
        expect(manager.isRegistered(name: "selftest.suspend"), "Resumed registration should remain active")
        manager.unregister(name: "selftest.suspend")

        var cfg = ToolboxConfig()
        cfg.clipboard.enabled = true
        cfg.keepAwake.enabled = true
        cfg.keepAwake.shortcut = cfg.clipboard.shortcut
        let conflict = manager.inAppConflictDescription(
            for: cfg.keepAwake.shortcut,
            excludingSourceID: "keep_awake",
            in: cfg
        )
        expect(conflict != nil, "inAppConflictDescription should detect KeepAwake vs Clipboard collision")

        manager.clearConflictingShortcuts(
            matching: cfg.keepAwake.shortcut,
            excludingSourceID: "keep_awake",
            in: &cfg
        )
        expect(cfg.clipboard.shortcut.isEmpty, "clearConflictingShortcuts should unbind colliding Clipboard shortcut")
        expect(!cfg.keepAwake.shortcut.isEmpty, "clearConflictingShortcuts must preserve excluded KeepAwake shortcut")
        expect(
            manager.inAppConflictDescription(for: cfg.keepAwake.shortcut, excludingSourceID: "keep_awake", in: cfg) == nil,
            "Conflict should be cleared after clearConflictingShortcuts"
        )

        let scrollShortcut = ShortcutSpec(key: "s", modifiers: [.command, .option])
        cfg.scrollDirection.shortcut = scrollShortcut
        cfg.dockMinimize.shortcut = scrollShortcut
        expect(
            manager.inAppConflictDescription(for: scrollShortcut, excludingSourceID: "scroll_direction", in: cfg) != nil,
            "inAppConflictDescription should detect ScrollDirection vs DockMinimize collision"
        )
        manager.clearConflictingShortcuts(matching: scrollShortcut, excludingSourceID: "scroll_direction", in: &cfg)
        expect(cfg.dockMinimize.shortcut.isEmpty, "clearConflictingShortcuts should clear colliding DockMinimize shortcut")
    }

    private static func testCustomCommandsShellExecution() {
        let res = CustomCommandsModule.executeShellSync("echo toolbox_ok")
        expect(res.exitCode == 0, "Shell command exitCode should be 0")
        expect(res.output == "toolbox_ok", "Shell command output mismatch: \(res.output)")
    }

    private static func testModuleRegistryAndSettingsViews() {
        let registry = ModuleRegistry.shared
        let ids = registry.modules.map(\.id)
        expect(Set(ids).count == ids.count, "ModuleRegistry IDs must be unique")
        expect(ids.count >= 4, "Expected at least 4 built-in modules")
        for module in registry.modules {
            expect(!module.name.isEmpty, "Module \(module.id) name must not be empty")
            _ = module.makeSettingsView()
        }
    }

    private static func testKeepAwakeLifecycle() {
        let keepAwake = KeepAwakeModule()
        keepAwake.activate(minutes: 15)
        expect(keepAwake.isAwakeActive, "KeepAwake should become active")
        expect(keepAwake.expiresAt != nil, "KeepAwake with 15m should set expiresAt")
        keepAwake.deactivate()
        expect(!keepAwake.isAwakeActive, "KeepAwake should deactivate cleanly")
    }

    private static func testMasterTogglePauseResumeAndInstantPopover() {
        var cfg = ToolboxConfig()
        expect(cfg.general.appEnabled, "GeneralConfig.appEnabled should default to true")

        let registry = ModuleRegistry.shared
        cfg.keepAwake.enabled = true
        cfg.general.appEnabled = true
        registry.reloadAll(with: cfg)
        expect(registry.clipboard.isRunning == cfg.clipboard.enabled, "Registry reloadAll active state mismatch")

        cfg.general.appEnabled = false
        registry.reloadAll(with: cfg)
        for module in registry.modules {
            expect(!module.isRunning, "Module \(module.id) must stop when general.appEnabled is false")
            if module.isEnabled(in: cfg) {
                expect(module.statusText(in: cfg, accessibilityGranted: true) == "Paused", "Enabled module \(module.id) statusText should be Paused when appEnabled is false")
            }
        }
        expect(cfg.keepAwake.enabled, "Per-module enabled state must stay preserved while paused")

        let menuBar = MenuBarController()
        menuBar.setVisible(true, isActive: true)
        expect(menuBar.attachedMenuForTesting == nil, "NSStatusItem must not attach NSMenu so macOS 26 does not auto-cancel tracking while inactive")
        expect(menuBar.statusButtonForTesting?.action != nil, "NSStatusItem button must handle clicks to toggle popover")
        expect(menuBar.pointerCursorViewCountForTesting >= 10, "Menu bar interactive controls must attach PointerCursorNSView overlays (found \(menuBar.pointerCursorViewCountForTesting))")
        menuBar.showPopoverForTesting()
        expect(menuBar.isPopoverVisibleForTesting, "showPopoverForTesting must display the status bar popover")
        expect(menuBar.popoverPanelForTesting?.styleMask.contains(.nonactivatingPanel) == true, "Status bar popover panel must use .nonactivatingPanel")
        expect(menuBar.popoverPanelForTesting?.hidesOnDeactivate == false, "Status bar popover panel must stay open when Toolbox is inactive")
        menuBar.hidePopoverForTesting()
        expect(!menuBar.isPopoverVisibleForTesting, "hidePopoverForTesting must dismiss the status bar popover")
        menuBar.setVisible(false)
        expect(menuBar.statusButtonForTesting == nil, "Hiding status item must remove status bar button")

        let primaryScreen = (frame: NSRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: NSRect(x: 0, y: 78, width: 1728, height: 1007))
        let secondaryScreen = (frame: NSRect(x: -132, y: 1117, width: 2560, height: 1440), visibleFrame: NSRect(x: -132, y: 1117, width: 2560, height: 1415))
        let originOnSecondDisplay = MenuBarController.popoverOrigin(
            size: NSSize(width: 340, height: 470),
            cursorPoint: NSPoint(x: 2100, y: 2545),
            buttonScreenRect: NSRect(x: 1320, y: 1088, width: 32, height: 24),
            screenFrames: [primaryScreen, secondaryScreen],
            fallbackVisibleFrame: primaryScreen.visibleFrame
        )
        expect(secondaryScreen.frame.contains(originOnSecondDisplay), "Menu bar click on secondary display must open popover on secondary display even if button.window frame is still on primary display (got \(originOnSecondDisplay))")

        let win = MainWindowController.shared.ensureWindow()
        win.layoutIfNeeded()
        expect(win.acceptsMouseMovedEvents, "Dashboard NSWindow must accept mouse moved events so hover cursors reset outside clickable items")
        if let rootView = win.contentView?.superview ?? win.contentView {
            // 1. Blank areas on the page (e.g. header banner, bottom margin below grid) must NOT match PointerCursorNSView.
            let emptyBannerPt = NSPoint(x: 500, y: 650)
            let emptySideMarginPt = NSPoint(x: 230, y: 300)
            expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptyBannerPt),
                   "Blank header area on Dashboard must not trigger pointingHand cursor")
            expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptySideMarginPt),
                   "Empty margin on Dashboard must not trigger pointingHand cursor")

            // 2. Clickable toolbar sidebar toggle and sidebar Dashboard item must match PointerCursorNSView.
            let toolbarBtnPt = NSPoint(x: 104, y: 734)
            let sidebarDashboardPt = NSPoint(x: 80, y: 665)
            expect(PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: toolbarBtnPt),
                   "Toolbar sidebar toggle button must match PointerCursorNSView")
            expect(PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: sidebarDashboardPt),
                   "Sidebar Dashboard row must match PointerCursorNSView")

            // 3. Verify all other destinations keep PointerCursorNSView tightly scoped to clickable controls (not empty areas).
            let destinations: [(String, SidebarDestination, NSPoint)] = [
                ("settings", .settings, NSPoint(x: 350, y: 600)),
                ("jsonConfig", .jsonConfig, NSPoint(x: 500, y: 350)),
                ("dock_minimize", .module("dock_minimize"), NSPoint(x: 500, y: 600)),
                ("clipboard", .module("clipboard"), NSPoint(x: 500, y: 600)),
                ("keep_awake", .module("keep_awake"), NSPoint(x: 500, y: 600)),
                ("custom_commands", .module("custom_commands"), NSPoint(x: 500, y: 600)),
                ("scroll_direction", .module("scroll_direction"), NSPoint(x: 500, y: 600)),
                ("screen_ocr", .module("screen_ocr"), NSPoint(x: 500, y: 600)),
                ("call_controls", .module("call_controls"), NSPoint(x: 500, y: 600)),
            ]
            for (label, dest, emptyPt) in destinations {
                MainWindowController.shared.navState.navigate(to: dest)
                win.layoutIfNeeded()
                expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptyPt),
                       "Non-clickable area on \(label) page must not trigger pointingHand cursor")
                expect(PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: toolbarBtnPt),
                       "Toolbar sidebar toggle button must stay active on \(label) page")
            }
            MainWindowController.shared.navState.selection = .dashboard
            MainWindowController.shared.navState.navigate(to: .settings)
            MainWindowController.shared.navState.goBack()
            expect(MainWindowController.shared.navState.selection == .dashboard, "NavigationState.goBack() must return to dashboard")
            win.layoutIfNeeded()
        }
        expect(win.contentMinSize.width >= 820 && win.contentMinSize.height >= 560, "Dashboard NSWindow contentMinSize must prevent squishing: \(win.contentMinSize)")
        expect(win.minSize.width >= 820 && win.minSize.height >= 588, "Dashboard NSWindow minSize mismatch: \(win.minSize)")

        for module in registry.modules {
            let texts = [module.name, module.tagline, module.aboutSummary] + module.featureTips
            for t in texts {
                expect(!t.contains("\u{2014}"), "Em dash found in module \(module.id) copy: \(t)")
            }
        }
        for mode in DockActionMode.allCases {
            expect(!mode.explanation.contains("\u{2014}"), "Em dash found in DockActionMode \(mode.rawValue)")
        }

        let activeIcon = MenuBarController.makeStatusBarIcon(isActive: true)
        let pausedIcon = MenuBarController.makeStatusBarIcon(isActive: false)
        expect(activeIcon.isTemplate && pausedIcon.isTemplate, "Status bar icons must be template images")
        expect(activeIcon.tiffRepresentation != pausedIcon.tiffRepresentation, "Active (filled) and paused (outlined) icons must differ")
    }

    private static func testScrollDirectionConfigAndMigration() {
        let cfg = ToolboxConfig()
        expect(!cfg.scrollDirection.enabled, "ScrollDirection should default to disabled (off by default)")
        expect(cfg.scrollDirection.target == .mouse, "ScrollDirection should default to inverting the mouse")

        if let data = try? JSONEncoder().encode(cfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.scrollDirection == cfg.scrollDirection, "ScrollDirectionConfig Codable round-trip mismatch")
            expect(decoded.schemaVersion == 10, "ToolboxConfig schemaVersion should be 10")
        } else {
            failures.append("ToolboxConfig Codable encode/decode failed")
        }

        // A config written by an older build has no scrollDirection key; it must decode
        // with the safe defaults instead of failing.
        let oldJSON = "{\"schemaVersion\": 2, \"general\": {\"appEnabled\": true}}"
        guard let data = oldJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) else {
            failures.append("Failed to decode pre-ScrollDirection config JSON")
            return
        }
        expect(!decoded.scrollDirection.enabled, "Legacy config should migrate ScrollDirection to disabled")
        expect(decoded.scrollDirection.target == .mouse, "Legacy config should migrate ScrollDirection target to mouse")

        let onJSON = "{\"schemaVersion\": 3, \"scrollDirection\": {\"enabled\": true, \"target\": \"trackpad\"}}"
        guard let data = onJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) else {
            failures.append("Failed to decode ScrollDirection config JSON")
            return
        }
        expect(decoded.scrollDirection.enabled, "ScrollDirection enabled should decode")
        expect(decoded.scrollDirection.target == .trackpad, "ScrollDirection target should decode")
    }

    private static func testScrollInversionClassificationAndInversion() {
        // Line based (classic mouse wheel) event: IsContinuous = 0.
        guard let mouseEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: -3, wheel3: 0) else {
            failures.append("Could not create test scroll event (line)")
            return
        }
        mouseEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        mouseEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 5)
        mouseEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -3)

        // Pixel based (trackpad / high resolution) event: IsContinuous = 1.
        guard let trackpadEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 42, wheel2: -17, wheel3: 0) else {
            failures.append("Could not create test scroll event (pixel)")
            return
        }
        trackpadEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        trackpadEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 42)
        trackpadEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -17)

        // Target = mouse: invert wheel events (line based), leave trackpad events untouched.
        expect(ScrollInversionTap.applyInversion(to: mouseEvent, target: .mouse), "Line based event should be inverted for the mouse target")
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -5, "Vertical line delta should be negated")
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 3, "Horizontal line delta should be negated")
        // The line fields are the master: negating them re-derives the pixel and fixed
        // point mirrors, so those follow the same sign flip (8 px per line).
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -40, "Derived pixel mirror should follow the negated master delta")
        expect(mouseEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 24, "Derived pixel mirror (horizontal) should follow the negated master delta")
        expect(!ScrollInversionTap.applyInversion(to: trackpadEvent, target: .mouse), "Pixel based event must NOT be inverted for the mouse target")
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 42, "Trackpad pixel delta must stay untouched for the mouse target")

        // Target = trackpad: invert pixel based events, leave wheel events untouched.
        guard let mouseEvent2 = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0) else { return }
        mouseEvent2.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        mouseEvent2.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 5)
        expect(!ScrollInversionTap.applyInversion(to: mouseEvent2, target: .trackpad), "Line based event must NOT be inverted for the trackpad target")
        expect(mouseEvent2.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 5, "Mouse line delta must stay untouched for the trackpad target")

        let trackpadDeltaBefore = trackpadEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        expect(ScrollInversionTap.applyInversion(to: trackpadEvent, target: .trackpad), "Pixel based event should be inverted for the trackpad target")
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -42, "Vertical pixel delta should be negated")
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 17, "Horizontal pixel delta should be negated")
        // The coarse line derivative on a pixel based event must not be touched,
        // because writing it would re-derive the pixel mirrors and destroy precision.
        expect(trackpadEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == trackpadDeltaBefore, "Coarse line derivative on pixel event must stay untouched")

        // Zero delta events must invert harmlessly (no-op) without crashing.
        guard let idle = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        idle.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        expect(ScrollInversionTap.applyInversion(to: idle, target: .mouse), "Zero delta event should still match the mouse target")

        // Mismatched events must still update lastObservedClass so smooth-scroll mice are surfaced in Live Status.
        let probeTap = ScrollInversionTap()
        probeTap.setTarget(.mouse)
        guard let mismatched = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0) else { return }
        mismatched.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        expect(!probeTap.processScrollWheelEvent(mismatched), "Continuous event should not be inverted when target is mouse")
        expect(probeTap.eventsInverted == 0, "eventsInverted should remain 0 on non-matching event")
        expect(probeTap.eventsObserved == 1 && probeTap.lastObservedClass == .trackpad, "lastObservedClass must track non-matching trackpad-style events")
    }

    private static func testScrollDirectionModuleLifecycleAndRegistry() {
        let registry = ModuleRegistry.shared
        let module = registry.scrollDirection
        expect(module.requiresAccessibility, "ScrollDirection must require Accessibility (it modifies events)")
        expect(module.category == .system, "ScrollDirection should be in the System category")
        expect(ModuleRegistry.shared.module(withID: "scroll_direction") === module, "Registry should resolve scroll_direction")

        // Status text is deterministic regardless of the live permission state.
        var off = ToolboxConfig()
        expect(module.statusText(in: off, accessibilityGranted: true) == "Disabled", "Disabled status text mismatch: \(module.statusText(in: off, accessibilityGranted: true))")
        off.scrollDirection.enabled = true
        off.general.appEnabled = false
        expect(module.statusText(in: off, accessibilityGranted: true) == "Paused", "Paused status text mismatch")
        off.general.appEnabled = true
        expect(module.statusText(in: off, accessibilityGranted: false) == "Needs Accessibility", "No-permission status text mismatch")

        // Lifecycle: enabled starts the module; the tap is installed only when allowed.
        var cfg = ToolboxConfig()
        cfg.scrollDirection.enabled = true
        module.reload(with: cfg)
        expect(module.isRunning, "Module should start when enabled")
        let granted = AXIsProcessTrusted()
        if granted {
            expect(module.isTapInstalled || module.statusText(in: cfg, accessibilityGranted: true) == "Standby",
                   "With Accessibility the tap should be installed (or report Standby)")
            let bgTap = ScrollInversionTap()
            if bgTap.install() {
                expect(bgTap.runsOnDedicatedBackgroundRunLoopForTesting, "ScrollInversionTap must run on a dedicated non-main background Thread CFRunLoop")
                bgTap.uninstall()
                expect(!bgTap.isInstalled, "ScrollInversionTap uninstall must clear tap")
            }
        } else {
            expect(!module.isTapInstalled, "Without Accessibility the tap must not be installed")
        }

        // Disabled always tears the tap down, in any permission state.
        cfg.scrollDirection.enabled = false
        module.reload(with: cfg)
        expect(!module.isRunning, "Module should stop when disabled")
        expect(!module.isTapInstalled, "Tap must be uninstalled when disabled")

        // Target change is applied to the tap without reinstall churn.
        cfg.scrollDirection.enabled = true
        cfg.scrollDirection.target = .trackpad
        module.reload(with: cfg)
        module.stop()
        expect(!module.isRunning, "stop() should deactivate the module")
    }

    private static func testDockMinimizeWindowsBehaviorAndPreFilter() {
        let cfg = DockMinimizeConfig()
        expect(cfg.actionMode == .hideApp, "Default DockActionMode should be .hideApp (Windows style hide & restore)")
        expect(DockActionMode.allCases.first == .hideApp, "DockActionMode.allCases should put .hideApp first")
        expect(Set(DockActionMode.allCases) == Set([.hideApp, .sendToBack, .minimizeAll, .minimizeFrontWindow]),
               "DockActionMode must contain all 4 modes")
        if let minimalData = "{\"enabled\": true}".data(using: .utf8),
           let decoded = try? JSONDecoder().decode(DockMinimizeConfig.self, from: minimalData) {
            expect(decoded.actionMode == .hideApp, "Decoded DockMinimizeConfig without actionMode should default to .hideApp")
        } else {
            failures.append("Failed to decode minimal DockMinimizeConfig JSON")
        }

        let primaryBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 960, y: 1050), inDisplayBounds: primaryBounds),
               "Bottom Dock edge point should pass pre-filter")
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 40, y: 540), inDisplayBounds: primaryBounds),
               "Left Dock edge point should pass pre-filter")
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 1880, y: 540), inDisplayBounds: primaryBounds),
               "Right Dock edge point should pass pre-filter")
        expect(!DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 100, y: 12), inDisplayBounds: primaryBounds),
               "Top menu bar point must be rejected by pre-filter")
        expect(!DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 960, y: 540), inDisplayBounds: primaryBounds),
               "Center of display must be rejected by pre-filter")

        let secondaryBounds = CGRect(x: 1920, y: 100, width: 1440, height: 900)
        expect(DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 2600, y: 970), inDisplayBounds: secondaryBounds),
               "Bottom Dock edge on offset secondary display should pass pre-filter")
        expect(!DockMinimizeModule.isPointNearDockEdge(CGPoint(x: 2000, y: 110), inDisplayBounds: secondaryBounds),
               "Top menu bar on offset secondary display must be rejected")
    }

    private static func testUpdateManagerAndCustomDialog() {
        expect(UpdateManager.isNewerVersion("1.1", than: "1.0"), "1.1 should be newer than 1.0")
        expect(UpdateManager.isNewerVersion("1.10", than: "1.9"), "1.10 should be newer than 1.9 numerically")
        expect(!UpdateManager.isNewerVersion("1.0", than: "1.0"), "Equal versions must not count as newer")
        expect(!UpdateManager.isNewerVersion("0.9", than: "1.0"), "Older version must not count as newer")
        expect(UpdateManager.isNewerVersion("1.2", than: "1.2-beta"), "Plain release should supersede suffixed prerelease")
        expect(!UpdateManager.isNewerVersion("1.2-beta", than: "1.2"), "Prerelease must not supersede plain release")

        let manager = UpdateManager.shared
        expect(!manager.currentVersion.isEmpty, "UpdateManager.currentVersion must not be empty")

        let baseNow = Date()
        manager.configureStateForTesting(lastCheckedAt: nil)
        expect(manager.formattedLastChecked(relativeTo: baseNow) == "Never", "Nil lastCheckedAt must format as Never")

        manager.configureStateForTesting(lastCheckedAt: baseNow.addingTimeInterval(-10))
        expect(manager.formattedLastChecked(relativeTo: baseNow).hasPrefix("Just now"), "Recent check must format as Just now")

        manager.configureStateForTesting(lastCheckedAt: baseNow.addingTimeInterval(-3600))
        let hourAgoFormatted = manager.formattedLastChecked(relativeTo: baseNow)
        expect(hourAgoFormatted.hasPrefix("Today at ") || hourAgoFormatted.hasPrefix("Yesterday at "),
               "Check from 1h ago formatted unexpectedly: \(hourAgoFormatted)")

        manager.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: true,
            checkProgress: 0.45,
            pendingUpdateVersion: nil,
            lastCheckedAt: baseNow
        )
        expect(manager.isChecking && manager.checkProgress == 0.45, "Checking progress state mismatch")

        manager.configureStateForTesting(
            isSparkleAvailable: true,
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: "1.1",
            pendingUpdateSizeBytes: 2_500_000,
            lastCheckedAt: baseNow
        )
        expect(manager.pendingUpdateVersion == "1.1", "pendingUpdateVersion mismatch")
        expect(manager.formattedPendingSize != nil, "formattedPendingSize should format non-zero byte counts")

        let dialog = ToolboxUpdateWindowController()
        dialog.populatePreviewAvailable(
            version: "1.1",
            currentVersion: "1.0",
            sizeBytes: 2_500_000,
            notes: "<p><b>New Update</b></p>"
        )
        expect(dialog.currentTitleForTesting == "Toolbox v1.1 Available", "Custom update dialog title mismatch")
        expect(dialog.currentSubtitleForTesting.contains("v1.0"), "Custom update dialog subtitle must include current version")
        expect(!dialog.window.isVisible, "populatePreviewAvailable must stay offscreen during headless testing")

        manager.configureStateForTesting(
            isChecking: false,
            checkProgress: 0,
            pendingUpdateVersion: nil,
            lastCheckedAt: nil
        )
    }

    private static func testMenuBarCustomizationOrderAndVisibility() {
        var cfg = ToolboxConfig()
        let registry = ModuleRegistry.shared
        let expectedDefaultOrder = ["dock_minimize", "clipboard", "port_killer", "screen_ocr", "keep_awake", "custom_commands", "scroll_direction", "call_controls"]

        expect(!cfg.general.hasCustomMenuBarLayout, "Default config should not report custom menu bar layout")
        expect(cfg.general.showQuickActionsInMenuBar, "Quick actions should be shown in menu bar by default")
        expect(cfg.general.showQuickCommandsInMenuBar, "Quick commands should be shown in menu bar by default")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "Default menu bar module order mismatch: \(registry.orderedMenuBarModules(for: cfg).map(\.id))"
        )
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "All 8 menu-bar-eligible modules should be visible in menu bar by default"
        )

        cfg.general.moveModuleInMenuBar(id: "keep_awake", direction: -1)
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["dock_minimize", "clipboard", "port_killer", "keep_awake", "screen_ocr", "custom_commands", "scroll_direction", "call_controls"],
            "Moving keep_awake up by 1 should place it before screen_ocr"
        )
        expect(cfg.general.hasCustomMenuBarLayout, "Reordering should mark hasCustomMenuBarLayout = true")

        cfg.general.moveModuleInMenuBar(fromId: "scroll_direction", toId: "dock_minimize")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "dock_minimize", "clipboard", "port_killer", "keep_awake", "screen_ocr", "custom_commands", "call_controls"],
            "Dragging scroll_direction to dock_minimize should place it first"
        )

        cfg.general.setModuleVisibleInMenuBar("dock_minimize", visible: false)
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "clipboard", "port_killer", "keep_awake", "screen_ocr", "custom_commands", "call_controls"],
            "Hiding dock_minimize from menu bar should omit it from visibleMenuBarModules"
        )
        expect(cfg.dockMinimize.enabled, "Hiding dock_minimize from status bar menu must not disable the module itself")

        cfg.general.menuBarModuleOrder = ["keep_awake", "clean_lock", "keep_awake", "unknown_id"]
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["keep_awake", "dock_minimize", "clipboard", "port_killer", "screen_ocr", "custom_commands", "scroll_direction", "call_controls"],
            "Partial, non-menu-bar, or unknown menuBarModuleOrder must normalize with remaining eligible modules and no duplicates"
        )

        cfg.general.showQuickActionsInMenuBar = false
        cfg.general.showQuickCommandsInMenuBar = false
        expect(cfg.general.hasCustomMenuBarLayout, "Hiding quick actions/commands should mark custom layout")

        cfg.general.resetMenuBarLayout()
        expect(!cfg.general.hasCustomMenuBarLayout, "resetMenuBarLayout must clear custom layout state")
        expect(registry.visibleMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder, "resetMenuBarLayout must restore default visible modules")
        expect(cfg.general.showQuickActionsInMenuBar && cfg.general.showQuickCommandsInMenuBar, "resetMenuBarLayout must restore quick actions & quick commands")
    }

    private static func testPortScannerParsersAndElevatedMerge() {
        let syntheticLsof = """
        p1234
        cnode
        u501
        f19
        n127.0.0.1:3000
        f20
        n[::1]:3000
        f21
        n127.0.0.1:9229
        p5678
        cpython3.11
        u501
        f5
        n*:8080
        """

        let syntheticNetstat = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state
        tcp4       0      0  127.0.0.1.3000         *.*                    LISTEN                 0            0  131072  131072             node:1234   00100
        tcp6       0      0  ::1.3000               *.*                    LISTEN                 0            0  131072  131072             node:1234   00100
        tcp4       0      0  *.80                   *.*                    LISTEN                 0            0  131072  131072            nginx:412    00100
        tcp4       0      0  127.0.0.1.49401        *.*                    LISTEN                 0            0  131072  131072 Antigravity Help:1616   00100
        tcp4       0      0  127.0.0.1.8000         127.0.0.1.51603        ESTABLISHED          760         2122  408000  146988       python3.11:1384   00102
        """

        let lsofRecs = PortScanner.parseLsofOutput(syntheticLsof)
        let netstatRecs = PortScanner.parseNetstatOutput(syntheticNetstat)

        expect(lsofRecs.count == 4, "Expected 4 lsof socket records, got \(lsofRecs.count)")
        expect(netstatRecs.count == 4, "Expected 4 netstat LISTEN records (ignoring ESTABLISHED), got \(netstatRecs.count)")
        expect(netstatRecs.contains(where: { $0.pid == 1616 && $0.command == "Antigravity Help" && $0.port == 49401 }), "netstat parser should preserve spaces in process names")

        let merged = PortScanner.mergeAndDeduplicate(
            lsofRecords: lsofRecs,
            netstatRecords: netstatRecs,
            currentUID: 501
        ) { pid in
            if pid == 412 {
                return ProcessMetadata(command: "nginx", uid: 0, executablePath: "/opt/homebrew/bin/nginx", workingDirectory: "/etc/nginx")
            }
            if pid == 1234 {
                return ProcessMetadata(command: "node", uid: 501, executablePath: "/usr/local/bin/node", workingDirectory: "/Users/dev/myapp")
            }
            return ProcessMetadata(command: nil, uid: nil, executablePath: nil, workingDirectory: nil)
        }

        // Expect: 412:80, 1234:3000 (deduped), 5678:8080, 1234:9229, 1616:49401 -> 5 entries
        expect(merged.count == 5, "Expected 5 deduplicated entries, got \(merged.count)")

        if let node3000 = merged.first(where: { $0.pid == 1234 && $0.port == 3000 }) {
            expect(node3000.addresses == ["127.0.0.1", "[::1]"], "Dual-stack node:3000 should collapse IPv4+IPv6: \(node3000.addresses)")
            expect(node3000.bindDisplay == "localhost (IPv4 + IPv6)", "bindDisplay mismatch: \(node3000.bindDisplay)")
            expect(!node3000.requiresElevation, "Same-UID process must not require elevation")
            expect(node3000.cwdBasename == "myapp", "cwdBasename mismatch: \(node3000.cwdBasename ?? "nil")")
        } else {
            failures.append("Missing merged entry for node:3000")
        }

        expect(merged.contains(where: { $0.pid == 1234 && $0.port == 9229 }), "Multi-port process should keep distinct (pid, port) entries")

        if let nginx80 = merged.first(where: { $0.pid == 412 && $0.port == 80 }) {
            expect(nginx80.requiresElevation, "Root-owned nginx:80 must be marked requiresElevation = true")
            expect(nginx80.ownerLabel == "root", "Root-owned nginx:80 ownerLabel should be 'root'")
            expect(!nginx80.seenInLsof, "Root-owned nginx:80 was surfaced via netstat, not lsof")
            expect(!nginx80.isSystemDaemon, "Root dev server nginx must not be hidden as an Apple system daemon")
        } else {
            failures.append("Missing root-owned nginx:80 entry from netstat merge")
        }
    }

    private static func testPortKillerSafetyAndLiveLoopbackListener() {
        expect(!PortKillerModule.validateKillTarget(pid: 0), "Must refuse PID 0")
        expect(!PortKillerModule.validateKillTarget(pid: 1), "Must refuse PID 1 (launchd)")
        expect(!PortKillerModule.validateKillTarget(pid: -1), "Must refuse negative PID")
        expect(!PortKillerModule.validateKillTarget(pid: ProcessInfo.processInfo.processIdentifier), "Must refuse self PID")
        expect(PortKillerModule.validateKillTarget(pid: 999_999), "Should allow normal non-self PID > 1")

        let module = PortKillerModule()
        let panel = module.ensurePanel()
        expect(!panel.hidesOnDeactivate, "PortKiller nonactivatingPanel must set hidesOnDeactivate = false")
        expect(panel.acceptsMouseMovedEvents, "PortKiller panel must accept mouse moved events for hover tooltips and cursors")
        expect(
            panel.contentView?.subviews.contains(where: { $0 is PointerCursorHostingView<PortKillerPopoverView> }) == true,
            "PortKiller panel must use PointerCursorHostingView to preserve hover cursors across layout and cursorUpdate"
        )

        // Verify PortKillerTooltipState respects 0.5s delay and exit-after-enter race protection
        let tipState = PortKillerTooltipState()
        var presented: HoverTooltipTarget?
        tipState.onPresent = { presented = $0 }
        tipState.setTooltip(HoverTooltipTarget(id: "btnA", text: "A", screenRect: CGRect(x: 10, y: 10, width: 20, height: 20)))
        expect(presented == nil, "Tooltip must wait 0.5s before presenting")
        tipState.setTooltip(HoverTooltipTarget(id: "btnB", text: "B", screenRect: CGRect(x: 40, y: 10, width: 20, height: 20)))
        tipState.setTooltip(nil, clearingID: "btnA") // Delayed exit from A must NOT cancel B
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        expect(presented?.id == "btnB", "Delayed exit for previous control must not cancel newer hovered tooltip")
        tipState.setTooltip(nil)
        expect(presented == nil, "Clearing tooltip state must hide presented tooltip")

        // Verify tooltip presents in an ignoresMouseEvents child NSPanel without mutating the popover hosting view
        panel.setFrame(NSRect(x: -5000, y: -5000, width: 400, height: 400), display: true)
        panel.orderFrontRegardless()
        let hostingView = panel.contentView?.subviews.first { $0 is PointerCursorHostingView<PortKillerPopoverView> }
        let hostingSubviewsBefore = hostingView?.subviews.count ?? -1
        module.updateTooltipPanel(
            with: HoverTooltipTarget(
                id: "test.tip",
                text: "Graceful Stop (SIGTERM)",
                screenRect: CGRect(x: -4720, y: -4760, width: 44, height: 20)
            ),
            requireMouseInside: false
        )
        let tipPanel = module.tooltipPanel
        expect(tipPanel != nil, "Tooltip must allocate a dedicated child NSPanel")
        expect(tipPanel?.ignoresMouseEvents == true, "Tooltip panel must ignore mouse events so hover stays on button")
        expect(tipPanel?.parent === panel, "Tooltip panel must attach as a child window of the popover panel")
        expect((hostingView?.subviews.count ?? -1) == hostingSubviewsBefore, "Presenting tooltip must not mutate popover hosting view")
        module.updateTooltipPanel(with: nil)
        expect(tipPanel?.parent == nil && tipPanel?.isVisible == false, "Clearing tooltip must detach and hide child panel")
        panel.orderOut(nil)

        // Bind a real ephemeral TCP loopback socket and verify PortScanner detects it live
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        expect(fd >= 0, "Should create test loopback socket")
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        expect(bindResult == 0, "Should bind test loopback socket to 127.0.0.1:0")
        expect(Darwin.listen(fd, 1) == 0, "Should listen on test loopback socket")

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(fd, saPtr, &len)
            }
        }
        expect(nameResult == 0, "getsockname should succeed")
        let assignedPort = Int(UInt16(bigEndian: boundAddr.sin_port))
        expect(assignedPort > 0, "Assigned ephemeral port should be > 0")

        let scannedPorts = PortScanner.scanListeningPortsSync()

        let selfPID = ProcessInfo.processInfo.processIdentifier
        expect(
            scannedPorts.contains(where: { $0.pid == selfPID && $0.port == assignedPort }),
            "Live PortScanner.scanListeningPortsSync() should detect self PID \(selfPID) listening on :\(assignedPort)"
        )
    }

    private static func testDeveloperModeAndSimulations() {
        let suiteName = "com.toolbox.selftest.devmode.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            failures.append("Failed to allocate isolated UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let devMode = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(!devMode.isUnlocked, "Developer mode must be locked by default")
        expect(!devMode.isPinPromptPresented, "PIN prompt must be hidden by default")
        expect(!devMode.stayUnlockedAcrossLaunches, "Session-only unlock should default to false")
        expect(devMode.unlockProgressHint == nil, "No hint should show before 2 taps")

        expect(!devMode.registerAboutHeaderTap(), "Tap 1 must not trigger PIN prompt")
        expect(devMode.unlockProgressHint == nil, "Tap 1 must not show hint yet")
        expect(!devMode.registerAboutHeaderTap(), "Tap 2 must not trigger PIN prompt")
        expect(devMode.unlockProgressHint == "3 more clicks to enter developer PIN", "Tap 2 hint mismatch: \(devMode.unlockProgressHint ?? "nil")")
        expect(!devMode.registerAboutHeaderTap(), "Tap 3 must not trigger PIN prompt")
        expect(!devMode.registerAboutHeaderTap(), "Tap 4 must not trigger PIN prompt")
        expect(devMode.unlockProgressHint == "1 more click to enter developer PIN", "Tap 4 hint mismatch: \(devMode.unlockProgressHint ?? "nil")")
        expect(devMode.registerAboutHeaderTap(), "Tap 5 must trigger PIN prompt")
        expect(devMode.isPinPromptPresented, "Tap 5 should present PIN prompt")
        expect(!devMode.isUnlocked, "Tap 5 must NOT bypass the PIN gate")
        expect(devMode.unlockProgressHint == nil, "Hint must clear once PIN prompt triggers")

        // Verify PIN validation, brute-force rate limiting, and cooldown recovery
        expect(!devMode.verifyPIN("0000") && devMode.verifyPIN("1708"), "PIN verification mismatch")
        let t0 = Date()
        expect(devMode.submitPIN("1111", now: t0) == .wrongPin(remainingAttempts: 4), "Attempt 1 wrong PIN mismatch")
        expect(devMode.submitPIN("2222", now: t0) == .wrongPin(remainingAttempts: 3), "Attempt 2 wrong PIN mismatch")
        expect(devMode.submitPIN("3333", now: t0) == .wrongPin(remainingAttempts: 2), "Attempt 3 wrong PIN mismatch")
        expect(devMode.submitPIN("4444", now: t0) == .wrongPin(remainingAttempts: 1), "Attempt 4 wrong PIN mismatch")
        expect(devMode.submitPIN("5555", now: t0) == .lockedOut(remainingSeconds: 15), "Attempt 5 should trigger 15s lockout")
        expect(devMode.submitPIN("1708", now: t0.addingTimeInterval(2)) == .lockedOut(remainingSeconds: 13), "Even correct PIN must be blocked during lockout")
        expect(!devMode.isUnlocked, "Must stay locked during cooldown")

        expect(devMode.submitPIN("1708", now: t0.addingTimeInterval(16)) == .unlocked, "Correct PIN after cooldown should unlock")
        expect(devMode.isUnlocked && !devMode.isPinPromptPresented, "Unlock should dismiss PIN prompt")

        // Session-only by default (does not persist unless opt-in is enabled)
        let sessionReload = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(!sessionReload.isUnlocked, "Developer mode must re-lock across launches by default")

        // Opt-in persistent unlock
        devMode.stayUnlockedAcrossLaunches = true
        let persistedReload = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(persistedReload.isUnlocked, "Developer mode should persist when stayUnlockedAcrossLaunches is enabled")
        persistedReload.lock()
        let postLockReload = DeveloperModeManager(userDefaults: testDefaults, isSessionOnly: false)
        expect(!postLockReload.isUnlocked, "Explicit lock() must require PIN on next launch")

        // Developer sections, presets, and release notes templates
        expect(DeveloperSection.allCases.count == 7 && DeveloperSection.allCases.contains(.screenOCR) && DeveloperSection.allCases.contains(.callControls), "Expected 7 DeveloperSection cases including .screenOCR and .callControls")
        expect(
            UpdateSimulationPreset.allCases.allSatisfy { !$0.summary.isEmpty },
            "All UpdateSimulationPreset cases should have non-empty summaries"
        )
        devMode.selectedReleaseNotesPreset = .longScrollable
        expect(
            devMode.effectiveReleaseNotesHTML(for: "2.0.0").contains("Bug Fixes &amp; Hardening"),
            "Long release notes preset should populate extended changelog HTML"
        )
        devMode.selectedErrorPreset = .eddsaSignatureInvalid
        expect(
            devMode.simulatedUpdateError.contains("SUPublicEDKey"),
            "Selecting UpdateErrorPreset should update simulatedUpdateError"
        )
        devMode.selectedErrorPreset = .networkTimeout
        devMode.selectedReleaseNotesPreset = .standard

        // Navigation pruning when locking
        let nav = NavigationState()
        nav.navigate(to: .settings)
        nav.navigate(to: .developer(.eventsAndTaps))
        nav.navigate(to: .developer(.hotKeysAndConfig))
        expect(nav.selection == .developer(.hotKeysAndConfig), "NavigationState should allow .developer subsections")
        nav.pruneDeveloperDestinations(fallback: .settings)
        expect(nav.selection == .settings, "pruneDeveloperDestinations should navigate away from .developer destinations")
        expect(
            !nav.history.contains {
                if case .developer = $0 { return true }
                return false
            },
            "pruneDeveloperDestinations should remove all .developer destinations from history"
        )

        // UpdateManager simulation presets
        let updateMgr = UpdateManager.shared
        updateMgr.applySimulationPreset(.updateAvailable, version: "2.4.0", sizeBytes: 4_200_000)
        expect(updateMgr.isSimulatingState, "isSimulatingState should be true during preset simulation")
        expect(updateMgr.activeSimulationPreset == .updateAvailable, "activeSimulationPreset mismatch")
        expect(updateMgr.pendingUpdateVersion == "2.4.0", "Simulated pendingUpdateVersion mismatch")
        expect(updateMgr.pendingReleaseNotesHTML?.contains("Toolbox v2.4.0") == true, "Simulated release notes should reference simulated version")

        updateMgr.applySimulationPreset(.checking)
        expect(updateMgr.isChecking && updateMgr.checkProgress == 0.62, "Checking preset should hold at 62%")

        updateMgr.applySimulationPreset(.checkFailed, errorMessage: "Simulated timeout")
        expect(updateMgr.lastCheckFailed && updateMgr.lastCheckError == "Simulated timeout", "Check failed preset mismatch")

        // One-shot 5s background schedule test & cancel/restore
        updateMgr.setDeveloperScheduleInterval(5)
        expect(
            updateMgr.isUsingCustomScheduleInterval
                && Int(updateMgr.scheduledCheckIntervalSeconds) == 5
                && updateMgr.customScheduleNextFireDate != nil,
            "5s dev schedule test should set scheduledCheckIntervalSeconds and start a live countdown"
        )
        updateMgr.setDeveloperScheduleInterval(nil)
        expect(
            !updateMgr.isUsingCustomScheduleInterval
                && Int(updateMgr.scheduledCheckIntervalSeconds) == Int(UpdateManager.defaultCheckIntervalSeconds)
                && updateMgr.customScheduleNextFireDate == nil,
            "Clearing dev schedule interval should restore default and clear custom countdown"
        )
        let initialBgCount = updateMgr.backgroundChecksCount
        updateMgr.recordBackgroundCheckOutcome("Up to date (v1.1)")
        expect(
            updateMgr.backgroundChecksCount == initialBgCount + 1 && updateMgr.lastBackgroundCheckAt != nil && updateMgr.lastBackgroundCheckOutcome == "Up to date (v1.1)",
            "recordBackgroundCheckOutcome should increment counter and store timestamp/outcome"
        )

        // Update dialog centering over app window and screen fallback
        let screenVisible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let appFrame = NSRect(x: 300, y: 120, width: 960, height: 680)
        let centeredOnApp = ToolboxUpdateWindowController.centeredOrigin(
            for: NSSize(width: 468, height: 344),
            relativeTo: appFrame,
            within: screenVisible
        )
        expect(
            centeredOnApp.x == 546 && centeredOnApp.y == 288,
            "Update dialog should center over Toolbox window, got \(centeredOnApp)"
        )
        let centeredOnScreen = ToolboxUpdateWindowController.centeredOrigin(
            for: NSSize(width: 468, height: 196),
            relativeTo: nil,
            within: screenVisible
        )
        expect(
            centeredOnScreen.x == 486 && centeredOnScreen.y == 340,
            "Update dialog should center vertically on screen when main window is closed, got \(centeredOnScreen)"
        )
        let clampedOrigin = ToolboxUpdateWindowController.centeredOrigin(
            for: NSSize(width: 468, height: 344),
            relativeTo: NSRect(x: 1300, y: 800, width: 400, height: 300),
            within: screenVisible
        )
        expect(
            clampedOrigin.x == screenVisible.maxX - 468 && clampedOrigin.y == screenVisible.maxY - 344,
            "Update dialog centering should clamp inside screen visibleFrame, got \(clampedOrigin)"
        )

        // PermissionsManager UI override
        let perms = PermissionsManager.shared
        let liveActual = perms.actualAccessibilityGranted
        perms.setSimulatedAccessibilityGranted(!liveActual)
        expect(perms.isAccessibilityGranted == !liveActual, "Simulated accessibility override must update UI state")
        expect(perms.actualAccessibilityGranted == liveActual, "Simulated accessibility override must not alter actualAccessibilityGranted")

        // Health checks & appcast XML parsing
        let checks = DeveloperHealthCheckRunner.shared.runAllChecks()
        expect(checks.count == 10, "Expected 10 preflight health checks, got \(checks.count)")
        expect(checks.contains(where: { $0.id == "security_hardening" }), "Expected security_hardening health check")
        expect(checks.contains(where: { $0.id == "login_app_policy" }), "Expected login_app_policy health check")
        expect(checks.contains(where: { $0.id == "simulation_guard" && $0.severity == .warning }), "Simulation guard check should warn while overrides are active")

        let sampleSpctl = "/Applications/Toolbox.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example (TEAMID)"
        expect(
            DeveloperHealthCheckRunner.parseGatekeeperSource(from: sampleSpctl) == "Notarized Developer ID",
            "Gatekeeper source parser mismatch"
        )

        let sampleAppcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
              <enclosure url="https://example.com/Toolbox.zip" sparkle:version="1.3.0" />
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        let parsedVersions = DeveloperHealthCheckRunner.parseAppcastVersions(from: sampleAppcast)
        expect(parsedVersions == ["1.3.0"], "Appcast XML version parser mismatch: \(parsedVersions)")

        // Runtime diagnostics snapshot & signing report
        let diag = RuntimeDiagnosticsSnapshot.capture()
        let report = diag.formattedReport(healthChecks: checks)
        let signingReport = diag.formattedSigningReport()
        expect(!diag.signing.signingIdentifier.isEmpty, "CodeSigningInspection should populate signingIdentifier")
        expect(!diag.architectureSummary.isEmpty && diag.pid > 0, "RuntimeDiagnosticsSnapshot should populate architecture and PID")
        expect(!diag.version.isEmpty && report.contains("Toolbox Diagnostics Report") && report.contains("Health Checks:") && report.contains("CDHash:"), "Diagnostics report should include header, CDHash, version, and health checks")
        expect(signingReport.contains("Toolbox Signing & Packaging Details") && signingReport.contains("Hardened Runtime:"), "Signing report should include hardened runtime and details")

        // Event log ring buffer, filtering, and export
        let eventLog = DeveloperEventLog.shared
        eventLog.clear()
        for idx in 0..<(DeveloperEventLog.maxEntries + 12) {
            eventLog.record(.dock, "Event \(idx)", detail: idx % 2 == 0 ? "tag-even" : nil)
        }
        expect(eventLog.entries.count == DeveloperEventLog.maxEntries, "DeveloperEventLog should cap at \(DeveloperEventLog.maxEntries) entries")
        expect(eventLog.entries.first?.message == "Event \(DeveloperEventLog.maxEntries + 11)", "DeveloperEventLog should store newest entries first")
        let filteredEvents = eventLog.filteredEntries(category: .dock, query: "tag-even")
        expect(!filteredEvents.isEmpty && filteredEvents.allSatisfy { $0.detail == "tag-even" }, "Event log filter mismatch")
        expect(eventLog.formattedExport(category: .dock, query: "tag-even").contains("Toolbox Event Log"), "Event log export mismatch")
        eventLog.clear()

        // Config checkpoint, diff, and section reset
        let checkpointStore = ConfigCheckpointStore.shared
        var baseCfg = ToolboxConfig()
        baseCfg.clipboard.maxItems = 50
        var modifiedCfg = baseCfg
        modifiedCfg.clipboard.maxItems = 99
        let diffs = ConfigCheckpointStore.diff(from: baseCfg, to: modifiedCfg)
        expect(
            diffs == [ConfigDiffItem(keyPath: "clipboard.maxItems", baselineValue: "50", currentValue: "99")],
            "Config diff mismatch: \(diffs)"
        )
        checkpointStore.saveCheckpoint(from: baseCfg)
        expect(!checkpointStore.diffsAgainstCheckpoint(current: modifiedCfg).isEmpty, "Checkpoint diff should detect changes")
        checkpointStore.clearCheckpoint()

        // HotKeyManager snapshot & simulated trigger
        let hkMgr = HotKeyManager.shared
        var didFireSimulatedHotKey = false
        _ = hkMgr.register(name: "dev.self_test.trigger", shortcut: ShortcutSpec.none) {}
        expect(!hkMgr.registeredHotKeys.contains(where: { $0.name == "dev.self_test.trigger" }), "Empty shortcut should not register")
        let regOK = hkMgr.register(name: "dev.self_test.trigger", shortcut: ShortcutSpec(key: "F19", modifiers: [.control, .option])) {
            didFireSimulatedHotKey = true
        }
        expect(regOK && hkMgr.registeredHotKeys.contains(where: { $0.name == "dev.self_test.trigger" }), "Registered hotkey should appear in snapshot")
        expect(hkMgr.simulateTrigger(name: "dev.self_test.trigger") && didFireSimulatedHotKey, "simulateTrigger should invoke registered handler")
        hkMgr.unregister(name: "dev.self_test.trigger")
        eventLog.clear()

        // Locking cleans up all simulations
        devMode.lock()
        expect(!devMode.isUnlocked, "lock() must disable Developer Tools")
        expect(!updateMgr.isSimulatingState && updateMgr.pendingUpdateVersion == nil, "lock() must clear UpdateManager simulation")
        expect(perms.simulatedAccessibilityGranted == nil, "lock() must clear PermissionsManager simulation")
    }

    private static func testCleanLockEventFilteringAndLifecycle() {
        // Config defaults & duration clamping
        let defaultCleanLock = CleanLockConfig()
        expect(!ModuleRegistry.shared.cleanLock.supportsEnableToggle, "CleanLock should not expose an enable/disable toggle")
        expect(!ModuleRegistry.shared.cleanLock.supportsMenuBar, "CleanLock should not appear in the Status Bar menu")
        expect(defaultCleanLock.durationSeconds == 60, "CleanLock default duration should be 60s")
        expect(defaultCleanLock.lockMouseAndTrackpad, "CleanLock should lock mouse & trackpad by default")
        expect(CleanLockConfig.clampedDuration(2) == 10, "Duration below 10s must clamp to 10s")
        expect(CleanLockConfig.clampedDuration(999) == 300, "Duration above 300s must clamp to 300s")
        expect(CleanLockConfig.clampedDuration(45) == 45, "In-range duration should be preserved")

        // Pure event filtering & kill-switch hold tests using synthesized CGEvents
        let tap = InputLockTap()
        let t0: TimeInterval = 1000.0
        tap.configureSession(lockMouseAndTrackpad: true, now: t0)

        // Sticky modifier grace (< 150ms) lets flagsChanged through without incrementing blockedCount
        if let flagsRelease = CGEvent(source: nil) {
            flagsRelease.type = .flagsChanged
            let decision = tap.evaluateEvent(flagsRelease, now: t0 + 0.05)
            expect(decision == .passThrough, "flagsChanged within sticky grace period should passThrough")
            expect(tap.currentBlockedCount == 0, "Grace period flagsChanged should not increment blockedCount")
        } else {
            failures.append("Failed to synthesize CGEvent for sticky modifier test")
        }

        // Keyboard keyDown ('A' = keyCode 0) after grace period should swallow & increment blockedCount
        if let keyA = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            let decision = tap.evaluateEvent(keyA, now: t0 + 0.5)
            expect(decision == .swallow, "keyDown('A') should be swallowed during Clean Lock")
            expect(tap.currentBlockedCount == 1, "Swallowed keyDown should increment blockedCount to 1")
        } else {
            failures.append("Failed to synthesize CGEvent for keyDown('A')")
        }

        // mouseMoved must always passThrough
        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ) {
            expect(tap.evaluateEvent(moveEvent, now: t0 + 0.6) == .passThrough, "mouseMoved must passThrough")
        }

        // Mouse click & scroll when lockMouseAndTrackpad == true -> swallow
        if let clickEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ) {
            expect(tap.evaluateEvent(clickEvent, now: t0 + 0.7) == .swallow, "leftMouseDown should swallow when lockMouseAndTrackpad is true")
        }
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 3,
            wheel2: 0,
            wheel3: 0
        ) {
            expect(tap.evaluateEvent(scrollEvent, now: t0 + 0.8) == .swallow, "scrollWheel should swallow when lockMouseAndTrackpad is true")
        }

        // Mouse click & scroll when lockMouseAndTrackpad == false -> passThrough
        tap.configureSession(lockMouseAndTrackpad: false, now: t0)
        if let clickEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        ) {
            expect(tap.evaluateEvent(clickEvent, now: t0 + 0.7) == .passThrough, "leftMouseDown should passThrough when lockMouseAndTrackpad is false")
        }
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 3,
            wheel2: 0,
            wheel3: 0
        ) {
            expect(tap.evaluateEvent(scrollEvent, now: t0 + 0.8) == .passThrough, "scrollWheel should passThrough when lockMouseAndTrackpad is false")
        }

        // Quick tap of Ctrl+Opt+Cmd+Esc released before 3s -> resets hold progress & stays locked
        tap.configureSession(lockMouseAndTrackpad: true, now: t0)
        let killFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        if let escDown1 = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(InputLockTap.escapeKeyCode), keyDown: true),
           let escUp1 = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(InputLockTap.escapeKeyCode), keyDown: false),
           let escDown2 = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(InputLockTap.escapeKeyCode), keyDown: true) {
            escDown1.flags = killFlags
            escUp1.flags = killFlags
            escDown2.flags = killFlags

            expect(tap.evaluateEvent(escDown1, now: t0 + 1.0) == .swallow, "Initial kill switch keyDown should swallow")
            expect(tap.currentKillSwitchProgress(now: t0 + 2.5) > 0.4, "Kill switch progress should advance while held")
            expect(tap.evaluateEvent(escUp1, now: t0 + 2.6) == .swallow, "Early Esc keyUp should swallow and reset")
            expect(tap.currentKillSwitchProgress(now: t0 + 2.7) == 0.0, "Early Esc release must reset kill switch progress")

            // Continuous hold >= 3s -> triggers .unlock while swallowing Esc
            expect(tap.evaluateEvent(escDown2, now: t0 + 3.0) == .swallow, "Restarted kill switch hold should swallow at 0s")
            expect(tap.evaluateEvent(escDown2, now: t0 + 5.9) == .swallow, "Kill switch hold at 2.9s should still swallow")
            expect(tap.evaluateEvent(escDown2, now: t0 + 6.0) == .unlock, "Kill switch hold >= 3.0s must trigger .unlock")

            // Post-unlock Esc release grace: swallow held Esc repeats/keyUp (avoiding macOS beep) while passing other keys through
            expect(tap.evaluateEvent(escDown2, now: t0 + 6.1) == .swallow, "Held Esc repeat right after unlock should be swallowed")
            if let keyA = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                expect(tap.evaluateEvent(keyA, now: t0 + 6.2) == .passThrough, "Other keys must passThrough immediately after unlock")
            }
            expect(tap.evaluateEvent(escUp1, now: t0 + 6.3) == .swallow, "Final Esc keyUp after unlock should be swallowed")
        } else {
            failures.append("Failed to synthesize Esc CGEvents for kill switch test")
        }

        // Countdown timer expiration & stop() teardown
        let module = ModuleRegistry.shared.cleanLock
        module.beginCountdownSession(durationSeconds: 10, lockMouseAndTrackpad: true, showHUD: false)
        expect(module.isLocked && module.remainingSeconds == 10, "Countdown session should enter locked state with 10s remaining")
        module.tickCountdown(now: Date().addingTimeInterval(11))
        expect(!module.isLocked && module.remainingSeconds == 0, "Timer reaching 0 must clear locked state")

        module.beginCountdownSession(durationSeconds: 15, lockMouseAndTrackpad: true, showHUD: false)
        expect(module.isLocked, "Countdown session should be locked before stop()")
        module.stop()
        expect(!module.isLocked, "stop() must cancel countdown and clear locked state")
    }

    private static func testCallControlsConfigAndCoreAudioEnumeration() {
        let cfg = ToolboxConfig()
        expect(cfg.schemaVersion == 10, "ToolboxConfig schemaVersion should be 10")
        expect(!cfg.callControls.enabled, "Call Controls should default to disabled")
        expect(cfg.callControls.overrideScope == .everywhere, "Default overrideScope should be everywhere")
        expect(cfg.callControls.typingUnmuteDelayMs == 450, "Default typingUnmuteDelayMs should be 450")
        expect(cfg.callControls.showFloatingMicIndicator, "showFloatingMicIndicator should default to true")
        expect(cfg.callControls.showVideoInFloatingIndicator, "showVideoInFloatingIndicator should default to true")
        expect(cfg.callControls.showFloatingPillOnlyDuringCalls, "showFloatingPillOnlyDuringCalls should default to true")
        expect(cfg.callControls.showToasts, "showToasts should default to true")

        let presetIDs = Set(cfg.callControls.appShortcutMappings.map(\.id))
        expect(
            presetIDs == Set(["teams", "zoom", "slack", "google_meet", "discord", "facetime"]),
            "Call Controls defaults should include all 6 built-in call apps: \(presetIDs)"
        )

        var customCfg = ToolboxConfig()
        customCfg.callControls.enabled = true
        customCfg.callControls.micShortcut = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        customCfg.callControls.videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
        customCfg.callControls.typingUnmuteDelayMs = 600
        customCfg.callControls.showVideoInFloatingIndicator = false
        customCfg.callControls.showFloatingPillOnlyDuringCalls = false
        customCfg.callControls.favoriteOutputUIDs = ["BuiltInSpeakerDevice"]

        if let data = try? JSONEncoder().encode(customCfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.callControls == customCfg.callControls, "CallControlsConfig Codable round-trip mismatch")
        } else {
            failures.append("CallControlsConfig Codable encode/decode failed")
        }

        // Legacy v5 config without callControls/audioGuard key must migrate cleanly
        let legacyJSON = "{\"schemaVersion\": 5, \"general\": {\"appEnabled\": true}}"
        if let data = legacyJSON.data(using: .utf8),
           let migrated = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(migrated.schemaVersion == 10, "Legacy config should upgrade to schemaVersion 10")
            expect(!migrated.callControls.enabled, "Legacy config must migrate callControls.enabled = false")
            expect(migrated.callControls.overrideScope == .everywhere, "Migrated default overrideScope should be everywhere")
            expect(migrated.callControls.showFloatingPillOnlyDuringCalls, "Legacy config must migrate showFloatingPillOnlyDuringCalls = true")
            expect(migrated.callControls.appShortcutMappings.count == 6, "Legacy config must populate 6 default call app presets")
        } else {
            failures.append("Failed to decode pre-CallControls JSON config")
        }

        // Legacy v6 config with active_call_app_only upgrades to everywhere
        let v6JSON = """
        {"schemaVersion": 6, "general": {"appEnabled": true}, "audioGuard": {"enabled": true, "overrideScope": "active_call_app_only"}}
        """
        if let data = v6JSON.data(using: .utf8),
           let upgraded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(upgraded.schemaVersion == 10, "v6 config should migrate to schemaVersion 10")
            expect(upgraded.callControls.overrideScope == .everywhere, "v6 active_call_app_only should upgrade to everywhere")
            expect(upgraded.callControls.showFloatingPillOnlyDuringCalls, "v6 config should upgrade showFloatingPillOnlyDuringCalls to true")
        } else {
            failures.append("Failed to migrate v6 audioGuard config")
        }

        // Legacy v7 config upgrades call-only pill default to true
        let v7JSON = """
        {"schemaVersion": 7, "general": {"appEnabled": true}, "audioGuard": {"enabled": true, "showFloatingPillOnlyDuringCalls": false}}
        """
        if let data = v7JSON.data(using: .utf8),
           let upgradedV7 = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(upgradedV7.schemaVersion == 10, "v7 config should migrate to schemaVersion 10")
            expect(upgradedV7.callControls.showFloatingPillOnlyDuringCalls, "v7 showFloatingPillOnlyDuringCalls should upgrade to true")
        } else {
            failures.append("Failed to migrate v7 audioGuard config")
        }

        // Legacy v8 config using audioGuard + audio_guard menu bar IDs must migrate cleanly to callControls + call_controls
        let v8JSON = """
        {"schemaVersion": 8, "general": {"appEnabled": true, "menuBarModuleOrder": ["dock_minimize", "audio_guard", "clipboard"], "menuBarHiddenModules": ["audio_guard"]}, "audioGuard": {"enabled": true, "typingUnmuteDelayMs": 725}}
        """
        if let data = v8JSON.data(using: .utf8),
           let upgradedV8 = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(upgradedV8.schemaVersion == 10, "v8 config should migrate to schemaVersion 10")
            expect(upgradedV8.callControls.enabled, "v8 audioGuard.enabled must migrate to callControls.enabled")
            expect(upgradedV8.callControls.typingUnmuteDelayMs == 725, "v8 audioGuard fields must be preserved in callControls")
            expect(
                upgradedV8.general.menuBarModuleOrder.contains("call_controls") && !upgradedV8.general.menuBarModuleOrder.contains("audio_guard"),
                "v8 menuBarModuleOrder must rewrite audio_guard to call_controls"
            )
            expect(
                upgradedV8.general.menuBarHiddenModules.contains("call_controls") && !upgradedV8.general.menuBarHiddenModules.contains("audio_guard"),
                "v8 menuBarHiddenModules must rewrite audio_guard to call_controls"
            )
        } else {
            failures.append("Failed to migrate v8 audioGuard config")
        }

        // CoreAudio & CoreMediaIO enumeration must complete safely even on headless Macs
        let devices = CoreAudioController.listDevices()
        for dev in devices {
            expect(dev.hasInput || dev.hasOutput, "Enumerated audio device \(dev.name) must have input or output channels")
        }
        _ = CoreAudioController.currentCameraStatus()
        _ = CoreAudioController.isDefaultInputRunningSomewhere()
    }

    private static func testCallControlsShortcutRemapper() {
        let micShortcut = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        let videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
        let spaceCode = UInt16(micShortcut.carbonKeyCode ?? 49)
        let vCode = UInt16(videoShortcut.carbonKeyCode ?? 9)
        var mappings = CallAppShortcutMapping.defaults

        // 1. Same-shortcut pass-through in Slack (Slack native mic is already Cmd+Shift+Space)
        let slackPass = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            frontmostPID: 101,
            frontmostWindowTitle: "Slack",
            runningApps: []
        )
        expect(slackPass == .passThrough, "Pressing Cmd+Shift+Space in Slack when micShortcut == Cmd+Shift+Space should passThrough")

        // 2. Microsoft Teams active -> remaps Cmd+Shift+Space to Cmd+Shift+M
        let teamsRemap = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.microsoft.teams2",
            frontmostPID: 202,
            frontmostWindowTitle: "Microsoft Teams",
            runningApps: []
        )
        if case .remap(let action, let app, let pid, let targetShortcut, let focusRestore) = teamsRemap {
            expect(action == .mic, "Teams remap action should be .mic")
            expect(app.id == "teams", "Target app should be Teams")
            expect(pid == 202, "Target PID should match frontmost Teams PID")
            expect(targetShortcut == ShortcutSpec(key: "m", modifiers: [.command, .shift]), "Teams mic target shortcut mismatch")
            expect(!focusRestore, "Frontmost Teams remap must not trigger background focus restore")
        } else {
            failures.append("Expected .remap for active Teams window, got \(teamsRemap)")
        }

        // 3. Toggled-off app is never matched
        if let idx = mappings.firstIndex(where: { $0.id == "teams" }) {
            mappings[idx].enabled = false
        }
        let disabledTeams = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.microsoft.teams2",
            frontmostPID: 202,
            frontmostWindowTitle: "Microsoft Teams",
            runningApps: []
        )
        expect(disabledTeams == .passThrough, "Disabled call app mapping must passThrough")
        if let idx = mappings.firstIndex(where: { $0.id == "teams" }) {
            mappings[idx].enabled = true
        }

        // 4. Non-call frontmost app passes through in activeCallAppOnly, and routes in activeOrRunningBackground
        let xcodePass = CallShortcutRemapper.resolveDecision(
            keyCode: vCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.apple.dt.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.microsoft.teams2", pid: 202, windowTitles: ["Teams"])]
        )
        expect(xcodePass == .passThrough, "Non-call app in activeCallAppOnly must passThrough")

        let backgroundTeams = CallShortcutRemapper.resolveDecision(
            keyCode: vCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeOrRunningBackground,
            mappings: mappings,
            frontmostBundleID: "com.apple.dt.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.microsoft.teams2", pid: 202, windowTitles: ["Teams"])]
        )
        if case .remap(let action, let app, let pid, let targetShortcut, let focusRestore) = backgroundTeams {
            expect(action == .video, "Background Teams action should be .video")
            expect(app.id == "teams", "Background target app should be Teams")
            expect(pid == 202, "Background target PID mismatch")
            expect(targetShortcut == ShortcutSpec(key: "o", modifiers: [.command, .shift]), "Teams video target shortcut mismatch")
            expect(focusRestore, "Background Teams remap should request brief focus restore")
        } else {
            failures.append("Expected .remap for background Teams in activeOrRunningBackground mode")
        }

        // 5. Window-title gate for Google Meet in Chrome
        let regularChrome = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.google.Chrome",
            frontmostPID: 404,
            frontmostWindowTitle: "GitHub - Pull Requests",
            runningApps: []
        )
        expect(regularChrome == .passThrough, "Regular Chrome tab without 'Meet' in title must passThrough")

        let meetChrome = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.google.Chrome",
            frontmostPID: 404,
            frontmostWindowTitle: "Meet - Weekly Standup",
            runningApps: []
        )
        if case .remap(let action, let app, _, let targetShortcut, _) = meetChrome {
            expect(action == .mic && app.id == "google_meet", "Chrome window titled 'Meet - Weekly Standup' should match Google Meet")
            expect(targetShortcut == ShortcutSpec(key: "d", modifiers: [.command]), "Google Meet mic shortcut should be Cmd+D")
        } else {
            failures.append("Expected .remap for Google Meet window in Chrome")
        }

        // 6. Synthetic event tag 0x544C4258 prevents infinite tap recursion
        let taggedEvent = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: CallShortcutRemapper.syntheticEventTag,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .activeCallAppOnly,
            mappings: mappings,
            frontmostBundleID: "com.microsoft.teams2",
            frontmostPID: 202,
            frontmostWindowTitle: "Microsoft Teams",
            runningApps: []
        )
        expect(taggedEvent == .passThrough, "Synthetic event carrying 0x544C4258 tag must always passThrough")

        // 7. Everywhere scope toggles hardware mic when no call app runs, relays to FaceTime when running, and syncs on same-key Slack
        let everywhereNoCall = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: mappings,
            frontmostBundleID: "com.apple.finder",
            frontmostPID: 501,
            frontmostWindowTitle: "Finder",
            runningApps: []
        )
        expect(everywhereNoCall == .globalHardwareOnly(action: .mic), "Everywhere scope without call app must return globalHardwareOnly(.mic)")

        let everywhereFaceTime = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: mappings,
            frontmostBundleID: "com.apple.finder",
            frontmostPID: 501,
            frontmostWindowTitle: "Finder",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.apple.FaceTime", pid: 601, windowTitles: ["FaceTime"])]
        )
        if case .remap(let action, let app, let pid, let targetShortcut, let focusRestore) = everywhereFaceTime {
            expect(action == .mic && app.id == "facetime" && pid == 601, "Everywhere scope should match running FaceTime in background")
            expect(targetShortcut == ShortcutSpec(key: "m", modifiers: [.command, .shift]), "FaceTime mic shortcut should be Cmd+Shift+M")
            expect(focusRestore, "FaceTime preset should allow fallback focus restore when needed")
        } else {
            failures.append("Expected .remap for running FaceTime in everywhere scope")
        }

        let everywhereSlackSame = CallShortcutRemapper.resolveDecision(
            keyCode: spaceCode,
            modifiers: [.command, .shift],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: mappings,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            frontmostPID: 101,
            frontmostWindowTitle: "Slack",
            runningApps: []
        )
        expect(everywhereSlackSame == .passThroughWithHardwareSync(action: .mic), "Everywhere scope with matching Slack native key must passThroughWithHardwareSync")

        expect(
            CallShortcutRemapper.axMenuModifiersMatch(1, expected: [.command, .shift]),
            "AX menu modifier 1 must match Command+Shift"
        )
        expect(
            CallShortcutRemapper.axMenuModifiersMatch(0, expected: [.command]),
            "AX menu modifier 0 must match Command only"
        )
        expect(
            !CallShortcutRemapper.axMenuModifiersMatch(8, expected: [.command]),
            "AX menu modifier 8 (kMenuNoCommandModifier) must not match Command"
        )

        // Menu control extraction & classification used by Add Call App auto-scan
        let parsedMic = CallShortcutRemapper.shortcutFromMenuItem(cmdChar: "M", virtualKey: nil, axMods: 1)
        expect(parsedMic == ShortcutSpec(key: "m", modifiers: [.command, .shift]), "AX menu item 'M' + mods 1 must parse to Cmd+Shift+M")

        let parsedVirtualSpace = CallShortcutRemapper.shortcutFromMenuItem(cmdChar: nil, virtualKey: 49, axMods: 1)
        expect(parsedVirtualSpace == ShortcutSpec(key: "space", modifiers: [.command, .shift]), "AX menu item virtualKey 49 + mods 1 must parse to Cmd+Shift+Space")

        expect(
            CallShortcutRemapper.classifyControlKind(title: "Mute Audio", menuPath: "Meeting > Mute Audio")?.kind == .mic,
            "'Mute Audio' should classify as .mic"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Start Video", menuPath: "Meeting > Start Video")?.kind == .video,
            "'Start Video' should classify as .video"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Quit App", menuPath: "File > Quit App") == nil,
            "Unrelated menu item 'Quit App' should not classify as mic or video"
        )

        // Verify PointerCursorNSView separates .cursorUpdate from .activeAlways (illegal AppKit combination)
        let pointerView = PointerCursorNSView()
        pointerView.frame = NSRect(x: 0, y: 0, width: 80, height: 28)
        pointerView.updateTrackingAreas()
        expect(pointerView.trackingAreas.count == 2, "PointerCursorNSView should install 2 distinct tracking areas (found \(pointerView.trackingAreas.count))")
        for area in pointerView.trackingAreas {
            let hasIllegalCombo = area.options.contains(.cursorUpdate) && area.options.contains(.activeAlways)
            expect(!hasIllegalCombo, "PointerCursorNSView must never combine .cursorUpdate with .activeAlways")
        }
    }

    private static func testCallControlsTypingMicStateMachine() {
        var sm = TypingMicStateMachine(isManuallyMuted: false, isTypingMuted: false, unmuteDelayMs: 450)
        expect(sm.unmuteDelaySeconds == 0.45, "Typing unmute delay should convert 450ms to 0.45s")

        // 1. Typing starts -> mute & schedule unmute; subsequent keys reschedule
        expect(sm.handleFilteredKeystroke() == .muteAndScheduleUnmute, "First keystroke should mute and schedule unmute")
        expect(sm.isTypingMuted, "isTypingMuted should become true")
        expect(sm.handleFilteredKeystroke() == .rescheduleUnmute, "Second keystroke should reschedule unmute")
        expect(sm.handleUnmuteTimerFired(), "Unmute timer firing should unmute when not manually muted")
        expect(!sm.isTypingMuted, "isTypingMuted should clear after unmute timer fires")

        // 2. Manual mute precedence: typing must NEVER unmute a manually muted mic
        _ = sm.setManualMute(true)
        expect(sm.isManuallyMuted && !sm.isTypingMuted, "setManualMute(true) must mark manual mute and clear typing mute")
        expect(sm.handleFilteredKeystroke() == .none, "Keystrokes while manually muted must return .none")
        expect(!sm.handleUnmuteTimerFired(), "Timer firing while manually muted must never unmute")

        // 3. Manual unmute clears manual mute cleanly
        _ = sm.setManualMute(false)
        expect(!sm.isManuallyMuted && !sm.isTypingMuted, "setManualMute(false) should clear manual mute")

        // 4. forceStopAndRestore forces unmute if typing-muted
        expect(sm.handleFilteredKeystroke() == .muteAndScheduleUnmute, "Keystroke after unmute should engage typing mute")
        expect(sm.forceStopAndRestore(), "forceStopAndRestore must return true while typing-muted")
        expect(!sm.isTypingMuted, "forceStopAndRestore must clear isTypingMuted")

        // 5. Keystroke filtering: Command/Control chords, call shortcuts, and synthetic tag are ignored
        let micShortcut = ShortcutSpec(key: "m", modifiers: [.option, .shift])
        let mCode = UInt16(micShortcut.carbonKeyCode ?? 46)
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: .maskCommand, eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Command chord must be ignored by typing detector"
        )
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: .maskControl, eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Control chord must be ignored by typing detector"
        )
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: [], eventUserData: CallShortcutRemapper.syntheticEventTag, ignoredShortcuts: []),
            "Synthetic 0x544C4258 event must be ignored by typing detector"
        )
        expect(
            TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: mCode, flags: [.maskAlternate, .maskShift], eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Configured call shortcut must be ignored by typing detector"
        )
        expect(
            !TypingMicStateMachine.shouldIgnoreKeystroke(keyCode: 0, flags: [], eventUserData: 0, ignoredShortcuts: [micShortcut]),
            "Plain typing keystroke 'A' must not be ignored"
        )
    }

    private static func testCallControlsHotKeyConflictsAndLifecycle() {
        let manager = HotKeyManager.shared
        var cfg = ToolboxConfig()
        cfg.callControls.enabled = true
        cfg.clipboard.enabled = true
        cfg.callControls.osMuteShortcut = cfg.clipboard.shortcut

        let conflict = manager.inAppConflictDescription(
            for: cfg.callControls.osMuteShortcut,
            excludingSourceID: "call_controls.os_mute",
            in: cfg
        )
        expect(conflict != nil, "HotKeyManager should detect collision between call_controls.os_mute and Clipboard")

        manager.clearConflictingShortcuts(
            matching: cfg.callControls.osMuteShortcut,
            excludingSourceID: "call_controls.os_mute",
            in: &cfg
        )
        expect(cfg.clipboard.shortcut.isEmpty, "clearConflictingShortcuts should clear colliding Clipboard shortcut")
        expect(!cfg.callControls.osMuteShortcut.isEmpty, "clearConflictingShortcuts must preserve excluded call_controls.os_mute")

        // Slack's Cmd+Shift+Space should not be falsely flagged via internal macOS hotkey slot 232
        let slackStyle = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        let sysConflictOnSlack = manager.systemOrMenuConflictDescription(for: slackStyle)
        expect(
            sysConflictOnSlack == nil,
            "Cmd+Shift+Space should not trigger a false-positive macOS system shortcut conflict unless explicitly configured by user (got: \(sysConflictOnSlack ?? "nil"))"
        )

        // Call Controls mic vs video collision check
        let shared = ShortcutSpec(key: "v", modifiers: [.command, .shift])
        cfg.callControls.micShortcut = shared
        cfg.callControls.videoShortcut = shared
        expect(
            manager.inAppConflictDescription(for: shared, excludingSourceID: "call_controls.video", in: cfg) != nil,
            "HotKeyManager should detect call_controls.mic vs call_controls.video collision"
        )
        manager.clearConflictingShortcuts(matching: shared, excludingSourceID: "call_controls.video", in: &cfg)
        expect(cfg.callControls.micShortcut.isEmpty, "clearConflictingShortcuts should clear colliding call_controls.mic shortcut")

        // Module lifecycle & deterministic statusText
        let callModule = ModuleRegistry.shared.callControls
        expect(ModuleRegistry.shared.module(withID: "call_controls") === callModule, "Registry must resolve call_controls")

        var statusCfg = ToolboxConfig()
        expect(callModule.statusText(in: statusCfg, accessibilityGranted: true) == "Disabled", "Disabled statusText mismatch")
        statusCfg.callControls.enabled = true
        statusCfg.general.appEnabled = false
        expect(callModule.statusText(in: statusCfg, accessibilityGranted: true) == "Paused", "Paused statusText mismatch")

        statusCfg.general.appEnabled = true
        statusCfg.callControls.micShortcut = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        expect(
            callModule.statusText(in: statusCfg, accessibilityGranted: false) == "Needs Accessibility",
            "Should report Needs Accessibility when unified keybind is set without permission"
        )

        let defaultCC = CallControlsConfig()
        expect(
            defaultCC.micShortcut == ShortcutSpec(key: "m", modifiers: [.control, .option, .command]),
            "Default CallControls micShortcut should be Ctrl+Option+Cmd+M"
        )
        expect(
            defaultCC.videoShortcut == ShortcutSpec(key: "v", modifiers: [.control, .option, .command]),
            "Default CallControls videoShortcut should be Ctrl+Option+Cmd+V"
        )

        let videoCapableSummary = CallControlsModule.videoCapableAppsSummary(from: CallAppShortcutMapping.defaults)
        expect(
            videoCapableSummary == "Teams, Zoom, or Meet",
            "Default video-capable summary should list Teams, Zoom, or Meet (got: \(videoCapableSummary))"
        )
        expect(
            CallControlsModule.videoUnavailableMessage(
                frontUnsupportedAppName: "FaceTime",
                anyUnsupportedAppName: "FaceTime",
                backgroundCapableAppName: nil,
                overrideScope: .everywhere,
                videoCapableSummary: videoCapableSummary
            ) == "FaceTime doesn't allow video shortcuts (macOS has no OS camera mute)",
            "Frontmost FaceTime video-unavailable toast should explain FaceTime doesn't allow video shortcuts"
        )
        expect(
            CallControlsModule.videoUnavailableMessage(
                frontUnsupportedAppName: nil,
                anyUnsupportedAppName: nil,
                backgroundCapableAppName: "Zoom",
                overrideScope: .activeCallAppOnly,
                videoCapableSummary: videoCapableSummary
            ) == "Focus Zoom or switch scope to Everywhere to toggle camera",
            "Active-app-only scope with background Zoom should prompt user to focus Zoom or change scope"
        )
        expect(
            CallControlsModule.videoUnavailableMessage(
                frontUnsupportedAppName: nil,
                anyUnsupportedAppName: nil,
                backgroundCapableAppName: nil,
                overrideScope: .everywhere,
                videoCapableSummary: videoCapableSummary
            ) == "Open Teams, Zoom, or Meet to toggle camera (macOS has no OS camera mute)",
            "Idle video-unavailable toast should accurately reflect enabled video-capable presets"
        )

        statusCfg.callControls.micShortcut = .none
        statusCfg.callControls.autoMuteWhileTyping = false
        callModule.reload(with: statusCfg)
        expect(callModule.isRunning, "CallControlsModule should start when enabled without requiring Accessibility for CoreAudio controls")
        callModule.stop()
        expect(!callModule.isRunning, "CallControlsModule.stop() must clear isRunning")
        expect(!callModule.isRemapperTapInstalled && !callModule.isTypingTapInstalled, "CallControlsModule.stop() must uninstall event taps")
    }

    private static func testCallControlsDeveloperSimulation() {
        let callModule = ModuleRegistry.shared.callControls
        let devManager = DeveloperModeManager.shared

        callModule.clearDeveloperSimulation()
        expect(!devManager.hasActiveSimulation, "hasActiveSimulation should be false initially")

        // 1. Zoom frontmost call preset + dry-run + interactive action simulation
        callModule.applyDeveloperSimulationPreset(.zoomCall)
        expect(callModule.developerSimulation != nil, "applyDeveloperSimulationPreset(.zoomCall) must populate developerSimulation")
        expect(devManager.hasActiveSimulation, "DeveloperModeManager.hasActiveSimulation must reflect active Call Controls simulation")

        var simConfig = CallControlsConfig()
        simConfig.enabled = true
        simConfig.overrideScope = .everywhere
        let micDecision = callModule.simulatedRoutingDecision(for: .mic, using: simConfig)
        if case .remap(let action, let targetApp, _, _, _) = micDecision {
            expect(action == .mic && targetApp.id == "zoom", "Simulated Zoom mic decision should remap to zoom")
        } else {
            failures.append("Simulated Zoom mic decision should return .remap (got: \(micDecision))")
        }
        let videoDecision = callModule.simulatedRoutingDecision(for: .video, using: simConfig)
        if case .remap(let action, let targetApp, _, _, _) = videoDecision {
            expect(action == .video && targetApp.id == "zoom", "Simulated Zoom video decision should remap to zoom")
        } else {
            failures.append("Simulated Zoom video decision should return .remap (got: \(videoDecision))")
        }

        let floatingState = FloatingMicIndicatorState()
        callModule.populateFloatingState(floatingState)
        expect(floatingState.hasInputDevice && !floatingState.isMuted, "Zoom preset should report live unmuted mic in FloatingMicIndicatorState")
        expect(floatingState.isCameraActive && floatingState.canToggleVideo, "Zoom preset should report live toggleable camera in FloatingMicIndicatorState")

        callModule.triggerSimulatedAction(.mic)
        expect(callModule.developerSimulation?.isMuted == true, "triggerSimulatedAction(.mic) should toggle simulated isMuted to true")
        callModule.triggerSimulatedAction(.video)
        expect(callModule.developerSimulation?.isCameraActive == false, "triggerSimulatedAction(.video) should toggle simulated isCameraActive to false")

        // 1b. Simulation dry-run parity: unbound keybind returns .passThrough unless fallback is requested, and respects Accessibility simulation & disabled apps
        var unboundConfig = simConfig
        unboundConfig.micShortcut = .none
        expect(
            callModule.simulatedRoutingDecision(for: .mic, using: unboundConfig, fallbackToDefaultIfUnbound: false) == .passThrough,
            "Unbound mic shortcut must report .passThrough in routing dry-run"
        )
        if case .remap(let action, let app, _, _, _) = callModule.simulatedRoutingDecision(for: .mic, using: unboundConfig, fallbackToDefaultIfUnbound: true) {
            expect(action == .mic && app.id == "zoom", "Fallback-enabled mic test should resolve to zoom")
        } else {
            failures.append("Fallback-enabled mic test should return .remap")
        }

        var disabledZoomCfg = simConfig
        if let idx = disabledZoomCfg.appShortcutMappings.firstIndex(where: { $0.id == "zoom" }) {
            disabledZoomCfg.appShortcutMappings[idx].enabled = false
        }
        expect(
            callModule.simulatedRoutingDecision(for: .video, using: disabledZoomCfg) == .globalHardwareOnly(action: .video),
            "Disabling Zoom mapping should surface Video Blocked in simulation dry-run"
        )

        if let sim = callModule.developerSimulation {
            let ctx = CallControlsModule.buildSimulatedContext(sim: sim, config: simConfig)
            let micCode = UInt16(simConfig.micShortcut.carbonKeyCode ?? 46)
            let tapDecision = CallShortcutRemapper.resolveDecision(
                keyCode: micCode,
                modifiers: simConfig.micShortcut.modifiers,
                eventUserData: 0,
                micShortcut: simConfig.micShortcut,
                videoShortcut: simConfig.videoShortcut,
                overrideScope: simConfig.overrideScope,
                mappings: simConfig.appShortcutMappings,
                frontmostBundleID: ctx.frontmostBundleID,
                frontmostPID: ctx.frontmostPID,
                frontmostWindowTitle: ctx.frontmostWindowTitle,
                runningApps: ctx.runningApps
            )
            expect(
                tapDecision == callModule.simulatedRoutingDecision(for: .mic, using: simConfig),
                "Simulated tap context resolution must match simulatedRoutingDecision identically"
            )
        }

        // Simulated Accessibility = false blocks keybind actions, while pill mic click still toggles hardware mic
        callModule.developerSimulation?.isMuted = false
        callModule.developerSimulation?.simulateAccessibilityGranted = false
        callModule.triggerSimulatedAction(.mic, fallbackToDefaultIfUnbound: true, respectSimulatedAccessibility: true)
        expect(
            callModule.developerSimulation?.isMuted == false,
            "Keybind simulation must be blocked when simulateAccessibilityGranted == false"
        )
        callModule.toggleSimulatedMicFromPill()
        expect(
            callModule.developerSimulation?.isMuted == true,
            "Pill mic click must still toggle mic even when simulateAccessibilityGranted == false"
        )

        // reload(with: disabled) must preserve active developer simulation
        var disabledModuleCfg = ToolboxConfig()
        disabledModuleCfg.callControls.enabled = false
        callModule.reload(with: disabledModuleCfg)
        expect(callModule.developerSimulation != nil, "reload(with: disabled) must preserve active developerSimulation")

        // 2. FaceTime call preset must report video unavailable rather than toggling video
        callModule.applyDeveloperSimulationPreset(.faceTimeCall)
        let ftVideoDecision = callModule.simulatedRoutingDecision(for: .video, using: simConfig)
        expect(ftVideoDecision == .globalHardwareOnly(action: .video), "Simulated FaceTime video decision must fall back to .globalHardwareOnly(action: .video) (got: \(ftVideoDecision))")
        callModule.triggerSimulatedAction(.video)
        expect(
            callModule.lastSimulationOutcome?.contains("FaceTime") == true,
            "Simulated FaceTime video action outcome should mention FaceTime (got: \(callModule.lastSimulationOutcome ?? "nil"))"
        )

        // 3. HUDToast height consistency across different SF Symbols
        let toastSymbols: [(String, Color)] = [
            ("mic.fill", .green),
            ("mic.slash.fill", .red),
            ("video.fill", .blue),
            ("video.slash", .orange),
            ("keyboard", .orange),
            ("exclamationmark.triangle.fill", .orange),
            ("arrow.uturn.right.circle", .secondary)
        ]
        let toastHeights = toastSymbols.map { HUDToast.measuredSize(title: "Sample Toast Title", symbol: $0.0, tint: $0.1).height }
        expect(
            toastHeights.allSatisfy { abs($0 - HUDToast.fixedHeight) < 0.5 },
            "HUDToast height must remain constant (\(HUDToast.fixedHeight)pt) across all icons (got: \(toastHeights))"
        )
        let longToastWidth = HUDToast.measuredSize(
            title: "Focus Zoom or switch scope to Everywhere to toggle camera",
            symbol: "video.slash",
            tint: .orange
        ).width
        expect(longToastWidth > 320, "Long HUDToast must measure full natural width instead of clamping (got: \(longToastWidth))")

        // 4. Floating pill top-right frame stability when toggling Mic / Camera
        let testScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 950)
        for deviceName in ["AirPods", "MacBook Pro Microphone"] {
            let pillState = FloatingMicIndicatorState()
            pillState.inputDeviceName = deviceName
            pillState.showVideoStatus = true
            pillState.hasCameraDevice = true
            pillState.canToggleVideo = true
            pillState.videoTargetAppName = "Zoom"
            pillState.cameraDeviceName = "FaceTime HD"
            pillState.isCameraActive = true
            pillState.isMuted = false
            pillState.isTypingMuted = false

            let liveSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            expect(liveSize.width > 280 && liveSize.height == 44, "Dual Mic+Video pill should measure full natural width & 44pt height (got: \(liveSize))")
            let liveFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: liveSize, inVisibleFrame: testScreenFrame)

            pillState.isMuted = true
            let mutedSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            let mutedFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: mutedSize, inVisibleFrame: testScreenFrame)

            pillState.isTypingMuted = true
            let typingSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            let typingFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: typingSize, inVisibleFrame: testScreenFrame)

            expect(
                liveFrame == mutedFrame && liveFrame == typingFrame,
                "Top-right floating pill must not move or resize when toggling mute for '\(deviceName)' (live: \(liveFrame), muted: \(mutedFrame), typing: \(typingFrame))"
            )

            pillState.isTypingMuted = false
            pillState.isMuted = false
            pillState.isCameraActive = false
            pillState.videoTargetAppName = "Microsoft Teams"
            let camOffSize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            let camOffFrame = FloatingMicIndicatorPanel.defaultTopRightFrame(for: camOffSize, inVisibleFrame: testScreenFrame)
            expect(
                liveFrame == camOffFrame,
                "Top-right floating pill must not move or resize when toggling camera for '\(deviceName)' even with long app name (live: \(liveFrame), camOff: \(camOffFrame))"
            )

            pillState.showVideoStatus = false
            let micOnlySize = FloatingMicIndicatorPanel.measuredPillSize(for: pillState)
            expect(micOnlySize.width > 160 && micOnlySize.width < liveSize.width - 60, "Mic-only pill should shrink cleanly when video is hidden (got: \(micOnlySize))")
        }

        // 4b. Real FloatingMicIndicatorPanel: initial position == resetToDefaultPosition() and zero shift at very-most top-right
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let panel = FloatingMicIndicatorPanel(userDefaults: nil)
            panel.update(
                isMuted: false,
                isTypingMuted: false,
                inputDeviceName: "MacBook Pro Microphone",
                hasInputDevice: true,
                showVideoStatus: true,
                isCameraActive: true,
                cameraDeviceName: "FaceTime HD",
                hasCameraDevice: true,
                canToggleVideo: true,
                videoTargetAppName: "Microsoft Teams"
            )
            panel.show()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let initialFrame = panel.currentFrame

            let customDraggedOrigin = NSPoint(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.minY + 120)
            if let f = initialFrame {
                panel.recordDraggedFrameForTesting(NSRect(origin: customDraggedOrigin, size: f.size))
                panel.resetToDefaultPosition()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                expect(
                    panel.currentFrame == initialFrame,
                    "Floating pill resetToDefaultPosition() must match initial position identically (initial: \(String(describing: initialFrame)), reset: \(String(describing: panel.currentFrame)))"
                )

                // Move to very-most top-right (screenPadding = 6pt) and toggle Mic & Video
                let pad = FloatingMicIndicatorPanel.screenPadding
                let cornerFrame = NSRect(
                    x: round(screen.visibleFrame.maxX - f.size.width - pad),
                    y: round(screen.visibleFrame.maxY - f.size.height - pad),
                    width: f.size.width,
                    height: f.size.height
                )
                panel.recordDraggedFrameForTesting(cornerFrame)
                panel.update(
                    isMuted: true,
                    isTypingMuted: false,
                    inputDeviceName: "MacBook Pro Microphone",
                    hasInputDevice: true,
                    showVideoStatus: true,
                    isCameraActive: false,
                    cameraDeviceName: "FaceTime HD",
                    hasCameraDevice: true,
                    canToggleVideo: true,
                    videoTargetAppName: "Microsoft Teams"
                )
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                expect(
                    panel.currentFrame == cornerFrame,
                    "Pill dragged to very-most top-right must not shift when toggling Mic/Video (expected: \(cornerFrame), got: \(String(describing: panel.currentFrame)))"
                )
            } else {
                failures.append("FloatingMicIndicatorPanel.show() did not produce a valid frame")
            }
            panel.hide()

            // Regression test: clicking/hiding the pill while PointerCursorNSView deferred cursor sync
            // timers (RunLoop.main.perform, 0.04s, 0.2s) are pending must not crash on closed NSPanel.
            var hideCallbackInvoked = false
            panel.onHidePill = {
                hideCallbackInvoked = true
                panel.hide()
            }
            panel.show()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let f = panel.currentFrame {
                let center = NSPoint(x: f.width - 12, y: f.height / 2)
                let downEvent = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: center,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 1.0
                )
                let upEvent = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: center,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 0.0
                )
                if let downEvent { NSApp.postEvent(downEvent, atStart: false) }
                if let upEvent { NSApp.postEvent(upEvent, atStart: false) }
            }
            panel.onHidePill?()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            expect(hideCallbackInvoked, "Floating pill onHidePill callback must execute cleanly")
            expect(panel.currentFrame == nil, "Floating pill currentFrame must be nil after onHidePill -> hide()")
        }

        // 4c. New simulation presets, simulated scope override, device profile, and pill hide override
        callModule.applyDeveloperSimulationPreset(.teamsBackground)
        callModule.developerSimulation?.simulatedScopeOverride = .activeCallAppOnly
        expect(
            callModule.simulatedRoutingDecision(for: .mic, using: simConfig) == .passThrough,
            "simulatedScopeOverride = .activeCallAppOnly must override saved .everywhere scope for background Teams"
        )
        callModule.applyDeveloperSimulationPreset(.discordCall)
        expect(callModule.developerSimulation?.targetAppID == "discord", "Discord preset should target discord")
        callModule.applyDeveloperSimulationPreset(.noCallApp)
        expect(callModule.developerSimulation?.targetAppID == "none", "No Call App preset should target none")
        callModule.developerSimulation?.deviceProfile = .noHardware
        callModule.toggleSimulatedMicFromPill()
        expect(
            callModule.lastSimulationOutcome?.contains("No input microphone") == true,
            "No-hardware profile pill toggle must report missing microphone"
        )
        callModule.developerSimulation?.pillVisibilityMode = .forceHide
        expect(!callModule.isFloatingPillVisible, "pillVisibilityMode = .forceHide must hide desktop pill even if streams were active")

        // 5. DeveloperModeManager.resetAllSimulations() clears Call Controls simulation cleanly
        devManager.resetAllSimulations()
        expect(callModule.developerSimulation == nil, "resetAllSimulations() must clear CallControlsModule.developerSimulation")
        expect(!callModule.isRemapperTapInstalled, "resetAllSimulations() must uninstall simulation event tap when module is off")
        expect(!devManager.hasActiveSimulation, "hasActiveSimulation must be false after resetAllSimulations()")

        // 6. ToolboxConfigSection.callControls & pure ConfigCheckpointStore diff detection
        expect(ToolboxConfigSection.allCases.contains(.callControls), "ToolboxConfigSection must include .callControls")
        let checkpointCfg = ToolboxConfig()
        var modifiedCfg = checkpointCfg
        modifiedCfg.callControls.typingUnmuteDelayMs = 900
        let diffs = ConfigCheckpointStore.diff(from: checkpointCfg, to: modifiedCfg)
        expect(
            diffs == [ConfigDiffItem(keyPath: "callControls.typingUnmuteDelayMs", baselineValue: "450", currentValue: "900")],
            "ConfigCheckpointStore.diff should detect callControls changes cleanly (got: \(diffs))"
        )
        DeveloperEventLog.shared.clear()
    }

    private static func testScreenOCRConfigAndLifecycle() {
        // Defaults
        let cfg = ToolboxConfig()
        expect(!cfg.screenOCR.enabled, "ScreenOCR should default to disabled")
        expect(cfg.screenOCR.recognitionLevel == .accurate, "ScreenOCR should default to accurate recognition")
        expect(cfg.screenOCR.preserveLineBreaks, "ScreenOCR should default to preserving line breaks")
        expect(cfg.screenOCR.detectQRCodes, "ScreenOCR should default to detecting QR/barcodes")
        expect(cfg.screenOCR.showToast, "ScreenOCR should default to showing toasts")
        expect(
            cfg.screenOCR.shortcut == ShortcutSpec(key: "o", modifiers: [.control, .option, .command]),
            "ScreenOCR default shortcut should be ⌃ ⌥ ⌘ O"
        )

        // Codable round-trip
        var customCfg = ToolboxConfig()
        customCfg.screenOCR.enabled = true
        customCfg.screenOCR.recognitionLevel = .fast
        customCfg.screenOCR.preserveLineBreaks = false
        customCfg.screenOCR.detectQRCodes = false
        customCfg.screenOCR.showToast = false
        customCfg.screenOCR.shortcut = ShortcutSpec(key: "s", modifiers: [.control, .option, .command])
        if let data = try? JSONEncoder().encode(customCfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.screenOCR == customCfg.screenOCR, "ScreenOCRConfig Codable round-trip mismatch")
            expect(decoded.schemaVersion == 10, "ToolboxConfig schemaVersion should be 10")
        } else {
            failures.append("ToolboxConfig with screenOCR failed Codable encode/decode")
        }

        // A config written by the previous build (schema 9, no screenOCR key) must decode
        // with the safe defaults and upgrade the schema.
        let legacyJSON = "{\"schemaVersion\": 9, \"general\": {\"appEnabled\": true}}"
        if let data = legacyJSON.data(using: .utf8),
           let migrated = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(migrated.schemaVersion == 10, "Legacy v9 config should upgrade to schemaVersion 10")
            expect(!migrated.screenOCR.enabled, "Legacy config must migrate screenOCR.enabled = false")
        } else {
            failures.append("Failed to decode pre-ScreenOCR JSON config")
        }

        // A partial screenOCR object must fill missing keys with safe defaults.
        let partialJSON = "{\"schemaVersion\": 10, \"screenOCR\": {\"enabled\": true, \"recognitionLevel\": \"fast\"}}"
        if let data = partialJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.screenOCR.enabled && decoded.screenOCR.recognitionLevel == .fast, "Partial screenOCR decode mismatch")
            expect(
                decoded.screenOCR.preserveLineBreaks && decoded.screenOCR.detectQRCodes && decoded.screenOCR.showToast,
                "Partial screenOCR should fill missing fields with defaults"
            )
            expect(
                decoded.screenOCR.shortcut == ShortcutSpec(key: "o", modifiers: [.control, .option, .command]),
                "Partial screenOCR shortcut should default to ⌃ ⌥ ⌘ O"
            )
        } else {
            failures.append("Failed to decode partial screenOCR JSON")
        }

        // In-app hotkey conflict detection & one-click resolution
        let manager = HotKeyManager.shared
        var conflictCfg = ToolboxConfig()
        conflictCfg.screenOCR.enabled = true
        conflictCfg.clipboard.enabled = true
        conflictCfg.clipboard.shortcut = conflictCfg.screenOCR.shortcut
        let conflict = manager.inAppConflictDescription(
            for: conflictCfg.screenOCR.shortcut,
            excludingSourceID: "screen_ocr",
            in: conflictCfg
        )
        expect(conflict != nil, "HotKeyManager should detect collision between Screen OCR and Clipboard")
        manager.clearConflictingShortcuts(
            matching: conflictCfg.screenOCR.shortcut,
            excludingSourceID: "screen_ocr",
            in: &conflictCfg
        )
        expect(conflictCfg.clipboard.shortcut.isEmpty, "clearConflictingShortcuts should clear colliding Clipboard shortcut")
        expect(!conflictCfg.screenOCR.shortcut.isEmpty, "clearConflictingShortcuts must preserve excluded Screen OCR shortcut")

        // Registry & lifecycle (shortcut .none so no global hotkey is armed in the test process)
        let module = ModuleRegistry.shared.screenOCR
        expect(ModuleRegistry.shared.module(withID: "screen_ocr") === module, "Registry must resolve screen_ocr")
        expect(!module.requiresAccessibility, "ScreenOCR must not require Accessibility")
        expect(module.category == .developer, "ScreenOCR should be in the Developer Tools category")
        expect(module.supportsEnableToggle, "ScreenOCR should expose an enable toggle")

        var moduleCfg = ToolboxConfig()
        moduleCfg.screenOCR.enabled = true
        moduleCfg.screenOCR.shortcut = .none
        module.reload(with: moduleCfg)
        expect(module.isRunning, "Module should start when enabled")

        moduleCfg.screenOCR.enabled = false
        module.reload(with: moduleCfg)
        expect(!module.isRunning, "Module should stop when disabled")

        moduleCfg.screenOCR.enabled = true
        moduleCfg.general.appEnabled = false
        module.reload(with: moduleCfg)
        expect(!module.isRunning, "Module must stop when the whole app is paused")

        module.stop()
        expect(!module.isRunning, "stop() should clear isRunning")

        // Deterministic status text across permission states
        var statusCfg = ToolboxConfig()
        expect(module.statusText(in: statusCfg, accessibilityGranted: true) == "Disabled", "Disabled statusText mismatch")
        statusCfg.screenOCR.enabled = true
        statusCfg.general.appEnabled = false
        expect(module.statusText(in: statusCfg, accessibilityGranted: true) == "Paused", "Paused statusText mismatch")
        statusCfg.general.appEnabled = true
        module.setScreenRecordingGrantedForTesting(false)
        expect(
            module.statusText(in: statusCfg, accessibilityGranted: true) == "Needs Screen Access",
            "Enabled module without Screen Recording permission must report Needs Screen Access"
        )
        module.setScreenRecordingGrantedForTesting(true)
        moduleCfg.general.appEnabled = true
        module.reload(with: moduleCfg)
        expect(module.statusText(in: moduleCfg, accessibilityGranted: true) == "Active", "Running module with permission must report Active")
        module.stop()

        // shortcutText formatting
        expect(
            module.shortcutText(in: statusCfg) == ShortcutSpec(key: "o", modifiers: [.control, .option, .command]).displayString,
            "shortcutText should format the default shortcut"
        )
        statusCfg.screenOCR.shortcut = .none
        expect(module.shortcutText(in: statusCfg) == nil, "shortcutText should be nil for .none")

        // Recent captures: newest first, capped at 10, clearable
        module.replaceRecentCaptures([])
        for idx in 0..<12 {
            module.appendRecent(OCRResult(text: "line \(idx)", qrPayloads: []))
        }
        expect(module.recentCaptures.count == ScreenOCRModule.maxRecentCaptures, "Recent captures should cap at 10")
        expect(module.recentCaptures.first?.text == "line 11", "Newest capture should be first")
        expect(module.recentCaptures.first?.lineCount == 1, "Single-line capture should report 1 line")
        module.clearRecentCaptures()
        expect(module.recentCaptures.isEmpty, "clearRecentCaptures should empty the session list")

        // Developer self-check lifecycle: renders the synthetic sample, runs the real
        // engine path off the main thread, and stores the result. Shortcut .none keeps
        // the global hotkey un-armed in the test process.
        var selfCheckCfg = ToolboxConfig()
        selfCheckCfg.screenOCR.enabled = true
        selfCheckCfg.screenOCR.shortcut = .none
        selfCheckCfg.screenOCR.recognitionLevel = .accurate
        selfCheckCfg.screenOCR.detectQRCodes = true
        module.reload(with: selfCheckCfg)
        module.clearSelfCheckResults()
        expect(module.lastSelfCheck == nil, "clearSelfCheckResults must clear the stored result")
        module.runSelfCheck()
        expect(module.isRunningSelfCheck, "runSelfCheck must mark the check in flight")
        let selfCheckDeadline = Date().addingTimeInterval(10)
        while module.isRunningSelfCheck && Date() < selfCheckDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(!module.isRunningSelfCheck, "runSelfCheck must finish within the deadline")
        expect(
            module.lastSelfCheck?.recognizedText.contains("Toolbox OCR self-check") == true,
            "Self-check must recognize the sample headline (got: \(module.lastSelfCheck?.recognizedText ?? "nil"))"
        )
        expect(
            module.lastSelfCheck?.qrPayloads.contains(ScreenOCREngine.selfCheckQRPayload) == true,
            "Self-check must decode the sample QR payload (got: \(module.lastSelfCheck?.qrPayloads ?? []))"
        )
        module.stop()

        // Developer pipeline test: report struct semantics, then a real full-screen
        // control run. Content-dependent stages (vision/output) may legitimately fail on
        // a machine without Screen Recording permission, so assert completion + launch,
        // never the recognition outcome.
        var reportProbe = OCRPipelineReport(
            kind: .fullScreen,
            stages: [
                OCRPipelineStage(id: "a", name: "A", status: .pass, detail: "ok"),
                OCRPipelineStage(id: "b", name: "B")
            ],
            startedAt: Date(),
            artifactPath: nil,
            outputPreview: nil
        )
        expect(!reportProbe.isComplete && !reportProbe.hasFailure, "Pending stage must block completion and not count as failure")
        reportProbe.stages[1].status = .fail
        expect(reportProbe.isComplete && reportProbe.hasFailure, "Fail stage must complete the report and flag failure")

        module.runPipelineTest(interactive: false)
        expect(module.isRunningPipelineTest, "runPipelineTest must mark the run in flight")
        let pipelineDeadline = Date().addingTimeInterval(20)
        while module.isRunningPipelineTest && Date() < pipelineDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(!module.isRunningPipelineTest, "Pipeline test must finish within the deadline")
        if let report = module.pipelineReport {
            let stageSummary = report.stages.map { "\($0.id)=\(String(describing: $0.status))" }.joined(separator: ", ")
            expect(report.isComplete, "Pipeline report must resolve every stage (got: \(stageSummary))")
            let launch = report.stages.first { $0.id == "launch" }
            expect(launch?.status == .pass, "screencapture must launch in the pipeline test")
        } else {
            failures.append("Pipeline report missing after run")
        }
        module.cancelPipelineTest()
        module.clearPipelineReport()

        // Stale temp sweep (launch hygiene): previous-session capture artifacts must be
        // removed, unrelated files must survive.
        let tempDir = FileManager.default.temporaryDirectory
        let staleURL = tempDir.appendingPathComponent("toolbox-ocr-selftest-sweep-\(UUID().uuidString).png")
        let keepURL = tempDir.appendingPathComponent("not-toolbox-selftest-\(UUID().uuidString).txt")
        try? Data([1]).write(to: staleURL)
        try? Data([1]).write(to: keepURL)
        ScreenOCRModule.sweepStaleTempFiles()
        expect(!FileManager.default.fileExists(atPath: staleURL.path), "sweepStaleTempFiles must remove stale toolbox-ocr-* artifacts")
        expect(FileManager.default.fileExists(atPath: keepURL.path), "sweepStaleTempFiles must leave unrelated files alone")
        try? FileManager.default.removeItem(at: keepURL)
    }

    private static func testScreenOCREngineRecognition() {
        // 1. Pure formatting: top-to-bottom ordering, same-row grouping, line-break joining
        let lines = [
            RecognizedTextLine(text: "right", normalizedY: 0.80, normalizedX: 0.60, confidence: 0.9),
            RecognizedTextLine(text: "alpha", normalizedY: 0.90, normalizedX: 0.10, confidence: 0.9),
            RecognizedTextLine(text: "bottom", normalizedY: 0.20, normalizedX: 0.30, confidence: 0.9),
            RecognizedTextLine(text: "left", normalizedY: 0.805, normalizedX: 0.05, confidence: 0.9)
        ]
        let lineBreaks = ScreenOCREngine.formattedText(from: lines, preserveLineBreaks: true)
        expect(lineBreaks == "alpha\nleft right\nbottom", "formattedText top-to-bottom + same-row grouping mismatch: \(lineBreaks)")
        let joined = ScreenOCREngine.formattedText(from: lines, preserveLineBreaks: false)
        expect(joined == "alpha left right bottom", "formattedText with preserveLineBreaks=false must join rows with spaces: \(joined)")
        expect(ScreenOCREngine.formattedText(from: [], preserveLineBreaks: true) == "", "Empty input must format to an empty string")

        // 1b. Height-relative same-row tolerance: adjacent lines in a dense document must
        // stay separate rows even when their spacing is well under the fixed 2% fallback
        // (regression: the old image-height tolerance merged them in large selections).
        let denseLines = (0..<6).map { i in
            RecognizedTextLine(
                text: "line \(i)",
                normalizedY: 0.95 - 0.015 * CGFloat(i),
                normalizedX: 0.20,
                normalizedHeight: 0.015,
                confidence: 0.9
            )
        }
        let denseOut = ScreenOCREngine.formattedText(from: denseLines, preserveLineBreaks: true)
        let denseRowCount = denseOut.components(separatedBy: "\n").count
        expect(denseRowCount == 6, "Dense lines (spacing 0.015, height 0.015) must stay 6 rows (got \(denseRowCount): \(denseOut.replacingOccurrences(of: "\n", with: " | ")))" )

        // Same visual line: two columns whose origins differ by less than half the line
        // height share one row and are joined left-to-right.
        let columnLines = [
            RecognizedTextLine(text: "colA", normalizedY: 0.800, normalizedX: 0.10, normalizedHeight: 0.015, confidence: 0.9),
            RecognizedTextLine(text: "colB", normalizedY: 0.806, normalizedX: 0.55, normalizedHeight: 0.015, confidence: 0.9)
        ]
        expect(
            ScreenOCREngine.formattedText(from: columnLines, preserveLineBreaks: true) == "colA colB",
            "Columns within half a line height must share one row"
        )

        // Paragraph gaps: a vertical gap wider than one median line height becomes a blank
        // line (line-breaks mode only); gaps exactly one height stay inside the paragraph.
        let paraLines = [
            RecognizedTextLine(text: "para one A", normalizedY: 0.94, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9),
            RecognizedTextLine(text: "para one B", normalizedY: 0.90, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9),
            RecognizedTextLine(text: "para two", normalizedY: 0.80, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9)
        ]
        let paraOut = ScreenOCREngine.formattedText(from: paraLines, preserveLineBreaks: true)
        expect(paraOut == "para one A\npara one B\n\npara two", "Paragraph gap must add a blank line only for the wide gap (got: \(paraOut.debugDescription))")
        let paraJoined = ScreenOCREngine.formattedText(from: paraLines, preserveLineBreaks: false)
        expect(paraJoined == "para one A para one B para two", "preserveLineBreaks=false must never emit blank lines (got: \(paraJoined.debugDescription))")

        // Textual paragraph break: Vision emitted a blank line inside the observation.
        let blankParaLines = [
            RecognizedTextLine(text: "first", normalizedY: 0.90, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9),
            RecognizedTextLine(text: "second", normalizedY: 0.86, normalizedX: 0.10, normalizedHeight: 0.02, confidence: 0.9, hadBlankBefore: true)
        ]
        expect(
            ScreenOCREngine.formattedText(from: blankParaLines, preserveLineBreaks: true) == "first\n\nsecond",
            "hadBlankBefore must re-emit the paragraph break"
        )

        // Unknown heights (legacy/test lines) must fall back to the fixed 2% tolerance.
        expect(
            ScreenOCREngine.sameRowTolerance(for: [RecognizedTextLine(text: "a", normalizedY: 0.5, normalizedX: 0.1, confidence: 0.9)]) == ScreenOCREngine.sameRowYtolerance,
            "sameRowTolerance without heights must fall back to sameRowYtolerance"
        )

        // 2. Pure text + QR combination
        expect(ScreenOCREngine.combinedOutput(text: "", qrPayloads: []) == "", "Empty text + empty QR must produce empty output")
        expect(ScreenOCREngine.combinedOutput(text: "  hello ", qrPayloads: []) == "hello", "Text-only output should be trimmed")
        expect(
            ScreenOCREngine.combinedOutput(text: "", qrPayloads: ["https://toolbox.dev", "https://toolbox.dev", " "]) == "https://toolbox.dev",
            "QR-only output should trim and dedupe payloads"
        )
        expect(
            ScreenOCREngine.combinedOutput(text: "hello", qrPayloads: ["https://x.dev", "https://y.dev"]) == "hello\nhttps://x.dev\nhttps://y.dev",
            "Combined text + QR output mismatch"
        )

        // 3. OCRResult helpers
        let multiLine = OCRResult(text: "A\nB\n\nC", qrPayloads: [])
        expect(multiLine.lineCount == 3, "lineCount should ignore blank lines (got \(multiLine.lineCount))")
        expect(multiLine.toastSummary == "Copied 3 lines", "toastSummary for multi-line text mismatch: \(multiLine.toastSummary)")
        let singleLine = OCRResult(text: "one", qrPayloads: [])
        expect(singleLine.toastSummary == "Copied 1 line", "toastSummary for single line mismatch: \(singleLine.toastSummary)")
        let qrOnly = OCRResult(text: "", qrPayloads: ["https://a.dev", "https://b.dev"])
        expect(qrOnly.toastSummary == "Copied 2 QR codes", "QR toastSummary mismatch: \(qrOnly.toastSummary)")
        expect(qrOnly.clipboardString == "https://a.dev\nhttps://b.dev", "QR-only clipboardString mismatch")
        expect(OCRResult(text: "  ", qrPayloads: []).isEmpty, "Whitespace-only result must count as empty")

        // 4. Small-region upscaling (spec: heights < 32 px get a 2x render)
        if let small = Self.drawTestImage(width: 120, height: 20, lines: ["tiny"], fontSize: 12) {
            let prepared = ScreenOCREngine.prepareImage(small)
            expect(prepared.width == 240 && prepared.height == 40, "prepareImage must upscale sub-32px images 2x (got \(prepared.width)x\(prepared.height))")
        } else {
            failures.append("Could not render small test bitmap")
        }
        if let normal = Self.drawTestImage(width: 400, height: 200, lines: ["normal"], fontSize: 40) {
            expect(ScreenOCREngine.prepareImage(normal) === normal, "prepareImage must leave >= 32px images untouched")
        }

        // 5. Real on-device Vision OCR over an offscreen-rendered bitmap
        if let image = Self.drawTestImage(
            width: 900,
            height: 300,
            lines: ["Toolbox Vision OCR 42", "second line here", "third line here"],
            fontSize: 64
        ) {
            let result = ScreenOCREngine.recognize(in: image, recognitionLevel: .accurate, preserveLineBreaks: true, detectBarcodes: false)
            expect(result.text.contains("Toolbox Vision OCR 42"), "Vision OCR must recognize the rendered headline (got: \(result.text))")
            expect(result.text.contains("second line here"), "Vision OCR must recognize the second line (got: \(result.text))")
            expect(result.lineCount == 3, "Vision OCR should produce 3 lines (got: \(result.lineCount): \(result.text))")
            expect(!result.text.contains("third line here") || result.lineCount == 3, "Recognized output should stay on 3 lines")

            let joinedResult = ScreenOCREngine.recognize(in: image, recognitionLevel: .accurate, preserveLineBreaks: false, detectBarcodes: false)
            expect(
                !joinedResult.text.contains("\n") && joinedResult.text.contains("Toolbox Vision OCR 42"),
                "preserveLineBreaks=false must join lines with spaces (got: \(joinedResult.text))"
            )

            // Empty image (blank white bitmap) must recognize as empty, not crash — and a
            // bright blank is NOT the near-black permission signature.
            if let blank = Self.drawTestImage(width: 300, height: 200, lines: [""], fontSize: 40) {
                let blankResult = ScreenOCREngine.recognize(in: blank, recognitionLevel: .fast, preserveLineBreaks: true, detectBarcodes: true)
                expect(blankResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Blank image must produce no text (got: \(blankResult.text))")
                expect(blankResult.isEmpty, "Blank image must produce an empty result")
                expect(!blankResult.looksBlank, "Bright blank image must not flag looksBlank")
            }

            // A near-black image is the classic Screen Recording permission failure
            // signature: empty result + looksBlank must both be true.
            if let black = Self.drawTestImage(width: 300, height: 200, lines: [""], fontSize: 40, background: .black) {
                let blackResult = ScreenOCREngine.recognize(in: black, recognitionLevel: .fast, preserveLineBreaks: true, detectBarcodes: true)
                expect(blackResult.isEmpty, "Black image must produce an empty result")
                expect(blackResult.looksBlank, "Near-black image must flag looksBlank")
            }
        } else {
            failures.append("Could not render offscreen OCR test bitmap")
        }

        // 6. Missing / cancelled capture file handling
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-ocr-selftest-missing-\(UUID().uuidString).png")
        let cancelled = ScreenOCREngine.loadCapturedImage(at: missingURL)
        expect(cancelled.kind == .cancelled && cancelled.image == nil, "Missing capture file must map to .cancelled")
        expect(
            ScreenOCREngine.recognizeFile(at: missingURL, recognitionLevel: .accurate, preserveLineBreaks: true, detectBarcodes: true) == nil,
            "recognizeFile on a missing file must return nil (clean Esc cancellation)"
        )

        // 7. Full file round-trip: render -> PNG on disk -> loadCapturedImage -> recognizeFile
        if let image = Self.drawTestImage(width: 700, height: 200, lines: ["toolbox file round trip"], fontSize: 56) {
            let rep = NSBitmapImageRep(cgImage: image)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("toolbox-ocr-selftest-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                failures.append("Could not encode test bitmap as PNG")
                return
            }
            do {
                try pngData.write(to: fileURL)
            } catch {
                failures.append("Could not write test PNG: \(error)")
                return
            }

            let loaded = ScreenOCREngine.loadCapturedImage(at: fileURL)
            expect(loaded.kind == .loaded && loaded.image != nil, "Valid capture PNG must map to .loaded")

            let fileResult = ScreenOCREngine.recognizeFile(
                at: fileURL,
                recognitionLevel: .accurate,
                preserveLineBreaks: true,
                detectBarcodes: true
            )
            expect(fileResult?.text.contains("toolbox file round trip") == true, "recognizeFile must OCR the on-disk capture (got: \(fileResult?.text ?? "nil"))")
        } else {
            failures.append("Could not build round-trip test bitmap")
        }

        // 8. End-to-end QR/barcode path: generate a real QR code (CoreImage) and decode
        // it with Vision's VNDetectBarcodesRequest. Previously only the pure
        // combinedOutput helper was tested, never the barcode request itself.
        if let qr = ScreenOCREngine.qrCodeImage(payload: "https://toolbox.dev/self-test", targetSize: 240) {
            if let framed = Self.frameImage(qr, in: 320, margin: 16) {
                let qrResult = ScreenOCREngine.recognize(in: framed, recognitionLevel: .fast, preserveLineBreaks: true, detectBarcodes: true)
                expect(
                    qrResult.qrPayloads.contains("https://toolbox.dev/self-test"),
                    "Vision must decode the generated QR code (got: \(qrResult.qrPayloads))"
                )
                expect(
                    qrResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "QR-only bitmap must not produce spurious text lines (got: \(qrResult.text))"
                )
            } else {
                failures.append("Could not frame QR test bitmap")
            }
        } else {
            failures.append("CoreImage could not generate the QR test code")
        }

        // 9. Developer self-check sample: the exact image the Developer Tools button
        // renders must round-trip through the engine (3 text lines + 1 QR payload).
        if let sample = ScreenOCREngine.makeSelfCheckSample() {
            let sampleResult = ScreenOCREngine.recognize(
                in: ScreenOCREngine.prepareImage(sample),
                recognitionLevel: .fast,
                preserveLineBreaks: true,
                detectBarcodes: true
            )
            expect(
                sampleResult.text.contains("Toolbox OCR self-check"),
                "Self-check sample text must be recognized (got: \(sampleResult.text))"
            )
            expect(
                sampleResult.qrPayloads.contains(ScreenOCREngine.selfCheckQRPayload),
                "Self-check sample QR must be decoded (got: \(sampleResult.qrPayloads))"
            )
        } else {
            failures.append("Could not render the developer self-check sample")
        }
    }

    /// Centers `image` on a white `size`×`size` bitmap with a `margin` quiet zone.
    private static func frameImage(_ image: CGImage, in size: Int, margin: Int) -> CGImage? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let inner = CGFloat(size) - CGFloat(margin) * 2
        let nsImage = NSImage(cgImage: image, size: NSSize(width: inner, height: inner))
        nsImage.draw(in: NSRect(x: CGFloat(margin), y: CGFloat(margin), width: inner, height: inner))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Renders high-contrast text lines into an offscreen bitmap for engine tests.
    private static func drawTestImage(width: Int, height: Int, lines: [String], fontSize: CGFloat, background: NSColor = .white) -> CGImage? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let lineHeight = fontSize * 1.7
        for (idx, line) in lines.enumerated() where !line.isEmpty {
            let y = CGFloat(height) - lineHeight * CGFloat(idx + 1) + fontSize * 0.25
            (line as NSString).draw(at: NSPoint(x: CGFloat(width) * 0.1, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func testMultiScreenOnboardingClipboardScrollAndMicSync() {
        // 1. Multi-screen window frame centering clamps cleanly inside secondary display bounds
        let secondaryVisible = NSRect(x: 1920, y: 25, width: 1440, height: 875)
        let centered = MainWindowController.centeredWindowFrame(
            currentSize: NSSize(width: 960, height: 680),
            onScreenVisibleFrame: secondaryVisible
        )
        expect(secondaryVisible.contains(centered), "Centered window frame must fit inside secondary screen visibleFrame: \(centered)")
        expect(abs(centered.midX - secondaryVisible.midX) <= 1.0, "Window should horizontally center on target screen")
        expect(abs(centered.midY - secondaryVisible.midY) <= 1.0, "Window should vertically center on target screen")

        // 2. First-open Accessibility onboarding modal state & seen flag persistence
        var cfg = ToolboxConfig()
        expect(!cfg.general.hasSeenAccessibilityOnboarding, "hasSeenAccessibilityOnboarding should default to false")
        cfg.general.hasSeenAccessibilityOnboarding = true
        if let data = try? JSONEncoder().encode(cfg),
           let decoded = try? JSONDecoder().decode(ToolboxConfig.self, from: data) {
            expect(decoded.general.hasSeenAccessibilityOnboarding, "hasSeenAccessibilityOnboarding must survive JSON round-trip")
        } else {
            failures.append("GeneralConfig with hasSeenAccessibilityOnboarding failed Codable round-trip")
        }

        let perms = PermissionsManager.shared
        let prevSeen = ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding
        perms.presentOnboardingModal()
        expect(perms.isPresentingOnboardingModal, "presentOnboardingModal() must set isPresentingOnboardingModal = true")
        perms.dismissOnboardingModal(markSeen: true)
        expect(!perms.isPresentingOnboardingModal, "dismissOnboardingModal() must close onboarding modal")
        expect(ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding, "dismissOnboardingModal(markSeen: true) must mark flag seen")
        ConfigManager.shared.config.general.hasSeenAccessibilityOnboarding = prevSeen

        // 3. Clipboard minimal scroll math keeps down-arrow selection at bottom (not top) and preserves selection on preview open/close
        let docBounds = NSRect(x: 0, y: 0, width: 400, height: 1000)
        let flippedVisible = NSRect(x: 0, y: 0, width: 400, height: 300)
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 120, width: 384, height: 50),
                visibleRect: flippedVisible,
                documentBounds: docBounds,
                isFlipped: true
            ) == nil,
            "Fully visible row must not trigger scroll"
        )
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 290, width: 384, height: 50),
                visibleRect: flippedVisible,
                documentBounds: docBounds,
                isFlipped: true
            ) == 40,
            "Scrolling down past bottom (flipped) should place row at bottom edge (y=40), not top (y=290)"
        )
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 20, width: 384, height: 50),
                visibleRect: NSRect(x: 0, y: 100, width: 400, height: 300),
                documentBounds: docBounds,
                isFlipped: true
            ) == 20,
            "Scrolling up past top (flipped) should place row at top edge (y=20)"
        )
        expect(
            ClipboardRowVisibilityNSView.minimalVerticalScrollOriginY(
                rowRect: NSRect(x: 8, y: 360, width: 384, height: 50),
                visibleRect: NSRect(x: 0, y: 400, width: 400, height: 300),
                documentBounds: docBounds,
                isFlipped: false
            ) == 360,
            "Scrolling down past bottom (unflipped) should place row at bottom edge (y=360)"
        )

        // 4. Call Controls mute label classification, effective state sync, and idle background Teams guard
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute mic (⌘⇧M)") == false, "'Mute mic (⌘⇧M)' means currently unmuted (false)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Unmute mic (⌘⇧M)") == true, "'Unmute mic (⌘⇧M)' means currently muted (true)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Turn off microphone (⌘ + d)") == false, "Google Meet turn off mic label should classify as unmuted (false)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Turn on microphone (⌘ + d)") == true, "Google Meet turn on mic label should classify as muted (true)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Unmute huddle") == true, "Slack 'Unmute huddle' label should classify as muted (true)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute huddle") == false, "Slack 'Mute huddle' label should classify as unmuted (false)")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute notifications") == nil, "Unrelated 'Mute notifications' must return nil")
        expect(CallShortcutRemapper.classifyCallMuteControlLabel("Mute all participants") == nil, "Unrelated 'Mute all participants' must return nil")

        expect(!CallControlsModule.resolveEffectiveMuteState(isTypingMuted: false, hardwareMuted: false, callAppMuted: false), "Live hardware + live app must resolve to live")
        expect(CallControlsModule.resolveEffectiveMuteState(isTypingMuted: false, hardwareMuted: false, callAppMuted: true), "App muted must resolve to muted even if hardware unmuted")
        expect(CallControlsModule.resolveEffectiveMuteState(isTypingMuted: false, hardwareMuted: true, callAppMuted: false), "Hardware muted must resolve to muted")
        expect(CallControlsModule.resolveEffectiveMuteState(isTypingMuted: true, hardwareMuted: false, callAppMuted: false), "Typing mute must resolve to muted")

        let initialSyncPlan = CallControlsModule.planObservedCallMuteSync(
            observedMuted: true,
            previousCallAppMuted: nil,
            hardwareInputMuted: false,
            syncHardwareWithApp: true,
            isTypingMuted: false,
            withinPostRelaySettleWindow: false,
            defaultInputAvailable: true
        )
        expect(
            initialSyncPlan == CallControlsModule.ObservedCallMutePlan(
                adoptCallAppMuted: true,
                hardwareMuteTarget: true,
                announceHardwareSyncLog: true
            ),
            "First read when joining an already-muted call with HW sync enabled must copy app mute to hardware"
        )
        let appOnlyPlan = CallControlsModule.planObservedCallMuteSync(
            observedMuted: true,
            previousCallAppMuted: nil,
            hardwareInputMuted: false,
            syncHardwareWithApp: false,
            isTypingMuted: false,
            withinPostRelaySettleWindow: false,
            defaultInputAvailable: true
        )
        expect(
            appOnlyPlan == CallControlsModule.ObservedCallMutePlan(
                adoptCallAppMuted: true,
                hardwareMuteTarget: nil,
                announceHardwareSyncLog: false
            ),
            "App-only mode must adopt app mute status in Toolbox without muting OS hardware (prevents Slack system-mute banner)"
        )
        let postRelayStale = CallControlsModule.planObservedCallMuteSync(
            observedMuted: false,
            previousCallAppMuted: true,
            hardwareInputMuted: true,
            syncHardwareWithApp: true,
            isTypingMuted: false,
            withinPostRelaySettleWindow: true,
            defaultInputAvailable: true
        )
        expect(postRelayStale == nil, "Post-relay settle window must ignore stale pre-flip AX poll")

        let micShortcut = ShortcutSpec(key: "m", modifiers: [.control, .option, .command])
        let mCode = UInt16(micShortcut.carbonKeyCode ?? 46)
        let idleTeamsEverywhere = CallShortcutRemapper.resolveDecision(
            keyCode: mCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: .none,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.apple.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: [RunningCallAppSnapshot(bundleIdentifier: "com.microsoft.teams2", pid: 202, windowTitles: ["Chat | Microsoft Teams"], hasActiveCallControl: false)],
            isCallActivityActive: false
        )
        expect(
            idleTeamsEverywhere == .globalHardwareOnly(action: .mic),
            "Idle background Teams without active call must not steal focus; should use globalHardwareOnly(.mic)"
        )

        expect(
            CoreAudioController.bundleID("com.tinyspeck.slackmacgap", matchesActiveInputProcessBundleIDs: ["com.tinyspeck.slackmacgap.helper"]),
            "Electron audio helper bundle ID must match its host call app"
        )
        expect(
            !CoreAudioController.bundleID("com.microsoft.teams", matchesActiveInputProcessBundleIDs: ["com.microsoft.teams2"]),
            "Similar bundle prefix without dot boundary must not cross-match"
        )
        expect(
            CoreAudioController.isNonCallSystemInputBundleID("com.apple.Sound-Settings.extension"),
            "System Settings Sound meter extension must be excluded from call mic activity detection"
        )
        expect(
            !CoreAudioController.isNonCallSystemInputBundleID("com.tinyspeck.slackmacgap.helper"),
            "Call app audio helpers must not be filtered as system settings extensions"
        )

        let videoShortcut = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
        let vCode = UInt16(videoShortcut.carbonKeyCode ?? 9)
        let slackActiveTeamsIdleSnapshots = [
            RunningCallAppSnapshot(
                bundleIdentifier: "com.microsoft.teams2",
                pid: 202,
                windowTitles: ["Chat | Microsoft Teams"],
                hasActiveCallControl: false,
                hasActiveAudioInput: false
            ),
            RunningCallAppSnapshot(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                pid: 405,
                windowTitles: ["Slack Huddle"],
                hasActiveCallControl: true,
                hasActiveAudioInput: true
            )
        ]

        let frontSlackVideo = CallShortcutRemapper.resolveDecision(
            keyCode: vCode,
            modifiers: [.control, .option, .command],
            eventUserData: 0,
            micShortcut: micShortcut,
            videoShortcut: videoShortcut,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            frontmostPID: 405,
            frontmostWindowTitle: "Slack Huddle",
            runningApps: slackActiveTeamsIdleSnapshots,
            isCallActivityActive: true
        )
        expect(
            frontSlackVideo == .globalHardwareOnly(action: .video),
            "Frontmost Slack (no video shortcut) must not fall through to idle background Teams for .video"
        )

        let bgSlackCallVideo = CallShortcutRemapper.resolveTargetPreview(
            action: .video,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.apple.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: slackActiveTeamsIdleSnapshots,
            isCallActivityActive: true
        )
        expect(
            bgSlackCallVideo == nil,
            "Active Slack Huddle owning mic input must block .video fallback to idle background Teams"
        )

        let bgSlackCallMic = CallShortcutRemapper.resolveTargetPreview(
            action: .mic,
            overrideScope: .everywhere,
            mappings: CallAppShortcutMapping.defaults,
            frontmostBundleID: "com.apple.Xcode",
            frontmostPID: 303,
            frontmostWindowTitle: "Toolbox.swift",
            runningApps: slackActiveTeamsIdleSnapshots,
            isCallActivityActive: true
        )
        expect(
            bgSlackCallMic?.app.id == "slack",
            "Active Slack Huddle owning mic input must receive .mic even if idle Teams precedes it in snapshot list"
        )

        // Browser / Google Meet safety: browser menu bar items (Bookmark This Tab Cmd+D, Use Selection Cmd+E) must never match call controls
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Bookmark This Tab…", menuPath: "Bookmarks > Bookmark This Tab…") == nil,
            "Browser 'Bookmark This Tab…' must not classify as a call control"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Use Selection for Find", menuPath: "Edit > Find > Use Selection for Find") == nil,
            "Browser 'Use Selection for Find' must not classify as a call control"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Minimize", menuPath: "Window > Minimize") == nil,
            "Window 'Minimize' must not classify as a call control"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Dynamic Island", menuPath: "View > Dynamic Island") == nil,
            "Unrelated word containing 'mic' substring must not classify as .mic"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Mute All", menuPath: "Participants > Mute All") == nil,
            "Host 'Mute All' must not classify as personal mic mute"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Mute", menuPath: "Video > Mute")?.kind == .mic,
            "FaceTime 'Video > Mute' must classify as .mic"
        )
        expect(
            CallShortcutRemapper.classifyControlKind(title: "Stop Video", menuPath: "Meeting > Stop Video")?.kind == .video,
            "Zoom 'Meeting > Stop Video' must classify as .video"
        )

        if let meetMapping = CallAppShortcutMapping.defaults.first(where: { $0.id == "google_meet" }),
           let zoomMapping = CallAppShortcutMapping.defaults.first(where: { $0.id == "zoom" }) {
            expect(CallShortcutRemapper.isBrowserMapping(meetMapping), "Google Meet preset must be identified as a browser mapping")
            expect(!CallShortcutRemapper.isBrowserMapping(zoomMapping), "Zoom preset must not be treated as a browser mapping")
        }
        expect(CallShortcutRemapper.isBrowserBundleID("com.google.Chrome"), "Chrome must be recognized as a browser bundle ID")
        expect(!CallShortcutRemapper.isBrowserBundleID("com.apple.FaceTime"), "FaceTime must not be recognized as a browser bundle ID")

        // Web-area mute classification rejects bare video-player "Mute"/"Unmute" while keeping Google Meet mic labels
        expect(
            CallShortcutRemapper.classifyCallMuteControlLabel("Mute (m)", isMenuItem: false, allowBareMuteWord: false) == nil,
            "Browser web-area inspection must ignore bare video-player 'Mute (m)' controls"
        )
        expect(
            CallShortcutRemapper.classifyCallMuteControlLabel("Turn off microphone (⌘ + d)", isMenuItem: false, allowBareMuteWord: false) == false,
            "Google Meet 'Turn off microphone' must classify as live (false) inside browser web area"
        )
        expect(
            CallShortcutRemapper.classifyCallMuteControlLabel("Turn on microphone", isMenuItem: false, allowBareMuteWord: false) == true,
            "Google Meet 'Turn on microphone' must classify as muted (true) inside browser web area"
        )

        // Video control classification for in-page Google Meet camera buttons
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Turn off camera (⌘ + e)") == true, "'Turn off camera' means camera is active (true)")
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Turn on camera") == false, "'Turn on camera' means camera is off (false)")
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Blur background") == nil, "'Blur background' must return nil")
        expect(CallShortcutRemapper.classifyCallVideoControlLabel("Video settings") == nil, "'Video settings' must return nil")

        // Floating pill stays visible when camera is turned off if active call app session remains open (e.g. muted Google Meet)
        expect(
            CallControlsModule.resolveCallOrMediaActive(isCameraActive: false, isMicStreamActive: false, hasActiveCallAppSession: true),
            "Active call app session must keep floating pill visible even when camera is off and mic stream is idle"
        )
        expect(
            !CallControlsModule.resolveCallOrMediaActive(isCameraActive: false, isMicStreamActive: false, hasActiveCallAppSession: false),
            "Floating pill must hide once camera, mic stream, and active call app session are all inactive"
        )

        // Both Ctrl+Opt+Cmd+M and Cmd+Shift+Space route to Google Meet when Meet tab is active in Chrome
        let slackStyleMic = ShortcutSpec(key: "space", modifiers: [.command, .shift])
        let slackSpaceCode = UInt16(slackStyleMic.carbonKeyCode ?? 49)
        for (label, testShortcut, code) in [("Ctrl+Opt+Cmd+M", micShortcut, mCode), ("Cmd+Shift+Space", slackStyleMic, slackSpaceCode)] {
            let meetFront = CallShortcutRemapper.resolveDecision(
                keyCode: code,
                modifiers: testShortcut.modifiers,
                eventUserData: 0,
                micShortcut: testShortcut,
                videoShortcut: videoShortcut,
                overrideScope: .everywhere,
                mappings: CallAppShortcutMapping.defaults,
                frontmostBundleID: "com.google.Chrome",
                frontmostPID: 707,
                frontmostWindowTitle: "Meet – qgs-xoum-qzq – Camera and microphone recording - Google Chrome",
                runningApps: []
            )
            if case .remap(let action, let app, _, let targetShortcut, _) = meetFront {
                expect(
                    action == .mic && app.id == "google_meet" && targetShortcut == ShortcutSpec(key: "d", modifiers: [.command]),
                    "\(label) on active Google Meet Chrome tab must remap to google_meet Cmd+D"
                )
            } else {
                failures.append("\(label) on active Google Meet Chrome tab should return .remap (got: \(meetFront))")
            }
        }

        // 5. Live Clipboard panel navigation: Down x12, Up x12, Right preview, Left back
        let liveClipboard = ClipboardModule()
        var clipCfg = ToolboxConfig()
        clipCfg.clipboard.maxItems = 30
        clipCfg.clipboard.persistHistory = false
        liveClipboard.reload(with: clipCfg)
        liveClipboard.clearHistory(keepPinned: false)
        for idx in (1...20).reversed() {
            liveClipboard.recordText("Clip item \(idx)\nSecond line for realistic height")
        }
        let clipPanel = liveClipboard.ensurePanel(width: 420, height: 420)
        liveClipboard.showPopover()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        let clipSearchField = clipPanel.firstEditableTextField()
        expect(clipSearchField != nil, "Clipboard popover must contain an editable NSTextField search box")
        let clipResponder = clipPanel.firstResponder
        let isClipSearchFocused = ((clipResponder as? NSTextView)?.delegate as AnyObject?) === clipSearchField || clipResponder === clipSearchField
        expect(isClipSearchFocused, "Clipboard showPopover must auto-focus search so character keys filter instead of beeping")

        func firstScrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        let clipScrollView = firstScrollView(in: clipPanel.contentView)
        expect(clipScrollView != nil, "Clipboard popover must contain an NSScrollView")
        let initialClipY = clipScrollView?.contentView.documentVisibleRect.origin.y ?? -1

        for _ in 0..<12 {
            liveClipboard.popoverState.moveSelection(delta: 1, in: liveClipboard.entries)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        expect(liveClipboard.popoverState.selectedEntryID == liveClipboard.entries[12].id, "12 down steps should select index 12")
        let downClipY = clipScrollView?.contentView.documentVisibleRect.origin.y ?? 0
        expect(downClipY > initialClipY + 20, "Navigating down 12 rows must scroll Clipboard downward (got \(downClipY) from \(initialClipY))")

        for _ in 0..<12 {
            liveClipboard.popoverState.moveSelection(delta: -1, in: liveClipboard.entries)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        expect(liveClipboard.popoverState.selectedEntryID == liveClipboard.entries[0].id, "12 up steps should return to index 0")
        let upClipY = clipScrollView?.contentView.documentVisibleRect.origin.y ?? 999
        expect(abs(upClipY) <= 1.0, "Navigating back up to index 0 must align cleanly at top y=0 (got \(upClipY))")

        for _ in 0..<8 {
            liveClipboard.popoverState.moveSelection(delta: 1, in: liveClipboard.entries)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        let viewedEntry = liveClipboard.entries[8]
        let yBeforePreview = clipScrollView?.contentView.documentVisibleRect.origin.y ?? 0
        expect(liveClipboard.popoverState.selectedEntryID == viewedEntry.id, "8 down steps should select index 8")
        liveClipboard.popoverState.previewEntryID = viewedEntry.id
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        if let previewID = liveClipboard.popoverState.previewEntryID {
            liveClipboard.popoverState.selectedEntryID = previewID
            liveClipboard.popoverState.previewEntryID = nil
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        expect(liveClipboard.popoverState.previewEntryID == nil, "Closing preview must clear previewEntryID")
        expect(liveClipboard.popoverState.selectedEntryID == viewedEntry.id, "Closing preview must stay on viewed entry (index 8), never jump to another row")
        let yAfterPreview = clipScrollView?.contentView.documentVisibleRect.origin.y ?? -1
        expect(abs(yAfterPreview - yBeforePreview) <= 2.0, "Closing preview must preserve list scroll position (before=\(yBeforePreview), after=\(yAfterPreview))")
        liveClipboard.hidePopover()
        liveClipboard.clearHistory(keepPinned: false)
        liveClipboard.stop()

        // 6. PortKiller search bar auto-focus & openSequence tracking
        let pkModule = PortKillerModule()
        let pkPanel = pkModule.ensurePanel(width: 460, height: 480)
        let seqBefore = pkModule.popoverState.openSequence
        pkModule.showPopover()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        expect(pkModule.popoverState.openSequence == seqBefore + 1, "PortKiller showPopover must increment openSequence")
        let pkSearchField = pkPanel.firstEditableTextField()
        expect(pkSearchField != nil, "PortKiller popover must provide an editable NSTextField search box")
        let pkResponder = pkPanel.firstResponder
        let isPKSearchFocused = ((pkResponder as? NSTextView)?.delegate as AnyObject?) === pkSearchField || pkResponder === pkSearchField
        expect(isPKSearchFocused, "PortKiller showPopover must focus the search bar automatically")
        pkModule.hidePopover()
        pkModule.stop()
    }

    private static func testSupportLinks() {
        expect(SupportLinks.githubSponsors.scheme == "https", "GitHub Sponsors URL must use https")
        expect(SupportLinks.githubSponsors.host == "github.com", "GitHub Sponsors URL host mismatch")
        expect(SupportLinks.githubSponsors.path == "/sponsors/ssa17", "GitHub Sponsors URL path mismatch")
        expect(SupportLinks.koFi.scheme == "https", "Ko-fi URL must use https")
        expect(SupportLinks.koFi.host == "ko-fi.com", "Ko-fi URL host mismatch")
        expect(SupportLinks.koFi.path == "/ssa17", "Ko-fi URL path mismatch")
    }
}
