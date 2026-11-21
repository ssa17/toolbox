# Screen OCR / Text Grabber — Feature Spec

> **Status:** Done · **Module:** `Modules/ScreenOCR/` · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Often you need text locked inside a screenshot, YouTube tutorial, PDF scan, simulator screenshot, error dialog, or screen-share video call. **Screen OCR** binds a global shortcut (`⇧ ⌘ 0`) to drag-select any screen region, runs Apple's on-device `Vision` text & QR/barcode recognizer completely offline, and drops the extracted text straight onto your clipboard.

### User Flows & UX
- **Capture Hotkey (`⇧ ⌘ 0`) or Menu/Settings Button:**
  - Invokes macOS's native interactive crosshair region selector (`/usr/sbin/screencapture -i -x`).
  - Dragging a box captures the region silently (`-x` disables camera shutter sound) and runs `ScreenOCREngine` asynchronously.
  - On success: copies recognized text (or decoded QR payload) to `NSPasteboard.general`, shows `HUDToast` with a snippet preview (e.g., `"Copied 4 lines"` or `"Copied QR URL"`), and appends to an in-memory **Recent Captures** list (up to 10 items, never persisted to disk for privacy).
  - Pressing `Esc` cancels cleanly with no toast and no error.
- **Settings View (`ScreenOCRSettingsView.swift`):**
  - **Capture & Shortcut** section: global shortcut (`ShortcutRecorderView`), "Capture Region Now" button, Screen Recording permission status / helper link.
  - **Recognition Options** section: recognition speed/accuracy picker (`Accurate` vs `Fast`), `Preserve line breaks` toggle (vs joining wrapped paragraph lines with spaces), `Detect QR & Barcodes` toggle, `Show toast notification` toggle.
  - **Recent Captures (Session Only)** section: list of extracted snippets from the current session with 1-click Copy and Clear Session buttons.

### Files Created
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
    var shortcut: ShortcutSpec = ShortcutSpec(key: "0", modifiers: [.command, .shift])
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
