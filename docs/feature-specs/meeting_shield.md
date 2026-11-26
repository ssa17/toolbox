# Meeting Shield (Presentation Mode) — Feature Spec

> **Status:** Planned · **Module:** `Modules/MeetingShield/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Before sharing a full screen on Zoom, Teams, Google Meet, or during a live demo, users scramble through multiple menus to hide messy Desktop files/widgets, silence notification banners, keep their Mac awake, and hide unrelated personal apps. **Meeting Shield** provides a single shortcut (`⌃ ⌥ ⌘ S`) and Menu Bar toggle that activates a clean, crash-safe presentation state and restores everything cleanly when the call ends.

### User Flows & UX
- **One-Click / Shortcut Shield Toggle (`⌃ ⌥ ⌘ S` or Menu Bar):**
  - Activates configured shield actions atomically and shows a `HUDToast` (`"Meeting Shield Active"`).
  - Pressing `⌃ ⌥ ⌘ S` again (or clicking **End Shield & Restore** in the Menu Bar / Settings) tears down desktop covers, releases the display-sleep assertion, runs the optional Focus-off Shortcut, and optionally unhides apps that Shield hid.
- **Shield Actions:**
  - **Hide Desktop Icons & Widgets:** Covers the Desktop icon layer with a clean wallpaper or solid backdrop—zero Finder restarts (`killall Finder`) and zero plist mutations.
  - **Keep Display Awake:** Prevents screen sleep and screensaver during long presentations (`IOPMAssertion`).
  - **Hide Background Apps ("Clean Stage"):** Hides all `.regular` apps except the frontmost app, Toolbox, and a user-configurable allowlist (e.g., Zoom, Teams, Slack, browsers, Keynote/PowerPoint), with optional restore on exit.
  - **Silence Notifications (Focus / Do Not Disturb):** Triggers user-chosen macOS Shortcuts (`shortcuts run`) on shield start/end.
  - **Auto-Expire Timer (optional):** Automatically ends Shield after `N` minutes (`0` = manual only) so users never forget it is active.
- **Settings View (`MeetingShieldSettingsView.swift`):**
  - Built with `FeatureSection`, `SettingRow`, `Divider()`, `ShortcutRecorderView`, and `.pointerCursor()` on all controls.
  - **Shortcut & Status** section: global shortcut (`ShortcutRecorderView`), live status badge + manual **Activate / End Shield & Restore** button, `Auto-expire after` picker (`Off`, `30 min`, `60 min`, `90 min`, `120 min`), `Show toast` toggle.
  - **Desktop & Display** section: `Hide Desktop icons` toggle, `Cover style` picker (`Current Wallpaper`, `Solid Dark`, `Solid Light`), `Keep display awake while active` toggle.
  - **Windows & Notifications** section: `Hide background apps on start` toggle, `Restore hidden apps on exit` toggle, `Apps to keep visible` list, `Run Focus Shortcuts` toggle + Shortcut pickers populated via `/usr/bin/shortcuts list` with quick setup instructions.

### Files to Create
- `Sources/Toolbox/Modules/MeetingShield/MeetingShieldModule.swift`
- `Sources/Toolbox/Modules/MeetingShield/DesktopCoverController.swift`
- `Sources/Toolbox/Modules/MeetingShield/FocusShortcutBridge.swift`
- `Sources/Toolbox/Modules/MeetingShield/MeetingShieldSettingsView.swift`

### Module Metadata
- `id`: `"meeting_shield"`
- `name`: `"Meeting Shield"`
- `tagline`: `"One shortcut to hide Desktop clutter, silence notifications, keep your display awake, and hide background apps while screen-sharing."`
- `symbolName`: `"shield.lefthalf.filled"`
- `accentColor`: `Color.purple`
- `category`: `.system`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Zero-Mutation Desktop Icon Cover (`DesktopCoverController`):**
   - Create one borderless `NSWindow` per `NSScreen` matching `screen.frame`:
     - `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)` (sits directly above Desktop icons and below all normal app windows).
     - `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`
     - `ignoresMouseEvents = true`, `canHide = false`, `isReleasedWhenClosed = false`.
   - For `.currentWallpaper`, read `NSWorkspace.shared.desktopImageURL(for: screen)` and render it with `.scaleProportionallyUpOrDown` (`NSImageView`); if unavailable (e.g., dynamic/Aerial video wallpaper or unreadable path), fall back gracefully to a solid dark backdrop.
   - Observe `NSApplication.didChangeScreenParametersNotification` to rebuild/reframe covers if external displays connect or disconnect mid-call.
   - **Crash-safe:** Because nothing modifies `com.apple.finder` `CreateDesktop`, Desktop icons reappear instantly if Toolbox quits or crashes.
2. **macOS Focus / DND Bridge (`FocusShortcutBridge`):**
   - Discover available shortcuts off the main thread via `/usr/bin/shortcuts list`.
   - When `enableFocusShortcut == true` and a non-empty shortcut name is configured, run `/usr/bin/shortcuts` asynchronously in `Task.detached` passing `Process.arguments = ["run", name]` (never shell interpolation) with a 5-second timeout (sanctioned, notarization-safe path on macOS 14+).
   - Register the global shortcut via `HotKeyManager.shared` using key `"meeting_shield.toggle"` (wired into `inAppConflictDescription` and `clearConflictingShortcuts`).
3. **Background App Hiding (`MeetingShieldSessionState`):**
   - On activation, snapshot `NSWorkspace.shared.runningApplications` filtered to `.activationPolicy == .regular`, `!isHidden`, not `frontmostApplication`, not `Bundle.main.bundleIdentifier`, and not in `keptVisibleBundleIDs`.
   - Call `app.hide()` and record their `pid` / `bundleIdentifier` in `hiddenAppPIDs`.
   - On deactivation, if `restoreHiddenAppsOnExit == true`, unhide still-running apps in `hiddenAppPIDs` without stealing focus from the current presentation/call window.
4. **Power Assertion & Guaranteed Teardown:**
   - Hold an independent `IOPMAssertionID` via `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Toolbox Meeting Shield" as CFString, &assertionID)` when `keepAwakeDuringShield == true`, and release only that own ID on exit so `KeepAwakeModule` is never affected.
   - Release the assertion, close cover windows, cancel any auto-expire timer, and run `focusOffShortcutName` in both `stop()` and `AppDelegate.applicationWillTerminate(_:)`.

### Configuration (`MeetingShieldConfig`)
```swift
enum DesktopCoverStyle: String, Codable, CaseIterable, Sendable {
    case currentWallpaper = "current_wallpaper"
    case solidDark = "solid_dark"
    case solidLight = "solid_light"
}

struct MeetingShieldConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "s", modifiers: [.control, .option, .command])
    var hideDesktopIcons: Bool = true
    var desktopCoverStyle: DesktopCoverStyle = .currentWallpaper
    var hideBackgroundApps: Bool = false
    var restoreHiddenAppsOnExit: Bool = true
    var keptVisibleBundleIDs: [String] = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.apple.iWork.Keynote",
        "com.microsoft.Powerpoint"
    ]
    var keepAwakeDuringShield: Bool = true
    var enableFocusShortcut: Bool = false
    var focusOnShortcutName: String = ""
    var focusOffShortcutName: String = ""
    var autoExpireMinutes: Int = 0
    var showToast: Bool = true
}
```
- `ToolboxConfig`: add `var meetingShield: MeetingShieldConfig = MeetingShieldConfig()` with lenient `decodeIfPresent` defaults, bump `schemaVersion`, and append `"meeting_shield"` to `GeneralConfig.defaultMenuBarModuleOrder`.

### Verification & Self-Tests
- **Session state machine (`SelfTestRunner`):** Verify activate → snapshot → deactivate restores state, repeated toggles remain idempotent, and `autoExpireMinutes` timer cancels cleanly on manual stop.
- **App filtering (`SelfTestRunner`):** Assert frontmost app, Toolbox bundle ID, and `keptVisibleBundleIDs` are never marked for hiding.
- **Multi-display geometry (`SelfTestRunner`):** Verify cover frame calculation across multiple `CGRect` screen bounds.
- **Config (`SelfTestRunner`):** Verify `MeetingShieldConfig` `Codable` round-trip and partial JSON migration defaults.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_meeting_shield.png`.

### Edge Cases & Pitfalls
- **Dynamic / Aerial video wallpapers:** `desktopImageURL(for:)` may return a `.mov` or `nil`; always check image decodability and fall back cleanly to `.solidDark`.
- **"Click wallpaper to reveal desktop":** Because cover windows set `ignoresMouseEvents = true`, desktop clicks behave normally without trapping focus.
- **Focus Shortcut missing/renamed:** If `shortcuts run` exits non-zero, log to `DeveloperEventLog` and surface a non-blocking warning without aborting the rest of Meeting Shield.
- **App quit while active:** Hook `MeetingShieldModule.deactivateIfActive()` into `AppDelegate.applicationWillTerminate(_:)` so `IOPMAssertion` and Focus-off cleanup always run.
