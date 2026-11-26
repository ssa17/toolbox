# Call Controls: AirPods & Bluetooth Mic Lock — Enhancement Spec

> **Status:** Shipped (schema v13) · **Target Module:** `Modules/CallControls/` (`call_controls`) · **Base Spec:** [call_controls.md](call_controls.md) · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Whenever macOS or a call/browser app activates the microphone on AirPods or Bluetooth headphones, macOS switches the headset from high-quality stereo (`A2DP`) to the low-bitrate mono Hands-Free Profile (`HFP`), making music, videos, and call voices sound tinny and muffled and enabling the headset's own sidetone ("hearing yourself"). **The two profiles are mutually exclusive**, so keeping stereo audio and using the headset microphone are not simultaneously possible - the UI presents this as a trade-off rather than a free upgrade. **AirPods & Bluetooth Mic Lock** extends `CallControls` with a zero-permission CoreAudio guard that keeps the system default input locked to a non-Bluetooth microphone (such as a USB mic or the MacBook's built-in mic) so Bluetooth headphones stay in high-quality stereo.

### User Flows & UX
- **Automatic Input Revert:**
  - When `preventBluetoothMicSwitch` is enabled and macOS switches the default audio input device to a Bluetooth device (`AudioTransportType.bluetooth`), Toolbox automatically reverts `kAudioHardwarePropertyDefaultInputDevice` to the user's preferred non-Bluetooth microphone (or `Auto: USB → Built-in`).
  - Shows an optional subtle `HUDToast` (`title: "AirPods Pro kept in stereo"`, `subtitle: "Apps now use MacBook Pro Microphone - not the headset mic"`).
- **1-Click Temporary Override:**
  - In **Menu Bar → Call Controls** and **Call Controls Settings**, users can click **"Allow Headset Mic"** / **"Use Headset Mic"** (e.g., when walking away from their desk) to temporarily pause reverting for the currently connected Bluetooth device; **"Back to Stereo"** clears it early, and the override clears automatically when that device disconnects.
- **Pinned-App Detection & Guidance:**
  - Some apps (notably Microsoft Teams, and Zoom once a device is picked) open the Bluetooth device *by UID*, ignoring the macOS default input. The guard cannot win there, so instead of failing silently Toolbox detects it and says so.
  - Detection reads `kAudioProcessPropertyDevices` (input scope) for every process object, so it knows *which* app captured *which* device.
  - When a process is capturing a Bluetooth input that is **not** the current system default, the Settings status card and the Menu Bar show an explicit warning naming the app plus the fix: *set its microphone to "Same as System"*. Each app is announced once per session via `HUDToast` and logged to `DeveloperEventLog`.
  - Assistants and audio daemons (Siri, dictation/CoreSpeech, controlcenter, avconferenced, mediaremoted, audiomxd, …) are excluded: they open the mic briefly and expose no per-app device setting, so warning about them would be noise with no fix behind it.

- **Settings View Additions (`CallControlsSettingsView.swift`):**
  - Add a new `FeatureSection("BLUETOOTH HEADPHONE AUDIO", subtitle: "Bluetooth can't carry stereo sound and a headset microphone at the same time - pick which one Toolbox protects.")` using `SettingRow`, `Divider()`, and `.pointerCursor()`:
    - `Use my Mac's microphone instead of the headset's` toggle (`preventBluetoothMicSwitch`) - deliberately named after the *trade-off* rather than a benefit, since the headset mic has to be given up to keep stereo. The subtitle states the A2DP/HFP constraint explicitly.
    - `Microphone to use instead` picker (`Auto (USB → Built-in)` or any connected non-Bluetooth input `deviceUID`).
    - `Confirm microphone switches with a toast` toggle (`showBluetoothMicLockToast`).
    - Live status row + **Allow Headset Mic** / **Back to Stereo** button when a Bluetooth headset is connected, plus a concise note explaining why the profiles are exclusive and reminding users to keep Zoom/Teams mic set to *"Same as System"* if an app overrides macOS defaults internally.

### Files to Create & Modify
- **Create:** `Sources/Toolbox/Modules/CallControls/BluetoothMicLockController.swift`
- **Modify:** `Sources/Toolbox/Modules/CallControls/CallControlsModule.swift` (wire `BluetoothMicLockController` into `start()`, `stop()`, `reload(with:)`, and device-change callbacks)
- **Modify:** `Sources/Toolbox/Modules/CallControls/CallControlsSettingsView.swift` (add `BLUETOOTH HEADPHONE AUDIO` section)
- **Modify:** `Sources/Toolbox/Core/ConfigManager.swift` (add 3 fields to `CallControlsConfig` with lenient `decodeIfPresent`)
- **Modify:** `Sources/Toolbox/Core/SelfTestRunner.swift` (add policy, loop-breaker, and config migration tests)

### Technical Design & macOS APIs
1. **Reuse `CoreAudioController`:**
   - Leverage existing `AudioTransportType.bluetooth` (`kAudioDeviceTransportTypeBluetooth`, `kAudioDeviceTransportTypeBluetoothLE`), `AudioDeviceInfo`, `CoreAudioController.listDevices()`, `setDefaultInputDevice(_:)`, and existing `kAudioHardwarePropertyDefaultInputDevice` / `kAudioHardwarePropertyDevices` listeners.
2. **Pure Policy Engine (`BluetoothMicLockPolicy`):**
   - Given `(currentDefaultInput: AudioDeviceInfo?, availableInputs: [AudioDeviceInfo], preferredFallbackUID: String?, lastNonBluetoothUID: String?, bypassedBluetoothUID: String?) -> AudioDeviceInfo?`:
     1. If `currentDefaultInput` is nil or `currentDefaultInput.transport != .bluetooth` → return `nil` (no revert needed).
     2. If `currentDefaultInput.uid == bypassedBluetoothUID` → return `nil` (user allowed temporary override).
     3. Filter `availableInputs` to non-Bluetooth physical inputs (`hasInput && transport != .bluetooth && transport != .virtual && transport != .aggregate`, falling back to virtual/aggregate only if no physical non-Bluetooth mic exists).
     4. Choose fallback in priority order:
        1. `preferredFallbackUID` (if currently connected)
        2. `lastNonBluetoothUID` (if currently connected)
        3. First `.usb` input
        4. First `.builtIn` input
        5. First remaining non-Bluetooth input
     5. If zero non-Bluetooth inputs exist (e.g., Mac mini / Mac Studio with no wired mic) → return `nil` so the user is never left without a working microphone.
3. **Anti-Thrash Loop Breaker & Debounce:**
   - Debounce input-change reactions by `150 ms` to avoid reacting mid-connection handshake.
   - Track revert timestamps in a `5 s` sliding window per Bluetooth `uid`: if `> 4` reverts occur within `5 s` (e.g., an app aggressively forces Bluetooth input in a tight loop), pause auto-revert for that `uid` for `15 s`, log to `DeveloperEventLog`, and surface a status warning instead of thrashing CoreAudio.
   - The pause schedules its own `DispatchWorkItem` re-evaluation for the moment `pausedUntil` elapses (cancelled by `invalidate()` / `clearBypass()` and whenever an evaluation succeeds). Without it, a guard whose headset is already the default input would never be woken by another CoreAudio event and would stay paused indefinitely.
4. **Pinned-App Detection (`CoreAudioController.activeInputProcessCaptures()` + `BluetoothMicLockPolicy.pinnedBluetoothMicBundleIDs`):**
   - Enumerate `kAudioHardwarePropertyProcessObjectList`, keep processes whose `kAudioProcessPropertyIsRunningInput` is non-zero, read `kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID`, and read `kAudioProcessPropertyDevices` **on the input scope** (the scope selects the input or output device list).
   - Map those device IDs onto `AudioDeviceInfo` and keep captures that touch a Bluetooth input which is *not* the current default. Capturing the default Bluetooth device is expected (`Allow Headset Mic`), not a hijack.
   - Friendly names resolve through `CallAppShortcutMapping` presets → running app → owning app of a helper process → bundle ID.
   - Re-evaluated whenever `refreshMicStreamActivity()` runs (process list / per-process input-state listeners), so it appears within the same event that started the capture.

5. **Cross-Feature Sync:**
   - After reverting the default input device, re-sync `CallControlsModule`'s active input mute state and `TypingMicGuard` listener.
   - Clear `temporarilyBypassedBluetoothUID` automatically whenever `kAudioHardwarePropertyDevices` reports that device disconnected.

### Configuration Additions (`CallControlsConfig`)
Add to `CallControlsConfig` in `Sources/Toolbox/Core/ConfigManager.swift` (with lenient `decodeIfPresent` defaults):
```swift
var preventBluetoothMicSwitch: Bool = false
var bluetoothMicLockFallbackUID: String? = nil
var showBluetoothMicLockToast: Bool = true
```

### Verification & Self-Tests
- **Policy selection (`SelfTestRunner`):**
  - Bluetooth default input reverts to `preferredFallbackUID` when connected; falls back to `.usb` then `.builtIn` if preferred USB mic is unplugged.
  - Zero non-Bluetooth inputs returns `nil` (never drops the user's only mic).
  - Temporary bypass UID suppresses revert until disconnect clears it.
- **Anti-thrash loop breaker (`SelfTestRunner`):** Simulate 5 rapid Bluetooth switches within `< 5 s` and assert the controller pauses reverting for `15 s`.
- **Pinned-app detection (`SelfTestRunner`):** a capture of the Bluetooth mic while the default is the built-in mic is reported; a capture of the fallback mic, of the default Bluetooth device, or a capture without a bundle ID is not; duplicates collapse; assistant/daemon bundle IDs are filtered out while Zoom/Chrome/Safari stay actionable; friendly-name resolution maps `us.zoom.xos` → Zoom and `com.microsoft.teams2.helper` → Microsoft Teams.
- **Backward-compatible config (`SelfTestRunner`):** Decode legacy `CallControlsConfig` JSON without the 3 new keys and assert safe defaults (`false`, `nil`, `true`).

### Edge Cases & Pitfalls
- **Desktop Macs without built-in mics (Mac mini / Mac Studio):** Returning `nil` when no non-Bluetooth input exists prevents breaking calls when AirPods are the sole microphone.
- **Clamshell mode on MacBooks:** Built-in mic availability can change on lid close; always re-evaluate against live `CoreAudioController.listDevices()`.
- **App-internal mic selection:** Apps like Zoom or Teams can open a specific input device directly without changing the macOS system default; those captures are detected and named in the UI, because no userland code can close another client's device (there is no per-client device ACL in CoreAudio, and a HAL plugin cannot block another client's IOProc).
- **Bluetooth disconnect/reconnect clearing temporary bypass:** Clear `temporarilyBypassedBluetoothUID` automatically whenever `kAudioHardwarePropertyDevices` reports that device disconnected.
- **Explicit UI intent:** If the user manually selects a Bluetooth microphone inside Toolbox's own **Call Controls → Audio Devices** list, automatically arm `temporarilyBypassedBluetoothUID` for that device until disconnect so Toolbox never fights the user's explicit choice.
- **Disabled / paused state:** When `preventBluetoothMicSwitch == false`, `CallControlsConfig.enabled == false`, or `appEnabled == false`, clear any pending debounce work items immediately.
