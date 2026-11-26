# Keyboard Shortcuts Hub & Caps Lock Hyper Key — Feature Spec

> **Status:** Planned · **Module / Shell:** `Core/ShortcutCatalog.swift`, `Modules/HyperKey/`, `UI/ShortcutsHubView.swift` · **Sidebar:** `SidebarDestination.shortcuts` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Two tightly connected problems solved in one place:
1. **Central Per-Feature Shortcut Hub:** With 10+ shipped and 9+ planned modules, hunting across separate module pages to check which keys are bound, which chords are free, or why two features collide creates unnecessary friction. A dedicated **Keyboard Shortcuts** sidebar view organizes every Toolbox keybind into clean, feature-by-feature sections so users can inspect, search, test, and rebind everything from one calm command center.
2. **Caps Lock as a Dual-Role Hyper Key (Tap vs. Hold):** Caps Lock sits on prime home-row real estate yet is rarely used. Holding Caps Lock + any key triggers a full modifier chord—defaulting to **`⌃ ⌥ ⌘` (Toolbox's 3-modifier chord family)** so every default Toolbox shortcut (`Caps Lock + P`, `Caps Lock + M`, `Caps Lock + ←/→/↑/↓`, etc.) works immediately with zero rebinding, or optionally **`⌃ ⌥ ⇧ ⌘` (Classic 4-Key Hyper)**—while a quick single press-and-release toggles normal Caps Lock (or optional `Escape` / `Disabled`).

### User Flows & UX
Inspired by the cleanest macOS shortcut experiences (**Raycast**, **CleanShot X**, **Arc**, **BetterTouchTool**, and **HotkeyClash**) while using Toolbox's own design primitives (`FeatureSection`, `SettingRow`, `ToolboxSegmentedControl`, `ShortcutRecorderView`, `ShortcutConflictStatusView`, `StatusBadge`, `.pointerCursor()`):

- **Sidebar Navigation (`SidebarDestination.shortcuts`):**
  - Dedicated **"Keyboard Shortcuts"** item (`keyboard` SF Symbol) placed directly below **Dashboard** in `Sources/Toolbox/UI/MainWindowController.swift` as a first-class workspace rather than buried under Settings.
  - Displays a subtle amber conflict dot **only** when active shortcuts collide (zero visual noise when healthy).
- **Header & Sticky Search/Filter Bar:**
  - Standard `BackToDashboardBar` + title **"Keyboard Shortcuts"** + calm live health pill (`"14 Active · 0 Conflicts"` or a clickable amber `"2 Conflicts"` pill that jumps straight to the conflicting section).
  - Instant search field (`"Search feature, action, or shortcut…"`) paired with a **"Press Key to Find"** toggle: pressing any physical chord highlights the owning feature row or reports `"<chord> is available"` immediately.
  - `ToolboxSegmentedControl` filter tabs (**`All`**, **`Active`**, **`Unassigned`**, **`Conflicts`**) plus a subtle `Hide disabled features` toggle.
- **Section 1 — Caps Lock Hyper Key (`FeatureSection`, Compact-When-Off Hero Card):**
  - When toggled OFF, collapses to a single clean `SettingRow` toggle so users who only want shortcut organization experience zero visual bloat.
  - Expands smoothly when toggled ON to reveal:
    - **Inline Permissions Check** (shown only if Accessibility or Input Monitoring is missing) + a 1-line check reminding users to keep **System Settings → Keyboard → Modifier Keys → Caps Lock** set to **"Caps Lock"** (overriding it natively to *No Action* starves macOS 14+/15 event taps of raw hardware presses).
    - **Hold Caps Lock acts as** (`ToolboxSegmentedControl`): **`⌃ ⌥ ⌘` (Toolbox Chord — Recommended)** vs **`⌃ ⌥ ⇧ ⌘` (Classic 4-Key Hyper)**.
    - **Single Tap Caps Lock** (`ToolboxSegmentedControl`): **`Toggle Caps Lock`** (default), **`Escape`**, or **`Disabled`**, plus **Tap Speed** slider (`120–400 ms`, default `250 ms`).
    - **Live Key Tester Micro-Strip** (BetterTouchTool-inspired): press `Caps Lock` alone or `Caps Lock + <key>` right on the page to see live feedback (`"Tapped → Toggle Caps Lock"` or `"Held → Dispatched Port Killer (⌃ ⌥ ⌘ P)"`).
- **Section 2 — Visual Key Map (`FeatureSection`, Collapsible Availability Matrix):**
  - Collapsible drawer (collapsed by default to keep the screen serene) with a modifier-family `ToolboxSegmentedControl` (`⌃ ⌥ ⌘`, `⌥ ⌘`, `⇧ ⌘`, `⌃ ⌥ ⇧ ⌘`).
  - Compact ANSI-style keycap grid (`1–0`, `Q–P`, `A–L`, `Z–M`, arrows/specials) with `.pointerCursor()`:
    - **Assigned keycap:** Tinted with the owning module's `accentColor`; hover tooltip names the feature & action; clicking scrolls to and briefly highlights that row.
    - **Available (Free) keycap:** Subtle outline; clicking opens a quick picker to assign that free chord to any Toolbox action in one click.
    - **System Reserved keycap:** Muted amber warning outline sourced from `HotKeyManager.wellKnownSystemShortcuts` with hover tooltip naming the macOS action.
- **Section 3 — Feature-by-Feature Keybind Sections (Core UX):**
  - **One dedicated `FeatureSection` card per Toolbox feature** (e.g., *Clipboard History*, *Window Snapper*, *Call Controls*, *Localhost Port Killer*, *Screen OCR*, *Keep Awake*, *Custom Commands*, plus upcoming modules as they ship), ordered consistently with `ModuleRegistry`.
  - **Per-Feature Header:** Module SF Symbol icon tinted with `module.accentColor`, feature name, `StatusBadge` (`Active` / `Disabled` / `Paused`), and a clean trailing **`Open Feature →`** link (`navState.navigate(to: .module(module.id))`).
  - **Clean `SettingRow`s separated by `Divider()`:**
    - Left: Action label + brief plain-English subtitle.
    - Right: `ShortcutRecorderView` (keycap glyphs `⌃ ⌥ ⌘ P`, pulsing active-recording state, clear `×`) + subtle **Reset** icon button shown *only* when modified from default.
    - Inline `ShortcutConflictStatusView` (warning triangle + plain-English conflict reason + 1-click **Assign Here** button) rendered *only* when an in-app collision or system-shortcut overlap exists.
  - **Progressive Disclosure for Shortcut-Heavy Features:** Modules with many bindings (such as `Window Snapper`'s 14+ actions) show primary chords (`Left / Right / Top / Bottom / Maximize`) directly and tuck secondary chords (`Quarters`, `Displays`, `Undo`, `Restore`) inside a clean collapsible disclosure in that feature's card—auto-expanding whenever search or the `Conflicts` filter matches a hidden row.
  - **Calm Footer:** Subtle **Reset All Shortcuts to Defaults** (`ToolboxDestructiveButtonStyle` with confirmation alert).

### Files to Create & Modify
- **Create:**
  - `Sources/Toolbox/Core/ShortcutCatalog.swift` (single declarative source of truth describing every module shortcut's `id`, `moduleID`, `moduleName`, `actionTitle`, `group` (`primary`/`secondary`), `defaultSpec`, and `read`/`write` closures on `ToolboxConfig`)
  - `Sources/Toolbox/Modules/HyperKey/HyperKeyModule.swift`
  - `Sources/Toolbox/Modules/HyperKey/CapsLockRemapper.swift`
  - `Sources/Toolbox/Modules/HyperKey/HyperKeyEventTap.swift`
  - `Sources/Toolbox/UI/ShortcutsHubView.swift`
- **Modify:**
  - `Sources/Toolbox/UI/MainWindowController.swift` (add `SidebarDestination.shortcuts`, sidebar row directly under Dashboard + conflict indicator dot, detail view switch)
  - `Sources/Toolbox/Core/HotKeyManager.swift` (delegate `inAppConflictDescription` and `clearConflictingShortcuts` to `ShortcutCatalog`, plus expose a lock-protected active-binding snapshot for direct Hyper Key dispatch)
  - `Sources/Toolbox/Core/PermissionsManager.swift` (add opt-in Input Monitoring permission check `isInputMonitoringGranted` via `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` and `requestInputMonitoringAccess()`, surfaced *only* when Caps Lock Hyper Key is enabled)
  - `Sources/Toolbox/Core/ConfigManager.swift` (add `HyperKeyConfig` to `ToolboxConfig` with lenient `decodeIfPresent`, bump `schemaVersion`)
  - `Sources/Toolbox/ToolboxApp.swift` (hook `HyperKey` HID-remap restoration + tap teardown into `AppDelegate.applicationWillTerminate(_:)`)
  - `Sources/Toolbox/Core/SelfTestRunner.swift` and `Sources/Toolbox/Core/SnapshotRunner.swift`

### Module / Feature Metadata
- `id`: `"hyper_key"` *(for `HyperKeyModule`; `SidebarDestination.shortcuts` is always visible in the sidebar)*
- `name`: `"Keyboard Shortcuts & Hyper Key"`
- `tagline`: `"Organize every Toolbox shortcut by feature and turn Caps Lock into a dual-role Hyper Key."`
- `symbolName`: `"keyboard"`
- `accentColor`: `Color.indigo`
- `category`: `.automation`
- `requiresAccessibility`: `false` for the Shortcuts Hub UI (zero permissions); **Accessibility + Input Monitoring** (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`) required only when **Caps Lock Hyper Key** is toggled ON.

### Technical Design & macOS APIs
1. **Unified `ShortcutCatalog` (`Core/ShortcutCatalog.swift`):**
   - Declarative `[ShortcutDescriptor]` covering every module shortcut (`id`, `moduleID`, `moduleName`, `actionTitle`, `subtitle`, `isPrimary`, `defaultSpec`, `read(from:)`, `write(_:to:)`, `isModuleEnabled(in:)`).
   - Replaces duplicated per-module switch/if chains in `HotKeyManager.inAppConflictDescription` and `HotKeyManager.clearConflictingShortcuts`, drives the per-feature sections and Visual Key Map in `ShortcutsHubView`, and enables an automated `SelfTestRunner` default-collision assertion.
2. **In-Process `IOHIDServiceClientSetProperty` Remapping (`CapsLockRemapper`):**
   - Use `IOKit` user-space HID APIs directly in-process (`IOHIDEventSystemClientCreate` → `IOHIDEventSystemClientCopyServices` → `IOHIDServiceClientSetProperty` for `kIOHIDUserKeyUsageMapKey`) to remap `Caps Lock` (`0x700000039`) → `F18` (`0x70000006D`).
   - **Why in-process instead of shelling out to `/usr/bin/hidutil`:** Starting in macOS Sonoma 14.2 and Sequoia 15, `UserKeyMapping` requires **Input Monitoring** TCC authorization. Running in-process means the user authorizes **Toolbox.app** once—never `/usr/bin/hidutil` + Terminal separately.
   - **Bonus benefit:** Driver-level remapping eliminates macOS's built-in ~100 ms Caps Lock tap-delay jitter while preserving instant LED-synced Caps Lock toggling via `IOHIDGetModifierLockState` / `IOHIDSetModifierLockState` (`kIOHIDCapsLockState`) in `IOKit.hidsystem`.
   - Snapshot any pre-existing `UserKeyMapping` first so external remaps (Karabiner-Elements or macOS Modifier Keys) are detected and warned about cleanly, and restore the pre-Toolbox map unconditionally on teardown.
3. **Hyper Key Event Tap & Direct Dispatch (`HyperKeyEventTap`):**
   - Run a dedicated background `Thread` + `CFRunLoop` `CGEventTap` (`.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`) guarded by an `OSAllocatedUnfairLock`-protected `HyperKeyStateMachine` (Swift 6 data-race safe, ignores `0x544C4258`-tagged synthetic events, re-arms on `tapDisabledByTimeout` / `tapDisabledByUserInput`).
   - **Critical macOS Fix — Direct In-Process Dispatch for Toolbox Carbon HotKeys:**
     - Carbon's `RegisterEventHotKey` evaluates WindowServer/hardware modifier state and often **ignores** synthetic modifier flags simply OR'd onto a `CGEvent` inside `.cgSessionEventTap`.
     - **Fast Path (Toolbox shortcuts):** When `F18` is held and a non-modifier key `K` receives `keyDown`, compute `(K, activeHyperModifiers)` and check `HotKeyManager`'s lock-protected snapshot of registered Toolbox bindings. If matched, swallow `keyDown` (`return nil`), mark `usedAsChord = true`, and invoke that Toolbox action directly on `@MainActor`—100% deterministic with zero Carbon synthetic-flag drops.
     - **Pass-Through / Third-Party App Path (unmatched chords):** When no registered Toolbox shortcut matches `(K, activeHyperModifiers)`, mark `usedAsChord = true` and post a complete `0x544C4258`-tagged modifier lifecycle (`kCGEventFlagsChanged` down → modified `keyDown` / `keyUp` → `kCGEventFlagsChanged` up) via `.cgSessionEventTap` so downstream apps and taps receive clean modifier transitions.
   - **Single Tap-and-Release (`F18` `keyUp`):** Swallow event and set `isHeld = false`. If `!usedAsChord && (now - downTimestamp) <= tapThresholdMs`:
     - `.capsLock`: toggle OS Caps Lock via `IOHIDSetModifierLockState` (`kIOHIDCapsLockState`).
     - `.escape`: post `0x544C4258`-tagged `Escape` (`keyCode 53`) `keyDown` + `keyUp`.
     - `.none`: no-op.
4. **Guaranteed Restoration Invariant:**
   - Restore `UserKeyMapping` back to its pre-Toolbox state and tear down the tap in `stop()`, whenever `enabled == false` or `config.general.appEnabled == false`, whenever Accessibility or Input Monitoring is revoked, and unconditionally in `AppDelegate.applicationWillTerminate(_:)`. On app launch, if `hyperKey.enabled == false`, clean up any leftover `0x700000039 → 0x70000006D` mapping.

### Configuration (`HyperKeyConfig`)
```swift
enum HyperKeyHoldMode: String, Codable, CaseIterable, Sendable {
    case toolboxChord = "toolbox_chord" // ⌃ ⌥ ⌘
    case classicHyper = "classic_hyper" // ⌃ ⌥ ⇧ ⌘
}

enum HyperKeyTapAction: String, Codable, CaseIterable, Sendable {
    case capsLock = "caps_lock"
    case escape = "escape"
    case none = "none"
}

struct HyperKeyConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var holdMode: HyperKeyHoldMode = .toolboxChord
    var tapAction: HyperKeyTapAction = .capsLock
    var tapThresholdMs: Int = 250
}
```
- `ToolboxConfig`: add `var hyperKey: HyperKeyConfig = HyperKeyConfig()` with lenient `decodeIfPresent` defaults and bump `schemaVersion`.

### Verification & Self-Tests
- **Zero Default Shortcut Collisions (`SelfTestRunner`):** Iterate `ShortcutCatalog.all` against `ToolboxConfig()` defaults and assert no two non-`.none` defaults share the same `ShortcutSpec`.
- **Direct Dispatch & `HyperKeyStateMachine` (`SelfTestRunner`):**
  - Quick tap (`< tapThresholdMs`, no other key) → emits `.triggerTapAction(.capsLock)` / `.escape` / `.none`.
  - Slow hold-and-release (`> tapThresholdMs`, no other key) → does NOT trigger Caps Lock tap.
  - Hold + registered Toolbox key (`P`) → returns `.dispatchToolboxHotKey("port_killer.toggle")`, sets `usedAsChord = true`, and releasing `F18` does NOT toggle Caps Lock.
  - Hold + unmatched key (`L`) → returns `.synthesizeThirdPartyChord`, sets `usedAsChord = true`, and cleans up cleanly on key rollover (releasing `F18` before `L` keyUp).
- **Config & Navigation (`SelfTestRunner`):** Verify `HyperKeyConfig` `Codable` round-trip, lenient partial JSON decoding, and `SidebarDestination.shortcuts` navigation history round-trip.
- **Visual Snapshot (`SnapshotRunner`):** Render `shortcuts_hub.png`.

### Edge Cases & Pitfalls
- **macOS 14.2+ / 15 Sequoia Input Monitoring TCC silent failure:** `IOHIDServiceClientSetProperty` can return success yet fail to remap keys unless **Input Monitoring** (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`) is granted; check this explicitly and show a one-click **Open Input Monitoring** prompt when Caps Lock Hyper Key is enabled.
- **macOS Modifier Keys override conflict:** If the user previously set Caps Lock → *No Action* or *Control* in **System Settings → Keyboard → Modifier Keys**, macOS suppresses raw Caps Lock events before `UserKeyMapping` sees them; detect and instruct users to keep native Caps Lock set to **"Caps Lock"**.
- **Carbon `RegisterEventHotKey` synthetic-flag bypass:** Solved by the Direct In-Process Fast Path in `HyperKeyEventTap` so Toolbox's own shortcuts never depend on Carbon honoring synthetic `CGEventFlags`.
- **Force-quit / crash recovery & external keyboards:** Observe `IOHIDManager` USB keyboard attach events to apply `UserKeyMapping` to newly plugged keyboards, clean stale mappings on next launch if `enabled == false`, and document manual reset (`hidutil property --set '{"UserKeyMapping":[]}'` or keyboard replug).
- **Secure Input (password fields):** macOS pauses `CGEventTap` during Secure Event Input; reset `isHeld = false` on focus/Secure Input transitions so modifiers never stick.
