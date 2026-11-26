# Window Switcher (`Alt+Tab`) — Feature Spec

> **Status:** Done (Shipped) · **Module:** `Modules/WindowSwitcher/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
macOS `⌘ Tab` switches between *applications*, not individual *windows*, and leaves minimized windows hidden behind Dock icons. Users juggling multiple browser, terminal, or editor windows—especially Windows switchers, developers, and students—have to combine `⌘ Tab`, `⌘ \``, Exposé, and Dock clicks to reach a specific window. **Window Switcher** provides an opt-in, keyboard-first window switcher (`⌥ Tab` / `⌥ ⇧ Tab`) that lists every open and minimized window in MRU order with optional live thumbnails and quick window actions.

### User Flows & UX
- **Hold-and-Cycle HUD (`⌥ Tab` forward, `⌥ ⇧ Tab` reverse, or `currentAppOnlyShortcut`):**
  - Holding the trigger modifier (`⌥` by default) and pressing `Tab` opens a centered non-activating HUD panel (`NSPanel` hosted via `PointerCursorHostingView`) and pre-selects index `1` (the previously active window).
  - Subsequent `Tab` / `⇧ Tab` (or `↓` / `↑` / `→` / `←`) presses cycle selection; clicking a row/card also selects and activates it.
  - Releasing the trigger modifier commits the selection: un-minimizes if minimized, raises the window, and activates its owning app.
  - Pressing `Esc` cancels and dismisses the HUD without changing focus.
- **Quick Actions While HUD Is Open (`enableQuickActions`):**
  - `W`: Close selected window (via `AXCloseButton` press).
  - `M`: Minimize / un-minimize selected window.
  - `H`: Hide owning application.
  - `Q`: Gracefully quit owning application (`NSRunningApplication.terminate()`).
  - Optional type-to-filter mode: typing characters filters the list by window title or app name.
- **Settings View (`WindowSwitcherSettingsView.swift`):**
  - Built with `FeatureSection`, `SettingRow`, `Divider()`, `ShortcutRecorderView`, and `.pointerCursor()` on all interactive controls.
  - **Trigger & Shortcuts** section: Trigger Modifier picker (`⌥ Option`, `⌃ Control`, `⌘ Command`), Trigger Key (`Tab`), optional `Current App Windows Only` shortcut (`ShortcutRecorderView`), and Accessibility permission status banner.
  - **Appearance & Thumbnails** section: Layout style picker (`List` vs `Grid`), `Show live window thumbnails` toggle (showing Screen Recording permission status/link when enabled without permission), `Enable quick actions (W/M/H/Q)` toggle.
  - **Window Filtering** section: `Include minimized windows`, `Include hidden apps`, `Active Space only`, `Active display only`, and `Excluded Apps` list.

### Files to Create
- `Sources/Toolbox/Modules/WindowSwitcher/WindowSwitcherModule.swift`
- `Sources/Toolbox/Modules/WindowSwitcher/WindowEnumerator.swift`
- `Sources/Toolbox/Modules/WindowSwitcher/WindowThumbnailProvider.swift`
- `Sources/Toolbox/Modules/WindowSwitcher/WindowSwitcherEventTap.swift`
- `Sources/Toolbox/Modules/WindowSwitcher/WindowSwitcherPanelView.swift`
- `Sources/Toolbox/Modules/WindowSwitcher/WindowSwitcherSettingsView.swift`

### Module Metadata
- `id`: `"window_switcher"`
- `name`: `"Window Switcher"`
- `tagline`: `"Switch directly between individual open and minimized windows with keyboard navigation and optional live thumbnails."`
- `symbolName`: `"rectangle.stack"`
- `accentColor`: `Color.indigo`
- `category`: `.windowAndDock`
- `requiresAccessibility`: `true` *(Accessibility is required for `CGEventTap` modifier-release detection and `AXUIElement` window enumeration/raising; Screen Recording is optional and used only when `showThumbnails` is enabled.)*

### Technical Design & macOS APIs
1. **Dedicated Background `CGEventTap` (`WindowSwitcherEventTap`):**
   - Carbon `HotKeyManager` cannot observe modifier-release events (`flagsChanged`), so `WindowSwitcherEventTap` runs a `.cgSessionEventTap` (`.headInsertEventTap`, `.defaultTap`) on a dedicated background `Thread` + `CFRunLoop` listening to `keyDown` and `flagsChanged`.
   - Maintain a lock-protected (`OSAllocatedUnfairLock`) snapshot of trigger config and `isHUDOpen` state for synchronous reads inside the background `CGEventTap` callback (Swift 6 data-race safe, zero main-thread blocking).
   - Ignore synthetic events tagged with Toolbox's `0x544C4258` marker, keep the tap callback side-effect free (dispatch HUD updates to `@MainActor`), and re-arm immediately on `tapDisabledByTimeout` / `tapDisabledByUserInput`.
   - Register optional `currentAppOnlyShortcut` via `HotKeyManager.shared` using key `"window_switcher.current_app"` (wired into `inAppConflictDescription` and `clearConflictingShortcuts`).
   - When disabled, paused (`config.general.appEnabled == false`), or lacking `AXIsProcessTrusted()`, tear down the tap completely, and hook tap teardown into `AppDelegate.applicationWillTerminate(_:)`.
2. **Window Enumeration & MRU Ordering (`WindowEnumerator`):**
   - Query live on-screen z-order via `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` (layer `0`, filtering helper windows `< 50 × 50` pt and Toolbox's own HUD panel).
   - Merge with per-app `AXUIElement` `kAXWindowsAttribute` (`AXStandardWindow` / `AXDialog`) so minimized windows and hidden-app windows are included. Match AX windows to `CGWindow` entries via PID + frame + title.
   - Maintain an in-memory MRU window key map updated on `NSWorkspace.didActivateApplicationNotification` and switcher commits.
   - Pure filtering/sorting helper handles `includeMinimized`, `includeHiddenApps`, `activeSpaceOnly`, `activeDisplayOnly`, `excludedBundleIDs`, and text filter queries.
3. **Focus Handoff (Mirrors `DockMinimizeModule`):**
   - On commit: if `kAXMinimizedAttribute == true`, set `kAXMinimizedAttribute` to `kCFBooleanFalse`.
   - Perform `kAXRaiseAction`, set `kAXMainAttribute` to `kCFBooleanTrue`, call `NSApp.yieldActivation(to: targetApp)`, and call `targetApp.activate()`.
4. **Optional Live Thumbnails (`WindowThumbnailProvider`):**
   - Use `ScreenCaptureKit` (`SCShareableContent` + `SCScreenshotManager.captureImage`) **only** when `config.showThumbnails == true && CGPreflightScreenCaptureAccess()`.
   - Cache scaled `<= 320 × 200` `CGImage` thumbnails in memory; never prompt for Screen Recording unexpectedly—fall back cleanly to high-resolution app icon + window title cards when Screen Recording is not granted.
5. **HUD Panel:**
   - Non-activating `NSPanel` (`styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]`, `hidesOnDeactivate = false`, `acceptsMouseMovedEvents = true`, `level = .popUpMenu`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`) hosted in `PointerCursorHostingView`, paired with outside-click dismissal monitors as a fail-safe.

### Configuration (`WindowSwitcherConfig`)
```swift
enum SwitcherTriggerModifier: String, Codable, CaseIterable, Sendable {
    case option, control, command
}

enum SwitcherLayoutStyle: String, Codable, CaseIterable, Sendable {
    case list, grid
}

struct WindowSwitcherConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var triggerModifier: SwitcherTriggerModifier = .option
    var triggerKey: String = "tab"
    var currentAppOnlyShortcut: ShortcutSpec = .none
    var layoutStyle: SwitcherLayoutStyle = .list
    var showThumbnails: Bool = false
    var includeMinimized: Bool = true
    var includeHiddenApps: Bool = true
    var activeSpaceOnly: Bool = false
    var activeDisplayOnly: Bool = false
    var enableQuickActions: Bool = true
    var excludedBundleIDs: [String] = []
}
```
- `ToolboxConfig`: add `var windowSwitcher: WindowSwitcherConfig = WindowSwitcherConfig()` with lenient `decodeIfPresent` defaults, bump `schemaVersion`, and append `"window_switcher"` to `GeneralConfig.defaultMenuBarModuleOrder`.

### Verification & Self-Tests
- **Config & migration (`SelfTestRunner`):** Verify `WindowSwitcherConfig` `Codable` round-trip and partial JSON lenient decoding.
- **Filtering & MRU ordering (`SelfTestRunner`):** Test pure `WindowEnumerator` filtering across minimized windows, hidden apps, excluded bundle IDs, active display bounds, and search query matching.
- **HUD selection state machine (`SelfTestRunner`):** Assert initial index `1` selection, `Tab` forward wrap, `⇧ Tab` backward wrap, `Esc` cancel, and modifier-release commit.
- **Visual Snapshots (`SnapshotRunner`):** Render `module_window_switcher.png` and `popover_window_switcher.png`.

### Edge Cases & Pitfalls
- **Missed `flagsChanged` / stuck HUD:** If modifier release occurs while another app grabs Secure Input or focus shifts unexpectedly, outside-click monitors, `Esc`, and app-deactivation observers must dismiss the HUD without committing.
- **Secure Input:** Password fields enable Secure Event Input; fail gracefully without hanging the event tap.
- **Permission revocation:** If Accessibility is revoked while active, `PermissionsManager` updates must stop the tap and clear any open HUD.
- **Coexistence with `DockMinimize` and `WindowSnapper`:** All three share AX/CGWindow patterns; ensure Window Switcher ignores Toolbox's own floating panels and leaves `⌘ Tab` untouched unless the user explicitly selects `.command` as `triggerModifier`.
