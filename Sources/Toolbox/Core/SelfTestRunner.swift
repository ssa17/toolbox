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

        if failures.isEmpty {
            print("All 19 self-test suites passed.")
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
            // 1. Blank areas on the page (e.g. header banner, padding, bottom-right empty quadrant) must NOT match PointerCursorNSView.
            let emptyBannerPt = NSPoint(x: 500, y: 650)
            let emptyBottomRightPt = NSPoint(x: 800, y: 120)
            expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptyBannerPt),
                   "Blank header area on Dashboard must not trigger pointingHand cursor")
            expect(!PointerCursorNSView.containsPointerCursorView(in: rootView, atWindowPoint: emptyBottomRightPt),
                   "Empty bottom-right Dashboard area must not trigger pointingHand cursor")

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
            expect(decoded.schemaVersion == 3, "ToolboxConfig schemaVersion should be 3")
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
        let expectedDefaultOrder = ["dock_minimize", "clipboard", "keep_awake", "custom_commands", "scroll_direction"]

        expect(!cfg.general.hasCustomMenuBarLayout, "Default config should not report custom menu bar layout")
        expect(cfg.general.showQuickActionsInMenuBar, "Quick actions should be shown in menu bar by default")
        expect(cfg.general.showQuickCommandsInMenuBar, "Quick commands should be shown in menu bar by default")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "Default menu bar module order mismatch: \(registry.orderedMenuBarModules(for: cfg).map(\.id))"
        )
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder,
            "All 5 modules should be visible in menu bar by default"
        )

        cfg.general.moveModuleInMenuBar(id: "keep_awake", direction: -1)
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["dock_minimize", "keep_awake", "clipboard", "custom_commands", "scroll_direction"],
            "Moving keep_awake up by 1 should place it before clipboard"
        )
        expect(cfg.general.hasCustomMenuBarLayout, "Reordering should mark hasCustomMenuBarLayout = true")

        cfg.general.moveModuleInMenuBar(fromId: "scroll_direction", toId: "dock_minimize")
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "dock_minimize", "keep_awake", "clipboard", "custom_commands"],
            "Dragging scroll_direction to dock_minimize should place it first"
        )

        cfg.general.setModuleVisibleInMenuBar("dock_minimize", visible: false)
        expect(
            registry.visibleMenuBarModules(for: cfg).map(\.id) == ["scroll_direction", "keep_awake", "clipboard", "custom_commands"],
            "Hiding dock_minimize from menu bar should omit it from visibleMenuBarModules"
        )
        expect(cfg.dockMinimize.enabled, "Hiding dock_minimize from status bar menu must not disable the module itself")

        cfg.general.menuBarModuleOrder = ["keep_awake", "keep_awake", "unknown_id"]
        expect(
            registry.orderedMenuBarModules(for: cfg).map(\.id) == ["keep_awake", "dock_minimize", "clipboard", "custom_commands", "scroll_direction"],
            "Partial or unknown menuBarModuleOrder must normalize with remaining registered modules and no duplicates"
        )

        cfg.general.showQuickActionsInMenuBar = false
        cfg.general.showQuickCommandsInMenuBar = false
        expect(cfg.general.hasCustomMenuBarLayout, "Hiding quick actions/commands should mark custom layout")

        cfg.general.resetMenuBarLayout()
        expect(!cfg.general.hasCustomMenuBarLayout, "resetMenuBarLayout must clear custom layout state")
        expect(registry.visibleMenuBarModules(for: cfg).map(\.id) == expectedDefaultOrder, "resetMenuBarLayout must restore default visible modules")
        expect(cfg.general.showQuickActionsInMenuBar && cfg.general.showQuickCommandsInMenuBar, "resetMenuBarLayout must restore quick actions & quick commands")
    }
}
