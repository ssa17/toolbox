# Toolbox Feature Roadmap & Implementation Specs

This document is the canonical engineering specification for Toolbox's next 6 quality-of-life and developer utility modules. Each feature is designed to be implemented, tested, and shipped **one module at a time** cleanly inside Toolbox's existing modular architecture.

---

## 1. Overview & Rollout Strategy

### Recommended Implementation Order

Features are ordered from zero-permission, self-contained utilities to modules that interact with Screen Capture, `CGEventTap` input interception, and CoreAudio HAL:

| # | Feature | Module ID | Category | Default Shortcut | Permissions Needed | Key macOS Frameworks | Status |
|---|---|---|---|---|---|---|---|
| 1 | **Localhost Port Killer** | `port_killer` | Developer Tools | `⌃ ⌥ ⌘ P` | None | `Foundation`, `Darwin` (`libproc`), `Network` (tests) | Done |
| 2 | **Color Picker & Swatch History** | `color_picker` | Developer Tools | `⌃ ⌥ ⌘ C` | None | `AppKit` (`NSColorSampler`, `NSColorSpace`) | Planned |
| 3 | **Dev Converter & Scratchpad** | `dev_tools` | Developer Tools | `⌃ ⌥ ⌘ B` | None | `Foundation`, `CryptoKit` | Planned |
| 4 | **Screen OCR (Text Grabber)** | `screen_ocr` | Developer Tools | `⌃ ⌥ ⌘ O` | Screen Recording (OS-managed via `screencapture`) | `Vision`, `CoreGraphics`, `AppKit` | Done |
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

## 2. Feature 1: Localhost Port Killer (`Modules/PortKiller/`) — Done

### Purpose & User Value
Developers constantly hit `EADDRINUSE` when a dev server (`Vite`, `Next.js`, `Node`, `Python`, `Go`, `Docker`, `Postgres`, `Redis`) stays alive in the background. Instead of dropping to a terminal to run `lsof -i :3000` and `kill -9 <pid>`, **Port Killer** surfaces active listening TCP ports in a searchable floating popover (`⌃ ⌥ ⌘ P`) and settings dashboard with process name, PID, port, bind address, and working directory—and lets you stop or force-kill them in one click.

### User Flows & UX
- **Global Popover (`⌃ ⌥ ⌘ P`):** Opens near the cursor (like `ClipboardModule`) with an auto-focused search box (`3000`, `node`, `vite`, folder name, or PID), optional filter chips (`All` / `Dev Ports` / `Hide System`), and live rows sorted with Pinned/Favorite ports first, then ascending port number.
- **Row Actions:** Each row shows process icon/badge, process name + port pill (`:5173`), working folder basename (full path in tooltip/subtitle), PID, and bind host (`127.0.0.1`, `::1`, `*`).
  - **Stop (`SIGTERM`)** button attempts graceful termination and triggers an immediate re-scan after 600 ms.
  - **Force Kill (`SIGKILL`)** button (or `⌥`-click / secondary button) sends `SIGKILL` immediately for wedged processes.
  - **Copy Port / Copy PID / Reveal CWD in Finder** in a compact context menu.
- **Settings View (`PortKillerSettingsView.swift`):**
  - **Shortcut & Behavior** section: global popover shortcut (`ShortcutRecorderView`), auto-refresh interval (`3s` / `5s` / `10s` / `Manual` when settings/popover open), default kill signal (`SIGTERM` vs `SIGKILL`), "Hide macOS system daemons" toggle.
  - **Favorite Dev Ports** section: quick preset chips (`3000`, `3001`, `4000`, `5000`, `5173`, `5432`, `6379`, `8000`, `8080`, `8888`) + custom port add/remove.
  - **Live Listening Ports** section: full-width table inside settings with Refresh button, Search bar, and Stop/Kill controls.

### Files to Create
- `Sources/Toolbox/Modules/PortKiller/PortKillerModule.swift`
- `Sources/Toolbox/Modules/PortKiller/PortScanner.swift`
- `Sources/Toolbox/Modules/PortKiller/PortKillerSettingsView.swift`
- `Sources/Toolbox/Modules/PortKiller/PortKillerPopoverView.swift`

### Module Metadata
- `id`: `"port_killer"`
- `name`: `"Port Killer"`
- `tagline`: `"Inspect active listening TCP ports and kill stuck dev servers in one click."`
- `symbolName`: `"network"`
- `accentColor`: `Color.indigo`
- `category`: `.developer`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Asynchronous Port Scanning (`PortScanner`):**
   - Run `/usr/sbin/lsof -iTCP -sTCP:LISTEN -P -n -F pcnTu` inside `Task.detached(priority: .userInitiated)` (never synchronously on `@MainActor`).
   - Parse `lsof -F` record-oriented output:
     - `p<pid>` starts a process block; `c<command>` sets process name; `u<uid>` sets owner UID; `n<addr>:<port>` records each listening socket.
     - Parse both IPv4 (`127.0.0.1:3000`, `*:8080`) and IPv6 (`[::1]:5173`, `[::]:3000`) addresses by splitting on the **last** `:` character.
   - **Path & CWD Enrichment:**
     - Use `Darwin`'s `proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))` for the full executable path (fast, in-process syscall, no extra subprocess).
     - Resolve working directory for displayed PIDs using `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, ...)` (`Darwin` / `libproc`), falling back to `lsof -a -p <pids> -d cwd -Fn` if needed.
   - **Deduplication:** A dual-stack server (listening on both `127.0.0.1:3000` and `[::1]:3000` under one PID) collapses into one entry per `(pid, port)` displaying both addresses or `localhost (IPv4 + IPv6)`.
2. **System Daemon Filtering:**
   - When `hideSystemProcesses == true`, hide entries whose UID differs from `getuid()`, whose executable lives under `/System/Library/` or `/usr/libexec/`, or whose command name matches well-known Apple background listeners (`rapportd`, `ControlCenter`, `sharingd`, `AirPlayXPCHelper`, `mDNSResponder`, `launchd`).
3. **Process Termination (`PortKillerModule`):**
   - Validate safety invariants before calling `Darwin.kill(pid, signal)`:
     - Refuse `pid <= 1`.
     - Refuse `pid == ProcessInfo.processInfo.processIdentifier` (Toolbox itself).
   - Call `kill(pid, signal.posixSignal)` (`SIGTERM` = `15`, `SIGKILL` = `9`).
   - Inspect `errno` if `kill` returns `-1`:
     - `EPERM`: show `HUDToast.shared.show(title: "Permission denied (run by another user)", symbol: "lock.fill", tint: .orange)`.
     - `ESRCH`: process already exited; refresh list silently.
   - On `SIGTERM`, schedule a 600 ms re-scan; if the same `(pid, port)` is still listening, mark the row with a `"Still running — Force Kill?"` prompt so the user can escalate with one click.

### Configuration (`PortKillerConfig`)
```swift
enum PortKillSignal: String, Codable, CaseIterable, Sendable {
    case sigterm = "sigterm"
    case sigkill = "sigkill"
}

struct PortKillerConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "p", modifiers: [.control, .option, .command])
    var refreshIntervalSeconds: Int = 5
    var hideSystemProcesses: Bool = true
    var favoritePorts: [Int] = [3000, 5173, 8000, 8080]
    var defaultSignal: PortKillSignal = .sigterm
}
```
- `ToolboxConfig`: add `var portKiller: PortKillerConfig = PortKillerConfig()` with lenient `decodeIfPresent`.

### Verification & Self-Tests
- **Parser unit tests (`SelfTestRunner`):** Feed synthetic `lsof -F pcnTu` output covering IPv4 (`127.0.0.1:3000`), IPv6 (`[::1]:5173`), wildcard (`*:8080`), dual-stack deduplication, and multi-port single-PID processes.
- **Live loopback listener test (`SelfTestRunner`):** Bind an in-process TCP socket (`NWListener` on port `0` or POSIX `socket`/`bind`/`listen` on `127.0.0.1:0`), inspect its assigned ephemeral port, run `PortScanner.scanListeningPorts()`, and assert that the current PID + assigned port appear.
- **Safety guard tests:** Assert termination helper refuses `pid <= 1` and self-PID.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_port_killer.png`.

### Edge Cases & Pitfalls
- **Main-thread blocking:** `lsof` can take 50–300 ms under heavy load; never invoke it synchronously on `@MainActor`.
- **Single-port vs multi-port:** A process may hold multiple ports (e.g., Node app + debugger port `9229`). Always key rows by `(pid, port)` rather than `pid` alone, and warn in subtitle if killing a PID will close multiple ports.
- **Popover polling:** Only run the auto-refresh `Timer` while the popover or settings view is visible, not continuously in the background while idle.

---

## 3. Feature 2: Color Picker & Swatch History (`Modules/ColorPicker/`)

### Purpose & User Value
Designers and frontend/macOS developers frequently need a pixel color from a mockup, browser, or simulator in code-ready formats (`#3B82F6`, `oklch(...)`, `Color(red:green:blue:)`, `rgb(...)`) and want to check WCAG text contrast immediately without opening heavy design tools. **Color Picker** uses macOS's native pixel loupe (`NSColorSampler`), requires **zero permissions**, and retains recent swatches plus a live WCAG 2.1 contrast checker.

### User Flows & UX
- **Instant Eyedropper (`⌃ ⌥ ⌘ C` or Pick button):** Summons macOS's native magnifying loupe over the cursor. Clicking any pixel samples the color, formats it in the user's `defaultFormat`, copies it to `NSPasteboard.general`, shows a `HUDToast` with the formatted string (and a color dot), and prepends it to swatch history. Pressing `Esc` cancels cleanly.
- **Settings & Studio View (`ColorPickerSettingsView.swift`):**
  - **Sampler & Output** section: global shortcut (`ShortcutRecorderView`), default copy format picker (`HEX`, `RGB`, `HSL`, `OKLCH`, `SwiftUI`, `NSColor`), uppercase HEX toggle, `#` prefix toggle, toast confirmation toggle.
  - **Current Color Inspector** section: large swatch preview with quick-copy pills for **all 6 formats** at once so users can grab any representation without changing their default.
  - **WCAG Contrast Checker** section: compare any two swatches (Foreground vs Background, with a one-click Swap button) showing live contrast ratio (`e.g. 4.85:1`) and pass/fail badges for **AA Normal (4.5:1)**, **AA Large (3.0:1)**, and **AAA Normal (7.0:1)**.
  - **Recent Swatches** section: clickable swatch grid (up to `maxHistory`, default `24`) to re-copy or load into Foreground/Background contrast slots, plus pin/clear controls.

### Files to Create
- `Sources/Toolbox/Modules/ColorPicker/ColorPickerModule.swift`
- `Sources/Toolbox/Modules/ColorPicker/ColorFormatter.swift`
- `Sources/Toolbox/Modules/ColorPicker/ColorPickerSettingsView.swift`

### Module Metadata
- `id`: `"color_picker"`
- `name`: `"Color Picker"`
- `tagline`: `"Sample any pixel on screen into HEX, RGB, HSL, OKLCH, or SwiftUI with WCAG contrast checks."`
- `symbolName`: `"eyedropper"`
- `accentColor`: `Color.orange`
- `category`: `.developer`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Zero-Permission Native Sampler:**
   - Use `NSColorSampler().show { [weak self] selectedColor in ... }` on `@MainActor`.
   - `NSColorSampler` is rendered by the macOS WindowServer/system color-sampler daemon and requires **no Screen Recording or Accessibility permissions**.
   - Guard against `selectedColor == nil` (user cancelled with `Esc`).
2. **Color Space Normalization & Pure Formatting (`ColorFormatter`):**
   - Normalize `NSColor` to sRGB before reading components:
     `guard let srgb = color.usingColorSpace(.sRGB) else { ... }`, then clamp `r`, `g`, `b`, `a` to `0.0...1.0` (Display P3 pixels can yield out-of-gamut values slightly `< 0` or `> 1` in extended sRGB).
   - Pure struct `RGBAColor: Codable, Equatable, Sendable` (`r`, `g`, `b`, `a` in `0.0...1.0`) as the canonical representation.
   - Pure formatting functions in `ColorFormatter`:
     - **HEX:** `#RRGGBB` (respecting `uppercaseHex` and `includeHashPrefix`; appends alpha `AA` when `a < 1.0`).
     - **RGB:** `rgb(59, 130, 246)` (or `rgba(59, 130, 246, 0.50)` if `a < 1.0`).
     - **HSL:** `hsl(217, 91%, 60%)` using standard cylindrical RGB-to-HSL math.
     - **OKLCH:** `oklch(0.623 0.214 259.8)`:
       1. Convert sRGB channels $c \in [0, 1]$ to linear sRGB: `c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)`.
       2. Transform linear sRGB to OKLab $(L, a, b)$ via Björn Ottosson's canonical matrices ($M_1$ to LMS, cube root $\text{cbrt}$, $M_2$ to OKLab).
       3. Convert $(a, b)$ to chroma $C = \sqrt{a^2 + b^2}$ and hue $H = \text{atan2}(b, a) \cdot \frac{180}{\pi} \pmod{360}$ (report `0` hue when achromatic $C < 0.0001$).
     - **SwiftUI:** `Color(red: 0.231, green: 0.510, blue: 0.965)`.
     - **NSColor:** `NSColor(srgbRed: 0.231, green: 0.510, blue: 0.965, alpha: 1.00)`.
3. **WCAG 2.1 Contrast Ratio:**
   - Relative luminance: $L = 0.2126 R_{lin} + 0.7152 G_{lin} + 0.0722 B_{lin}$ using the same sRGB-to-linear transfer function.
   - Contrast ratio: $(L_{\max} + 0.05) / (L_{\min} + 0.05) \in [1.0, 21.0]$.
   - Threshold badges: `AA Normal` ($\ge 4.5$), `AA Large` ($\ge 3.0$), `AAA Normal` ($\ge 7.0$).
4. **Swatch Persistence:**
   - Store `[ColorSwatch]` in `color_swatches.json` inside `ConfigManager.shared.configURL.deletingLastPathComponent()` (matching `ClipboardModule`'s `pinned_clipboard.json` pattern so `TOOLBOX_CONFIG_DIR` and `--self-test`/`--snapshot-ui` stay isolated).
   - Deduplicate consecutive or matching swatches (comparing quantized 8-bit RGB/A), promoting re-picked swatches to index `0` while respecting `pinned` status and `maxHistory`.

### Configuration (`ColorPickerConfig`)
```swift
enum ColorFormat: String, Codable, CaseIterable, Sendable {
    case hex, rgb, hsl, oklch, swiftUI, nsColor
}

struct ColorPickerConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "c", modifiers: [.control, .option, .command])
    var defaultFormat: ColorFormat = .hex
    var uppercaseHex: Bool = true
    var includeHashPrefix: Bool = true
    var maxHistory: Int = 24
    var showToastOnPick: Bool = true
}
```
- `ToolboxConfig`: add `var colorPicker: ColorPickerConfig = ColorPickerConfig()`.

### Verification & Self-Tests
- **Formatter accuracy (`SelfTestRunner`):** Verify exact outputs for pure black (`#000000`), pure white (`#FFFFFF`), and `#3B82F6` across all 6 formats (`HEX`, `RGB`, `HSL`, `OKLCH`, `SwiftUI`, `NSColor`), plus uppercase/hash-prefix toggles.
- **WCAG math (`SelfTestRunner`):** Assert `#FFFFFF` vs `#000000` yields `21.0`, identical colors yield `1.0`, and `#3B82F6` vs `#FFFFFF` matches expected pass/fail AA flags.
- **Persistence & dedup (`SelfTestRunner`):** Verify swatch history trimming, pinning preservation, and `color_swatches.json` round-trip in the isolated temp config directory.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_color_picker.png`.

### Edge Cases & Pitfalls
- **Display P3 / wide-gamut colors:** `color.usingColorSpace(.sRGB)` on P3 monitors can return components like `1.09` or `-0.04`. Always clamp `(r, g, b)` to `0...1` before computing 8-bit HEX or luminance.
- **Interaction with `ClipboardModule`:** Copying a sampled color intentionally puts it on `NSPasteboard.general`; do not suppress `ClipboardModule` unless desired, so the picked color is also available in clipboard history.

---

## 4. Feature 3: Dev Converter & Scratchpad (`Modules/DevTools/`)

### Purpose & User Value
Developers constantly open random browser tabs to pretty-print JSON, inspect JWT claims/expiration, Base64/URL-decode strings, convert Unix timestamps, or compute SHA-256 hashes—often pasting sensitive tokens or payloads onto third-party websites. **Dev Converter & Scratchpad** brings all of these transforms into an instant, 100% offline floating utility (`⌃ ⌥ ⌘ B`) and module workspace.

### User Flows & UX
- **Floating Scratchpad Popover (`⌃ ⌥ ⌘ B`):**
  - Opens a non-activating `NSPanel` (`~580 × 480` pt) mirroring `ClipboardModule`'s panel lifecycle.
  - Optional **"Auto-load clipboard on open"**: when enabled, seeds the input editor from `NSPasteboard.general` if it looks like a transformable payload (or always loads current clipboard text with a clear `Paste` / `Clear` toolbar).
  - **Smart Detection Banner:** Automatically analyzes input and highlights a one-click recommended action (e.g., `"Detected JWT (Expires in 2h 14m) → Decode JWT"`, `"Detected Unix Epoch (ms) → Convert Timestamp"`, `"Detected Valid JSON → Pretty Print"`).
  - **Transform Toolbar / Sidebar Chips:**
    - **JSON:** `Pretty (2sp)`, `Pretty (4sp)`, `Minify`, `Sort Keys`, `Escape`, `Unescape`
    - **JWT:** `Decode Header & Payload + Claims Check`
    - **Encode / Decode:** `Base64 Encode`, `Base64 Decode`, `Base64URL Decode`, `URL Encode`, `URL Decode`, `HTML Encode`, `HTML Decode`
    - **Time & Hashes:** `Timestamp ↔ ISO-8601`, `New UUID v4`, `SHA-256`, `SHA-512`, `MD5`
  - **Output Pane:** Monospaced viewer with error badge (exact line/column on invalid JSON), `Copy Output`, and `Use Output as Input` (swap button for chained transforms like URL-decode → JSON-format).
- **Settings View (`DevToolsSettingsView.swift`):**
  - Global shortcut (`ShortcutRecorderView`), `Auto-load clipboard on open` toggle, `JSON indent spaces` (`2` or `4`), `Sort JSON keys` default toggle, plus an embedded quick-test scratchpad preview.

### Files to Create
- `Sources/Toolbox/Modules/DevTools/DevToolsModule.swift`
- `Sources/Toolbox/Modules/DevTools/DevTransformEngine.swift`
- `Sources/Toolbox/Modules/DevTools/DevToolsSettingsView.swift`
- `Sources/Toolbox/Modules/DevTools/DevToolsPopoverView.swift`

### Module Metadata
- `id`: `"dev_tools"`
- `name`: `"Dev Converter"`
- `tagline`: `"Offline scratchpad to format JSON, inspect JWTs, encode/decode Base64 & URLs, convert timestamps, and hash."`
- `symbolName`: `"curlybraces.square"`
- `accentColor`: `Color.blue`
- `category`: `.developer`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Pure Transform Engine (`DevTransformEngine`):**
   - Stateless `enum DevTransformEngine` returning a structured `TransformResult` (`output: String`, `statusBadge: String?`, `isError: Bool`, `errorDetail: String?`).
   - **Auto-Detection Heuristics (`detectKind(for input: String) -> DetectedInputKind?`):**
     1. Trim whitespace/newlines.
     2. **JWT:** Three `.`-separated segments matching Base64URL charset (`[A-Za-z0-9_-]`), first segment decodes to JSON containing `"alg"` or starts with `eyJ`.
     3. **JSON:** Starts with `{` or `[` and parses via `JSONSerialization`.
     4. **Unix Timestamp:** Matches `^-?\d{10}$` (seconds) or `^-?\d{13}$` (milliseconds).
     5. **URL-encoded:** Contains `%[0-9A-Fa-f]{2}` sequences or `http(s)://` query strings.
     6. **Base64:** Length multiple of 4 (or valid unpadded Base64URL) decoding cleanly to UTF-8 text.
   - **JSON Formatter & Diagnostics:**
     - Parse with `JSONSerialization.jsonObject(with:options: [.fragmentsAllowed])` and serialize with `.prettyPrinted`, `.withoutEscapingSlashes`, and optional `.sortedKeys`.
     - Post-process indentation if `indentSpaces == 2` (Apple's `JSONSerialization` emits 2 spaces by default on macOS; scale leading indentation cleanly when 4 spaces requested).
     - On `NSError` (`NSCocoaErrorDomain` `NSPropertyListReadCorruptError` / `NSDebugDescription`), extract line/column/character index from `userInfo` when available and compute fallback `(line, column)` scanner if missing.
   - **JWT Inspector:**
     - Pad each Base64URL segment (`-` → `+`, `_` → `/`, pad `=` to multiple of 4), decode Header & Payload JSON.
     - Inspect standard numeric date claims (`exp`, `iat`, `nbf`): convert epoch seconds to UTC ISO-8601 + local readable date and compare `exp` against `Date()` to report `"Valid (expires in …)"` or `"Expired … ago"`.
     - Never transmit JWTs over the network or verify HMAC/RSA secrets silently—explicitly note `"Signature not verified (offline decode)"`.
   - **Timestamps:**
     - Support 10-digit seconds, 13-digit milliseconds, 16-digit microseconds, and ISO-8601 input (`ISO8601DateFormatter` with fractional seconds fallback), displaying UTC, Local, and relative offset.
   - **Cryptography (`CryptoKit`):**
     - `SHA256.hash(data:)`, `SHA512.hash(data:)`, and `Insecure.MD5.hash(data:)` formatted as lowercase hex strings.
2. **Code Editor Input Ergonomics:**
   - Wrap an `NSTextView` (or configure SwiftUI `TextEditor`) with `isAutomaticQuoteSubstitutionEnabled = false`, `isAutomaticDashSubstitutionEnabled = false`, `isAutomaticTextReplacementEnabled = false`, and `isAutomaticSpellingCorrectionEnabled = false` so macOS never mangles straight JSON quotes `"` into smart quotes `“”`.

### Configuration (`DevToolsConfig`)
```swift
struct DevToolsConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "b", modifiers: [.control, .option, .command])
    var autoLoadClipboardOnOpen: Bool = true
    var jsonIndentSpaces: Int = 2
    var sortJsonKeys: Bool = false
}
```
- `ToolboxConfig`: add `var devTools: DevToolsConfig = DevToolsConfig()`.

### Verification & Self-Tests
- **Transform suite (`SelfTestRunner`):**
  - JSON pretty-print (2 spaces & 4 spaces), sorted keys, minify, escape/unescape, and invalid-JSON error diagnostic.
  - JWT decode with synthetic header + payload containing future `exp` and past `exp` claims, asserting formatted JSON and expiry status.
  - Base64 & Base64URL encode/decode, URL encode/decode, HTML entity encode/decode.
  - Epoch seconds/ms ↔ ISO-8601 round-trip, UUID v4 format validation, and known-vector `SHA-256` (`"abc"` → `"ba7816bf..."`), `SHA-512`, `MD5`.
  - Auto-detection tests for all 5 input kinds.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_dev_tools.png`.

### Edge Cases & Pitfalls
- **Smart quotes in macOS text views:** Default macOS `NSTextView` replaces `"` with `“`; disabling smart substitutions is mandatory for a JSON scratchpad.
- **Non-UTF-8 Base64 output:** When decoding Base64 yields raw binary bytes rather than valid UTF-8, return a clean hex dump (`xxd`-style or spaced hex) with an explanatory badge instead of failing silently.
- **Large payloads:** Cap auto-load from clipboard or display truncation warning for multi-megabyte strings so opening the popover stays instantaneous (`< 50 ms`).

---

## 5. Feature 4: Screen OCR / Text Grabber (`Modules/ScreenOCR/`) — Done

### Purpose & User Value
Often you need text locked inside a screenshot, YouTube tutorial, PDF scan, simulator screenshot, error dialog, or screen-share video call. **Screen OCR** binds a global shortcut (`⌃ ⌥ ⌘ O`) to drag-select any screen region, runs Apple's on-device `Vision` text & QR/barcode recognizer completely offline, and drops the extracted text straight onto your clipboard.

### User Flows & UX
- **Capture Hotkey (`⌃ ⌥ ⌘ O`) or Menu/Settings Button:**
  - Invokes macOS's native interactive crosshair region selector (`/usr/sbin/screencapture -i -x`).
  - Dragging a box captures the region silently (`-x` disables camera shutter sound) and runs `ScreenOCREngine` asynchronously.
  - On success: copies recognized text (or decoded QR payload) to `NSPasteboard.general`, shows `HUDToast` with a snippet preview (e.g., `"Copied 4 lines"` or `"Copied QR URL"`), and appends to an in-memory **Recent Captures** list (up to 10 items, never persisted to disk for privacy).
  - Pressing `Esc` cancels cleanly with no toast and no error.
- **Settings View (`ScreenOCRSettingsView.swift`):**
  - **Capture & Shortcut** section: global shortcut (`ShortcutRecorderView`), "Capture Region Now" button, Screen Recording permission status / helper link.
  - **Recognition Options** section: recognition speed/accuracy picker (`Accurate` vs `Fast`), `Preserve line breaks` toggle (vs joining wrapped paragraph lines with spaces), `Detect QR & Barcodes` toggle, `Show toast notification` toggle.
  - **Recent Captures (Session Only)** section: list of extracted snippets from the current session with 1-click Copy and Clear Session buttons.

### Files to Create
- `Sources/Toolbox/Modules/ScreenOCR/ScreenOCRModule.swift`
- `Sources/Toolbox/Modules/ScreenOCR/ScreenOCREngine.swift`
- `Sources/Toolbox/Modules/ScreenOCR/ScreenOCRSettingsView.swift`
- **Build link update:** Add `.linkedFramework("Vision")` to `Package.swift`.

### Module Metadata
- `id`: `"screen_ocr"`
- `name`: `"Screen OCR"`
- `tagline`: `"Drag-select any area on screen to copy unselectable text or QR codes completely offline."`
- `symbolName`: `"text.viewfinder"`
- `accentColor`: `Color.mint`
- `category`: `.developer`
- `requiresAccessibility`: `false`

### Technical Design & macOS APIs
1. **Interactive Region Capture (`ScreenOCRModule`):**
   - Guard against overlapping captures (`guard !isCapturing else { return }`).
   - Create a unique temporary PNG path under `FileManager.default.temporaryDirectory` (`toolbox-ocr-<UUID>.png`).
   - Run `/usr/sbin/screencapture -i -x <tempPath>` inside `Task.detached`.
   - Always `defer { try? FileManager.default.removeItem(at: tempURL) }` once loaded into memory as `CGImage` (`CGImageSourceCreateWithURL` or `NSImage(contentsOf:)?.cgImage(forProposedRect: nil, context: nil, hints: nil)`) so no screenshot ever lingers on disk.
   - If the user pressed `Esc`, `screencapture` exits without writing the file (`!FileManager.default.fileExists(atPath: tempPath)`). Return quietly as a cancellation.
   - *Note on Screen Recording permission:* `/usr/sbin/screencapture` is an Apple-signed system binary that handles its own capture authorization smoothly and respects macOS Screen Recording permissions cleanly without requiring custom full-screen `CGWindowListCreateImage` capture loops.
2. **On-Device Vision Recognition (`ScreenOCREngine`):**
   - Pure async/synchronous helper taking `CGImage` + options:
     - Configure `VNRecognizeTextRequest`:
       - `request.recognitionLevel = config.recognitionLevel == .accurate ? .accurate : .fast`
       - `request.usesLanguageCorrection = true`
       - `request.automaticallyDetectsLanguage = true` (supported on macOS 14+)
     - Sort observations top-to-bottom (`boundingBox.origin.y` descending, since Vision coordinates use bottom-left origin) with slight y-tolerance for same-line columns, or use natural order returned by Vision and join lines with `\n` (when `preserveLineBreaks == true`) or `" "` (when `preserveLineBreaks == false`).
     - When `detectQRCodes == true`, also run `VNDetectBarcodesRequest` in the same `VNImageRequestHandler(cgImage: options: [:])`; if text is empty and a barcode/QR `payloadStringValue` is found (or combine both if desired—prefer text when substantial, and surface QR payload cleanly when present).
3. **Clipboard & Toast Feedback:**
   - Write recognized text to `NSPasteboard.general` on `@MainActor`.
   - If nothing was recognized, show `HUDToast.shared.show(title: "No text found in selection", symbol: "text.viewfinder", tint: .orange)`.

### Configuration (`ScreenOCRConfig`)
```swift
enum OCRRecognitionLevel: String, Codable, CaseIterable, Sendable {
    case accurate = "accurate"
    case fast = "fast"
}

struct ScreenOCRConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "o", modifiers: [.control, .option, .command])
    var recognitionLevel: OCRRecognitionLevel = .accurate
    var preserveLineBreaks: Bool = true
    var detectQRCodes: Bool = true
    var showToast: Bool = true
}
```
- `ToolboxConfig`: add `var screenOCR: ScreenOCRConfig = ScreenOCRConfig()`.

### Verification & Self-Tests
- **Offscreen `Vision` OCR test (`SelfTestRunner`):** Programmatically draw high-contrast text (`"Toolbox Vision OCR 42"`) onto an offscreen bitmap `CGContext` (`NSBitmapImageRep` / `CGContext`), extract `CGImage`, run `ScreenOCREngine.recognize(...)`, and assert the output contains `"Toolbox Vision OCR 42"`.
- **Line-break joining test:** Verify `preserveLineBreaks: true` vs `false` formatting over multi-line test lines, including a dense-rows regression (line heights relative to a large capture must not merge adjacent lines) and a same-row columns case.
- **End-to-end QR/barcode test:** Generate a real QR code with CoreImage `CIQRCodeGenerator` and assert `VNDetectBarcodesRequest` decodes its payload; the developer self-check sample must round-trip through the same engine path.
- **Developer self-check lifecycle test:** `ScreenOCRModule.runSelfCheck()` runs the sample off the main thread, then stores the `OCRSelfCheckResult` (text, QR payloads, duration).
- **Missing/cancelled file handling:** Assert graceful `nil` / cancelled state when temp screenshot file does not exist.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_screen_ocr.png` (permission badge pinned for determinism).

### Edge Cases & Pitfalls
- **Tiny or low-contrast screenshots:** When a user selects a small UI label (`< 40 px` tall), Vision recognizes significantly better if very small `CGImage` regions are checked with `.accurate` (or upscaled 2x if height `< 32 px`).
- **Dense text in large selections:** Same-row grouping must scale with the *text* size, not the selection size — the tolerance is half the median observation line height (clamped to 0.4–2% of image height), so body copy in a full-screen capture keeps its line breaks while same-line columns still merge.
- **Rapid shortcut presses / stacked crosshairs:** Ignoring re-entrant hotkey triggers while a capture is in flight prevents spawning stacked crosshair sessions. `isCaptureInFlight` deliberately includes the developer pipeline test, whose interactive crosshair must not stack a second one under the global hotkey.
- **Stopped mid-flight:** If the module is disabled or the app pauses while a capture/recognition is in flight, the in-flight result is dropped (never written to the clipboard) and its file removed.
- **Failed-capture retention (diagnostic evidence):** Successful captures delete their temp PNG immediately, but *failed* (empty/undecodable) captures are **kept** and surfaced in Developer Tools → Screen OCR (Reveal / Re-analyze) plus `Toolbox --ocr-file`. Stale `toolbox-ocr-*` artifacts are swept at app launch (`ScreenOCRModule.sweepStaleTempFiles`) and pipeline-test artifacts at the start of each test, so nothing accumulates across sessions.
- **Uniform-black vs dark UI:** The "selection looks black" permission heuristic tests the *fraction* of near-black pixels (> 99% = uniform black = permission-failure signature) — never an average luminance, which false-positives on dark-themed UIs (terminals, dark mode) that are dark but not uniform.
- **Small text in large captures:** Vision's default `minimumTextHeight` (1/40 of image height) silently drops normal 13–16 pt text in full-screen Retina captures; the engine sets it to 1/100.
- **Multi-line observations & paragraphs:** Vision groups a paragraph into one observation; the box is split evenly across its sub-lines (own Y + height each) so paragraphs don't merge into one row, and a vertical gap > 1× median line height — or an explicit blank line in the source text — re-emits a paragraph break when `preserveLineBreaks` is on.

---

## 6. Feature 5: Keyboard & Trackpad Clean Lock (`Modules/CleanLock/`) — Done

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

### Files to Create
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

---

## 7. Feature 6: Call Controls (`Modules/CallControls/`) — Done

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
