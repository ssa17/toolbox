# Call Controls — Feature Spec

> **Status:** Done · **Module:** `Modules/CallControls/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Every video call app uses a different shortcut for Mic Mute (`⌘ ⇧ A` in Zoom, `⌘ ⇧ Space` in Slack, `⌘ ⇧ M` in Teams/Discord, `⌘ D` in Google Meet) and Video Off/On (`⌘ ⇧ V` in Zoom/Slack/Discord, `⌘ ⇧ O` in Teams, `⌘ E` in Google Meet). Worse, macOS isolates camera feeds per app so there is no OS-level video kill switch.

**Call Controls** solves both with a **Unified Call Keybind Override** plus CoreAudio power-user tools:
1. **Your One Mic Keybind & One Video Keybind:** Pick one Mic shortcut (default `⌃ ⌥ ⌘ M`) and one Video shortcut (default `⌃ ⌥ ⌘ V`), then simply toggle **ON/OFF** which common call apps (`Microsoft Teams`, `Zoom`, `Slack`, `Google Meet`, `Discord`, `FaceTime`) Toolbox should handle.
   - When you're in an enabled app (say **Microsoft Teams** with native Video `⌘ ⇧ O`) and press your custom keybind, Toolbox automatically translates and fires `⌘ ⇧ O` into Teams—without hijacking your shortcut in unrelated apps like VS Code or Finder!
   - Defaults to **Everywhere** scope so pressing your keybind even while coding in an editor routes to your running call app.
2. **Global OS Hardware Mic Mute (`CoreAudio`):** Instant hardware-level mute across all apps (with volume-zero fallback) and quick Menu Bar / hotkey control.
3. **Floating Call Pill & Developer Simulator:** Draggable top-right pill (`[≡] | Mic | Video`, shown automatically during calls by default) plus quick device switching, optional *Unclack*-style **Auto-Mute Mic While Typing**, and built-in `Developer → Call Controls` simulation & AX probing tools.

### User Flows & UX
- **Unified Mic & Video Keybind Override:**
  - User picks their preferred **My Mic Keybind** (`micShortcut`) and **My Video Keybind** (`videoShortcut`) using `ShortcutRecorderView`.
  - Below those two pickers sits a clean **Supported Call Apps** list pre-populated with the most common apps and their native shortcuts:
    - **Microsoft Teams** — Mic `⌘ ⇧ M`, Video `⌘ ⇧ O`
    - **Zoom** — Mic `⌘ ⇧ A`, Video `⌘ ⇧ V`
    - **Slack** — Mic `⌘ ⇧ Space`, Video `⌘ ⇧ V`
    - **Google Meet (Chrome / Arc / Safari / Brave)** — Mic `⌘ D`, Video `⌘ E`
    - **Discord** — Mic `⌘ ⇧ M`, Video `⌘ ⇧ V`
    - **FaceTime** — Mic `⌘ ⇧ M`, Video *(none — OS/app doesn't expose a camera shortcut)*
  - Each app row has a simple **ON/OFF toggle** (`isEnabled`) so the user chooses exactly which apps Toolbox handles.
  - **Context-Aware Routing (`overrideScope`):**
    - **Everywhere (Default):** Routes from any frontmost app to an enabled active/running call app, falling back cleanly or muting the OS mic when idle.
    - **Active Call App Only:** Only intercepts your Mic/Video keybinds when a toggled-on call app is the frontmost active window.
- **OS Hardware Mic Mute (`osMuteShortcut`, optional):**
  - Optional global Carbon shortcut (`osMuteShortcut`) + Menu Bar quick toggle that mutes the macOS default input device at the CoreAudio HAL level (`kAudioDevicePropertyMute`) regardless of which app is open, and updates `FloatingMicIndicatorPanel` + `HUDToast`.
  - Users can also pair CoreAudio hardware mute when their Unified Mic Keybind fires (`syncHardwareMuteWithAppMicToggle`).
- **Quick Device Switching (`Cycle Output` shortcut or Menu Bar / Settings):**
  - Lists all available CoreAudio input & output devices with transport icon (`Built-in`, `Bluetooth`, `USB`, `DisplayPort/HDMI`, `Aggregate/Virtual`).
  - Lets users star **Favorite Output Devices** so pressing the optional `Cycle Output` shortcut toggles cleanly between e.g. `MacBook Pro Speakers` and `AirPods`.
- **Auto-Mute Mic While Typing (Optional *Unclack* Mode):**
  - When enabled (and Accessibility is granted), listens passively to keystrokes (`CGEventTap` `.listenOnly`).
  - The instant typing starts, mutes the OS mic via CoreAudio if it was live, and restores unmuted state after `typingUnmuteDelayMs` (default `450 ms`) of keyboard silence.
  - **Precedence rule:** If the user *manually* muted the mic, typing never unmutes it!
- **Settings View (`CallControlsSettingsView.swift`):**
  - **Unified Call Keybinds** section: `My Mic Keybind` (`ShortcutRecorderView`), `My Video Keybind` (`ShortcutRecorderView`), `Override Scope` picker, `Also mute macOS hardware mic` toggle, and inline Accessibility warning if enabled without Accessibility permission.
  - **Floating Call Pill** section: toggle visibility, call-only auto-show mode, show/hide video button, and reset top-right position.
  - **Supported Call Apps** section: pre-populated list (`Teams`, `Zoom`, `Slack`, `Google Meet`, `Discord`, `FaceTime`) with an **On/Off Toggle** per row and an **"Add App…"** picker that scans the selected app's macOS Accessibility menu bar (`AXMenuBar`) for native mic/video controls.
  - **OS Hardware Mic & Typing Guard** section: live hardware mute toggle button, optional `Global OS Mic Mute` shortcut (`ShortcutRecorderView`), `Auto-Mute Mic While Typing` toggle, and restore delay slider (`250 ms` – `1000 ms`).
  - **Audio Devices** section: live Input and Output device lists with active checkmark, favorite star toggle (for `Cycle Output` shortcut), and volume/mute indicator.

### Files Created
- `Sources/Toolbox/Modules/CallControls/CallControlsModule.swift`
- `Sources/Toolbox/Modules/CallControls/CoreAudioController.swift`
- `Sources/Toolbox/Modules/CallControls/CallShortcutRemapper.swift`
- `Sources/Toolbox/Modules/CallControls/TypingMicGuard.swift`
- `Sources/Toolbox/Modules/CallControls/FloatingMicIndicatorPanel.swift`
- `Sources/Toolbox/Modules/CallControls/CallControlsSettingsView.swift`
- `Sources/Toolbox/UI/DeveloperCallControlsView.swift`
- **Build link update:** `.linkedFramework("CoreAudio")`, `.linkedFramework("AudioToolbox")`, and `.linkedFramework("CoreMediaIO")` in `Package.swift`.

### Module Metadata
- `id`: `"call_controls"`
- `name`: `"Call Controls"`
- `tagline`: `"One shortcut for Mic & Video across FaceTime, Teams, Zoom, Slack & Meet, live call pill, and device switching."`
- `symbolName`: `"mic.slash"`
- `accentColor`: `Color.green`
- `category`: `.system`
- `requiresAccessibility`: `false` *(Optional: core CoreAudio mic mute and device switching require zero permissions; Accessibility is required for **Unified Call Keybind Override** and **Auto-Mute While Typing**. `CallControlsSettingsView` shows an inline Accessibility banner whenever an Accessibility-dependent subfeature is enabled and `!permissions.isAccessibilityGranted`.)*

### Technical Design & macOS APIs
1. **Context-Aware Call Shortcut Remapper (`CallShortcutRemapper`):**
   - **Built-in Default Presets (`CallAppShortcutMapping.defaults`):**
     - **Microsoft Teams** (`com.microsoft.teams2`): Mic `⌘ ⇧ M`, Video `⌘ ⇧ O`
     - **Zoom** (`us.zoom.xos`): Mic `⌘ ⇧ A`, Video `⌘ ⇧ V`
     - **Slack** (`com.tinyspeck.slackmacgap`): Mic `⌘ ⇧ Space`, Video `⌘ ⇧ V`
     - **Google Meet (Chrome / Arc / Safari / Brave)** (`com.google.Chrome`, `company.thebrowser.Browser`, `com.apple.Safari`, `com.brave.Browser`, with `requiredWindowTitleSubstring = "Meet"`): Mic `⌘ D`, Video `⌘ E`
     - **Discord** (`com.hnc.Discord`): Mic `⌘ ⇧ M`, Video `⌘ ⇧ V`
     - **FaceTime** (`com.apple.FaceTime`): Mic `⌘ ⇧ M`, Video `.none` (silent `AXMenuBar` trigger supported)
   - **Why `CallShortcutRemapper` uses a context-aware `CGEventTap` instead of always-on Carbon hotkeys (when `overrideScope == .activeCallAppOnly`):**
     - Carbon `RegisterEventHotKey` intercepts a key combination **everywhere** on macOS—even if the user set `My Mic Keybind` to `⌘ ⇧ Space` (which they still want to work normally in other apps).
     - Using a lightweight background `CGEventTap` (`.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`, listening to `keyDown` only and ignoring synthetic events tagged with Toolbox's own `eventSourceUserData` magic marker `0x544C4258`):
       1. Cache `frontmostBundleID` / `frontmostPID` via `NSWorkspace.didActivateApplicationNotification` (zero main-thread IPC inside the tap callback!).
       2. Check if the pressed `keyCode` + normalized modifier flags match `micShortcut` or `videoShortcut`. If not → pass event straight through immediately (`return Unmanaged.passUnretained(event)`).
       3. Resolve the target `CallAppShortcutMapping`:
          - **Active app match:** If `frontmostBundleID` matches an enabled mapping (and if `requiredWindowTitleSubstring` is set, e.g. `"Meet"`, verify the frontmost/active window title contains `"Meet"`), select it.
          - **Background call app match (only if `overrideScope == .activeOrRunningBackground`):** Check the most recently active running app from `NSWorkspace.shared.runningApplications` matching an enabled mapping.
          - **No matching enabled call app:** Pass the keystroke straight through untouched! (So `⌘ ⇧ Space` / `⌘ ⇧ V` continues working normally in all non-call apps.)
       4. **Same-Shortcut Pass-Through Optimization:** If the resolved app's native shortcut is **already identical** to the user's custom shortcut (e.g., user picked `⌘ ⇧ Space` and is currently focused in **Slack**), let the original `CGEvent` pass straight through untouched (`return Unmanaged.passUnretained(event)`) instead of swallowing and re-synthesizing it!
       5. **Translate & Dispatch:** Otherwise swallow the user's custom `keyDown` (`return nil`), wait for modifier bleed safety or synthesize clean `keyDown` + `keyUp` `CGEvent`s tagged with `0x544C4258` for the app's native shortcut (`targetShortcut`):
          - **Primary:** `event.postToPid(targetPID)` (works cleanly without focus disruption in native apps like Zoom).
          - **Optional Focus-and-Restore Fallback (`allowBriefFocusRestore`):** When `overrideScope == .activeOrRunningBackground` targets a background Electron/browser app (Teams, Slack, Google Meet, Discord) that ignores `postToPid`, save `previousApp`, call `targetApp.activate()`, wait `~80 ms`, post via `.cghidEventTap`, wait `~60 ms`, and restore focus to `previousApp`.
          - Show compact `HUDToast` (`"Mic → Teams (⌘ ⇧ M)"` / `"Video → Teams (⌘ ⇧ O)"`).
2. **CoreAudio HAL Controller (`CoreAudioController`):**
   - Pure CoreAudio wrapper around `kAudioObjectSystemObject` (`<CoreAudio/CoreAudio.h>`):
     - **Enumerate devices:** Read `kAudioHardwarePropertyDevices` (`AudioObjectGetPropertyDataSize` + `AudioObjectGetPropertyData`).
     - **Device metadata:** Read `kAudioObjectPropertyName` (`CFString`), `kAudioDevicePropertyDeviceUID` (`CFString`), `kAudioDevicePropertyTransportType` (`UInt32` — built-in, Bluetooth, USB, etc.).
     - **Input vs Output capability:** Query `kAudioDevicePropertyStreamConfiguration` for `kAudioObjectPropertyScopeInput` and `kAudioObjectPropertyScopeOutput`, summing `mNumberChannels` across `AudioBufferList` buffers to classify input/output availability cleanly.
     - **Default Device Read/Write:** Read & set `kAudioHardwarePropertyDefaultInputDevice` and `kAudioHardwarePropertyDefaultOutputDevice` (`AudioDeviceID`).
     - **Mic Mute Read/Write with Volume Fallback:**
       1. Check `AudioObjectHasProperty` / `AudioObjectIsPropertySettable` for `kAudioDevicePropertyMute` on `kAudioObjectPropertyScopeInput` (master element `0`, falling back to channel `1`).
       2. If mute property is settable, read/write `UInt32` (`1` = muted, `0` = unmuted).
       3. Some USB mics/virtual audio drivers lack hardware `kAudioDevicePropertyMute`. Fallback: read `kAudioDevicePropertyVolumeScalar` (`Float32` on input scope), store `savedVolumeBeforeFallbackMute`, and set volume to `0.0` (restoring `savedVolumeBeforeFallbackMute` on unmute).
     - **Live Property Listeners:** Register `AudioObjectAddPropertyListenerBlock` on `kAudioObjectSystemObject` for `kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultInputDevice`, `kAudioHardwarePropertyDefaultOutputDevice`, and on the active input device for `kAudioDevicePropertyMute` — hopping updates back to `@MainActor`.
3. **State Safety Invariant (Never Leave Mic Stuck Muted):**
   - Track whether Toolbox initiated a transient typing mute (and any fallback `savedVolumeBeforeFallbackMute`).
   - Whenever `CallControlsModule.stop()`, `autoMuteWhileTyping = false`, default input device changes, or `AppDelegate.applicationWillTerminate(_:)` runs, immediately cancel any pending unmute timer and restore any active typing mute (or fallback saved volume) before releasing listeners.
4. **Typing Mic Guard (`TypingMicGuard`):**
   - Passive **listen-only** `CGEvent.tapCreate(..., options: .listenOnly, eventsOfInterest: mask(keyDown), ...)` on a dedicated background `Thread` + `CFRunLoopRun()` (`app.toolbox.typing-mic-guard`), active **only** when `config.enabled && appEnabled && config.autoMuteWhileTyping && AXIsProcessTrusted()`.
   - Because `.listenOnly` does not modify or delay events, it introduces zero typing lag.
   - **Keystroke Filtering:** Always ignore the configured `micShortcut`, `videoShortcut`, `osMuteShortcut`, `cycleOutputShortcut`, Toolbox's `0x544C4258`-tagged synthetic events, and `⌘`/`⌃` command chords so toggling call hotkeys never trips the typing debouncer.
   - **State Machine:**
     - `isManuallyMuted: Bool` (synced with external CoreAudio mute changes when not typing-muted).
     - `isTypingMuted: Bool` + `unmuteWorkItem: DispatchWorkItem?`.
     - On filtered `keyDown`:
       - If `isManuallyMuted`: do nothing.
       - If `!isTypingMuted`: set `isTypingMuted = true`, mute mic via `CoreAudioController`.
       - Reset `unmuteWorkItem` to fire after `typingUnmuteDelayMs` (default `450 ms`).
     - When `unmuteWorkItem` fires:
       - If `isTypingMuted && !isManuallyMuted`, unmute mic and set `isTypingMuted = false`.

### Configuration (`CallControlsConfig`)
```swift
enum CallOverrideScope: String, Codable, CaseIterable, Sendable {
    case activeCallAppOnly = "active_call_app_only"
    case activeOrRunningBackground = "active_or_running_background"
}

struct CallAppShortcutMapping: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var appName: String
    var bundleIdentifier: String
    var enabled: Bool = true
    var micShortcut: ShortcutSpec = .none
    var videoShortcut: ShortcutSpec = .none
    var requiredWindowTitleSubstring: String? = nil
    var allowBriefFocusRestore: Bool = false
}

struct CallControlsConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var micShortcut: ShortcutSpec = ShortcutSpec(key: "m", modifiers: [.control, .option, .command])
    var videoShortcut: ShortcutSpec = ShortcutSpec(key: "v", modifiers: [.control, .option, .command])
    var osMuteShortcut: ShortcutSpec = .none
    var cycleOutputShortcut: ShortcutSpec = .none
    var overrideScope: CallOverrideScope = .everywhere
    var syncHardwareMuteWithAppMicToggle: Bool = false
    var autoMuteWhileTyping: Bool = false
    var typingUnmuteDelayMs: Int = 450
    var showFloatingMicIndicator: Bool = true
    var showVideoInFloatingIndicator: Bool = true
    var showFloatingPillOnlyDuringCalls: Bool = true
    var showToasts: Bool = true
    var favoriteOutputUIDs: [String] = []
    var favoriteInputUIDs: [String] = []
    var appShortcutMappings: [CallAppShortcutMapping] = CallAppShortcutMapping.defaults
}
```
- `ToolboxConfig`: `var callControls: CallControlsConfig = CallControlsConfig()` (migrates legacy `audioGuard` JSON key seamlessly).

### Verification & Self-Tests
- **CoreAudio enumeration resilience (`SelfTestRunner`):** Invoke `CoreAudioController.listDevices()` and verify it completes without crashing even on headless/CI Macs with zero virtual/physical audio devices, properly separating input vs output channel counts.
- **CallShortcutRemapper & preset resolution tests (`SelfTestRunner`):**
  1. Codable round-trip, legacy `audioGuard` migration, and default preset coverage (`Microsoft Teams`, `Zoom`, `Slack`, `Google Meet`, `Discord`, `FaceTime`).
  2. Toggled-off apps are never matched; toggled-on apps resolve accurately.
  3. `Everywhere` vs `Active Call App Only` routing, same-shortcut pass-through, window-title `"Meet"` gate, and `0x544C4258` recursion guard.
- **TypingMicGuard state machine tests (`SelfTestRunner`):** Verify pure `TypingMicStateMachine` transitions, manual-mute precedence, and `forceStopAndRestore()`.
- **Developer Simulation & Visual Snapshots (`SelfTestRunner`, `SnapshotRunner`):** Verify `CallControlsModule` developer presets, routing dry-run, simulated mic/video actions, and render `module_call_controls.png`, `call_controls_floating_pill.png`, and `developer_call_controls.png`.

### Edge Cases & Pitfalls
- **Infinite event-tap recursion:** Always tag synthetic remapped `CGEvent`s via `event.setIntegerValueField(.eventSourceUserData, value: 0x544C4258)` and immediately pass through any event carrying that tag in both `CallShortcutRemapper` and `TypingMicGuard`. (Especially critical when user's custom shortcut shares keys with another app's native shortcut!)
- **Bluetooth HFP / AirPods profile delay:** Switching to AirPods mic (`input`) causes macOS to switch Bluetooth codecs (AAC → HFP); CoreAudio fires asynchronous `kAudioHardwarePropertyDevices` / default-device callbacks while the hardware settles. Guard against stale `AudioDeviceID` values by keying user favorites on `deviceUID` (`CFString`) rather than transient `AudioDeviceID`.
- **Browser false-positives on `⌘ D` / `⌘ E`:** Never send Google Meet shortcuts (`⌘ D` Bookmark Page, `⌘ E` Search/Select) to Chrome/Arc/Safari unless a window title containing `"Meet"` is confirmed, avoiding accidental bookmark popups while browsing!
- **Modifier bleed during shortcut relay:** When the user presses e.g. `⌘ ⇧ Space` to trigger Teams' `⌘ ⇧ M` (or `⌃ ⌥ ⌘ V` for `⌘ ⇧ V`), clear/set the target `CGEventFlags` explicitly on the synthesized `CGEvent` rather than inheriting the HID system state flags.
- **No `NSMicrophoneUsageDescription` capture needed:** Querying `CoreAudio` device properties (`kAudioDevicePropertyMute`, `kAudioDevicePropertyVolumeScalar`, `kAudioHardwarePropertyDefaultInputDevice`) does **not** open an `AVAudioEngine` / `AudioUnit` recording stream, so it does not trigger the orange macOS microphone-in-use dot! Keep it strictly at the CoreAudio HAL property layer and never instantiate an audio input IOProc.
