# Call Controls: AirPods & Bluetooth Mic Lock — Enhancement Spec

> **Status:** Planned · **Target Module:** `Modules/CallControls/` (`call_controls`) · **Base Spec:** [call_controls.md](call_controls.md) · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Whenever macOS or a call/browser app activates the microphone on AirPods or Bluetooth headphones, macOS switches the headset from high-quality stereo (`A2DP`) to the low-bitrate mono Hands-Free Profile (`HFP`), making music, videos, and call voices sound tinny and muffled. **AirPods & Bluetooth Mic Lock** extends `CallControls` with a zero-permission CoreAudio guard that keeps the system default input locked to a non-Bluetooth microphone (such as a USB mic or the MacBook's built-in mic) so Bluetooth headphones stay in high-quality stereo.

### User Flows & UX
- **Automatic Input Revert:**
  - When `preventBluetoothMicSwitch` is enabled and macOS switches the default audio input device to a Bluetooth device (`AudioTransportType.bluetooth`), Toolbox automatically reverts `kAudioHardwarePropertyDefaultInputDevice` to the user's preferred non-Bluetooth microphone (or `Auto: USB → Built-in`).
  - Shows an optional subtle `HUDToast` (`"Kept AirPods in stereo — mic set to MacBook Pro Microphone"`).
- **1-Click Temporary Override:**
  - In **Menu Bar → Call Controls** and **Call Controls Settings**, users can click **"Allow Bluetooth Mic Until Disconnect"** (e.g., when walking away from their desk) to temporarily pause reverting for the currently connected Bluetooth device; the override clears automatically when that device disconnects.
- **Settings View Additions (`CallControlsSettingsView.swift`):**
  - Add a new `FeatureSection("BLUETOOTH AUDIO QUALITY", subtitle: "Prevent AirPods and Bluetooth headsets from dropping into low-quality call audio.")` using `SettingRow`, `Divider()`, and `.pointerCursor()`:
    - `Keep Bluetooth headphones in high-quality stereo` toggle (`preventBluetoothMicSwitch`).
    - `Fallback microphone` picker (`Auto (USB → Built-in)` or any connected non-Bluetooth input `deviceUID`).
    - `Show toast when reverting mic` toggle (`showBluetoothMicLockToast`).
    - Live status row + **Allow Until Disconnect** button when a Bluetooth headset is connected, plus a concise note reminding users to keep Zoom/Teams mic set to *"Same as System"* if an app overrides macOS defaults internally.

### Files to Create & Modify
- **Create:** `Sources/Toolbox/Modules/CallControls/BluetoothMicLockController.swift`
- **Modify:** `Sources/Toolbox/Modules/CallControls/CallControlsModule.swift` (wire `BluetoothMicLockController` into `start()`, `stop()`, `reload(with:)`, and device-change callbacks)
- **Modify:** `Sources/Toolbox/Modules/CallControls/CallControlsSettingsView.swift` (add `BLUETOOTH AUDIO QUALITY` section)
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
4. **Cross-Feature Sync:**
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
- **Backward-compatible config (`SelfTestRunner`):** Decode legacy `CallControlsConfig` JSON without the 3 new keys and assert safe defaults (`false`, `nil`, `true`).

### Edge Cases & Pitfalls
- **Desktop Macs without built-in mics (Mac mini / Mac Studio):** Returning `nil` when no non-Bluetooth input exists prevents breaking calls when AirPods are the sole microphone.
- **Clamshell mode on MacBooks:** Built-in mic availability can change on lid close; always re-evaluate against live `CoreAudioController.listDevices()`.
- **App-internal mic selection:** Apps like Zoom or Teams can open a specific input device directly without changing the macOS system default; surface a clear hint in Settings to keep app mic set to *"Same as System"*.
- **Bluetooth disconnect/reconnect clearing temporary bypass:** Clear `temporarilyBypassedBluetoothUID` automatically whenever `kAudioHardwarePropertyDevices` reports that device disconnected.
- **Explicit UI intent:** If the user manually selects a Bluetooth microphone inside Toolbox's own **Call Controls → Audio Devices** list, automatically arm `temporarilyBypassedBluetoothUID` for that device until disconnect so Toolbox never fights the user's explicit choice.
- **Disabled / paused state:** When `preventBluetoothMicSwitch == false`, `CallControlsConfig.enabled == false`, or `appEnabled == false`, clear any pending debounce work items immediately.
