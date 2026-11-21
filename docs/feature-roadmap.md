# Toolbox Feature Roadmap

This document is the **parent index** for Toolbox feature planning: it tracks every shipped and planned feature in one overview table, fixes the rollout order, and carries the shared implementation checklist that every module must follow.

The **detailed implementation spec for each feature** — user flows, file lists, module metadata, macOS API design, configuration schemas, self-test plans, and edge cases — lives in its own file under [`docs/feature-specs/`](feature-specs/), linked in **§2 Feature Specs** below. Done features keep their full spec there as the design record (the shipped code remains the source of truth for behavior); planned features are implemented from their spec file.

---

## 1. Overview & Rollout Strategy

### Recommended Implementation Order

Features are ordered from zero-permission, self-contained utilities to modules that interact with Screen Capture, `CGEventTap` input interception, and CoreAudio HAL:

| # | Feature | Module ID | Category | Default Shortcut | Permissions Needed | Key macOS Frameworks | Status |
|---|---|---|---|---|---|---|---|
| 1 | **Localhost Port Killer** | `port_killer` | Developer Tools | `⌃ ⌥ ⌘ P` | None | `Foundation`, `Darwin` (`libproc`), `Network` (tests) | Done |
| 2 | **Color Picker & Swatch History** | `color_picker` | Developer Tools | `⌃ ⌥ ⌘ C` | None | `AppKit` (`NSColorSampler`, `NSColorSpace`) | Planned |
| 3 | **Dev Converter & Scratchpad** | `dev_tools` | Developer Tools | `⌃ ⌥ ⌘ B` | None | `Foundation`, `CryptoKit` | Planned |
| 4 | **Screen OCR (Text Grabber)** | `screen_ocr` | Developer Tools | `⇧ ⌘ 0` | Screen Recording (OS-managed via `screencapture`) | `Vision`, `CoreGraphics`, `AppKit` | Done |
| 5 | **Keyboard & Trackpad Clean Lock** | `clean_lock` | System & Power | None *(Button / Menu Bar only)* | Accessibility (required) | `CoreGraphics` (`CGEventTap`), `AppKit` | Done |
| 6 | **Call Controls** | `call_controls` | System & Power | `⌃ ⌥ ⌘ M` (Mic) & `⌃ ⌥ ⌘ V` (Video), customizable per user | Accessibility (optional: Unified Call Keybind Override & Auto-Mute While Typing) | `CoreAudio`, `AudioToolbox`, `CoreMediaIO`, `CoreGraphics`, `ApplicationServices` | Done |

---

### Shared Implementation Checklist (Required for Every Module)

Follow these repo invariants (see [AGENTS.md](../AGENTS.md) and [EXTENDING.md](../EXTENDING.md)) whenever implementing any module from this spec:

1. **Module Isolation (`Sources/Toolbox/Modules/<Feature>/`)**
   - Separate pure engine/runtime logic (`*Module.swift` + helper engine/tap/scanner files) from SwiftUI views (`*SettingsView.swift`, and `*PopoverView.swift` when the module has a floating HUD/popover).
   - **Apple CLT Constraint:** Do **not** use the `@Observable` macro or import `XCTest`. Use `ObservableObject`, `@Published`, and `@ObservedObject`.
2. **Protocol & Category (`Sources/Toolbox/Core/ToolboxModule.swift`)**
   - Add `case developer = "Developer Tools"` to `ModuleCategory` when implementing the first developer module (Feature 1).
   - Conform to `ToolboxModule` with complete `id`, `name`, `tagline`, `aboutSummary`, `featureTips`, `symbolName`, `accentColor`, `category`, `requiresAccessibility`, `accessibilityReason`, `isRunning`, `statusText`, `shortcutText`, `start()`, `stop()`, `reload(with:)`, and `makeSettingsView()`.
3. **Configuration (`Sources/Toolbox/Core/ConfigManager.swift`)**
   - Define a dedicated `<Feature>Config: Codable, Equatable, Sendable` struct with safe defaults (`enabled: Bool = false`) and a lenient `init(from decoder: Decoder)` using `decodeIfPresent(...) ?? default` so older config files migrate seamlessly.
   - Add the property to `ToolboxConfig` (bumping `schemaVersion` when adding a typed config struct) and append the module's `id` to `GeneralConfig.defaultMenuBarModuleOrder`.
   - Use `ShortcutSpec` for global shortcuts and register/unregister via `HotKeyManager.shared` using unique `"<module_id>.<action>"` keys.
4. **Shortcut Conflict Prevention (`Sources/Toolbox/Core/HotKeyManager.swift`)**
   - **Conflict-free defaults:** Default global shortcuts to 3-modifier chords (`⌃ ⌥ ⌘ <Key>`) or `.none` so enabling a module never breaks common 2-modifier `⌥ ⌘ <Key>` shortcuts in Finder, browsers, or IDEs (such as `⌥ ⌘ P` Path Bar, `⌥ ⌘ B` Bookmarks Bar, `⌥ ⌘ L` Downloads / Format Code, `⌥ ⌘ M` Minimize All, `⌥ ⌘ O` Bookmark Manager).
   - **Unregister when inactive:** Always call `HotKeyManager.shared.unregister(...)` in `stop()` and whenever `enabled == false` or `config.general.appEnabled == false` so disabled modules never intercept keystrokes.
   - **In-app collision detection:** Wire every new module's shortcut(s) into `HotKeyManager.inAppConflictDescription(for:excludingSourceID:in:)` and `HotKeyManager.clearConflictingShortcuts(matching:excludingSourceID:in:)` so `ShortcutRecorderView` surfaces collisions and supports one-click **Assign Here**.
   - **Common system/app warnings:** Expand `HotKeyManager.wellKnownSystemShortcuts` with well-known macOS/app `⌥ ⌘` chords (`⌥ ⌘ D`, `⌥ ⌘ M`, `⌥ ⌘ L`, `⌥ ⌘ P`, `⌥ ⌘ B`, `⌥ ⌘ I`, `⌥ ⌘ C`) so users see a gentle warning if they manually pick one.
5. **Module Registry & Lifecycle (`ModuleRegistry.swift`, `ToolboxApp.swift`)**
   - Instantiate and append the module to `ModuleRegistry.shared.modules`.
   - Ensure `stop()` tears down all timers, monitors, panels, and event taps cleanly when the module is disabled or Toolbox is paused (`config.general.appEnabled == false`).
   - If the module modifies persistent system state (event-swallowing taps or microphone mute), also hook cleanup into `AppDelegate.applicationWillTerminate(_:)`.
6. **UI & Design System (`UI/Theme.swift`, `UI/ShortcutRecorderView.swift`, `UI/HUDToast.swift`)**
   - Build `*SettingsView.swift` using `FeatureSection("TITLE", subtitle: ...)` blocks, `SettingRow`, `Divider()`, and `ShortcutRecorderView` (never `ShortcutRecorderButton` — the view in `UI/ShortcutRecorderView.swift` is `ShortcutRecorderView`).
   - Apply `.pointerCursor()` to every interactive element (`Button`, `Toggle`, `Picker`, `Stepper`, `Menu`, clickable cards, popover rows).
   - For floating popovers (Features 1 and 3), mirror `ClipboardModule`: use `NSPanel` with `styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]`, `hidesOnDeactivate = false`, `level = .popUpMenu`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`, and paired `NSEvent.addGlobalMonitorForEvents` + `NSEvent.addLocalMonitorForEvents` for outside-click dismissal (plus `Esc` to close).
7. **Build Frameworks (`Package.swift`)**
   - Link any newly required Apple frameworks (such as `Vision` for Feature 4 or `CoreAudio` / `AudioToolbox` for Feature 6) in `Package.swift` under `linkerSettings`.
8. **Verification (`SelfTestRunner.swift`, `SnapshotRunner.swift`, `CHANGELOG.md`)**
   - Add unit & lifecycle tests to `Sources/Toolbox/Core/SelfTestRunner.swift` and a view snapshot to `Sources/Toolbox/Core/SnapshotRunner.swift`.
   - Add a concise user-facing bullet under `## [Unreleased]` in `CHANGELOG.md` at commit time (per [`.agents/skills/changelog/SKILL.md`](../.agents/skills/changelog/SKILL.md)).
   - Verify with:
     ```bash
     ./scripts/build-app.sh --fast
     ./build/Toolbox.app/Contents/MacOS/Toolbox --self-test
     ./build/Toolbox.app/Contents/MacOS/Toolbox --snapshot-ui .work/snapshots
     ```

---

## 2. Feature Specs (detailed breakdowns)

Each feature's full detailed spec lives in its own file under [`docs/feature-specs/`](feature-specs/):

| # | Feature | Status | Detailed Spec |
|---|---|---|---|
| 1 | Localhost Port Killer | Done | [`feature-specs/port_killer.md`](feature-specs/port_killer.md) |
| 2 | Color Picker & Swatch History | Planned | [`feature-specs/color_picker.md`](feature-specs/color_picker.md) |
| 3 | Dev Converter & Scratchpad | Planned | [`feature-specs/dev_tools.md`](feature-specs/dev_tools.md) |
| 4 | Screen OCR (Text Grabber) | Done | [`feature-specs/screen_ocr.md`](feature-specs/screen_ocr.md) |
| 5 | Keyboard & Trackpad Clean Lock | Done | [`feature-specs/clean_lock.md`](feature-specs/clean_lock.md) |
| 6 | Call Controls | Done | [`feature-specs/call_controls.md`](feature-specs/call_controls.md) |

---

## 3. Backlog (spec draft, not yet in the rollout order)

- **Window Snapping** — interactive drag-to-zone snapping with 1:1 on-screen outline previews, keyboard placement, per-display divisions, and predefined workspace profiles that auto-set up apps and zones. [`feature-specs/window_snapping.md`](feature-specs/window_snapping.md) (implementation-ready design spec; not yet in the rollout order)
