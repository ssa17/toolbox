# Quick Screenshot — Feature Spec

> **Status:** Planned · **Module:** `Modules/QuickScreenshot/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
macOS's built-in screenshot tool drops files onto the Desktop and offers slow, basic Markup—making it tedious to capture an area, add an arrow or step number, **irreversibly redact** sensitive emails/API keys, and copy straight to the clipboard for Slack, GitHub, email, or AI chats. **Quick Screenshot** (`⌃ ⌥ ⌘ 5`) gives users a fast, CleanShot X / Shottr-style floating capture editor with solid-box redaction, one-click Vision OCR, and seamless integration with Toolbox's `Clipboard` history.

### User Flows & UX
- **Capture (`⌃ ⌥ ⌘ 5` or Menu Bar / Settings button):**
  - Launches `/usr/sbin/screencapture -i -x [-o] <tempPath>` (pressing `Space` toggles window capture; `Esc` cancels cleanly with no toast).
  - If `openEditorAfterCapture == true` (default), opens a crisp floating **Quick Editor** window containing the captured image; if `false`, copies straight to `NSPasteboard.general` with a `HUDToast` and optional compact corner preview card to open the editor on click.
- **Quick Editor Canvas:**
  - **Tools:** Select/Move (`V`), Arrow (`A`), Rectangle (`R`), Ellipse (`O`), Highlighter (`H`), Text Callout (`T`), Auto-Increment Step Counter (`N`: `1`, `2`, `3`…), **Redact (`B` — Solid Opaque Box default, or Pixelate)**, and Crop (`C`).
  - **Style & History Bar:** Color swatches, stroke thickness, `Undo (⌘ Z)` / `Redo (⇧ ⌘ Z)`.
  - **Smart Actions:**
    - **Auto-Redact Secrets/PII:** Runs local `Vision` text recognition + pattern matching (emails, `sk-...`, `ghp_...`, `AKIA...`, `Bearer ...`, JWTs, phone/card numbers) and places editable solid-black redaction boxes over matches so users can review or undo before exporting.
    - **Copy Text (OCR):** Reuses `ScreenOCREngine` to copy extracted text from the screenshot.
  - **Output Bar:**
    - **Copy (`⌘ C` / `Return`):** Flattens annotations + redactions at full native Retina resolution, writes PNG + TIFF to `NSPasteboard.general` (automatically picked up by `Clipboard` Image History), shows `HUDToast`, and closes if `closeEditorAfterCopy == true`.
    - **Save (`⌘ S`):** Saves flattened PNG/JPEG to `defaultSaveDirectory` (or `NSSavePanel`).
    - **Share:** Opens native `NSSharingServicePicker` (AirDrop, Mail, Messages).
- **Settings View (`QuickScreenshotSettingsView.swift`):**
  - Built with `FeatureSection`, `SettingRow`, `Divider()`, `ShortcutRecorderView`, and `.pointerCursor()` on all controls.
  - **Capture & Shortcut** section: global shortcut (`ShortcutRecorderView`), "Capture Now" button, Screen Recording permission status / helper link, `Open editor after capture` toggle, `Close editor after copy` toggle, `Omit window drop shadow` toggle (`-o`).
  - **Editor & Export** section: `Default redaction style` picker (`Solid Opaque Box`, `Pixelate`), `Save format` (`PNG`, `JPEG`), `JPEG quality` slider, `Default save folder` picker, `Show toast` toggle.

### Files to Create
- `Sources/Toolbox/Modules/QuickScreenshot/QuickScreenshotModule.swift`
- `Sources/Toolbox/Modules/QuickScreenshot/ScreenshotAnnotationModel.swift`
- `Sources/Toolbox/Modules/QuickScreenshot/ScreenshotRenderer.swift`
- `Sources/Toolbox/Modules/QuickScreenshot/ScreenshotAutoRedactor.swift`
- `Sources/Toolbox/Modules/QuickScreenshot/QuickScreenshotEditorView.swift`
- `Sources/Toolbox/Modules/QuickScreenshot/QuickScreenshotSettingsView.swift`
- **Build link check:** Verify `.linkedFramework("CoreImage")` in `Package.swift` if not already transitively linked.

### Module Metadata
- `id`: `"quick_screenshot"`
- `name`: `"Quick Screenshot"`
- `tagline`: `"Capture any area or window into a fast floating editor to annotate, redact secrets, copy to clipboard, or share."`
- `symbolName`: `"camera.viewfinder"`
- `accentColor`: `Color.red`
- `category`: `.productivity`
- `requiresAccessibility`: `false` *(Screen Recording is OS-managed via `/usr/sbin/screencapture`.)*

### Technical Design & macOS APIs
1. **Interactive Capture (Mirrors `ScreenOCRModule`):**
   - Enforce `guard !isCaptureInFlight else { return }` to prevent stacked crosshair sessions, cap concurrent Quick Editor windows (max `5`), and release full `CGImage` buffers immediately on editor window close.
   - Write to `FileManager.default.temporaryDirectory/toolbox-shot-<UUID>.png` with owner-only `0600` permissions (screenshots may contain secrets before redaction), run `/usr/sbin/screencapture -i -x [-o] <path>` in `Task.detached`, load `CGImage` into memory, and `defer { try? FileManager.default.removeItem(at: tempURL) }`.
   - Sweep stale `toolbox-shot-*` files on launch (`sweepStaleTempFiles()`), and check the `> 99%` uniform-black heuristic to surface a helpful Screen Recording permission hint if a capture fails due to missing OS permission.
   - Register the global shortcut via `HotKeyManager.shared` using key `"quick_screenshot.capture"` (wired into `inAppConflictDescription` and `clearConflictingShortcuts`).
2. **Native-Pixel Annotation Model (`ScreenshotAnnotationModel`):**
   - Store all shapes, arrows, text callouts, step badges, crop rect, and redactions in **native `CGImage` pixel coordinates** (independent of editor window zoom/Retina scale) with immutable undo/redo history stacks.
3. **Irreversible Flattening Renderer (`ScreenshotRenderer`):**
   - Render base `CGImage` (cropped to `cropRect` if set) into a full-resolution `CGContext` preserving color space:
     - **Solid Redaction:** Draw 100% opaque `CGColor` fill (`alpha = 1.0`) directly into the pixel buffer—never translucent layers or metadata overlays.
     - **Pixelate Redaction:** Apply `CIPixellate` clipped strictly to the redaction rect.
     - **Annotations:** Draw arrows, rectangles, ellipses, highlighter strokes (`multiply` blend mode), numbered step badges, and CoreText/AppKit labels cleanly scaled for Retina clarity.
4. **Local Auto-Redactor (`ScreenshotAutoRedactor`):**
   - Run `VNRecognizeTextRequest` (`.accurate`) on the captured `CGImage`, inspect word/token bounding boxes (`boundingBox(for: range)`), and match emails, bearer/API tokens, AWS keys, JWTs, and credit-card/phone patterns to emit editable `AnnotationItem` redactions.

### Configuration (`QuickScreenshotConfig`)
```swift
enum RedactStyle: String, Codable, CaseIterable, Sendable {
    case solidBlack = "solid_black"
    case pixelate = "pixelate"
}

enum ScreenshotSaveFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg
}

struct QuickScreenshotConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var shortcut: ShortcutSpec = ShortcutSpec(key: "5", modifiers: [.control, .option, .command])
    var openEditorAfterCapture: Bool = true
    var closeEditorAfterCopy: Bool = true
    var omitWindowShadow: Bool = false
    var defaultRedactMode: RedactStyle = .solidBlack
    var defaultSaveDirectory: String = "~/Desktop"
    var saveFormat: ScreenshotSaveFormat = .png
    var jpegQuality: Double = 0.9
    var showToast: Bool = true
}
```
- `ToolboxConfig`: add `var quickScreenshot: QuickScreenshotConfig = QuickScreenshotConfig()` with lenient `decodeIfPresent` defaults, bump `schemaVersion`, and append `"quick_screenshot"` to `GeneralConfig.defaultMenuBarModuleOrder`.

### Verification & Self-Tests
- **Annotation & undo/redo (`SelfTestRunner`):** Test adding/moving/deleting annotations, auto-incrementing step counters (`1, 2, 3`), and multi-step Undo/Redo.
- **Offscreen flattening (`SelfTestRunner`):** Render annotations onto a synthetic `400 × 300` `CGImage` and assert: (a) crop yields exact target pixel dimensions, (b) solid redaction sets every pixel inside the rect to pure opaque black `(0, 0, 0, 255)`, and (c) pixelation modifies pixels only inside the target rect.
- **Auto-redactor (`SelfTestRunner`):** Verify regex/token matching for emails, `sk-...`, `ghp_...`, `AKIA...`, and JWTs without false-positiving on ordinary prose.
- **Config (`SelfTestRunner`):** Verify `QuickScreenshotConfig` `Codable` round-trip and partial JSON migration defaults.
- **Visual Snapshot (`SnapshotRunner`):** Render `module_quick_screenshot.png`.

### Edge Cases & Pitfalls
- **Retina coordinate mapping:** Always convert SwiftUI view coordinates to native `CGImage` pixel coordinates via the rendered image rect so 2x/3x Retina captures align pixel-perfectly.
- **Stacked captures:** `isCaptureInFlight` must cover both global shortcut and Settings "Capture Now" triggers.
- **Shortcut separation:** Uses `⌃ ⌥ ⌘ 5` so it never collides with macOS `⇧ ⌘ 5` or `ScreenOCR`'s `⇧ ⌘ 0`.
- **Disabled mid-flight:** If the module is disabled or Toolbox pauses while `screencapture` is open, discard the result and remove the temp file.
