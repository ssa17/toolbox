# Color Picker & Swatch History — Feature Spec

> **Status:** Planned · **Module:** `Modules/ColorPicker/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

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

## Appendix: Earlier Planning Draft (superseded)

> ⚠️ **Superseded — do not implement from this draft.** The notes below were written independently of the canonical spec above and in places contradict it (e.g., they assume permissions and feature scope the canonical spec does not have, and list different files). Where the two disagree, **the spec above wins** (and, for shipped features, the running code). The draft is retained here so no planning notes are lost.

### Purpose & User Value

Color selection is an essential part of many workflows, yet macOS's native color picker can be inconvenient to access frequently. Some developers also need a **history of recently sampled colors** to quickly reference or reuse colors later.

**Color Picker & Swatch History** provides a fast, accessible way to:
1. **Sample Colors from Anywhere**: Click to sample colors from any visible UI element, image, or window
2. **Access Swatch History**: Browse and reuse colors you've previously sampled
3. **Copy as Multiple Formats**: Get the selected color in HEX, RGB, HSL, or Apple's NSColor format
4. **Quick Keyboard Access**: Launch with a memorable shortcut (e.g., `⌃ ⌥ ⌘ C`)

**User Value**: 
- Faster color selection vs. opening Xcode, Preview, or System Preferences
- Don't lose great color combinations when switching apps
- Workflows for designers, developers, and anyone who needs precise colors

### User Flows & UX

#### Color Sampling
- **Global Popover (`⌃ ⌥ ⌘ C`):** Opens near cursor or in a fixed position, displays the sampled color in a clean card
- **Color Preview**: Shows the sampled color as a large swatch with the color name below
- **Live Updates**: As you move the cursor, the color card updates in real-time (optional toggle)
- **Sampling Options**:
  - **Foreground Color**: Samles the top-most non-transparent pixel
  - **Background Color**: Samples what's behind the window
  - **Background of Selection**: Highlights the area that was clicked

#### Swatch History
- **History List View**: Displays all recently sampled colors (default: last 10-20 colors)
- **Color Cards**: Each swatch shows:
  - Color preview (circular or square)
  - Color name or hex code (e.g., "#3B82F6", "blue-500")
  - Date/time sampled (optional, can be hidden)
- **Organization**: Colors sorted by date (newest first) or can be manually reordered
- **Search/Filter**: Optional filter by hue range, brightness, or category

#### Color Format Selection
- **Output Format Picker**: Choose which format to copy (HEX, RGB, HSL, CSS, NSColor)
- **Format Presets**: Quick-select common formats (HEX/RGB, or all formats at once)
- **One-Click Copy**: Copy color to clipboard with selected format

#### Presets & Categories
- **System Colors**: Access macOS/iOS standard colors (System Blue, System Gray, etc.)
- **Brand Colors**: Pre-defined company/brand colors (Twitter blue, Facebook blue, etc.)
- **Named Colors**: Browse all NSColorSystem named colors (red, orange, yellow, etc.)
- **Custom Presets**: Save frequently-used color combinations for quick access

#### Accessibility Considerations
- **Contrast Checker**: Optional checker to test selected color against white/black
- **Large Text**: Toggle between large/small preview for easier viewing on Retina displays

#### Popover Placement & Behavior
- **Cursor-Based**: Popover appears near cursor when hovering over UI element
- **Fixed Position**: Always appears in a consistent location (e.g., top-right of screen)
- **Non-Activating**: Popover stays open when clicking outside (like clipboard menu)
- **Auto-Dismiss**: Dismiss after timeout or clicking outside (user-configurable)

### Key Capabilities

- **Fast Sampling**: Sub-100ms color extraction from screen
- **History Persistence**: Swatches saved across Toolbox restart
- **Multiple Formats**: Support for common color formats (HEX, RGB, HSL, etc.)
- **Accessibility**: Keyboard-accessible (shortcut-triggered, no mouse required)
- **Presets System**: Pre-loaded and user-defined color collections
- **Search & Filter**: Find colors by name, value range, or category
- **Contrast Checking**: Optional WCAG AA/AAA compliance check

### Technical Constraints & Considerations

- **Accessibility Permission Required**: To read pixel data from other apps' windows
- **Screen Recording Not Needed**: Color sampling uses AX/UI accessibility APIs, not screen capture
- **Performance**: Should handle hundreds of windows without lag
- **Color Space**: Convert between sRGB, Display P3, and other color spaces correctly
- **Transparency Handling**: Decide how to handle alpha transparency (sample RGB only, or include opacity?)
- **Color Name Lookup**: Map hex values to closest NSColorSystem name (fuzzy matching)
- **Platform Differences**: macOS color space varies by display (calibrated vs. uncalibrated)
- **Copy to Clipboard**: Need to integrate with AppKit's clipboard copying mechanism

### Files to Create

- `Sources/Toolbox/Modules/ColorPicker/ColorPickerModule.swift` — Main module orchestrator, lifecycle management, global shortcut handling, popovers
- `Sources/Toolbox/Modules/ColorPicker/ColorSampler.swift` — Color sampling logic, handles cursor tracking, AX queries, color extraction
- `Sources/Toolbox/Modules/ColorPicker/SwatchHistory.swift` — Manages color swatch storage and retrieval
- `Sources/Toolbox/Modules/ColorPicker/ColorPickerPopoverView.swift` — SwiftUI popover for color preview and sampling
- `Sources/Toolbox/Modules/ColorPicker/SwatchHistoryView.swift` — SwiftUI view for browsing color history
- `Sources/Toolbox/Modules/ColorPicker/ColorFormatConverter.swift` — Convert between color formats (HEX⇄RGB⇄HSL, etc.)
- `Sources/Toolbox/Modules/ColorPicker/ColorPresetManager.swift` — Manage preset color collections

---

### Additional Notes for Implementation

When you start implementing this feature, consider:

1. **Color Space Management**: macOS has different color spaces (Display P3 on Retina, sRGB on non-Retina). You'll need to handle conversions correctly, especially for web colors (HEX) vs. native Apple colors.

2. **Color Name Lookup**: macOS has a built-in `NSColorSystem.color(withName:)` that returns named colors. You'll need to map hex values to the closest named color. This can be done by comparing color values and finding the best match within a tolerance threshold.

3. **Transparency Handling**: Some users want just the RGB values (for web design), others want the alpha channel too (for native apps). Consider making this configurable.

4. **Performance Optimization**: Color sampling involves querying AXUIElement for pixel data, which can be slow. Consider:
   - Caching recently-sampled colors at coordinates
   - Only updating color when cursor moves significantly
   - Throttling live preview updates

5. **Contrast Checking**: If you want to include contrast checking, you'll need to sample both the foreground color and the background color it's drawn on, then calculate luminance ratio against white and black backgrounds.

6. **Clipboard Integration**: When copying color, you'll create a new string in the clipboard. For RGB, HEX, and HSL this is straightforward. For NSColor, you'll need to convert and potentially use AppKit to paste it into color picker-compatible apps.

7. **Accessibility Compliance**: Ensure the popover itself is accessible (keyboard navigable). Users should be able to dismiss it, select a color, or add to history without a mouse.

8. **Persistence Format**: When saving/swatching colors, consider storing as an array of color objects with format: `{ hex: String, rgb: {r,g,b}, hsl: {h,s,l}, alpha: Double }`. This future-proofs your storage format.
