# Extending Toolbox

Toolbox is structured so both human developers and AI agents can add a new utility module cleanly in minutes without modifying existing features.

## Core Architecture

- **`Sources/Toolbox/Core/ToolboxModule.swift`**: Defines the `ToolboxModule` protocol (`id`, `name`, `tagline`, `aboutSummary`, `featureTips`, `start()`, `stop()`, `reload(with:)`, `makeSettingsView()`).
- **`Sources/Toolbox/Core/ModuleRegistry.swift`**: Holds every active module instance. The Dashboard grid, Sidebar list, and Menu Bar popover are all generated dynamically from `ModuleRegistry.shared.modules`.
- **`Sources/Toolbox/Core/ConfigManager.swift`**: Watches `~/.config/toolbox/config.json` and hot-reloads edits. `ToolboxConfig` includes `extensions: [String: JSONValue]` so new modules can persist arbitrary settings before/without editing top-level config structs.
- **`Sources/Toolbox/Core/HotKeyManager.swift`**: Register any `ShortcutSpec` globally via Carbon with automatic conflict reporting.
- **`Sources/Toolbox/Core/PermissionsManager.swift`**: Non-blocking Accessibility checker. Modules setting `requiresAccessibility = true` wait gracefully until permission is granted.
- **`Sources/Toolbox/UI/Theme.swift`**: Reusable `FeatureSection`, `SettingRow`, `SectionCard`, `StatusBadge`, `ShortcutPill`, and `.pointerCursor()` styling primitives.

## Adding a New Module

1. Create a folder `Sources/Toolbox/Modules/<YourFeature>/` containing:
   - `<YourFeature>Module.swift` conforming to `ToolboxModule` (handling lifecycle, hotkeys, and config read/write via a dedicated `ToolboxConfig` struct or `config.extensions["your_feature"]`).
   - `<YourFeature>SettingsView.swift` using `FeatureSection` and `SettingRow` blocks with `.pointerCursor()` on all interactive controls.
2. Instantiate and append it to `modules` in `Sources/Toolbox/Core/ModuleRegistry.swift`.
3. Add targeted unit/regression checks to `Sources/Toolbox/Core/SelfTestRunner.swift`.
4. Rebuild and verify:
   ```bash
   ./scripts/build-app.sh --notarize
   ./build/Toolbox.app/Contents/MacOS/Toolbox --self-test
   ```
