# Keyboard & Trackpad Clean Lock — Feature Spec

> **Status:** Done · **Module:** `Modules/CleanLock/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Wiping crumbs or dust off a MacBook keyboard or trackpad triggers random shortcuts, pauses media, clicks things behind the cloth, or types gibberish into open editors. **Clean Lock** locks **both** your keyboard (including media, volume, and brightness keys) and your mouse/trackpad clicks & scrolling for a fixed timer (**60 seconds / 1 minute** by default) while displaying **large countdown numbers in the center of the screen** (`60`, `59`, `58`…) until full control automatically resets—paired with a deliberate **press-and-hold kill switch** (`Hold ⌃ ⌥ ⌘ Esc` for `3s`) that is virtually impossible to trigger accidentally with a cleaning cloth.

### User Flows & UX
- **Activate Lock ("Lock Keyboard & Mouse (1m)" button in Settings or Menu Bar quick action):**
  - Requires Accessibility permission (same gate as `DockMinimize` and `ScrollDirection`). If Accessibility is not granted, prompt instead of locking.
  - Has **no global trigger keybind**—Clean Lock is only triggered intentionally from the Settings button or Status Bar menu.
  - Installs `InputLockTap` on a dedicated background thread and displays `CleanLockHUDPanel` dead-center on the active screen.
- **Locked State & Large Center-Screen Countdown (`CleanLockHUDPanel`):**
  - Non-activating centered floating card (`ignoresMouseEvents = true`, high-contrast frosted material) showing:
    - **Large monospaced countdown numbers** (`60`, `59`, `58`…, `~72–84 pt` bold rounded/monospaced digits) surrounded by an animated **circular progress ring** counting down smoothly to `0`,
    - Clear label (`"Cleaning Lock Active — Keyboard & Trackpad Locked"`),
    - Live blocked-input counter (`"14 inputs blocked"`),
    - **Emergency Kill Switch indicator:** `"Hold ⌃ ⌥ ⌘ Esc (3s) to unlock early"`, which fills an inline hold-progress bar in real time while the user holds the 4-key combo.
  - When either the timer reaches `0` or the kill switch is held for `3s`, `CleanLockModule` automatically uninstalls `InputLockTap`, dismisses `CleanLockHUDPanel`, restores full keyboard/mouse control, and shows a brief `"Keyboard & Mouse Unlocked"` `HUDToast`.
- **Settings View (`CleanLockSettingsView.swift`):**
  - **Lock Controls** section: prominent **"Lock Keyboard & Mouse"** primary button (showing the selected duration, e.g., `"Lock for 60s"`), duration picker (`15s`, `30s`, `60s` default, `2m`, `3m`), and `Also lock mouse & trackpad clicks` toggle (default **ON**). (No `ShortcutRecorderView` needed.)
  - **How Release Works** section: explains that the large center-screen countdown automatically restores full input at `0`, and documents the emergency **Hold `⌃ ⌥ ⌘ Esc` for 3s** kill switch.

### Files Created
- `Sources/Toolbox/Modules/CleanLock/CleanLockModule.swift`
- `Sources/Toolbox/Modules/CleanLock/InputLockTap.swift`
- `Sources/Toolbox/Modules/CleanLock/CleanLockHUDPanel.swift`
- `Sources/Toolbox/Modules/CleanLock/CleanLockSettingsView.swift`

### Module Metadata
- `id`: `"clean_lock"`
- `name`: `"Clean Lock"`
- `tagline`: `"Lock your keyboard and trackpad for 1 minute with a large on-screen countdown for safe cleaning."`
- `symbolName`: `"keyboard.badge.ellipsis"`
- `accentColor`: `Color.red`
- `category`: `.system`
- `requiresAccessibility`: `true`
- `accessibilityReason`: `"Needed to intercept and temporarily block keyboard and pointer events during the Clean Lock countdown."`

### Technical Design & macOS APIs
1. **Dedicated Background Event Tap (`InputLockTap`):**
   - Mirror `ScrollInversionTap`: `CGEvent.tapCreate` at `.cgSessionEventTap` / `.headInsertEventTap` / `.defaultTap` on a dedicated `Thread` + `CFRunLoopRun()` (`app.toolbox.clean-lock-tap`), never on the main thread.
   - Re-arm on `.tapDisabledByTimeout` / `.tapDisabledByUserInput` only while `isLockActive` is true.
   - **Event Mask:**
     - Always swallow keyboard events: `keyDown`, `keyUp`, `flagsChanged`, and `CGEventType(rawValue: 14)!` (`NSEvent.EventType.systemDefined` — covers hardware volume, brightness, Play/Pause, Mission Control, and Fn media keys!).
     - When `lockMouseAndTrackpad == true` (default), also swallow `leftMouseDown`, `leftMouseUp`, `rightMouseDown`, `rightMouseUp`, `otherMouseDown`, `otherMouseUp`, and `scrollWheel` (allowing `mouseMoved` to pass so the cursor remains visible, or swallowing clicks/scrolls so wiping the trackpad cannot click anything).
     - **Sticky Modifier Prevention:** If the user had any modifier keys held right at the instant they clicked Lock, let `flagsChanged` release events through during the first `150 ms` so macOS never treats a modifier as stuck.
2. **Triple-Layer Release & Lifecycle Safety (Mandatory Safety Invariant):**
   - **Layer 1 — Bounded Countdown Timer (Primary Release):**
     - Every lock session starts a `0.1 s` / `1.0 s` main-actor `Timer` initialized from `durationSeconds` (clamped `10...300`, default `60`).
     - Never allow an unbounded or infinite lock—when `remainingSeconds <= 0`, `unlock(reason: .timerExpired)` unconditionally tears down `InputLockTap` and closes `CleanLockHUDPanel`.
   - **Layer 2 — Press-and-Hold Kill Switch (`Hold ⌃ ⌥ ⌘ Esc` for `3s`):**
     - Inside `InputLockTap`, detect `keyDown` for `kVK_Escape` when `.maskControl`, `.maskAlternate`, and `.maskCommand` are all held (requiring 3 spread modifiers + top-left `Esc` makes accidental cloth activation virtually impossible).
     - Record `killSwitchHoldStartedAt` on initial `keyDown`, drive a live `0.0 → 1.0` hold-progress indicator in `CleanLockHUDPanel` on a short tick, and cancel/reset immediately if `keyUp` (`kVK_Escape`) or `flagsChanged` (releasing any of `⌃`/`⌥`/`⌘`) occurs before `3s`.
     - Once held continuously for `>= 3s`, trigger `unlock(reason: .killSwitchHeld)` on `DispatchQueue.main` and swallow the `Esc` event so it never cancels anything underneath.
   - **Layer 3 — Lifecycle & Termination Teardown:**
     - `CleanLockModule.stop()` and `AppDelegate.applicationWillTerminate(_:)` unconditionally call `unlock(reason: .systemStop)` and `tap.uninstall()`.
     - Note: Power button / Touch ID / `Ctrl+Cmd+Q` / Force Restart remain handled below session taps by macOS WindowServer/loginwindow as an OS hardware safety net.
3. **Large Center-Screen Countdown HUD (`CleanLockHUDPanel`):**
   - `.nonactivatingPanel` + `.borderless`, `level = .screenSaver` (centered on `NSScreen.main`, stays clearly visible above all windows and full-screen spaces), `ignoresMouseEvents = true`, `backgroundColor = .clear`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`.
   - Displays a `~300 × 300` pt rounded card with `.ultraThickMaterial`, circular progress ring (`trim(from: 0, to: progress)`), large monospaced countdown digits (`72–84 pt`), and blocked-event counter.

### Configuration (`CleanLockConfig`)
```swift
struct CleanLockConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var durationSeconds: Int = 60
    var lockMouseAndTrackpad: Bool = true
}
```
- `ToolboxConfig`: add `var cleanLock: CleanLockConfig = CleanLockConfig()`.

### Verification & Self-Tests
- **Pure event filtering & kill-switch hold tests (`SelfTestRunner`):**
  - Construct synthesized `CGEvent`s:
    - Keyboard `keyDown` (`A`) → `InputLockTap.evaluateEvent(...)` returns `.swallow` and increments blocked count.
    - Quick tap of `⌃ ⌥ ⌘ Esc` released before `3s` → resets hold progress and stays locked.
    - `⌃ ⌥ ⌘ Esc` held continuously for `>= 3s` → triggers `.unlock` while swallowing the `Esc` event.
    - Mouse click / scroll when `lockMouseAndTrackpad == true` → `.swallow`; when `false` → `.passThrough`.
    - `mouseMoved` → `.passThrough`.
- **Countdown & lifecycle tests (`SelfTestRunner`):**
  - Verify `durationSeconds` clamps safely (`10...300`) and defaults to `60`.
  - Verify timer reaching `0` clears locked state and `stop()` cancels the countdown and tears down cleanly.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_clean_lock.png` (and optionally a preview of the countdown HUD card inside Settings or snapshot).

### Edge Cases & Pitfalls
- **Never allow infinite lock:** `durationSeconds` must always be finite and clamped (`10...300` seconds) so a user can never trap their input session.
- **No `HotKeyManager` registration:** Clean Lock uses a Menu Bar / Settings button only and automatically unlocks via the countdown timer, so it never occupies any global shortcut slot.
- **Accessibility check before locking:** Check `AXIsProcessTrusted()` right when locking is requested; if `false`, refuse to enter locked state and surface `PermissionsManager.shared.promptAndOpenSettings()`.
