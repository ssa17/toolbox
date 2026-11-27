# Quick Screenshot — Feature Spec

> **Status:** Shipped · **Module:** `Modules/QuickScreenshot/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
macOS's built-in screenshot tool drops files onto the Desktop and offers slow, basic Markup—making it tedious to capture an area, add an arrow or step number, **irreversibly redact** sensitive emails/API keys, and copy straight to the clipboard for Slack, GitHub, email, or AI chats. **Quick Screenshot** (`⌃ ⌥ ⌘ 5`) gives users a fast, CleanShot X / Shottr-style floating capture editor with solid-box redaction, one-click Vision OCR, and seamless integration with Toolbox's `Clipboard` history.

### User Flows & UX
- **Capture (`⌃ ⌥ ⌘ 5` or Menu Bar / Settings button):**
  - Launches `/usr/sbin/screencapture -i -x [-o] <tempPath>` (pressing `Space` toggles window capture; `Esc` cancels cleanly with no toast).
  - If `openEditorAfterCapture == true` (default), opens a crisp floating **Quick Editor** window containing the captured image; if `false`, copies straight to `NSPasteboard.general` with a `HUDToast` and optional compact corner preview card to open the editor on click.
- **Quick Editor Canvas:**
  - **Tools:** Select/Move (`S`), Arrow (`A`), Rect (`R`), Ellipse (`E`), Highlight (`H`), Text (`T`), Number (`N`: `1`, `2`, `3`…), **Redact (`X` — Solid Opaque Box default, or Pixelate)**, and Crop (`C`).
  - **Style & History Bar:** Contextual color swatches & stroke thickness (or Solid/Pixelate style when Redact is active/selected), `Undo (⌘ Z)` / `Redo (⇧ ⌘ Z)`.
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

### Hardening Notes & Open Decisions
*Surfaced by plan review. These are plan-level findings and decisions to ratify — not code steps.*

**Shortcut & System Integration (⌘⇧4 / ⌘⇧5)**
- ⌘⇧4 is a macOS-registered system chord ("Save Area Screenshot"). A Carbon hotkey for the same chord is rejected by the system (`eventHotKeyExistsErr`) — this is why `HotKeyManager` surfaces "Active macOS system shortcut" warnings for it, and why the default chord is `⌃ ⌥ ⌘ 5`.
- Actually replacing ⌘⇧4 means swallowing the system-registered chord via a background event tap (the same pattern WindowSnapper/FinderEnhancer use) — which requires **Accessibility permission** and flips this module from zero-permission to Accessibility-gated. That is a real positioning change and must be an explicit, opt-in decision, not a silent default.
- ⌘⇧5 ("Screenshot & Recording Options") carries screen recording and the full screenshot toolbar. It must **not** be swallowed or intercepted. ⌘⇧3 (full-screen shot) is likewise out of scope.
- Proposed direction (pending ratification): keep `⌃ ⌥ ⌘ 5` as the default zero-permission chord; add an opt-in **"Replace macOS ⌘⇧4"** setting (default off) that swallows ⌘⇧4 and routes it to Quick Screenshot, requiring Accessibility, and that disables cleanly (tap torn down, system chord re-arms) when the module is disabled, paused, or Toolbox is paused. ⌘⇧5 and ⌘⇧3 remain untouched.
- Either way, the module must not intercept or swallow the built-in chords while disabled/paused, and the shortcut recorder must surface the system-shortcut warning for ⌘⇧4/⌘⇧5 so users understand the trade-off.
- `⌃ ⌥ ⌘ S` ("S" for Screenshot) was considered and **rejected**: it is not a system-reserved chord, but it is the planned default for `meeting_shield` (see `meeting_shield.md` and the roadmap). Taking it would break the collision-free default-shortcut invariant across planned modules. Keep `⌃ ⌥ ⌘ 5`.

**Editor canvas**
- No zoom/pan is planned: a full-screen Retina capture cannot be annotated at fit-to-screen scale. Add zoom (fit / 100% / 200%) and pan to the plan; annotations stay in native coordinates so zoom is a view concern.
- The editor window type is unspecified: it must be **key/activating** (it receives V/A/R/… and ⌘Z), unlike the `.nonactivatingPanel` pattern used by Clipboard/PortKiller. Record this explicitly so it isn't copy-pasted wrong.
- Close/cancel semantics with unsaved annotations are undefined: Esc and window-close should confirm or discard deliberately, and the plan should state the affordance.
- Step-counter semantics are undefined: does the counter continue across annotations in a single capture? Reset per capture? Per tool?

**Capture & privacy**
- Temp-file permissions: `screencapture` writes the file itself, so owner-only 0600 cannot be assumed — the plan must state how the 0600 guarantee is enforced, not just that it exists.
- The no-editor fallback (`openEditorAfterCapture == false`) copies the **raw, unredacted** capture to the clipboard — and then into Clipboard Image History via its existing auto-pickup. This needs an explicit decision: default off, or at minimum a documented, warned path.
- Redacted copies landing in Clipboard Image History is intended and desirable, but should be a named, documented decision (and dedupe/history-cap behavior should be inherited deliberately, not by accident).
- Reuse the ScreenOCR machinery explicitly (capture process, `screencapture` invocation, permission probe, load/blank-detection helpers, `ScreenOCREngine`) instead of growing a parallel OCR/capture stack in this module.

**Auto-redactor**
- Recognition runs off the main thread; `.accurate` recognition on a large capture is slow and must never block the editor.
- Use a checksum (Luhn) for card-like numbers instead of pure regex, to kill most false positives; phone/JWT patterns need an explicit false-positive budget and should not drown the review list.
- Detected boxes should be **reviewable**: surface each match with its source snippet/confidence so users can dismiss or keep it — a silent box storm would train users to distrust the tool.

**Export & fidelity**
- JPEG export: PNG→JPEG drops alpha — composite onto an opaque background first, and test the JPEG path, not just PNG.
- Coordinate conversion (view → native pixels) belongs in one place with a non-1.0-scale self-test, not only in a checklist.
- Undo/redo on the immutable annotation list is the right model; per-frame re-render at Retina scale (dozens of shapes over a large image) is the thing to watch.

**Phasing & test gaps**
- Phase the rollout so each phase is shippable and testable: (1) capture + copy to clipboard, (2) editor with shapes/arrows/text/step badges, (3) redact + auto-redact + OCR, (4) save/share/JPEG.
- Self-tests to add beyond the current plan: arrow/rect/text/step-badge flattening; JPEG alpha compositing; non-1.0 scale mapping; discard-on-disable mid-capture; opt-in ⌘⇧4 tap enable/disable lifecycle.
