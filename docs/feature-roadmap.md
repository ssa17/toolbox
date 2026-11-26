# Toolbox Feature Roadmap

This document is the **parent index** for **all** Toolbox modules: it tracks **Planned** modules and enhancements in **§1**, maintains a complete **Done (Shipped)** reference table (including both foundational Core modules and all shipped Roadmap modules) in **§2**, and defines the shared implementation checklist every module must follow in **§3**.

The **detailed implementation spec for each feature** — user flows, file lists, module metadata, macOS API design, configuration schemas, self-test plans, and edge cases — lives in its own file under [`docs/feature-specs/`](feature-specs/), linked in the **Spec** columns below. For `Done` features, shipped code is the source of truth and the spec remains the design record; `Planned` features are implemented from their spec.

**Quick Navigation:** [Planned Modules](#planned-modules) · [Planned Enhancements](#planned-enhancements-to-shipped-modules) · [Done (Shipped)](#2-done-shipped-modules-reference) · [Shared Checklist](#3-shared-implementation-checklist-required-for-every-module) · [Backlog](#4-backlog-unscheduled-ideas)

---

## 1. Planned Features & Enhancements

### Planned Modules

Ordered from zero-permission, self-contained utilities to modules that interact with Screen Capture, `CGEventTap` input interception, and Accessibility:

| Feature | Module ID | Category | Default Shortcut | Permissions Needed | Key macOS Frameworks | Spec |
|---|---|---|---|---|---|---|
| **Color Picker & Swatch History** | `color_picker` | Developer Tools | `⌃ ⌥ ⌘ E` | None | `AppKit` (`NSColorSampler`, `NSColorSpace`) | [`color_picker.md`](feature-specs/color_picker.md) |
| **Dev Converter & Scratchpad** | `dev_tools` | Developer Tools | `⌃ ⌥ ⌘ B` | None | `Foundation`, `CryptoKit` | [`dev_tools.md`](feature-specs/dev_tools.md) |
| **Floating File Drop Shelf** | `drop_shelf` | Clipboard & Text | `⌃ ⌥ ⌘ D` *(+ drag shake)* | None | `AppKit` (`NSPanel`, `NSDraggingDestination`, `NSFilePromiseReceiver`), `UniformTypeIdentifiers` | [`drop_shelf.md`](feature-specs/drop_shelf.md) |
| **Local Image Compressor & Cropper** | `image_compressor` | Clipboard & Text | `⌃ ⌥ ⌘ I` | None | `ImageIO`, `CoreImage`, `AppKit`, `UniformTypeIdentifiers` | [`image_compressor.md`](feature-specs/image_compressor.md) |
| **Meeting Shield (Presentation Mode)** | `meeting_shield` | System & Power | `⌃ ⌥ ⌘ S` | None *(optional Focus Shortcuts)* | `AppKit`, `IOKit`, `Foundation` | [`meeting_shield.md`](feature-specs/meeting_shield.md) |
| **Quick Screenshot** | `quick_screenshot` | Clipboard & Text | `⌃ ⌥ ⌘ 5` | Screen Recording (OS-managed via `screencapture`) | `AppKit`, `CoreGraphics`, `Vision` (optional OCR) | [`quick_screenshot.md`](feature-specs/quick_screenshot.md) |
| **Keyboard Shortcuts Hub & Caps Lock Hyper Key** | `hyper_key` *(Sidebar: Keyboard Shortcuts)* | Commands & Shortcuts | Hold `Caps Lock` (`⌃ ⌥ ⌘` or `⌃ ⌥ ⇧ ⌘`); Tap `Caps Lock` *(opt-in)* | None *(Shortcuts Hub)*; Accessibility & Input Monitoring *(required for Caps Lock Hyper Key)* | `IOKit` (`IOHIDServiceClientSetProperty`, `IOHIDSetModifierLockState`), `CoreGraphics`, `AppKit`, `Carbon` | [`keyboard_shortcuts_hub.md`](feature-specs/keyboard_shortcuts_hub.md) |

### Planned Enhancements to Shipped Modules

*No pending enhancements. Clipboard Image History has shipped and is recorded in the Done table below.*

*All default shortcuts across all shipped and planned modules are verified collision-free (`⌃ ⌥ ⌘ C` is reserved by `WindowSnapper` Center, so `ColorPicker` uses `⌃ ⌥ ⌘ E`).*

---

## 2. Done (Shipped Modules Reference)

Complete reference of all shipped modules in `Sources/Toolbox/Modules/` (foundational Core modules + shipped Roadmap modules):

| Feature | Module ID | Origin | Category | Default Shortcut | Permissions Needed | Key macOS Frameworks | Docs / Spec |
|---|---|---|---|---|---|---|---|
| **Dock Click to Minimize** | `dock_minimize` | Core | Window & Dock | None *(Dock click)* | Accessibility (required) | `ApplicationServices` (AX), `CoreGraphics`, `AppKit` | [`Modules/DockMinimize/`](../Sources/Toolbox/Modules/DockMinimize/) |
| **Clipboard History** | `clipboard` | Core | Clipboard & Text | `⌥ ⌘ V` | None *(optional Accessibility for auto-paste)* | `AppKit`, `Carbon`, `CryptoKit`, `ImageIO` | [`Modules/Clipboard/`](../Sources/Toolbox/Modules/Clipboard/) · [`clipboard_image_history.md`](feature-specs/clipboard_image_history.md) |
| **Keep Awake** | `keep_awake` | Core | System & Power | `⌥ ⌘ K` | None | `IOKit` (`IOPMAssertion`), `CoreGraphics`, `AppKit` | [`Modules/KeepAwake/`](../Sources/Toolbox/Modules/KeepAwake/) |
| **Custom Commands** | `custom_commands` | Core | Commands & Shortcuts | User-defined *(default presets: `⌥ ⌘ T`, `⇧ ⌥ ⌘ I`, `⇧ ⌥ ⌘ D`)* | None *(optional Accessibility for snippet auto-paste)* | `AppKit`, `Carbon`, `Foundation` | [`Modules/CustomCommands/`](../Sources/Toolbox/Modules/CustomCommands/) |
| **Scroll Direction** | `scroll_direction` | Core | System & Power | None *(Background `CGEventTap`)* | Accessibility (required) | `CoreGraphics` (`CGEventTap`), `AppKit` | [`scroll-direction.md`](scroll-direction.md) · [`Modules/ScrollDirection/`](../Sources/Toolbox/Modules/ScrollDirection/) |
| **Localhost Port Killer** | `port_killer` | Roadmap | Developer Tools | `⌃ ⌥ ⌘ P` | None | `Foundation`, `Darwin` (`libproc`), `Network` (tests) | [`port_killer.md`](feature-specs/port_killer.md) |
| **Screen OCR (Text Grabber)** | `screen_ocr` | Roadmap | Developer Tools | `⇧ ⌘ 0` | Screen Recording (OS-managed via `screencapture`) | `Vision`, `CoreGraphics`, `AppKit` | [`screen_ocr.md`](feature-specs/screen_ocr.md) |
| **Keyboard & Trackpad Clean Lock** | `clean_lock` | Roadmap | System & Power | None *(Button / Menu Bar only)* | Accessibility (required) | `CoreGraphics` (`CGEventTap`), `AppKit` | [`clean_lock.md`](feature-specs/clean_lock.md) |
| **Call Controls** *(incl. AirPods & Bluetooth Mic Lock)* | `call_controls` | Roadmap | System & Power | `⌃ ⌥ ⌘ M` (Mic) & `⌃ ⌥ ⌘ V` (Video), customizable per user | Accessibility (optional: Unified Call Keybind Override & Auto-Mute While Typing) | `CoreAudio`, `AudioToolbox`, `CoreMediaIO`, `CoreGraphics`, `ApplicationServices` | [`call_controls.md`](feature-specs/call_controls.md) · [`call_controls_bluetooth_mic_lock.md`](feature-specs/call_controls_bluetooth_mic_lock.md) |
| **Window Snapper** | `window_snapper` | Roadmap | Window & Dock | `⌃ ⌥ ⌘ ←/→/↑/↓` (plus halves, thirds, quarters, restore pre-snap size, and profile shortcuts) | Accessibility (required) | `ApplicationServices` (AX), `CoreGraphics`, `AppKit`, `Carbon` | [`window_snapper.md`](feature-specs/window_snapper.md) |
| **Finder Enhancer** | `finder_enhancer` | Roadmap | System & Power | None *(Finder-scoped `⌘ X`/`⌘ V`/`Return`/`F2` + auto-quit)* | Accessibility (required) | `CoreGraphics` (`CGEventTap`), `ApplicationServices` (AX), `AppKit` | [`finder_enhancer.md`](feature-specs/finder_enhancer.md) |
| **Window Switcher (`Alt+Tab`)** | `window_switcher` | Roadmap | Window & Dock | `⌥ Tab` / `⌥ ⇧ Tab` *(opt-in)* | Accessibility (required); Screen Recording (optional, for thumbnails) | `ApplicationServices` (AX), `CoreGraphics`, `ScreenCaptureKit` (optional), `AppKit` | [`window_switcher.md`](feature-specs/window_switcher.md) |

---

## 3. Shared Implementation Checklist (Required for Every Module)

Follow these repo invariants (see [AGENTS.md](../AGENTS.md) and [EXTENDING.md](../EXTENDING.md)) whenever implementing any module from this roadmap:

1. **Module Isolation (`Sources/Toolbox/Modules/<Feature>/`)**
   - Separate pure runtime/engine logic (`*Module.swift` + helper engine/tap/scanner files) from SwiftUI views (`*SettingsView.swift`, and `*PopoverView.swift` when the module has a floating HUD/popover).
   - **Apple CLT Constraint:** Do **not** use the `@Observable` macro or import `XCTest`. Use `ObservableObject`, `@Published`, and `@ObservedObject`.
   - Run any `CGEventTap` or blocking I/O on a dedicated background queue and run loop (never the main run loop), keep callbacks side-effect free, and re-arm taps on `tapDisabledByTimeout` / `tapDisabledByUserInput`.
2. **Protocol & Category (`Sources/Toolbox/Core/ToolboxModule.swift`)**
   - Reuse an existing `ModuleCategory` (`.windowAndDock`, `.productivity`, `.developer`, `.system`, or `.automation`) unless a genuinely new category is needed.
   - Conform to `ToolboxModule` with complete `id`, `name`, `tagline`, `aboutSummary`, `featureTips`, `symbolName`, `accentColor`, `category`, `requiresAccessibility`, `accessibilityReason`, `supportsMenuBar`, `supportsEnableToggle`, `isRunning`, `isEnabled(in:)`, `setEnabled(_:in:)`, `statusText(in:accessibilityGranted:)`, `shortcutText(in:)`, `start()`, `stop()`, `reload(with:)`, and `makeSettingsView()`.
3. **Configuration & Migration (`Sources/Toolbox/Core/ConfigManager.swift`)**
   - Define a dedicated `<Feature>Config: Codable, Equatable, Sendable` struct with safe defaults (`enabled: Bool = false`) and a lenient `init(from decoder: Decoder)` using `decodeIfPresent(...) ?? default` so older config files migrate seamlessly.
   - Add the property to `ToolboxConfig`, bump `schemaVersion`, and append the module's `id` to `GeneralConfig.defaultMenuBarModuleOrder`.
   - Use `ShortcutSpec` for global shortcuts and register/unregister via `HotKeyManager.shared` using unique `"<module_id>.<action>"` keys.
4. **Shortcut Conflict Prevention (`Sources/Toolbox/Core/HotKeyManager.swift`)**
   - **Conflict-free defaults:** Default global shortcuts to 3-modifier chords (`⌃ ⌥ ⌘ <Key>`) or `.none` so enabling a module never breaks common 2-modifier `⌥ ⌘` / `⌃ ⌘` shortcuts in macOS, Finder, browsers, or IDEs.
   - **Unregister when inactive:** Always call `HotKeyManager.shared.unregister(...)` in `stop()` and whenever `enabled == false` or `config.general.appEnabled == false` so disabled modules never intercept keystrokes.
   - **In-app collision detection:** Wire every new module's shortcut(s) into `HotKeyManager.inAppConflictDescription(for:excludingSourceID:in:)` and `HotKeyManager.clearConflictingShortcuts(matching:excludingSourceID:in:)` (and `ShortcutCatalog` once [`keyboard_shortcuts_hub.md`](feature-specs/keyboard_shortcuts_hub.md) ships) so `ShortcutRecorderView` and the Keyboard Shortcuts Hub surface collisions and support one-click **Assign Here**.
   - **Common system/app warnings:** Verify `HotKeyManager.wellKnownSystemShortcuts` covers any relevant macOS or common app chords near the module's shortcuts so users see a gentle warning if they manually pick one.
5. **Module Registry, Permissions & Lifecycle (`ModuleRegistry.swift`, `PermissionsManager.swift`, `ToolboxApp.swift`)**
   - Instantiate and append the module to `ModuleRegistry.shared.modules`.
   - Ensure `stop()` tears down all timers, monitors, panels, and event taps cleanly when the module is disabled or Toolbox is paused (`config.general.appEnabled == false`).
   - Keep permission handling non-blocking: modules with `requiresAccessibility = true` wait gracefully until permission is granted, and optional or OS-managed permissions degrade cleanly with clear status text.
   - If the module modifies persistent system state (such as event-swallowing taps, microphone mute, or sleep assertions), hook guaranteed cleanup into `AppDelegate.applicationWillTerminate(_:)`.
6. **UI, Popovers & Design System (`UI/Theme.swift`, `UI/ShortcutRecorderView.swift`, `UI/HUDToast.swift`)**
   - Build `*SettingsView.swift` using `FeatureSection("TITLE", subtitle: ...)` blocks, `SettingRow`, `Divider()`, and `ShortcutRecorderView` (never `ShortcutRecorderButton` — the view in `UI/ShortcutRecorderView.swift` is `ShortcutRecorderView`).
   - Apply `.pointerCursor()` to every interactive element (`Button`, `Toggle`, `Picker`, `Stepper`, `Menu`, clickable cards, popover rows).
   - For floating popovers (e.g., `dev_tools`, `drop_shelf`, `image_compressor`), mirror `ClipboardModule` / `PortKillerModule`: use `NSPanel` with `styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]`, `hidesOnDeactivate = false`, `acceptsMouseMovedEvents = true`, `level = .popUpMenu`, and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`; host SwiftUI views in `PointerCursorHostingView` (never raw `NSHostingView`); keep hover tooltips in a separate `ignoresMouseEvents = true` child `NSPanel`; and pair `NSEvent.addGlobalMonitorForEvents` + `NSEvent.addLocalMonitorForEvents` for outside-click dismissal (plus `Esc` to close).
7. **Build Frameworks (`Package.swift`)**
   - Link any newly required Apple frameworks in `Package.swift` under `linkerSettings`.
8. **Verification, Diagnostics & Release Hygiene (`SelfTestRunner.swift`, `SnapshotRunner.swift`, `CHANGELOG.md`)**
   - Add unit, config-migration, and lifecycle tests to `Sources/Toolbox/Core/SelfTestRunner.swift`, a view snapshot to `Sources/Toolbox/Core/SnapshotRunner.swift`, and health checks to `DeveloperHealthChecks.swift` if the module introduces runtime invariants worth validating.
   - Add a concise user-facing bullet under `## [Unreleased]` in `CHANGELOG.md` at commit time (per [`.agents/skills/changelog/SKILL.md`](../.agents/skills/changelog/SKILL.md)).
   - Follow the **Signing & TCC Permission Invariant** in [AGENTS.md](../AGENTS.md): never overwrite `./build/Toolbox.app` with an ad-hoc build (use `APP_BUNDLE=.work/Toolbox-dev.app ./scripts/build-app.sh --fast --allow-adhoc` when Keychain signing is unavailable).
   - Verify with:
     ```bash
     ./scripts/build-app.sh --fast
     ./build/Toolbox.app/Contents/MacOS/Toolbox --self-test
     ./build/Toolbox.app/Contents/MacOS/Toolbox --snapshot-ui .work/snapshots
     ```

---

## 4. Backlog (Unscheduled Ideas)

*(No pending backlog items — all candidates have been specced and promoted into §1 above.)*

To propose a new feature, draft a spec under `docs/feature-specs/<module_id>.md` (covering user flows, macOS APIs, config schema, self-test plan, and edge cases), list it here until scheduled, and promote it to §1 when ready for implementation.
