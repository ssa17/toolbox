# Clipboard History: Image History Support — Enhancement Spec

> **Status:** Shipped · **Target Module:** `Modules/Clipboard/` (`clipboard`) · **Parent:** [Toolbox Feature Roadmap](../feature-roadmap.md)

### Purpose & User Value
Toolbox's `Clipboard History` (`⌥ ⌘ V`) currently captures text only (`recordText`), meaning copied screenshots, `QuickScreenshot` captures, design snippets, and copied web images vanish as soon as the user copies something else. Adding **Image History Support** stores copied images cleanly on disk with fast thumbnails, SHA-256 deduplication, and instant re-paste—without bloating `config.json` or RAM.

### User Flows & UX
- **Automatic Image Capture:**
  - Copying an image (from Preview, browsers, Slack, `QuickScreenshot`, or `⇧ ⌃ ⌘ 4`) adds an image entry to `Clipboard History` with a rounded `48 × 36` pt thumbnail, pixel dimensions & byte size (e.g., `"1440 × 900 · 412 KB"`), and an `IMG` pill badge.
  - Users can pin (`⌘ P`), name/rename (`⌘ R`), reorder pinned items, and delete (`⌫`) image entries identically to text entries.
- **Popover Filtering & Inspector (`ClipboardPopoverView.swift`):**
  - Filter chips (`All`, `Text`, `Images`, `Pinned`) let users jump straight to recent screenshots/images; text search matches custom titles and dimensions/format labels.
  - Pressing `→`, `Space`, or `⌘ I` opens the **Inspector** showing a crisp scaled image preview, metadata, and quick actions (`Paste`, `Copy`, `Pin`, `Rename`, `Save As…`, `Delete`).
- **Settings View Additions (`ClipboardSettingsView.swift`):**
  - Add an `IMAGE HISTORY` `FeatureSection` using `SettingRow`, `Divider()`, and `.pointerCursor()`:
    - `Capture copied images` toggle (`captureImages`, default `true`).
    - `Max image items` stepper (`maxImageItems`, default `15`, range `1–100`).
    - `Max image size (MB)` stepper (`maxImageSizeMB`, default `20`, range `1–100`).
    - Live disk usage readout + **Clear Image Cache** button (preserving pinned images unless confirmed).

### Files to Create & Modify
- **Create:** `Sources/Toolbox/Modules/Clipboard/ClipboardImageStore.swift`
- **Modify:** `Sources/Toolbox/Modules/Clipboard/ClipboardModule.swift` (backward-compatible `ClipboardEntry`, pasteboard image classification, restore-to-pasteboard, cache cleanup)
- **Modify:** `Sources/Toolbox/Modules/Clipboard/ClipboardPopoverView.swift` (thumbnail rows, `All / Text / Images / Pinned` filter chips, Inspector image preview + `Save As…`)
- **Modify:** `Sources/Toolbox/Modules/Clipboard/ClipboardSettingsView.swift` (`IMAGE HISTORY` section)
- **Modify:** `Sources/Toolbox/Core/ConfigManager.swift` (add 3 fields to `ClipboardConfig` with lenient `decodeIfPresent`)
- **Modify:** `Sources/Toolbox/Core/SelfTestRunner.swift` and `Sources/Toolbox/Core/SnapshotRunner.swift`

### Technical Design & macOS APIs
1. **Backward-Compatible `ClipboardEntry`:**
   ```swift
   enum ClipboardEntryKind: String, Codable, Equatable, Sendable {
       case text, image
   }

   struct ClipboardImageMetadata: Codable, Equatable, Sendable {
       var filename: String
       var thumbnailFilename: String
       var sha256: String
       var pixelWidth: Int
       var pixelHeight: Int
       var byteSize: Int
   }
   ```
   - Keep `text: String` (empty or descriptive label like `"Image 1440×900"` for image entries) and decode `kind` via `decodeIfPresent(ClipboardEntryKind.self, forKey: .kind) ?? .text` and `image` via `decodeIfPresent` so existing `pinned_clipboard.json` and `clipboard_history.json` files load seamlessly.
2. **Pasteboard Classification Precedence (`pollPasteboard()`):**
   - After existing `ignoreConcealedTypes` checks:
     1. **Finder file-icon guard:** If `NSPasteboard.general` contains `.fileURL`, do **not** capture its icon `.tiff` as an image!
     2. **Rich-text guard:** If `NSPasteboard.general.string(forType: .string)` is non-empty, capture as `.text` (prevents Word, Excel, Notes, and browsers from polluting image history with preview TIFFs alongside copied text).
     3. **Image types:** Otherwise inspect `NSPasteboard.PasteboardType.png`, `NSPasteboard.PasteboardType("public.jpeg")`, `NSPasteboard.PasteboardType("public.heic")`, and `.tiff` in priority order.
3. **On-Disk Image Store (`ClipboardImageStore`):**
   - Store normalized PNGs (`<uuid>.png`) and `240 px` max-dimension thumbnails (`<uuid>-thumb.png`, generated via `CGImageSourceCreateThumbnailAtIndex`) inside `ConfigManager.shared.configURL.deletingLastPathComponent().appendingPathComponent("clipboard-images")` with owner-only permissions (`0700` directory, `0600` PNG files) so `TOOLBOX_CONFIG_DIR`, `--self-test`, and `--snapshot-ui` stay isolated automatically.
   - Run PNG normalization, `CryptoKit.SHA256` hashing, and thumbnail generation off the main thread in `Task.detached` guarded by `latestCapturedChangeCount` so large 5K screenshots never hitch the `300 ms` poll timer.
   - Deduplicate matching `SHA256` hashes when `config.deduplicate == true`, and reject raw payloads exceeding `config.maxImageSizeMB * 1024 * 1024` bytes.
   - Cache small decoded thumbnails in `NSCache<NSString, NSImage>` (never hold full-resolution bitmaps in RAM); lazy-load full image only for Inspector preview or paste restore.
   - Delete unreferenced image/thumbnail files when an unpinned entry is evicted (enforcing `maxImageItems` independently of text `maxItems`), deleted, or cleared; run `sweepOrphanedFiles(referencedFilenames:)` on launch.
4. **Restore to Pasteboard:**
   - Write both `.png` and `.tiff` representations to `NSPasteboard.general`, update `lastChangeCount` before auto-pasting to avoid self-recapture, and trigger `⌘ V` if `pasteAutomatically == true`.

### Configuration Additions (`ClipboardConfig`)
Add to `ClipboardConfig` in `Sources/Toolbox/Core/ConfigManager.swift` (with lenient `decodeIfPresent` defaults):
```swift
var captureImages: Bool = true
var maxImageItems: Int = 15
var maxImageSizeMB: Int = 20
```

### Verification & Self-Tests
- **Backward-compatible decoding (`SelfTestRunner`):** Decode legacy `ClipboardEntry` JSON (without `kind` or `image`) and assert `kind == .text` and `image == nil`.
- **`ClipboardImageStore` (`SelfTestRunner`):** Verify saving a synthetic `CGImage` in an isolated temp config dir creates full PNG + thumbnail, records exact pixel dimensions, deduplicates matching SHA-256 hashes, rejects payloads over `maxImageSizeMB`, deletes files on eviction/delete, and `sweepOrphanedFiles` removes unreferenced files while keeping pinned files.
- **Pasteboard classification (`SelfTestRunner`):** Verify `.fileURL` + `.tiff` is ignored, `.string` + `.tiff` captures `.text`, and `.png` / `.tiff` captures `.image`.
- **Config migration (`SelfTestRunner`):** Decode legacy `ClipboardConfig` JSON missing the 3 new keys and assert safe defaults (`true`, `15`, `20`).
- **Visual Snapshot (`SnapshotRunner`):** Update clipboard popover snapshot coverage to include an image row thumbnail.

### Edge Cases & Pitfalls
- **Finder `.fileURL` icon TIFFs & rich-text previews:** Precedence rules above prevent copied files or styled text from appearing as fake image entries.
- **`persistHistory == false`:** Purge unpinned image files on `stop()` / launch while preserving pinned image files referenced by `pinned_clipboard.json`.
- **Pinned image deletion safety:** Never delete an image file on disk if another pinned or unpinned entry shares the same `filename` (from deduplication).
- **`QuickScreenshot` synergy:** `QuickScreenshot` writes PNG + TIFF to `NSPasteboard.general`, which `ClipboardModule` picks up automatically as a crisp image entry.
