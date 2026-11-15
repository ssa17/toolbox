import AppKit
import CoreGraphics
import Foundation

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

        if failures.isEmpty {
            print("All 23 self-test suites passed.")
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

        clipboard.clearHistory(keepPinned: true)
        expect(clipboard.entries.map(\.text) == ["second"], "clearHistory(keepPinned: true) should keep pinned items")
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
        expect(!cfg.customCommands.enabled, "CustomCommands should default to disabled (off by default)")
        expect(!cfg.scrollDirection.enabled, "ScrollDirection should default to disabled (off by default)")
        expect(cfg.dockMinimize.excludedBundleIDs.isEmpty, "No apps should be excluded by default")
        expect(DockActionMode.allCases.contains(.sendToBack), "DockActionMode should include sendToBack")
        expect(cfg.clipboard.maxItems == 25, "Clipboard default maxItems should be 25")
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
        expect(menuBar.attachedMenuForTesting === menuBar.menuInstanceForTesting, "NSStatusItem must attach native NSMenu for guaranteed click-to-toggle")
        expect(menuBar.menuInstanceForTesting.items.first?.view != nil, "Menu item must host MenuBarPopoverView")
        expect(menuBar.pointerCursorViewCountForTesting >= 10, "Menu bar interactive controls must attach PointerCursorNSView overlays (found \(menuBar.pointerCursorViewCountForTesting))")
        menuBar.setVisible(false)
        expect(menuBar.attachedMenuForTesting == nil, "Hiding status item must clear attached menu")

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
            expect(decoded.schemaVersion == 5, "ToolboxConfig schemaVersion should be 5")
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
        let expectedDefaultOrder = ["dock_minimize", "clipboard", "port_killer", "keep_awake", "custom_commands", "scroll_direction"]

        expect(!cfg.general.hasCustomMenuBarLayout, "Default config should not report custom menu bar layout")
        expect(cfg.general.showQuickActionsInMenuBar, "Quick actions should be shown in menu bar by default")
        expect(cfg.general.showQuickCommandsInMenuBar, "Quick commands should be shown in menu bar by default")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "Default menu bar module order mismatch: \(registry.orderedMenuBarModules(for: cfg).map(\.id))"
        )
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "All 6 menu-bar-eligible modules should be visible in menu bar by default"
        )

        cfg.general.moveModuleInMenuBar(id: "keep_awake", direction: -1)
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["dock_minimize", "clipboard", "keep_awake", "port_killer", "custom_commands", "scroll_direction"],
            "Moving keep_awake up by 1 should place it before port_killer"
        )
        expect(cfg.general.hasCustomMenuBarLayout, "Reordering should mark hasCustomMenuBarLayout = true")

        cfg.general.moveModuleInMenuBar(fromId: "scroll_direction", toId: "dock_minimize")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "dock_minimize", "clipboard", "keep_awake", "port_killer", "custom_commands"],
            "Dragging scroll_direction to dock_minimize should place it first"
        )

        cfg.general.setModuleVisibleInMenuBar("dock_minimize", visible: false)
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "clipboard", "keep_awake", "port_killer", "custom_commands"],
            "Hiding dock_minimize from menu bar should omit it from visibleMenuBarModules"
        )
        expect(cfg.dockMinimize.enabled, "Hiding dock_minimize from status bar menu must not disable the module itself")

        cfg.general.menuBarModuleOrder = ["keep_awake", "clean_lock", "keep_awake", "unknown_id"]
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["keep_awake", "dock_minimize", "clipboard", "port_killer", "custom_commands", "scroll_direction"],
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
        expect(DeveloperSection.allCases.count == 5, "Expected 5 DeveloperSection cases")
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
}
