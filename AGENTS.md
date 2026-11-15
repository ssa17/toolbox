# Repository Guide (`AGENTS.md`)

Instructions and conventions for human contributors and AI coding agents working on **Toolbox** (`/Users/syed/workspace/apps/toolbox`).

## Architecture & File Organization

- **`Sources/Toolbox/ToolboxApp.swift`**: `@main` entry point (`ToolboxMain`), `--version`, `--self-test`, `--snapshot-ui`, single-instance guard, and `AppDelegate`.
- **`Sources/Toolbox/Core/`**: Cross-cutting services (`ConfigManager`, `ModuleRegistry`, `ToolboxModule` protocol, `PermissionsManager`, `HotKeyManager`, `UpdateManager`, `SelfTestRunner`, `SnapshotRunner`).
- **`Sources/Toolbox/Modules/<Feature>/`**: Each feature is isolated in its own subdirectory, separating background runtime logic (`*Module.swift`) from SwiftUI views (`*SettingsView.swift`, `*PopoverView.swift`). Keep runtime and UI cleanly separated when modifying or adding features.
- **`Sources/Toolbox/UI/`**: Shared shell chrome, navigation, dashboard, general settings, menu bar controller, JSON config editor, and design primitives in `Theme.swift`.

## UI & UX Conventions

- **Design System (`UI/Theme.swift`)**:
  - Group settings into calm, clearly separated `FeatureSection("TITLE", subtitle: ...)` blocks using `SettingRow` and `Divider()` between rows.
  - Apply `.pointerCursor()` to every interactive element (`Button`, `Toggle`, `Picker`, `Stepper`, `Menu`, clickable cards, popover rows) so hover feedback works consistently across windows and popovers.
- **Navigation (`UI/MainWindowController.swift`)**:
  - The sidebar toggle (`sidebar.left`) stays fixed in the top-left window toolbar right beside the traffic lights.
  - Subpages show a single `< Back to Dashboard` control and retain the current page when switching away and reopening from the Dock.
- **Feature Detail Container (`UI/ModuleDetailViews.swift`)**:
  - Automatically renders the module header toggle, collapsed-by-default **About This Feature** disclosure header, optional Accessibility permission banner, and `module.makeSettingsView()`.

## Toolchain & macOS Platform Constraints

- **Swift / Xcode CLT Constraints**: Builds may run under Apple CommandLineTools without full Xcode (`SwiftUIMacros` / `XCTest.framework` unavailable):
  - **Do not use `@Observable` macro** in SwiftUI views—use `ObservableObject` with `@Published` and `@ObservedObject`.
  - **Do not import `XCTest`**—add all automated assertions to `SelfTestRunner.swift` and run `./build/Toolbox.app/Contents/MacOS/Toolbox --self-test`.
- **Non-activating Popovers (`Modules/Clipboard/ClipboardModule.swift`, `Modules/PortKiller/PortKillerModule.swift`)**:
  - Keep `hidesOnDeactivate = false` and `acceptsMouseMovedEvents = true` on `.nonactivatingPanel` popovers, and pair `NSEvent.addGlobalMonitorForEvents` with `NSEvent.addLocalMonitorForEvents` so outside clicks dismiss popovers both inside other apps and inside Toolbox's own windows.
  - Host popover SwiftUI views in `PointerCursorHostingView` (`UI/Theme.swift`) rather than raw `NSHostingView` so AppKit `cursorUpdate` and SwiftUI `layout()` passes don't drop `.pointerCursor()` back to `.arrow`. Keep hover tooltips in a separate `ignoresMouseEvents = true` child `NSPanel` instead of the popover's SwiftUI `ZStack` so tooltip show/hide never mutates the popover view hierarchy or flashes the cursor.
- **Scroll Inversion (`Modules/ScrollDirection/ScrollInversionTap.swift`)**:
  - Run the session-level `CGEventTap` for `scrollWheel` on a dedicated background queue + run loop (never the main run loop), keep the handler side-effect free, and re-arm on `tapDisabledByTimeout`/`tapDisabledByUserInput`.
  - Classify scroll events with `kCGScrollWheelEventIsContinuous`: non-zero = pixel-based (trackpad / high-resolution mice), zero = line-based (classic mouse wheels). The line delta fields are the *master*: writing one re-derives the pixel and fixed-point mirrors, so negate mirrors first and the line fields last; on pixel-based events never write the line fields (it would destroy the high-resolution value). Full write-up: `docs/scroll-direction.md`.
- **Live Window Stack (`Modules/DockMinimize/DockMinimizeModule.swift`)**:
  - Query live z-order via `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` rather than relying only on async workspace notifications, and transfer focus using `NSApp.yieldActivation(to:)` + `kAXFrontmostAttribute` + `activate()`.

## Release & Changelog Rules (Invariants)

1. **Keep release history:** `fastlane release` creates a GitHub release (`v<version>`); never delete old releases or tags (the GitHub Releases page is the public history). `releases/appcast.xml` carrying only the latest entry is intentional and separate.
2. **Log user-visible changes (`.agents/skills/changelog/SKILL.md`):** Every user-visible change gets a bullet in `CHANGELOG.md` under `## [Unreleased]` at commit time (in the same commit), and pending entries are summarized before `fastlane release` so the Sparkle "what's new" dialog stays concise.
3. **Never advertise an update that isn't strictly newer:** `UpdateManager` compares versions via `UpdateManager.isNewerVersion` before setting `pendingUpdateVersion`, and all update indicators (sidebar badge, dashboard banner, status bar menu button, Settings card) read from that guarded property.
4. **Reference docs:** See [`docs/feature-roadmap.md`](docs/feature-roadmap.md) (upcoming module specs & rollout plan), [`docs/distribution-guide.md`](docs/distribution-guide.md) (release pipeline & release notes), [`docs/testing.md`](docs/testing.md) (test & snapshot loop), [`docs/scroll-direction.md`](docs/scroll-direction.md) (scroll event tap details), and [`.agents/skills/changelog/SKILL.md`](.agents/skills/changelog/SKILL.md) (commit/release changelog skill).

## Build, Signing, Notarization & Testing

See **[`docs/testing.md`](docs/testing.md)** for the full iterative debugging, isolated configuration (`TOOLBOX_CONFIG_DIR`, `--self-test`), and visual UI snapshot (`--snapshot-ui`) workflow. Always verify changes before finishing:

1. Iterate quickly with debug builds & visual snapshots:
   ```bash
   ./scripts/build-app.sh --fast
   ./build/Toolbox.app/Contents/MacOS/Toolbox --self-test
   ./build/Toolbox.app/Contents/MacOS/Toolbox --snapshot-ui .work/snapshots
   ```
2. Final release build & notarization (requires `Developer ID Application` cert and `notary-profile` keychain profile):
   ```bash
   pkill -x Toolbox 2>/dev/null || true
   ./scripts/build-app.sh --notarize
   ```
3. Run built-in tests and Gatekeeper check:
   ```bash
   ./build/Toolbox.app/Contents/MacOS/Toolbox --self-test
   spctl --assess --type execute --verbose ./build/Toolbox.app
   ```
4. Relaunch and verify process:
   ```bash
   open ./build/Toolbox.app
   pgrep -l Toolbox
   ```
