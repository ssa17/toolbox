# Finder Enhancer — Feature Spec

> **Status:** Done (Shipped) · **Module:** `Modules/FinderEnhancer/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Finder and macOS window lifecycles surprise users—especially Windows switchers, students, and everyday multitaskers—in three small but constant ways: `⌘ X` does not cut files (macOS requires `⌘ C` then `⌥ ⌘ V`), pressing `Return` renames a file instead of opening it, and closing an app's last window leaves the process sitting in the Dock. **Finder Enhancer** provides three independent, opt-in quality-of-life fixes with strict text-input and system-app safety guards.

### User Flows & UX
- **1. Finder Cut & Paste (`⌘ X` → `⌘ V`):**
  - When Finder is frontmost and the user is **not** typing in a text field, pressing `⌘ X` synthesizes `⌘ C`, records `NSPasteboard.general.changeCount`, and shows an optional `HUDToast` (`"Cut N items — press ⌘ V to move"`).
  - Pressing `⌘ V` in Finder while cut state is armed (and pasteboard still holds the exact cut items) translates `⌘ V` into Finder's native `⌥ ⌘ V` (*Move Item Here*) and clears cut state.
  - Pressing `Esc` or copying anything else (`changeCount` changes) disarms cut state automatically.
- **2. Finder Keyboard Tweaks (`Return` to Open, optional `F2` to Rename):**
  - When enabled and Finder is frontmost (with no text field or modal sheet focused), pressing `Return` translates to `⌘ O` (Open).
  - Optional `F2` to Rename translates `F2` into `Return` in Finder when not already editing a filename.
- **3. Auto-Quit on Last Window Close:**
  - Watches window closures for `.regular` applications.
  - Defaults to **Allowlist Only** mode (pre-populated with safe single-document/utility apps: Preview, TextEdit, QuickTime Player, System Settings, Calculator, Font Book) so users never lose long-running browsers, terminals, or IDEs unexpectedly.
  - Optional **All Except Excluded** mode applies globally while enforcing a mandatory protected system denylist (`com.apple.finder`, Toolbox's own bundle ID, Dock, and background/accessory apps).
  - Waits `autoQuitDelayMs` (default `500 ms`), re-verifies 0 remaining standard windows, and calls graceful `app.terminate()` (never `forceTerminate()`).
- **Settings View (`FinderEnhancerSettingsView.swift`):**
  - Built with `FeatureSection`, `SettingRow`, `Divider()`, and `.pointerCursor()` on all controls.
  - **Finder Cut & Paste** section: `Enable ⌘ X / ⌘ V file move` toggle, `Show toast on cut` toggle.
  - **Finder Navigation** section: `Return opens selected item` toggle, `F2 renames selected item` toggle.
  - **Auto-Quit on Last Window Close** section: master toggle, mode picker (`Allowlist Only` vs `All Except Excluded`), grace delay slider (`200–2000 ms`), and app picker/list for allowlist or exclusions.

### Files to Create
- `Sources/Toolbox/Modules/FinderEnhancer/FinderEnhancerModule.swift`
- `Sources/Toolbox/Modules/FinderEnhancer/FinderKeyInterceptor.swift`
- `Sources/Toolbox/Modules/FinderEnhancer/LastWindowQuitWatcher.swift`
- `Sources/Toolbox/Modules/FinderEnhancer/FinderEnhancerSettingsView.swift`

### Module Metadata
- `id`: `"finder_enhancer"`
- `name`: `"Finder Enhancer"`
- `tagline`: `"Add ⌘ X cut-and-paste and Return-to-open in Finder, plus optional auto-quit when an app's last window closes."`
- `symbolName`: `"folder.badge.gearshape"`
- `accentColor`: `Color.blue`
- `category`: `.system`
- `requiresAccessibility`: `true`

### Technical Design & macOS APIs
1. **Finder-Scoped `CGEventTap` (`FinderKeyInterceptor`):**
   - Run a `.cgSessionEventTap` (`.headInsertEventTap`, `.defaultTap`) on a dedicated background `Thread` + `CFRunLoop` listening to `keyDown`, active only when `enabled && appEnabled && AXIsProcessTrusted()`.
   - Cache `frontmostBundleID` via `NSWorkspace.didActivateApplicationNotification` (zero main-thread IPC inside the callback); if `frontmostBundleID != "com.apple.finder"`, pass through immediately.
   - Ignore synthetic events tagged with Toolbox's `0x544C4258` marker and re-arm on `tapDisabledByTimeout` / `tapDisabledByUserInput`.
2. **Mandatory Text-Input Safety Gate (`isFocusedElementTextInput`):**
   - Before intercepting `⌘ X`, `⌘ V`, `Return`, or `F2`, query `kAXFocusedUIElementAttribute` on Finder's `AXUIElementCreateApplication(pid)` (with `AXUIElementCreateSystemWide()` fallback) and inspect `kAXRoleAttribute` / `kAXSubroleAttribute` / enclosing window & sheet state.
   - If the focused element is `AXTextField`, `AXTextArea`, `AXComboBox`, or `AXSearchField` (inline filename rename, Finder search bar, `⇧ ⌘ G` Go to Folder, Get Info comments, or Open/Save sheets), pass the keystroke straight through untouched.
3. **Cut State Machine (`FinderCutStateMachine`):**
   - Pure state machine tracking `armedChangeCount: Int?`.
   - On `⌘ X`: capture `preCopyCount = NSPasteboard.general.changeCount`, post `0x544C4258`-tagged `⌘ C` directly to Finder via `postToPid`, and perform a bounded poll of `NSPasteboard.general.changeCount` (every `15 ms` up to `450 ms`). Only arm cut state if `changeCount` advances; if nothing was selected in Finder (`changeCount` unchanged), do **not** arm cut state and show no toast.
   - On `⌘ V`: proceed **only** if `armedChangeCount == NSPasteboard.general.changeCount` and `NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])` is true. Otherwise clear cut state and pass `⌘ V` through untouched.
   - When armed and valid: swallow `⌘ V`, post `0x544C4258`-tagged `⌥ ⌘ V` (`Move Item Here`) directly to Finder via `postToPid`, and clear `armedChangeCount`.
4. **Last-Window Auto-Quit (`LastWindowQuitWatcher`):**
   - Observe `NSWorkspace.didLaunchApplicationNotification`, `didTerminateApplicationNotification`, and per-app AX `kAXUIElementDestroyedNotification` (and `kAXWindowMiniaturizedNotification` ignored—minimized windows still count as open!).
   - Filter out `.accessory` / `.prohibited` activation policies and mandatory protected bundle IDs (`com.apple.finder`, `Bundle.main.bundleIdentifier`, `com.apple.dock`, `com.apple.SystemUIServer`).
   - Schedule a `DispatchWorkItem` for `autoQuitDelayMs`; cancel it if the app opens a new window or becomes active again; on fire, re-query `kAXWindowsAttribute` (filtering `AXStandardWindow` / `AXDialog`) and call `app.terminate()` only if count is `0`.
   - Remove all per-PID `AXObserver`s and pending `DispatchWorkItem`s cleanly in `stop()`, on app termination, and in `AppDelegate.applicationWillTerminate(_:)`.

### Configuration (`FinderEnhancerConfig`)
```swift
enum AutoQuitAppMode: String, Codable, CaseIterable, Sendable {
    case allowlistOnly = "allowlist_only"
    case allExceptExcluded = "all_except_excluded"
}

struct FinderEnhancerConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var enableCutAndPaste: Bool = true
    var showCutToast: Bool = true
    var enableReturnToOpen: Bool = false
    var enableF2ToRename: Bool = false
    var enableAutoQuitOnLastWindowClose: Bool = false
    var autoQuitMode: AutoQuitAppMode = .allowlistOnly
    var autoQuitDelayMs: Int = 500
    var autoQuitAllowlistBundleIDs: [String] = [
        "com.apple.Preview",
        "com.apple.TextEdit",
        "com.apple.QuickTimePlayerX",
        "com.apple.systempreferences",
        "com.apple.calculator",
        "com.apple.FontBook"
    ]
    var autoQuitExcludedBundleIDs: [String] = []
}
```
- `ToolboxConfig`: add `var finderEnhancer: FinderEnhancerConfig = FinderEnhancerConfig()` with lenient `decodeIfPresent` defaults, bump `schemaVersion`, and append `"finder_enhancer"` to `GeneralConfig.defaultMenuBarModuleOrder`.

### Verification & Self-Tests
- **`FinderCutStateMachine` (`SelfTestRunner`):** Verify `⌘ X` arms state → matching `changeCount` + `.fileURL` `⌘ V` emits move and disarms → second `⌘ V` passes through; changed `changeCount` disarms; `Esc` disarms; `isTextInputFocused == true` always passes through.
- **`LastWindowQuitWatcher` eligibility (`SelfTestRunner`):** Assert protected system bundle IDs are never eligible, `allowlistOnly` vs `allExceptExcluded` filtering works, and `windowCount > 0` or minimized windows block termination.
- **Config (`SelfTestRunner`):** Verify `FinderEnhancerConfig` `Codable` round-trip and partial JSON migration defaults.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_finder_enhancer.png`.

### Edge Cases & Pitfalls
- **Inline rename / Go to Folder / Get Info:** Text-input AX role check prevents `⌘ X` from breaking text editing or `Return` from opening files while renaming.
- **Cross-app copy invalidation:** Copying text in Safari after pressing `⌘ X` in Finder bumps `changeCount` and drops `.fileURL`, so pasting back in Finder never moves old files accidentally.
- **Read-only volumes & permissions:** Delegating the actual move to Finder's native `⌥ ⌘ V` ensures macOS handles volume boundaries, Trash/undo (`⌘ Z` in Finder), and auth prompts natively.
- **Unsaved documents on auto-quit:** Using graceful `app.terminate()` (never `forceTerminate()`) lets apps show their standard "Save changes?" sheet and cancel quit safely.
